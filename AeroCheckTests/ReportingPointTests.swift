import XCTest
import CoreLocation
@testable import AeroCheck

/// Unit tests for the v4.1.0 VFR reporting-point layer: parsing OpenAIP's keyless GeoJSON export into
/// `[ReportingPoint]` (a `compulsory` flag, an elevation measure, remarks; tolerant of missing optionals)
/// + the region query used for the nav-map markers.
final class ReportingPointTests: XCTestCase {

    private let sampleGeoJSON = """
    { "type": "FeatureCollection", "features": [
      { "type": "Feature",
        "properties": { "_id": "rp1", "name": "SIERRA", "compulsory": true, "country": "CH",
          "airports": ["abc"], "elevation": { "value": 727, "unit": 0, "referenceDatum": 1 },
          "remarks": "Les Eplatures VRP - S {SLESE}" },
        "geometry": { "type": "Point", "coordinates": [6.706, 46.956] } },
      { "type": "Feature",
        "properties": { "_id": "rp2", "name": "WHISKEY", "country": "CH" },
        "geometry": { "type": "Point", "coordinates": [7.0, 46.5] } }
    ] }
    """.data(using: .utf8)!

    func testParseReportingPointGeoJSON() throws {
        let points = try ReportingPoint.parse(geoJSON: sampleGeoJSON)
        XCTAssertEqual(points.count, 2)
        let s = points[0]
        XCTAssertEqual(s.id, "rp1")
        XCTAssertEqual(s.name, "SIERRA")
        XCTAssertTrue(s.compulsory)
        XCTAssertEqual(s.remarks, "Les Eplatures VRP - S {SLESE}")
        XCTAssertEqual(s.elevationFeetMSL, Int((727.0 * 3.28084).rounded()))   // meters → feet
        XCTAssertEqual(s.latitude, 46.956, accuracy: 0.00001)
        XCTAssertEqual(s.longitude, 6.706, accuracy: 0.00001)   // [lon, lat] order honoured
    }

    func testParseDefaultsCompulsoryFalseAndOptionals() throws {
        let w = try ReportingPoint.parse(geoJSON: sampleGeoJSON)[1]
        XCTAssertFalse(w.compulsory)        // absent → false
        XCTAssertNil(w.elevationFeetMSL)
        XCTAssertNil(w.remarks)
    }

    func testParseSkipsMalformedGeometry() throws {
        let json = """
        {"type":"FeatureCollection","features":[{"type":"Feature",
          "properties":{"_id":"z","name":"X"},
          "geometry":{"type":"Point","coordinates":[7]}}]}
        """.data(using: .utf8)!
        XCTAssertTrue(try ReportingPoint.parse(geoJSON: json).isEmpty)   // single coordinate → skipped
    }

