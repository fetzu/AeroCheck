import Foundation
import CoreLocation

/// Manages OpenAIP OBSTACLE data via the keyless, per-country GeoJSON exports
/// (`storage.googleapis.com/.../{cc}_obs.geojson`) — a sibling to `OpenAIPNavaidDataService`, sharing its
/// lazy-load + atomic per-country cache. Obstacles are read-only situational-awareness markers (no snap,
/// no nearest query), but the region query now sits on the throttled map-region-change hot path
/// (NavigationView + FlightPlanMapBuilderView), so it keeps the same 1° spatial grid as the navaid
/// service to gather only the overlapping cells instead of scanning the whole country-wide array.
/// New OpenAIP layer for v4.1.0; additive — it does not touch the working airspace path.
///
/// The cache/download lifecycle (same directories, file names and metadata shape as before) is
/// delegated to a shared `OpenAIPLayerCache`; this service keeps its published surface, spatial
/// grid and queries.
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

    private var obstacles: [Obstacle] = [] {
        didSet { rebuildSpatialGrid() }
    }

    private let cache = OpenAIPLayerCache<Obstacle>(
        directoryName: "OpenAIPObstacleData",
        filePrefix: "obstacles",
        endpointSuffix: "obs",
        restPath: "obstacles",
        logLabel: "Obstacle",
        parse: Obstacle.parse(geoJSON:))

    // MARK: - Spatial index (coarse 1° grid, mirrors OpenAIPNavaidDataService)

    private struct GridKey: Hashable { let lat: Int; let lon: Int }
    private static let gridCellDegrees = 1.0
    private var spatialGrid: [GridKey: [Obstacle]] = [:]

    private func gridKey(lat: Double, lon: Double) -> GridKey {
        GridKey(lat: ((lat / Self.gridCellDegrees).safeRoundedInt(.down, or: 0)),
                lon: ((lon / Self.gridCellDegrees).safeRoundedInt(.down, or: 0)))
    }

    private func rebuildSpatialGrid() {
        var grid: [GridKey: [Obstacle]] = [:]
        for obstacle in obstacles {
            grid[gridKey(lat: obstacle.latitude, lon: obstacle.longitude), default: []].append(obstacle)
        }
        spatialGrid = grid
    }

    init() {
        // Restore lightweight metadata (counts/dates) without loading the obstacles into memory.
        if let summary = cache.restoredSummary() {
            downloadedCountries = summary.downloadedCountries
            obstacleCount = summary.totalCount
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
        obstacles = loaded
        obstacleCount = loaded.count
        isLoaded = true
    }

    // MARK: - Download (keyless GeoJSON exports)

    /// Download + cache obstacles for the given countries from the public, keyless GeoJSON exports. A
    /// per-country failure keeps that country's existing cache rather than dropping it.
    func downloadData(for countries: [String], skippingCached: Bool = false) async {
        guard !isDownloading, !countries.isEmpty else { return }
        isDownloading = true
        downloadProgress = 0
        downloadError = nil
        defer { isDownloading = false }

        let result = await cache.downloadData(for: countries, skippingCached: skippingCached) { downloadProgress = $0 }
        obstacles = result.features
        obstacleCount = result.features.count
        downloadedCountries = result.summary.downloadedCountries
        lastUpdated = result.summary.lastUpdated
        isDataAvailable = result.summary.isDataAvailable
        isLoaded = true
        // A country no source could serve is reported, not swallowed. Silence here is what let the
        // trip-prefetch banner re-offer a download that had just failed, with nothing on screen to
        // say so. (device-test feedback, v4.4.0)
        downloadError = result.failedCountries.isEmpty ? nil : result.failedCountries.joined(separator: ", ")
    }

    // MARK: - Queries

    /// Obstacles whose coordinate falls within the lat/lon ranges (for map markers). Gathers only the
    /// grid cells the requested bounds overlap, then applies the exact range check to those candidates
    /// — avoids a full linear scan on the throttled map-region-change hot path.
    /// Obstacles whose coordinate falls in the given ranges, capped at `limit`.
    ///
    /// The cap exists because this feeds map annotations directly and was previously unbounded,
    /// unlike its airport and airspace siblings which have capped at 100 for a while — a dense
    /// region could hand the map thousands of markers in one update. (APP-05)
    ///
    /// When the cap truncates, the TALLEST obstacles are kept rather than an arbitrary slice of
    /// grid order: dropping a 2000 ft mast near the aircraft while keeping a low fence post would
    /// be worse than not capping at all. Truncation is logged, never silent.
    func obstaclesInRegion(
        latRange: ClosedRange<Double>,
        lonRange: ClosedRange<Double>,
        limit: Int = 250
    ) -> [Obstacle] {
        let minLatKey = ((latRange.lowerBound / Self.gridCellDegrees).safeRoundedInt(.down, or: 0))
        let maxLatKey = ((latRange.upperBound / Self.gridCellDegrees).safeRoundedInt(.down, or: 0))
        let minLonKey = ((lonRange.lowerBound / Self.gridCellDegrees).safeRoundedInt(.down, or: 0))
        let maxLonKey = ((lonRange.upperBound / Self.gridCellDegrees).safeRoundedInt(.down, or: 0))

        var candidates: [Obstacle] = []
        for latKey in minLatKey...maxLatKey {
            for lonKey in minLonKey...maxLonKey {
                if let cell = spatialGrid[GridKey(lat: latKey, lon: lonKey)] {
                    candidates.append(contentsOf: cell)
                }
            }
        }

        let inRegion = candidates.filter { latRange.contains($0.latitude) && lonRange.contains($0.longitude) }
        guard inRegion.count > limit else { return inRegion }
        AppLog.general.debugLine("Obstacle region query truncated: \(inRegion.count) in range, showing the \(limit) tallest")
        return Array(
            inRegion
                .sorted { ($0.elevationFeetMSL ?? $0.heightFeetAGL ?? 0) > ($1.elevationFeetMSL ?? $1.heightFeetAGL ?? 0) }
                .prefix(limit)
        )
    }

    func deleteData() {
        cache.deleteData()
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
