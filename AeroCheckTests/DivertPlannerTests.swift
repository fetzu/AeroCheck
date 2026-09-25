import XCTest
import CoreLocation
@testable import AeroCheck

/// `DivertPlanner`: the in-flight list of where to go instead. (v5.1)
///
/// The aircraft is at 47°N 9°E. One minute of latitude is 1 NM; at 47°N one degree of longitude is
/// 40.9 NM.
final class DivertPlannerTests: XCTestCase {

    private let here = CLLocationCoordinate2D(latitude: 47.0, longitude: 9.0)
    private let nmPerDegLon = 60 * cos(47.0 * .pi / 180)

    private func field(_ ident: String, northNM: Double = 0, eastNM: Double = 0, country: String = "CH",
                       ppr: Bool = false) -> TripPlanner.Aerodrome {
        TripPlanner.Aerodrome(ident: ident, name: ident,
                              latitude: 47.0 + northNM / 60, longitude: 9.0 + eastNM / nmPerDegLon,
                              elevationFeet: 1500, frequency: nil, isPPR: ppr, country: country)
    }

    private func sections(track: Double? = 270, gs: Double = 100, wind: FlightPlan.WindAloft? = nil,
                          _ fields: [TripPlanner.Aerodrome],
                          destination: TripPlanner.Aerodrome? = nil, alternate: TripPlanner.Aerodrome? = nil,
                          pinned: TripPlanner.Aerodrome? = nil) -> DivertPlanner.Sections {
        DivertPlanner.sections(from: here, track: track, groundSpeedKt: gs, cruiseKt: 100, wind: wind,
                               aerodromes: fields, destination: destination, alternate: alternate,
                               pinned: pinned, country: "CH")
    }

    func testFieldsAheadComeSoonestFirstAndTurningBackIsSeparate() {
        // Flying west.
        let result = sections([field("WEST", eastNM: -10), field("EAST", eastNM: 5),
                               field("NRTH", northNM: 20), field("FARR", eastNM: -80)])
        XCTAssertEqual(result.ahead.map(\.aerodrome.ident), ["WEST", "NRTH"],
                       "abeam counts as ahead: no turn back needed")
        XCTAssertEqual(result.behind.map(\.aerodrome.ident), ["EAST"])
        XCTAssertEqual(result.ahead[0].minutes, 6, accuracy: 0.1)
        XCTAssertEqual(result.ahead[0].bearing, 270, accuracy: 0.5)
        XCTAssertFalse((result.ahead + result.behind).contains { $0.aerodrome.ident == "FARR" },
                       "beyond \(DivertPlanner.rangeNM) NM is not a diversion field")
    }

    func testTheWindDecidesWhatIsSoonest() {
        // 30 kt straight from the west while flying west at 70 kt over the ground: 100 kt through the air.
        let wind = FlightPlan.WindAloft(directionDegTrue: 270, speedKt: 30)
        XCTAssertEqual(DivertPlanner.trueAirspeed(groundSpeedKt: 70, track: 270, wind: wind), 100, accuracy: 0.01)
        let result = sections(track: 270, gs: 70, wind: wind,
                              [field("UPWD", eastNM: -10), field("DOWN", eastNM: 10)])
        XCTAssertEqual(result.ahead.first?.minutes ?? 0, 10.0 / 70 * 60, accuracy: 0.2, "into the wind")
        XCTAssertEqual(result.behind.first?.minutes ?? 0, 10.0 / 130 * 60, accuracy: 0.2, "with the wind")
    }

    func testTheDestinationAndAlternateAreListedApart() {
        let dest = field("DEST", eastNM: -40)
        let alt = field("ALTN", northNM: 5, eastNM: -30)
        let result = sections([dest, alt, field("WEST", eastNM: -10)], destination: dest, alternate: alt)
        XCTAssertEqual(result.destination?.aerodrome.ident, "DEST")
        XCTAssertEqual(result.alternate?.aerodrome.ident, "ALTN")
        XCTAssertEqual(result.ahead.map(\.aerodrome.ident), ["WEST"], "not listed twice")
    }

    func testAFieldAcrossTheBorderIsFlagged() {
        let result = sections([field("LOIH", northNM: 10, country: "AT"), field("LSZE", eastNM: -10)])
        XCTAssertEqual(result.ahead.first { $0.aerodrome.ident == "LOIH" }?.crossesBorder, true)
        XCTAssertEqual(result.ahead.first { $0.aerodrome.ident == "LSZE" }?.crossesBorder, false)
    }

    func testAFieldPickedOnTheMapIsAlwaysListedFirst() {
        let far = field("PICK", eastNM: -90)
        let result = sections([field("WEST", eastNM: -10)], pinned: far)
        XCTAssertEqual(result.ahead.first?.aerodrome.ident, "PICK", "whatever its rank or distance")
        XCTAssertEqual(result.ahead.count, 2)
    }

    func testOnTheGroundEverythingIsAheadAtCruiseSpeed() {
        // No meaningful track below 30 kt: nothing is "behind", and times use the cruise speed.
        let result = sections(track: 90, gs: 5, [field("WEST", eastNM: -10), field("EAST", eastNM: 10)])
        XCTAssertTrue(result.behind.isEmpty)
        XCTAssertEqual(result.ahead.first?.minutes ?? 0, 6, accuracy: 0.1)
    }

    func testAngleBetweenBearingsWrapsAround() {
        XCTAssertEqual(DivertPlanner.angle(between: 350, and: 10), 20)
        XCTAssertEqual(DivertPlanner.angle(between: 10, and: 190), 180)
    }
}
