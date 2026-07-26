import Foundation
import CoreLocation

/// Manages OpenAIP AIRPORT data via the keyless, per-country GeoJSON exports
/// (`storage.googleapis.com/.../{cc}_apt.geojson`) — a sibling to the other OpenAIP layer services.
/// Feeds `AirportDataMergeEngine` (OpenAIP is the primary airport source; OurAirports gap-fills). When
/// no OpenAIP airport data is downloaded, the merge is a no-op and OurAirports remains the backbone. (v4.1.0)
///
/// The cache/download lifecycle (same directories, file names and metadata shape as before) is
/// delegated to a shared `OpenAIPLayerCache`; this service keeps its published surface and queries.
@MainActor
final class OpenAIPAirportDataService: ObservableObject {
    static let shared = OpenAIPAirportDataService()

    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadError: String?
    @Published var lastUpdated: Date?
    @Published var isDataAvailable = false
    @Published var airportCount = 0
    @Published var downloadedCountries: [String] = []
    @Published private(set) var isLoaded = false

    private var airports: [OpenAIPAirport] = []

    private let cache = OpenAIPLayerCache<OpenAIPAirport>(
        directoryName: "OpenAIPAirportData",
        filePrefix: "airports",
        endpointSuffix: "apt",
        logLabel: "OpenAIP airport",
        parse: OpenAIPAirport.parse(geoJSON:))

    init() {
        if let summary = cache.restoredSummary() {
            downloadedCountries = summary.downloadedCountries
            airportCount = summary.totalCount
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
        airports = loaded
        airportCount = loaded.count
        isLoaded = true
    }

    // MARK: - Download (keyless GeoJSON exports)

    func downloadData(for countries: [String]) async {
        guard !isDownloading, !countries.isEmpty else { return }
        isDownloading = true
        downloadProgress = 0
        downloadError = nil
        defer { isDownloading = false }

        let result = await cache.downloadData(for: countries) { downloadProgress = $0 }
        airports = result.features
        airportCount = result.features.count
        downloadedCountries = result.summary.downloadedCountries
        lastUpdated = result.summary.lastUpdated
        isDataAvailable = result.summary.isDataAvailable
        isLoaded = true
    }

    // MARK: - Queries

    /// All loaded OpenAIP airports — consumed by the merge engine. Call `ensureLoaded()` first.
    func allLoadedAirports() -> [OpenAIPAirport] { airports }

    /// Drops the in-memory array after the merge has consumed it. (APP-16)
    ///
    /// This service is a read-once source: `allLoadedAirports()` has exactly one caller
    /// (`AirportDataService.applyOpenAIPMergeIfAvailable`), which folds the data into its own
    /// merged store and never reads it again. The raw array nevertheless stayed resident for the
    /// process lifetime — a full second copy of the country dataset, held alongside the merged one
    /// it was already folded into.
    ///
    /// The on-disk cache and the published summary (`airportCount`, `downloadedCountries`,
    /// `lastUpdated`, `isDataAvailable`) are deliberately left intact: Settings renders them, and
    /// `isLoaded = false` means a later `ensureLoaded()` simply re-reads from disk if the data is
    /// ever needed again.
    func releaseLoadedAirports() {
        guard isLoaded else { return }
        airports = []
        isLoaded = false
        AppLog.airportData.debugLine("Released in-memory OpenAIP airport array after merge")
    }

    func airportsInRegion(latRange: ClosedRange<Double>, lonRange: ClosedRange<Double>) -> [OpenAIPAirport] {
        airports.filter { latRange.contains($0.latitude) && lonRange.contains($0.longitude) }
    }

    func deleteData() {
        cache.deleteData()
        airports = []
        airportCount = 0
        downloadedCountries = []
        lastUpdated = nil
        isDataAvailable = false
        isLoaded = false
    }

    #if DEBUG
    func seedForTesting(_ seeded: [OpenAIPAirport]) {
        airports = seeded
        airportCount = seeded.count
        isLoaded = true
    }
    #endif
}
