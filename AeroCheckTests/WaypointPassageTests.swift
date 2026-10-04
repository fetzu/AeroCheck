import XCTest
import CoreLocation
@testable import AeroCheck

/// `WaypointPassage`: actual times over, reconstructed from a GPS track.
///
/// Synthetic flights east along 47°N at 100 kt, one fix every 10 s. 0.1° of longitude is 4.09 NM
/// there, so a waypoint every 0.3° is 12.3 NM (7.4 min) apart.
final class WaypointPassageTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let nmPerDegLon = 60 * cos(47.0 * .pi / 180)

    private func route(_ points: [(lat: Double, lon: Double)]) -> [CLLocationCoordinate2D] {
        points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    /// Fixes along `path` (lat, lon corners) at 100 kt from `start` (default `t0`).
    private func track(_ path: [(lat: Double, lon: Double)], from start: Date? = nil) -> [WaypointPassage.Fix] {
        var fixes: [WaypointPassage.Fix] = []
        var t = start ?? t0
        let step = 100.0 / 3600 * 10   // NM per 10 s
        for k in 0..<(path.count - 1) {
            let a = path[k], b = path[k + 1]
            let dx = (b.lon - a.lon) * nmPerDegLon, dy = (b.lat - a.lat) * 60
            let n = max(1, Int((hypot(dx, dy) / step).rounded(.up)))
            for i in 0..<n {
                let f = Double(i) / Double(n)
                fixes.append(.init(time: t, coordinate: .init(latitude: a.lat + (b.lat - a.lat) * f,
                                                              longitude: a.lon + (b.lon - a.lon) * f), speed: 51))
                t = t.addingTimeInterval(10)
            }
        }
        let last = path[path.count - 1]
        fixes.append(.init(time: t, coordinate: .init(latitude: last.lat, longitude: last.lon), speed: 51))
        return fixes
    }

    /// Seconds after `t0` at which a 100 kt flight from `startLon` reaches `lon` along 47°N.
    private func seconds(from startLon: Double, to lon: Double) -> Double {
        (lon - startLon) * nmPerDegLon / 100 * 3600
    }

    func testWaypointsFlownOneMileToTheSideAreStillPassed() {
        let r = route([(47.0, 7.0), (47.0, 7.3), (47.0, 7.6), (47.0, 7.9)])
        // Flown the whole way 1 NM north of the line — the old 500 m radius saw none of it.
        let fixes = track([(47.0, 7.0), (47.0 + 1.0 / 60, 7.05), (47.0 + 1.0 / 60, 7.85), (47.0, 7.9)])
        let times = WaypointPassage.timesOver(route: r, track: fixes, takeoff: t0, landing: fixes.last!.time)

        XCTAssertEqual(times[0], t0, "departure = takeoff")
        XCTAssertEqual(times[3], fixes.last!.time, "destination = landing")
        for (i, lon) in [(1, 7.3), (2, 7.6)] {
            let expected = seconds(from: 7.0, to: lon)
            XCTAssertEqual(times[i]?.timeIntervalSince(t0) ?? -1, expected, accuracy: 20, "waypoint \(i)")
        }
    }

    func testAWaypointPassedTooFarAwayStaysEmptyAndTheRestStillMatch() {
        // The second turning point sits 3 NM north of where the aircraft actually flew.
        let r = route([(47.0, 7.0), (47.0, 7.3), (47.05, 7.6), (47.0, 7.9)])
        let fixes = track([(47.0, 7.0), (47.0, 7.9)])
        let times = WaypointPassage.timesOver(route: r, track: fixes, takeoff: t0, landing: fixes.last!.time)
        XCTAssertNotNil(times[1])
        XCTAssertNil(times[2], "3 NM off is beyond the tolerance")
        XCTAssertNotNil(times[3])
    }

    func testADiversionLeavesTheRestOfTheRouteWithoutTimes() {
        let r = route([(47.0, 7.0), (47.0, 7.3), (47.0, 7.6), (47.0, 7.9)])
        // Turned south after the first waypoint and landed 10 NM away from the route.
        let fixes = track([(47.0, 7.0), (47.0, 7.35), (46.85, 7.4)])
        let times = WaypointPassage.timesOver(route: r, track: fixes, takeoff: t0, landing: fixes.last!.time)
        XCTAssertNotNil(times[1])
        XCTAssertNil(times[2])
        XCTAssertNil(times[3], "landed somewhere else: no time at the planned destination")
    }

    func testCuttingTheCornerCountsAsPassingTheTurn() {
        // East, then a 90° turn north at 7.3; the aircraft turns 1 NM early.
        let r = route([(47.0, 7.0), (47.0, 7.3), (47.3, 7.3)])
        let fixes = track([(47.0, 7.0), (47.0, 7.3 - 1 / nmPerDegLon), (47.0 + 1.0 / 60, 7.3), (47.3, 7.3)])
        let times = WaypointPassage.timesOver(route: r, track: fixes, takeoff: t0, landing: fixes.last!.time)
        XCTAssertNotNil(times[1])
        XCTAssertEqual(times[1]?.timeIntervalSince(t0) ?? -1, seconds(from: 7.0, to: 7.3), accuracy: 60)
    }

    func testWithoutATakeoffTimeTheFirstFastFixCounts() {
        let r = route([(47.0, 7.0), (47.0, 7.3), (47.0, 7.6)])
        var fixes = track([(47.0, 7.0), (47.0, 7.6)])
        // Taxiing: two slow fixes before the roll.
        fixes.insert(.init(time: t0.addingTimeInterval(-60), coordinate: .init(latitude: 47.0, longitude: 7.0), speed: 3), at: 0)
        let times = WaypointPassage.timesOver(route: r, track: fixes, takeoff: nil, landing: nil)
        XCTAssertEqual(times[0], t0)
        XCTAssertNotNil(times[1])
        XCTAssertNil(times[2], "still flying: no landing, no destination time")
    }

    func testATimeRecordedInFlightIsKept() {
        var plan = FlightPlan(name: "Kept")
        plan.waypoints = [(47.0, 7.0), (47.0, 7.3), (47.0, 7.6)].map {
            FlightPlanWaypoint(coordinate: .init(latitude: $0.0, longitude: $0.1))
        }
        let tapped = t0.addingTimeInterval(123)
        plan.waypoints[1].actualTimeOver = tapped
        let gps = track([(47.0, 7.0), (47.0, 7.6)]).map {
            GPSPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, altitude: 1500,
                     timestamp: $0.time, speed: $0.speed)
        }
        let filled = plan.withActualTimesOver(fromTrack: gps, takeoff: t0, landing: gps.last!.timestamp)
        XCTAssertEqual(filled.waypoints[1].actualTimeOver, tapped)
        XCTAssertEqual(filled.waypoints[0].actualTimeOver, t0)
        XCTAssertNotNil(filled.waypoints[2].actualTimeOver)
    }

    /// The departure's time over is the take-off once it is known, whatever was recorded in flight,
    /// and the destination's the landing; without them, a recorded time stays. The Flight Log and the nav log of a past flight read it
    /// like this (`withActualTimesOver(from:)`). (6.1)
    func testTheDeparturesTimeOverIsTheTakeoffOnceItIsKnown() {
        var plan = FlightPlan(name: "Departure")
        plan.waypoints = [(47.0, 7.0), (47.0, 7.3), (47.0, 7.6)].map {
            FlightPlanWaypoint(coordinate: .init(latitude: $0.0, longitude: $0.1))
        }
        let firstFastFix = t0.addingTimeInterval(8)
        plan.waypoints[0].actualTimeOver = firstFastFix
        let gps = track([(47.0, 7.0), (47.0, 7.6)]).map {
            GPSPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, altitude: 1500,
                     timestamp: $0.time, speed: $0.speed)
        }

        XCTAssertEqual(plan.withActualTimesOver(fromTrack: gps, takeoff: nil, landing: nil).waypoints[0].actualTimeOver,
                       firstFastFix)
        XCTAssertEqual(plan.withActualTimesOver(fromTrack: gps, takeoff: t0, landing: nil).waypoints[0].actualTimeOver,
                       t0)
        var flight = Flight(startTime: t0, lineUpTime: t0.addingTimeInterval(2))
        flight.gpsTrack = gps
        XCTAssertEqual(plan.withActualTimesOver(from: flight).waypoints[0].actualTimeOver, t0.addingTimeInterval(2))

        // Taking off somewhere else than the departure is no time over it.
        let elsewhere = track([(47.2, 7.3), (47.0, 7.6)]).map {
            GPSPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, altitude: 1500,
                     timestamp: $0.time, speed: $0.speed)
        }
        XCTAssertEqual(plan.withActualTimesOver(fromTrack: elsewhere, takeoff: t0, landing: nil).waypoints[0].actualTimeOver,
                       firstFastFix)

        // The destination likewise: its time over is the landing once it is known.
        let marked = gps.last!.timestamp.addingTimeInterval(-40)
        plan.waypoints[2].actualTimeOver = marked
        XCTAssertEqual(plan.withActualTimesOver(fromTrack: gps, takeoff: t0, landing: nil).waypoints[2].actualTimeOver,
                       marked)
        XCTAssertEqual(plan.withActualTimesOver(fromTrack: gps, takeoff: t0, landing: gps.last!.timestamp)
                        .waypoints[2].actualTimeOver, gps.last!.timestamp)
    }

    func testETOAtAWaypointIsTheArrivingLegs() {
        var plan = FlightPlan(name: "ETO", plannedDepartureTime: t0)
        plan.waypoints = [(47.0, 7.0), (47.0, 7.3), (47.0, 7.6)].map {
            FlightPlanWaypoint(coordinate: .init(latitude: $0.0, longitude: $0.1), plannedGroundSpeed: 100)
        }
        plan.calculateRouteData()
        XCTAssertEqual(plan.estimatedTimeOver(at: 0), t0)
        XCTAssertEqual(plan.estimatedTimeOver(at: 1), plan.waypoints[0].estimatedTimeOver)
        XCTAssertEqual(plan.estimatedTimeOver(at: 2), plan.waypoints[2].estimatedTimeOver)
        XCTAssertGreaterThan(plan.estimatedTimeOver(at: 2)!, plan.estimatedTimeOver(at: 1)!)
    }

    // MARK: - In flight: the live catch-up (v6.0.1)

    /// A plan through `points`, active on a manager of its own.
    @MainActor
    private func activePlan(_ points: [(lat: Double, lon: Double)]) -> FlightPlanManager {
        let manager = makeTestPlanManager()
        let plan = FlightPlan(name: "Live", waypoints: points.enumerated().map { i, p in
            FlightPlanWaypoint(name: "WP\(i)", coordinate: .init(latitude: p.lat, longitude: p.lon))
        })
        manager.add(plan)
        manager.activateFlightPlan(plan)
        addTeardownBlock { @MainActor in manager.stopChronometer() }
        return manager
    }

    /// One run of the in-flight catch-up, for a flight started with the plan (off at `t0`).
    @MainActor
    private func catchUp(_ manager: FlightPlanManager, _ track: [GPSPoint]) {
        manager.catchUpWaypointPassages(track: track, takeoff: t0, flightPlanId: manager.activeFlightPlan?.id)
    }

    private func gps(_ fixes: [WaypointPassage.Fix]) -> [GPSPoint] {
        fixes.map {
            GPSPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, altitude: 1500,
                     timestamp: $0.time, speed: $0.speed)
        }
    }

    /// The core property of the move out of the nav map: runs every 15 s over the track so far end
    /// exactly where one run over the whole flight does, and never step back.
    @MainActor
    func testCatchingUpAsTheTrackGrowsEndsWhereTheWholeTrackDoes() throws {
        let route: [(lat: Double, lon: Double)] = [(47.0, 7.0), (47.0, 7.3), (47.05, 7.6), (47.0, 7.9)]
        let flights: [(String, [WaypointPassage.Fix])] = [
            ("a mile to the side", track([(47.0, 7.0), (47.0 + 1.0 / 60, 7.05), (47.0 + 1.0 / 60, 7.85), (47.0, 7.9)])),
            ("the second turn missed by 3 NM", track([(47.0, 7.0), (47.0, 7.9)])),
            ("corners cut", track([(47.0, 7.0), (47.0, 7.28), (47.04, 7.58), (47.0, 7.88), (47.0, 7.9)])),
        ]
        for (name, fixes) in flights {
            let manager = activePlan(route)
            let armed = try XCTUnwrap(manager.activeFlightPlan)
            let points = gps(fixes)
            var targets: [Int] = []
            // A fix every 10 s: a run every second fix is the 15 s cadence at its slowest.
            for end in stride(from: 2, through: points.count, by: 2) {
                catchUp(manager, Array(points.prefix(end)))
                targets.append(try XCTUnwrap(manager.activeFlightPlan).currentWaypointIndex)
            }
            catchUp(manager, points)

            let live = try XCTUnwrap(manager.activeFlightPlan)
            let batch = armed.withActualTimesOver(fromTrack: points, takeoff: t0, landing: nil)
            XCTAssertEqual(live.waypoints.map(\.actualTimeOver), batch.waypoints.map(\.actualTimeOver), name)
            XCTAssertEqual(targets, targets.sorted(), "\(name): only ever forward")
            XCTAssertNil(live.waypoints[3].actualTimeOver, "\(name): the destination waits for the landing")
            let lastPassed = try XCTUnwrap(batch.waypoints.lastIndex { $0.actualTimeOver != nil })
            XCTAssertEqual(live.currentWaypointIndex, lastPassed + 1, "\(name): the next one is the target")
        }
    }

    /// Circuits past the same reporting point: marked once, on the first pass, and the circuits after
    /// it neither move the target nor restart the leg timer. The home field is the destination too,
    /// overflown on every circuit, and stays open until the landing.
    @MainActor
    func testCircuitsPastAWaypointMarkItOnce() throws {
        let field = (lat: 47.0, lon: 7.0), point = (lat: 47.03, lon: 7.0)   // 1.8 NM north
        let manager = activePlan([field, point, field])
        let lap: [(lat: Double, lon: Double)] = [field, (47.035, 7.0), (47.035, 7.03), (46.99, 7.03), (46.99, 7.0)]
        let points = gps(track(Array(repeating: lap, count: 4).flatMap { $0 } + [field]))

        var firstPass: Date?
        var timerAfterFirstPass: FlightPlanManager.LegTimerSnapshot?
        for end in stride(from: 2, through: points.count, by: 2) {
            catchUp(manager, Array(points.prefix(end)))
            let plan = try XCTUnwrap(manager.activeFlightPlan)
            guard let passed = plan.waypoints[1].actualTimeOver else { continue }
            if let firstPass {
                XCTAssertEqual(passed, firstPass, "one ATO, the first pass")
                XCTAssertEqual(manager.legTimerSnapshot, timerAfterFirstPass, "the leg timer runs on")
            } else {
                firstPass = passed
                manager.restoreLegTimer(.init(accumulated: 42, startTime: nil))
                timerAfterFirstPass = manager.legTimerSnapshot
            }
            XCTAssertEqual(plan.currentWaypointIndex, 2)
            XCTAssertNil(plan.waypoints[2].actualTimeOver, "the home field waits for the landing")
        }
        let pass = try XCTUnwrap(firstPass)
        XCTAssertEqual(pass.timeIntervalSince(t0), 1.8 / 100 * 3600, accuracy: 20, "on the first lap")
        XCTAssertEqual(manager.activeFlightPlan?.waypoints[0].actualTimeOver, t0, "the departure = takeoff")
    }

    /// A diversion leaves the route: a route waypoint passed on the way to the other field is not the
    /// one the aircraft is flying to. Back on the route, the track catches the plan up.
    @MainActor
    func testNothingIsMarkedWhileDiverting() throws {
        let manager = activePlan([(47.0, 7.0), (47.0, 7.3), (47.0, 7.6), (47.0, 7.9)])
        // Diverting to a field past the second waypoint, flying along the route to it.
        let fixes = track([(47.0, 7.0), (47.0, 7.7), (46.95, 7.75)])
        let points = gps(fixes)
        let turn = points.firstIndex { $0.longitude >= 7.4 }!
        catchUp(manager, Array(points.prefix(turn)))
        XCTAssertEqual(manager.activeFlightPlan?.currentWaypointIndex, 2)

        manager.divert(to: TripPlanner.Aerodrome(ident: "LSZX", name: "Elsewhere", latitude: 46.95, longitude: 7.75,
                                                 elevationFeet: 1500, frequency: nil, isPPR: false))
        for end in stride(from: turn + 2, through: points.count, by: 2) {
            catchUp(manager, Array(points.prefix(end)))
        }
        var plan = try XCTUnwrap(manager.activeFlightPlan)
        XCTAssertNil(plan.waypoints[2].actualTimeOver, "passed abeam, but while diverting")
        XCTAssertEqual(plan.currentWaypointIndex, 2)

        manager.resumeRoute()
        catchUp(manager, points)
        plan = try XCTUnwrap(manager.activeFlightPlan)
        XCTAssertEqual(plan.waypoints[2].actualTimeOver?.timeIntervalSince(t0) ?? -1,
                       seconds(from: 7.0, to: 7.6), accuracy: 20, "back on the route: caught up")
        XCTAssertEqual(plan.currentWaypointIndex, 3)
    }

    /// END FLIGHT fills the times over from the track on the flight's own plan only: a plan left armed
    /// through circuits, or a flight started without it, was not flown.
    @MainActor
    func testEndFlightFillsTheTimesOverOfTheFlightsOwnPlanOnly() throws {
        let points = gps(track([(47.0, 7.0), (47.0, 7.6)]))
        for linked in [true, false] {
            let manager = activePlan([(47.0, 7.0), (47.0, 7.3), (47.0, 7.6)])
            let planId = try XCTUnwrap(manager.activeFlightPlan?.id)
            let flight = Flight(flightPlanId: linked ? planId : nil, gpsTrack: points)

            manager.populateTimingFromFlight(planId, flight: flight, takeoff: t0, landing: points.last!.timestamp)

            let plan = try XCTUnwrap(manager.flightPlans.first { $0.id == planId })
            if linked {
                XCTAssertEqual(plan.waypoints[0].actualTimeOver, t0)
                XCTAssertNotNil(plan.waypoints[1].actualTimeOver)
                XCTAssertEqual(plan.waypoints[2].actualTimeOver, points.last!.timestamp)
            } else {
                XCTAssertTrue(plan.waypoints.allSatisfy { $0.actualTimeOver == nil }, "not this flight's plan")
            }
        }
    }

    // MARK: - In flight: from the GPS pipeline (v6.0.1)

    /// A flight under way with `planManager`'s plan, wired the way `FlightLauncher` wires it. Not
    /// `linked`: circuits, or a flight started without the plan, which `FlightLauncher` starts with no
    /// plan while the plan stays armed.
    @MainActor
    private func trackingFlight(planManager: FlightPlanManager, linked: Bool = true,
                                circuits: Bool = false) -> (LocationManager, AppState) {
        let appState = makeTestAppState()
        appState.startFlight(withAircraft: appState.settings.defaultAirplane,
                             flightPlanId: linked ? planManager.activeFlightPlan?.id : nil, circuitMode: circuits)
        XCTAssertTrue(appState.isFlightActive, "the bundled aircraft starts a flight")
        let locationManager = LocationManager()
        locationManager.authorizationStatus = .authorizedAlways
        locationManager.startTracking(appState: appState, interval: 5, flightPlanManager: planManager)
        addTeardownBlock { @MainActor in locationManager.stopTracking() }
        return (locationManager, appState)
    }

    /// Each fix as the GPS delivers it: received `age` seconds after it was taken.
    @MainActor
    private func fly(_ fixes: [WaypointPassage.Fix], through locationManager: LocationManager,
                     accuracy: CLLocationAccuracy = 5, age: TimeInterval = 0) {
        for fix in fixes {
            let location = CLLocation(coordinate: fix.coordinate, altitude: 900, horizontalAccuracy: accuracy,
                                      verticalAccuracy: 10, course: 90, speed: fix.speed, timestamp: fix.time)
            locationManager.processLocation(location, isOwnFix: true, now: fix.time.addingTimeInterval(age))
        }
    }

    /// Waypoint 0 is the departure aerodrome, where the aircraft sits through the whole preflight. The
    /// 500 m radius marked it there before engine start, and moved on to waypoint 1.
    @MainActor
    func testParkedOnTheDepartureMarksNothingUntilTakeoff() throws {
        let manager = activePlan([(47.0, 7.0), (47.0, 7.3), (47.0, 7.6)])
        let (gpsPipeline, appState) = trackingFlight(planManager: manager)

        // Ten minutes on the ramp, a fix every 10 s, on waypoint 0 itself.
        let ramp = (0..<60).map {
            WaypointPassage.Fix(time: t0.addingTimeInterval(-600 + 10 * Double($0)),
                                coordinate: .init(latitude: 47.0, longitude: 7.0), speed: 0)
        }
        fly(ramp, through: gpsPipeline)
        XCTAssertGreaterThan(appState.currentFlight?.gpsTrack.count ?? 0, 50, "the ramp is recorded")
        XCTAssertNil(manager.activeFlightPlan?.waypoints[0].actualTimeOver, "parked is not a passage")
        XCTAssertEqual(manager.activeFlightPlan?.currentWaypointIndex, 0)

        appState.lineUpTime = t0
        fly(track([(47.0, 7.0), (47.0, 7.6)]), through: gpsPipeline)

        let plan = try XCTUnwrap(manager.activeFlightPlan)
        XCTAssertEqual(plan.waypoints[0].actualTimeOver, t0, "the departure = takeoff")
        XCTAssertEqual(plan.waypoints[1].actualTimeOver?.timeIntervalSince(t0) ?? -1,
                       seconds(from: 7.0, to: 7.3), accuracy: 20)
        XCTAssertNil(plan.waypoints[2].actualTimeOver, "the destination waits for the landing")
        XCTAssertEqual(plan.currentWaypointIndex, 2)
    }

    /// A stale fix (CoreLocation hands out its cached one on start) or an invalid one is not recorded,
    /// so however well placed, it marks nothing. The same positions, received fresh, do.
    @MainActor
    func testAStaleOrInvalidFixMarksNothing() throws {
        let manager = activePlan([(47.0, 7.0), (47.0, 7.3), (47.0, 7.6)])
        let (gpsPipeline, appState) = trackingFlight(planManager: manager)
        appState.lineUpTime = t0
        let fixes = track([(47.0, 7.0), (47.0, 7.6)])
        let passage = t0.addingTimeInterval(seconds(from: 7.0, to: 7.3))

        fly(fixes.filter { $0.time < passage.addingTimeInterval(-30) }, through: gpsPipeline)
        XCTAssertEqual(manager.activeFlightPlan?.currentWaypointIndex, 1, "the departure is behind")

        let beyond = Array(fixes.filter { $0.time > passage.addingTimeInterval(60) }.prefix(3))
        fly(beyond, through: gpsPipeline, age: 30)
        fly(beyond, through: gpsPipeline, accuracy: -1)
        XCTAssertNil(manager.activeFlightPlan?.waypoints[1].actualTimeOver)
        XCTAssertEqual(manager.activeFlightPlan?.currentWaypointIndex, 1)

        fly(beyond, through: gpsPipeline)
        XCTAssertEqual(manager.activeFlightPlan?.waypoints[1].actualTimeOver?.timeIntervalSince(passage) ?? -99,
                       0, accuracy: 30)
        XCTAssertEqual(manager.activeFlightPlan?.currentWaypointIndex, 2)
    }

    /// Only the flight's own plan is marked. A plan left armed through circuits, or through a flight
    /// started without it, is not the one being flown, even flown right over.
    @MainActor
    func testAPlanLeftArmedIsNotMarkedByAnotherFlight() throws {
        for circuits in [true, false] {
            let manager = activePlan([(47.0, 7.0), (47.0, 7.3), (47.0, 7.6)])
            let (gpsPipeline, appState) = trackingFlight(planManager: manager, linked: false, circuits: circuits)
            appState.lineUpTime = t0

            fly(track([(47.0, 7.0), (47.0, 7.6)]), through: gpsPipeline)

            let plan = try XCTUnwrap(manager.activeFlightPlan)
            XCTAssertTrue(plan.waypoints.allSatisfy { $0.actualTimeOver == nil }, circuits ? "circuits" : "flown without it")
            XCTAssertEqual(plan.currentWaypointIndex, 0)
        }
    }
    // MARK: - In flight: the landing (6.2)

    /// Fixes parked at `point`, a minute of them, from `start`: after the landing, on the field.
    private func parked(at point: (lat: Double, lon: Double), from start: Date) -> [WaypointPassage.Fix] {
        (1...6).map { WaypointPassage.Fix(time: start.addingTimeInterval(10 * Double($0)),
                                          coordinate: .init(latitude: point.lat, longitude: point.lon), speed: 0) }
    }

    /// Landed at the route's end: at the next fix its time over is the landing, nothing is left to MARK
    /// and the leg timer stands at the last leg's time, without an automatic-mark notice to take back.
    /// A MARK over the field before the landing gives way to it, as at END FLIGHT. Until 6.2 the
    /// destination waited for END FLIGHT, and MARK offered it on the ramp (ground replay, flight-12).
    @MainActor
    func testTheLandingAtTheRoutesEndIsItsTimeOverAndStopsTheLegTimer() throws {
        for markedOverhead in [false, true] {
            let manager = activePlan([(47.0, 7.0), (47.0, 7.3), (47.0, 7.6)])
            let (gpsPipeline, appState) = trackingFlight(planManager: manager)
            appState.lineUpTime = t0
            manager.startChronometer()
            let flown = track([(47.0, 7.0), (47.0, 7.6)])
            fly(flown, through: gpsPipeline)
            if markedOverhead {
                manager.markWaypoint()
                XCTAssertNotNil(manager.activeFlightPlan?.waypoints[2].actualTimeOver, "MARK over the field")
            } else {
                XCTAssertNil(manager.activeFlightPlan?.waypoints[2].actualTimeOver, "the destination waits for the landing")
            }
            let landing = try XCTUnwrap(flown.last?.time)
            appState.recordFullStop(at: landing)
            fly(Array(parked(at: (47.0, 7.6), from: landing).prefix(1)), through: gpsPipeline)

            let plan = try XCTUnwrap(manager.activeFlightPlan)
            XCTAssertEqual(plan.waypoints[2].actualTimeOver, landing, "overhead MARK \(markedOverhead): the landing")
            XCTAssertEqual(plan.currentWaypointIndex, 3, "nothing left to MARK")
            XCTAssertTrue(manager.isFlightPlanCompleted)
            XCTAssertFalse(manager.isChronometerRunning, "the leg timer stopped")
            if !markedOverhead {
                let passed = try XCTUnwrap(plan.waypoints[1].actualTimeOver)
                XCTAssertEqual(manager.chronometerElapsed, landing.timeIntervalSince(passed), accuracy: 1,
                               "the last leg's time")
            }
            XCTAssertNotEqual(manager.autoMarkNotice?.waypointName, "WP2", "the landing is not a passage to take back")

            // The minute on the field after it changes nothing more.
            let timer = manager.legTimerSnapshot
            fly(parked(at: (47.0, 7.6), from: landing), through: gpsPipeline)
            XCTAssertEqual(manager.activeFlightPlan?.waypoints[2].actualTimeOver, landing)
            XCTAssertEqual(manager.legTimerSnapshot, timer)
        }
    }

    /// A full stop at a field on the way (a precautionary landing beside the second leg) ends nothing:
    /// the destination keeps waiting, and the waypoints flown after the next take-off are still marked.
    @MainActor
    func testALandingOnTheWayEndsNothing() throws {
        let manager = activePlan([(47.0, 7.0), (47.0, 7.3), (47.0, 7.6), (47.0, 7.9)])
        let (gpsPipeline, appState) = trackingFlight(planManager: manager)
        appState.lineUpTime = t0
        let first = track([(47.0, 7.0), (47.0, 7.4)])
        fly(first, through: gpsPipeline)
        let landing = try XCTUnwrap(first.last?.time)
        appState.recordFullStop(at: landing)
        let stop = parked(at: (47.0, 7.4), from: landing)
        fly(stop, through: gpsPipeline)
        XCTAssertNil(manager.activeFlightPlan?.waypoints[3].actualTimeOver, "not the route's end")
        XCTAssertEqual(manager.activeFlightPlan?.currentWaypointIndex, 2)

        fly(track([(47.0, 7.4), (47.0, 7.75)], from: stop.last!.time.addingTimeInterval(10)), through: gpsPipeline)
        let plan = try XCTUnwrap(manager.activeFlightPlan)
        XCTAssertNotNil(plan.waypoints[2].actualTimeOver, "passed after the stop")
        XCTAssertEqual(plan.currentWaypointIndex, 3)
        XCTAssertNil(plan.waypoints[3].actualTimeOver)
    }

    /// The destination taken back after the landing (RESUME LEG on the last leg) is the pilot's to MARK:
    /// the landing doesn't come back to it.
    @MainActor
    func testADestinationTakenBackAfterTheLandingIsLeftToMark() throws {
        let manager = activePlan([(47.0, 7.0), (47.0, 7.3), (47.0, 7.6)])
        let (gpsPipeline, appState) = trackingFlight(planManager: manager)
        appState.lineUpTime = t0
        let flown = track([(47.0, 7.0), (47.0, 7.6)])
        fly(flown, through: gpsPipeline)
        let landing = try XCTUnwrap(flown.last?.time)
        appState.recordFullStop(at: landing)
        let ground = parked(at: (47.0, 7.6), from: landing)
        fly(Array(ground.prefix(1)), through: gpsPipeline)
        XCTAssertEqual(manager.activeFlightPlan?.waypoints[2].actualTimeOver, landing)

        manager.resumeLeg(at: 2)
        fly(Array(ground.dropFirst()), through: gpsPipeline)
        // A minute and more on: past the 15 s cadence, several runs.
        fly(parked(at: (47.0, 7.6), from: ground.last!.time), through: gpsPipeline)
        XCTAssertNil(manager.activeFlightPlan?.waypoints[2].actualTimeOver, "taken back: left to MARK")
        XCTAssertEqual(manager.activeFlightPlan?.currentWaypointIndex, 2)
    }
}
