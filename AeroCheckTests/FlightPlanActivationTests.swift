import XCTest
import CoreLocation
@testable import AeroCheck

/// Activation lifetime (v4.4.0).
///
/// Activating a plan used to be discarded on every `scenePhase == .active` when no flight was
/// running — so activating in the clubhouse and then glancing at another app silently threw the plan
/// away, taking the nav map's route with it. The condition was wrong in principle too: activating
/// before engine start is the normal order of work, not a stale leftover.
///
/// Staleness is now a question of AGE, checked once at launch. These tests pin both halves: a recent
/// activation survives, an abandoned one does not, and an activation with no recorded age is kept
/// (unknown is not evidence of stale).
@MainActor
final class FlightPlanActivationTests: XCTestCase {

    private func plan(named name: String = "LSZQ → LSZB") -> FlightPlan {
        FlightPlan(
            name: name,
            waypoints: [
                FlightPlanWaypoint(name: "LSZQ", coordinate: .init(latitude: 47.392, longitude: 7.030)),
                FlightPlanWaypoint(name: "LSZB", coordinate: .init(latitude: 46.914, longitude: 7.497)),
            ]
        )
    }

    /// A manager on its OWN defaults suite and datastore. The test host shares the app's bundle id, so
    /// building one against `.standard` wrote a synthetic route into the real app's active-plan slot —
    /// a test artifact that then showed up as ACTIVE in the app on that simulator.
    private func manager() -> FlightPlanManager {
        makeTestPlanManager()
    }

    // MARK: - Routes have no date (v5.x)

    /// A route is a path, not an appointment. Saves written before that distinction carried a
    /// departure time, and a route claiming a date is what made several of them all look like
    /// "today's flight plan".
    @MainActor
    func testTheSweepClearsDatesFromRoutesNoFlightFollows() {
        let plans = manager()
        var route = FlightPlan(name: "Route")
        route.plannedDepartureTime = Date()
        plans.add(route)

        plans.clearDatesFromUnflownRoutes(followedPlanIds: [])

        XCTAssertNil(plans.flightPlans.first { $0.id == route.id }?.plannedDepartureTime)
    }

    /// The destructive half. A plan a flight follows keeps its date — that date IS the flight, and
    /// a sweep that ran before the threads loaded would take it away.
    @MainActor
    func testTheSweepLeavesAFlightsOwnDateAlone() {
        let plans = manager()
        var flown = FlightPlan(name: "Flown")
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        flown.plannedDepartureTime = when
        plans.add(flown)

        plans.clearDatesFromUnflownRoutes(followedPlanIds: [flown.id])

        XCTAssertEqual(plans.flightPlans.first { $0.id == flown.id }?.plannedDepartureTime, when)
    }

    /// The active copy is held separately, so clearing only the list would let the next edit write
    /// the date back.
    @MainActor
    func testTheSweepAlsoClearsTheActiveCopy() {
        let plans = manager()
        var route = FlightPlan(name: "Route")
        route.waypoints = [
            FlightPlanWaypoint(name: "LSZQ", coordinate: CLLocationCoordinate2D(latitude: 47.4, longitude: 7.2)),
            FlightPlanWaypoint(name: "LSGY", coordinate: CLLocationCoordinate2D(latitude: 46.8, longitude: 6.6))
        ]
        route.plannedDepartureTime = Date()
        plans.add(route)
        plans.activateFlightPlan(route)
        XCTAssertNotNil(plans.activeFlightPlan?.plannedDepartureTime)

        plans.clearDatesFromUnflownRoutes(followedPlanIds: [])

        XCTAssertNil(plans.activeFlightPlan?.plannedDepartureTime)
    }

    func testActivationStampsTheTime() {
        let manager = manager()
        manager.activateFlightPlan(plan())
        XCTAssertNotNil(manager.activeFlightPlan?.activatedAt,
                        "activation must be dated, or it can never be expired")
    }

