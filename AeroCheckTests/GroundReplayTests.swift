import XCTest
import CoreLocation
@testable import AeroCheck

/// The ground replays (GroundReplay.swift): the replay's own pieces, and whole flights replayed through
/// the chain the app runs in flight, without a view: LocationManager → FlightEventDetector → the cues →
/// AppState, on the flight's clock (`FlightClock.virtual`, stopped at each fix's time). A headless pilot
/// answers the check slot the way the UI tests tap it. The flights are the UI tests' scenarios
/// (AeroCheckUITests/Scenarios, scripts/flightsim) and a committed corpus fixture; the expectations are
/// the Python referee's, written into each scenario.
@MainActor
final class GroundReplayTests: XCTestCase {

    override func tearDown() {
        // The clock is global: never leave a test's on for the next.
        FlightClock.virtual = nil
        super.tearDown()
    }

    // MARK: - The clock

    func testTheVirtualClockRunsFasterAndTheUndoWindowStaysThePilots() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        FlightClock.virtual = .init(wallAnchor: Date(), virtualAnchor: start, rate: 10)
        let now = FlightClock.now
        XCTAssertEqual(now.timeIntervalSince(start), 0, accuracy: 1)
        let wall = Date()
        let clock = FlightClock.virtual!
        XCTAssertEqual(clock.virtual(at: wall.addingTimeInterval(3)).timeIntervalSince(clock.virtual(at: wall)), 30, accuracy: 0.001)
        // Sixty virtual seconds ago is six of the pilot's: the toast's six seconds are the pilot's.
        XCTAssertEqual(FlightClock.pilotSeconds(since: FlightClock.now.addingTimeInterval(-60)), 6, accuracy: 0.5)
        FlightClock.virtual = nil
        XCTAssertEqual(FlightClock.now.timeIntervalSinceNow, 0, accuracy: 1, "the wall clock without a replay")
    }

    // MARK: - The track and the holds

    func testFixesAreSortedRebasedAndTakeTheirCourseFromTheTrack() {
        let rows: [[Double?]] = [
            [1_000_010, 47.0010, 7.0, 500, 10, 5],         // north of the first: 0°
            [1_000_000, 47.0000, 7.0, 500, 0, 5],
            [1_000_020, 47.0010, 7.0015, 500, 10, 5, 123], // its own course is kept
            [1_000_030, 47.0010, 7.0030, 500, 10, 5],      // east of the last that moved: 90°
            [1_000_040, 47.0010, 7.0030, 500, 0, 5],       // parked: the course it had
            [1_000_050, 47.0010, 7.0030, 500, 0],          // too short: dropped
        ]
        let fixes = GroundReplayFix.fixes(from: rows)
        XCTAssertEqual(fixes.map(\.t), [0, 10, 20, 30, 40])
        XCTAssertEqual(fixes[0].course, 0, accuracy: 1, "before it moves: the first bearing")
        XCTAssertEqual(fixes[1].course, 0, accuracy: 1)
        XCTAssertEqual(fixes[2].course, 123)
        XCTAssertEqual(fixes[3].course, 90, accuracy: 1)
        XCTAssertEqual(fixes[4].course, 90, accuracy: 1)
        XCTAssertNil(fixes[0].baroRelativeM)
        let location = fixes[1].location(at: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(location.timestamp, Date(timeIntervalSince1970: 5), "stamped with the replay's clock")
    }

    // MARK: - The aerodromes

    /// The replay's aerodromes stay through the store's later passes. Since 6.2.0 a pass rebuilds the
    /// store from its backbone, and the launch's OpenAIP merge, run after the injection, emptied it again
    /// on a fresh simulator: no field to anchor the take-off to, so the climb check showed due on the runway.
    func testTheReplaysAerodromesSurviveTheStoresLaterPasses() async {
        let store = makeTestAirportStore(openAIPAirports: makeTestOpenAIPAirportLayer { _ in [] })
        let field = GroundReplayScenario.Aerodrome(ident: "LSZQ", name: nil, lat: 47.3949, lon: 7.0321,
                                                  elev: 1880, type: "small_airport")
        store.injectForReplay([GroundReplay.airport(field)])
        await store.applyOpenAIPMergeIfAvailable()
        await store.ensureLoaded()
        let near = store.findNearestAirports(to: CLLocationCoordinate2D(latitude: 47.395, longitude: 7.032),
                                             limit: 3, maxDistanceNm: 5, types: AirportType.fixedWing)
        XCTAssertEqual(near.map(\.ident), ["LSZQ"], "the launch's merge and a later load keep the replay's field")
    }

    func testTheReplayWaitsAtEachHoldUntilThePilotReleasesIt() {
        var cursor = GroundReplayCursor(duration: 600, holds: [
            .init(t: 0, condition: .engineStart),
            .init(t: 100, condition: .lineUp),
        ])
        var flight = GroundReplayCursor.FlightState()
        cursor.advance(by: 50, flight: flight)
        XCTAssertEqual(cursor.t, 0, "parked until ENGINE START")
        flight.isFlightActive = true
        flight.engineStarted = true
        cursor.advance(by: 150, flight: flight)
        XCTAssertEqual(cursor.t, 100, "at the holding point")
        XCTAssertEqual(cursor.waitingAt?.condition, .lineUp)
        flight.phase = .lineUp                         // NEXT to the line-up check also lets it go
        cursor.advance(by: 30, flight: flight)
        XCTAssertEqual(cursor.t, 130)
        cursor.advance(by: 1000, flight: flight)
        XCTAssertEqual(cursor.t, 600, "stops at the end of the track")
        XCTAssertEqual(GroundReplayCursor.Condition("phase:climb"), .phase(.climb))
        XCTAssertNil(GroundReplayCursor.Condition("whenever"))
    }

    /// A stop-and-go waits for the line-up check itself: the Cockpit is past it already (on the landing
    /// check), and the card's CONFIRM takes it back to TAXI.
    func testAStopAndGoWaitsForTheLineUpCheckItself() {
        XCTAssertEqual(GroundReplayCursor.Condition("phaseIs:lineUp"), .phaseIs(.lineUp))
        var cursor = GroundReplayCursor(duration: 600, holds: [.init(t: 100, condition: .phaseIs(.lineUp))])
        var flight = GroundReplayCursor.FlightState(isFlightActive: true, engineStarted: true, linedUp: true,
                                                    phase: .landing)
        cursor.advance(by: 150, flight: flight)
        XCTAssertEqual(cursor.t, 100, "on the landing check, past the line-up: still waiting")
        flight.phase = .taxi
        cursor.advance(by: 10, flight: flight)
        XCTAssertEqual(cursor.t, 100, "CONFIRM: TAXI, still waiting")
        flight.phase = .lineUp
        cursor.advance(by: 10, flight: flight)
        XCTAssertEqual(cursor.t, 110, "the line-up check again: away")
    }

    // MARK: - Whole flights through the chain

    /// LSZQ → INS → LSGC, every check done as it comes due: the detector, its cues and the check slot
    /// agree with the referee; the landed card at LSGC, YES; the flight ends with one landing and every
    /// check done.
    func testCrossCountryEveryCheckOnTimeThroughTheWholeChain() throws {
        let flight = try HeadlessFlight(test: self, scenario: "xc-all-checks")
        flight.fly()
        let expected = try XCTUnwrap(flight.scenario.expected)

        XCTAssertEqual(flight.events.map(\.type.code), expected.events.map(\.type))
        for (got, want) in zip(flight.events, expected.events) {
            XCTAssertEqual(flight.track(got.timestamp), want.t, accuracy: 15, "\(want.type) at \(want.t) s")
        }
        flight.assertCuesMatchTheReferee()

        // The slot came due in order, each about when its cue came.
        flight.assertSlot(.climb, tone: .due, near: expected.cue("takeoff"))
        flight.assertSlot(.cruise, tone: .due, near: expected.cue("levelOff"))
        flight.assertSlot(.descent, tone: .due, near: expected.cue("descent"))
        flight.assertSlot(.approach, tone: .due, near: expected.cue("approach"))
        flight.assertSlot(.landing, tone: .quiet, near: expected.cue("circuit"))
        let fredaAtLigerz = flight.slots.first { $0.slot.action == .confirmFreda }
        XCTAssertEqual(fredaAtLigerz.map { $0.t } ?? 0, flight.scenario.marks["wp1"]!, accuracy: 20,
                       "FREDA due at INS, passed more than 5 min after the cruise check")
        XCTAssertEqual(flight.landedCards.map(\.aerodrome), ["LSGC"])

        let saved = try XCTUnwrap(flight.endedFlight)
        XCTAssertEqual(saved.fullStopCount, 1)
        let debrief = try XCTUnwrap(CheckDebrief.make(for: saved))
        XCTAssertTrue(debrief.allDone, "every check done: \(debrief.noted.map { "\($0.phase) \($0.status)" })")
        XCTAssertEqual(debrief.rows.first { $0.phase == .landing }?.status, .confirmedAfterLanding)
        XCTAssertEqual(debrief.freda?.done.count, 1)
        XCTAssertTrue(debrief.freda?.missed.isEmpty ?? true)
    }

    /// The same route with the climb check left open through the level-off, gone NEXT past, and NOT SURE
    /// on the landed card: debrief-2's lines.
    func testClimbCheckLeftOpenIsOwedThenSkippedInTheDebrief() throws {
        let flight = try HeadlessFlight(test: self, scenario: "xc-climb-owed")
        flight.leaveOpen = [.climb]
        flight.landedAnswer = .notSure
        flight.onLevelOff = { appState in
            XCTAssertEqual(appState.cueTiming(for: .climb), .owed)
            XCTAssertEqual(appState.owedCue(for: .climb), .levelOff)
            appState.nextPhase()                       // NEXT past it, the review's CONTINUE
        }
        flight.fly()
        flight.assertSlot(.climb, tone: .owed, near: flight.scenario.expected?.cue("levelOff"))
        let saved = try XCTUnwrap(flight.endedFlight)
        let debrief = try XCTUnwrap(CheckDebrief.make(for: saved))
        let climb = try XCTUnwrap(debrief.rows.first { $0.phase == .climb })
        XCTAssertEqual(climb.status, .owed, "owed, never done")
        XCTAssertEqual(climb.cue, .levelOff, "you levelled off with it open")
        XCTAssertNotNil(climb.owedAt)
        XCTAssertNotNil(climb.at, "skipped hh:mm")
        XCTAssertEqual(debrief.rows.first { $0.phase == .landing }?.status, .notSure)
        XCTAssertFalse(debrief.allDone)
    }

    /// Circuits: a touch-and-go, two stop-and-goes and a full stop. The circuits keep the detector's cards
    /// (CONFIRM: TAXI after a full stop), never the landed card, and there is no FREDA.
    func testCircuitsKeepTheirCardsAndHaveNoFreda() throws {
        let flight = try HeadlessFlight(test: self, scenario: "circuits-stop-and-go", circuits: true)
        flight.fly()
        let expected = try XCTUnwrap(flight.scenario.expected)
        XCTAssertEqual(flight.events.map(\.type.code), expected.events.map(\.type))
        XCTAssertTrue(flight.landedCards.isEmpty, "no landed card in circuits")
        XCTAssertEqual(flight.cardsConfirmed, ["TG", "FS", "FS", "FS"])
        XCTAssertEqual(flight.phaseAfterFullStops, [.taxi, .taxi, .taxi], "CONFIRM on the full-stop card: TAXI")
        XCTAssertFalse(flight.fredaEverRan, "no FREDA in circuits")
        let saved = try XCTUnwrap(flight.endedFlight)
        XCTAssertEqual(saved.touchAndGoCount, 1)
        XCTAssertEqual(saved.fullStopCount, 3)
    }

    /// The committed LSGN → LSZQ leg of 29 Sep (anonymised, no route): a real track, replayed the same way,
    /// gives its one full stop as a landed card at LSZQ.
    func testARecordedFlightGivesItsLandedCard() throws {
        let flight = try HeadlessFlight(test: self, fixture: "AeroCheck_20260929_1406_F-HVXA")
        flight.fly()
        XCTAssertEqual(flight.events.map(\.type.code), ["FS"])
        XCTAssertEqual(flight.landedCards.map(\.aerodrome), ["LSZQ"])
        XCTAssertEqual(try XCTUnwrap(flight.endedFlight).fullStopCount, 1)
    }

    /// flight-12's landing at LSGC, the route's end: from the fix after the landed card's answer, LSGC's ATO
    /// is the landing, MARK has nothing left to offer and the leg timer stands at the last leg's time. MAP's
    /// band holds what AFTER LANDING has with the route flown: MARK dimmed, Divert off. Until 6.2 the
    /// destination waited for END FLIGHT, and MAP offered MARK LSGC on the ramp, the leg timer running.
    func testTheLandingAtTheRoutesEndIsItsATOAndEndsTheRoute() throws {
        let flight = try HeadlessFlight(test: self, scenario: "xc-all-checks")
        var seen: (plan: FlightPlan, landing: Date, timer: FlightPlanManager.LegTimerSnapshot?, elapsed: TimeInterval,
                   roles: [ActSlotRole], phase: ChecklistPhase, notice: String?)?
        flight.onFix = { [unowned flight] _ in
            let plans = flight.plans, appState = flight.appState
            // START LEG at the line-up, as the pilot of flight-16 had it.
            if appState.lineUpTime != nil, !plans.isChronometerRunning, plans.chronometerElapsed < 0.5 {
                plans.startChronometer()
            }
            // The first fix after the answer (the card is answered after the chain takes a fix).
            guard seen == nil, let landing = appState.landingTime, let plan = plans.activeFlightPlan else { return }
            seen = (plan, landing, plans.legTimerSnapshot, plans.chronometerElapsed,
                    ActBandRoles.make(page: .map, appState: appState, plans: plans), appState.currentPhase,
                    plans.autoMarkNotice?.waypointName)
        }
        flight.fly()
        XCTAssertEqual(flight.landedCards.map(\.aerodrome), ["LSGC"])
        let after = try XCTUnwrap(seen, "a landing recorded in flight")
        let destination = try XCTUnwrap(after.plan.waypoints.last)
        XCTAssertEqual(destination.name, "LSGC", "the route's end")
        XCTAssertEqual(destination.actualTimeOver, after.landing, "LSGC's ATO is the landing")
        XCTAssertEqual(after.plan.currentWaypointIndex, after.plan.waypoints.count, "nothing left to MARK")
        XCTAssertNil(after.timer?.startTime, "the leg timer stopped")
        let ins = try XCTUnwrap(after.plan.waypoints[1].actualTimeOver, "INS passed")
        XCTAssertEqual(after.elapsed, after.landing.timeIntervalSince(ins), accuracy: 1,
                       "at the last leg's time, INS to the landing")
        XCTAssertEqual(after.phase, .afterLanding)
        XCTAssertEqual(after.roles, [.checkSlot, .mark, .divert(enabled: false, diverting: false), .more(withDivert: false)],
                       "MARK dimmed, Divert off: the route flown")
        XCTAssertNotEqual(after.notice, "LSGC", "the landing is not a passage to take back")
    }

    /// undo-5's relaunch: the app killed and launched again mid-flight. On route-vrps with the climb check
    /// left open, in cruise (the climb check owed) and over LSZQ at circuit height (the landing check
    /// shown, GO AROUND in MAP's band); on xc-all-checks in cruise, FREDA counting; in circuits, on a
    /// downwind and on the ground after a stop-and-go, where the next take-off is a new leg. From each
    /// relaunch to the end of the flight, the check slot and MAP's band read as they do on the same
    /// flight flown straight through, and the flight ends with the same records and landings. Until 6.2
    /// the detector started again on the ground, read the first fast fixes as a take-off and its cues as
    /// a new leg: the owed climb check showed as due, GO AROUND gave way to MARK, and the debrief had the
    /// climb check owed three times; and FREDA counted its ten minutes again from the restore.
    func testARelaunchMidFlightKeepsTheChecksAndTheBandAsTheyWere() throws {
        struct Seen: Equatable {
            let slot: CheckSlot
            let roles: [ActSlotRole]
            let owed: [ChecklistPhase: FlightCue]
        }
        /// The slot as drawn: its time to the minute ("FREDA ✓ 12:01").
        func drawn(_ slot: CheckSlot) -> CheckSlot {
            var drawn = slot
            if case .fredaCountsFrom(let since, let at) = slot.title {
                drawn.title = .fredaCountsFrom(since, Date(timeIntervalSince1970: (at.timeIntervalSince1970 / 60).rounded(.down) * 60))
            }
            return drawn
        }
        func fly(_ name: String, circuits: Bool, leaveOpen: Set<ChecklistPhase>, relaunchingAt relaunches: [Double]) throws
            -> (seen: [Double: Seen], flight: HeadlessFlight) {
            let flight = try HeadlessFlight(test: self, scenario: name, circuits: circuits)
            flight.leaveOpen = leaveOpen
            flight.relaunches = relaunches
            var seen: [Double: Seen] = [:]
            flight.onFix = { [unowned flight] fix in
                let appState = flight.appState
                seen[fix.t] = Seen(slot: drawn(CockpitCheckSlot.slot(for: appState)),
                                   roles: ActBandRoles.make(page: .map, appState: appState, plans: flight.plans),
                                   owed: ChecklistPhase.allCases.reduce(into: [:]) { owed, phase in
                                       owed[phase] = appState.owedCue(for: phase)
                                   })
            }
            flight.fly()
            return (seen, flight)
        }
        func state(_ seen: [Double: Seen], at t: Double) throws -> Seen {
            try XCTUnwrap(seen.filter { $0.key >= t }.min { $0.key < $1.key }?.value)
        }
        let flights: [(name: String, circuits: Bool, leaveOpen: Set<ChecklistPhase>, relaunches: [Double])] = [
            ("route-vrps", false, [.climb], [1000, 1700]),
            ("xc-all-checks", false, [], [1100]),
            ("circuits-stop-and-go", true, [], [760, 990]),
        ]
        for (name, circuits, leaveOpen, relaunches) in flights {
            let straight = try fly(name, circuits: circuits, leaveOpen: leaveOpen, relaunchingAt: [])
            let relaunched = try fly(name, circuits: circuits, leaveOpen: leaveOpen, relaunchingAt: relaunches)

            // What the relaunches are about.
            if name == "xc-all-checks" {
                let cruise = try state(straight.seen, at: relaunches[0]).slot
                guard case .fredaCountsFrom(.cruiseCheck, _) = cruise.title else {
                    return XCTFail("in cruise, FREDA counting from the cruise check: \(cruise)")
                }
            } else if !circuits {
                XCTAssertEqual(try state(straight.seen, at: relaunches[0]).owed[.climb], .levelOff,
                               "the climb check owed in cruise")
                XCTAssertEqual(try state(straight.seen, at: relaunches[1]).roles,
                               [.checkSlot, .goAround, .touchAndGo, .more(withDivert: true)], "GO AROUND over LSZQ")
            } else {
                let marks = straight.flight.scenario.marks
                XCTAssertTrue((marks["downwind2"]!..<marks["base2"]!).contains(relaunches[0]), "on the second downwind")
                let downwind = try state(straight.seen, at: relaunches[0]).slot
                XCTAssertEqual([downwind.phase, downwind.tone] as [AnyHashable], [ChecklistPhase.landing, CheckSlot.Tone.idle],
                               "the approach check done, the landing check next")
                XCTAssertTrue((marks["stopped"]!..<marks["takeoffRoll2"]!).contains(relaunches[1]),
                              "stopped after the stop-and-go, before the next take-off roll")
            }

            // Give or take the relaunch's own cadence: the passages run 15 s from it, and the detector every
            // 5 s, not on the straight flight's beat. A state seen within 15 s of the same moment flown
            // straight through is the same state; the bug kept them apart for minutes.
            var differ: [String] = []
            for t in straight.seen.keys.sorted() where t >= relaunches[0] {
                guard let want = straight.seen[t], let got = relaunched.seen[t], want != got,
                      !straight.seen.contains(where: { abs($0.key - t) <= 15 && $0.value == got }) else { continue }
                if want.slot != got.slot { differ.append("\(Int(t)) s, the slot: \(got.slot), straight: \(want.slot)") }
                if want.roles != got.roles { differ.append("\(Int(t)) s, MAP's band: \(got.roles), straight: \(want.roles)") }
                if want.owed != got.owed { differ.append("\(Int(t)) s, owed: \(got.owed), straight: \(want.owed)") }
            }
            XCTAssertTrue(differ.isEmpty, "\(name), after a relaunch:\n\(differ.prefix(12).joined(separator: "\n"))")
            func ended(_ flight: HeadlessFlight) -> [String] {
                let saved = flight.endedFlight
                return (saved?.checkRecords ?? []).map { "\($0.phase.map { "\($0)" } ?? "?") \($0.kind)" }
                    + ["TG \(saved?.touchAndGoCount ?? -1)", "FS \(saved?.fullStopCount ?? -1)"]
            }
            XCTAssertEqual(ended(relaunched.flight), ended(straight.flight), "\(name): the records and the landings")
        }
    }

    // MARK: - OFF ROUTE (6.2, MAP's status slot)

    /// OFF ROUTE never speaks on the routes the replays fly (plan PR 4), fed at every fix as the Cockpit
    /// feeds it. route-vrps with the UI test's own taps: SAIGNELEGIER marked on its own and taken back, a
    /// minute flown past it, MARK, then RESUME LEG on ST-URSANNE once marked; xc-planned, whose departure
    /// joins the leg to INS 9 NM out. A rule on the leg flown alone, as 6.2 first had it, would have spoken
    /// on both: asked too, so the replays are a test of something.
    func testOffRouteNeverSpeaksOnTheRoutesTheReplaysFly() throws {
        for name in ["route-vrps", "xc-planned"] {
            let flight = try HeadlessFlight(test: self, scenario: name)
            let watch = OffRouteWatch(flight: flight, pilotTakesBackSaignelegier: name == "route-vrps")
            flight.fly()
            XCTAssertEqual(watch.spoke, [], "\(name): OFF ROUTE")
            XCTAssertFalse(watch.legAlone.isEmpty, "\(name): the leg flown alone would have said OFF ROUTE")
            if name == "route-vrps" {
                XCTAssertEqual(watch.taps, ["UNDO SAIGNELEGIER", "MARK SAIGNELEGIER", "RESUME LEG ST-URSANNE"])
            }
        }
    }

    /// And it speaks where a flight does leave its route: the descent abandoned for another field, the
    /// route still armed, miles off it.
    func testOffRouteSpeaksWhenTheFlightLeavesTheRoute() throws {
        let flight = try HeadlessFlight(test: self, scenario: "xc-descent-abandoned")
        let watch = OffRouteWatch(flight: flight)
        flight.fly()
        XCTAssertFalse(watch.spoke.isEmpty, "OFF ROUTE once off the route")
        XCTAssertGreaterThan(watch.farthest, 5, "miles off: \(watch.farthest) NM")
    }

    /// A barometric altitude in the scenario reaches the recorded track, as the device's barometer does.
    func testABarometricAltitudeIsRecordedWithTheFix() throws {
        let appState = makeTestAppState()
        appState.startFlight(withAircraft: appState.settings.defaultAirplane)
        let location = LocationManager()
        location.authorizationStatus = .authorizedAlways
        location.startTracking(appState: appState, interval: 5)
        addTeardownBlock { @MainActor in location.stopTracking() }
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        FlightClock.virtual = .init(wallAnchor: Date(), virtualAnchor: t, rate: 0)
        let fix = GroundReplayFix(t: 0, latitude: 47.39, longitude: 7.03, altitudeM: 572, speedMS: 0,
                                  horizontalAccuracy: 4, course: -1, baroRelativeM: 1.25)
        location.feedReplayFix(fix.location(at: t), baroRelativeAltitudeM: fix.baroRelativeM)
        XCTAssertEqual(appState.currentFlight?.gpsTrack.last?.baroAltitude, 1.25)
        XCTAssertEqual(appState.currentFlight?.gpsTrack.last?.timestamp, t)
    }
}

