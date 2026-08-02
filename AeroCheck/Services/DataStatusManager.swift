import Foundation

// MARK: - Freshness

/// How current a dataset is, derived from its age against per-category thresholds. Ordered by
/// increasing concern so a collection can be reduced to its worst case. (v4.1.0 Data Freshness)
enum DataFreshness: Int, Comparable, CaseIterable {
    case fresh = 0      // within the aging threshold
    case aging = 1      // past aging, within stale
    case stale = 2      // past the stale threshold
    case missing = 3    // never downloaded

    static func < (lhs: DataFreshness, rhs: DataFreshness) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Age thresholds for a category, in seconds. `aging` is the soft hint, `stale` the hard one. Shown as
/// "data as of <date>" — never as an AIRAC cycle number (the crowd-sourced data isn't AIRAC-aligned).
struct FreshnessThresholds: Equatable {
    let aging: TimeInterval
    let stale: TimeInterval

    private static let day: TimeInterval = 24 * 60 * 60

    /// Charts + airspace: ~AIRAC cadence as a soft hint, the existing 90-day TTL as the hard one.
    static let aeronautical = FreshnessThresholds(aging: 28 * day, stale: 90 * day)
    /// Airports: slower-moving than airspace.
    static let airports = FreshnessThresholds(aging: 90 * day, stale: 180 * day)

    /// Classify an age (`now − lastUpdated`). A nil `lastUpdated` is `.missing`; a future date (clock
    /// skew) is treated as `.fresh`.
    func freshness(lastUpdated: Date?, now: Date) -> DataFreshness {
        guard let lastUpdated else { return .missing }
        let age = now.timeIntervalSince(lastUpdated)
        if age >= stale { return .stale }
        if age >= aging { return .aging }
        return .fresh
    }
}

// MARK: - Descriptor

/// Whether a dataset is safety-relevant structured data or merely cartographic imagery. Drives the
/// weighted Home-dot reduction: stale IMAGERY never raises the dot (it has its own nudge and can't be
/// "silently wrong"), stale DATA does. (v4.1.0 Data Freshness)
enum DataSetUrgency { case primary, imagery }

/// Where a dataset comes from — surfaced as a provenance caveat ("community-sourced — indicative only").
enum DataProvenance { case community, official, bundled }

/// Which connectivity gate governs this dataset's refresh (see `DataRefreshGate`).
enum DataSetRefreshPolicy { case smallSilentJSON, largeTilesConfirmCellular }

/// A uniform, value-type description of one external dataset's currency + footprint. Built by a
/// `DataSetProvider` from a service's state; consumed by `DataStatusManager`, the Settings hub, the
/// Home dot, and the on-map cue. Kept a pure value (no action closures) so it stays `Equatable` and
/// trivially testable; refresh/delete live on the provider/service. (v4.1.0 Data Freshness)
struct DataSet: Identifiable, Equatable {
    let id: String
    let displayName: String
    /// Source + what it contains (e.g. "OpenAIP · controlled airspace, sectors & frequencies"). The
    /// source is named first so users can tell OpenAIP from OurAirports (esp. once both serve airports).
    let detail: String
    let urgency: DataSetUrgency
    let provenance: DataProvenance
    let refreshPolicy: DataSetRefreshPolicy
    let lastUpdated: Date?
    /// `var` so the developer "simulate stale data" toggle can override it to exercise the surfaces.
    var freshness: DataFreshness
    let sizeOnDisk: Int64?        // bytes; nil if unknown / not computed yet
    let coverage: [String]        // region/country codes; empty == global or n/a
    let isDownloaded: Bool
}

// MARK: - Home-dot health

/// The reduced, ambient health shown by the Home status dot. Green (`ok`) is silent — the common case.
enum DataHealth: Int, Comparable {
    case noData = -1    // grey — no primary dataset has ever been downloaded (distinct from "fresh")
    case ok = 0         // green / silent
    case attention = 1  // amber
    case urgent = 2     // red

    static func < (lhs: DataHealth, rhs: DataHealth) -> Bool { lhs.rawValue < rhs.rawValue }

    /// One dataset's contribution to the dot, applying the urgency weighting: imagery never raises the
    /// dot; for primary data `aging → attention`, `stale → urgent`, and `missing → ok` (never-downloaded
    /// optional data isn't a problem — the hub and trip-prefetch surface gaps instead of alarming).
    static func contribution(of dataSet: DataSet) -> DataHealth {
        guard dataSet.urgency == .primary else { return .ok }
        switch dataSet.freshness {
        case .fresh, .missing: return .ok
        case .aging: return .attention
        case .stale: return .urgent
        }
    }

