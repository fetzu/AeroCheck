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
}
