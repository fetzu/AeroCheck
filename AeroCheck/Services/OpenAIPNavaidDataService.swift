import Foundation
import CoreLocation

/// On-disk metadata for the navaid cache (per-country last-sync + count). Mirrors `OpenAIPCacheMetadata`.
struct NavaidCacheMetadata: Codable {
    var lastSyncDates: [String: Date] = [:]
    var counts: [String: Int] = [:]
}

/// Manages OpenAIP NAVAID data via the keyless, per-country GeoJSON exports
/// (`storage.googleapis.com/.../{cc}_nav.geojson`) — a sibling to `OpenAIPDataService`, mirroring its
/// lazy-load + atomic per-country cache, but without the REST pagination / API key. Provides a
/// nearest-navaid query (the flight-plan builder snap + the declination fix) and a region query (map
/// markers). New OpenAIP layer for v4.1.0; additive — it does not touch the working airspace path.
@MainActor
final class OpenAIPNavaidDataService: ObservableObject {
    /// Shared instance — the app DI, the data-status provider, and the flight-plan builder all use this
    /// one instance (the builder reads it directly rather than threading @EnvironmentObject through the
    /// whole presentation chain, mirroring the codebase's other `.shared` managers). (v4.1.0)
    static let shared = OpenAIPNavaidDataService()

    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadError: String?
    @Published var lastUpdated: Date?
    @Published var isDataAvailable = false
    @Published var navaidCount = 0
    @Published var downloadedCountries: [String] = []
    @Published private(set) var isLoaded = false

    private var navaids: [Navaid] = [] {
        didSet { rebuildSpatialGrid() }
    }

    // MARK: - Spatial index (coarse 1° grid, mirrors AirportDataService)

    private struct GridKey: Hashable { let lat: Int; let lon: Int }
    private static let gridCellDegrees = 1.0
    private var spatialGrid: [GridKey: [Navaid]] = [:]

    private func gridKey(lat: Double, lon: Double) -> GridKey {
        GridKey(lat: Int((lat / Self.gridCellDegrees).rounded(.down)),
                lon: Int((lon / Self.gridCellDegrees).rounded(.down)))
    }

    private func rebuildSpatialGrid() {
        var grid: [GridKey: [Navaid]] = [:]
        for navaid in navaids {
            grid[gridKey(lat: navaid.latitude, lon: navaid.longitude), default: []].append(navaid)
        }
        spatialGrid = grid
    }

    // MARK: - Storage

