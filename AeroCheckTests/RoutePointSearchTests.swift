import XCTest
import CoreLocation
@testable import AeroCheck

/// The route builder's "Via" search (6.0.1): reporting points by name, aerodrome or unofficial ident,
/// navaids by ident or name, ranked, and measured from the route. Points as the OpenAIP core API
/// returns them for Switzerland (2026-09-29), trimmed to what the search reads.
final class RoutePointSearchTests: XCTestCase {

    private let lsgc = "6261519e0e8346dfd925198a"
    private let lszb = "62615198cb27f42509466dbb"
    private let lsmp = "626151a44b027aab592b445d"
    private let lsza = "6261519f5e9ded57104530ff"

    private lazy var aerodromes: [String: ReportingPointAerodrome] = [
        lsgc: ReportingPointAerodrome(icao: "LSGC", name: "LES EPLATURES"),
        lszb: ReportingPointAerodrome(icao: "LSZB", name: "BERN-BELP"),
        lsmp: ReportingPointAerodrome(icao: "LSMP", name: "PAYERNE"),
        lsza: ReportingPointAerodrome(icao: "LSZA", name: "LUGANO"),
    ]

    private lazy var points: [ReportingPoint] = {
        func item(_ id: String, _ name: String, _ airport: String, _ lat: Double, _ lon: Double,
                  compulsory: Bool = false, remarks: String? = nil) -> [String: Any] {
            var item: [String: Any] = ["_id": id, "name": name, "compulsory": compulsory, "airports": [airport],
                                       "geometry": ["type": "Point", "coordinates": [lon, lat]]]
            item["remarks"] = remarks
            return item
        }
        let items = [
            item("e-lsgc", "E", lsgc, 47.13717, 6.97583, remarks: "Les Eplatures VRP - E {ELESE}"),
            item("n-lsgc", "N", lsgc, 47.18967, 6.91833, remarks: "Les Eplatures VRP - N {NLESE}"),
            item("ne-lsgc", "NE", lsgc, 47.14, 6.84167, remarks: "Les Eplatures VRP - NE {NELES}"),
            item("e-lszb", "E", lszb, 47.00028, 7.64611, compulsory: true, remarks: "Bern airport"),
            item("witzwil", "WITZWIL", lsmp, 46.99028, 7.04861, compulsory: true),
            item("murten", "MURTEN", lsmp, 46.92111, 7.14528, remarks: "Payerne airport"),
            item("abm", "ABM AVENCHES", lsmp, 46.87056, 7.04972, compulsory: true),
            item("sluga", "SLUGA", lsza, 45.9025, 8.90467, remarks: "Lugano VRP - S {SLUGA}"),
        ]
        let data = try! OpenAIPLayerCache<ReportingPoint>.featureCollectionData(fromCoreAPIItems: items)
        return try! ReportingPoint.parse(geoJSON: data)
    }()

    private lazy var navaids: [Navaid] = try! Navaid.parse(geoJSON: Data("""
    { "type": "FeatureCollection", "features": [
      { "type": "Feature", "properties": { "_id": "fri", "name": "FRIBOURG", "identifier": "FRI", "type": 4,
          "frequency": { "value": "110.850", "unit": 2 } },
        "geometry": { "type": "Point", "coordinates": [7.2253, 46.7778] } },
      { "type": "Feature", "properties": { "_id": "wil", "name": "WILLISAU", "identifier": "WIL", "type": 4,
          "frequency": { "value": "116.900", "unit": 2 } },
        "geometry": { "type": "Point", "coordinates": [7.9744, 47.1789] } }
    ] }
    """.utf8))

    /// LSZQ → LSMP, which passes La Chaux-de-Fonds and the Seeland.
    private let route = [CLLocationCoordinate2D(latitude: 47.3922, longitude: 7.0296),
                         CLLocationCoordinate2D(latitude: 46.8425, longitude: 6.9136)]

    private func search(_ query: String, route: [CLLocationCoordinate2D]? = nil) -> [RoutePointSearch.Result] {
        RoutePointSearch.search(query, reportingPoints: points, aerodromes: aerodromes, navaids: navaids,
                                route: route ?? self.route)
    }

    private func ids(_ results: [RoutePointSearch.Result]) -> [String] {
        results.map { $0.id.replacingOccurrences(of: "rp:", with: "").replacingOccurrences(of: "nav:", with: "") }
    }

    // MARK: - Matching

    func testANamedPointByItsName() {
        XCTAssertEqual(ids(search("WITZWIL")), ["witzwil"])
        XCTAssertEqual(ids(search("witz")), ["witzwil"], "case and a start are enough")
        XCTAssertEqual(ids(search("abm avenches")), ["abm"], "a name of two words, typed whole")
    }

    func testTheAerodromeNarrowsAShortName() {
        XCTAssertEqual(ids(search("LSGC E")).first, "e-lsgc")
        XCTAssertFalse(ids(search("LSGC E")).contains("e-lszb"), "Bern's E is not Les Eplatures'")
        XCTAssertEqual(ids(search("E LSZB")), ["e-lszb"], "in either order")
        XCTAssertEqual(ids(search("eplatures e")).first, "e-lsgc", "or by the aerodrome's name")
    }

