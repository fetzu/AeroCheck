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

    private func dataSet(urgency: DataSetUrgency, freshness: DataFreshness) -> DataSet {
        DataSet(id: "x", displayName: "x", urgency: urgency, provenance: .community,
                refreshPolicy: .smallSilentJSON, lastUpdated: nil, freshness: freshness,
                sizeOnDisk: nil, coverage: [], isDownloaded: freshness != .missing)
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
        init(_ d: DataSet) { dataSet = d }
        func makeDataSet(now: Date) -> DataSet { dataSet }
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
