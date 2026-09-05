import XCTest
import CoreLocation
@testable import AeroCheck

/// Tests for flight-plan model logic.
final class FlightPlanTests: XCTestCase {

    // MARK: - legArriving(at:) — the in-flight HUD reads the ARRIVING leg, not the arrival waypoint

    func testLegArrivingReadsPrecedingWaypointForTwoWaypointPlan() {
        // The model stores each leg's data on its DEPARTURE waypoint, so waypoint A carries the
        // A→B leg and arrival waypoint B carries nil. The HUD previously read leg data off B and
        // showed "---" for a 2-waypoint plan; it must read it off A via legArriving(at:). (UX-01)
        let a = FlightPlanWaypoint(name: "A",
                                   coordinate: CLLocationCoordinate2D(latitude: 46.0, longitude: 6.0),
                                   magneticCourse: 92, distance: 12.3, estimatedElapsedTime: 600)
        let b = FlightPlanWaypoint(name: "B",
                                   coordinate: CLLocationCoordinate2D(latitude: 46.2, longitude: 6.4))
        let plan = FlightPlan(waypoints: [a, b])

        // Departure waypoint (index 0) has no inbound leg.
        XCTAssertNil(plan.legArriving(at: 0))

        // The leg ARRIVING at B (index 1) is the A→B leg, carried on waypoint A.
        let leg = plan.legArriving(at: 1)
        XCTAssertEqual(leg?.id, a.id)
        XCTAssertEqual(leg?.magneticCourse, 92)
        XCTAssertEqual(leg?.distance, 12.3)
        XCTAssertEqual(leg?.estimatedElapsedTime, 600)
    }

    func testLegArrivingIsNilForOutOfRangeIndices() {
        let plan = FlightPlan(waypoints: [
            FlightPlanWaypoint(name: "A", coordinate: CLLocationCoordinate2D(latitude: 46, longitude: 6)),
            FlightPlanWaypoint(name: "B", coordinate: CLLocationCoordinate2D(latitude: 47, longitude: 7))
        ])
        XCTAssertNil(plan.legArriving(at: -1))  // negative index never crashes
        XCTAssertNil(plan.legArriving(at: 5))   // beyond the array never crashes
    }

    func testCalculateRouteDataUsesInjectedDeclinationProvider() {
        FlightPlan.magneticDeclinationProvider = { _ in 5.0 }
        defer { FlightPlan.magneticDeclinationProvider = nil }
        var plan = FlightPlan(waypoints: [
            FlightPlanWaypoint(name: "A", coordinate: CLLocationCoordinate2D(latitude: 46, longitude: 8)),
            FlightPlanWaypoint(name: "B", coordinate: CLLocationCoordinate2D(latitude: 47, longitude: 8))   // due north
        ])
        plan.calculateRouteData()
        // True course ≈ 0; magnetic = (0 − 5 + 360) % 360 = 355.
        XCTAssertEqual(plan.waypoints[0].magneticCourse ?? -1, 355, accuracy: 1.0)
    }

    func testCalculateRouteDataFallsBackToConstantDeclination() {
        FlightPlan.magneticDeclinationProvider = nil
        var plan = FlightPlan(waypoints: [
            FlightPlanWaypoint(name: "A", coordinate: CLLocationCoordinate2D(latitude: 46, longitude: 8)),
            FlightPlanWaypoint(name: "B", coordinate: CLLocationCoordinate2D(latitude: 47, longitude: 8))
        ])
        plan.calculateRouteData()
        // No provider → 2°E fallback; magnetic = (0 − 2 + 360) % 360 = 358.
        XCTAssertEqual(plan.waypoints[0].magneticCourse ?? -1, 358, accuracy: 1.0)
    }

    func testLegArrivingOnEmptyPlanIsNil() {
        let plan = FlightPlan(waypoints: [])
        XCTAssertNil(plan.legArriving(at: 0))
        XCTAssertNil(plan.legArriving(at: 1))
    }

    // MARK: - currentWaypointId — FREQ panel highlights the right row despite filtering (UX-11)