    func testParseSkipsFeatureMissingRequiredPropertyWithoutAbortingRest() throws {
        // A feature missing the REQUIRED `_id` must be skipped, not abort the whole FeatureCollection
        // decode. (v4.1.0 pre-tag fix — M1)
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","properties":{"_id":"ok1","name":"ALPHA"},"geometry":{"type":"Point","coordinates":[7.0,46.8]}},
          {"type":"Feature","properties":{"name":"NO ID"},"geometry":{"type":"Point","coordinates":[7.1,46.9]}},
          {"type":"Feature","properties":{"_id":"ok2","name":"BRAVO"},"geometry":{"type":"Point","coordinates":[6.1,46.4]}}
        ]}
        """.data(using: .utf8)!
        XCTAssertEqual(try ReportingPoint.parse(geoJSON: json).map(\.id), ["ok1", "ok2"])   // middle skipped, rest survive
    }

    @MainActor
    func testReportingPointsInRegion() throws {
        let service = OpenAIPReportingPointDataService()
        service.seedForTesting(try ReportingPoint.parse(geoJSON: sampleGeoJSON))

        let inBox = service.reportingPointsInRegion(latRange: 46.9...47.0, lonRange: 6.7...6.8)
        XCTAssertEqual(inBox.count, 1)
        XCTAssertEqual(inBox.first?.id, "rp1")

        XCTAssertTrue(service.reportingPointsInRegion(latRange: 0...1, lonRange: 0...1).isEmpty)
    }

    /// The 1° spatial grid added for the perf review (30-performance.md #9) must gather region-query
    /// candidates from every overlapping cell and still apply the exact range check — asserted against
    /// an independently reimplemented brute-force filter over a dataset straddling the (lat 45, lon 9)
    /// cell corner: one point per surrounding cell, a same-cell false positive outside the query range,
    /// and a far-away point in an untouched cell.
    @MainActor
    func testReportingPointsInRegionMatchesBruteForceAcrossGridBoundary() throws {
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","properties":{"_id":"P1"},"geometry":{"type":"Point","coordinates":[8.95,44.95]}},
          {"type":"Feature","properties":{"_id":"P2"},"geometry":{"type":"Point","coordinates":[8.95,45.05]}},
          {"type":"Feature","properties":{"_id":"P3"},"geometry":{"type":"Point","coordinates":[9.05,44.95]}},
          {"type":"Feature","properties":{"_id":"P4"},"geometry":{"type":"Point","coordinates":[9.05,45.05]}},
          {"type":"Feature","properties":{"_id":"P5"},"geometry":{"type":"Point","coordinates":[8.80,44.95]}},
          {"type":"Feature","properties":{"_id":"P6"},"geometry":{"type":"Point","coordinates":[10.0,10.0]}}
        ]}
        """.data(using: .utf8)!
        let all = try ReportingPoint.parse(geoJSON: json)

        let latRange = 44.9...45.1
        let lonRange = 8.9...9.1
        let bruteForce = all.filter { latRange.contains($0.latitude) && lonRange.contains($0.longitude) }

        let service = OpenAIPReportingPointDataService()
        service.seedForTesting(all)
        let gridResult = service.reportingPointsInRegion(latRange: latRange, lonRange: lonRange)

        XCTAssertEqual(Set(gridResult.map(\.id)), Set(bruteForce.map(\.id)))
        XCTAssertEqual(Set(gridResult.map(\.id)), ["P1", "P2", "P3", "P4"])
    }

    /// `reportingPointsNear`'s ring-widening grid walk must find the nearest point even when it sits in
    /// an adjacent grid cell to the query coordinate — a naive "only check the query's own cell"
    /// implementation would miss it and could return the wrong (same-cell but farther) point instead.
    @MainActor
    func testReportingPointsNearFindsNearestAcrossGridBoundary() throws {
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","properties":{"_id":"near","name":"NEAR"},"geometry":{"type":"Point","coordinates":[9.001,45.001]}},
          {"type":"Feature","properties":{"_id":"far","name":"FAR"},"geometry":{"type":"Point","coordinates":[8.5,44.5]}}
        ]}
        """.data(using: .utf8)!
        let all = try ReportingPoint.parse(geoJSON: json)

        let service = OpenAIPReportingPointDataService()
        service.seedForTesting(all)

        // Query coordinate sits just inside cell (44, 8); "near" sits just across the corner in the
        // diagonally adjacent cell (45, 9), about 0.15 NM away. "far" shares the query's own cell but is
        // ~35 NM away.
        let coord = CLLocationCoordinate2D(latitude: 44.999, longitude: 8.999)
        let nearest = service.reportingPointsNear(to: coord, maxDistanceNm: 50, limit: 1)

        XCTAssertEqual(nearest.map(\.id), ["near"])

        // Both must be found (equal to the brute-force filter+sort) when the limit allows it.
        let both = service.reportingPointsNear(to: coord, maxDistanceNm: 50, limit: 2)
        let bruteForce = all
            .compactMap { p -> (ReportingPoint, Double)? in
                let d = p.distanceNM(from: coord)
                return d <= 50 ? (p, d) : nil
            }
            .sorted { ($0.1, $0.0.compulsory ? 0 : 1) < ($1.1, $1.0.compulsory ? 0 : 1) }
            .map { $0.0.id }
        XCTAssertEqual(both.map(\.id), bruteForce)
    }

    // MARK: - Aerodromes and remarks (6.0.1)

    /// Point "E" as `api.core.openaip.net/api/reporting-points?country=CH` returns it (2026-09-29),
    /// and the aerodrome its `airports` names, as `/api/airports` does.
    private let pointE = """
    {"_id":"629cc7abf4b4089a578e3c55","name":"E","compulsory":false,"country":"CH",
     "airports":["6261519e0e8346dfd925198a"],
     "geometry":{"type":"Point","coordinates":[6.975833333333333,47.137166666666666]},
     "elevation":{"value":821,"unit":0,"referenceDatum":1},
     "remarks":"Les Eplatures VRP - E {ELESE}"}
    """
    private let lsgcGeoJSON = """
    {"type":"FeatureCollection","features":[
      {"type":"Feature","properties":{"_id":"6261519e0e8346dfd925198a","name":"LES EPLATURES",
        "icaoCode":"LSGC","type":2,"country":"CH"},
       "geometry":{"type":"Point","coordinates":[6.7928,47.0839]}},
      {"type":"Feature","properties":{"_id":"626151995e9ded5710452eee","name":"COURTELARY",
        "icaoCode":"LSZJ","type":2,"country":"CH"},
       "geometry":{"type":"Point","coordinates":[7.0908,47.1836]}}
    ]}
    """

    private func corePoints(_ items: String...) throws -> [ReportingPoint] {
        let objects = try items.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) }
        return try ReportingPoint.parse(geoJSON: OpenAIPLayerCache<ReportingPoint>.featureCollectionData(fromCoreAPIItems: objects))
    }

    private func point(name: String?, remarks: String?, compulsory: Bool = false,
                       airports: [String] = ["6261519e0e8346dfd925198a"]) throws -> ReportingPoint {
        var properties: [String: Any] = ["_id": UUID().uuidString, "compulsory": compulsory, "airports": airports]
        if let name { properties["name"] = name }
        if let remarks { properties["remarks"] = remarks }
        properties["geometry"] = ["type": "Point", "coordinates": [7.0, 47.0]]
        let data = try OpenAIPLayerCache<ReportingPoint>.featureCollectionData(fromCoreAPIItems: [properties])
        return try XCTUnwrap(ReportingPoint.parse(geoJSON: data).first)
    }

    private let lsgc = ReportingPointAerodrome(icao: "LSGC", name: "LES EPLATURES")
    private var onRequest: String { L10n.Briefing.onRequest }

    func testParseKeepsTheAerodromesAndAnEmptyListWhenThereAreNone() throws {
        let points = try ReportingPoint.parse(geoJSON: sampleGeoJSON)
        XCTAssertEqual(points[0].airports, ["abc"])
        XCTAssertEqual(points[1].airports, [], "parsed from OpenAIP: an empty list, never nil")
        let e = try XCTUnwrap(corePoints(pointE).first)
        XCTAssertEqual(e.airports, ["6261519e0e8346dfd925198a"])
        XCTAssertEqual(e.code, "ELESE")
    }

    func testMalformedAerodromeListDropsTheListNotThePoint() throws {
        let json = """
        {"type":"FeatureCollection","features":[{"type":"Feature",
          "properties":{"_id":"x","name":"E","airports":"oops"},
          "geometry":{"type":"Point","coordinates":[7.0,47.0]}}]}
        """.data(using: .utf8)!
        let parsed = try ReportingPoint.parse(geoJSON: json)
        XCTAssertEqual(parsed.map(\.id), ["x"])
        XCTAssertEqual(parsed.first?.airports, [])
    }

    func testCodeIsTheBracedIdentOnly() {
        XCTAssertEqual(ReportingPointRemarks.code(in: "Les Eplatures VRP - E {ELESE}"), "ELESE")
        XCTAssertEqual(ReportingPointRemarks.code(in: "Lugano VRP - S {SLUGA}"), "SLUGA")
        XCTAssertEqual(ReportingPointRemarks.code(in: "Geneva Helicopter VRP - la Pallanteri {LAPAL}"), "LAPAL")
        XCTAssertNil(ReportingPointRemarks.code(in: "}"), "the French junk remark")
        XCTAssertNil(ReportingPointRemarks.code(in: "{"))
        XCTAssertNil(ReportingPointRemarks.code(in: "MAX 3500"))
        XCTAssertNil(ReportingPointRemarks.code(in: "see {note}"), "lower case is prose, not an ident")
        XCTAssertNil(ReportingPointRemarks.code(in: "{ABCDEFGH}"), "longer than an ident")
        XCTAssertEqual(ReportingPointRemarks.code(in: "{x} then {NELES}"), "NELES")
        XCTAssertNil(ReportingPointRemarks.code(in: nil))
    }

    func testNoteDropsTheIdentAndTheJunk() {
        XCTAssertEqual(ReportingPointRemarks.note(in: "Les Eplatures VRP - E {ELESE}"), "Les Eplatures VRP - E")
        XCTAssertNil(ReportingPointRemarks.note(in: "}"))
        XCTAssertNil(ReportingPointRemarks.note(in: " {ELESE} "))
        XCTAssertNil(ReportingPointRemarks.note(in: nil))
        XCTAssertEqual(ReportingPointRemarks.note(in: "  MAX   3500 "), "MAX 3500")
        XCTAssertEqual(ReportingPointRemarks.note(in: "PIZZOLI\nFROM PES VOR: 262°/39NM"),
                       "PIZZOLI\nFROM PES VOR: 262°/39NM")
    }

    func testNoteKeepsOnlyWhatTheAerodromeLineDoesNotSay() {
        func note(_ text: String, _ aerodrome: String?) -> String? {
            ReportingPointRemarks.informativeNote(text, aerodromeName: aerodrome)
        }
        XCTAssertNil(note("Les Eplatures VRP - E", "LES EPLATURES"))
        XCTAssertNil(note("Geneva VRP - GE", "GENEVA"))
        XCTAssertNil(note("Lugano VRP - S", "LUGANO"))
        XCTAssertNil(note("Bern airport", "BERN-BELP"))
        XCTAssertNil(note("St. Gallen Altenrhein airport", "ST. GALLEN-ALTENRHEIN"))
        XCTAssertNil(note("VPR", "ROMA URBE"))
        XCTAssertEqual(note("Geneva Helicopter VRP - Palexpo", "GENEVA"), "Helicopter VRP - Palexpo")
        XCTAssertEqual(note("MAX 3500", "GRENCHEN"), "MAX 3500")
        XCTAssertEqual(note("Max 3500 EXC HEL", "GRENCHEN"), "Max 3500 EXC HEL")
        XCTAssertEqual(note("UL reporting point", "MEAUX ESBLY"), "UL reporting point")
        XCTAssertEqual(note("Min. 600ft AGL or 350ft AGL if TWR instruction \"LOW ALTITUDE\"", "ZURICH"),
                       "Min. 600ft AGL or 350ft AGL if TWR instruction \"LOW ALTITUDE\"")
        // No aerodrome to name it: the remark is the only place that does, so it stays whole.
        XCTAssertEqual(note("Les Eplatures VRP - E", nil), "Les Eplatures VRP - E")
        XCTAssertEqual(note("Sion airport", nil), "Sion airport")
    }

    func testLabelNamesTheAerodromeOnceAndLeavesTheIdentOut() throws {
        let e = try XCTUnwrap(corePoints(pointE).first)
        let label = ReportingPointLabel(point: e, aerodrome: lsgc)
        XCTAssertEqual(label.title, "E")
        XCTAssertEqual(label.subtitle, "LSGC Les Eplatures · \(onRequest.localizedLowercase)")
        XCTAssertNil(label.note)
        XCTAssertEqual(label.briefingValue, "LSGC · \(onRequest)")
        XCTAssertFalse(label.subtitle.contains("ELESE"))
        XCTAssertFalse(label.subtitle.contains("{"))
    }

    func testLabelKeepsALimitOnItsOwnLine() throws {
        let label = ReportingPointLabel(point: try point(name: "E", remarks: "MAX 3500", compulsory: true),
                                        aerodrome: ReportingPointAerodrome(icao: "LSZG", name: "GRENCHEN"))
        XCTAssertEqual(label.subtitle, "LSZG Grenchen · \(L10n.Briefing.compulsory.localizedLowercase)")
        XCTAssertEqual(label.note, "MAX 3500")
    }

    func testLabelWithoutAnAerodromeFallsBackToTheStatusAndTheRemark() throws {
        let label = ReportingPointLabel(point: try point(name: "E", remarks: "Les Eplatures VRP - E {ELESE}"),
                                        aerodrome: nil)
        XCTAssertEqual(label.subtitle, onRequest)
        XCTAssertEqual(label.note, "Les Eplatures VRP - E", "the ident is gone, the prose stays")
        XCTAssertEqual(label.briefingValue, onRequest)
        let unnamed = ReportingPointLabel(point: try point(name: " ", remarks: "}"), aerodrome: nil)
        XCTAssertEqual(unnamed.title, String(localized: "Reporting point"))
        XCTAssertNil(unnamed.note, "a lone brace is no remark")
    }

    func testAerodromeWithoutICAOCodeIsNamedAlone() {
        let field = ReportingPointAerodrome(icao: nil, name: "BELLECHASSE")
        XCTAssertEqual(field.displayLine, "Bellechasse")
        XCTAssertEqual(ReportingPointAerodrome(icao: "LSZG", name: "Grenchen").displayName, "Grenchen")
    }

    /// The join is offline: OpenAIP's `airports` against the ids of the downloaded airport layer. It
    /// takes the first id it knows, so Geneva's points (LSGG and a French id) still resolve, and it
    /// survives the merge releasing the airport array.
    @MainActor
    func testJoinFindsTheAerodromeByOpenAIPIdAndSurvivesTheRelease() throws {
        let service = OpenAIPAirportDataService()
        service.seedForTesting(try OpenAIPAirport.parse(geoJSON: Data(lsgcGeoJSON.utf8)))
        let e = try XCTUnwrap(corePoints(pointE).first)
        XCTAssertEqual(service.aerodrome(for: e), lsgc)

        let twoIds = try point(name: "N", remarks: nil, airports: ["not-downloaded", "6261519e0e8346dfd925198a"])
        XCTAssertEqual(service.aerodrome(for: twoIds)?.icao, "LSGC")
        // Courtelary is nearer to E than Les Eplatures; the join does not care.
        XCTAssertNotEqual(service.aerodrome(for: e)?.icao, "LSZJ")

        service.releaseLoadedAirports()
        XCTAssertEqual(service.aerodrome(for: e), lsgc, "the index outlives the merged-away array")
        XCTAssertEqual(service.label(for: e).subtitle, "LSGC Les Eplatures · \(onRequest.localizedLowercase)")
    }

    @MainActor
    func testNoAerodromeFallback() throws {
        let service = OpenAIPAirportDataService()
        service.seedForTesting(try OpenAIPAirport.parse(geoJSON: Data(lsgcGeoJSON.utf8)))
        XCTAssertNil(service.aerodrome(for: try point(name: "W", remarks: nil, airports: [])))
        XCTAssertNil(service.aerodrome(for: try point(name: "W", remarks: nil, airports: ["elsewhere"])))
        let old = try JSONDecoder().decode(ReportingPoint.self, from: Data(oldCachedPoint.utf8))
        XCTAssertNil(service.aerodrome(for: old))
        XCTAssertEqual(service.label(for: old).subtitle, onRequest)
    }

    // MARK: - Cache from before 6.0.1

    /// How 6.0 wrote a point to `reportingpoints_CH.json`: no `airports`.
    private let oldCachedPoint = """
    {"id":"629cc7abf4b4089a578e3c55","name":"E","compulsory":false,"elevationFeetMSL":2694,
     "latitude":47.137167,"longitude":6.975833,"remarks":"Les Eplatures VRP - E {ELESE}"}
    """

    func testOldCacheDecodesWithoutAerodromes() throws {
        let old = try JSONDecoder().decode([ReportingPoint].self, from: Data("[\(oldCachedPoint)]".utf8))
        XCTAssertEqual(old.first?.name, "E")
        XCTAssertNil(old.first?.airports)
        XCTAssertEqual(old.first?.code, "ELESE")
    }

    func testMetadataFromBeforeTheFormatVersionDecodesAndOtherLayersWriteTheSameBytes() throws {
        let old = try JSONDecoder().decode(OpenAIPLayerCacheMetadata.self,
                                           from: Data(#"{"lastSyncDates":{},"counts":{"CH":104}}"#.utf8))
        XCTAssertNil(old.formatVersion)
        XCTAssertEqual(old.counts, ["CH": 104])
        let written = String(decoding: try JSONEncoder().encode(OpenAIPLayerCacheMetadata(counts: ["CH": 1])),
                             as: UTF8.self)
        XCTAssertFalse(written.contains("formatVersion"), "a layer without a version keeps its old bytes")
    }

    func testOnlyADownloadedCacheInAnOlderFormatPredatesTheAerodromes() {
        typealias Summary = OpenAIPLayerCache<ReportingPoint>.Summary
        XCTAssertTrue(OpenAIPReportingPointDataService.predatesAerodromes(
            Summary(metadata: OpenAIPLayerCacheMetadata(counts: ["CH": 104]))))
        XCTAssertFalse(OpenAIPReportingPointDataService.predatesAerodromes(
            Summary(metadata: OpenAIPLayerCacheMetadata(counts: ["CH": 104],
                                                        formatVersion: OpenAIPReportingPointDataService.cacheFormat))))
        XCTAssertFalse(OpenAIPReportingPointDataService.predatesAerodromes(
            Summary(metadata: OpenAIPLayerCacheMetadata())), "nothing downloaded: nothing to refresh")
    }

    /// An old cache is refreshed by the foreground refresh whatever its date, without being called
    /// stale: the Home dot stays green over a missing aerodrome label.
    @MainActor
    func testTheDataHubRefreshesAnOldCacheWithoutCallingItStale() async throws {
        let service = OpenAIPReportingPointDataService()
        service.seedForTesting(try ReportingPoint.parse(geoJSON: sampleGeoJSON), cachePredatesAerodromes: true)
        service.lastUpdated = Date()
        let provider = OpenAIPReportingPointProvider(service: service)
        let set = provider.makeDataSet(now: Date())
        XCTAssertTrue(set.formatOutdated)
        XCTAssertEqual(set.freshness, .fresh)
        XCTAssertEqual(DataHealth.contribution(of: set), .ok)
        XCTAssertTrue(service.needsUpdate)

        var refreshed = 0
        let manager = DataStatusManager(providers: [CountingProvider(dataSet: set) { refreshed += 1 }],
                                        networkMonitor: NetworkMonitor(stub: NetworkConditions(isConnected: true, isWiFi: true, isExpensive: false, isConstrained: false)),
                                        userDefaults: makeTestDefaults())
        await manager.autoRefreshIfNeeded(cellularUpdatesEnabled: false)
        XCTAssertEqual(refreshed, 1, "fetched once more, like stale data")

        service.seedForTesting(try ReportingPoint.parse(geoJSON: sampleGeoJSON), cachePredatesAerodromes: false)
        XCTAssertFalse(provider.makeDataSet(now: Date()).formatOutdated)
    }

    /// A provider that reports a fixed data set and counts refreshes.
    @MainActor
    private struct CountingProvider: DataSetProvider {
        let dataSet: DataSet
        let onRefresh: () -> Void
        var id: String { dataSet.id }
        func makeDataSet(now: Date) -> DataSet { dataSet }
        func refresh() async { onRefresh() }
        func delete() {}
    }

    /// The route prefetch passes `skippingCached`: it must not keep an old-format country behind a
    /// fresh date. It fetches it again, marks the cache current, and reuses it from then on.
    @MainActor
    func testSkippingCachedStillFetchesACacheInAnOlderFormatOnce() async throws {
        var fetched: [String] = []
        let pointJSON = pointE
        let directory = "ReportingPointTests-\(UUID().uuidString)"
        let cache = OpenAIPLayerCache<ReportingPoint>(
            directoryName: directory, filePrefix: "reportingpoints", endpointSuffix: "rpp",
            restPath: "reporting-points", logLabel: "test",
            formatVersion: OpenAIPReportingPointDataService.cacheFormat,
            parse: ReportingPoint.parse(geoJSON:),
            fetch: { country in
                fetched.append(country)
                let object = try JSONSerialization.jsonObject(with: Data(pointJSON.utf8))
                return try ReportingPoint.parse(geoJSON: OpenAIPLayerCache<ReportingPoint>.featureCollectionData(fromCoreAPIItems: [object]))
            })
        defer { cache.deleteData() }

        // A 6.0 cache on disk: the points without `airports`, metadata without a format.
        let base = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent(directory, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("[\(oldCachedPoint)]".utf8).write(to: base.appendingPathComponent("reportingpoints_CH.json"))
        try JSONEncoder().encode(OpenAIPLayerCacheMetadata(lastSyncDates: ["CH": Date()], counts: ["CH": 1]))
            .write(to: base.appendingPathComponent("metadata.json"))
        XCTAssertTrue(OpenAIPReportingPointDataService.predatesAerodromes(try XCTUnwrap(cache.restoredSummary())))

        let first = await cache.downloadData(for: ["CH"], skippingCached: true) { _ in }
        XCTAssertEqual(fetched, ["CH"], "an old-format country is fetched even when skipping the cache")
        XCTAssertEqual(first.features.first?.airports, ["6261519e0e8346dfd925198a"])
        XCTAssertFalse(OpenAIPReportingPointDataService.predatesAerodromes(first.summary))

        let second = await cache.downloadData(for: ["CH"], skippingCached: true) { _ in }
        XCTAssertEqual(fetched, ["CH"], "a current cache is reused")
        XCTAssertEqual(second.features.first?.airports, ["6261519e0e8346dfd925198a"])
    }

    /// Offline, the old file stays (the maps keep working with the old labels) and so does the flag,
    /// so the next foreground tries again.
    @MainActor
    func testAFailedRefreshKeepsTheOldCacheAndTheFlag() async throws {
        struct Offline: Error {}
        let directory = "ReportingPointTests-\(UUID().uuidString)"
        let cache = OpenAIPLayerCache<ReportingPoint>(
            directoryName: directory, filePrefix: "reportingpoints", endpointSuffix: "rpp",
            restPath: "reporting-points", logLabel: "test",
            formatVersion: OpenAIPReportingPointDataService.cacheFormat,
            parse: ReportingPoint.parse(geoJSON:),
            fetch: { _ in throw Offline() })
        defer { cache.deleteData() }
        let base = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent(directory, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("[\(oldCachedPoint)]".utf8).write(to: base.appendingPathComponent("reportingpoints_CH.json"))
        try JSONEncoder().encode(OpenAIPLayerCacheMetadata(lastSyncDates: ["CH": Date()], counts: ["CH": 1]))
            .write(to: base.appendingPathComponent("metadata.json"))

        let result = await cache.downloadData(for: ["CH"]) { _ in }
        XCTAssertEqual(result.failedCountries, ["CH"])
        XCTAssertEqual(result.features.map(\.name), ["E"], "the old points are kept")
        XCTAssertTrue(OpenAIPReportingPointDataService.predatesAerodromes(result.summary))
    }

    // MARK: - open flightmaps points (6.2.0)

    /// OpenAIP's Swiss reporting points as its export had them on 2026-10-02 (a cut): the ones the
    /// open flightmaps fixture below meets, by the investigation's rule.
    private let openAIPSwissGeoJSON = """
    {"type":"FeatureCollection","features":[
      {"type":"Feature","properties":{"_id":"629ccdb6f4b4089a578e6a53","name":"YVONAND","compulsory":true,"airports":[]},
       "geometry":{"type":"Point","coordinates":[6.75,46.79417]}},
      {"type":"Feature","properties":{"_id":"629ccdb7f4b4089a578e6a5c","name":"LUCENCS","compulsory":true,"airports":[]},
       "geometry":{"type":"Point","coordinates":[6.81611,46.71556]}},
      {"type":"Feature","properties":{"_id":"629ccdbff4b4089a578e6a9b","name":"MURTEN","compulsory":false,"airports":[],
       "remarks":"Payerne airport"},"geometry":{"type":"Point","coordinates":[7.14528,46.92111]}},
      {"type":"Feature","properties":{"_id":"63cd2474e19a94c9b6c5d4c5","name":"S","compulsory":false,"airports":[],
       "remarks":"MAX 4000"},"geometry":{"type":"Point","coordinates":[8.52,47.36]}},
      {"type":"Feature","properties":{"_id":"63cd2528e19a94c9b6c5d52e","name":"E1","compulsory":false,"airports":[],
       "remarks":"MAX 3000"},"geometry":{"type":"Point","coordinates":[8.7,47.52]}},
      {"type":"Feature","properties":{"_id":"629ccdd0ac58872690a8a91d","name":"V","compulsory":false,"airports":[]},
       "geometry":{"type":"Point","coordinates":[9.4,47.54722]}},
      {"type":"Feature","properties":{"_id":"629cc7c1f4b4089a578e3d09","name":"SLUGA","compulsory":false,"airports":[],
       "remarks":"Lugano VRP - S {SLUGA}"},"geometry":{"type":"Point","coordinates":[8.90467,45.9025]}},
      {"type":"Feature","properties":{"_id":"629cc7bbf4b4089a578e3ce0","name":"HS","compulsory":false,"airports":[]},
       "geometry":{"type":"Point","coordinates":[7.317,46.21117]}},
      {"type":"Feature","properties":{"_id":"629cc7abf4b4089a578e3c55","name":"E","compulsory":false,
       "airports":["6261519e0e8346dfd925198a"],"remarks":"Les Eplatures VRP - E {ELESE}"},
       "geometry":{"type":"Point","coordinates":[6.97583,47.13717]}}
    ]}
    """

    /// OpenAIP's airports for those points' fields (2026-10-02). LSHZ is left out on purpose.
    private let openAIPSwissAirportsGeoJSON = """
    {"type":"FeatureCollection","features":[
      {"type":"Feature","properties":{"_id":"626151995e9ded5710452e8d","name":"BIRRFELD","icaoCode":"LSZF","type":2,"country":"CH"},
       "geometry":{"type":"Point","coordinates":[8.23398,47.44368]}},
      {"type":"Feature","properties":{"_id":"626151a20e8346dfd9251a99","name":"SPECK-FEHRALTORF","icaoCode":"LSZK","type":2,"country":"CH"},
       "geometry":{"type":"Point","coordinates":[8.7575,47.3764]}},
      {"type":"Feature","properties":{"_id":"626151a25e9ded5710453204","name":"SION","icaoCode":"LSGS","type":0,"country":"CH"},
       "geometry":{"type":"Point","coordinates":[7.32694,46.21917]}},
      {"type":"Feature","properties":{"_id":"6261519e0e8346dfd925198a","name":"LES EPLATURES","icaoCode":"LSGC","type":2,"country":"CH"},
       "geometry":{"type":"Point","coordinates":[6.79361,47.08417]}}
    ]}
    """

    /// open flightmaps' Swiss points of AIRAC 2610 (© open flightmaps association), cut, with the ids
    /// and positions the published file has. Real OFM-only points: LUCENS (OpenAIP's "LUCENCS", 0.53 NM
    /// away, is another name), ABM ALTREU, LSZF's ECHO and END N, LSZK's ECHO, LSGS's S (0.58 NM from
    /// OpenAIP's "HS"), and the helicopter points HZ704 (LSHZ) and HE (LSZG).
    ///
    /// The others are the cases the device must catch itself, as it would with an older file or a
    /// newer OpenAIP: they are marked not in OpenAIP here although the extractor marks them in it.
    /// YVONAND (0.64 NM) and MURTEN (0.55 NM) are the same names at disputed positions; LSZH's SIERRA
    /// is OpenAIP's "S" 0.27 NM away; LSZH's E1 is named "ECHO1" the way OFM names Bern's; LSZR's V is
    /// a short name 0.75 NM from OpenAIP's. Synthetic: Lugano's S moved 0.3 NM from OpenAIP's "SLUGA",
    /// "HOTEL SIERRA" 0.05 NM from OpenAIP's "HS", and a "V" 1.5 NM from LSZR's, which is another point.
    /// CHABREY is marked in OpenAIP, as published, and never joins.
    private let ofmSwissPoints = Data("""
    { "v": 1, "source": "open flightmaps", "region": "LSAS", "country": "CH",
      "airac": "2610", "validFrom": "2026-10-01", "validTo": "2026-10-29",
      "procedures": [],
      "points": [
        {"id": "bae55362-a4d5-14f8-19a4-a435038b8ea5", "name": "LUCENS", "kind": "mrp", "lat": 46.70696, "lon": 6.81904, "inOpenAIP": false},
        {"id": "3d5dea93-3e2e-ea94-f307-7bef664e17be", "name": "ABM ALTREU", "kind": "mrp", "lat": 47.1875, "lon": 7.4486, "inOpenAIP": false},
        {"id": "d0bbffb7-5b84-4608-311f-0f10d5b7fc2a", "name": "ECHO", "kind": "mrp", "ad": "LSZF", "lat": 47.41608, "lon": 8.29611, "inOpenAIP": false},
        {"id": "48ccfb61-9b59-78b5-e088-b8c0ba8d066d", "name": "END N", "kind": "enr", "ad": "LSZF", "lat": 47.48528, "lon": 8.23556, "inOpenAIP": false},
        {"id": "f0ab4c90-4e26-aac6-a951-dadedd789924", "name": "ECHO", "kind": "rp", "ad": "LSZK", "lat": 47.37972, "lon": 8.79222, "inOpenAIP": false},
        {"id": "0e240688-94ed-b81d-cb06-9977f09ae188", "name": "S", "kind": "rp", "ad": "LSGS", "lat": 46.205, "lon": 7.30611, "inOpenAIP": false},
        {"id": "3dc0a67b-c64d-d620-c3e0-a4c65fc8a8c0", "name": "HZ704", "kind": "heli", "ad": "LSHZ", "lat": 47.34528, "lon": 8.55778, "inOpenAIP": false},
        {"id": "831a6cca-6300-1ddb-8255-9133d102d287", "name": "HE", "kind": "heli", "ad": "LSZG", "lat": 47.2096, "lon": 7.48064, "inOpenAIP": false},
        {"id": "91de2ee4-4dc0-80d6-a512-1650d3e457c1", "name": "YVONAND", "kind": "mrp", "lat": 46.78702, "lon": 6.76151, "inOpenAIP": false},
        {"id": "d9ba5787-c040-996c-7acf-a7303dbf53df", "name": "MURTEN", "kind": "rp", "lat": 46.91191, "lon": 7.1446, "inOpenAIP": false},
        {"id": "14d03a5d-7203-5363-9ec2-9687666be0ca", "name": "SIERRA", "kind": "mrp", "ad": "LSZH", "lat": 47.35611, "lon": 8.52333, "inOpenAIP": false},
        {"id": "3b7745d4-d00e-c40d-5910-b67cfffd6a08", "name": "ECHO1", "kind": "rp", "ad": "LSZH", "lat": 47.52417, "lon": 8.70167, "inOpenAIP": false},
        {"id": "6b9d1f55-a68f-657f-d38d-46140ea55a86", "name": "V", "kind": "mrp", "ad": "LSZR", "lat": 47.55917, "lon": 9.39472, "inOpenAIP": false},
        {"id": "synthetic-lugano-s", "name": "S", "kind": "mrp", "lat": 45.9075, "lon": 8.90472, "inOpenAIP": false},
        {"id": "synthetic-hotel-sierra", "name": "HOTEL SIERRA", "kind": "rp", "lat": 46.212, "lon": 7.317, "inOpenAIP": false},
        {"id": "synthetic-v-far", "name": "V", "kind": "rp", "lat": 47.57222, "lon": 9.4, "inOpenAIP": false},
        {"id": "9861b91d-aef5-0a47-aa21-ecaca301a8be", "name": "CHABREY", "kind": "rp", "lat": 46.93028, "lon": 6.99917, "inOpenAIP": true}
      ] }
    """.utf8)

    /// The points that join from that fixture, by name and aerodrome.
    private let ofmOnlyFixed = ["LUCENS", "ABM ALTREU", "ECHO LSZF", "END N LSZF", "ECHO LSZK", "S LSGS", "V"]
    private let ofmOnlyNonPowered = ["HZ704 LSHZ", "HE LSZG"]

    private func tag(_ point: ReportingPoint) -> String {
        [point.name, point.aerodromeICAO].compactMap { $0 }.joined(separator: " ")
    }

    /// A catalog over test sources: OpenAIP's points (for `openAIPCountries`) and airports seeded in
    /// memory, open flightmaps' file downloaded from a fake aerocheck.app into a temporary directory
    /// and loaded.
    @MainActor
    private func makeCatalog(openAIPCountries: [String] = ["CH"], withAirports: Bool = true,
                             loadOFM: Bool = true) async throws -> (ReportingPointCatalog, OFMDataService) {
        let openAIP = OpenAIPReportingPointDataService()
        openAIP.seedForTesting(try ReportingPoint.parse(geoJSON: Data(openAIPSwissGeoJSON.utf8)),
                               downloadedCountries: openAIPCountries)
        let airports = OpenAIPAirportDataService()
        if withAirports {
            airports.seedForTesting(try OpenAIPAirport.parse(geoJSON: Data(openAIPSwissAirportsGeoJSON.utf8)))
        }
        let server = VFRDataTests.FakeVFRServer()
        server.publish(["CH": ofmSwissPoints])
        let ofm = makeTestOFMService { url in try server.fetch(url) }
        await ofm.downloadData(for: ["CH"])
        XCTAssertEqual(ofm.downloadedCountries, ["CH"])
        if loadOFM { await ofm.ensureLoaded() }
        return (ReportingPointCatalog(openAIP: openAIP, ofm: ofm, aerodromes: airports), ofm)
    }

    func testTheMatchingRuleReducesNamesLikeTheExtractor() {
        XCTAssertEqual(ReportingPointMatch.canonicalName("SIERRA"), "S")
        XCTAssertEqual(ReportingPointMatch.canonicalName("ECHO1"), "E1")
        XCTAssertEqual(ReportingPointMatch.canonicalName("Echo 2"), "E2")
        XCTAssertEqual(ReportingPointMatch.canonicalName("FOXTROTT"), "F")
        XCTAssertEqual(ReportingPointMatch.canonicalName("ECHOES"), "ECHOES", "a word that only starts like one")
        XCTAssertEqual(ReportingPointMatch.canonicalName("ABM AVENCHES"), "AVENCHES")
        XCTAssertEqual(ReportingPointMatch.canonicalName("INTERLAKEN SÜD"), "INTERLAKENSUED")
        XCTAssertEqual(ReportingPointMatch.canonicalName("Châtel-St-Denis"), "CHATELSTDENIS")
        XCTAssertTrue(ReportingPointMatch.isSameName(ofm: "SIERRA", openAIP: "S"))
        XCTAssertTrue(ReportingPointMatch.isSameName(ofm: "ECHO1", openAIP: "E1"))
        XCTAssertTrue(ReportingPointMatch.isSameName(ofm: "PALEX", openAIP: "PALEXPO"), "a 4+ letter start")
        XCTAssertTrue(ReportingPointMatch.isSameName(ofm: "GE", openAIP: "GEGEN"), "OpenAIP's 5-letter code")
        XCTAssertTrue(ReportingPointMatch.isSameName(ofm: "S", openAIP: "SLUGA"))
        XCTAssertFalse(ReportingPointMatch.isSameName(ofm: "S", openAIP: "HS"))
        XCTAssertFalse(ReportingPointMatch.isSameName(ofm: "LUCENS", openAIP: "LUCENCS"), "OpenAIP's typo is another name")
        XCTAssertFalse(ReportingPointMatch.isSameName(ofm: "", openAIP: ""))
        XCTAssertEqual(ReportingPointMatch.distanceNM(46.78702, 6.76151, 46.79417, 6.75), 0.64, accuracy: 0.01)
    }

    /// The investigation's cases: what OpenAIP has (same point, a phonetic name, a 5-letter code, a
    /// disputed position) shows once, as OpenAIP's; what it lacks joins.
    @MainActor
    func testTheDeviceKeepsOnlyThePointsOpenAIPLacks() async throws {
        let (catalog, _) = try await makeCatalog()
        let all = catalog.allPoints(includingNonPowered: false)
        let ofm = all.filter { $0.source == .openFlightmaps }
        XCTAssertEqual(Set(ofm.map(tag)), Set(ofmOnlyFixed))
        XCTAssertEqual(all.filter { $0.source == .openAIP }.count, 9, "every OpenAIP point stays")
        // Once each, as OpenAIP's.
        for name in ["YVONAND", "MURTEN"] {
            XCTAssertEqual(all.filter { $0.name == name }.map(\.source), [.openAIP], "\(name): disputed position, OpenAIP wins")
        }
        XCTAssertFalse(ofm.contains { $0.name == "SIERRA" }, "LSZH's SIERRA is OpenAIP's S")
        XCTAssertFalse(ofm.contains { $0.name == "ECHO1" }, "ECHO1 is OpenAIP's E1")
        XCTAssertFalse(ofm.contains { $0.id == "ofm:6b9d1f55-a68f-657f-d38d-46140ea55a86" }, "LSZR's V, 0.75 NM: disputed")
        XCTAssertTrue(ofm.contains { $0.id == "ofm:synthetic-v-far" }, "a short name 1.5 NM away is another point")
        XCTAssertFalse(ofm.contains { $0.id == "ofm:synthetic-lugano-s" }, "S is OpenAIP's SLUGA")
        XCTAssertFalse(ofm.contains { $0.name == "HOTEL SIERRA" }, "0.05 NM: the same point whatever its name")
        XCTAssertFalse(all.contains { $0.name == "CHABREY" }, "marked in OpenAIP by the extractor")
        // What joins says where it comes from.
        let lucens = try XCTUnwrap(ofm.first { $0.name == "LUCENS" })
        XCTAssertEqual(lucens.id, "ofm:bae55362-a4d5-14f8-19a4-a435038b8ea5")
        XCTAssertTrue(lucens.compulsory, "an MRP is compulsory")
        XCTAssertEqual(lucens.airac, "2610")
        XCTAssertFalse(try XCTUnwrap(ofm.first { tag($0) == "ECHO LSZK" }).compulsory, "an RP is on request")
    }

    @MainActor
    func testOFMPointsJoinOnlyWhereOpenAIPPointsAreOnTheDevice() async throws {
        let (catalog, _) = try await makeCatalog(openAIPCountries: ["DE"])
        XCTAssertTrue(catalog.allPoints(includingNonPowered: true).allSatisfy { $0.source == .openAIP },
                      "without OpenAIP's Swiss points the check means nothing")
        XCTAssertNotNil(catalog.point(withId: "ofm:bae55362-a4d5-14f8-19a4-a435038b8ea5"), "a saved id still resolves")
    }

    @MainActor
    func testHelicopterAndGliderPointsNeedTheSwitch() async throws {
        XCTAssertFalse(AppSettings().showsNonPoweredReportingPoints, "off until the map's switch is on")
        var withSwitch = AppSettings()
        withSwitch.showNonPoweredCircuitsOnMap = true
        XCTAssertTrue(withSwitch.showsNonPoweredReportingPoints, "the \"Glider, UL & helicopter\" switch brings them")
        let (catalog, _) = try await makeCatalog()
        XCTAssertTrue(Set(ofmOnlyNonPowered).isDisjoint(with: catalog.allPoints(includingNonPowered: false).map(tag)))
        XCTAssertTrue(Set(ofmOnlyNonPowered).isSubset(of: catalog.allPoints(includingNonPowered: true).map(tag)))
        let lshz = CLLocationCoordinate2D(latitude: 47.37694, longitude: 8.55111)
        XCTAssertFalse(catalog.pointsNear(to: lshz, maxDistanceNm: 3, limit: 6, includingNonPowered: false)
            .contains { $0.name == "HZ704" })
        XCTAssertTrue(catalog.pointsNear(to: lshz, maxDistanceNm: 3, limit: 6, includingNonPowered: true)
            .contains { $0.name == "HZ704" })
        XCTAssertEqual(catalog.label(for: try XCTUnwrap(catalog.point(withId: "ofm:3dc0a67b-c64d-d620-c3e0-a4c65fc8a8c0"))).note,
                       L10n.Nav.helicopterReportingPoint)
        let glider = ReportingPointCatalog.Entry(point: ReportingPoint(id: "g", name: "G", compulsory: false,
                                                                       latitude: 47, longitude: 8), kind: .glider)
        XCTAssertTrue(glider.isNonPowered)
    }

    /// One place, one point: open flightmaps had Sion's S (RP) and SIERRA (MRP) at the same position.
    func testTwoOFMPointsAtOnePlaceShowOnceTheCompulsoryOne() throws {
        let file = try JSONDecoder().decode(OFMRegionFile.self, from: Data("""
        { "v": 1, "country": "CH", "airac": "2610", "validFrom": "2026-10-01", "validTo": "2026-10-29",
          "points": [
            {"id": "s", "name": "S", "kind": "rp", "ad": "LSGS", "lat": 46.205, "lon": 7.30611, "inOpenAIP": false},
            {"id": "sierra", "name": "SIERRA", "kind": "mrp", "ad": "LSGS", "lat": 46.205, "lon": 7.30611, "inOpenAIP": false},
            {"id": "n", "name": "N", "kind": "rp", "lat": 46.23944, "lon": 7.35639, "inOpenAIP": false}
          ] }
        """.utf8))
        let sets = [OFMDataService.PointSet(country: "CH", airac: file.airac, points: file.points),
                    OFMDataService.PointSet(country: "CH", airac: file.airac, points: file.points)]
        let entries = ReportingPointCatalog.pointsOpenAIPLacks(sets, openAIP: [], openAIPCountries: ["CH"])
        XCTAssertEqual(entries.map(\.point.id), ["ofm:sierra", "ofm:n"])
        XCTAssertTrue(ReportingPointCatalog.pointsOpenAIPLacks(sets, openAIP: [], openAIPCountries: []).isEmpty)
    }

    /// A route saved by any build keeps resolving: OpenAIP's `_id`s as before, `ofm:` ids whatever the
    /// switch or the merge decides today.
    @MainActor
    func testSavedOpenAIPAndOFMIdsResolve() async throws {
        let (catalog, _) = try await makeCatalog()
        let yvonand = try XCTUnwrap(catalog.point(withId: "629ccdb6f4b4089a578e6a53"))
        XCTAssertEqual(yvonand.name, "YVONAND")
        XCTAssertEqual(yvonand.source, .openAIP)
        XCTAssertEqual(catalog.aerodrome(forSourceId: "629cc7abf4b4089a578e3c55")?.icao, "LSGC")
        let lucens = try XCTUnwrap(catalog.point(withId: "ofm:bae55362-a4d5-14f8-19a4-a435038b8ea5"))
        XCTAssertEqual(lucens.name, "LUCENS")
        XCTAssertEqual(lucens.source, .openFlightmaps)
        XCTAssertEqual(catalog.point(withId: "ofm:3dc0a67b-c64d-d620-c3e0-a4c65fc8a8c0")?.name, "HZ704",
                       "behind the switch, still resolved")
        XCTAssertEqual(catalog.point(withId: "ofm:91de2ee4-4dc0-80d6-a512-1650d3e457c1")?.name, "YVONAND",
                       "OpenAIP's now, still resolved")
        XCTAssertEqual(catalog.aerodrome(forSourceId: "ofm:d0bbffb7-5b84-4608-311f-0f10d5b7fc2a")?.icao, "LSZF")
        XCTAssertNil(catalog.point(withId: "ofm:nothing"))
        XCTAssertNil(catalog.point(withId: "nothing"))
        XCTAssertNil(catalog.point(withId: "bae55362-a4d5-14f8-19a4-a435038b8ea5"), "an OFM id is only found namespaced")
    }

    /// An OpenAIP cache from before 6.2.0 reads as OpenAIP's; an OFM point keeps what it says.
    func testTheCacheFormatTakesTheNewFieldsTolerantly() throws {
        let old = try JSONDecoder().decode(ReportingPoint.self, from: Data(oldCachedPoint.utf8))
        XCTAssertEqual(old.source, .openAIP)
        XCTAssertNil(old.aerodromeICAO)
        XCTAssertNil(old.airac)
        let unknown = try JSONDecoder().decode(ReportingPoint.self, from: Data("""
        {"id":"x","name":"E","compulsory":false,"latitude":47.1,"longitude":6.9,"source":"elsewhere","aerodromeICAO":7}
        """.utf8))
        XCTAssertEqual(unknown.source, .openAIP, "an unknown source is no lost point")
        XCTAssertNil(unknown.aerodromeICAO)
        let ofm = ReportingPoint(id: "ofm:x", name: "S", compulsory: false, latitude: 46.205, longitude: 7.30611,
                                 source: .openFlightmaps, aerodromeICAO: "LSGS", airac: "2610")
        XCTAssertEqual(try JSONDecoder().decode(ReportingPoint.self, from: JSONEncoder().encode(ofm)), ofm)
        XCTAssertEqual(ReportingPointCatalog.icaoCode("lsgs"), "LSGS")
        XCTAssertNil(ReportingPointCatalog.icaoCode("EDAGA"), "OFM's code for a field without an ICAO code")
        XCTAssertNil(ReportingPointCatalog.icaoCode("LS1"))
    }

    /// "S (LSGS)": the aerodrome by its ICAO code where OpenAIP's id join has nothing, named from
    /// OpenAIP's airport layer when it has the field, by the code alone otherwise.
    @MainActor
    func testAnOFMPointIsNamedWithItsAerodromesICAOCode() async throws {
        let (catalog, _) = try await makeCatalog()
        let s = try XCTUnwrap(catalog.point(withId: "ofm:0e240688-94ed-b81d-cb06-9977f09ae188"))
        let label = catalog.label(for: s)
        XCTAssertEqual(label.aerodrome?.icao, "LSGS")
        XCTAssertEqual(label.subtitle, "LSGS Sion · \(onRequest.localizedLowercase)")
        let waypoint = RoutePoint.reportingPoint(s, label).waypoint(asEndpoint: false)
        XCTAssertEqual(waypoint.pointKind, .vrp)
        XCTAssertEqual(waypoint.sourceId, "ofm:0e240688-94ed-b81d-cb06-9977f09ae188")
        XCTAssertEqual(waypoint.aerodromeICAO, "LSGS")
        XCTAssertNil(waypoint.code)
        XCTAssertEqual(waypoint.routeName(.full), "S (LSGS)")
        XCTAssertEqual(waypoint.routeName(.compact), "S")
        // LSHZ isn't in OpenAIP's airports here: the code alone.
        let hz = catalog.label(for: try XCTUnwrap(catalog.point(withId: "ofm:3dc0a67b-c64d-d620-c3e0-a4c65fc8a8c0")))
        XCTAssertEqual(hz.aerodrome?.displayLine, "LSHZ")
        XCTAssertEqual(hz.subtitle, "LSHZ · \(onRequest.localizedLowercase)")

        let (bare, _) = try await makeCatalog(withAirports: false)
        let bareLabel = bare.label(for: s)
        XCTAssertEqual(bareLabel.subtitle, "LSGS · \(onRequest.localizedLowercase)")
        XCTAssertEqual(ReportingPointLabel.routeName("S", aerodromeICAO: bareLabel.aerodrome?.icao, form: .full), "S (LSGS)")
    }

    @MainActor
    func testTheCalloutAndTheBriefingSayWhereAnOFMPointComesFrom() async throws {
        let (catalog, _) = try await makeCatalog()
        let echo = catalog.label(for: try XCTUnwrap(catalog.point(withId: "ofm:f0ab4c90-4e26-aac6-a951-dadedd789924")))
        XCTAssertEqual(echo.source, "open flightmaps · AIRAC 2610")
        let text = try XCTUnwrap(ReportingPointAnnotation.calloutDetailText(echo)?.string)
        XCTAssertEqual(text, "LSZK Speck-Fehraltorf · \(onRequest.localizedLowercase)\nopen flightmaps · AIRAC 2610")
        let openAIPPoint = catalog.label(for: try XCTUnwrap(catalog.point(withId: "629ccdb6f4b4089a578e6a53")))
        XCTAssertNil(openAIPPoint.source)
        XCTAssertNil(ReportingPointAnnotation.calloutDetailText(openAIPPoint), "an OpenAIP point without a note: no detail")
        // A helicopter point: what it is for, then where it comes from.
        let he = catalog.label(for: try XCTUnwrap(catalog.point(withId: "ofm:831a6cca-6300-1ddb-8255-9133d102d287")))
        XCTAssertEqual(ReportingPointAnnotation.calloutDetailText(he)?.string,
                       "LSZG · \(onRequest.localizedLowercase)\n\(L10n.Nav.helicopterReportingPoint)\nopen flightmaps · AIRAC 2610")
    }

    /// The briefing's six nearest within 8 NM take both sources. Around LSZQ and LSGC open flightmaps
    /// has no point OpenAIP lacks in AIRAC 2610 (the nearest, ABM ALTREU, is 21 NM from LSZQ); around
    /// LSZF it has three.
    @MainActor
    func testTheBriefingListsTheOFMPointsAroundAField() async throws {
        let (catalog, _) = try await makeCatalog()
        let lszf = CLLocationCoordinate2D(latitude: 47.44368, longitude: 8.23398)
        let around = BriefingContextBuilder.reportingPoints(around: lszf, catalog: catalog, includingNonPowered: false)
        XCTAssertEqual(around.map(tag), ["END N LSZF", "ECHO LSZF"], "nearest first")
        for field in [CLLocationCoordinate2D(latitude: 47.39238, longitude: 7.02886),     // LSZQ
                      CLLocationCoordinate2D(latitude: 47.08417, longitude: 6.79361)] {    // LSGC
            XCTAssertTrue(BriefingContextBuilder.reportingPoints(around: field, catalog: catalog, includingNonPowered: true)
                .allSatisfy { $0.source == .openAIP })
        }
        let lugano = CLLocationCoordinate2D(latitude: 45.9025, longitude: 8.90467)
        XCTAssertEqual(BriefingContextBuilder.reportingPoints(around: lugano, catalog: catalog, includingNonPowered: false)
            .map(\.name), ["SLUGA"], "Lugano's S once, as OpenAIP's")
        XCTAssertTrue(BriefingContextBuilder.reportingPoints(around: nil, catalog: catalog, includingNonPowered: false).isEmpty)
    }

    @MainActor
    func testTheViaSearchFindsAnOFMPoint() async throws {
        let (catalog, _) = try await makeCatalog()
        func search(_ query: String) -> [RoutePointSearch.Result] {
            RoutePointSearch.search(query, reportingPoints: catalog.allPoints(includingNonPowered: false),
                                    aerodrome: { catalog.aerodrome(for: $0) }, navaids: [], route: [])
        }
        let echo = try XCTUnwrap(search("LSZK ECHO").first)
        XCTAssertEqual(echo.id, "rp:ofm:f0ab4c90-4e26-aac6-a951-dadedd789924")
        XCTAssertEqual(echo.title, "ECHO")
        XCTAssertEqual(echo.subtitle, "LSZK Speck-Fehraltorf · open flightmaps")
        XCTAssertEqual(echo.kind, .reportingPoint(compulsory: false))
        XCTAssertEqual(search("lucens").map(\.id), ["rp:ofm:bae55362-a4d5-14f8-19a4-a435038b8ea5"])
        XCTAssertEqual(search("ABM ALTREU").first?.subtitle, "open flightmaps", "no aerodrome: the source alone")
        XCTAssertEqual(Set(search("birrfeld").map(\.title)), ["ECHO", "END N"], "by the aerodrome's name")
        XCTAssertTrue(search("HZ704").isEmpty, "a helicopter point needs the switch")
        // The search by OpenAIP ids finds the field by its code among the same aerodromes.
        let byId = RoutePointSearch.search("LSZK ECHO", reportingPoints: catalog.allPoints(includingNonPowered: false),
                                           aerodromes: [:], navaids: [], route: [])
        XCTAssertEqual(byId.first?.subtitle, "LSZK · open flightmaps")
        // Picking it makes the waypoint.
        guard case let .reportingPoint(point, label) = echo.point else { return XCTFail("not a reporting point") }
        XCTAssertEqual(RoutePoint.reportingPoint(point, label).waypoint(asEndpoint: false).aerodromeICAO, "LSZK")
    }

    @MainActor
    func testAPointDroppedNearAnOFMPointSnapsToIt() async throws {
        let (catalog, _) = try await makeCatalog()
        let dropped = CLLocationCoordinate2D(latitude: 47.1925, longitude: 7.4486)   // 0.3 NM north of ABM ALTREU
        let candidate = try XCTUnwrap(catalog.pointsNear(to: dropped, maxDistanceNm: 1.2, limit: 1, includingNonPowered: false).first)
        XCTAssertEqual(candidate.name, "ABM ALTREU")
        let target = RoutePoint.snapTarget(near: dropped, aerodrome: nil, navaid: nil,
                                           reportingPoint: (candidate, catalog.label(for: candidate)))
        XCTAssertEqual(target?.sourceId, "ofm:3d5dea93-3e2e-ea94-f307-7bef664e17be")
        XCTAssertEqual(target?.kind, .vrp)
        // HE (LSZG) is a helicopter point: no snap without the switch.
        let nearHE = CLLocationCoordinate2D(latitude: 47.2096, longitude: 7.4830)
        XCTAssertTrue(catalog.pointsNear(to: nearHE, maxDistanceNm: 0.5, limit: 1, includingNonPowered: false).isEmpty)
        XCTAssertEqual(catalog.pointsNear(to: nearHE, maxDistanceNm: 0.5, limit: 1, includingNonPowered: true).first?.name, "HE")
    }

    /// The map's region query: OpenAIP's first, then the open flightmaps points, within the cap.
    @MainActor
    func testTheRegionQueryAddsTheOFMPointsWithinTheCap() async throws {
        let (catalog, _) = try await makeCatalog()
        let points = catalog.points(latRange: 46.6...46.95, lonRange: 6.7...7.2, includingNonPowered: false)
        XCTAssertEqual(Set(points.map(\.name)), ["YVONAND", "LUCENCS", "MURTEN", "LUCENS"])
        XCTAssertEqual(points.last?.source, .openFlightmaps)
        XCTAssertEqual(catalog.points(latRange: 46.6...46.95, lonRange: 6.7...7.2, includingNonPowered: false, limit: 3)
            .map(\.source), [.openAIP, .openAIP, .openAIP])
        XCTAssertTrue(catalog.points(latRange: 0...1, lonRange: 0...1, includingNonPowered: true).isEmpty)
    }

    /// Nothing waits for open flightmaps: the maps ask, it loads in the background, and `revision`
    /// tells them to ask again.
    @MainActor
    func testTheOFMPointsLoadWhenFirstShown() async throws {
        let (catalog, ofm) = try await makeCatalog(loadOFM: false)
        XCTAssertFalse(ofm.isLoaded)
        XCTAssertTrue(catalog.allPoints(includingNonPowered: false).allSatisfy { $0.source == .openAIP })
        let before = catalog.revision
        catalog.loadIfNeeded()
        for _ in 0..<200 where !ofm.isLoaded { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(ofm.isLoaded)
        XCTAssertGreaterThan(catalog.revision, before)
        XCTAssertEqual(Set(catalog.allPoints(includingNonPowered: false).filter { $0.source == .openFlightmaps }.map(tag)),
                       Set(ofmOnlyFixed))
        XCTAssertNotEqual(catalog.labelRevision, 0)
    }

    /// The GPX `<desc>` of a waypoint made from an open flightmaps point, right after launch (nothing
    /// has loaded them yet): the name and the aerodrome the waypoint stored. Loaded, from the point.
    @MainActor
    func testTheGPXDescriptionOfAnOFMWaypointNeedsNoLoadedPoints() async throws {
        let (catalog, ofm) = try await makeCatalog(loadOFM: false)
        XCTAssertFalse(ofm.isLoaded)
        var sion = FlightPlanWaypoint(name: "S", coordinate: CLLocationCoordinate2D(latitude: 46.205, longitude: 7.30611))
        sion.pointKind = .vrp
        sion.sourceId = "ofm:0e240688-94ed-b81d-cb06-9977f09ae188"
        sion.aerodromeICAO = "LSGS"
        XCTAssertEqual(FlightPlanExportService.gpxDescription(of: sion, catalog: catalog), "S · LSGS Sion")
        var unassociated = sion
        unassociated.aerodromeICAO = nil
        XCTAssertNil(FlightPlanExportService.gpxDescription(of: unassociated, catalog: catalog), "no aerodrome, no description")
        var gone = sion
        gone.sourceId = "629cc7abf4b4089a578e3c99"
        XCTAssertNil(FlightPlanExportService.gpxDescription(of: gone, catalog: catalog), "an OpenAIP id it doesn't know: as before")

        await ofm.ensureLoaded()
        XCTAssertEqual(FlightPlanExportService.gpxDescription(of: sion, catalog: catalog), "S · LSGS Sion")
        var e = FlightPlanWaypoint(name: "E", coordinate: CLLocationCoordinate2D(latitude: 47.13717, longitude: 6.97583))
        e.pointKind = .vrp
        e.sourceId = "629cc7abf4b4089a578e3c55"
        let plan = FlightPlan(name: "GPX", waypoints: [sion, e])
        XCTAssertEqual(FlightPlanExportService.gpxDescriptions(for: plan, catalog: catalog),
                       [sion.id: "S · LSGS Sion", e.id: "E · LSGC Les Eplatures"])
    }

    func testTheNewStringsHaveTheirFrench() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "fr", ofType: "lproj"))
        let french = try XCTUnwrap(Bundle(path: path))
        let missing = "\u{1}missing"
        XCTAssertEqual(french.localizedString(forKey: "Helicopter reporting point", value: missing, table: nil),
                       "Point de report pour hélicoptères")
        XCTAssertEqual(french.localizedString(forKey: "Glider reporting point", value: missing, table: nil),
                       "Point de report pour planeurs")
    }
}
