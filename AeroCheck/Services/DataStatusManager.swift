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
    let displayName: String       // TODO(PR3 hub): swap to L10n.DataFreshness.* keys
    let urgency: DataSetUrgency
    let provenance: DataProvenance
    let refreshPolicy: DataSetRefreshPolicy
    let lastUpdated: Date?
    let freshness: DataFreshness
    let sizeOnDisk: Int64?        // bytes; nil if unknown / not computed yet
    let coverage: [String]        // region/country codes; empty == global or n/a
    let isDownloaded: Bool
}

// MARK: - Home-dot health

/// The reduced, ambient health shown by the Home status dot. Green (`ok`) is silent — the common case.
enum DataHealth: Int, Comparable {
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

/// A source that can describe its current dataset. Adapters wrap the existing services so the services
/// themselves stay untouched in this increment. (v4.1.0 Data Freshness)
@MainActor
protocol DataSetProvider {
    func makeDataSet(now: Date) -> DataSet
}

// MARK: - Manager

/// The single freshness "brain": aggregates a `DataSet` per source and reduces them to the ambient
/// Home-dot health. Foreground-only — `recompute()` runs at construction and (from a later increment)
/// on launch / scenePhase `.active`; there are no background tasks. (v4.1.0 Data Freshness)
@MainActor
final class DataStatusManager: ObservableObject {

    @Published private(set) var dataSets: [DataSet] = []
    @Published private(set) var overallHealth: DataHealth = .ok

    private let providers: [DataSetProvider]
    private let now: () -> Date

    /// Held for the refresh increment (PR 7) and exposed so the hub can show connectivity and refresh
    /// decisions share one source of truth.
    let networkMonitor: NetworkMonitor

    init(providers: [DataSetProvider], networkMonitor: NetworkMonitor, now: @escaping () -> Date = Date.init) {
        self.providers = providers
        self.networkMonitor = networkMonitor
        self.now = now
        recompute()
    }

    /// Re-read every provider and recompute the reduced health. Cheap + synchronous (no I/O beyond what
    /// the providers already hold in memory), so it is safe to call on every foreground.
    func recompute() {
        let stamp = now()
        dataSets = providers.map { $0.makeDataSet(now: stamp) }
        overallHealth = DataHealth.reduce(dataSets)
    }
}

// MARK: - Adapters for the existing services

/// OpenAIP airspace vector data — safety-relevant (powers conflict detection + sectors + CTR freqs).
@MainActor
struct OpenAIPAirspaceProvider: DataSetProvider {
    let service: OpenAIPDataService
    func makeDataSet(now: Date) -> DataSet {
        DataSet(
            id: "openaip.airspace",
            displayName: "Airspace",
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
}

/// OurAirports airport database — global, slower-moving.
@MainActor
struct OurAirportsProvider: DataSetProvider {
    let service: AirportDataService
    func makeDataSet(now: Date) -> DataSet {
        DataSet(
            id: "ourairports.airports",
            displayName: "Airports",
            urgency: .primary,
            provenance: .community,
            refreshPolicy: .smallSilentJSON,
            lastUpdated: service.lastUpdated,
            freshness: FreshnessThresholds.airports.freshness(lastUpdated: service.lastUpdated, now: now),
            sizeOnDisk: nil,
            coverage: [],
            isDownloaded: service.isDataAvailable
        )
    }
}

/// Swiss ICAO chart tiles — cartographic IMAGERY on a yearly (April) cycle with its own update nudge,
/// so freshness follows that cycle (`needsYearlyUpdate`) rather than the day-count thresholds, and it
/// never drives the Home dot.
@MainActor
struct SwissChartsProvider: DataSetProvider {
    let manager: OfflineMapManager
    func makeDataSet(now: Date) -> DataSet {
        let freshness: DataFreshness = manager.isCacheAvailable
            ? (manager.needsYearlyUpdate ? .aging : .fresh)
            : .missing
        return DataSet(
            id: "swisstopo.icao",
            displayName: "Swiss ICAO Chart",
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
}
