import XCTest
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
