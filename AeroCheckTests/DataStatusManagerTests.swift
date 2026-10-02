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

    // MARK: - OpenAIP aerodromes (6.2.0)

    /// One aerodrome per country, as the fake export serves it: Bern for CH, Friedrichshafen for DE.
    private func aerodromes() -> (String) throws -> [OpenAIPAirport] {
        { country in
            let json = """
            { "type": "FeatureCollection", "features": [
              { "type": "Feature", "properties": { "_id": "\(country)-1", "name": "FIELD \(country)",
                  "icaoCode": "\(country == "CH" ? "LSZB" : "EDNY")", "type": 3, "country": "\(country)" },
                "geometry": { "type": "Point", "coordinates": [\(country == "CH" ? "7.4971, 46.9141" : "9.5113, 47.6713")] } }
            ] }
            """
            return try OpenAIPAirport.parse(geoJSON: Data(json.utf8))
        }
    }

    private func row(_ id: String, in manager: DataStatusManager) throws -> DataSet {
        try XCTUnwrap(manager.dataSets.first { $0.id == id })
    }

    /// Like the other OpenAIP layers: primary data, the aeronautical thresholds, silent refresh; its
    /// countries in the row. Not in the trip prefetch (see `OpenAIPAirportProvider.perCountryCoverage`).
    func testTheAerodromeRowFollowsTheAeronauticalThresholds() {
        let layer = makeTestOpenAIPAirportLayer { _ in [] }
        let provider = OpenAIPAirportProvider(service: layer)
        let missing = provider.makeDataSet(now: now)
        XCTAssertEqual(missing.freshness, .missing)
        XCTAssertFalse(missing.isDownloaded)

        layer.isDataAvailable = true
        layer.downloadedCountries = ["CH", "DE"]
        for (age, expected) in [(1.0, DataFreshness.fresh), (40, .aging), (100, .stale)] {
            layer.lastUpdated = now.addingTimeInterval(-age * day)
            XCTAssertEqual(provider.makeDataSet(now: now).freshness, expected, "\(age) days")
        }
        let set = provider.makeDataSet(now: now)
        XCTAssertEqual(set.id, "openaip.airports")
        XCTAssertEqual(set.displayName, L10n.DataStorage.openAIPAirportsName)
        XCTAssertEqual(set.urgency, .primary)
        XCTAssertEqual(set.provenance, .community)
        XCTAssertEqual(set.refreshPolicy, .smallSilentJSON)
        XCTAssertEqual(set.coverage, ["CH", "DE"])
        XCTAssertTrue(set.isDownloaded)
        XCTAssertNil(set.updateFailure)

        XCTAssertNil(provider.perCountryCoverage, "kept out of the trip prefetch")
        let manager = DataStatusManager(providers: [provider], networkMonitor: NetworkMonitor(stub: .disconnected),
                                        now: { self.now }, userDefaults: makeTestDefaults())
        XCTAssertEqual(manager.tripCountriesNeedingData(routeCountries: ["CH", "FR"]), [])
        XCTAssertEqual(manager.overallHealth, .urgent, "stale aerodromes turn the dot red like any primary data")
    }

    /// Stale aerodromes are fetched again by the foreground refresh, which they never were without a
    /// provider.
    func testTheForegroundRefreshUpdatesStaleAerodromes() async throws {
        var fetched: [String] = []
        let serve = aerodromes()
        let layer = makeTestOpenAIPAirportLayer { fetched.append($0); return try serve($0) }
        await layer.downloadData(for: ["CH"])
        layer.lastUpdated = Date().addingTimeInterval(-100 * day)
        let wifi = NetworkConditions(isConnected: true, isWiFi: true, isExpensive: false, isConstrained: false)
        let manager = DataStatusManager(providers: [OpenAIPAirportProvider(service: layer)],
                                        networkMonitor: NetworkMonitor(stub: wifi), userDefaults: makeTestDefaults())
        XCTAssertEqual(try row("openaip.airports", in: manager).freshness, .stale)

        await manager.autoRefreshIfNeeded(cellularUpdatesEnabled: true)
        XCTAssertEqual(fetched, ["CH", "CH"])
        XCTAssertEqual(try row("openaip.airports", in: manager).freshness, .fresh)
    }

    /// "Remove all downloads" removes the aerodromes, on disk and from the merged airport store.
    func testRemoveAllIncludesTheAerodromes() async throws {
        let root = makeTestDirectory()
        let layer = makeTestOpenAIPAirportLayer(root: root, fetch: aerodromes())
        let store = makeTestAirportStore(openAIPAirports: layer)
        store.followOpenAIPAirports()
        await layer.downloadData(for: ["CH"])
        await store.waitForPendingPasses()
        XCTAssertNotNil(store.findAirport(byIdent: "LSZB"))
        let directory = root.appendingPathComponent(OpenAIPAirportDataService.directoryName).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory))

        let manager = DataStatusManager(providers: [OpenAIPAirportProvider(service: layer), OurAirportsProvider(service: store)],
                                        networkMonitor: NetworkMonitor(stub: .disconnected), userDefaults: makeTestDefaults())
        XCTAssertTrue(try row("openaip.airports", in: manager).isDownloaded)
        XCTAssertTrue(store.isDataAvailable, "the store serves the aerodromes")
        XCTAssertFalse(try row("ourairports.airports", in: manager).isDownloaded, "but OurAirports isn't downloaded")
        manager.removeAll()
        await store.waitForPendingPasses()

        XCTAssertEqual(try row("openaip.airports", in: manager).freshness, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory))
        XCTAssertNil(store.findAirport(byIdent: "LSZB"), "the merged store let go of them too")
        XCTAssertFalse(store.isDataAvailable)
        XCTAssertFalse(layer.hasPPRData)
    }

    /// A refresh that leaves a country behind says so under the row, and the next one that completes
    /// clears it.
    func testAFailedUpdateShowsUnderTheRowUntilOneCompletes() async throws {
        var failing: Set<String> = []
        let serve = aerodromes()
        let layer = makeTestOpenAIPAirportLayer { country in
            if failing.contains(country) { throw URLError(.timedOut) }
            return try serve(country)
        }
        await layer.downloadData(for: ["CH", "DE"])
        let manager = DataStatusManager(providers: [OpenAIPAirportProvider(service: layer)],
                                        networkMonitor: NetworkMonitor(stub: .disconnected), userDefaults: makeTestDefaults())
        XCTAssertNil(try row("openaip.airports", in: manager).updateFailure)

        failing = ["DE"]
        await manager.refresh(try row("openaip.airports", in: manager))
        let failed = try row("openaip.airports", in: manager)
        XCTAssertEqual(failed.updateFailure?.countries, ["DE"])
        XCTAssertEqual(failed.coverage, ["CH", "DE"], "DE keeps its old file")
        XCTAssertTrue(L10n.DataStorage.updateFailed(["DE"]).contains("DE"))

        failing = []
        await manager.refresh(try row("openaip.airports", in: manager))
        XCTAssertNil(try row("openaip.airports", in: manager).updateFailure)
    }

    /// Every data row reads its layer's failure: the OpenAIP layers by country, OurAirports without.
    func testEveryDataRowShowsItsFailedUpdate() {
        let airspace = OpenAIPDataService()
        let navaids = OpenAIPNavaidDataService()
        let obstacles = OpenAIPObstacleDataService()
        let points = OpenAIPReportingPointDataService()
        let store = makeTestAirportStore(openAIPAirports: makeTestOpenAIPAirportLayer { _ in [] })
        airspace.failedCountries = ["CH"]
        navaids.failedCountries = ["DE"]
        obstacles.failedCountries = ["AT"]
        points.failedCountries = ["FR"]
        store.downloadError = "The request timed out."
        let providers: [DataSetProvider] = [
            OpenAIPAirspaceProvider(service: airspace), OpenAIPNavaidProvider(service: navaids),
            OpenAIPObstacleProvider(service: obstacles), OpenAIPReportingPointProvider(service: points),
            OurAirportsProvider(service: store),
        ]
        XCTAssertEqual(providers.map { $0.makeDataSet(now: now).updateFailure?.countries },
                       [["CH"], ["DE"], ["AT"], ["FR"], []])

        airspace.failedCountries = []
        navaids.failedCountries = []
        obstacles.failedCountries = []
        points.failedCountries = []
        store.downloadError = nil
        XCTAssertTrue(providers.allSatisfy { $0.makeDataSet(now: now).updateFailure == nil })
    }

    /// The line is short, names the countries, says what to do, and has its French.
    func testTheFailureLineInEnglishAndFrench() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "fr", ofType: "lproj"))
        let french = try XCTUnwrap(Bundle(path: path))
        let missing = "\u{1}missing"
        XCTAssertEqual(french.localizedString(forKey: "Couldn't update %@. Try again on Wi-Fi.", value: missing, table: nil),
                       "Mise à jour impossible : %@. Réessayez en Wi-Fi.")
        XCTAssertEqual(french.localizedString(forKey: "Couldn't update. Try again on Wi-Fi.", value: missing, table: nil),
                       "Mise à jour impossible. Réessayez en Wi-Fi.")
        XCTAssertEqual(french.localizedString(forKey: "Aerodromes", value: missing, table: nil), "Aérodromes")
        XCTAssertNotEqual(french.localizedString(forKey: "OpenAIP · runways, frequencies & PPR · primary source",
                                                 value: missing, table: nil), missing)
        XCTAssertTrue(L10n.DataStorage.updateFailed(["CH", "DE"]).contains("CH, DE"))
        XCTAssertNotEqual(L10n.DataStorage.updateFailed([]), L10n.DataStorage.updateFailed(["CH"]))
    }
}