    /// The bug. A plan activated moments ago must still be active — this is the pilot who activated
    /// in the clubhouse and then checked the weather app.
    func testRecentActivationSurvivesTheLaunchCheck() {
        let manager = manager()
        manager.activateFlightPlan(plan())

        XCTAssertFalse(manager.expireStaleActivation(), "a fresh activation must not be expired")
        XCTAssertNotNil(manager.activeFlightPlan)
    }

    /// Still active a day later — Friday-evening planning for a Saturday flight.
    func testActivationSurvivesADay() {
        let manager = manager()
        manager.activateFlightPlan(plan())

        let tomorrow = Date().addingTimeInterval(24 * 60 * 60)
        XCTAssertFalse(manager.expireStaleActivation(now: tomorrow))
        XCTAssertNotNil(manager.activeFlightPlan)
    }

    /// But not indefinitely: an activation nobody flew stops framing the nav map eventually.
    func testAbandonedActivationExpires() {
        let manager = manager()
        manager.activateFlightPlan(plan())

        let wellPast = Date().addingTimeInterval(FlightPlanManager.activationLifetime + 60)
        XCTAssertTrue(manager.expireStaleActivation(now: wellPast))
        XCTAssertNil(manager.activeFlightPlan)
    }

    /// The boundary belongs to the pilot: exactly at the lifetime, the plan is still theirs.
    func testExpiryIsExclusiveAtTheBoundary() throws {
        let manager = manager()
        manager.activateFlightPlan(plan())

        // Measured from the stamp the manager actually wrote, not from `Date()` here — the few
        // microseconds between the two would otherwise push this just past the boundary.
        let activatedAt = try XCTUnwrap(manager.activeFlightPlan?.activatedAt)
        let exactly = activatedAt.addingTimeInterval(FlightPlanManager.activationLifetime)
        XCTAssertFalse(manager.expireStaleActivation(now: exactly))
        XCTAssertNotNil(manager.activeFlightPlan)
    }

    /// Plans saved before v4.4.0 carry no `activatedAt`. An unknown age must not be read as an old
    /// one — that would silently deactivate every existing user's plan on upgrade.
    func testActivationWithoutATimestampIsKept() {
        let manager = manager()
        manager.activateFlightPlan(plan())
        manager.activeFlightPlan?.activatedAt = nil

        let wellPast = Date().addingTimeInterval(FlightPlanManager.activationLifetime * 10)
        XCTAssertFalse(manager.expireStaleActivation(now: wellPast))
        XCTAssertNotNil(manager.activeFlightPlan)
    }

    // MARK: - Deactivate confirmation (P2) and the expiry notice (P5)

    /// Nothing recorded yet — the pre-flight case. Deactivating costs nothing, so the UI must not
    /// stop and ask.
    func testFreshlyArmedPlanHasNoProgressToLose() {
        let manager = manager()
        manager.activateFlightPlan(plan())
        XCTAssertFalse(manager.activePlanHasRecordedProgress)
    }

    /// A logged waypoint time is exactly what a deactivate → re-activate round trip destroys, so it
    /// must count as progress.
    func testARecordedWaypointTimeCountsAsProgress() {
        let manager = manager()
        manager.activateFlightPlan(plan())
        manager.activeFlightPlan?.waypoints[0].actualTimeOver = Date()
        XCTAssertTrue(manager.activePlanHasRecordedProgress)
    }

    func testAdvancingPastTheFirstWaypointCountsAsProgress() {
        let manager = manager()
        manager.activateFlightPlan(plan())
        manager.activeFlightPlan?.currentWaypointIndex = 1
        XCTAssertTrue(manager.activePlanHasRecordedProgress)
    }

    /// A running leg timer is progress too — deactivating resets it.
    func testARunningChronometerCountsAsProgress() {
        let manager = manager()
        manager.activateFlightPlan(plan())
        manager.activeFlightPlan?.chronometerStartTime = Date()
        XCTAssertTrue(manager.activePlanHasRecordedProgress)
    }

