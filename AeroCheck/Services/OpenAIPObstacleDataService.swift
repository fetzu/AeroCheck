import Foundation
import CoreLocation

/// On-disk metadata for the obstacle cache (per-country last-sync + count). Mirrors `NavaidCacheMetadata`.
struct ObstacleCacheMetadata: Codable {
    var lastSyncDates: [String: Date] = [:]
    var counts: [String: Int] = [:]
}

/// Manages OpenAIP OBSTACLE data via the keyless, per-country GeoJSON exports
/// (`storage.googleapis.com/.../{cc}_obs.geojson`) — a sibling to `OpenAIPNavaidDataService`, sharing its
/// lazy-load + atomic per-country cache. Obstacles are read-only situational-awareness markers (no snap,
/// no nearest query), so this drops the spatial grid and keeps only a region query for map markers.
/// New OpenAIP layer for v4.1.0; additive — it does not touch the working airspace path.
@MainActor
final class OpenAIPObstacleDataService: ObservableObject {
    /// Shared instance — the app DI, the data-status provider, the download sheet, and the nav map all
    /// read this one instance directly (mirrors `OpenAIPNavaidDataService.shared`), so no service has to
    /// be threaded through @EnvironmentObject. (v4.1.0)
    static let shared = OpenAIPObstacleDataService()

    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadError: String?
    @Published var lastUpdated: Date?
    @Published var isDataAvailable = false
    @Published var obstacleCount = 0
    @Published var downloadedCountries: [String] = []
    @Published private(set) var isLoaded = false

    private var obstacles: [Obstacle] = []

    // MARK: - Storage

    private let fileManager = FileManager.default
    private var dataDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("OpenAIPObstacleData", isDirectory: true)
    }
    private var metadataFileURL: URL { dataDirectory.appendingPathComponent("metadata.json") }
    private func obstacleFileURL(for country: String) -> URL {
        dataDirectory.appendingPathComponent("obstacles_\(country).json")
    }

    init() {
        // Restore lightweight metadata (counts/dates) without loading the obstacles into memory.
        if let data = try? Data(contentsOf: metadataFileURL),
           let metadata = try? JSONDecoder().decode(ObstacleCacheMetadata.self, from: data) {
            downloadedCountries = metadata.counts.keys.sorted()
            obstacleCount = metadata.counts.values.reduce(0, +)
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
              let metadata = try? JSONDecoder().decode(ObstacleCacheMetadata.self, from: metaData) else { return }
        let urls = metadata.counts.keys.map { obstacleFileURL(for: $0) }
        let loaded: [Obstacle] = await Task.detached(priority: .userInitiated) {
            let decoder = JSONDecoder()
            var all: [Obstacle] = []
            for url in urls {
                guard let data = try? Data(contentsOf: url),
                      let decoded = try? decoder.decode([Obstacle].self, from: data) else { continue }
                all.append(contentsOf: decoded)
            }
            return all
        }.value
        obstacles = loaded
        obstacleCount = loaded.count
        isLoaded = true
    }

    // MARK: - Download (keyless GeoJSON exports)

    /// Download + cache obstacles for the given countries from the public, keyless GeoJSON exports. A
    /// per-country failure keeps that country's existing cache rather than dropping it.
    func downloadData(for countries: [String]) async {
        guard !isDownloading, !countries.isEmpty else { return }
        isDownloading = true
        downloadProgress = 0
        downloadError = nil
        defer { isDownloading = false }

        try? fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        var metadata = (try? Data(contentsOf: metadataFileURL))
            .flatMap { try? JSONDecoder().decode(ObstacleCacheMetadata.self, from: $0) } ?? ObstacleCacheMetadata()
        var allLoaded: [Obstacle] = []

        for (index, country) in countries.enumerated() {
            let cc = country.lowercased()
            guard let url = URL(string: "\(OpenAIPConfig.geoJSONExportBaseURL)/\(cc)_obs.geojson") else { continue }
            do {
                let (data, response) = try await ExternalRequest.data(from: url)
                guard response.statusCode == 200 else {
                    appendExistingCache(for: country, into: &allLoaded)
                    continue
                }
                let parsed = try Obstacle.parse(geoJSON: data)
                let encoded = try JSONEncoder().encode(parsed)
                try encoded.write(to: obstacleFileURL(for: country), options: .atomic)
                metadata.counts[country] = parsed.count
                metadata.lastSyncDates[country] = Date()
                allLoaded.append(contentsOf: parsed)
            } catch {
                AppLog.openAIP.debugLine("Obstacle download failed for \(country): \(error)")
                appendExistingCache(for: country, into: &allLoaded)
            }
            downloadProgress = Double(index + 1) / Double(countries.count)
        }

        // De-selected countries are pruned (file + metadata) so this layer matches the requested set —
        // consistent with the airspace layer; additive callers union first, so they lose nothing.
        // (download-integrity fix)
        OpenAIPConfig.pruneDeselectedCountries(
            keeping: countries, counts: &metadata.counts, lastSyncDates: &metadata.lastSyncDates,
            fileURL: { obstacleFileURL(for: $0) }, fileManager: fileManager)
        if let metaEncoded = try? JSONEncoder().encode(metadata) {
            try? metaEncoded.write(to: metadataFileURL, options: .atomic)
        }
        obstacles = allLoaded
        obstacleCount = allLoaded.count
        downloadedCountries = metadata.counts.keys.sorted()
        lastUpdated = metadata.lastSyncDates.values.max()
        isDataAvailable = !downloadedCountries.isEmpty
        isLoaded = true
    }

    private func appendExistingCache(for country: String, into accumulator: inout [Obstacle]) {
        if let data = try? Data(contentsOf: obstacleFileURL(for: country)),
           let decoded = try? JSONDecoder().decode([Obstacle].self, from: data) {
            accumulator.append(contentsOf: decoded)
        }
    }

    // MARK: - Queries

    /// Obstacles whose coordinate falls within the lat/lon ranges (for map markers).
    func obstaclesInRegion(latRange: ClosedRange<Double>, lonRange: ClosedRange<Double>) -> [Obstacle] {
        obstacles.filter { latRange.contains($0.latitude) && lonRange.contains($0.longitude) }
    }

    func deleteData() {
        try? fileManager.removeItem(at: dataDirectory)
        obstacles = []
        obstacleCount = 0
        downloadedCountries = []
        lastUpdated = nil
        isDataAvailable = false
        isLoaded = false
    }

    #if DEBUG
    /// Test seam: seed in-memory obstacles without a network download.
    func seedForTesting(_ seeded: [Obstacle]) {
        obstacles = seeded
        obstacleCount = seeded.count
        isLoaded = true
    }
    #endif
}