    private let fileManager = FileManager.default
    private var dataDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("OpenAIPNavaidData", isDirectory: true)
    }
    private var metadataFileURL: URL { dataDirectory.appendingPathComponent("metadata.json") }
    private func navaidFileURL(for country: String) -> URL {
        dataDirectory.appendingPathComponent("navaids_\(country).json")
    }

    init() {
        // Restore lightweight metadata (counts/dates) without loading the navaids into memory.
        if let data = try? Data(contentsOf: metadataFileURL),
           let metadata = try? JSONDecoder().decode(NavaidCacheMetadata.self, from: data) {
            downloadedCountries = metadata.counts.keys.sorted()
            navaidCount = metadata.counts.values.reduce(0, +)
            lastUpdated = metadata.lastSyncDates.values.max()
            isDataAvailable = !downloadedCountries.isEmpty
        }
    }

    /// Stale once older than the shared aeronautical-data TTL (90 days).
    var needsUpdate: Bool {
        guard let lastUpdated else { return true }
        return Date().timeIntervalSince(lastUpdated) > OpenAIPConfig.airspaceCacheExpirationInterval
    }

    // MARK: - Load

    func ensureLoaded() async {
        guard !isLoaded else { return }
        await loadFromLocal()
    }

    private func loadFromLocal() async {
        guard let metaData = try? Data(contentsOf: metadataFileURL),
              let metadata = try? JSONDecoder().decode(NavaidCacheMetadata.self, from: metaData) else { return }
        let urls = metadata.counts.keys.map { navaidFileURL(for: $0) }
        let loaded: [Navaid] = await Task.detached(priority: .userInitiated) {
            let decoder = JSONDecoder()
            var all: [Navaid] = []
            for url in urls {
                guard let data = try? Data(contentsOf: url),
                      let decoded = try? decoder.decode([Navaid].self, from: data) else { continue }
                all.append(contentsOf: decoded)
            }
            return all
        }.value
        navaids = loaded
        navaidCount = loaded.count
        isLoaded = true
    }

    // MARK: - Download (keyless GeoJSON exports)

    /// Download + cache navaids for the given countries from the public, keyless GeoJSON exports. A
    /// per-country failure keeps that country's existing cache rather than dropping it.
    func downloadData(for countries: [String]) async {
        guard !isDownloading, !countries.isEmpty else { return }
        isDownloading = true
        downloadProgress = 0
        downloadError = nil
        defer { isDownloading = false }

        try? fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        var metadata = (try? Data(contentsOf: metadataFileURL))
            .flatMap { try? JSONDecoder().decode(NavaidCacheMetadata.self, from: $0) } ?? NavaidCacheMetadata()
        var allLoaded: [Navaid] = []

        for (index, country) in countries.enumerated() {
            let cc = country.lowercased()
            guard let url = URL(string: "\(OpenAIPConfig.geoJSONExportBaseURL)/\(cc)_nav.geojson") else { continue }
            do {
                let (data, response) = try await ExternalRequest.data(from: url)
                guard response.statusCode == 200 else {
                    appendExistingCache(for: country, into: &allLoaded)
                    continue
                }
                let parsed = try Navaid.parse(geoJSON: data)
                let encoded = try JSONEncoder().encode(parsed)
                try encoded.write(to: navaidFileURL(for: country), options: .atomic)
                metadata.counts[country] = parsed.count
                metadata.lastSyncDates[country] = Date()
                allLoaded.append(contentsOf: parsed)
            } catch {
                AppLog.openAIP.debugLine("Navaid download failed for \(country): \(error)")
                appendExistingCache(for: country, into: &allLoaded)
            }
            downloadProgress = Double(index + 1) / Double(countries.count)
        }

        // De-selected countries are pruned (file + metadata) so this layer matches the requested set —
        // consistent with the airspace layer. Additive callers (trip-prefetch, builder, refresh) union
        // before calling, so they pass the full set and lose nothing. (download-integrity fix)
        for country in Set(metadata.counts.keys).subtracting(countries) {
            metadata.counts.removeValue(forKey: country)
            metadata.lastSyncDates.removeValue(forKey: country)
            try? fileManager.removeItem(at: navaidFileURL(for: country))
        }
        if let metaEncoded = try? JSONEncoder().encode(metadata) {
            try? metaEncoded.write(to: metadataFileURL, options: .atomic)
        }
        navaids = allLoaded
        navaidCount = allLoaded.count
        downloadedCountries = metadata.counts.keys.sorted()
        lastUpdated = metadata.lastSyncDates.values.max()
        isDataAvailable = !downloadedCountries.isEmpty
        isLoaded = true
    }

    private func appendExistingCache(for country: String, into accumulator: inout [Navaid]) {
        if let data = try? Data(contentsOf: navaidFileURL(for: country)),
           let decoded = try? JSONDecoder().decode([Navaid].self, from: data) {
            accumulator.append(contentsOf: decoded)
        }
    }

    // MARK: - Queries

    /// Nearest navaid within `maxDistanceNm` — the builder snap target and the declination source.
    func nearestNavaid(to coord: CLLocationCoordinate2D, maxDistanceNm: Double) -> Navaid? {
        let centerKey = gridKey(lat: coord.latitude, lon: coord.longitude)
        let cellSpanNm = Self.gridCellDegrees * 60.0
        let ringRadius = max(1, Int((maxDistanceNm / cellSpanNm).rounded(.up)))
        var best: Navaid?
        var bestDistance = maxDistanceNm
        for dLat in -ringRadius...ringRadius {
            for dLon in -ringRadius...ringRadius {
                guard let bucket = spatialGrid[GridKey(lat: centerKey.lat + dLat, lon: centerKey.lon + dLon)] else { continue }
                for navaid in bucket {
                    let distance = navaid.distanceNM(from: coord)
                    if distance <= bestDistance {
                        bestDistance = distance
                        best = navaid
                    }
                }
            }
        }
        return best
    }

    /// Navaids whose coordinate falls within the lat/lon ranges (for map markers).
    func navaidsInRegion(latRange: ClosedRange<Double>, lonRange: ClosedRange<Double>) -> [Navaid] {
        navaids.filter { latRange.contains($0.latitude) && lonRange.contains($0.longitude) }
    }

    func deleteData() {
        try? fileManager.removeItem(at: dataDirectory)
        navaids = []
        navaidCount = 0
        downloadedCountries = []
        lastUpdated = nil
        isDataAvailable = false
        isLoaded = false
    }

    #if DEBUG
    /// Test seam: seed in-memory navaids without a network download.
    func seedForTesting(_ seeded: [Navaid]) {
        navaids = seeded
        navaidCount = seeded.count
        isLoaded = true
    }
    #endif
}