// MARK: - The headless pilot

/// OFF ROUTE through a headless flight: the Cockpit's rule fed every fix (GPS good: the replay's fixes are
/// the device's own), and beside it the rule on the leg flown alone. With `pilotTakesBackSaignelegier`,
/// the taps of `WaypointMarkingUITests`: UNDO on SAIGNELEGIER marked on its own, MARK a minute later,
/// RESUME LEG on ST-URSANNE once it is marked.
@MainActor
private final class OffRouteWatch {
    private(set) var spoke: [String] = []
    private(set) var legAlone: [String] = []
    private(set) var farthest = 0.0
    private(set) var taps: [String] = []
    private var rule = OffRouteRule()
    private var wasOffTheLeg = false

    init(flight: HeadlessFlight, pilotTakesBackSaignelegier: Bool = false) {
        var takenBackAt: Double?
        flight.onFix = { [unowned self, unowned flight] fix in
            let plans = flight.plans
            if pilotTakesBackSaignelegier {
                if takenBackAt == nil, let notice = plans.autoMarkNotice, notice.waypointName == "SAIGNELEGIER" {
                    plans.undoAutoMark(notice)
                    takenBackAt = fix.t
                    self.taps.append("UNDO SAIGNELEGIER")
                }
                if let at = takenBackAt, self.taps.count == 1, fix.t >= at + 60 {
                    plans.markWaypoint()
                    self.taps.append("MARK SAIGNELEGIER")
                }
                if self.taps.count == 2, let plan = plans.activeFlightPlan, plan.waypoints.count > 4,
                   plan.waypoints[4].actualTimeOver != nil {
                    plans.resumeLeg(at: 4)
                    self.taps.append("RESUME LEG ST-URSANNE")
                }
            }
            let input = OffRouteRule.Input(
                plan: plans.activeFlightPlan, aircraft: CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude),
                circuits: false, lineUpTime: flight.appState.lineUpTime, landingTime: flight.appState.landingTime,
                isTracking: true, signal: .good, isSimulating: false)
            if let nm = self.rule.update(input) {
                self.spoke.append("\(Int(fix.t)) s: \(String(format: "%.1f", nm)) NM")
                self.farthest = max(self.farthest, nm)
            }
            let alone = OffRouteRule.Input(leg: input.leg, aircraft: input.aircraft, diverting: input.diverting,
                                           airborne: input.airborne, gpsGood: true)
            let off = OffRouteRule.evaluate(alone, wasOffRoute: self.wasOffTheLeg)
            self.wasOffTheLeg = off != nil
            if let off { self.legAlone.append("\(Int(fix.t)) s: \(String(format: "%.1f", off)) NM") }
        }
    }
}

