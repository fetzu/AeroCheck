import XCTest
import CoreLocation
@testable import AeroCheck

/// Full-stop circuits (6.3.0, PLAN-6.3.0, the author's Q1 to Q3 of 11 Oct). A full stop goes on to the after
/// landing check; at its end NEW CIRCUIT, in NEXT's place, starts the next lap at the check before departure
/// (taxi and run-up flown once, on the first lap), and the check slot beside it goes on to the parking check.
/// A full stop is counted once per lap: the detector card's CONFIRM, LANDED, or else the choice at the end
/// of the after landing check. Touch-and-goes and go-arounds go back to the climb check, as before. Flown on
/// the bundled WT9, every item to check one by one.
@MainActor
final class CircuitsTests: XCTestCase {

    /// The flight's clock, stopped: READY FOR LINE UP at 0 s estimates the take-off at 120 s, and a landing
    /// is never before it (`clampedToLineUp`).
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func t(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
    private func at(_ seconds: Double) {
        FlightClock.virtual = .init(wallAnchor: Date(), virtualAnchor: t(seconds), rate: 0)
    }
    private var touchdown: Date { t(600) }

    override func tearDown() {
        // The clock is global: never leave a test's on for the next.
        FlightClock.virtual = nil
        super.tearDown()
    }

    private func flight(circuits: Bool = true) -> AppState {
        at(0)
        let appState = makeTestAppState()
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.settings.learningMode = true
        appState.settings.stepByStepHighlighting = true
        appState.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9",
                             circuitMode: circuits)
        addTeardownBlock { @MainActor in if appState.isFlightActive { appState.cancelFlight() } }
        return appState
    }

    /// Every check up to `phase` worked through, as NEXT leaves them, and `phase` the current one.
    private func fly(_ appState: AppState, to phase: ChecklistPhase) {
        for _ in 0..<16 where appState.currentPhase != phase {
            if appState.currentPhase == .engineStart { appState.recordEngineStart() }
            completeCurrentCheck(appState)
            appState.nextPhase()
        }
        XCTAssertEqual(appState.currentPhase, phase)
    }

    private func completeCurrentCheck(_ appState: AppState) {
        appState.markLastItemComplete(learningMode: appState.effectiveLearningMode)
        if appState.currentCheckAwaitsConfirmation { appState.confirmMemoryCheck() }
    }

    /// The landing check's NEXT: the after landing check, nothing counted yet (the pilot may still go on
    /// from the runway).
    private func landedWithNext(_ appState: AppState) {
        fly(appState, to: .landing)
        completeCurrentCheck(appState)
        appState.nextPhase()
        XCTAssertEqual(appState.currentPhase, .afterLanding)
    }

    // MARK: The choice at the end of the after landing check

    func testNEWCIRCUITIsOfferedAtTheEndOfTheAfterLandingCheckOfACircuitsFlight() {
        let appState = flight()
        landedWithNext(appState)
        XCTAssertEqual(appState.currentFlight?.fullStopCount, 0, "NEXT on the landing check counts nothing")
        if !appState.currentCheckIsDone {
            XCTAssertFalse(appState.offersNewCircuit, "not while the check is open: CHECK first, as NEXT")
        }
        completeCurrentCheck(appState)
        XCTAssertTrue(appState.offersNewCircuit)
        let slot = CockpitCheckSlot.slot(for: appState)
        XCTAssertEqual([slot.phase, slot.action] as [AnyHashable], [ChecklistPhase.shutdown, CheckSlot.Action.advance],
                       "the slot beside it: the parking check, one tap")

        let other = flight(circuits: false)
        landedWithNext(other)
        completeCurrentCheck(other)
        XCTAssertFalse(other.offersNewCircuit, "NEXT on any other flight")
    }