    func testCurrentWaypointIdSurvivesFrequencyFiltering() {
        // Waypoint A has NO frequency; the current waypoint B does. The FREQ panel filters to
        // waypoints WITH a frequency, so B sits at filtered-position 0 while its real index is 1 —
        // the old `currentWaypointIndex == filteredIndex` compare highlighted the wrong row.
        let a = FlightPlanWaypoint(name: "A", coordinate: CLLocationCoordinate2D(latitude: 46, longitude: 6))
        var b = FlightPlanWaypoint(name: "B", coordinate: CLLocationCoordinate2D(latitude: 47, longitude: 7))
        b.frequency = "118.700"
        var plan = FlightPlan(waypoints: [a, b])
        plan.currentWaypointIndex = 1 // current = B

        let withFrequency = plan.waypoints.filter { $0.frequency != nil && !$0.frequency!.isEmpty }
        XCTAssertEqual(withFrequency.count, 1)
        // Identity-based selection: the single frequency row (B) is correctly the current one,
        // even though its filtered position (0) differs from currentWaypointIndex (1).
        XCTAssertEqual(plan.currentWaypointId, b.id)
        XCTAssertTrue(withFrequency.allSatisfy { $0.id == plan.currentWaypointId })
    }

    func testCurrentWaypointIdIsNilForOutOfRangeIndex() {
        var plan = FlightPlan(waypoints: [
            FlightPlanWaypoint(name: "A", coordinate: CLLocationCoordinate2D(latitude: 46, longitude: 6))
        ])
        plan.currentWaypointIndex = 5
        XCTAssertNil(plan.currentWaypointId)
    }

    // MARK: - RouteAltitudeProfile — extrapolated altitude (flight-plan revamp #4)

    /// ~1° of longitude at 46°N ≈ 41.7 NM, so a two-point W→E leg gives a known total to interpolate.
    private func eastWestPlan(altA: Double?, altB: Double?) -> [FlightPlanWaypoint] {
        [FlightPlanWaypoint(name: "A", coordinate: CLLocationCoordinate2D(latitude: 46.0, longitude: 6.0), altitude: altA),
         FlightPlanWaypoint(name: "B", coordinate: CLLocationCoordinate2D(latitude: 46.0, longitude: 8.0), altitude: altB)]
    }

    func testAltitudeProfileInterpolatesBetweenKnownWaypoints() {
        let prof = RouteAltitudeProfile(eastWestPlan(altA: 2000, altB: 6000))
        // Midpoint of the leg should be the mean of the two altitudes.
        let mid = prof.altitude(atNM: prof.totalNM / 2)
        XCTAssertNotNil(mid)
        XCTAssertEqual(mid!, 4000, accuracy: 60) // small tolerance for great-circle vs linear NM
    }

    func testAltitudeProfileClampsBeyondEnds() {
        let prof = RouteAltitudeProfile(eastWestPlan(altA: 2000, altB: 6000))
        XCTAssertEqual(prof.altitude(atNM: -10), 2000)              // before the first known point
        XCTAssertEqual(prof.altitude(atNM: prof.totalNM + 50), 6000) // after the last known point
    }

    func testAltitudeProfileWithNoAltitudesHasNoData() {
        let prof = RouteAltitudeProfile(eastWestPlan(altA: nil, altB: nil))
        XCTAssertFalse(prof.hasData)
        XCTAssertNil(prof.altitude(atNM: prof.totalNM / 2))
    }

    func testAltitudeProfileSingleKnownAltitudeClampsFlat() {
        // Only the departure altitude set → the whole profile sits at that altitude.
        let prof = RouteAltitudeProfile(eastWestPlan(altA: 3500, altB: nil))
        XCTAssertTrue(prof.hasData)
        XCTAssertEqual(prof.altitude(atNM: 0), 3500)
        XCTAssertEqual(prof.altitude(atNM: prof.totalNM), 3500)
    }

    // A single known altitude extrapolates to a flat line; terrain clearance must NOT be judged
    // against it (over rising terrain it produces a false bust). hasUsableProfile gates that. (v4.0.0
    // review P1)
    func testAltitudeProfileNeedsTwoAltitudesToBeUsableForTerrain() {
        XCTAssertFalse(RouteAltitudeProfile(eastWestPlan(altA: nil, altB: nil)).hasUsableProfile)
        XCTAssertFalse(RouteAltitudeProfile(eastWestPlan(altA: 3500, altB: nil)).hasUsableProfile)
        XCTAssertTrue(RouteAltitudeProfile(eastWestPlan(altA: 3500, altB: 6000)).hasUsableProfile)
    }

