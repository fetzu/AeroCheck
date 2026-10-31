import CoreLocation
import XCTest
@testable import AeroCheck

/// Onboarding's "Based at" suggestion (6.8.0, the author's answer 2 A): the nearest aerodrome with an ICAO code from
/// OpenAIP's answer, heliports and closed fields left out; a country's list read page by page.
final class NearestAerodromeTests: XCTestCase {

    private let porrentruy = CLLocationCoordinate2D(latitude: 47.488, longitude: 7.042)

    private func page(_ items: String, page: Int = 1, of total: Int = 1) -> Data {
        Data(#"{"items":[\#(items)],"page":\#(page),"totalPages":\#(total)}"#.utf8)
    }

    func testTheNearestWithAnICAOCodeNoHeliportNorClosedField() throws {
        let data = page("""
            {"icaoCode":"LFSB","name":"Bâle-Mulhouse","type":3,"geometry":{"coordinates":[7.529,47.590]}},
            {"icaoCode":"LSZQ","name":"Bressaucourt","type":2,"geometry":{"coordinates":[7.040,47.408]}},
            {"name":"Without code","type":2,"geometry":{"coordinates":[7.04,47.49]}},
            {"icaoCode":"LSHX","name":"A heliport","type":7,"geometry":{"coordinates":[7.04,47.49]}},
            {"icaoCode":"LSXX","name":"Closed","type":8,"geometry":{"coordinates":[7.04,47.49]}}
            """)
        let found = try XCTUnwrap(NearestAerodrome.nearest(in: data, to: porrentruy))
        XCTAssertEqual(found.ident, "LSZQ")
        XCTAssertEqual(found.distanceNM, 4.8, accuracy: 0.3)
    }

    func testACountrysListSaysWhenMorePagesFollow() throws {
        let item = #"{"icaoCode":"LFGA","name":"Colmar","type":2,"geometry":{"coordinates":[7.36,48.11]}}"#
        XCTAssertEqual(NearestAerodrome.page(page(item, page: 1, of: 2), near: porrentruy)?.hasMore, true)
        XCTAssertEqual(NearestAerodrome.page(page(item, page: 2, of: 2), near: porrentruy)?.hasMore, false)
        XCTAssertNil(NearestAerodrome.page(Data("<html>403</html>".utf8), near: porrentruy), "the firewall's page")
    }

    func testTheRequestsAskOnlyForTheFieldsRead() throws {
        let around = try XCTUnwrap(NearestAerodrome.request(near: porrentruy)?.url?.absoluteString)
        XCTAssertTrue(around.contains("pos=47.49,7.04"), around)
        XCTAssertTrue(around.contains("fields=icaoCode,name,type,geometry"), around)
        let country = try XCTUnwrap(NearestAerodrome.request(country: "FR", page: 2)?.url?.absoluteString)
        XCTAssertTrue(country.contains("country=FR&limit=1000&page=2"), country)
        XCTAssertTrue(country.contains("fields="), country)
    }

    func testANameInCapitalsReadsInTitleCase() {
        XCTAssertEqual(NearestAerodrome.displayName("BRESSAUCOURT"), "Bressaucourt")
        XCTAssertEqual(NearestAerodrome.displayName("BÂLE-MULHOUSE"), "Bâle-Mulhouse")
        XCTAssertEqual(NearestAerodrome.displayName("Lugano-Agno"), "Lugano-Agno")
        XCTAssertNil(NearestAerodrome.displayName(""))
    }
}