    /// Q1: the next lap starts at the check before departure. Taxi and run-up stay as the first lap left
    /// them; the checks the lap flies again start clean, deferred items included.
    func testNEWCIRCUITStartsTheNextLapAtTheCheckBeforeDeparture() {
        let appState = flight()
        landedWithNext(appState)
        completeCurrentCheck(appState)
        appState.deferredItems[.approach] = ["x"]
        appState.deferredChecks = [.climb]
        let taxi = appState.phaseCompletionStatus[.taxi], runup = appState.phaseCompletionStatus[.runup]

        appState.startNewCircuit()

        XCTAssertEqual(appState.currentPhase, .beforeDeparture)
        XCTAssertEqual(appState.phaseCompletionStatus[.taxi], taxi, "taxi: flown once")
        XCTAssertEqual(appState.phaseCompletionStatus[.runup], runup, "run-up: flown once")
        XCTAssertEqual(appState.phaseCompletionStatus[.preflight], .completed)
        for phase in ChecklistPhase.allCases
        where (ChecklistPhase.beforeDeparture.rawValue...ChecklistPhase.afterLanding.rawValue).contains(phase.rawValue) {
            XCTAssertNil(appState.phaseCompletionStatus[phase], "\(phase) starts again")
            XCTAssertEqual(appState.getHighlightedItem(for: phase), 0, "\(phase) starts again")
            XCTAssertNil(appState.deferredItems[phase], "\(phase) starts again")
        }
        XCTAssertTrue(appState.deferredChecks.isEmpty, "what was put off on the last lap is asked again on this one")
        XCTAssertEqual(appState.circuitLaps.newCircuits, 1)
        XCTAssertEqual(appState.circuitLaps.lastLoop, .fullStop)
    }

    /// Q3: nothing counted the full stop on the lap (NEXT on the landing check): NEW CIRCUIT counts it, at
    /// the detector's touchdown, and tells the detector, whose card then never comes.
    func testNEWCIRCUITCountsTheFullStopNothingCountedAtItsTouchdown() {
        let appState = flight()
        var told = 0
        appState.takeLapFullStop = { [touchdown] in told += 1; return touchdown }
        landedWithNext(appState)
        completeCurrentCheck(appState)

        at(650)
        appState.startNewCircuit()

        XCTAssertEqual(told, 1, "the detector told of the full stop")
        XCTAssertEqual(appState.currentFlight?.fullStopCount, 1)
        XCTAssertEqual(appState.currentFlight?.fullStopTimes, [touchdown], "at its touchdown")
        XCTAssertEqual(appState.landingTime, touchdown)
    }

    /// Without a touchdown from the detector (no GPS on the runway): counted at the choice.
    func testWithoutATouchdownTheFullStopIsCountedAtTheChoice() {
        let appState = flight()
        appState.takeLapFullStop = { nil }
        landedWithNext(appState)
        completeCurrentCheck(appState)
        at(650)
        appState.startNewCircuit()
        XCTAssertEqual(appState.currentFlight?.fullStopCount, 1)
        XCTAssertEqual(appState.currentFlight?.fullStopTimes, [t(650)])
    }

    /// Q3: the card's CONFIRM counted it: NEW CIRCUIT counts nothing more, and asks the detector nothing.
    func testAFullStopTheCardCountedIsNotCountedAgain() {
        let appState = flight()
        var told = 0
        appState.takeLapFullStop = { told += 1; return nil }
        fly(appState, to: .landing)
        appState.recordFullStop(at: touchdown)                      // the card's CONFIRM
        XCTAssertEqual(appState.currentPhase, .afterLanding)
        XCTAssertTrue(appState.fullStopCountedThisLap)
        completeCurrentCheck(appState)

        at(650)
        appState.startNewCircuit()

        XCTAssertEqual(appState.currentFlight?.fullStopCount, 1, "once per lap")
        XCTAssertEqual(told, 0)
    }

