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

    /// The slot is the act band's first, in one frame on every page (6.2): on MAP in every phase, route or
    /// not, circuits or not; on CHECKLIST wherever the phase has no action of its own and isn't cruise
    /// (Q11). From circuit height GO AROUND and TOUCH-AND-GO take the places after it, never its own.
    /// Before the band, the landscape column and the bottom row each had their rule (`MapThumbColumn`,
    /// `MapThumbRow`). (6.1, the author's call: the slot stays left)
    func testTheSlotIsTheActBandsFirst() {
        for phase in ChecklistPhase.allCases {
            for route in [false, true] {
                for circuits in [false, true] {
                    for landingShown in [false, true] {
                        let map = ActBandRoles.make(page: .map, phase: phase, hasRoute: route, circuits: circuits,
                                                    landingShown: landingShown)
                        XCTAssertEqual(map.first, .checkSlot, "\(phase), route \(route), circuits \(circuits)")
                        XCTAssertEqual(map.filter { $0 == .checkSlot }.count, 1)
                    }
                }
            }
            let checklist = ActBandRoles.make(page: .checklist, phase: phase, hasRoute: true)
            let ownSlot = !phase.showsEngineStartButton && !phase.showsEngineShutdownButton && phase != .cruise
            XCTAssertEqual(checklist.first == .checkSlot, ownSlot, "\(phase) on CHECKLIST")
        }
        XCTAssertEqual(ActBandRoles.make(page: .map, phase: .approach, hasRoute: false, circuits: true, landingShown: true),
                       [.checkSlot, .goAround, .touchAndGo, .more(withDivert: false)], "circuits: slot, GO AROUND, TOUCH-AND-GO")
        XCTAssertEqual(ActBandRoles.make(page: .map, phase: .cruise, hasRoute: false)[1], .routes,
                       "Routes after the slot, not before it")
    }

    // MARK: Its lines hold still

    /// The line under the name, beside MARK on the iPad and on the phone: its lines and size come from its
    /// room, the state's at its widest, so FREDA counting down changes nothing; the letters keep their line
    /// over the waypoint's. The room itself is `CheckSlotLabelLayoutTests`'. (6.1, stability; set by
    /// `ActFace` since 6.2)
    func testTheSecondLineKeepsItsRoom() {
        let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let counting = (1...10).map {
            CheckSlot.make(phase: .cruise, check: .list(open: 0), next: .descent,
                           freda: .counting(after: .cruiseCheck, at: at, minutesLeft: $0))
        }
        for (scale, width) in [(CockpitScale.kneeboard, CGFloat(156)), (.phone, 84)] {
            let height = CockpitType.size(kneeboard: 104, phone: 92, scale: scale) - 6
            let settings = Set(counting.map { slot in
                ActFace.set(CheckSlotLabel.blocks(slot, scale: scale), width: width, height: height, spacing: 2)
                    .map { "\($0.roomLines) \($0.size)" }
            })
            XCTAssertEqual(settings.count, 1, "\(scale): \(settings)")
        }
        let due = CheckSlot.make(phase: .cruise, check: .list(open: 0), next: .descent, freda: .due(waypoint: "LSGC"))
        let line = ActFace.set(CheckSlotLabel.blocks(due, scale: .kneeboard), width: 156, height: 98, spacing: 2).last
        XCTAssertEqual(line?.lines, [L10n.Freda.flowCompact, "LSGC"], "the letters over the waypoint, on the iPad")
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
    /// icon and the gap), the landscape column's, and the phone's act band slot on an iPhone 17 (100 pt,
    /// less its inset) and 17e (94).
    private enum TextWidth {
        static let iPadSharedRow: CGFloat = 256 - 2 * 22 - 32 - 16
        static let iPadColumn: CGFloat = 388 - 2 * 22 - 32 - 16
        static let phoneSlot: CGFloat = 100 - 2 * ActFace.inset
        static let narrowestPhoneSlot: CGFloat = 94 - 2 * ActFace.inset
    }

    /// The phone's slot as `ActFace` sets it: its 92 pt less the border, 3 pt each side.
    private func phoneSetting(_ slot: CheckSlot, width: CGFloat = TextWidth.phoneSlot) -> [ActFace.Setting] {
        ActFace.set(CheckSlotLabel.blocks(slot, scale: .phone), width: width, height: 92 - 2 * 3, spacing: 2)
    }

    /// The iPad's, beside MARK: its 104 pt less the border.
    private func iPadSetting(_ slot: CheckSlot, width: CGFloat = TextWidth.iPadSharedRow) -> [ActFace.Setting] {
        ActFace.set(CheckSlotLabel.blocks(slot, scale: .kneeboard), width: width, height: 104 - 2 * 3, spacing: 2)
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
        // The device check: an iPad in portrait, cruise, the slot beside MARK. The face is set to fit
        // (`ActFace`, 6.2), which centres the block in the slot: with nothing kept under the two lines,
        // their middle is the slot's. With a second line kept empty, they sat about 12 pt above it.
        let slot = CheckSlot.make(phase: .cruise, check: .list(open: 5), next: .descent)
        for settings in [iPadSetting(slot), iPadSetting(slot, width: TextWidth.iPadColumn), phoneSetting(slot)] {
            for setting in settings {
                XCTAssertEqual(setting.roomLines.count, setting.lines.count, "\(setting.lines)")
            }
        }
        let label = CockpitType.label(for: .kneeboard)
        XCTAssertEqual(iPadSetting(slot).map(\.lines.count), [1, 1], "the name on one line, \"5 items\" on one")
        XCTAssertGreaterThanOrEqual(iPadSetting(slot).first?.size ?? 0, label, "the name at the label size or over")
        XCTAssertEqual(iPadSetting(slot).last?.size, label)
    }

    func testFredaCountingDownNeverMovesTheName() throws {
        // A width where "FREDA in 10 min" wraps and "FREDA in 9 min" doesn't: the room is the state's,
        // not the minute's, and the name keeps its place, as before.
        let size = CockpitType.label(for: .phone)
        let width = try XCTUnwrap(stride(from: CGFloat(60), through: 300, by: 1).first { width in
            plain(counting(10).lineText(narrow: true), size: size, weight: .medium, lines: 2, width: width)
                > plain(counting(9).lineText(narrow: true), size: size, weight: .medium, lines: 2, width: width)
        })
        for width in [width, TextWidth.iPadSharedRow, TextWidth.iPadColumn] {
            let settings = Set((1...10).map { minutes in
                iPadSetting(counting(minutes), width: width).map { "\($0.roomLines) \($0.size)" }
            })
            XCTAssertEqual(settings.count, 1, "the iPad at \(width) pt: \(settings)")
        }
        // The phone's act band slot sets the name and its line by their room: the same lines at the same
        // size every minute. (6.2)
        for width in [width, TextWidth.phoneSlot, TextWidth.narrowestPhoneSlot] {
            let settings = Set((1...10).map { minutes in
                phoneSetting(counting(minutes), width: width).map { "\($0.roomLines) \($0.size)" }
            })
            XCTAssertEqual(settings.count, 1, "the phone at \(width) pt: \(settings)")
        }
        // The Companion iPhone's wide slot too.
        XCTAssertEqual(Set((1...10).map { label(counting($0), .phone, width: 300, prominent: true) }).count, 1)
    }

    func testTheTimeOfTheTickNeverMovesTheName() {
        // "CRUISE CHECK ✓ 9:05" and "✓ 14:24": the same room, on a 24-hour clock and on a 12-hour one
        // ("9:05 AM", "2:24 PM"). Not only on the test host's own clock: a host that can't read the
        // simulator's preferences falls back to en_US, a 12-hour clock, where this failed with "✓ 00:00
        // AM" against "✓ 00:00 PM". (6.2)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let morning = calendar.date(bySettingHour: 9, minute: 5, second: 0, of: at)!
        let afternoon = calendar.date(bySettingHour: 14, minute: 24, second: 0, of: at)!
        for identifier in ["en_CH", "fr_CH", "en_US"] {
            let locale = Locale(identifier: identifier)
            for stacked in [false, true] {
                XCTAssertEqual(counting(6, at: morning).titleRoom(stacked: stacked, locale: locale),
                               counting(6, at: afternoon).titleRoom(stacked: stacked, locale: locale),
                               "\(identifier), stacked: \(stacked)")
            }
        }
        let twelveHour = Locale(identifier: "en_US")
        XCTAssertTrue(counting(6, at: morning).titleText(locale: twelveHour).hasSuffix("AM"), "a 12-hour clock here")
        XCTAssertEqual(counting(6, at: morning).titleRoom(locale: twelveHour).filter(\.isNumber).count, 4,
                       "two figures to the hour: \(counting(6, at: morning).titleRoom(locale: twelveHour))")
        XCTAssertEqual(iPadSetting(counting(6, at: morning)).map(\.roomLines),
                       iPadSetting(counting(6, at: afternoon)).map(\.roomLines), "the iPad")
        XCTAssertEqual(iPadSetting(counting(6, at: morning)).map(\.size),
                       iPadSetting(counting(6, at: afternoon)).map(\.size))
        XCTAssertEqual(phoneSetting(counting(6, at: morning)).map(\.roomLines),
                       phoneSetting(counting(6, at: afternoon)).map(\.roomLines), "the phone")
        XCTAssertEqual(phoneSetting(counting(6, at: morning)).map(\.size),
                       phoneSetting(counting(6, at: afternoon)).map(\.size))
    }

    func testALineShrinkingToFitNeverMovesTheName() {
        // Under FREDA's tick on the iPad, in a slot too narrow for its words at their size ("FREDA dans 10
        // min" in 110 pt): set smaller, by as much for every minute, so the room holds.
        let narrow: CGFloat = 110
        let settings = (1...10).map { iPadSetting(counting($0), width: narrow) }
        XCTAssertLessThan(settings[0].map(\.size).min() ?? 0, iPadSetting(counting(10), width: TextWidth.iPadColumn).map(\.size).min() ?? 0,
                          "it shrinks at \(narrow) pt")
        XCTAssertEqual(Set(settings.map { $0.map { "\($0.roomLines) \($0.size)" } }).count, 1)
    }

    func testANameTooLongForThePhonesSlotTakesLinesNotRoom() {
        // A name too long for one line of the phone's slot ("CHECK BEFORE ENGINE START", "AVANT
        // DÉMARRAGE") takes the lines it needs, at its size where they fit, and keeps no empty line: the
        // block stays in the middle. Before 6.2 it shrank to fit two lines, to about 11 pt. (6.2)
        let slot = CheckSlot.make(phase: .beforeEngineStart, check: .list(open: 4), next: .engineStart)
        for width: CGFloat in [64, TextWidth.narrowestPhoneSlot, TextWidth.phoneSlot] {
            let settings = phoneSetting(slot, width: width)
            for setting in settings {
                XCTAssertEqual(setting.roomLines.count, setting.lines.count, "at \(width) pt: \(setting.lines)")
            }
            let height = zip(CheckSlotLabel.blocks(slot, scale: .phone), settings).reduce(CGFloat(2)) {
                $0 + CGFloat($1.1.lines.count) * ActFace.lineHeight(size: $1.1.size, block: $1.0)
            }
            XCTAssertLessThanOrEqual(height, 92 - 6, "at \(width) pt")
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
