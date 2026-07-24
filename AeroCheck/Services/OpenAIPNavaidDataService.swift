import Foundation
import CoreLocation

/// Manages OpenAIP NAVAID data via the keyless, per-country GeoJSON exports
/// (`storage.googleapis.com/.../{cc}_nav.geojson`) — a sibling to `OpenAIPDataService`, mirroring its
/// lazy-load + atomic per-country cache, but without the REST pagination / API key. Provides a
/// nearest-navaid query (the flight-plan builder snap + the declination fix) and a region query (map
/// markers). New OpenAIP layer for v4.1.0; additive — it does not touch the working airspace path.
///
/// The cache/download lifecycle (same directories, file names and metadata shape as before) is
/// delegated to a shared `OpenAIPLayerCache`; this service keeps its published surface, spatial
/// grid and queries.
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

    private let cache = OpenAIPLayerCache<Navaid>(
        directoryName: "OpenAIPNavaidData",
        filePrefix: "navaids",
        endpointSuffix: "nav",
        logLabel: "Navaid",
        parse: Navaid.parse(geoJSON:))

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

    init() {
        // Restore lightweight metadata (counts/dates) without loading the navaids into memory.
        if let summary = cache.restoredSummary() {
            downloadedCountries = summary.downloadedCountries
            navaidCount = summary.totalCount
            lastUpdated = summary.lastUpdated
            isDataAvailable = summary.isDataAvailable
        }
    }

    /// Stale once older than the shared aeronautical-data TTL (90 days).
    var needsUpdate: Bool { cache.isStale(lastUpdated: lastUpdated) }

    // MARK: - Load

    func ensureLoaded() async {
        guard !isLoaded else { return }
        guard let loaded = await cache.loadFromLocal() else { return }
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

        let result = await cache.downloadData(for: countries) { downloadProgress = $0 }
        navaids = result.features
        navaidCount = result.features.count
        downloadedCountries = result.summary.downloadedCountries
        lastUpdated = result.summary.lastUpdated
        isDataAvailable = result.summary.isDataAvailable
        isLoaded = true
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
    /// Gathers only the overlapping grid cells instead of scanning the full array — the grid is
    /// already maintained for `nearestNavaid`, this query just never used it. (PERF-27)
    func navaidsInRegion(latRange: ClosedRange<Double>, lonRange: ClosedRange<Double>) -> [Navaid] {
        let minKey = gridKey(lat: latRange.lowerBound, lon: lonRange.lowerBound)
        let maxKey = gridKey(lat: latRange.upperBound, lon: lonRange.upperBound)
        var result: [Navaid] = []
        for lat in minKey.lat...maxKey.lat {
            for lon in minKey.lon...maxKey.lon {
                guard let bucket = spatialGrid[GridKey(lat: lat, lon: lon)] else { continue }
                for navaid in bucket where latRange.contains(navaid.latitude) && lonRange.contains(navaid.longitude) {
                    result.append(navaid)
                }
            }
        }
        return result
    }

    func deleteData() {
        cache.deleteData()
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
