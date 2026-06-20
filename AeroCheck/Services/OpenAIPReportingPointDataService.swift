import Foundation
import CoreLocation

/// On-disk metadata for the reporting-point cache (per-country last-sync + count). Mirrors `ObstacleCacheMetadata`.
struct ReportingPointCacheMetadata: Codable {
    var lastSyncDates: [String: Date] = [:]
    var counts: [String: Int] = [:]
}

/// Manages OpenAIP VFR REPORTING-POINT data via the keyless, per-country GeoJSON exports
/// (`storage.googleapis.com/.../{cc}_rpp.geojson`) — a sibling to `OpenAIPObstacleDataService`, sharing
/// its lazy-load + atomic per-country cache and a region query for the read-only nav-map markers.
/// New OpenAIP layer for v4.1.0; additive — it does not touch the working airspace path.
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

    private var points: [ReportingPoint] = []

    // MARK: - Storage

    private let fileManager = FileManager.default
    private var dataDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("OpenAIPReportingPointData", isDirectory: true)
    }
    private var metadataFileURL: URL { dataDirectory.appendingPathComponent("metadata.json") }
    private func pointFileURL(for country: String) -> URL {
        dataDirectory.appendingPathComponent("reportingpoints_\(country).json")
    }

    init() {
        if let data = try? Data(contentsOf: metadataFileURL),
           let metadata = try? JSONDecoder().decode(ReportingPointCacheMetadata.self, from: data) {
            downloadedCountries = metadata.counts.keys.sorted()
            reportingPointCount = metadata.counts.values.reduce(0, +)
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
              let metadata = try? JSONDecoder().decode(ReportingPointCacheMetadata.self, from: metaData) else { return }
        let urls = metadata.counts.keys.map { pointFileURL(for: $0) }
        let loaded: [ReportingPoint] = await Task.detached(priority: .userInitiated) {
            let decoder = JSONDecoder()
            var all: [ReportingPoint] = []
            for url in urls {
                guard let data = try? Data(contentsOf: url),
                      let decoded = try? decoder.decode([ReportingPoint].self, from: data) else { continue }
                all.append(contentsOf: decoded)
            }
            return all
        }.value
        points = loaded
        reportingPointCount = loaded.count
        isLoaded = true
    }

    // MARK: - Download (keyless GeoJSON exports)

    func downloadData(for countries: [String]) async {
        guard !isDownloading, !countries.isEmpty else { return }
        isDownloading = true
        downloadProgress = 0
        downloadError = nil
        defer { isDownloading = false }

        try? fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        var metadata = (try? Data(contentsOf: metadataFileURL))
            .flatMap { try? JSONDecoder().decode(ReportingPointCacheMetadata.self, from: $0) } ?? ReportingPointCacheMetadata()
        var allLoaded: [ReportingPoint] = []

        for (index, country) in countries.enumerated() {
            let cc = country.lowercased()
            guard let url = URL(string: "\(OpenAIPConfig.geoJSONExportBaseURL)/\(cc)_rpp.geojson") else { continue }
            do {
                let (data, response) = try await ExternalRequest.data(from: url)
                guard response.statusCode == 200 else {
                    appendExistingCache(for: country, into: &allLoaded)
                    continue
                }
                let parsed = try ReportingPoint.parse(geoJSON: data)
                let encoded = try JSONEncoder().encode(parsed)
                try encoded.write(to: pointFileURL(for: country), options: .atomic)
                metadata.counts[country] = parsed.count
                metadata.lastSyncDates[country] = Date()
                allLoaded.append(contentsOf: parsed)
            } catch {
                AppLog.openAIP.debugLine("Reporting-point download failed for \(country): \(error)")
                appendExistingCache(for: country, into: &allLoaded)
            }
            downloadProgress = Double(index + 1) / Double(countries.count)
        }

        if let metaEncoded = try? JSONEncoder().encode(metadata) {
            try? metaEncoded.write(to: metadataFileURL, options: .atomic)
        }
        // Keep already-cached countries not re-requested this call in memory (review #5).
        for country in metadata.counts.keys where !countries.contains(country) {
            appendExistingCache(for: country, into: &allLoaded)
        }
        points = allLoaded
        reportingPointCount = allLoaded.count
        downloadedCountries = metadata.counts.keys.sorted()
        lastUpdated = metadata.lastSyncDates.values.max()
        isDataAvailable = !downloadedCountries.isEmpty
        isLoaded = true
    }

    private func appendExistingCache(for country: String, into accumulator: inout [ReportingPoint]) {
        if let data = try? Data(contentsOf: pointFileURL(for: country)),
           let decoded = try? JSONDecoder().decode([ReportingPoint].self, from: data) {
            accumulator.append(contentsOf: decoded)
        }
    }

    // MARK: - Queries

    /// Reporting points whose coordinate falls within the lat/lon ranges (for map markers).
    func reportingPointsInRegion(latRange: ClosedRange<Double>, lonRange: ClosedRange<Double>) -> [ReportingPoint] {
        points.filter { latRange.contains($0.latitude) && lonRange.contains($0.longitude) }
    }

    /// Nearest reporting points to a coordinate (for briefings), within `maxDistanceNm`, closest first,
    /// capped at `limit`. Compulsory points are surfaced ahead of on-request ones at equal distance.
    func reportingPointsNear(to coord: CLLocationCoordinate2D, maxDistanceNm: Double, limit: Int) -> [ReportingPoint] {
        points
            .compactMap { p -> (ReportingPoint, Double)? in
                let d = p.distanceNM(from: coord)
                return d <= maxDistanceNm ? (p, d) : nil
            }
            .sorted { ($0.1, $0.0.compulsory ? 0 : 1) < ($1.1, $1.0.compulsory ? 0 : 1) }
            .prefix(limit)
            .map { $0.0 }
    }

    func deleteData() {
        try? fileManager.removeItem(at: dataDirectory)
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