private extension FlightEventType {
    /// The referee's names.
    var code: String {
        switch self {
        case .fullStop: return "FS"
        case .touchAndGo: return "TG"
        case .goAround: return "GA"
        }
    }
}

/// What a scenario file says the referee expects (the app reads only the flight).
private struct ScenarioFile: Decodable {
    struct Expected: Decodable {
        struct Event: Decodable { let type: String; let t: Double }
        struct Cue: Decodable { let type: String; let t: Double; let implied: Bool }
        let events: [Event]
        let cues: [Cue]

        func cue(_ type: String) -> Double? { cues.first { $0.type == type && !$0.implied }?.t }
    }
    let marks: [String: Double]?
    let expected: Expected?
}

/// A flight replayed through LocationManager, the detector and AppState as the app wires them in flight,
/// on the flight's clock stopped at each fix, with a pilot who answers the slot when it asks.
@MainActor
private final class HeadlessFlight {
    struct SlotSeen { let t: Double; let slot: CheckSlot }

    let scenario: (marks: [String: Double], expected: ScenarioFile.Expected?)
    let replay: GroundReplayScenario
    let fixes: [GroundReplayFix]
    /// The app's: a relaunch (`relaunches`) puts new ones in their place, as a kill and a launch do.
    private(set) var appState: AppState
    private(set) var location = LocationManager()
    private(set) var detector = FlightEventDetector()
    let airports = AirportDataService()
    private(set) var plans: FlightPlanManager
    let circuits: Bool
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private unowned let test: XCTestCase
    private let datastore: DataPersistenceManager
    private let defaults: UserDefaults