    // MARK: - bestInsertionIndex — cheapest-insertion smart add (flight-plan revamp #4)

    private func wp(_ lat: Double, _ lon: Double) -> FlightPlanWaypoint {
        FlightPlanWaypoint(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    func testBestInsertionAppendsForEmptyOrSinglePlan() {
        XCTAssertEqual(FlightPlanManager.bestInsertionIndex(for: CLLocationCoordinate2D(latitude: 46, longitude: 7), in: []), 0)
        XCTAssertEqual(FlightPlanManager.bestInsertionIndex(for: CLLocationCoordinate2D(latitude: 46, longitude: 7), in: [wp(46, 6)]), 1)
    }

    func testBestInsertionPlacesMidpointOnTheLeg() {
        // A(46,6) → B(46,8); a point near the middle inserts between them (index 1).
        let plan = [wp(46, 6), wp(46, 8)]
        XCTAssertEqual(FlightPlanManager.bestInsertionIndex(for: CLLocationCoordinate2D(latitude: 46.02, longitude: 7), in: plan), 1)
    }

    func testBestInsertionAppendsBeyondLastAndPrependsBeforeFirst() {
        let plan = [wp(46, 6), wp(46, 8)]
        XCTAssertEqual(FlightPlanManager.bestInsertionIndex(for: CLLocationCoordinate2D(latitude: 46, longitude: 9), in: plan), 2) // append
        XCTAssertEqual(FlightPlanManager.bestInsertionIndex(for: CLLocationCoordinate2D(latitude: 46, longitude: 5), in: plan), 0) // prepend
    }

    func testBestInsertionChoosesTheNearerLegOnAThreePointRoute() {
        // A(46,6) - B(46,7) - C(46,8); a point near the B→C leg inserts at index 2.
        let plan = [wp(46, 6), wp(46, 7), wp(46, 8)]
        XCTAssertEqual(FlightPlanManager.bestInsertionIndex(for: CLLocationCoordinate2D(latitude: 46.02, longitude: 7.5), in: plan), 2)
        // …and a point near the A→B leg inserts at index 1.
        XCTAssertEqual(FlightPlanManager.bestInsertionIndex(for: CLLocationCoordinate2D(latitude: 46.02, longitude: 6.5), in: plan), 1)
    }

    // MARK: - ICAO flight plan message (Doc 4444)
    //
    // This text gets read off the screen while filling in skybriefing's form, so a field that is
    // syntactically wrong is worse than one that is absent: it looks authoritative and gets copied.

    private func filedPlan(departure: Date? = nil) -> FlightPlan {
        var plan = FlightPlan(
            name: "LSZQ → LSGY",
            waypoints: [
                FlightPlanWaypoint(name: "LSZQ", coordinate: CLLocationCoordinate2D(latitude: 47.4247, longitude: 7.1869)),
                FlightPlanWaypoint(name: "LSGY", coordinate: CLLocationCoordinate2D(latitude: 46.7619, longitude: 6.6141)),
            ],
            pilot: "Jean Dupont",
            plannedDepartureTime: departure,
            fuelFlow: 20,
            fuelOnBoard: 60,
            personsOnBoard: 2,
            aircraftColour: "white red"
        )
        plan.calculateRouteData()
        return plan
    }

    func testFieldEighteenNeverEmitsAMalformedIndicator() {
        // The old output was "0/2 PIC/JEAN DUPONT": "0" is Field 18's *nothing to declare* marker,
        // not an indicator prefix, and neither "0/" nor "PIC/" exists in Doc 4444. Persons on board
        // is Field 19 P/, and the pilot in command is Field 19 C/.
        let fpl = filedPlan().toICAOFlightPlan()
        XCTAssertFalse(fpl.contains("0/2"), "0/ is not an ICAO Field 18 indicator")
        XCTAssertFalse(fpl.contains("PIC/"), "PIC/ is not an ICAO Field 18 indicator")
        XCTAssertTrue(fpl.contains("C/JEAN DUPONT"), "the pilot belongs in Field 19 C/")
    }

    func testFieldEighteenIsTheLiteralZeroWhenThereIsNothingToDeclare() {
        // Both aerodromes have ICAO codes and no departure date is set, so there is genuinely
        // nothing to say — which is written "0", not an empty line.
        let fpl = filedPlan().toICAOFlightPlan()
        XCTAssertTrue(fpl.contains("\n-0\n"), "Field 18 must be the literal 0, got:\n\(fpl)")
    }

    func testDateOfFlightIsDeclaredWhenTheDepartureIsKnown() {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 5
        components.hour = 8; components.minute = 30
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let fpl = filedPlan(departure: calendar.date(from: components)!).toICAOFlightPlan()

        XCTAssertTrue(fpl.contains("DOF/260905"), "DOF is yyMMdd in UTC, got:\n\(fpl)")
        XCTAssertTrue(fpl.contains("-LSZQ0830\n"), "Field 13 time is UTC HHmm, got:\n\(fpl)")
    }

    /// Field 19 is the last line of the message. Worth isolating: Field 10 renders equipment and
    /// surveillance as "S/N", so searching the whole message for "S/" finds a match that has nothing
    /// to do with survival equipment.
    private func fieldNineteen(of fpl: String) -> String {
        String(fpl.split(separator: "\n").last ?? "")
    }

    func testSurvivalEquipmentIsNeverInvented() {
        // S/, J/ and D/ tell search and rescue how to look for a downed aircraft. The app cannot see
        // the baggage compartment, so it must leave them for the pilot rather than guess a default.
        let field19 = fieldNineteen(of: filedPlan().toICAOFlightPlan())
        for indicator in ["S/", "J/", "D/"] {
            XCTAssertFalse(field19.contains(indicator),
                           "\(indicator) is equipment we cannot observe and must not assert: \(field19)")
        }
    }

    func testRadioIsDeclaredBecauseFieldNineteenRequiresIt() {
        // R/ is mandatory and VHF is structurally certain — an aircraft that cannot legally fly this
        // airspace without it. Nothing beyond that letter is asserted.
        let field19 = fieldNineteen(of: filedPlan().toICAOFlightPlan())
        XCTAssertTrue(field19.contains("R/V"), field19)
        XCTAssertFalse(field19.contains("R/VE"), "an ELT is equipment we have no way of knowing about")
    }

    func testFieldNineteenKeepsThePrescribedOrder() {
        let field19 = fieldNineteen(of: filedPlan().toICAOFlightPlan())
        let positions = ["E/", "P/", "R/", "A/", "C/"].map { field19.range(of: $0)?.lowerBound }
        XCTAssertFalse(positions.contains(where: { $0 == nil }), "all five should be present: \(field19)")
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted(),
                       "Field 19 order is E/ P/ R/ S/ J/ D/ A/ N/ C/: \(field19)")
    }

    func testEnduranceRoundsToWholeMinutesWithoutLosingAnHour() {
        // 60 L at 20 L/h is exactly 3 h. Truncating the fractional part of a value that lands a hair
        // under would have read 0259.
        let fpl = filedPlan().toICAOFlightPlan()
        XCTAssertTrue(fpl.contains("E/0300"), "got:\n\(fpl)")
    }

    func testAnAerodromeWithoutAnICAOCodeIsGivenAsCoordinatesNotAName() {
        // Field 18 separates indicators with a space, so "DEP/GRENCHEN FIELD" would split into a
        // second, meaningless indicator. ICAO lat/long is the standard form and has no spaces.
        var plan = FlightPlan(waypoints: [
            FlightPlanWaypoint(name: "Grenchen field", coordinate: CLLocationCoordinate2D(latitude: 47.1817, longitude: 7.4172)),
            FlightPlanWaypoint(name: "LSGY", coordinate: CLLocationCoordinate2D(latitude: 46.7619, longitude: 6.6141)),
        ])
        plan.calculateRouteData()
        let fpl = plan.toICAOFlightPlan()

        XCTAssertTrue(fpl.contains("DEP/4711N00725E"), "got:\n\(fpl)")
        XCTAssertFalse(fpl.contains("GRENCHEN FIELD"))
    }

    func testICAOLatLongCarriesRoundedMinutesIntoTheDegree() {
        // 47.99999° is 48°00', never 47°60'.
        XCTAssertEqual(FlightPlan.icaoLatLong(47.99999, 7.99999), "4800N00800E")
        XCTAssertEqual(FlightPlan.icaoLatLong(-33.5, -70.75), "3330S07045W")
        XCTAssertEqual(FlightPlan.icaoLatLong(0, 0), "0000N00000E")
    }
}