    /// LANDED (FULL STOP LANDING, held on the after landing check) counts it too.
    func testAFullStopLANDEDCountedIsNotCountedAgain() {
        let appState = flight()
        appState.takeLapFullStop = { nil }
        landedWithNext(appState)
        appState.recordLanding(at: touchdown)
        completeCurrentCheck(appState)
        at(650)
        appState.startNewCircuit()
        XCTAssertEqual(appState.currentFlight?.fullStopCount, 1, "once per lap")
    }

    /// The last lap's full stop counted at the parking check, minutes after a touchdown the detector never told of
    /// (6.4.1, F2): END FLIGHT takes it to the touchdown the track shows, nothing having flown since. Until then it
    /// stayed at the choice, a second landing beside the track's in the review, and the flight time ran to it.
    func testALapsFullStopCountedLateIsItsTouchdownAtEndFlight() throws {
        let appState = flight()
        appState.takeLapFullStop = { nil }
        landedWithNext(appState)
        completeCurrentCheck(appState)
        at(900)
        CockpitCheckSlot.perform(CockpitCheckSlot.slot(for: appState).action, appState: appState, onShowChecklist: {})
        XCTAssertEqual(appState.currentFlight?.fullStopTimes, [t(900)], "counted at the choice")

        // The track: the take-off at 130 s, the circuit, the touchdown near 580 s, the taxi in.
        let knot = 0.514444
        var points: [GPSPoint] = []
        var time = t(100)
        func fix(_ heightFt: Double, _ kt: Double, after seconds: TimeInterval = 6) {
            time = time.addingTimeInterval(seconds)
            points.append(GPSPoint(latitude: 47.39 + Double(points.count) * 0.0003, longitude: 7.03,
                                   altitude: 573 + heightFt * 0.3048, timestamp: time, speed: kt * knot,
                                   horizontalAccuracy: 3.5))
        }
        for kt in [10.0, 30, 50] { fix(0, kt) }
        for height in [50.0, 300, 600, 900, 1000] { fix(height, 65) }
        fix(1000, 75, after: 360)
        for height in [600.0, 300, 120, 30] { fix(height, 60) }
        fix(1, 40)
        for kt in [30.0, 15, 6, 8, 8] { fix(0, kt) }
        appState.currentFlight?.gpsTrack = points
        let measured = try XCTUnwrap(TrackTimes.analyze(track: points, engineStart: nil, engineShutdown: nil).landing)
        XCTAssertGreaterThan(t(900).timeIntervalSince(measured), 4 * 60)

        appState.refineTimingFromTrack()

        XCTAssertEqual(appState.currentFlight?.fullStopTimes, [measured], "the lap's full stop is the touchdown's")
        XCTAssertEqual(appState.landingTime, measured)
    }

    /// The parking check, the other way on (the check slot's tap, or NEXT from the Companion): it counts the
    /// lap's full stop as NEW CIRCUIT does, once, and the circuits end there.
    func testTheParkingCheckCountsTheFullStopOnce() {
        let appState = flight()
        appState.takeLapFullStop = { [touchdown] in touchdown }
        landedWithNext(appState)
        completeCurrentCheck(appState)

        at(650)
        CockpitCheckSlot.perform(CockpitCheckSlot.slot(for: appState).action, appState: appState, onShowChecklist: {})

        XCTAssertEqual(appState.currentPhase, .shutdown)
        XCTAssertEqual(appState.currentFlight?.fullStopCount, 1)
        XCTAssertEqual(appState.landingTime, touchdown, "the flight's landing")
        XCTAssertEqual(appState.circuitLaps.newCircuits, 0)

        let confirmed = flight()
        fly(confirmed, to: .landing)
        confirmed.recordFullStop(at: touchdown)
        completeCurrentCheck(confirmed)
        confirmed.nextPhase()
        XCTAssertEqual(confirmed.currentFlight?.fullStopCount, 1, "the card counted it: once")
    }