    /// Track times at which the app is killed and launched again, mid-flight (replay undo-5).
    var relaunches: [Double] = []

    /// The checks the pilot leaves alone when they come due.
    var leaveOpen: Set<ChecklistPhase> = []
    var landedAnswer: LandedAnswer = .yes
    /// Called once, at the first fix with the cruise check's cue come (the level-off).
    var onLevelOff: ((AppState) -> Void)?
    /// Called at every fix, once the chain has taken it: what the Cockpit does with a fix besides.
    var onFix: ((GroundReplayFix) -> Void)?

    private(set) var slots: [SlotSeen] = []
    private(set) var landedCards: [(aerodrome: String?, t: Double)] = []
    private(set) var cardsConfirmed: [String] = []
    private(set) var phaseAfterFullStops: [ChecklistPhase] = []
    private(set) var fredaEverRan = false
    private(set) var endedFlight: Flight?
    /// What the detector emitted and cued, kept before END FLIGHT resets it.
    private(set) var events: [EmittedFlightEvent] = []
    private(set) var cues: [FlightCueEvent] = []

    convenience init(test: XCTestCase, scenario name: String, circuits: Bool = false) throws {
        let url = try XCTUnwrap(Bundle(for: GroundReplayTests.self).url(forResource: name, withExtension: "json",
                                                                       subdirectory: "Scenarios"), "scenario \(name)")
        try self.init(test: test, url: url, circuits: circuits)
    }

