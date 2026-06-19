import XCTest
@testable import AeroCheck

/// Unit tests for the v4.1.0 data-freshness backbone: the pure freshness/health rules and the
/// `DataStatusManager` aggregation. No live services — providers are faked.
@MainActor
final class DataStatusManagerTests: XCTestCase {

    private let day: TimeInterval = 24 * 60 * 60
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Freshness thresholds

    func testFreshnessClassifiesByAge() {
        let t = FreshnessThresholds.aeronautical   // aging 28d, stale 90d
        XCTAssertEqual(t.freshness(lastUpdated: now.addingTimeInterval(-1 * day), now: now), .fresh)
        XCTAssertEqual(t.freshness(lastUpdated: now.addingTimeInterval(-28 * day), now: now), .aging)   // boundary inclusive
        XCTAssertEqual(t.freshness(lastUpdated: now.addingTimeInterval(-60 * day), now: now), .aging)
        XCTAssertEqual(t.freshness(lastUpdated: now.addingTimeInterval(-90 * day), now: now), .stale)   // boundary inclusive
        XCTAssertEqual(t.freshness(lastUpdated: now.addingTimeInterval(-200 * day), now: now), .stale)
    }

    func testFreshnessMissingWhenNeverDownloaded() {
        XCTAssertEqual(FreshnessThresholds.airports.freshness(lastUpdated: nil, now: now), .missing)
    }

    func testFreshnessTreatsFutureDateAsFresh() {
        // Clock skew shouldn't read as stale.
        XCTAssertEqual(FreshnessThresholds.aeronautical.freshness(lastUpdated: now.addingTimeInterval(day), now: now), .fresh)
    }

    func testAirportsThresholdsAreLongerThanAeronautical() {
        let t = FreshnessThresholds.airports   // aging 90d, stale 180d
        XCTAssertEqual(t.freshness(lastUpdated: now.addingTimeInterval(-60 * day), now: now), .fresh)
        XCTAssertEqual(t.freshness(lastUpdated: now.addingTimeInterval(-120 * day), now: now), .aging)
        XCTAssertEqual(t.freshness(lastUpdated: now.addingTimeInterval(-200 * day), now: now), .stale)
    }

    // MARK: - Health contribution + reduction (weighting)

    private func dataSet(id: String = "x", urgency: DataSetUrgency, freshness: DataFreshness,
                         refreshPolicy: DataSetRefreshPolicy = .smallSilentJSON,
                         isDownloaded: Bool? = nil) -> DataSet {
        DataSet(id: id, displayName: id, detail: id, urgency: urgency, provenance: .community,
                refreshPolicy: refreshPolicy, lastUpdated: nil, freshness: freshness,
                sizeOnDisk: nil, coverage: [], isDownloaded: isDownloaded ?? (freshness != .missing))
    }

    func testPrimaryContributionMapping() {
        XCTAssertEqual(DataHealth.contribution(of: dataSet(urgency: .primary, freshness: .fresh)), .ok)
        XCTAssertEqual(DataHealth.contribution(of: dataSet(urgency: .primary, freshness: .missing)), .ok)
        XCTAssertEqual(DataHealth.contribution(of: dataSet(urgency: .primary, freshness: .aging)), .attention)
        XCTAssertEqual(DataHealth.contribution(of: dataSet(urgency: .primary, freshness: .stale)), .urgent)
    }

    func testImageryNeverRaisesTheDot() {
        // Even stale imagery contributes nothing — it has its own nudge and can't be silently wrong.
        for f in DataFreshness.allCases {
            XCTAssertEqual(DataHealth.contribution(of: dataSet(urgency: .imagery, freshness: f)), .ok)
        }
    }

    func testReduceTakesTheWorstPrimaryAndIgnoresStaleImagery() {
        let sets = [
            dataSet(urgency: .primary, freshness: .fresh),
            dataSet(urgency: .imagery, freshness: .stale),   // must NOT raise the dot
            dataSet(urgency: .primary, freshness: .aging),
        ]
        XCTAssertEqual(DataHealth.reduce(sets), .attention)

        let withStaleData = sets + [dataSet(urgency: .primary, freshness: .stale)]
        XCTAssertEqual(DataHealth.reduce(withStaleData), .urgent)
    }