    func testAnAerodromeAloneListsItsPoints() {
        XCTAssertEqual(Set(ids(search("LSGC"))), ["e-lsgc", "n-lsgc", "ne-lsgc"])
        XCTAssertEqual(Set(ids(search("payerne"))), ["witzwil", "murten", "abm"])
    }

    func testTheUnofficialIdentFindsItsPoint() {
        let results = search("ELESE")
        XCTAssertEqual(ids(results), ["e-lsgc"])
        XCTAssertEqual(results.first?.tier, 3)
        XCTAssertEqual(results.first?.title, "E", "shown by its name, not by the ident")
        XCTAssertEqual(ids(search("SLUGA")), ["sluga"], "SLUGA is also the point's name")
    }

    func testNavaidsByIdentOrName() {
        XCTAssertEqual(ids(search("FRI")), ["fri"])
        XCTAssertEqual(ids(search("fribourg")), ["fri"])
        let result = search("FRI").first
        XCTAssertEqual(result?.kind, .navaid)
        XCTAssertEqual(result?.subtitle, "VOR/DME · FRIBOURG")
        if case .navaid(let navaid)? = result?.point { XCTAssertEqual(navaid.identifier, "FRI") } else { XCTFail() }
    }

    func testOneLetterDoesNotBringUpAWholeAerodrome() {
        // "E" matches the points named E (and a name starting with E), not every point of Les
        // *E*platures: a qualifier needs three letters to match its start.
        XCTAssertEqual(Set(ids(search("E"))), ["e-lsgc", "e-lszb"])
        XCTAssertTrue(search("QQQ").isEmpty)
        XCTAssertTrue(search("   ").isEmpty)
    }

    // MARK: - Ranking

    /// The name itself, then a start of it, then the aerodrome or navaid name, then the ident; nearest
    /// the route first within a rank.
    func testRankingByHowTheQueryNamesThePointThenByDistance() {
        let wi = search("WI")
        XCTAssertEqual(ids(wi), ["witzwil", "wil"], "both start with WI: WITZWIL is nearer the route")
        XCTAssertEqual(wi.map(\.tier), [1, 1])

        let e = search("E")
        XCTAssertEqual(ids(e), ["e-lsgc", "e-lszb"], "Les Eplatures' E is on the route, Bern's 28 NM off")
        XCTAssertLessThan(e[0].distanceNM ?? .infinity, e[1].distanceNM ?? 0)

        // An exact name beats an aerodrome-only match.
        let lsgcN = search("LSGC N")
        XCTAssertEqual(ids(lsgcN).first, "n-lsgc")
        XCTAssertEqual(lsgcN.first?.tier, 0)
        XCTAssertEqual(lsgcN.first(where: { $0.id == "rp:ne-lsgc" })?.tier, 1)
    }

    func testTheIdentRanksBelowNamesAndAerodromes() {
        XCTAssertEqual(RoutePointSearch.tier(["elese"], name: "E", qualifiers: ["LSGC", "LES EPLATURES"], ident: "ELESE"), 3)
        XCTAssertEqual(RoutePointSearch.tier(["lsgc"], name: "E", qualifiers: ["LSGC", "LES EPLATURES"], ident: "ELESE"), 2)
        XCTAssertEqual(RoutePointSearch.tier(["e"], name: "E", qualifiers: ["LSGC", "LES EPLATURES"], ident: "ELESE"), 0)
        XCTAssertNil(RoutePointSearch.tier(["lszb", "e"], name: "E", qualifiers: ["LSGC", "LES EPLATURES"], ident: "ELESE"))
    }

    // MARK: - Result rows

    func testAResultCarriesTheLabelAndTheDistanceFromTheRoute() throws {
        let e = try XCTUnwrap(search("LSGC E").first)
        XCTAssertEqual(e.subtitle, "LSGC Les Eplatures")
        XCTAssertEqual(e.kind, .reportingPoint(compulsory: false))
        XCTAssertEqual(try XCTUnwrap(e.distanceNM), 0, accuracy: 0.1, "E sits on the leg LSZQ → LSMP")
        let n = try XCTUnwrap(search("LSGC N").first?.distanceNM)
        XCTAssertEqual(n, 2.8, accuracy: 0.2, "from the leg, not from its ends (N is 7 NM from LSZQ)")
        guard case .reportingPoint(let point, let label) = e.point else { return XCTFail() }
        XCTAssertEqual(point.code, "ELESE")
        XCTAssertEqual(label.aerodrome?.icao, "LSGC")
        XCTAssertEqual(try XCTUnwrap(search("WITZWIL").first).kind, .reportingPoint(compulsory: true))
    }

    func testWithoutALegTheDistanceIsFromTheOnlyPointOrTheReference() throws {
        let fromDeparture = try XCTUnwrap(search("MURTEN", route: [route[1]]).first?.distanceNM)
        XCTAssertEqual(fromDeparture, 10.6, accuracy: 0.3)
        let none = RoutePointSearch.search("MURTEN", reportingPoints: points, aerodromes: aerodromes, navaids: [],
                                           route: [], reference: nil)
        XCTAssertNil(none.first?.distanceNM)
    }

    func testTheListIsCapped() {
        XCTAssertLessThanOrEqual(RoutePointSearch.search("E", reportingPoints: points + points, aerodromes: aerodromes,
                                                         navaids: navaids, route: route, limit: 3).count, 3)
    }
}