    /// A lap is what the flight flew since its last loop: a full stop counted on an earlier lap doesn't
    /// count for this one, which a touch-and-go started.
    func testAFullStopOfAnEarlierLapDoesNotCountForThisOne() {
        let appState = flight()
        appState.takeLapFullStop = { nil }
        fly(appState, to: .landing)
        appState.recordFullStop(at: touchdown)                      // lap 1, the card
        completeCurrentCheck(appState)
        at(650)
        appState.startNewCircuit()                                  // lap 2
        fly(appState, to: .landing)
        appState.recordTouchAndGo(at: t(1000))                      // lap 3
        XCTAssertEqual(appState.currentPhase, .climb)
        XCTAssertFalse(appState.fullStopCountedThisLap)
        fly(appState, to: .landing)
        completeCurrentCheck(appState)
        appState.nextPhase()                                        // NEXT on the landing check
        completeCurrentCheck(appState)

        at(1400)
        appState.startNewCircuit()                                  // lap 4

        XCTAssertEqual(appState.currentFlight?.fullStopCount, 2, "lap 1's, then lap 3's")
        XCTAssertEqual(appState.currentFlight?.touchAndGoCount, 1)
        XCTAssertEqual(appState.circuitLaps.newCircuits, 2)
        XCTAssertEqual(appState.currentPhase, .beforeDeparture)
    }

    /// Touch-and-goes and go-arounds still loop to the climb check, and start a lap.
    func testATouchAndGoStillGoesBackToTheClimbCheck() {
        let appState = flight()
        fly(appState, to: .landing)
        appState.recordTouchAndGo(at: touchdown)
        XCTAssertEqual(appState.currentPhase, .climb)
        XCTAssertEqual(appState.circuitLaps.lastLoop, .touchAndGo)
        XCTAssertEqual(appState.circuitLaps.lapStartedAt, touchdown)
        fly(appState, to: .landing)
        appState.recordGoAround(at: t(900))
        XCTAssertEqual(appState.currentPhase, .climb)
        XCTAssertEqual(appState.circuitLaps.lapStartedAt, t(900))
    }

    /// NEW CIRCUIT is the after landing check's, on a circuits flight only.
    func testNEWCIRCUITDoesNothingElsewhere() {
        let appState = flight()
        fly(appState, to: .climb)
        appState.startNewCircuit()
        XCTAssertEqual(appState.currentPhase, .climb)
        let other = flight(circuits: false)
        landedWithNext(other)
        other.startNewCircuit()
        XCTAssertEqual(other.currentPhase, .afterLanding)
        XCTAssertEqual(other.circuitLaps.newCircuits, 0)
    }

    /// A memory check at the end: ✓ DONE confirms it and stays, and the choice follows (it went on to the
    /// parking check in the same tap). (6.3.0)
    func testDONEOnAMemoryAfterLandingCheckOnlyConfirmsInCircuits() throws {
        let appState = flight()
        appState.settings.learningMode = false
        landedWithNext(appState)
        try XCTSkipUnless(appState.currentCheckAwaitsConfirmation, "the WT9's after landing check is a memory check")
        XCTAssertNil(appState.memoryConfirmationMovesTo)
        appState.confirmMemoryCheckAndAdvance()
        XCTAssertEqual(appState.currentPhase, .afterLanding, "✓ DONE stays")
        XCTAssertTrue(appState.offersNewCircuit)

        let other = flight(circuits: false)
        other.settings.learningMode = false
        landedWithNext(other)
        XCTAssertEqual(other.memoryConfirmationMovesTo, .shutdown, "one tap on any other flight, as before")
    }

    // MARK: The top bar's loops and lap (6.3.0)