    convenience init(test: XCTestCase, fixture name: String) throws {
        let url = try XCTUnwrap(Bundle(for: GroundReplayTests.self).url(forResource: name, withExtension: "json",
                                                                       subdirectory: "FlightEventFixtures")
                                ?? Bundle(for: GroundReplayTests.self).url(forResource: name, withExtension: "json"),
                                "fixture \(name)")
        try self.init(test: test, url: url, circuits: false, isFixture: true)
    }

    init(test: XCTestCase, url: URL, circuits: Bool, isFixture: Bool = false) throws {
        self.test = test
        self.circuits = circuits
        let data = try Data(contentsOf: url)
        replay = try JSONDecoder().decode(GroundReplayScenario.self, from: data)
        if isFixture {
            // A corpus fixture reads as a scenario (name, track, aerodromes): no holds, no route, and its
            // expectations are the detector tests'.
            scenario = ([:], nil)
        } else {
            let file = try JSONDecoder().decode(ScenarioFile.self, from: data)
            scenario = (file.marks ?? [:], file.expected)
        }
        fixes = GroundReplayFix.fixes(from: replay.track)
        datastore = test.makeTestDatastore()
        defaults = test.makeTestDefaults()
        appState = test.makeTestAppState(datastore: datastore, defaults: defaults)
        appState.settings.learningMode = false              // the Memory test, as on the 6.1.0 page
        appState.saveSettings()                             // and after a relaunch
        plans = test.makeTestPlanManager(datastore: datastore, defaults: defaults)
        airports.injectForReplay(replay.airports.map(GroundReplay.airport))
        if let route = replay.route, !circuits {
            GroundReplay.arm(route, name: replay.name, in: plans)
        }
    }