    func testReduceEmptyIsOk() {
        XCTAssertEqual(DataHealth.reduce([]), .ok)
    }

    // MARK: - Manager aggregation

    final class FakeProvider: DataSetProvider {
        var dataSet: DataSet
        var id: String { dataSet.id }
        private(set) var refreshCount = 0
        private(set) var deleteCount = 0
        init(_ d: DataSet) { dataSet = d }
        func makeDataSet(now: Date) -> DataSet { dataSet }
        func refresh() async { refreshCount += 1 }
        func delete() { deleteCount += 1 }
    }

    /// Per-country mock for trip-aware prefetch: reports coverage + records the prefetch country list.
    final class FakePerCountryProvider: DataSetProvider {
        var dataSet: DataSet
        var coverage: [String]
        private(set) var prefetchedCountries: [String]?
        var id: String { dataSet.id }
        init(_ d: DataSet, coverage: [String]) { dataSet = d; self.coverage = coverage }
        func makeDataSet(now: Date) -> DataSet { dataSet }
        func refresh() async {}
        func delete() {}
        var perCountryCoverage: [String]? { coverage }
        func prefetch(countries: [String]) async { prefetchedCountries = countries }
    }

    func testTripCountriesNeedingDataAndPrefetch() async {
        let net = NetworkMonitor(stub: .disconnected)
        // airspace covers CH only; navaids cover CH + FR. Route crosses CH + FR.
        let asp = FakePerCountryProvider(dataSet(id: "asp", urgency: .primary, freshness: .fresh), coverage: ["CH"])
        let nav = FakePerCountryProvider(dataSet(id: "nav", urgency: .primary, freshness: .fresh), coverage: ["CH", "FR"])
        let manager = DataStatusManager(providers: [asp, nav], networkMonitor: net, now: { self.now })

        // CH is covered by both; FR is missing from airspace → only FR is "needed".
        XCTAssertEqual(manager.tripCountriesNeedingData(routeCountries: ["CH", "FR"]), ["FR"])

        await manager.prefetchTripData(countries: ["FR"])
        XCTAssertEqual(asp.prefetchedCountries, ["FR"])
        XCTAssertEqual(nav.prefetchedCountries, ["FR"])   // both per-country layers get the country
    }

    func testTripCountriesNeedingDataEmptyWhenFullyCovered() {
        let net = NetworkMonitor(stub: .disconnected)
        let p = FakePerCountryProvider(dataSet(id: "asp", urgency: .primary, freshness: .fresh), coverage: ["CH", "FR"])
        let manager = DataStatusManager(providers: [p], networkMonitor: net, now: { self.now })
        XCTAssertTrue(manager.tripCountriesNeedingData(routeCountries: ["CH", "FR"]).isEmpty)
    }

    func testRefreshDispatchesToMatchingProviderOnly() async {
        let net = NetworkMonitor(stub: .disconnected)
        let a = FakeProvider(dataSet(id: "a", urgency: .primary, freshness: .stale))
        let b = FakeProvider(dataSet(id: "b", urgency: .primary, freshness: .stale))
        let manager = DataStatusManager(providers: [a, b], networkMonitor: net, now: { self.now })
        await manager.refresh(manager.dataSets.first { $0.id == "a" }!)
        XCTAssertEqual(a.refreshCount, 1)
        XCTAssertEqual(b.refreshCount, 0)
    }

    func testDeleteAndRemoveAll() {
        let net = NetworkMonitor(stub: .disconnected)
        let a = FakeProvider(dataSet(id: "a", urgency: .primary, freshness: .stale))
        let b = FakeProvider(dataSet(id: "b", urgency: .primary, freshness: .stale))
        let manager = DataStatusManager(providers: [a, b], networkMonitor: net, now: { self.now })
        manager.delete(manager.dataSets.first { $0.id == "b" }!)
        XCTAssertEqual(b.deleteCount, 1)
        XCTAssertEqual(a.deleteCount, 0)
        manager.removeAll()
        XCTAssertEqual(a.deleteCount, 1)
        XCTAssertEqual(b.deleteCount, 2)
    }

