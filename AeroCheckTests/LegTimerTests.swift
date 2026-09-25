import XCTest
@testable import AeroCheck

/// MARK and the leg timer, and taking either back: a mis-tap in turbulence is undone with one tap.
/// (v6.0 · C2)
@MainActor
final class LegTimerTests: XCTestCase {

    private func activePlan() -> FlightPlanManager {
        let manager = makeTestPlanManager()
        let plan = FlightPlan(name: "Leg timer", waypoints: [
            FlightPlanWaypoint(name: "LSZQ", coordinate: .init(latitude: 47.392, longitude: 7.030)),
            FlightPlanWaypoint(name: "LSGC", coordinate: .init(latitude: 47.083, longitude: 6.793)),
            FlightPlanWaypoint(name: "LSGN", coordinate: .init(latitude: 46.958, longitude: 6.864)),
        ])
        manager.add(plan)
        manager.activateFlightPlan(plan)
        addTeardownBlock { @MainActor in manager.stopChronometer() }
        return manager
    }

    func testUndoingAMarkPutsTheWaypointBack() throws {
        let manager = activePlan()
        manager.markWaypoint()                                        // LSZQ, the departure
        manager.startChronometer()
        manager.restoreLegTimer(.init(accumulated: 0, startTime: Date().addingTimeInterval(-200)))
        let before = try XCTUnwrap(manager.legTimerSnapshot)
        XCTAssertEqual(manager.activeFlightPlan?.currentWaypointIndex, 1)

        manager.markWaypoint()                                        // LSGC, by mistake
        XCTAssertEqual(manager.activeFlightPlan?.currentWaypointIndex, 2)
        XCTAssertNotNil(manager.activeFlightPlan?.waypoints[1].actualTimeOver)
        XCTAssertLessThan(manager.chronometerElapsed, 5, "MARK restarts the leg")

        manager.undoMark(ofWaypointAt: 1, timer: before)

        let plan = try XCTUnwrap(manager.activeFlightPlan)
        XCTAssertEqual(plan.currentWaypointIndex, 1, "LSGC is the target again")
        XCTAssertNil(plan.waypoints[1].actualTimeOver)
        XCTAssertNotNil(plan.waypoints[0].actualTimeOver, "the departure's time is kept")
        XCTAssertEqual(manager.legTimerSnapshot, before)
        XCTAssertEqual(manager.chronometerElapsed, 200, accuracy: 2, "the leg keeps its time")
        XCTAssertTrue(manager.isChronometerRunning)
    }

    func testUndoingAResetBringsTheTimeBack() throws {
        let manager = activePlan()
        manager.restoreLegTimer(.init(accumulated: 125, startTime: nil))   // paused at 2:05
        let before = try XCTUnwrap(manager.legTimerSnapshot)

        manager.resetChronometer()
        XCTAssertEqual(manager.chronometerElapsed, 0)

        manager.restoreLegTimer(before)
        XCTAssertEqual(manager.chronometerElapsed, 125)
        XCTAssertFalse(manager.isChronometerRunning, "still paused")
    }

    func testARestoredRunningTimerCountsTheTimeSince() {
        let manager = activePlan()
        manager.restoreLegTimer(.init(accumulated: 60, startTime: Date().addingTimeInterval(-30)))
        XCTAssertTrue(manager.isChronometerRunning)
        XCTAssertEqual(manager.chronometerElapsed, 90, accuracy: 2)
    }

    func testNoActivePlanNoSnapshot() {
        XCTAssertNil(makeTestPlanManager().legTimerSnapshot)
    }
}