    /// Worst-of-all reduction across datasets.
    static func reduce(_ dataSets: [DataSet]) -> DataHealth {
        dataSets.map { contribution(of: $0) }.max() ?? .ok
    }
}

// MARK: - Provider

/// A source that can describe AND act on its dataset. Adapters wrap the existing services so the
/// services themselves stay untouched. (v4.1.0 Data Freshness)
@MainActor
protocol DataSetProvider {
    /// Stable identifier; matches the `DataSet.id` this provider produces.
    var id: String { get }
    /// Snapshot the dataset's current currency/footprint.
    func makeDataSet(now: Date) -> DataSet
    /// Refresh (download/update) the dataset, reusing the service's existing download path.
    func refresh() async
    /// Delete the dataset's on-disk cache.
    func delete()
    /// For per-country layers: the ISO-2 country codes currently cached, else nil (not country-scoped).
    /// Drives trip-aware prefetch coverage diffing. (v4.1.0)
    var perCountryCoverage: [String]? { get }
    /// For per-country layers: download `countries` (merged with what's already cached) for trip-aware
    /// prefetch. Default no-op for non-country-scoped or intentionally-excluded (e.g. heavy tile) layers.
    func prefetch(countries: [String]) async
}

extension DataSetProvider {
    var perCountryCoverage: [String]? { nil }
    func prefetch(countries: [String]) async {}
}

// MARK: - Manager

/// The single freshness "brain": aggregates a `DataSet` per source, reduces them to the ambient
/// Home-dot health, and dispatches refresh/delete to the owning provider. Foreground-only —
/// `recompute()` runs at construction and (from PR 7) on launch / scenePhase `.active`; no background
/// tasks. (v4.1.0 Data Freshness)
@MainActor
final class DataStatusManager: ObservableObject {

    @Published private(set) var dataSets: [DataSet] = []
    @Published private(set) var overallHealth: DataHealth = .ok
    /// When true, ContentView shows a one-line, snoozable "your data is out of date" nudge. Set only
    /// when a primary dataset is STALE (not merely aging) and the nudge isn't snoozed. (v4.1.0)
    @Published private(set) var showStaleNudge = false

    /// Developer toggle (About → Developer Options): forces every downloaded primary dataset to read
    /// STALE so the Home dot, nudge, and on-map cue can be exercised on device without waiting months. (v4.1.0)
    @Published var debugForceStale = false {
        didSet { recompute() }
    }

    private let providers: [DataSetProvider]
    private let now: () -> Date
    private let userDefaults: UserDefaults
    private let nudgeSnoozeKey = "dataFreshnessNudgeSnoozeUntil"
    private let nudgeSnoozeInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Held for the refresh increment (PR 7) and exposed so the hub can show connectivity and refresh
    /// decisions share one source of truth.
    let networkMonitor: NetworkMonitor

    init(providers: [DataSetProvider], networkMonitor: NetworkMonitor,
         now: @escaping () -> Date = Date.init, userDefaults: UserDefaults = .standard) {
        self.providers = providers
        self.networkMonitor = networkMonitor
        self.now = now
        self.userDefaults = userDefaults
        recompute()
    }

    /// Re-read every provider and recompute the reduced health. Cheap + synchronous (no I/O beyond what
    /// the providers already hold in memory), so it is safe to call on every foreground.
    func recompute() {
        let stamp = now()
        var sets = providers.map { $0.makeDataSet(now: stamp) }
        if debugForceStale {
            sets = sets.map { set in
                var copy = set
                if copy.urgency == .primary && copy.isDownloaded { copy.freshness = .stale }
                return copy
            }
        }
        dataSets = sets
        if debugForceStale {
            overallHealth = .urgent
        } else if !sets.contains(where: { $0.urgency == .primary && $0.isDownloaded }) {
            // Nothing downloaded yet → a distinct grey "No data", not a misleading green "OK". (v4.1.0 fix)
            overallHealth = .noData
        } else {
            overallHealth = DataHealth.reduce(dataSets)
        }
        evaluateNudge()
    }

    // MARK: - Stale-data nudge (snoozable; generalises the OfflineMapManager yearly reminder)

    private var isNudgeSnoozed: Bool {
        guard let until = userDefaults.object(forKey: nudgeSnoozeKey) as? Date else { return false }
        return until > now()
    }

