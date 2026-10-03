import SwiftUI
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

    /// Portrait, and the phone on its side: the slot leads the row in every phase, route or not. From
    /// circuit height GO AROUND and TOUCH-AND-GO take the place of MARK, Divert and More (or Routes), and
    /// the slot keeps its own; it moved to the middle between them, every lap. (6.1, the author's call)
    func testInTheBottomRowTheSlotAlwaysLeads() {
        for events in [false, true] {
            for route in [false, true] {
                let row = MapThumbRow.make(showsCheckSlot: true, showsEventButtons: events, hasRoute: route,
                                           flightActive: true)
                XCTAssertTrue(row.slotLeads, "events \(events), route \(route): \(row)")
            }
        }
        XCTAssertEqual(MapThumbRow.make(showsCheckSlot: true, showsEventButtons: true, hasRoute: false,
                                        flightActive: true), .slotThenFlightEvents, "circuits: slot, GO AROUND, TOUCH-AND-GO")
        XCTAssertEqual(MapThumbRow.make(showsCheckSlot: true, showsEventButtons: true, hasRoute: true,
                                        flightActive: true), .slotThenFlightEvents)
        XCTAssertEqual(MapThumbRow.make(showsCheckSlot: true, showsEventButtons: false, hasRoute: true,
                                        flightActive: true), .slotThenMark)
        XCTAssertEqual(MapThumbRow.make(showsCheckSlot: true, showsEventButtons: false, hasRoute: false,
                                        flightActive: true), .slotThenRoutes, "Routes after the slot, not before it")
    }

    func testWithoutTheSlotTheBottomRowIsAsBefore() {
        XCTAssertEqual(MapThumbRow.make(showsCheckSlot: false, showsEventButtons: false, hasRoute: true,
                                        flightActive: true), .legTimerThenMark)
        XCTAssertFalse(MapThumbRow.legTimerThenMark.slotLeads)
        XCTAssertEqual(MapThumbRow.make(showsCheckSlot: false, showsEventButtons: false, hasRoute: true,
                                        flightActive: false), .routes, "Plan › Map: no MARK before the flight")
        XCTAssertEqual(MapThumbRow.make(showsCheckSlot: false, showsEventButtons: false, hasRoute: false,
                                        flightActive: true), .routes)
    }

    // MARK: Its lines hold still

    /// How many lines the second line may take, beside MARK, under FREDA's tick, on the phone. The room
    /// it keeps within that is its state's (`CheckSlotLabelLayoutTests`). (6.1, stability)
    func testTheSecondLineKeepsItsRoom() {
        let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let counting = (1...10).map {
            CheckSlot.make(phase: .cruise, check: .list(open: 0), next: .descent,
                           freda: .counting(after: .cruiseCheck, at: at, minutesLeft: $0))
        }
        // Beside MARK on the iPad, under FREDA's tick on two lines: one line, scaled a little more.
        XCTAssertEqual(Set(counting.map { $0.lineLines(phone: false, prominent: false) }), [1])
        XCTAssertEqual(counting[0].lineMinimumScale(phone: false, prominent: false), 0.7)
        // The phone keeps two, its title and line both fitting its 92 pt.
        XCTAssertEqual(Set(counting.map { $0.lineLines(phone: true, prominent: false) }), [2])

        let owed = CheckSlot.make(phase: .climb, check: .memory(done: false), next: .cruise, timing: .owed, owedBy: .levelOff)
        let due = CheckSlot.make(phase: .climb, check: .memory(done: false), next: .cruise)
        XCTAssertEqual(owed.lineLines(phone: false, prominent: false), due.lineLines(phone: false, prominent: false),
                       "the owed line coming changes nothing above it")
        XCTAssertEqual(due.lineLines(phone: false, prominent: false), 2)
        XCTAssertEqual(due.lineMinimumScale(phone: false, prominent: false), 0.8)
        XCTAssertEqual(CheckSlot.make(phase: .cruise, check: .list(open: 0), next: .descent, freda: .due(waypoint: "LSGC"))
                        .lineLines(phone: false, prominent: false), 2, "the letters over the waypoint")
        XCTAssertEqual(due.lineLines(phone: false, prominent: true), 1, "the wide slot on the iPad")
        XCTAssertEqual(due.lineLines(phone: true, prominent: true), 2)
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

/// The slot's name and its line sit in the middle of the slot, and hold still while a value ticks.
/// Until 6.1.0 the room for a second line of two was kept in every state: "CRUISE CHECK" over a one-line
/// "5 items" sat in the top of the slot over an empty line. The room is now the state's at its widest
/// (`CheckSlot.titleRoom`, `lineRoom`), and the button centres it. (6.1, device check of 3 Oct)
@MainActor
final class CheckSlotLabelLayoutTests: XCTestCase {

    /// The text's room in the slot: the iPad's beside Routes or MARK (256 pt, less its padding, its
    /// icon and the gap), the landscape column's, and the phone's beside MARK.
    private enum TextWidth {
        static let iPadSharedRow: CGFloat = 256 - 2 * 22 - 32 - 16
        static let iPadColumn: CGFloat = 388 - 2 * 22 - 32 - 16
        static let phoneSharedRow: CGFloat = 107 - 2 * 10
    }

    private let at = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func height(_ view: some View, width: CGFloat) -> CGFloat {
        UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 1_000)).height
    }

    private func label(_ slot: CheckSlot, _ scale: CockpitScale, width: CGFloat, prominent: Bool = false) -> CGFloat {
        height(CheckSlotLabel(slot: slot, prominent: prominent, scale: scale), width: width)
    }

    /// A text as the label sets it, without any room kept.
    private func plain(_ text: String, size: CGFloat, weight: Font.Weight, lines: Int, width: CGFloat,
                       minimumScale: CGFloat = 1) -> CGFloat {
        height(Text(verbatim: text).font(.aero(size: size, weight: weight)).lineLimit(lines)
                .minimumScaleFactor(minimumScale), width: width)
    }

    private func counting(_ minutes: Int, at: Date? = nil) -> CheckSlot {
        CheckSlot.make(phase: .cruise, check: .list(open: 0), next: .descent,
                       freda: .counting(after: .cruiseCheck, at: at ?? self.at, minutesLeft: minutes))
    }

    func testTheNameAndItsLineFillTheBlockTheSlotCentres() {
        // The device check: an iPad in portrait, cruise, the map with no route, the slot beside Routes.
        let slot = CheckSlot.make(phase: .cruise, check: .list(open: 5), next: .descent)
        let ipad = CockpitType.label(for: .kneeboard)
        let width = TextWidth.iPadSharedRow
        let name = plain(slot.titleText(stacked: true), size: 25, weight: .bold, lines: 1, width: width, minimumScale: 0.6)
        let line = plain(slot.lineText(stacked: true), size: ipad, weight: .medium, lines: 2, width: width, minimumScale: 0.8)
        XCTAssertEqual(line, plain("A", size: ipad, weight: .medium, lines: 1, width: width), "\"5 items\" takes one line")
        // The button centres the block in its 104 pt: with nothing under the two lines, their middle is
        // the slot's. With a second line kept empty, they sat about 12 pt above it.
        XCTAssertEqual(label(slot, .kneeboard, width: width), name + 4 + line, accuracy: 0.5)

        // The iPad's landscape column, and the phone beside MARK, its name on two lines.
        let column = TextWidth.iPadColumn
        XCTAssertEqual(label(slot, .kneeboard, width: column),
                       plain(slot.titleText(stacked: true), size: 25, weight: .bold, lines: 1, width: column, minimumScale: 0.6)
                       + 4 + plain(slot.lineText(stacked: true), size: ipad, weight: .medium, lines: 2, width: column,
                                   minimumScale: 0.8),
                       accuracy: 0.5)
        let phone = TextWidth.phoneSharedRow
        XCTAssertEqual(label(slot, .phone, width: phone),
                       plain(slot.titleText(stacked: true), size: 19, weight: .bold, lines: 2, width: phone, minimumScale: 0.6)
                       + 4 + plain(slot.lineText(narrow: true), size: CockpitType.label(for: .phone), weight: .medium,
                                   lines: 2, width: phone, minimumScale: 0.8),
                       accuracy: 0.5)
    }

    func testFredaCountingDownNeverMovesTheName() throws {
        // A width where "FREDA in 10 min" wraps and "FREDA in 9 min" doesn't: the room is the state's,
        // not the minute's, and the name keeps its place, as before.
        let size = CockpitType.label(for: .phone)
        let width = try XCTUnwrap(stride(from: CGFloat(60), through: 300, by: 1).first { width in
            plain(counting(10).lineText(narrow: true), size: size, weight: .medium, lines: 2, width: width)
                > plain(counting(9).lineText(narrow: true), size: size, weight: .medium, lines: 2, width: width)
        })
        for scale in [CockpitScale.phone, .kneeboard] {
            for width in [width, TextWidth.phoneSharedRow, TextWidth.iPadSharedRow,
                          TextWidth.iPadColumn] {
                let heights = Set((1...10).map { label(counting($0), scale, width: width) })
                XCTAssertEqual(heights.count, 1, "\(scale) at \(width) pt: \(heights)")
            }
        }
        // The Companion iPhone's wide slot too.
        XCTAssertEqual(Set((1...10).map { label(counting($0), .phone, width: 300, prominent: true) }).count, 1)
    }

    func testTheTimeOfTheTickNeverMovesTheName() {
        // "CRUISE CHECK ✓ 9:05" and "✓ 14:24": the same room.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let morning = calendar.date(bySettingHour: 9, minute: 5, second: 0, of: at)!
        let afternoon = calendar.date(bySettingHour: 14, minute: 24, second: 0, of: at)!
        for (scale, width) in [(CockpitScale.phone, TextWidth.phoneSharedRow), (.kneeboard, TextWidth.iPadSharedRow)] {
            XCTAssertEqual(label(counting(6, at: morning), scale, width: width),
                           label(counting(6, at: afternoon), scale, width: width), "\(scale)")
        }
    }

    func testALineShrinkingToFitNeverMovesTheName() {
        // Under FREDA's tick on the iPad the line has one line, and shrinks to fit a narrow slot ("FREDA
        // dans 10 min" beside "Déroutement"): by as much for every minute, so the room holds.
        let size = CockpitType.label(for: .kneeboard)
        let narrow: CGFloat = 110
        XCTAssertLessThan(plain(counting(10).lineText(stacked: true), size: size, weight: .medium, lines: 1,
                                width: narrow, minimumScale: 0.7),
                          plain(counting(10).lineText(stacked: true), size: size, weight: .medium, lines: 1,
                                width: TextWidth.iPadColumn, minimumScale: 0.7),
                          "it shrinks at \(narrow) pt")
        XCTAssertEqual(Set((1...10).map { label(counting($0), .kneeboard, width: narrow) }).count, 1)
    }

    func testANameShrinkingToFitKeepsNoRoomUnderIt() {
        // A name too long for the phone's slot beside MARK shrinks to fit ("CROISIÈRE" beside
        // "Déroutement", "CHECK BEFORE ENGINE START"): the room is the shrunk name's, so nothing empty
        // is left under it, and the two lines stay in the middle.
        let slot = CheckSlot.make(phase: .beforeEngineStart, check: .list(open: 4), next: .engineStart)
        for width: CGFloat in [64, TextWidth.phoneSharedRow] {
            let name = plain(slot.titleText(stacked: true), size: 19, weight: .bold, lines: 2, width: width,
                             minimumScale: 0.6)
            let line = plain(slot.lineText(narrow: true), size: CockpitType.label(for: .phone), weight: .medium,
                             lines: 2, width: width, minimumScale: 0.8)
            XCTAssertEqual(label(slot, .phone, width: width), name + 4 + line, accuracy: 0.5, "at \(width) pt")
        }
    }

    func testTheRoomIsTheStatesAtItsWidest() {
        XCTAssertEqual(CheckSlot.widestFigures("CRUISE CHECK\n✓ 9:05", atLeast: 2), "CRUISE CHECK\n✓ 00:00")
        XCTAssertEqual(CheckSlot.widestFigures("2:24 PM", atLeast: 2), "00:00 PM")
        XCTAssertEqual(CheckSlot.widestFigures("10/16 · 120", atLeast: 2), "00/00 · 000")
        XCTAssertEqual(CheckSlot.widestFigures("5 items", atLeast: 1), "0 items", "a count as it is")
        XCTAssertEqual(CheckSlot.widestFigures("F·R·E·D·A", atLeast: 2), "F·R·E·D·A")
        XCTAssertEqual(CheckSlot.Line.items(1).widest, .items(2), "the plural")
        XCTAssertEqual(CheckSlot.Line.items(12).widest, .items(12))
        XCTAssertEqual(CheckSlot.Line.fredaIn(minutes: 3).widest, .fredaIn(minutes: 10), "the 10 it counts from")
        XCTAssertEqual(CheckSlot.Line.owed(.levelOff).widest, .owed(.levelOff))
        for minutes in 1...10 {
            XCTAssertEqual(counting(minutes).lineRoom(narrow: true), counting(10).lineRoom(narrow: true))
            XCTAssertEqual(counting(minutes).lineRoom(stacked: true), counting(10).lineRoom(stacked: true))
        }
        let list = { (open: Int) in CheckSlot.make(phase: .cruise, check: .list(open: open), next: .descent) }
        XCTAssertEqual(Set((1...9).map { list($0).lineRoom(stacked: true) }).count, 1, "one to nine items, one room")
    }

    func testTheSlotKeepsItsFrameInEveryState() {
        let states = [
            CheckSlot.make(phase: .cruise, check: .list(open: 5), next: .descent),
            CheckSlot.make(phase: .climb, check: .memory(done: false), next: .cruise),
            CheckSlot.make(phase: .climb, check: .memory(done: false), next: .cruise, timing: .owed, owedBy: .levelOff),
            counting(9),
            CheckSlot.make(phase: .cruise, check: .list(open: 0), next: .descent, freda: .due(waypoint: "SEGNELÉGIER")),
            CheckSlot.make(phase: .climb, check: .list(open: 0), next: .cruise),
            CheckSlot.make(phase: .landing, check: .memory(done: false), next: .afterLanding),
        ]
        for slot in states {
            let size = UIHostingController(rootView: CheckSlotButton(slot: slot) {})
                .sizeThatFits(in: CGSize(width: 256, height: 1_000))
            XCTAssertEqual(size.height, CheckSlotButton.height, "\(slot.line)")
        }
    }
}
