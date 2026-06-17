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
}