    /// The lap: one more than the loops taken (touch-and-goes, go-arounds, NEW CIRCUIT); a full stop gone on
    /// to the parking check ends the laps, it starts none. The current loop: the one that started the lap,
    /// and the full stop's from the after landing check on.
    func testTheLapAndTheLoopItTook() {
        let appState = flight()
        appState.takeLapFullStop = { nil }
        var marks: CircuitLoopMarks? { appState.circuitLoopMarks }
        XCTAssertEqual(marks?.lap, 1)
        XCTAssertNil(marks?.current, "neither loop before the first")
        fly(appState, to: .landing)
        appState.recordTouchAndGo(at: t(400))
        XCTAssertEqual(marks, CircuitLoopMarks(touchAndGoes: 1, fullStops: 0, current: .touchAndGo, lap: 2))
        fly(appState, to: .landing)
        appState.recordGoAround(at: t(500))
        XCTAssertEqual(marks?.lap, 3)
        XCTAssertEqual(marks?.touchAndGoes, 2, "a go-around flies the loop again too (the seventh dry run checks)")
        fly(appState, to: .landing)
        appState.recordFullStop(at: touchdown)
        XCTAssertEqual(marks, CircuitLoopMarks(touchAndGoes: 2, fullStops: 1, current: .fullStop, lap: 3),
                       "after landing: the full stop's loop, still lap 3")
        completeCurrentCheck(appState)
        at(650)
        appState.startNewCircuit()
        XCTAssertEqual(marks, CircuitLoopMarks(touchAndGoes: 2, fullStops: 1, current: .fullStop, lap: 4))
        fly(appState, to: .landing)
        completeCurrentCheck(appState)
        appState.nextPhase()
        completeCurrentCheck(appState)
        at(1000)
        appState.nextPhase()                                        // on to the parking check
        XCTAssertEqual(marks, CircuitLoopMarks(touchAndGoes: 2, fullStops: 2, current: .fullStop, lap: 4),
                       "the parking check: no new lap")

        XCTAssertNil(flight(circuits: false).circuitLoopMarks, "no loops on any other flight")
    }

    /// The loops' spans on the bar, cruise and descent left out.
    func testTheLoopsSpans() {
        let bar = ChecklistPhase.allCases.filter { !$0.isSkippedInCircuitMode(true) }
        XCTAssertEqual(CircuitLoopMarks.phases(of: .touchAndGo, in: bar), [.climb, .approach, .landing])
        XCTAssertEqual(CircuitLoopMarks.phases(of: .fullStop, in: bar),
                       [.beforeDeparture, .lineUp, .climb, .approach, .landing, .afterLanding])
    }

    // MARK: Leaving circuits, or taking them up, in flight (6.3.0, Q5 and Q6)

    /// Off: a normal flight from now. Cruise and descent come back, NEW CIRCUIT goes; the counts and the
    /// laps stay, and so does how the flight began (END FLIGHT's close-out reads it).
    func testLeavingCircuitsMakesItANormalFlightFromNow() {
        let appState = flight()
        fly(appState, to: .landing)
        appState.recordTouchAndGo(at: t(400))
        XCTAssertEqual(appState.currentPhase, .climb)
        appState.goToPhase(.cruise)
        XCTAssertEqual(appState.currentPhase, .climb, "circuits: cruise can't be entered")

        appState.setCircuitMode(false)

        XCTAssertFalse(appState.isCircuitMode)
        XCTAssertTrue(appState.startedAsCircuits, "how the flight began")
        XCTAssertEqual(appState.currentFlight?.touchAndGoCount, 1, "the counts stay")
        XCTAssertEqual(appState.circuitLaps.lastLoop, .touchAndGo, "and the laps")
        XCTAssertNil(appState.circuitLoopMarks, "no loops drawn on a normal flight")
        completeCurrentCheck(appState)
        appState.nextPhase()
        XCTAssertEqual(appState.currentPhase, .cruise, "NEXT: the cruise check again")
        appState.goToPhase(.descent)
        XCTAssertEqual(appState.currentPhase, .descent, "a jump there too")
        fly(appState, to: .afterLanding)
        completeCurrentCheck(appState)
        XCTAssertFalse(appState.offersNewCircuit, "NEXT at the end of the after landing check")
    }

