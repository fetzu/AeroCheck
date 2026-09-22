import XCTest
import CoreLocation
@testable import AeroCheck

/// `RouteRadioPlanner`: who the printed nav log says to talk to on each leg.
///
/// The route runs east along 47°N in 0.3° steps (≈12.3 NM, 7.4 min at 100 kt per leg), from a field
/// at 1500 ft over three waypoints at 5000 ft to a field at 1500 ft. Row `i` is the leg ENDING at
/// waypoint `i`, so row 2 is the B→C leg.
final class RouteRadioPlannerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FlightPlan.windsAloftProvider = nil
        FlightPlan.magneticDeclinationProvider = nil
    }

    override func tearDown() {
        FlightPlan.windsAloftProvider = nil
        FlightPlan.magneticDeclinationProvider = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private let zurichInfo = RouteRadioPlanner.Station(frequency: "124.700", callSign: "ZURICH INFO")

    private func waypoints(frequencyOn index: Int? = nil) -> [FlightPlanWaypoint] {
        let lons = [7.0, 7.3, 7.6, 7.9, 8.2]
        let alts: [Double] = [1500, 5000, 5000, 5000, 1500]
        let names = ["A", "B", "C", "D", "E"]
        var plan = FlightPlan(waypoints: lons.indices.map { i in
            FlightPlanWaypoint(name: names[i], coordinate: .init(latitude: 47.0, longitude: lons[i]),
                               altitude: alts[i], plannedGroundSpeed: 100)
        })
        if let index {
            plan.waypoints[index].frequency = "118.000"
            plan.waypoints[index].callSign = "MY TWR"
        }
        plan.calculateRouteData()
        return plan.waypoints
    }

    private func airspace(_ name: String, type: Int, icaoClass: Int?, lon: ClosedRange<Double>,
                          lat: ClosedRange<Double> = 46.9...47.1,
                          floor: AltitudeLimit = AltitudeLimit(value: 0, unit: 1, referenceDatum: 0),
                          ceiling: AltitudeLimit = AltitudeLimit(value: 130, unit: 6, referenceDatum: 2),
                          frequency: (String, String)? = nil) -> Airspace {
        let ring: [[Double]] = [
            [lon.lowerBound, lat.lowerBound], [lon.lowerBound, lat.upperBound],
            [lon.upperBound, lat.upperBound], [lon.upperBound, lat.lowerBound], [lon.lowerBound, lat.lowerBound],
        ]
        return Airspace(
            id: name, name: name, type: type, icaoClass: icaoClass, country: "CH",
            upperCeiling: ceiling, lowerCeiling: floor,
            geometry: AirspaceGeometry(type: "Polygon", coordinates: [ring]), activity: nil,
            frequencies: frequency.map { [AirspaceFrequency(value: $0.0, name: $0.1, primary: true, unit: nil)] })
    }

    private func msl(_ feet: Int) -> AltitudeLimit { AltitudeLimit(value: feet, unit: 1, referenceDatum: 1) }

    private func plan(_ airspaces: [Airspace], waypoints wps: [FlightPlanWaypoint]? = nil,
                      departure: RouteRadioPlanner.Aerodrome? = nil,
                      destination: RouteRadioPlanner.Aerodrome? = nil,
                      fis: RouteRadioPlanner.Station? = nil, tag: String = "NOTAM") -> RouteRadioPlanner.Plan {
        let fisStation = fis ?? zurichInfo
        return RouteRadioPlanner.plan(.init(
            waypoints: wps ?? waypoints(), airspaces: airspaces, departure: departure, destination: destination,
            fis: { _ in fisStation }, checkAreaTag: tag))
    }

    // MARK: - Stations

    func testLegTakesTheFrequencyOfTheAirspaceItEnters() {
        let ctr = airspace("CTR ALPHA", type: 4, icaoClass: 3, lon: 7.40...7.50, frequency: ("130.150", "ALPHA TOWER"))
        let rows = plan([ctr]).rows

        XCTAssertEqual(rows[1].station?.callSign, "ZURICH INFO")
        XCTAssertEqual(rows[2].station?.frequency, "130.150")
        XCTAssertEqual(rows[2].station?.callSign, "ALPHA TWR")
        XCTAssertTrue(rows[2].changed)
        // Where, and when it is left again: the boundary is 4.1 NM after B, the exit 8.2 NM.
        XCTAssertTrue(rows[2].remarks[0].hasPrefix("▸ CTR ALPHA (D) +4."), rows[2].remarks.description)
        XCTAssertTrue(rows[2].remarks.contains { $0.hasPrefix("leave CTR ALPHA +8.") }, rows[2].remarks.description)
        // Back on FIS for the next leg, which is then repeated as a ditto.
        XCTAssertEqual(rows[3].station?.callSign, "ZURICH INFO")
        XCTAssertTrue(rows[3].changed)
        XCTAssertEqual(rows[4].station?.callSign, "ZURICH INFO")
        XCTAssertFalse(rows[4].changed)
    }

    func testAirspaceActiveByNotamIsFlagged() {
        let ctr = airspace("CTR ALPHA (HX)", type: 4, icaoClass: 3, lon: 7.40...7.50, frequency: ("130.150", "ALPHA TOWER"))
        let result = plan([ctr])
        XCTAssertEqual(result.rows[2].station?.isHX, true)
        XCTAssertTrue(result.rows[2].remarks[0].contains("HX"))
        XCTAssertTrue(result.checkAreas.contains("CTR ALPHA (HX)"))
        XCTAssertTrue(result.stations.contains { $0.label == "ALPHA TWR" && $0.marker.contains("HX") })
    }

    func testTMAWithoutAFrequencyBorrowsItsCTRs() {
        // Every TMA BERN n in OpenAIP publishes no frequency; CTR BERN does.
        let tma = airspace("TMA BRAVO 1", type: 7, icaoClass: 3, lon: 7.70...7.80, floor: msl(3500))
        let ctr = airspace("CTR BRAVO", type: 4, icaoClass: 3, lon: 7.70...7.80, lat: 46.50...46.60,
                           frequency: ("121.025", "BRAVO TOWER"))
        let result = plan([tma, ctr])

        let station = result.rows[3].station
        XCTAssertEqual(station?.frequency, "121.025")
        XCTAssertEqual(station?.callSign, "BRAVO TWR")
        XCTAssertEqual(station?.inferredFrom, "CTR BRAVO")
        XCTAssertTrue(result.notes.contains { $0.contains("CTR BRAVO") }, result.notes.description)
        XCTAssertTrue(result.stations.contains { $0.label == "BRAVO TWR" && $0.marker.contains("†") })
    }

    func testAirspaceClearedVerticallyIsNoCallButIsNotedWhenClose() {
        let close = airspace("TMA CHARLIE", type: 7, icaoClass: 3, lon: 7.35...7.55, floor: msl(5500),
                             frequency: ("127.000", "CHARLIE APPROACH"))
        let far = airspace("TMA DELTA", type: 7, icaoClass: 3, lon: 7.35...7.55, lat: 46.95...47.05, floor: msl(7000),
                           frequency: ("128.000", "DELTA APPROACH"))
        let rows = plan([close, far]).rows
        XCTAssertEqual(rows[2].station?.callSign, "ZURICH INFO")
        XCTAssertTrue(rows[2].remarks.contains("below TMA CHARLIE (5500)"), rows[2].remarks.description)
        XCTAssertFalse(rows[2].remarks.contains { $0.contains("DELTA") })
    }

    func testClassEAirspaceSetsNoFrequency() {
        let tmaE = airspace("TMA ECHO", type: 7, icaoClass: 4, lon: 7.35...7.55, floor: msl(3000),
                            frequency: ("129.000", "ECHO RADAR"))
        XCTAssertEqual(RouteRadioPlanner.kind(of: tmaE), .ignore)
        XCTAssertEqual(plan([tmaE]).rows[2].station?.callSign, "ZURICH INFO")
    }

    func testBoundaryJustPastAWaypointIsCalledOnTheLegBefore() {
        // FIZ starting 0.2 NM after D: there is no time to call once past D, so the call goes on the
        // leg TO D — as with Samedan's FIZ, 0.1 NM after W.
        let fiz = airspace("FIZ FOXTROT", type: 6, icaoClass: 6, lon: 7.905...8.30, floor: msl(0), ceiling: msl(10000),
                           frequency: ("135.325", "FOXTROT INFORMATION"))
        let rows = plan([fiz]).rows

        XCTAssertEqual(rows[3].station?.callSign, "FOXTROT INFO")
        XCTAssertTrue(rows[3].changed)
        XCTAssertEqual(rows[3].remarks.first, "▸ FIZ FOXTROT (RMZ) at D")
        XCTAssertEqual(rows[4].station?.callSign, "FOXTROT INFO")
        XCTAssertFalse(rows[4].changed)
    }

    // MARK: - Aerodromes

    func testDepartureAndDestinationUseTheAerodromeContact() {
        let dep = RouteRadioPlanner.Aerodrome(ident: "LSZQ", contact: .init(frequency: "122.050", callSign: "LSZQ AFIS"),
                                              atis: nil, ground: nil)
        let dest = RouteRadioPlanner.Aerodrome(ident: "LSZS", contact: .init(frequency: "135.325", callSign: "LSZS TWR"),
                                               atis: "136.600", ground: "121.600")
        let result = plan([], departure: dep, destination: dest)

        XCTAssertEqual(result.rows[0].station?.callSign, "LSZQ AFIS")
        XCTAssertEqual(result.rows[4].station?.callSign, "LSZS TWR")
        XCTAssertTrue(result.rows[4].remarks.contains("GND 121.600"))
        // ATIS on the last row reached at least 10 minutes before arrival (legs are 7.4 min each).
        XCTAssertTrue(result.rows[2].remarks.contains("ATIS LSZS 136.600"), result.rows.map(\.remarks).description)
        XCTAssertEqual(result.stations.map(\.label),
                       ["LSZQ AFIS", "ZURICH INFO", "LSZS TWR", "LSZS ATIS", "LSZS GND", "EMERGENCY"])
    }

    func testFrequencyTypedOnAWaypointWins() {
        let rows = plan([], waypoints: waypoints(frequencyOn: 2)).rows
        XCTAssertEqual(rows[2].station?.frequency, "118.000")
        XCTAssertEqual(rows[2].station?.callSign, "MY TWR")
        XCTAssertTrue(rows[2].isManual)
        XCTAssertTrue(rows[3].changed, "FIS again after the typed station")
    }

    func testManualOnlyKeepsJustWhatWasTyped() {
        let result = RouteRadioPlanner.manualOnly(waypoints(frequencyOn: 1))
        XCTAssertEqual(result.rows.compactMap(\.station?.callSign), ["MY TWR"])
        XCTAssertEqual(result.stations.last, RouteRadioPlanner.emergency)
    }

    // MARK: - Areas to check

    func testRestrictedAreaIsListedForDABS() {
        let glider = airspace("LSR29 TAVANNES", type: 21, icaoClass: 8, lon: 7.35...7.45,
                              floor: msl(4000), ceiling: msl(6000))
        let result = plan([glider], tag: "DABS")
        XCTAssertTrue(result.rows[2].remarks.contains { $0.hasPrefix("LS-R29 Tavannes +2.") && $0.hasSuffix("· DABS") },
                      result.rows[2].remarks.description)
        XCTAssertEqual(result.checkAreas, ["LS-R29 Tavannes"])
        XCTAssertEqual(result.rows[2].station?.callSign, "ZURICH INFO", "an area to check never sets the frequency")
    }

    // MARK: - Names

    func testNameHelpers() {
        XCTAssertEqual(RouteRadioPlanner.baseName("TMA BERN 1"), "BERN")
        XCTAssertEqual(RouteRadioPlanner.baseName("CTR BERN (HX)"), "BERN")
        XCTAssertEqual(RouteRadioPlanner.baseName("TMA BALE ZURICH AZ4 T3"), "BALE ZURICH")
        XCTAssertEqual(RouteRadioPlanner.callSign("SAMEDAN INFORMATION"), "SAMEDAN INFO")
        XCTAssertEqual(RouteRadioPlanner.callSign("Zuerich Tower"), "ZUERICH TWR")
        XCTAssertEqual(RouteRadioPlanner.foldNames(["TMA BERN 2", "TMA BERN 4"]), "TMA BERN 2 / 4")
        XCTAssertEqual(RouteRadioPlanner.Station.normalized("121.03"), "121.030")
        let r = airspace("LSD10 BREIL/BRIGELS", type: 2, icaoClass: 8, lon: 7.0...7.1)
        XCTAssertEqual(RouteRadioPlanner.checkAreaName(r), "LS-D10 Breil/Brigels")
    }
}
