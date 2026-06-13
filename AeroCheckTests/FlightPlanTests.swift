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
}
