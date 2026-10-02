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

    /// Out of the check before departure, the advance is READY FOR LINE UP, then the line up check, as on
    /// the thumb bar: no "first" any more, the tap is the ready moment. Read off the slot, so the
    /// Companion's snapshot keeps its shape. (6.2)
    func testTheCheckBeforeDepartureDoneOffersReadyForLineUp() throws {
        let slot = CheckSlot.make(phase: .beforeDeparture, check: .list(open: 0), next: .lineUp)
        XCTAssertEqual(slot.phase, .lineUp)
        XCTAssertEqual(slot.line, .next)
        XCTAssertEqual(slot.action, .advance)
        XCTAssertEqual(slot.tone, .idle)
        XCTAssertTrue(slot.readiesForLineUp)
        XCTAssertEqual(slot.titleText(), L10n.ChecklistAction.readyForLineUp)
        XCTAssertEqual(slot.titleText(stacked: true), L10n.ChecklistAction.readyForLineUp)
        let then = L10n.Cockpit.thenCheck(ChecklistPhase.lineUp.shortTitle)
        XCTAssertEqual(slot.lineText(), then)
        XCTAssertEqual(slot.lineText(narrow: true), then)
        XCTAssertEqual(slot.lineText(stacked: true), then)
        XCTAssertEqual(slot.lineAccessibilityText, then)
        XCTAssertEqual(try JSONDecoder().decode(CheckSlot.self, from: JSONEncoder().encode(slot)), slot,
                       "the same shape on the wire as any advance")

        let climb = CheckSlot.make(phase: .climb, check: .list(open: 0), next: .cruise)
        XCTAssertFalse(climb.readiesForLineUp)
        XCTAssertEqual(climb.titleText(), ChecklistPhase.cruise.shortTitle)
        XCTAssertEqual(climb.lineText(), L10n.CheckSlot.nextCheck)
        XCTAssertFalse(CheckSlot.make(phase: .beforeDeparture, check: .list(open: 3), next: .lineUp).readiesForLineUp,
                       "the list first")
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

    // MARK: The flight's timing (6.1, cues from the flight)

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

    func testAnOwedCheckNamesTheMomentThatPassedIt() {
        let memory = CheckSlot.make(phase: .climb, check: .memory(done: false), next: .cruise, timing: .owed, owedBy: .levelOff)
        XCTAssertEqual(memory.line, .owed(.levelOff))
        XCTAssertEqual(memory.tone, .owed)
        XCTAssertEqual(memory.action, .confirmFromMemory, "one tap, done late")
        let list = CheckSlot.make(phase: .cruise, check: .list(open: 5), next: .descent, timing: .owed, owedBy: .descent)
        XCTAssertEqual(list.line, .owed(.descent))
        XCTAssertEqual(list.action, .showChecklist)
        XCTAssertNotEqual(CheckSlot.Line.owed(.levelOff).text, CheckSlot.Line.owed(.descent).text)
        XCTAssertEqual(CheckSlot.Line.owed(.levelOff).shortText, L10n.CheckSlot.owedShort)
    }

    func testTheNextCheckComesToTheSlotOnceItsCueCame() {
        let memory = CheckSlot.make(phase: .cruise, check: .list(open: 0), next: .descent,
                                    upcoming: .init(check: .memory(done: false), timing: .due))
        XCTAssertEqual(memory.phase, .descent)
        XCTAssertEqual(memory.line, .fromMemory)
        XCTAssertEqual(memory.tone, .due)
        XCTAssertEqual(memory.action, .advanceAndConfirm, "on to it and done from memory, one tap")

        let list = CheckSlot.make(phase: .climb, check: .memory(done: true), next: .cruise,
                                  upcoming: .init(check: .list(open: 5), timing: .due))
        XCTAssertEqual(list.line, .items(5))
        XCTAssertEqual(list.action, .advance)

        let owed = CheckSlot.make(phase: .cruise, check: .list(open: 0), next: .descent,
                                  upcoming: .init(check: .memory(done: false), timing: .owed, owedBy: .approach))
        XCTAssertEqual(owed.line, .owed(.approach))
        XCTAssertEqual(owed.tone, .owed)

        let notYet = CheckSlot.make(phase: .cruise, check: .list(open: 0), next: .descent,
                                    upcoming: .init(check: .memory(done: false), timing: .notYet))
        XCTAssertEqual(notYet.line, .next)
        XCTAssertEqual(notYet.tone, .idle)
    }

    func testFredaRunningComesBeforeTheNextCheck() {
        // AppState stops FREDA at the descent cue; while it runs, the slot is FREDA's.
        let slot = CheckSlot.make(phase: .cruise, check: .list(open: 0), next: .descent,
                                  freda: .counting(after: .cruiseCheck, at: Date(), minutesLeft: 6),
                                  upcoming: .init(check: .memory(done: false), timing: .due))
        XCTAssertEqual(slot.icon, .freda)
    }

    func testTheLandingCheckIsNeverOfferedAsTheNextCheck() {
        let slot = CheckSlot.make(phase: .approach, check: .memory(done: true), next: .landing,
                                  upcoming: .init(check: .memory(done: false), timing: .due))
        XCTAssertEqual(slot.line, .next, "nothing to press: only the circuit shows it, dashed")
    }

    func testFromCircuitHeightTheLandingCheckIsShownDashed() {
        let memory = CheckSlot.make(phase: .approach, check: .memory(done: false), next: .landing,
                                    timing: .owed, landingShown: .memory(done: false))
        XCTAssertEqual(memory.phase, .landing)
        XCTAssertEqual(memory.tone, .quiet, "whatever was open before it")
        XCTAssertEqual(memory.line, .fromMemoryQuiet)
        XCTAssertEqual(memory.action, .goToLanding)
        let list = CheckSlot.make(phase: .descent, check: .memory(done: true), next: .approach,
                                  landingShown: .list(open: 2))
        XCTAssertEqual(list.line, .itemsQuiet(2))
        XCTAssertEqual(list.action, .goToLanding)
        let inLanding = CheckSlot.make(phase: .landing, check: .memory(done: false), next: .afterLanding,
                                       landingShown: .memory(done: false))
        XCTAssertEqual(inLanding.action, .confirmFromMemory, "on the landing check, a tap still confirms it")
    }

    // MARK: Where it sits

    /// The iPad on its side: the slot heads the map's thumb controls on a row of its own in every phase,
    /// route or not. Beside Routes it showed "CRUISE CH…" over "FREDA in 6…". (6.1, device check)
    func testInTheLandscapeColumnTheSlotAlwaysHasARowOfItsOwn() {
        for events in [false, true] {
            for route in [false, true] {
                let column = MapThumbColumn.make(showsCheckSlot: true, showsEventButtons: events,
                                                 hasRoute: route, flightActive: true)
                XCTAssertTrue(column.slotHasOwnRow, "events \(events), route \(route): \(column)")
            }
        }
        XCTAssertEqual(MapThumbColumn.make(showsCheckSlot: true, showsEventButtons: false, hasRoute: false,
                                           flightActive: true), .slotOverRoutes, "Routes where MARK would be")
        XCTAssertEqual(MapThumbColumn.make(showsCheckSlot: true, showsEventButtons: false, hasRoute: true,
                                           flightActive: true), .slotOverMark)
        XCTAssertEqual(MapThumbColumn.make(showsCheckSlot: true, showsEventButtons: true, hasRoute: true,
                                           flightActive: true), .slotOverFlightEvents, "GO AROUND in place of MARK")
    }

    func testWithoutTheSlotTheLandscapeColumnIsAsBefore() {
        XCTAssertEqual(MapThumbColumn.make(showsCheckSlot: false, showsEventButtons: false, hasRoute: true,
                                           flightActive: true), .legTimerOverMark)
        XCTAssertEqual(MapThumbColumn.make(showsCheckSlot: false, showsEventButtons: false, hasRoute: true,
                                           flightActive: false), .routes, "Plan › Map: no MARK before the flight")
        XCTAssertEqual(MapThumbColumn.make(showsCheckSlot: false, showsEventButtons: false, hasRoute: false,
                                           flightActive: true), .routes)
    }

    func testTheSlotTravelsToTheCompanion() throws {
        for slot in [CheckSlot.make(phase: .cruise, check: .list(open: 0), next: .descent,
                                    freda: .counting(after: .freda, at: Date(timeIntervalSince1970: 60), minutesLeft: 4)),
                     CheckSlot.make(phase: .climb, check: .memory(done: false), next: .cruise, timing: .owed, owedBy: .levelOff),
                     CheckSlot.make(phase: .cruise, check: .list(open: 0), next: .descent, freda: .due(waypoint: "LSGC"))] {
            XCTAssertEqual(try JSONDecoder().decode(CheckSlot.self, from: JSONEncoder().encode(slot)), slot)
        }
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

    /// The check before departure, every item checked: the slot offers READY FOR LINE UP, never "READY
    /// FOR LINE UP first", and its tap records the take-off estimate on the way to the line up check. (6.2)
    @MainActor
    func testTheSlotOutOfTheCheckBeforeDepartureIsReadyForLineUp() throws {
        let appState = flight(memoryTest: false)
        try XCTSkipIf(appState.checkItems(.beforeDeparture).isEmpty)
        appState.currentPhase = .beforeDeparture
        XCTAssertNil(CockpitCheckSlot.pendingAction(in: appState), "nothing to press first")
        XCTAssertEqual(CockpitCheckSlot.slot(for: appState).action, .showChecklist, "the list first")

        appState.markLastItemComplete(learningMode: appState.effectiveLearningMode)
        let slot = CockpitCheckSlot.slot(for: appState)
        XCTAssertTrue(slot.readiesForLineUp)
        XCTAssertEqual(slot.action, .advance)
        XCTAssertEqual(slot.titleText(), L10n.ChecklistAction.readyForLineUp)

        CockpitCheckSlot.perform(slot.action, appState: appState, onShowChecklist: {})
        XCTAssertEqual(appState.currentPhase, .lineUp)
        XCTAssertNotNil(appState.lineUpTime)
        XCTAssertEqual(appState.phaseCompletionStatus[.beforeDeparture], .completed)
    }
}