    func testRefreshAllUpdatableRespectsGateAndSkipsTiles() async {
        // Offline → gate forbids → nothing refreshes.
        let offlineMon = NetworkMonitor(stub: .disconnected)
        let p = FakeProvider(dataSet(id: "a", urgency: .primary, freshness: .stale, isDownloaded: true))
        let m1 = DataStatusManager(providers: [p], networkMonitor: offlineMon, now: { self.now })
        await m1.refreshAllUpdatable(cellularUpdatesEnabled: true)
        XCTAssertEqual(p.refreshCount, 0)

        // Wi-Fi → downloaded small-JSON refreshes; tiles are excluded from Update-all.
        let wifi = NetworkConditions(isConnected: true, isWiFi: true, isExpensive: false, isConstrained: false)
        let wifiMon = NetworkMonitor(stub: wifi)
        let small = FakeProvider(dataSet(id: "small", urgency: .primary, freshness: .stale, refreshPolicy: .smallSilentJSON, isDownloaded: true))
        let tile = FakeProvider(dataSet(id: "tile", urgency: .imagery, freshness: .stale, refreshPolicy: .largeTilesConfirmCellular, isDownloaded: true))
        let m2 = DataStatusManager(providers: [small, tile], networkMonitor: wifiMon, now: { self.now })
        await m2.refreshAllUpdatable(cellularUpdatesEnabled: true)
        XCTAssertEqual(small.refreshCount, 1)
        XCTAssertEqual(tile.refreshCount, 0)
    }

    // MARK: - Stale-data nudge

    func testStaleNudgeFiresOnUrgentAndSnoozeSilencesIt() {
        let suite = UserDefaults(suiteName: "test.nudge.\(UUID().uuidString)")!
        let net = NetworkMonitor(stub: .disconnected)
        let stale = FakeProvider(dataSet(id: "a", urgency: .primary, freshness: .stale))
        let manager = DataStatusManager(providers: [stale], networkMonitor: net, now: { self.now }, userDefaults: suite)
        XCTAssertTrue(manager.showStaleNudge)    // stale primary → urgent → nudge
        manager.snoozeNudge()
        XCTAssertFalse(manager.showStaleNudge)
        manager.recompute()
        XCTAssertFalse(manager.showStaleNudge)   // stays snoozed across recompute
    }

    func testNoNudgeWhenOnlyAging() {
        let suite = UserDefaults(suiteName: "test.nudge.\(UUID().uuidString)")!
        let net = NetworkMonitor(stub: .disconnected)
        let aging = FakeProvider(dataSet(id: "a", urgency: .primary, freshness: .aging))
        let manager = DataStatusManager(providers: [aging], networkMonitor: net, now: { self.now }, userDefaults: suite)
        XCTAssertFalse(manager.showStaleNudge)   // aging is silent (dot only)
    }

    // MARK: - Foreground auto-refresh

    func testAutoRefreshOnlyStaleSmallJSONWhenGatePermits() async {
        let wifi = NetworkConditions(isConnected: true, isWiFi: true, isExpensive: false, isConstrained: false)
        let net = NetworkMonitor(stub: wifi)
        let staleSmall = FakeProvider(dataSet(id: "stale", urgency: .primary, freshness: .stale, isDownloaded: true))
        let agingSmall = FakeProvider(dataSet(id: "aging", urgency: .primary, freshness: .aging, isDownloaded: true))
        let staleTile = FakeProvider(dataSet(id: "tile", urgency: .imagery, freshness: .stale, refreshPolicy: .largeTilesConfirmCellular, isDownloaded: true))
        let manager = DataStatusManager(providers: [staleSmall, agingSmall, staleTile], networkMonitor: net, now: { self.now })
        await manager.autoRefreshIfNeeded(cellularUpdatesEnabled: true)
        XCTAssertEqual(staleSmall.refreshCount, 1)
        XCTAssertEqual(agingSmall.refreshCount, 0)   // aging is not auto-refreshed
        XCTAssertEqual(staleTile.refreshCount, 0)    // tiles never auto-refresh
    }

