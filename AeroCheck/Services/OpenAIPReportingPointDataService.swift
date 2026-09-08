import Foundation
import CoreLocation

/// Manages OpenAIP VFR REPORTING-POINT data via the keyless, per-country GeoJSON exports
/// (`storage.googleapis.com/.../{cc}_rpp.geojson`) — a sibling to `OpenAIPObstacleDataService`, sharing
/// its lazy-load + atomic per-country cache. Both the region query (nav-map markers) and the nearest-k
/// query (briefings) sit on hot paths, so this keeps the same 1° spatial grid as
/// `OpenAIPNavaidDataService` to avoid scanning the whole country-wide array on every call.
/// New OpenAIP layer for v4.1.0; additive — it does not touch the working airspace path.
///
/// The cache/download lifecycle (same directories, file names and metadata shape as before) is
/// delegated to a shared `OpenAIPLayerCache`; this service keeps its published surface, spatial
/// grid and queries.
@MainActor
final class OpenAIPReportingPointDataService: ObservableObject {
    static let shared = OpenAIPReportingPointDataService()

    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadError: String?
    @Published var lastUpdated: Date?
    @Published var isDataAvailable = false
    @Published var reportingPointCount = 0
    @Published var downloadedCountries: [String] = []
    @Published private(set) var isLoaded = false

    private var points: [ReportingPoint] = [] {
        didSet { rebuildSpatialGrid() }
    }

    private let cache = OpenAIPLayerCache<ReportingPoint>(
        directoryName: "OpenAIPReportingPointData",
        filePrefix: "reportingpoints",
        endpointSuffix: "rpp",
        restPath: "reporting-points",
        logLabel: "Reporting-point",
        parse: ReportingPoint.parse(geoJSON:))

    // MARK: - Spatial index (coarse 1° grid, mirrors OpenAIPNavaidDataService)

    private struct GridKey: Hashable { let lat: Int; let lon: Int }
    private static let gridCellDegrees = 1.0
    private var spatialGrid: [GridKey: [ReportingPoint]] = [:]

    private func gridKey(lat: Double, lon: Double) -> GridKey {
        GridKey(lat: ((lat / Self.gridCellDegrees).safeRoundedInt(.down, or: 0)),
                lon: ((lon / Self.gridCellDegrees).safeRoundedInt(.down, or: 0)))
    }

    private func rebuildSpatialGrid() {
        var grid: [GridKey: [ReportingPoint]] = [:]
        for point in points {
            grid[gridKey(lat: point.latitude, lon: point.longitude), default: []].append(point)
        }
        spatialGrid = grid
    }

    init() {
        if let summary = cache.restoredSummary() {
            downloadedCountries = summary.downloadedCountries
            reportingPointCount = summary.totalCount
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
        points = loaded
        reportingPointCount = loaded.count
        isLoaded = true
    }

    // MARK: - Download (keyless GeoJSON exports)

    func downloadData(for countries: [String], skippingCached: Bool = false) async {
        guard !isDownloading, !countries.isEmpty else { return }
        isDownloading = true
        downloadProgress = 0
        downloadError = nil
        defer { isDownloading = false }

        let result = await cache.downloadData(for: countries, skippingCached: skippingCached) { downloadProgress = $0 }
        points = result.features
        reportingPointCount = result.features.count
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

    /// Reporting points whose coordinate falls within the lat/lon ranges (for map markers). Gathers only
    /// the grid cells the requested bounds overlap, then applies the exact range check to those
    /// candidates — avoids a full linear scan on the map-region-change hot path.
    /// VFR reporting points in the given ranges, capped at `limit` to bound map annotations. (APP-05)
    /// Truncation is logged rather than silent.
    func reportingPointsInRegion(
        latRange: ClosedRange<Double>,
        lonRange: ClosedRange<Double>,
        limit: Int = 250
    ) -> [ReportingPoint] {
        let minLatKey = ((latRange.lowerBound / Self.gridCellDegrees).safeRoundedInt(.down, or: 0))
        let maxLatKey = ((latRange.upperBound / Self.gridCellDegrees).safeRoundedInt(.down, or: 0))
        let minLonKey = ((lonRange.lowerBound / Self.gridCellDegrees).safeRoundedInt(.down, or: 0))
        let maxLonKey = ((lonRange.upperBound / Self.gridCellDegrees).safeRoundedInt(.down, or: 0))

        var candidates: [ReportingPoint] = []
        for latKey in minLatKey...maxLatKey {
            for lonKey in minLonKey...maxLonKey {
                if let cell = spatialGrid[GridKey(lat: latKey, lon: lonKey)] {
                    candidates.append(contentsOf: cell)
                }
            }
        }

        let inRegion = candidates.filter { latRange.contains($0.latitude) && lonRange.contains($0.longitude) }
        guard inRegion.count > limit else { return inRegion }
        AppLog.general.debugLine("Reporting-point region query truncated: \(inRegion.count) in range, showing \(limit)")
        return Array(inRegion.prefix(limit))
    }

    /// Nearest reporting points to a coordinate (for briefings), within `maxDistanceNm`, closest first,
    /// capped at `limit`. Compulsory points are surfaced ahead of on-request ones at equal distance.
    ///
    /// Since `maxDistanceNm` is a fixed cap (unlike `OpenAIPNavaidDataService.nearestNavaid`'s shrinking
    /// best-distance), any point within range must fall inside the ring of cells whose radius covers
    /// `maxDistanceNm` from the center cell — gathered exactly like `nearestNavaid`'s ring walk. The sort
    /// then only has to order those in-range candidates, not the whole country-wide array.
    func reportingPointsNear(to coord: CLLocationCoordinate2D, maxDistanceNm: Double, limit: Int) -> [ReportingPoint] {
        let centerKey = gridKey(lat: coord.latitude, lon: coord.longitude)
        let cellSpanNm = Self.gridCellDegrees * 60.0
        let ringRadius = max(1, Int((maxDistanceNm / cellSpanNm).rounded(.up)))

        var candidates: [(ReportingPoint, Double)] = []
        for dLat in -ringRadius...ringRadius {
            for dLon in -ringRadius...ringRadius {
                guard let bucket = spatialGrid[GridKey(lat: centerKey.lat + dLat, lon: centerKey.lon + dLon)] else { continue }
                for point in bucket {
                    let d = point.distanceNM(from: coord)
                    if d <= maxDistanceNm {
                        candidates.append((point, d))
                    }
                }
            }
        }

        return candidates
            .sorted { ($0.1, $0.0.compulsory ? 0 : 1) < ($1.1, $1.0.compulsory ? 0 : 1) }
            .prefix(limit)
            .map { $0.0 }
    }

    func deleteData() {
        cache.deleteData()
        points = []
        reportingPointCount = 0
        downloadedCountries = []
        lastUpdated = nil
        isDataAvailable = false
        isLoaded = false
    }

    #if DEBUG
    func seedForTesting(_ seeded: [ReportingPoint]) {
        points = seeded
        reportingPointCount = seeded.count
        isLoaded = true
    }
    #endif
}
