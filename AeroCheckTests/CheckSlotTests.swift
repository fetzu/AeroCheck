import XCTest
@testable import AeroCheck

/// The check slot on the map (6.1, "Checks in flight" Q1): what it holds for each check, its colour, and
/// what one tap does. Pure (`CheckSlot.make`), then read off a flight (`CockpitCheckSlot`).
final class CheckSlotTests: XCTestCase {

    // MARK: The current check

    func testAMemoryCheckIsConfirmedWithOneTap() {
        let slot = CheckSlot.make(phase: .climb, check: .memory(done: false), next: .cruise)
        XCTAssertEqual(slot.phase, .climb)
        XCTAssertEqual(slot.line, .fromMemory)
        XCTAssertEqual(slot.icon, .confirm)
        XCTAssertEqual(slot.tone, .due, "the current check left open is due, until the flight's cues come")
        XCTAssertEqual(slot.action, .confirmFromMemory)
    }

    func testAReadDoCheckOpensTheList() {
        let slot = CheckSlot.make(phase: .cruise, check: .list(open: 5), next: .descent)
        XCTAssertEqual(slot.phase, .cruise)
        XCTAssertEqual(slot.line, .items(5))
        XCTAssertEqual(slot.icon, .list)
        XCTAssertEqual(slot.tone, .due)
        XCTAssertEqual(slot.action, .showChecklist)
    }

    func testTheLandingCheckIsShownQuietButATapStillConfirms() {
        let memory = CheckSlot.make(phase: .landing, check: .memory(done: false), next: .afterLanding)
        XCTAssertEqual(memory.tone, .quiet)
        XCTAssertEqual(memory.line, .fromMemoryQuiet)
        XCTAssertEqual(memory.action, .confirmFromMemory)

        let list = CheckSlot.make(phase: .landing, check: .list(open: 2), next: .afterLanding)
        XCTAssertEqual(list.tone, .quiet, "nothing to press from final to the runway vacated, list or not")
        XCTAssertEqual(list.action, .showChecklist)

        let owed = CheckSlot.make(phase: .landing, check: .memory(done: false), next: .afterLanding, timing: .owed)
        XCTAssertEqual(owed.tone, .quiet, "never amber in the landing phase")
    }

    // MARK: Done: the next check

    func testADoneCheckOffersTheNextOneIdle() {
        for check in [CheckSlotCheck.memory(done: true), .list(open: 0), .none] {
            let slot = CheckSlot.make(phase: .climb, check: check, next: .cruise)
            XCTAssertEqual(slot.phase, .cruise, "\(check)")
            XCTAssertEqual(slot.line, .next)
            XCTAssertEqual(slot.icon, .next)
            XCTAssertEqual(slot.tone, .idle)
            XCTAssertEqual(slot.action, .advance)
        }
    }

    func testTheLastCheckDoneSendsToTheChecklist() {
        let slot = CheckSlot.make(phase: .hangar, check: .list(open: 0), next: nil)
        XCTAssertEqual(slot.phase, .hangar)
        XCTAssertEqual(slot.line, .allChecked)
        XCTAssertEqual(slot.tone, .idle)
        XCTAssertEqual(slot.action, .showChecklist, "END FLIGHT is on the checklist")
    }

    func testAPhaseActionStillToPressComesBeforeGoingOn() {
        let slot = CheckSlot.make(phase: .engineStart, check: .list(open: 0), next: .afterEngineStart,
                                  pendingAction: "ENGINE START")
        XCTAssertEqual(slot.phase, .engineStart)
        XCTAssertEqual(slot.line, .actionFirst("ENGINE START"))
        XCTAssertEqual(slot.tone, .due)
        XCTAssertEqual(slot.action, .showChecklist, "going on would record the phase red")

        let open = CheckSlot.make(phase: .engineStart, check: .list(open: 3), next: .afterEngineStart,
                                  pendingAction: "ENGINE START")
        XCTAssertEqual(open.line, .items(3), "the list first, then the action")
    }

    // MARK: FREDA in cruise (6.1, Q6)

    func testFredaCountingShowsWhenItComes() {
        let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let slot = CheckSlot.make(phase: .cruise, check: .list(open: 0), next: .descent,
                                  freda: .counting(after: .cruiseCheck, at: at, minutesLeft: 6))
        XCTAssertEqual(slot.title, .fredaCountsFrom(.cruiseCheck, at), "CRUISE CHECK ✓ 14:24")
        XCTAssertEqual(slot.line, .fredaIn(minutes: 6))
        XCTAssertEqual(slot.icon, .freda)
        XCTAssertEqual(slot.tone, .idle, "nothing due: dark")
        XCTAssertEqual(slot.action, .showChecklist, "where NEXT and the FREDA button are")
        XCTAssertTrue(slot.titleText().hasPrefix("\(ChecklistPhase.cruise.shortTitle) ✓ "))
        XCTAssertTrue(slot.titleText(stacked: true).hasPrefix("\(ChecklistPhase.cruise.shortTitle)\n✓ "),
                      "beside MARK, the time under the check, so neither shrinks under 20 pt")
    }