    private func evaluateNudge() {
        // Only the assertive case (STALE primary data → .urgent) nudges; aging stays silent on the dot.
        // The debug toggle forces the nudge regardless of snooze so it can be tested.
        showStaleNudge = (overallHealth == .urgent) && (debugForceStale || !isNudgeSnoozed)
    }

    /// Snooze the nudge for a week (the "remind me later" / tap-to-dismiss action).
    func snoozeNudge() {
        userDefaults.set(now().addingTimeInterval(nudgeSnoozeInterval), forKey: nudgeSnoozeKey)
        showStaleNudge = false
    }

    /// Refresh a single dataset, then recompute the dot.
    func refresh(_ dataSet: DataSet) async {
        await providers.first { $0.id == dataSet.id }?.refresh()
        recompute()
    }

    /// Delete a single dataset's cache, then recompute the dot.
    func delete(_ dataSet: DataSet) {
        providers.first { $0.id == dataSet.id }?.delete()
        recompute()
    }

    /// Trip-aware prefetch (v4.1.0): the route's countries that are NOT yet covered by at least one
    /// per-country layer (airspace / navaids / obstacles / reporting points). Empty → nothing to offer.
    func tripCountriesNeedingData(routeCountries: [String]) -> [String] {
        let perCountry = providers.compactMap { $0.perCountryCoverage }
        guard !perCountry.isEmpty else { return [] }
        return routeCountries.filter { country in
            perCountry.contains { !$0.contains(country) }
        }
    }

    /// The same gap, split by layer, so the download can be sized before it is offered. Coverage is
    /// per-layer — a device can hold Swiss airspace and no Swiss obstacles — and quoting the size of
    /// data already on disk would overstate what the button is about to do. (v4.4.0)
    func tripCountriesNeedingDataByLayer(routeCountries: [String]) -> [TripDataSizeEstimator.Layer: [String]] {
        var result: [TripDataSizeEstimator.Layer: [String]] = [:]
        for provider in providers {
            guard let layer = Self.sizedLayer(forProviderID: provider.id),
                  let coverage = provider.perCountryCoverage else { continue }
            let missing = routeCountries.filter { !coverage.contains($0) }
            if !missing.isEmpty { result[layer] = missing }
        }
        return result
    }

    /// Provider id → the layer the size estimator knows how to price. Providers with no entry (map
    /// tiles, the OurAirports database) are not part of the trip top-up and carry no per-country cost.
    private static func sizedLayer(forProviderID id: String) -> TripDataSizeEstimator.Layer? {
        switch id {
        case "openaip.airspace": return .airspace
        case "openaip.navaids": return .navaids
        case "openaip.obstacles": return .obstacles
        case "openaip.reportingpoints": return .reportingPoints
        default: return nil
        }
    }

    /// Download the given countries (merged with each layer's existing cache) across every per-country
    /// layer, then recompute. Heavy tile layers opt out via the default no-op. This is an explicit,
    /// user-initiated action, so it isn't subject to the silent-refresh network gate.
    func prefetchTripData(countries: [String]) async {
        guard !countries.isEmpty else { return }
        for provider in providers {
            await provider.prefetch(countries: countries)
        }
        recompute()
    }

    /// Refresh every downloaded small-JSON dataset permitted on the current network (tiles are excluded
    /// — they need an explicit size-shown confirmation). Backs the hub's "Update all". No-op when the
    /// network gate forbids it.
    func refreshAllUpdatable(cellularUpdatesEnabled: Bool) async {
        guard DataRefreshGate.allowsSilentSmallRefresh(networkMonitor.conditions, cellularUpdatesEnabled: cellularUpdatesEnabled) else { return }
        let stamp = now()
        for provider in providers {
            let set = provider.makeDataSet(now: stamp)
            guard set.refreshPolicy == .smallSilentJSON, set.isDownloaded else { continue }
            await provider.refresh()
        }
        recompute()
    }

    /// Delete every dataset's cache ("Remove all downloads"), then recompute.
    func removeAll() {
        providers.forEach { $0.delete() }
        recompute()
    }