    /// An expiry must leave enough behind to explain itself and to be undone — the whole point of the
    /// notice is that the app no longer changes this state silently.
    func testExpiryRecordsWhatItRetired() throws {
        let manager = manager()
        manager.activateFlightPlan(plan())
        let wellPast = Date().addingTimeInterval(FlightPlanManager.activationLifetime + 60)

        XCTAssertTrue(manager.expireStaleActivation(now: wellPast))
        let expired = try XCTUnwrap(manager.expiredActivation)
        XCTAssertEqual(expired.routeLabel, "LSZQ → LSZB", "the notice names the route, as the plan list does")
    }

    /// …and re-arming from the notice actually re-arms, rather than just clearing the banner.
    func testRearmingRestoresTheActivation() throws {
        let manager = manager()
        let subject = plan()
        manager.flightPlans = [subject]
        manager.activateFlightPlan(subject)
        _ = manager.expireStaleActivation(now: Date().addingTimeInterval(FlightPlanManager.activationLifetime + 60))
        XCTAssertNil(manager.activeFlightPlan)

        manager.rearmExpiredActivation()

        XCTAssertEqual(manager.activeFlightPlan?.id, subject.id)
        XCTAssertNil(manager.expiredActivation, "the notice clears once acted on")
    }

    /// If the plan was deleted while the notice was up, re-arming clears the notice instead of
    /// resurrecting something that no longer exists.
    func testRearmingADeletedPlanJustClearsTheNotice() {
        let manager = manager()
        manager.activateFlightPlan(plan())          // never added to `flightPlans`
        _ = manager.expireStaleActivation(now: Date().addingTimeInterval(FlightPlanManager.activationLifetime + 60))

        manager.rearmExpiredActivation()

        XCTAssertNil(manager.activeFlightPlan)
        XCTAssertNil(manager.expiredActivation)
    }

    func testNoActivePlanIsNotAnExpiry() {
        XCTAssertFalse(manager().expireStaleActivation())
    }

    /// `activatedAt` must round-trip, or the expiry check reads nil on every launch and the plan
    /// becomes immortal.
    func testActivatedAtSurvivesCodableRoundTrip() throws {
        var subject = plan()
        subject.activatedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FlightPlan.self, from: try encoder.encode(subject))