    func testFredaDueIsOneTap() {
        let slot = CheckSlot.make(phase: .cruise, check: .list(open: 0), next: .descent,
                                  freda: .due(waypoint: "SEGNELÉGIER"))
        XCTAssertEqual(slot.title, .freda)
        XCTAssertEqual(slot.line, .fredaFlow(waypoint: "SEGNELÉGIER"))
        XCTAssertEqual(slot.tone, .due)
        XCTAssertEqual(slot.action, .confirmFreda, "a flow: no list to open")
        XCTAssertEqual(CheckSlot.Line.fredaFlow(waypoint: "SEGNELÉGIER").shortText, L10n.Freda.flowCompact,
                       "the phone's narrow slot keeps the letters")
        XCTAssertEqual(CheckSlot.Line.fredaFlow(waypoint: "SEGNELÉGIER").stackedText, "F·R·E·D·A\nSEGNELÉGIER",
                       "beside MARK on the iPad, the letters over the waypoint")
        XCTAssertTrue(CheckSlot.Line.fredaFlow(waypoint: "SEGNELÉGIER").text.contains("SEGNELÉGIER"))
    }

    func testTheCruiseListStillOpenComesBeforeFreda() {
        let slot = CheckSlot.make(phase: .cruise, check: .list(open: 5), next: .descent, freda: .due(waypoint: nil))
        XCTAssertEqual(slot.line, .items(5))
        XCTAssertEqual(slot.action, .showChecklist)
        XCTAssertEqual(slot.title, .check)
    }

    // MARK: The flight's timing (the cues come in a later PR)

    func testTheFlightsTimingColoursAnOpenCheck() {
        XCTAssertEqual(CheckSlot.make(phase: .climb, check: .memory(done: false), next: .cruise, timing: .notYet).tone, .idle)
        XCTAssertEqual(CheckSlot.make(phase: .climb, check: .memory(done: false), next: .cruise, timing: .due).tone, .due)
        XCTAssertEqual(CheckSlot.make(phase: .climb, check: .memory(done: false), next: .cruise, timing: .owed).tone, .owed)
        XCTAssertEqual(CheckSlot.make(phase: .cruise, check: .list(open: 5), next: .descent, timing: .owed).tone, .owed)
    }

    func testTheTimingNeverColoursTheNextCheck() {
        let slot = CheckSlot.make(phase: .climb, check: .memory(done: true), next: .cruise, timing: .owed)
        XCTAssertEqual(slot.tone, .idle)
    }

    // MARK: Read off a flight

    @MainActor
    private func flight(memoryTest: Bool) -> AppState {
        let appState = makeTestAppState()
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.settings.learningMode = !memoryTest
        appState.settings.stepByStepHighlighting = true
        appState.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9")
        addTeardownBlock { @MainActor in appState.cancelFlight() }
        return appState
    }

    /// The bundled WT9 flies its climb from memory (every item hidden in the Memory test) and reads its
    /// cruise check.
    @MainActor
    func testTheSlotFollowsTheFlight() throws {
        let appState = flight(memoryTest: true)
        try XCTSkipUnless(appState.isMemoryCheck(.climb, learningMode: false), "needs the WT9's memory climb")
        appState.currentPhase = .climb
        XCTAssertEqual(CockpitCheckSlot.slot(for: appState).action, .confirmFromMemory)

        appState.confirmMemoryCheck()
        let next = CockpitCheckSlot.slot(for: appState)
        XCTAssertEqual(next.phase, .cruise)
        XCTAssertEqual(next.action, .advance)

        appState.nextPhase()
        let cruise = CockpitCheckSlot.slot(for: appState)
        let items = appState.activeChecklist.visibleItems(for: .cruise, learningMode: false).filter { !$0.isHeader }
        XCTAssertEqual(cruise.line, .items(items.count))
        XCTAssertEqual(cruise.action, .showChecklist)
    }

    @MainActor
    func testWithMemoryTestOffTheClimbIsAList() throws {
        let appState = flight(memoryTest: false)
        appState.currentPhase = .climb
        let items = appState.activeChecklist.visibleItems(for: .climb, learningMode: true).filter { !$0.isHeader }
        try XCTSkipIf(items.isEmpty)
        XCTAssertEqual(CockpitCheckSlot.slot(for: appState).line, .items(items.count))
    }

    @MainActor
    func testAPhaseActionUnpressedIsNamed() {
        let appState = flight(memoryTest: false)
        appState.currentPhase = .engineStart
        XCTAssertNotNil(CockpitCheckSlot.pendingAction(in: appState))
        appState.recordEngineStart()
        XCTAssertNil(CockpitCheckSlot.pendingAction(in: appState))
    }
}
