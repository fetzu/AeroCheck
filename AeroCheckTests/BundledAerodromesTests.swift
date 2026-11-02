import CoreLocation
import XCTest
@testable import AeroCheck

/// The bundled aerodrome index (6.8.0, the author's go of 2 Nov 2026): onboarding's nearest aerodrome and its search,
/// offline and without OpenAIP.
final class BundledAerodromesTests: XCTestCase {

    func testTheBundledIndexLoads() {
        let all = BundledAerodromes.all
        XCTAssertGreaterThan(all.count, 15000, "the app bundles the index")
        XCTAssertEqual(all.first { $0.ident == "LSZQ" }?.latitude ?? 0, 47.392, accuracy: 0.01)
    }

    func testTheNearestIsTheAerodromeUnderThePilot() {
        let samedan = CLLocationCoordinate2D(latitude: 46.534, longitude: 9.884)
        XCTAssertEqual(BundledAerodromes.nearest(to: samedan)?.ident, "LSZS")
        let bressaucourt = CLLocationCoordinate2D(latitude: 47.39, longitude: 7.03)
        XCTAssertEqual(BundledAerodromes.nearest(to: bressaucourt)?.ident, "LSZQ")
        // Mid-Atlantic: nothing within reach of a base.
        XCTAssertNil(BundledAerodromes.nearest(to: CLLocationCoordinate2D(latitude: 40, longitude: -40)))
    }

    func testTheSearchFindsByCodeAndByNameWithoutAccents() {
        XCTAssertEqual(BundledAerodromes.search("lszq").first?.ident, "LSZQ", "the code first")
        XCTAssertTrue(BundledAerodromes.search("Bressau").contains { $0.ident == "LSZQ" })
        XCTAssertEqual(BundledAerodromes.search("Bern").first?.ident, "LSZB", "Bern Airport before San Bernardino")
        XCTAssertTrue(BundledAerodromes.search("gruyere").contains { $0.ident == "LSGT" }, "La Gruyère, without its accent")
        XCTAssertEqual(BundledAerodromes.search("L").count, 0, "two characters at least")
        XCTAssertLessThanOrEqual(BundledAerodromes.search("LS").count, 6)
    }

    @MainActor
    func testTheDownloadedAirportDataAnswersBeforeTheBundle() async {
        // The author's question of 2 Nov 2026: the bundle is a snapshot from the last tag; once the airport data is on
        // the device, it answers. A made-up aerodrome the bundle doesn't have proves which one did.
        let store = makeTestAirportStore(openAIPAirports: makeTestOpenAIPAirportLayer { _ in [] })
        store.injectForReplay([Airport(id: 1, ident: "LSXX", type: .smallAirport, name: "Fresher Field",
                                       latitude: 47.39, longitude: 7.03, elevation: 1_500, continent: "EU",
                                       isoCountry: "CH", isoRegion: "CH", municipality: nil, scheduledService: false,
                                       gpsCode: "LSXX", iataCode: nil, localCode: nil)])
        let here = CLLocationCoordinate2D(latitude: 47.39, longitude: 7.03)
        let found = await NearestAerodrome.find(near: here, country: "CH", store: store)
        XCTAssertEqual(found?.ident, "LSXX", "the downloaded data, not the bundle")
        let bundled = await NearestAerodrome.find(near: here, country: "CH")
        XCTAssertEqual(bundled?.ident, "LSZQ", "the bundle without it")
    }

    func testALineIsCodeNameLatitudeLongitude() {
        let parsed = BundledAerodromes.parse("# a comment\nLSZQ\tBressaucourt Airfield\t47.392\t7.029\nbroken line\n")
        XCTAssertEqual(parsed.map(\.ident), ["LSZQ"])
        XCTAssertEqual(parsed.first?.folded, "bressaucourt airfield")
    }
}