        XCTAssertEqual(decoded.activatedAt?.timeIntervalSince1970 ?? 0,
                       1_800_000_000, accuracy: 1)
    }

    // MARK: - END FLIGHT and a plan left armed (v6.0.1)

    private func encoded(_ plan: FlightPlan?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(try XCTUnwrap(plan))
    }

    /// Circuits flown with a plan armed for a later flight: END FLIGHT writes nothing into that plan,
    /// attaches none to the circuits, and leaves it armed. The plan a flight was started with gets its
    /// times and is attached, as before. The same steps as `FlightView.performEndFlight`.
    func testEndFlightSettlesOnlyThePlanTheFlightWasStartedWith() throws {
        for startedWithIt in [false, true] {
            let datastore = makeTestDatastore()
            let manager = makeTestPlanManager(datastore: datastore)
            let appState = makeTestAppState(datastore: datastore)
            let armed = plan()
            manager.add(armed)
            manager.activateFlightPlan(armed)
            addTeardownBlock { @MainActor in manager.stopChronometer() }
            let before = try encoded(manager.activeFlightPlan)

            appState.startFlight(withAircraft: appState.settings.defaultAirplane,
                                 flightPlanId: startedWithIt ? armed.id : nil, circuitMode: !startedWithIt)
            let takeoff = Date(timeIntervalSinceNow: -1_800), landing = Date(timeIntervalSinceNow: -60)
            appState.currentFlight?.gpsTrack = [
                GPSPoint(latitude: 47.392, longitude: 7.030, altitude: 450, timestamp: takeoff, speed: 30),
                GPSPoint(latitude: 46.914, longitude: 7.497, altitude: 510, timestamp: landing, speed: 0),
            ]
            appState.lineUpTime = takeoff
            appState.landingTime = landing

            let flight = try XCTUnwrap(appState.currentFlight)
            let flown = manager.settleFlownPlan(flight, takeoff: takeoff, landing: landing, landedAt: nil)
            appState.endFlight(withFlightPlan: flown)
            if flown != nil { manager.deactivateFlightPlan() }

            let logged = try XCTUnwrap(appState.flights.first { $0.id == flight.id })
            if startedWithIt {
                XCTAssertEqual(flown?.id, armed.id)
                XCTAssertEqual(logged.flightPlan?.id, armed.id, "attached to its flight")
                XCTAssertEqual(logged.flightPlan?.timeOff, takeoff)
                XCTAssertNotNil(logged.flightPlan?.waypoints[0].actualTimeOver)
                XCTAssertNil(manager.activeFlightPlan, "its activation ends with the flight")
            } else {
                XCTAssertNil(flown)
                XCTAssertNil(logged.flightPlan, "no plan attached to the circuits")
                XCTAssertEqual(try encoded(manager.activeFlightPlan), before, "still armed, exactly as it was")
                XCTAssertEqual(try encoded(manager.flightPlans.first { $0.id == armed.id }), before)
            }
        }
    }

    /// ABANDON FLIGHT on circuits flown with a plan armed for a later flight: the plan stays armed,
    /// exactly as it was. The same steps as the abandon alert in `FlightView`.
    func testAbandoningCircuitsLeavesAPlanArmedForAnotherFlight() throws {
        let datastore = makeTestDatastore()
        let manager = makeTestPlanManager(datastore: datastore)
        let appState = makeTestAppState(datastore: datastore)
        let armed = plan()
        manager.add(armed)
        manager.activateFlightPlan(armed)
        addTeardownBlock { @MainActor in manager.stopChronometer() }
        let before = try encoded(manager.activeFlightPlan)
        appState.startFlight(withAircraft: appState.settings.defaultAirplane, circuitMode: true)

        let abandoned = appState.currentFlight
        appState.cancelFlight()
        manager.abandonFlownPlan(of: abandoned)

        XCTAssertFalse(appState.isFlightActive)
        XCTAssertEqual(try encoded(manager.activeFlightPlan), before, "still armed, exactly as it was")
    }

    /// ABANDON FLIGHT on a flight started with the plan ends its activation, as it always did.
    func testAbandoningAFlightEndsTheActivationOfItsPlan() throws {
        let datastore = makeTestDatastore()
        let manager = makeTestPlanManager(datastore: datastore)
        let appState = makeTestAppState(datastore: datastore)
        let armed = plan()
        manager.add(armed)
        manager.activateFlightPlan(armed)
        addTeardownBlock { @MainActor in manager.stopChronometer() }
        appState.startFlight(withAircraft: appState.settings.defaultAirplane, flightPlanId: armed.id)

        let abandoned = appState.currentFlight
        appState.cancelFlight()
        manager.abandonFlownPlan(of: abandoned)

        XCTAssertNil(manager.activeFlightPlan)
        XCTAssertEqual(manager.flightPlans.first { $0.id == armed.id }?.isActive, false)
    }

    // MARK: - ETOs from the take-off (6.1)

    private let plannedDeparture = Date(timeIntervalSince1970: 1_790_000_000)
    private let knot = 0.514444

    /// LSZQ → LSZB, planned to leave at `plannedDeparture`, at 5,000 ft and 100 kt.
    private func departingPlan() -> FlightPlan {
        var p = plan()
        p.plannedDepartureTime = plannedDeparture
        for i in p.waypoints.indices {
            p.waypoints[i].altitude = 5000
            p.waypoints[i].plannedGroundSpeed = 100
        }
        p.calculateRouteData()
        return p
    }

    /// A minute of taxi at LSZQ, then a roll starting at `roll` and a climb-out, one fix every 6 s.
    /// `upTo`: the track so far, as it stands in flight.
    private func track(rollingAt roll: Date, upTo end: Date = .distantFuture) -> [GPSPoint] {
        var points: [GPSPoint] = []
        var time = roll.addingTimeInterval(-66), north = 0.0, altitude = 430.0
        func fix(_ speed: Double, climb: Double = 0) {
            time = time.addingTimeInterval(6)
            north += speed * 6
            altitude += climb * 6
            points.append(GPSPoint(latitude: 47.392 + north / 111_320, longitude: 7.030, altitude: altitude,
                                   timestamp: time, speed: speed, horizontalAccuracy: 3.5))
        }
        for _ in 0..<10 { fix(4) }                     // taxi
        fix(30 * knot); fix(48 * knot)                 // the roll
        for _ in 0..<20 { fix(65 * knot, climb: 3.5) } // off and climbing, ~690 ft/min
        return points.filter { $0.timestamp <= end }
    }

    private func measuredTakeoff(rollingAt roll: Date) throws -> Date {
        try XCTUnwrap(TrackTimes.analyze(track: track(rollingAt: roll), engineStart: roll.addingTimeInterval(-600),
                                         engineShutdown: nil).takeoff)
    }

    /// An activated plan and a manager, the flight started with it.
    private func flying() -> (FlightPlanManager, FlightPlan) {
        let manager = manager()
        let p = departingPlan()
        manager.add(p)
        manager.activateFlightPlan(p)
        addTeardownBlock { @MainActor in manager.stopChronometer() }
        return (manager, p)
    }

    /// 29 Sep, three legs: LINE UP never tapped, the take-offs 11.5 to 18.6 minutes after the planned
    /// departures, and the DEST ETO in flight 11 to 18 minutes before the landing. The ETOs count from
    /// the take-off the track shows; the planned departure stays the pilot's.
    func testWithoutLineUpTheETOsCountFromTheTakeoffTheTrackShows() throws {
        let (manager, p) = flying()
        let roll = plannedDeparture.addingTimeInterval(16 * 60)
        let takeoff = try measuredTakeoff(rollingAt: roll)

        manager.followTakeoff(track: track(rollingAt: roll), engineStart: roll.addingTimeInterval(-600),
                                    flightPlanId: p.id)

        let active = try XCTUnwrap(manager.activeFlightPlan)
        XCTAssertEqual(active.etoAnchor, takeoff)
        XCTAssertEqual(active.waypoints.last?.estimatedTimeOver,
                       takeoff.addingTimeInterval(p.waypoints.last!.cumulativeEET!), "the in-flight DEST row")
        XCTAssertEqual(active.plannedDepartureTime, plannedDeparture, "the pilot's planned departure")
        XCTAssertEqual(active.estimatedTimeOver(at: 0), plannedDeparture, "the departure row keeps it")
        XCTAssertEqual(active.waypoints.map(\.estimatedElapsedTime), p.waypoints.map(\.estimatedElapsedTime))
        XCTAssertEqual(manager.flightPlans.first { $0.id == p.id }?.etoAnchor, takeoff, "saved with the plan")
    }

    /// Still on the runway: nothing to count from yet.
    func testTheETOsWaitForTheTakeoff() throws {
        let (manager, p) = flying()
        let roll = plannedDeparture.addingTimeInterval(16 * 60)

        manager.followTakeoff(track: track(rollingAt: roll, upTo: roll.addingTimeInterval(6)),
                                    engineStart: roll.addingTimeInterval(-600), flightPlanId: p.id)

        XCTAssertNil(manager.activeFlightPlan?.etoAnchor)
        XCTAssertEqual(manager.activeFlightPlan?.waypoints.last?.estimatedTimeOver,
                       p.waypoints.last?.estimatedTimeOver)
    }

    /// LINE UP tapped at the holding point: the tap plus 2 minutes is within a minute of the take-off,
    /// and the pilot's own time stands.
    func testLineUpWithinAMinuteOfTheTakeoffStands() throws {
        let (manager, p) = flying()
        let roll = plannedDeparture.addingTimeInterval(16 * 60)
        let lineUp = try measuredTakeoff(rollingAt: roll).addingTimeInterval(-40)

        manager.anchorETOsOnLineUp(lineUp)
        manager.followTakeoff(track: track(rollingAt: roll), engineStart: roll.addingTimeInterval(-600),
                                    flightPlanId: p.id)

        XCTAssertEqual(manager.activeFlightPlan?.etoAnchor, lineUp)
        XCTAssertEqual(manager.activeFlightPlan?.plannedDepartureTime, plannedDeparture,
                       "LINE UP no longer overwrites the planned departure")
    }

    /// LINE UP tapped long before the take-off (a queue at the holding point): the take-off wins, and
    /// a LINE UP tapped after it moves nothing.
    func testLineUpFarFromTheTakeoffGivesWayToIt() throws {
        let (manager, p) = flying()
        let roll = plannedDeparture.addingTimeInterval(16 * 60)
        let takeoff = try measuredTakeoff(rollingAt: roll)

        manager.anchorETOsOnLineUp(takeoff.addingTimeInterval(-5 * 60))
        XCTAssertEqual(manager.activeFlightPlan?.etoAnchor, takeoff.addingTimeInterval(-5 * 60))
        manager.followTakeoff(track: track(rollingAt: roll), engineStart: roll.addingTimeInterval(-600),
                                    flightPlanId: p.id)
        XCTAssertEqual(manager.activeFlightPlan?.etoAnchor, takeoff)

        manager.anchorETOsOnLineUp(takeoff.addingTimeInterval(3 * 60))
        XCTAssertEqual(manager.activeFlightPlan?.etoAnchor, takeoff, "an estimate of what already happened")
    }

    /// Circuits flown with a plan armed for a later flight: not that plan's take-off.
    func testOnlyThePlanTheFlightWasStartedWithCountsFromItsTakeoff() throws {
        let (manager, _) = flying()
        let before = try encoded(manager.activeFlightPlan)
        let roll = plannedDeparture.addingTimeInterval(16 * 60)

        manager.followTakeoff(track: track(rollingAt: roll), engineStart: roll.addingTimeInterval(-600),
                                    flightPlanId: nil)
        manager.followTakeoff(track: track(rollingAt: roll), engineStart: roll.addingTimeInterval(-600),
                                    flightPlanId: UUID())

        XCTAssertEqual(try encoded(manager.activeFlightPlan), before)
    }

    /// END FLIGHT counts the ETOs from the take-off it measured, to the second, even where LINE UP
    /// stood within a minute of it in flight: the nav log printed after the flight is the record.
    func testEndFlightCountsTheETOsFromTheMeasuredTakeoff() throws {
        let (manager, p) = flying()
        let roll = plannedDeparture.addingTimeInterval(16 * 60)
        let takeoff = try measuredTakeoff(rollingAt: roll)
        manager.anchorETOsOnLineUp(takeoff.addingTimeInterval(-40))

        let landing = takeoff.addingTimeInterval(1_500)
        var flight = Flight(airplane: "wt9-dynamic", flightPlanId: p.id, startTime: roll.addingTimeInterval(-900),
                            engineStartTime: roll.addingTimeInterval(-600))
        flight.gpsTrack = track(rollingAt: roll)
        let settled = try XCTUnwrap(manager.settleFlownPlan(flight, takeoff: takeoff, landing: landing, landedAt: nil))

        XCTAssertEqual(settled.etoAnchor, takeoff)
        XCTAssertEqual(settled.timeOff, takeoff)
        XCTAssertEqual(settled.waypoints.last?.estimatedTimeOver,
                       takeoff.addingTimeInterval(p.waypoints.last!.cumulativeEET!))
        XCTAssertEqual(settled.plannedDepartureTime, plannedDeparture)
    }

    /// The 23 Sep plan: planned with forecast winds, then LINE UP recomputed every leg with a cache
    /// that had nothing for that hour, and all 25 legs came back at 100 kt. Moving the ETOs to the
    /// take-off keeps the leg times, and the winds they were computed with.
    func testCountingFromTheTakeoffKeepsTheLegTimesAndTheirWinds() throws {
        FlightPlan.windsAloftProvider = { _, _, _ in FlightPlan.WindAloft(directionDegTrue: 200, speedKt: 25) }
        addTeardownBlock { @MainActor in FlightPlan.windsAloftProvider = nil }
        let (manager, p) = flying()
        XCTAssertNotNil(p.waypoints[0].planningWind)
        FlightPlan.windsAloftProvider = { _, _, _ in nil }                 // after a relaunch: empty

        let roll = plannedDeparture.addingTimeInterval(16 * 60)
        manager.anchorETOsOnLineUp(roll)
        manager.followTakeoff(track: track(rollingAt: roll), engineStart: roll.addingTimeInterval(-600),
                                    flightPlanId: p.id)
        let active = try XCTUnwrap(manager.activeFlightPlan)
        XCTAssertEqual(active.waypoints.map(\.estimatedElapsedTime), p.waypoints.map(\.estimatedElapsedTime))
        XCTAssertEqual(active.waypoints.map(\.planningWind), p.waypoints.map(\.planningWind))

        // An edit in flight recomputes the legs: with no forecast to be had, the planned wind stays.
        var edited = active
        edited.waypoints[1].remarks = "Joining downwind"
        edited.calculateRouteData()
        XCTAssertEqual(edited.waypoints.map(\.estimatedElapsedTime), p.waypoints.map(\.estimatedElapsedTime))
        XCTAssertEqual(edited.etoAnchor, active.etoAnchor)
    }

    /// A new activation is a new flight: the ETOs count from the planned departure again.
    func testActivatingAgainCountsFromThePlannedDeparture() throws {
        let (manager, p) = flying()
        manager.anchorETOsOnLineUp(plannedDeparture.addingTimeInterval(600))
        manager.deactivateFlightPlan()
        let flown = try XCTUnwrap(manager.flightPlans.first { $0.id == p.id })
        XCTAssertNotNil(flown.etoAnchor)

        manager.activateFlightPlan(flown)

        XCTAssertNil(manager.activeFlightPlan?.etoAnchor)
        XCTAssertEqual(manager.activeFlightPlan?.waypoints.last?.estimatedTimeOver,
                       p.waypoints.last?.estimatedTimeOver)
    }

    /// A route no flight follows loses the take-off of the flight flown on it with its date: it would
    /// otherwise keep printing that flight's times.
    func testTheSweepClearsATakeoffFromARouteNoFlightFollows() {
        let plans = manager()
        var route = departingPlan()
        route.etoAnchor = plannedDeparture.addingTimeInterval(600)
        route.retimeETOs()
        plans.add(route)

        plans.clearDatesFromUnflownRoutes(followedPlanIds: [])

        let swept = plans.flightPlans.first { $0.id == route.id }
        XCTAssertNil(swept?.etoAnchor)
        XCTAssertTrue(swept?.waypoints.allSatisfy { $0.estimatedTimeOver == nil } ?? false)
    }

    // MARK: - The departure's time over is the take-off (6.1)

    /// Without LINE UP the catch-up marked the departure at the first fix at ~39 kt, with it at the
    /// tap plus 2 minutes; once the track shows the take-off, the departure's time over is the take-off
    /// and the first leg's timer starts from it.
    func testInFlightTheDeparturesTimeOverBecomesTheTakeoff() throws {
        for lineUp in [nil, 120.0] {
            let (manager, p) = flying()
            manager.startChronometer()
            let roll = plannedDeparture.addingTimeInterval(16 * 60)
            let takeoff = try measuredTakeoff(rollingAt: roll)
            let early = track(rollingAt: roll, upTo: roll.addingTimeInterval(12))   // off, not 100 ft yet

            manager.followTakeoff(track: early, engineStart: roll.addingTimeInterval(-600), flightPlanId: p.id)
            manager.catchUpWaypointPassages(track: early, takeoff: lineUp.map { roll.addingTimeInterval($0) },
                                            flightPlanId: p.id)
            let before = try XCTUnwrap(manager.activeFlightPlan?.waypoints[0].actualTimeOver)
            XCTAssertNotEqual(before, takeoff, "the catch-up's own estimate, before the take-off is known")

            manager.followTakeoff(track: track(rollingAt: roll), engineStart: roll.addingTimeInterval(-600),
                                  flightPlanId: p.id)

            XCTAssertEqual(manager.activeFlightPlan?.waypoints[0].actualTimeOver, takeoff)
            XCTAssertEqual(manager.activeFlightPlan?.currentWaypointIndex, 1)
            XCTAssertEqual(manager.activeFlightPlan?.chronometerStartTime, takeoff,
                           "the first leg is timed from the take-off")
        }
    }

    /// Found before the catch-up marks the departure: the catch-up marks it at the take-off at once.
    func testTheCatchUpMarksTheDepartureAtTheTakeoffOnceItIsKnown() throws {
        let (manager, p) = flying()
        let roll = plannedDeparture.addingTimeInterval(16 * 60)
        let takeoff = try measuredTakeoff(rollingAt: roll)

        manager.followTakeoff(track: track(rollingAt: roll), engineStart: roll.addingTimeInterval(-600),
                              flightPlanId: p.id)
        manager.catchUpWaypointPassages(track: track(rollingAt: roll), takeoff: roll.addingTimeInterval(120),
                                        flightPlanId: p.id)

        XCTAssertEqual(manager.activeFlightPlan?.waypoints[0].actualTimeOver, takeoff,
                       "not LINE UP's estimate once the take-off is known")
    }

    /// END FLIGHT: the departure's time over and Time OFF are the measured take-off, whatever the
    /// flight recorded in flight or an earlier flight of the same route left in Time OFF.
    func testEndFlightWritesTheMeasuredTakeoffAsTheDeparturesTimeOverAndTimeOff() throws {
        let manager = manager()
        var route = departingPlan()
        route.timeOff = plannedDeparture.addingTimeInterval(-86_400)          // flown yesterday
        manager.add(route)
        manager.activateFlightPlan(route)
        addTeardownBlock { @MainActor in manager.stopChronometer() }
        let roll = plannedDeparture.addingTimeInterval(16 * 60)
        let takeoff = try measuredTakeoff(rollingAt: roll)
        let early = track(rollingAt: roll, upTo: roll.addingTimeInterval(12))
        manager.catchUpWaypointPassages(track: early, takeoff: nil, flightPlanId: route.id)
        XCTAssertNotEqual(manager.activeFlightPlan?.waypoints[0].actualTimeOver, takeoff)

        var flight = Flight(airplane: "wt9-dynamic", flightPlanId: route.id, startTime: roll.addingTimeInterval(-900),
                            engineStartTime: roll.addingTimeInterval(-600))
        flight.gpsTrack = track(rollingAt: roll)
        let settled = try XCTUnwrap(manager.settleFlownPlan(flight, takeoff: takeoff,
                                                            landing: takeoff.addingTimeInterval(1_500), landedAt: nil))

        XCTAssertEqual(settled.waypoints[0].actualTimeOver, takeoff)
        XCTAssertEqual(settled.timeOff, takeoff)
    }
}