    func testAutoRefreshSkippedWhenGateForbids() async {
        let net = NetworkMonitor(stub: .disconnected)   // offline → gate forbids
        let staleSmall = FakeProvider(dataSet(id: "stale", urgency: .primary, freshness: .stale, isDownloaded: true))
        let manager = DataStatusManager(providers: [staleSmall], networkMonitor: net, now: { self.now })
        await manager.autoRefreshIfNeeded(cellularUpdatesEnabled: true)
        XCTAssertEqual(staleSmall.refreshCount, 0)
    }

    // MARK: - Debug "simulate stale data"

    func testDebugForceStaleDrivesUrgentNudgeAndStaleRows() {
        let suite = UserDefaults(suiteName: "test.nudge.\(UUID().uuidString)")!
        let net = NetworkMonitor(stub: .disconnected)
        let fresh = FakeProvider(dataSet(id: "a", urgency: .primary, freshness: .fresh, isDownloaded: true))
        let manager = DataStatusManager(providers: [fresh], networkMonitor: net, now: { self.now }, userDefaults: suite)
        XCTAssertEqual(manager.overallHealth, .ok)
        XCTAssertFalse(manager.showStaleNudge)

        manager.debugForceStale = true   // didSet → recompute
        XCTAssertEqual(manager.overallHealth, .urgent)
        XCTAssertTrue(manager.showStaleNudge)
        XCTAssertEqual(manager.dataSets.first?.freshness, .stale)   // downloaded primary forced stale

        manager.debugForceStale = false
        XCTAssertEqual(manager.overallHealth, .ok)
        XCTAssertEqual(manager.dataSets.first?.freshness, .fresh)
    }

    func testManagerAggregatesAndReducesOnInit() {
        let net = NetworkMonitor(stub: .disconnected)
        let p1 = FakeProvider(dataSet(urgency: .primary, freshness: .aging))
        let p2 = FakeProvider(dataSet(urgency: .imagery, freshness: .stale))
        let manager = DataStatusManager(providers: [p1, p2], networkMonitor: net, now: { self.now })

        XCTAssertEqual(manager.dataSets.count, 2)
        XCTAssertEqual(manager.overallHealth, .attention)   // aging primary; stale imagery ignored
    }

    func testRecomputePicksUpProviderChanges() {
        let net = NetworkMonitor(stub: .disconnected)
        let p = FakeProvider(dataSet(urgency: .primary, freshness: .fresh))
        let manager = DataStatusManager(providers: [p], networkMonitor: net, now: { self.now })
        XCTAssertEqual(manager.overallHealth, .ok)

        p.dataSet = dataSet(urgency: .primary, freshness: .stale)
        manager.recompute()
        XCTAssertEqual(manager.overallHealth, .urgent)
    }

    // MARK: - Real adapter mapping (state controlled explicitly — the simulator container may already
    // hold cached airspace data, so we set the service's published props rather than rely on disk)

    func testOpenAIPAdapterMapsServiceState() {
        let service = OpenAIPDataService()

        service.isDataAvailable = true
        service.lastUpdated = now.addingTimeInterval(-100 * day)   // > 90d stale threshold
        service.downloadedCountries = ["CH", "DE"]
        let populated = OpenAIPAirspaceProvider(service: service).makeDataSet(now: now)
        XCTAssertEqual(populated.id, "openaip.airspace")
        XCTAssertEqual(populated.urgency, .primary)
        XCTAssertEqual(populated.provenance, .community)
        XCTAssertTrue(populated.isDownloaded)
        XCTAssertEqual(populated.coverage, ["CH", "DE"])
        XCTAssertEqual(populated.freshness, .stale)

        service.isDataAvailable = false
        service.lastUpdated = nil
        let missing = OpenAIPAirspaceProvider(service: service).makeDataSet(now: now)
        XCTAssertFalse(missing.isDownloaded)
        XCTAssertEqual(missing.freshness, .missing)
    }
}