    /// Silent foreground auto-refresh (called on scenePhase `.active`): refresh every downloaded
    /// small-JSON dataset that has gone STALE, when the network gate permits. Aging stays untouched
    /// (the soft hint), and large tiles are never auto-refreshed. A successful refresh makes the
    /// dataset fresh, so it won't re-download until it ages out again. (v4.1.0)
    func autoRefreshIfNeeded(cellularUpdatesEnabled: Bool) async {
        guard DataRefreshGate.allowsSilentSmallRefresh(networkMonitor.conditions, cellularUpdatesEnabled: cellularUpdatesEnabled) else { return }
        let stamp = now()
        for provider in providers {
            let set = provider.makeDataSet(now: stamp)
            guard set.refreshPolicy == .smallSilentJSON, set.isDownloaded, set.freshness == .stale else { continue }
            await provider.refresh()
        }
        recompute()
    }
}

// MARK: - Adapters for the existing services

/// OpenAIP airspace vector data — safety-relevant (powers conflict detection + sectors + CTR freqs).
@MainActor
struct OpenAIPAirspaceProvider: DataSetProvider {
    let service: OpenAIPDataService
    var id: String { "openaip.airspace" }
    var perCountryCoverage: [String]? { service.downloadedCountries }
    func prefetch(countries: [String]) async {
        await service.downloadData(for: Array(Set(service.downloadedCountries).union(countries)))
    }

    func makeDataSet(now: Date) -> DataSet {
        DataSet(
            id: id,
            displayName: L10n.DataStorage.airspaceName,
            detail: L10n.DataStorage.airspaceDetail,
            urgency: .primary,
            provenance: .community,
            refreshPolicy: .smallSilentJSON,
            lastUpdated: service.lastUpdated,
            freshness: FreshnessThresholds.aeronautical.freshness(lastUpdated: service.lastUpdated, now: now),
            sizeOnDisk: nil,
            coverage: service.downloadedCountries,
            isDownloaded: service.isDataAvailable
        )
    }

    func refresh() async {
        let countries = service.downloadedCountries
        guard !countries.isEmpty else { return }   // nothing downloaded → nothing to refresh
        await service.downloadData(for: countries)
    }

    func delete() { service.deleteData() }
}

/// OurAirports airport database — global, slower-moving.
@MainActor
struct OurAirportsProvider: DataSetProvider {
    let service: AirportDataService
    var id: String { "ourairports.airports" }

    func makeDataSet(now: Date) -> DataSet {
        DataSet(
            id: id,
            displayName: L10n.DataStorage.airportsName,
            detail: L10n.DataStorage.airportsDetail,
            urgency: .primary,
            provenance: .community,
            // The OurAirports refresh re-downloads the full ~40K-airport CSV (multi-MB), so it must NOT be
            // silently auto-refreshed on cellular — treat it like the large/manual tile downloads. (review #9)
            refreshPolicy: .largeTilesConfirmCellular,
            lastUpdated: service.lastUpdated,
            freshness: FreshnessThresholds.airports.freshness(lastUpdated: service.lastUpdated, now: now),
            sizeOnDisk: nil,
            coverage: [],
            isDownloaded: service.isDataAvailable
        )
    }

    func refresh() async { await service.downloadData() }
    func delete() { service.deleteData() }
}

/// Swiss ICAO chart tiles — cartographic IMAGERY on a yearly (April) cycle with its own update nudge,
/// so freshness follows that cycle (`needsYearlyUpdate`) rather than the day-count thresholds, and it
/// never drives the Home dot.
@MainActor
struct SwissChartsProvider: DataSetProvider {
    let manager: OfflineMapManager
    var id: String { "swisstopo.icao" }

    func makeDataSet(now: Date) -> DataSet {
        let freshness: DataFreshness = manager.isCacheAvailable
            ? (manager.needsYearlyUpdate ? .aging : .fresh)
            : .missing
        return DataSet(
            id: id,
            displayName: L10n.DataStorage.swissChartName,
            detail: L10n.DataStorage.swissChartDetail,
            urgency: .imagery,
            provenance: .official,
            refreshPolicy: .largeTilesConfirmCellular,
            lastUpdated: manager.cacheDate,
            freshness: freshness,
            sizeOnDisk: manager.cacheSizeBytes > 0 ? manager.cacheSizeBytes : nil,
            coverage: ["CH"],
            isDownloaded: manager.isCacheAvailable
        )
    }

    func refresh() async { await manager.downloadICAOChart() }
    func delete() { manager.deleteCache() }
}

/// OpenAIP raster map TILES — cartographic IMAGERY, optional and cosmetic (the app draws its own
/// airspace from the vector DATA above; tiles only add labels/navaid symbols). No TTL, so it's fresh
/// when present, and it never drives the Home dot. Surfaced separately per the data-first/tiles-optional
/// stance. (v4.1.0)
@MainActor
struct OpenAIPTilesProvider: DataSetProvider {
    let manager: OpenAIPCacheManager
    var id: String { "openaip.tiles" }