    func track(_ date: Date) -> Double { date.timeIntervalSince(start) }

    private func setClock(_ t: Double) {
        FlightClock.virtual = .init(wallAnchor: Date(), virtualAnchor: start.addingTimeInterval(t), rate: 0)
    }

    // MARK: Flying

    func fly() {
        setClock(0)
        appState.startFlight(withAircraft: appState.settings.defaultAirplane, aircraftRegistration: "F-HVXA",
                             flightPlanId: circuits ? nil : plans.activeFlightPlan?.id, circuitMode: circuits)
        XCTAssertTrue(appState.isFlightActive)
        startTracking()
        // ENGINE START at the first fix, as the replay's first hold waits for.
        workGroundChecks(until: .afterEngineStart, engineStart: true)
        let lineUpHold = replay.holds?.first { $0.until == "lineUp" }?.t
        var linedUp = lineUpHold == nil
        var levelledOff = false
        var lastFreda = -Double.infinity
        for fix in fixes {
            setClock(fix.t)
            if let next = relaunches.first, fix.t >= next {
                relaunches.removeFirst()
                relaunch()
            }
            if !linedUp, let hold = lineUpHold, fix.t >= hold {
                departure()
                linedUp = true
            }
            location.feedReplayFix(fix.location(at: FlightClock.now), baroRelativeAltitudeM: fix.baroRelativeM)
            onFix?(fix)
            // FREDA, as the Cockpit's 5 s evaluation does it.
            if fix.t - lastFreda >= 5 {
                lastFreda = fix.t
                appState.evaluateFreda(lastPassage: FredaWaypointPassage.latest(in: plans.activeFlightPlan))
            }
            fredaEverRan = fredaEverRan || appState.freda.isRunning
            noteSlot(at: fix.t)
            if !levelledOff, appState.flightCues.cueHasCome(for: .cruise, circuitMode: circuits) || appState.cueTiming(for: .climb) == .owed {
                levelledOff = true
                onLevelOff?(appState)
            }
            answerCards(at: fix.t)
            answerSlot(at: fix.t)
        }
        events = detector.emittedEvents
        cues = detector.cueEvents
        endFlight()
    }

