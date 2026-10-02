import Foundation
import CoreLocation

/// Manages OpenAIP AIRPORT data via the keyless, per-country GeoJSON exports
/// (`s3.openaip.net/openaip-system-exports/{cc}_apt.geojson`) — a sibling to the other OpenAIP layer services.
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
    /// Countries the last download could not update (their old file, if any, is kept). Empty after a
    /// download that served every country. Shown in Navigation & Maps and in Data & Storage. (6.2.0)
    @Published var failedCountries: [String] = []
    @Published var lastUpdated: Date?
    @Published var isDataAvailable = false
    @Published var airportCount = 0
    @Published var downloadedCountries: [String] = []
    @Published private(set) var isLoaded = false

    private var airports: [OpenAIPAirport] = [] {
        // Kept when the array is released after the merge: the merged `Airport` store has no PPR
        // flag, and without this set the answer to "is this field PPR?" disappeared a few seconds
        // after launch — so the flight thread's PPR rows depended on timing. (v5.1)
        didSet {
            guard !airports.isEmpty else { return }
            pprIcaoCodes = Set(airports.filter(\.isPPR).compactMap(\.icaoCode).map { $0.uppercased() })
            hasPPRData = true
            fuelTypesByIcao = Self.fuelIndex(airports)
            aerodromesById = Self.aerodromeIndex(airports)
        }
    }

    /// Fuel grades by uppercased ICAO ident, for the flight thread's fuel row. Kept when the array is
    /// released after the merge, like the PPR set: read from the array, the destination's grades were
    /// gone a few seconds after launch, so the fuel row almost never named them. (6.2.0)
    private(set) var fuelTypesByIcao: [String: [OpenAIPFuelType]] = [:]

    /// The fuel grades OpenAIP lists for `icao`; empty when it lists none or doesn't know the field.
    func fuelTypes(forICAO icao: String) -> [OpenAIPFuelType] {
        fuelTypesByIcao[icao.uppercased()] ?? []
    }

    nonisolated static func fuelIndex(_ airports: [OpenAIPAirport]) -> [String: [OpenAIPFuelType]] {
        Dictionary(airports.compactMap { airport -> (String, [OpenAIPFuelType])? in
            guard let icao = airport.icaoCode?.uppercased(), !icao.isEmpty else { return nil }
            let fuels = airport.fuelTypes
            return fuels.isEmpty ? nil : (icao, fuels)
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Code and name of every OpenAIP aerodrome, by its OpenAIP `_id`: what a reporting point's
    /// `airports` refers to. Survives `releaseLoadedAirports()`, like the PPR set, since the merged
    /// `Airport` store keeps no OpenAIP id. (6.0.1)
    private(set) var aerodromesById: [String: ReportingPointAerodrome] = [:] {
        didSet { aerodromeIndexRevision &+= 1 }
    }
    /// Counts changes of `aerodromesById`, for the maps to relabel their reporting points.
    private(set) var aerodromeIndexRevision = 0
    private var aerodromeIndexTask: Task<Void, Never>?

    /// ICAO idents of the aerodromes OpenAIP flags as PPR. Survives `releaseLoadedAirports()`.
    private(set) var pprIcaoCodes: Set<String> = []
    /// Whether `pprIcaoCodes` has been filled from real data at all — an empty set is then a real
    /// "no PPR fields", not "nothing downloaded".
    private(set) var hasPPRData = false

    /// Called when the downloaded aerodromes change (a download that updated a country, or a delete),
    /// so the merged airport store folds them in without a relaunch. Set once, by the app's
    /// `AirportDataService.followOpenAIPAirports()`. (6.2.0)
    var onAirportsChanged: (@MainActor () -> Void)?

    /// The Application Support directory of the cache: Data & Storage sizes it.
    nonisolated static let directoryName = "OpenAIPAirportData"

    private let cache: OpenAIPLayerCache<OpenAIPAirport>

    /// - Parameter cache: tests only; one in a test directory, with its own fetch.
    init(cache: OpenAIPLayerCache<OpenAIPAirport>? = nil) {
        self.cache = cache ?? OpenAIPLayerCache<OpenAIPAirport>(
            directoryName: Self.directoryName,
            filePrefix: "airports",
            endpointSuffix: "apt",
            restPath: "airports",
            logLabel: "OpenAIP airport",
            parse: OpenAIPAirport.parse(geoJSON:))
        if let summary = self.cache.restoredSummary() {
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
        failedCountries = []
        defer { isDownloading = false }

        let previousCountries = downloadedCountries
        let result = await cache.downloadData(for: countries) { downloadProgress = $0 }
        airports = result.features
        airportCount = result.features.count
        downloadedCountries = result.summary.downloadedCountries
        lastUpdated = result.summary.lastUpdated
        isDataAvailable = result.summary.isDataAvailable
        isLoaded = true
        // A country no source could serve is reported, not swallowed. Silence here is what let the
        // trip-prefetch banner re-offer a download that had just failed, with nothing on screen to
        // say so. (device-test feedback, v4.4.0)
        failedCountries = result.failedCountries
        // New runways and frequencies reached the app only at the next launch, when the merge ran
        // again. Every download path ends here (the download page, Data & Storage, the foreground
        // refresh), so the merge follows from here too. Not after a download that changed nothing:
        // the re-merge reloads the whole airport database. (6.2.0)
        if result.failedCountries.count < countries.count || downloadedCountries != previousCountries {
            onAirportsChanged?()
        }
    }

    // MARK: - Aerodromes of the reporting points (6.0.1)

    /// Fill `aerodromesById` from the cache when the airport array has not been loaded (the merge
    /// runs only once airports are needed). Decodes the files off the main actor and keeps only
    /// codes and names; the array itself stays unloaded. Once per launch.
    func ensureAerodromeIndexLoaded() async {
        guard aerodromesById.isEmpty, isDataAvailable else { return }
        if let running = aerodromeIndexTask { return await running.value }
        let task = Task { @MainActor in
            guard let loaded = await cache.loadFromLocal(), aerodromesById.isEmpty else { return }
            aerodromesById = Self.aerodromeIndex(loaded)
        }
        aerodromeIndexTask = task
        await task.value
        aerodromeIndexTask = nil
    }

    /// The aerodrome a reporting point belongs to: the first of its `airports` that the downloaded
    /// OpenAIP airports know. Nil for a point naming none, or before the airport layer is loaded.
    func aerodrome(for point: ReportingPoint) -> ReportingPointAerodrome? {
        point.airports?.lazy.compactMap { self.aerodromesById[$0] }.first
    }

    func label(for point: ReportingPoint) -> ReportingPointLabel {
        ReportingPointLabel(point: point, aerodrome: aerodrome(for: point))
    }

    nonisolated static func aerodromeIndex(_ airports: [OpenAIPAirport]) -> [String: ReportingPointAerodrome] {
        Dictionary(airports.map { ($0.id, ReportingPointAerodrome(icao: $0.icaoCode, name: $0.name)) },
                   uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Queries

    /// All loaded OpenAIP airports — consumed by the merge engine. Call `ensureLoaded()` first.
    func allLoadedAirports() -> [OpenAIPAirport] { airports }

    /// Drops the in-memory array after the merge has consumed it. (APP-16)
    ///
    /// This service is a read-once source: `allLoadedAirports()` has exactly one caller
    /// (the merge in `AirportDataService`), which folds the data into its own
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

    func deleteData() {
        cache.deleteData()
        airports = []
        aerodromesById = [:]
        pprIcaoCodes = []
        hasPPRData = false
        fuelTypesByIcao = [:]
        airportCount = 0
        downloadedCountries = []
        failedCountries = []
        lastUpdated = nil
        isDataAvailable = false
        isLoaded = false
        // The merged store still held these aerodromes' runways and frequencies until a relaunch.
        onAirportsChanged?()
    }

    #if DEBUG
    func seedForTesting(_ seeded: [OpenAIPAirport]) {
        airports = seeded
        airportCount = seeded.count
        isLoaded = true
    }
    #endif
}