    func makeDataSet(now: Date) -> DataSet {
        DataSet(
            id: id,
            displayName: L10n.DataStorage.openAIPTilesName,
            detail: L10n.DataStorage.openAIPTilesDetail,
            urgency: .imagery,
            provenance: .community,
            refreshPolicy: .largeTilesConfirmCellular,
            lastUpdated: manager.cacheDate,
            freshness: manager.isCacheAvailable ? .fresh : .missing,
            sizeOnDisk: manager.cacheSizeBytes > 0 ? manager.cacheSizeBytes : nil,
            coverage: manager.cachedCountries,
            isDownloaded: manager.isCacheAvailable
        )
    }

    func refresh() async {
        let countries = manager.cachedCountries
        guard !countries.isEmpty else { return }
        await manager.downloadTiles(for: countries)
    }

    func delete() { manager.deleteCache() }
}

/// OpenAIP navaids (VOR/DME/NDB) — structured, nav-relevant data, so it gets the data-first freshness
/// class (primary, small-JSON), not the cosmetic-tile class. (v4.1.0)
@MainActor
struct OpenAIPNavaidProvider: DataSetProvider {
    let service: OpenAIPNavaidDataService
    var id: String { "openaip.navaids" }
    var perCountryCoverage: [String]? { service.downloadedCountries }
    func prefetch(countries: [String]) async {
        await service.downloadData(for: Array(Set(service.downloadedCountries).union(countries)))
    }

    func makeDataSet(now: Date) -> DataSet {
        DataSet(
            id: id,
            displayName: L10n.DataStorage.navaidsName,
            detail: L10n.DataStorage.navaidsDetail,
            urgency: .primary,
            provenance: .community,
            refreshPolicy: .smallSilentJSON,
            lastUpdated: service.lastUpdated,
            freshness: FreshnessThresholds.aeronautical.freshness(lastUpdated: service.lastUpdated, now: now),
            sizeOnDisk: nil,
            coverage: service.downloadedCountries,
            isDownloaded: service.isDataAvailable
        )
    }

    func refresh() async {
        let countries = service.downloadedCountries
        guard !countries.isEmpty else { return }
        await service.downloadData(for: countries)
    }

    func delete() { service.deleteData() }
}

@MainActor
struct OpenAIPObstacleProvider: DataSetProvider {
    let service: OpenAIPObstacleDataService
    var id: String { "openaip.obstacles" }
    var perCountryCoverage: [String]? { service.downloadedCountries }
    func prefetch(countries: [String]) async {
        await service.downloadData(for: Array(Set(service.downloadedCountries).union(countries)))
    }

    func makeDataSet(now: Date) -> DataSet {
        DataSet(
            id: id,
            displayName: L10n.DataStorage.obstaclesName,
            detail: L10n.DataStorage.obstaclesDetail,
            urgency: .primary,
            provenance: .community,
            refreshPolicy: .smallSilentJSON,
            lastUpdated: service.lastUpdated,
            freshness: FreshnessThresholds.aeronautical.freshness(lastUpdated: service.lastUpdated, now: now),
            sizeOnDisk: nil,
            coverage: service.downloadedCountries,
            isDownloaded: service.isDataAvailable
        )
    }

    func refresh() async {
        let countries = service.downloadedCountries
        guard !countries.isEmpty else { return }
        await service.downloadData(for: countries)
    }

    func delete() { service.deleteData() }
}

@MainActor
struct OpenAIPReportingPointProvider: DataSetProvider {
    let service: OpenAIPReportingPointDataService
    var id: String { "openaip.reportingpoints" }
    var perCountryCoverage: [String]? { service.downloadedCountries }
    func prefetch(countries: [String]) async {
        await service.downloadData(for: Array(Set(service.downloadedCountries).union(countries)))
    }

    func makeDataSet(now: Date) -> DataSet {
        DataSet(
            id: id,
            displayName: L10n.DataStorage.reportingPointsName,
            detail: L10n.DataStorage.reportingPointsDetail,
            urgency: .primary,
            provenance: .community,
            refreshPolicy: .smallSilentJSON,
            lastUpdated: service.lastUpdated,
            freshness: FreshnessThresholds.aeronautical.freshness(lastUpdated: service.lastUpdated, now: now),
            sizeOnDisk: nil,
            coverage: service.downloadedCountries,
            isDownloaded: service.isDataAvailable
        )
    }

    func refresh() async {
        let countries = service.downloadedCountries
        guard !countries.isEmpty else { return }
        await service.downloadData(for: countries)
    }

    func delete() { service.deleteData() }
}