    /// The GPS pipeline and the detector, wired as `FlightLauncher` (and, after a relaunch, `AeroCheckApp`)
    /// wire them.
    private func startTracking() {
        location.authorizationStatus = .authorizedAlways
        detector.configure(speeds: appState.activeChecklist.speeds, stallSpeed: appState.activeChecklist.stallSpeed)
        location.startTracking(appState: appState, interval: 5, airportDataService: airports, flightEventDetector: detector,
                               flightPlanManager: plans, activeChecklist: appState.activeChecklist)
    }

    /// Killed and launched again, just after a checkpoint (the app writes one every 30 s and at every cue
    /// and landing; a kill loses the fixes since the last): nothing winds down (no END of anything), and
    /// what the launch finds on disk comes back, as `AeroCheckApp` brings it back: the flight from its
    /// checkpoint, the plan from the defaults, a new detector and GPS pipeline.
    private func relaunch() {
        appState.checkpointActiveFlight(force: true)
        appState.flushPendingCheckpoint()
        appState = test.makeTestAppState(datastore: datastore, defaults: defaults)
        XCTAssertTrue(appState.restoreActiveFlightState(), "the flight restored")
        plans = test.makeTestPlanManager(datastore: datastore, defaults: defaults)
        detector = FlightEventDetector()
        location = LocationManager()
        startTracking()
    }

    /// The ground checks up to `phase`, lists checked, memory checks confirmed.
    private func workGroundChecks(until phase: ChecklistPhase, engineStart: Bool = false) {
        for _ in 0..<16 where appState.currentPhase != phase {
            if appState.currentPhase == .engineStart, engineStart { appState.recordEngineStart() }
            completeCurrentCheck()
            appState.nextPhase()
        }
    }

    /// Before Departure to the climb check: its NEXT, READY FOR LINE UP since 6.2 (which records the
    /// line-up), then LINE UP's one tap. The one place that knows how the Cockpit asks for the line-up.
    private func departure() {
        workGroundChecks(until: .beforeDeparture)
        completeCurrentCheck()
        appState.nextPhase()
        XCTAssertNotNil(appState.lineUpTime, "READY FOR LINE UP records the line-up")
        appState.confirmMemoryCheckAndAdvance()
    }