    /// On, in cruise or descent: on to the approach check, both skipped as NEXT skips them on a circuits
    /// flight (a check done stays done), neither owed any more.
    func testTakingUpCircuitsInCruiseGoesOnToTheApproachCheck() {
        let appState = flight(circuits: false)
        fly(appState, to: .cruise)
        completeCurrentCheck(appState)
        appState.nextPhase()
        XCTAssertEqual(appState.currentPhase, .descent)
        appState.flightCues.owe(.descent, cue: .descent, at: t(300))

        appState.setCircuitMode(true)

        XCTAssertTrue(appState.isCircuitMode)
        XCTAssertFalse(appState.startedAsCircuits)
        XCTAssertEqual(appState.currentPhase, .approach)
        XCTAssertTrue(appState.getPhaseStatus(.cruise).isDone, "the cruise check done stays done")
        XCTAssertEqual(appState.phaseCompletionStatus[.descent], .skipped)
        XCTAssertNil(appState.owedCue(for: .descent), "not owed")
        XCTAssertEqual(appState.circuitLoopMarks?.lap, 1)
    }

    /// On anywhere else: nothing moves; NEXT skips cruise and descent from then on.
    func testTakingUpCircuitsElsewhereMovesNothing() {
        let appState = flight(circuits: false)
        fly(appState, to: .climb)
        appState.setCircuitMode(true)
        XCTAssertEqual(appState.currentPhase, .climb)
        completeCurrentCheck(appState)
        appState.nextPhase()
        XCTAssertEqual(appState.currentPhase, .approach)
        XCTAssertEqual(appState.phaseCompletionStatus[.cruise], .skipped)
    }

    // MARK: A go-around where the flight is going (6.4.0, st-14)

    /// LSZQ, the route's end in these tests.
    private let lszq = CLLocationCoordinate2D(latitude: 47.4517, longitude: 7.0247)

    /// The last fix: `nm` east of LSZQ.
    private func at(_ appState: AppState, nmEastOfLSZQ nm: Double) {
        let longitude = lszq.longitude + nm / (60 * cos(lszq.latitude * .pi / 180))
        appState.addGPSPoint(GPSPoint(latitude: lszq.latitude, longitude: longitude, altitude: 700, speed: 40, course: 70))
    }

    /// A go-around on a flight with no route is a circuit: circuits from there on, the climb check, then the
    /// approach check; the cruise and descent checks skipped, never owed.
    func testAGoAroundWithoutARouteTakesUpCircuits() {
        let appState = flight(circuits: false)
        fly(appState, to: .landing)
        appState.recordGoAround(at: t(400))
        XCTAssertTrue(appState.isCircuitMode)
        XCTAssertFalse(appState.startedAsCircuits, "how the flight began stays")
        XCTAssertEqual(appState.currentPhase, .climb)
        completeCurrentCheck(appState)
        appState.nextPhase()
        XCTAssertEqual(appState.currentPhase, .approach)
        XCTAssertEqual(appState.phaseCompletionStatus[.cruise], .skipped)
        XCTAssertEqual(appState.phaseCompletionStatus[.descent], .skipped)
    }

    /// At the route's end (within the approach cue's 5 NM), a go-around and a touch-and-go take up circuits.
    func testAGoAroundOrATouchAndGoAtTheRoutesEndTakesUpCircuits() {
        for touchAndGo in [false, true] {
            let appState = flight(circuits: false)
            appState.routeDestination = lszq
            fly(appState, to: .landing)
            at(appState, nmEastOfLSZQ: 0.4)
            if touchAndGo { appState.recordTouchAndGo(at: t(400)) } else { appState.recordGoAround(at: t(400)) }
            XCTAssertTrue(appState.isCircuitMode, touchAndGo ? "touch-and-go" : "go-around")
            completeCurrentCheck(appState)
            appState.nextPhase()
            XCTAssertEqual(appState.currentPhase, .approach)
        }
    }

