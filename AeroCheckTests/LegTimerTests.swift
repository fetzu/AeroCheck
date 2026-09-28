import XCTest
import CoreLocation
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

    // MARK: - The waypoints the flight marks on its own (v6.0.1)

    private let lszq = CLLocationCoordinate2D(latitude: 47.392, longitude: 7.030)
    private let lsgc = CLLocationCoordinate2D(latitude: 47.083, longitude: 6.793)
    private let lsgn = CLLocationCoordinate2D(latitude: 46.958, longitude: 6.864)

    /// A fix every 10 s at 100 kt along `corners`, from `start`.
    private func flight(_ corners: [CLLocationCoordinate2D], from start: Date) -> [GPSPoint] {
        var points: [GPSPoint] = []
        var t = start
        for (a, b) in zip(corners, corners.dropFirst()) {
            let nm = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1852
            let steps = max(1, Int((nm / (100.0 / 360)).rounded(.up)))
            for i in 0..<steps {
                let f = Double(i) / Double(steps)
                points.append(GPSPoint(latitude: a.latitude + (b.latitude - a.latitude) * f,
                                       longitude: a.longitude + (b.longitude - a.longitude) * f,
                                       altitude: 1500, timestamp: t, speed: 51))
                t = t.addingTimeInterval(10)
            }
        }
        return points
    }

    /// Off LSZQ, past LSGC and half way to LSGN; and the same flight cut short of LSGC.
    private func pastLSGC(takeoff: Date) -> (short: [GPSPoint], past: [GPSPoint]) {
        let halfWay = CLLocationCoordinate2D(latitude: (lsgc.latitude + lsgn.latitude) / 2,
                                             longitude: (lsgc.longitude + lsgn.longitude) / 2)
        let past = flight([lszq, lsgc, halfWay], from: takeoff)
        let short = past.filter { $0.latitude > lsgc.latitude + 0.05 }
        return (short, past)
    }

    /// One run of the in-flight catch-up, for a flight started with the plan.
    private func catchUp(_ manager: FlightPlanManager, _ track: [GPSPoint], takeoff: Date) {
        manager.catchUpWaypointPassages(track: track, takeoff: takeoff, flightPlanId: manager.activeFlightPlan?.id)
    }

    /// The catch-up finds a passage up to 15 s after it happened: the new leg starts at the passage,
    /// so the leg timer reads the time since the waypoint, as its ATO does.
    func testALegTheFlightStartsOnItsOwnIsTimedFromThePassage() throws {
        let manager = activePlan()
        let takeoff = Date().addingTimeInterval(-3600)
        manager.startChronometer()

        catchUp(manager, pastLSGC(takeoff: takeoff).past, takeoff: takeoff)

        let plan = try XCTUnwrap(manager.activeFlightPlan)
        let passed = try XCTUnwrap(plan.waypoints[1].actualTimeOver)
        XCTAssertEqual(plan.currentWaypointIndex, 2)
        XCTAssertEqual(plan.chronometerStartTime, passed)
        XCTAssertEqual(manager.chronometerElapsed, Date().timeIntervalSince(passed), accuracy: 2)
        XCTAssertTrue(manager.isChronometerRunning)
    }

    func testAPausedLegTimerStaysAtZero() {
        let manager = activePlan()
        let takeoff = Date().addingTimeInterval(-3600)
        manager.restoreLegTimer(.init(accumulated: 125, startTime: nil))

        catchUp(manager, pastLSGC(takeoff: takeoff).past, takeoff: takeoff)

        XCTAssertEqual(manager.activeFlightPlan?.currentWaypointIndex, 2)
        XCTAssertEqual(manager.chronometerElapsed, 0)
        XCTAssertFalse(manager.isChronometerRunning)
    }
}