    private func completeCurrentCheck() {
        guard !appState.currentCheckIsDone else { return }
        if appState.currentCheckAwaitsConfirmation {
            appState.confirmMemoryCheck()
        } else {
            appState.markLastItemComplete(learningMode: appState.effectiveLearningMode)
        }
    }

    /// The slot, as the pilot answers it: due or owed, tapped (a list it opens worked through on the
    /// checklist page), unless the pilot leaves that check open; from circuit height, on to the landing check.
    private func answerSlot(at t: Double) {
        let slot = noteSlot(at: t)
        guard appState.landedCard == nil else { return }
        guard slot.tone == .due || slot.tone == .owed || slot.action == .goToLanding else { return }
        if leaveOpen.contains(slot.phase) { return }
        // The checks the flight times wait for their cue (the climb check for 500 ft, not the runway).
        let cued: Set<ChecklistPhase> = [.climb, .cruise, .descent, .approach]
        if cued.contains(slot.phase), slot.tone == .due,
           !appState.flightCues.cueHasCome(for: slot.phase, circuitMode: circuits) { return }
        CockpitCheckSlot.perform(slot.action, appState: appState) { self.completeCurrentCheck() }
        if slot.action == .advance, !appState.currentCheckIsDone { completeCurrentCheck() }
    }

    /// The slot as drawn now, kept when it changed.
    @discardableResult
    private func noteSlot(at t: Double) -> CheckSlot {
        let slot = CockpitCheckSlot.slot(for: appState)
        if slots.last?.slot != slot { slots.append(SlotSeen(t: t, slot: slot)) }
        return slot
    }

    /// The landed card (answered as `landedAnswer`) and, in circuits, the detector's own cards (CONFIRM).
    private func answerCards(at t: Double) {
        if let card = appState.landedCard {
            landedCards.append((card.aerodrome, t))
            appState.answerLandedCard(landedAnswer)
        }
        for event in [detector.pendingTouchAndGo, detector.pendingFullStop, detector.pendingGoAround].compactMap({ $0 }) {
            cardsConfirmed.append(event.type.code)
            FlightEventConfirmationOverlay.confirm(event, appState: appState, detector: detector)
            if event.type == .fullStop { phaseAfterFullStops.append(appState.currentPhase) }
            // On to the next circuit: the checks to the climb again, as after a stop-and-go.
            if event.type == .fullStop, circuits { departure() }
        }
    }

    /// The checks after the landing, ENGINE SHUTDOWN, the hangar, END FLIGHT.
    private func endFlight() {
        for _ in 0..<6 where appState.currentPhase != .hangar && appState.currentPhase.rawValue >= ChecklistPhase.afterLanding.rawValue {
            if appState.currentPhase == .shutdown { appState.recordEngineShutdown() }
            completeCurrentCheck()
            appState.nextPhase()
        }
        completeCurrentCheck()
        let id = appState.currentFlight?.id
        location.stopTracking()
        appState.endFlight(withFlightPlan: nil)
        endedFlight = appState.flights.first { $0.id == id }
    }

    // MARK: Asserting

    /// The slot showed `phase`'s check in `tone` about when the referee's cue came (±40 s: the detector's
    /// 5 s cadence, and the slot asked at the next fix): the first time after the take-off roll. (Before
    /// any take-off, a check open is due as before the cues: the climb check, from the line-up.)
    func assertSlot(_ phase: ChecklistPhase, tone: CheckSlot.Tone, near cue: Double?,
                    file: StaticString = #filePath, line: UInt = #line) {
        let roll = scenario.marks["takeoffRoll"] ?? 0
        guard let seen = slots.first(where: { $0.t >= roll && $0.slot.phase == phase && $0.slot.tone == tone }) else {
            return XCTFail("the slot never showed \(phase) \(tone): \(slots.map { "\(Int($0.t)) \($0.slot.phase) \($0.slot.tone)" })", file: file, line: line)
        }
        guard let cue else { return XCTFail("no referee cue for \(phase)", file: file, line: line) }
        XCTAssertEqual(seen.t, cue, accuracy: 40, "\(phase) \(tone) at \(Int(seen.t)) s, cue at \(Int(cue)) s", file: file, line: line)
    }

    /// Every cue the referee expects came from the Swift chain, within ±15 s.
    func assertCuesMatchTheReferee(file: StaticString = #filePath, line: UInt = #line) {
        guard let expected = scenario.expected else { return }
        let codes: [String: FlightCue] = Dictionary(uniqueKeysWithValues: FlightCue.allCases.map { ($0.code, $0) })
        for want in expected.cues where !want.implied {
            guard let cue = codes[want.type] else { continue }
            let got = cues.first { event in
                if case .fired(let fired) = event.kind, fired == cue, !event.implied {
                    return abs(track(event.time) - want.t) <= 15
                }
                return false
            }
            XCTAssertNotNil(got, "cue \(want.type) at \(Int(want.t)) s: got \(cues.map { "\($0.kind) \(Int(track($0.time)))" })",
                            file: file, line: line)
        }
    }
}