    /// At an aerodrome on the way, the route goes on: its cruise and descent checks with it.
    func testATouchAndGoOnTheWayKeepsTheRoutesChecks() {
        let appState = flight(circuits: false)
        appState.routeDestination = lszq
        fly(appState, to: .landing)
        at(appState, nmEastOfLSZQ: 20)
        appState.recordTouchAndGo(at: t(400))
        XCTAssertFalse(appState.isCircuitMode)
        completeCurrentCheck(appState)
        appState.nextPhase()
        XCTAssertEqual(appState.currentPhase, .cruise)
    }

    /// A relaunch finds the switch as it was left, and how the flight began.
    func testARelaunchKeepsTheSwitchAndHowTheFlightBegan() throws {
        let datastore = makeTestDatastore()
        let defaults = makeTestDefaults()
        let appState = makeTestAppState(datastore: datastore, defaults: defaults)
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9", circuitMode: true)
        appState.setCircuitMode(false)
        appState.flushPendingCheckpoint()

        let restored = makeTestAppState(datastore: datastore, defaults: defaults)
        XCTAssertTrue(restored.restoreActiveFlightState())
        addTeardownBlock { @MainActor in if restored.isFlightActive { restored.cancelFlight() } }
        XCTAssertFalse(restored.isCircuitMode)
        XCTAssertTrue(restored.startedAsCircuits)
    }

    // MARK: Relaunch, and the Companion

    /// A relaunch keeps the lap: a full stop counted before it isn't counted again after it.
    func testARelaunchKeepsTheLap() throws {
        let datastore = makeTestDatastore()
        let defaults = makeTestDefaults()
        let appState = makeTestAppState(datastore: datastore, defaults: defaults)
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.settings.stepByStepHighlighting = true
        appState.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9", circuitMode: true)
        fly(appState, to: .landing)
        appState.recordTouchAndGo(at: t(400))
        fly(appState, to: .landing)
        appState.recordFullStop(at: touchdown)
        appState.checkpointActiveFlight(force: true)
        appState.flushPendingCheckpoint()

        let restored = makeTestAppState(datastore: datastore, defaults: defaults)
        XCTAssertTrue(restored.restoreActiveFlightState())
        addTeardownBlock { @MainActor in if restored.isFlightActive { restored.cancelFlight() } }
        XCTAssertEqual(restored.circuitLaps, appState.circuitLaps)
        XCTAssertTrue(restored.fullStopCountedThisLap)
        completeCurrentCheck(restored)
        at(650)
        restored.startNewCircuit()
        XCTAssertEqual(restored.currentFlight?.fullStopCount, 1, "once per lap, across the relaunch")
    }

    /// The Companion iPhone's NEW CIRCUIT: offered in the snapshot while the iPad offers it, and taken only
    /// then, so a tap arriving after the pilot went on here does nothing.
    func testTheCompanionsNEWCIRCUITIsTheIPadsOwn() {
        let appState = flight()
        let plans = makeTestPlanManager()
        landedWithNext(appState)
        XCTAssertFalse(CompanionConnectivityManager.checklistSnapshot(of: appState, mayStreamItemText: false).offersNewCircuit)
        completeCurrentCheck(appState)
        XCTAssertTrue(CompanionConnectivityManager.checklistSnapshot(of: appState, mayStreamItemText: false).offersNewCircuit)

        CompanionConnectivityManager.apply(.newCircuit, appState: appState, flightPlanManager: plans)
        XCTAssertEqual(appState.currentPhase, .beforeDeparture)
        CompanionConnectivityManager.apply(.newCircuit, appState: appState, flightPlanManager: plans)
        XCTAssertEqual(appState.circuitLaps.newCircuits, 1, "a second tap does nothing")
        XCTAssertEqual(appState.currentPhase, .beforeDeparture)
    }
}
