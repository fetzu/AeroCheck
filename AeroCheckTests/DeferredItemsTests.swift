import XCTest
@testable import AeroCheck

/// Items left unchecked by NEXT: listed before the phase is left, then kept as deferred items until
/// they are checked. (v6.0 · B2)
@MainActor
final class DeferredItemsTests: XCTestCase {

    private func flight(learningMode: Bool = true, stepByStep: Bool = true) -> AppState {
        let appState = makeTestAppState()
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.settings.learningMode = learningMode
        appState.settings.stepByStepHighlighting = stepByStep
        appState.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9")
        addTeardownBlock { @MainActor in appState.cancelFlight() }
        return appState
    }

    private func items(_ appState: AppState, _ phase: ChecklistPhase) -> [ChecklistItem] {
        appState.activeChecklist.visibleItems(for: phase, learningMode: true).filter { !$0.isHeader }
    }

    func testNextWithItemsOpenDefersThem() throws {
        let appState = flight()
        let preflight = items(appState, .preflight)
        try XCTSkipIf(preflight.count < 2, "needs a phase with at least two items")
        appState.advanceHighlightedItem(learningMode: true)          // the first one checked

        let open = appState.openItems(in: .preflight)
        XCTAssertEqual(open.map(\.id), preflight.dropFirst().map(\.id), "the unchecked ones, in order")

        appState.nextPhase()
        XCTAssertEqual(appState.currentPhase, .beforeEngineStart)
        XCTAssertEqual(appState.phaseCompletionStatus[.preflight], .skipped)
        XCTAssertEqual(appState.deferredItems[.preflight], open.map(\.id))
        XCTAssertEqual(appState.deferredItemCount, preflight.count - 1)
        XCTAssertEqual(appState.deferredChecklist.first?.phase, .preflight)
    }

    func testAPhaseWorkedThroughDefersNothing() {
        let appState = flight()
        appState.markLastItemComplete(learningMode: true)
        XCTAssertTrue(appState.openItems(in: .preflight).isEmpty)
        appState.nextPhase()
        XCTAssertEqual(appState.phaseCompletionStatus[.preflight], .completed)
        XCTAssertEqual(appState.deferredItemCount, 0)
    }

    func testCheckingTheLastDeferredItemTurnsThePhaseGreen() {
        let appState = flight()
        appState.nextPhase()
        XCTAssertEqual(appState.phaseCompletionStatus[.preflight], .skipped)

        let ids = appState.deferredItems[.preflight] ?? []
        XCTAssertFalse(ids.isEmpty)
        for id in ids.dropLast() { appState.checkDeferredItem(id, in: .preflight) }
        XCTAssertEqual(appState.phaseCompletionStatus[.preflight], .skipped, "one still open")
        appState.checkDeferredItem(ids.last!, in: .preflight)

        XCTAssertNil(appState.deferredItems[.preflight])
        XCTAssertEqual(appState.deferredItemCount, 0)
        XCTAssertEqual(appState.phaseCompletionStatus[.preflight], .completed)
    }

    func testAPhaseMissingItsButtonStaysRedOnceItsItemsAreChecked() {
        let appState = flight()
        appState.currentPhase = .engineStart                         // ENGINE START never pressed
        XCTAssertFalse(appState.openItems(in: .engineStart).isEmpty)
        appState.nextPhase()
        XCTAssertEqual(appState.phaseCompletionStatus[.engineStart], .missingAction)

        for id in appState.deferredItems[.engineStart] ?? [] {
            appState.checkDeferredItem(id, in: .engineStart)
        }
        XCTAssertEqual(appState.phaseCompletionStatus[.engineStart], .missingAction,
                       "checking items doesn't record the engine start")
    }

    func testWithoutStepByStepNothingIsTracked() {
        let appState = flight(stepByStep: false)
        XCTAssertTrue(appState.openItems(in: .preflight).isEmpty)
        appState.nextPhase()
        XCTAssertEqual(appState.deferredItemCount, 0)
        XCTAssertEqual(appState.phaseCompletionStatus[.preflight], .completed)
    }

    func testHiddenMemoryItemsAreOnlyOpenOnceRevealed() throws {
        let appState = flight(learningMode: false)
        appState.currentPhase = .engineStart
        let shown = appState.activeChecklist.visibleItems(for: .engineStart, learningMode: false)
        let all = appState.activeChecklist.visibleItems(for: .engineStart, learningMode: true)
        try XCTSkipIf(shown.count == all.count, "needs a phase with hidden memory items")

        XCTAssertEqual(appState.openItems(in: .engineStart).count, shown.count, "hidden items aren't on screen")
        appState.hiddenItemsRevealed = true
        XCTAssertEqual(appState.openItems(in: .engineStart).count, all.count)
    }

    func testANewCircuitClearsTheLastCircuitsDeferredItems() {
        let appState = flight()
        appState.currentPhase = .approach
        appState.nextPhase()
        XCTAssertNotNil(appState.deferredItems[.approach])
        appState.deferredItems[.preflight] = ["kept"]

        appState.recordTouchAndGo(at: Date())

        XCTAssertNil(appState.deferredItems[.approach], "that approach is over; the next one starts clean")
        XCTAssertEqual(appState.deferredItems[.preflight], ["kept"], "phases before the circuit stay deferred")
    }

    func testDeferredItemsSurviveACrash() throws {
        let source = flight()
        source.nextPhase()
        let ids = try XCTUnwrap(source.deferredItems[.preflight])

        let snapshot = ActiveFlightState(flight: try XCTUnwrap(source.currentFlight), from: source)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ActiveFlightState.self, from: encoder.encode(snapshot))

        let restored = makeTestAppState()
        decoded.restore(to: restored)
        XCTAssertEqual(restored.deferredItems[.preflight], ids)
        restored.isFlightActive = false
    }

    func testACheckpointFromBefore6StillRestores() throws {
        let source = flight()
        let snapshot = ActiveFlightState(flight: try XCTUnwrap(source.currentFlight), from: source)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? [String: Any])
        json.removeValue(forKey: "deferredItems")
        let old = try JSONSerialization.data(withJSONObject: json)

        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ActiveFlightState.self, from: old)
        let restored = makeTestAppState()
        restored.deferredItems = [.taxi: ["stale"]]
        decoded.restore(to: restored)
        XCTAssertTrue(restored.deferredItems.isEmpty)
        restored.isFlightActive = false
    }

    // MARK: DEFER inside a phase (the Cockpit, v6.0 · P2)

    /// All visible items, headers included, as the highlight index counts them.
    private func visible(_ appState: AppState, _ phase: ChecklistPhase) -> [ChecklistItem] {
        appState.activeChecklist.visibleItems(for: phase, learningMode: appState.effectiveLearningMode)
    }

    func testDeferKeepsTheItemAndMovesOn() throws {
        let appState = flight()
        let list = visible(appState, .preflight)
        try XCTSkipIf(list.count < 3 || list[0].isHeader, "needs a phase opening on an item")
        appState.deferHighlightedItem()
        XCTAssertEqual(appState.getHighlightedItem(for: .preflight), 1)
        XCTAssertEqual(appState.deferredItems[.preflight], [list[0].id])
        XCTAssertEqual(appState.currentPhaseDeferredIds, [list[0].id])
        XCTAssertEqual(appState.deferredItemCount, 1, "listed with the other deferred items at once")
    }

    func testDeferringTheLastItemReachesTheEnd() throws {
        let appState = flight()
        let list = visible(appState, .preflight)
        try XCTSkipIf(list.last?.isHeader ?? true)
        appState.currentHighlightedItem[.preflight] = list.count - 1
        appState.deferHighlightedItem()
        XCTAssertTrue(appState.areAllItemsCompleted(learningMode: appState.effectiveLearningMode))
        XCTAssertEqual(appState.deferredItems[.preflight], [list.last!.id])
    }

    func testAPhaseLeftWithADeferredItemIsNotComplete() throws {
        let appState = flight()
        let list = visible(appState, .preflight)
        try XCTSkipIf(list.count < 2 || list[0].isHeader)
        appState.deferHighlightedItem()                               // the first one, deferred
        appState.markLastItemComplete(learningMode: appState.effectiveLearningMode)   // the rest, checked
        XCTAssertTrue(appState.openItems(in: .preflight).isEmpty, "nothing left to review on NEXT")

        appState.nextPhase()
        XCTAssertEqual(appState.phaseCompletionStatus[.preflight], .skipped)
        XCTAssertEqual(appState.deferredItems[.preflight], [list[0].id], "kept, not overwritten")

        appState.checkDeferredItem(list[0].id, in: .preflight)
        XCTAssertEqual(appState.phaseCompletionStatus[.preflight], .completed)
    }

    func testNextMergesDeferredAndOpenItemsInListOrder() throws {
        let appState = flight()
        let list = visible(appState, .preflight).filter { !$0.isHeader }
        try XCTSkipIf(list.count < 3 || visible(appState, .preflight)[0].isHeader)
        appState.deferHighlightedItem()                               // item 0 deferred, item 1 current
        appState.nextPhase()                                          // items 1… still open

        let ids = try XCTUnwrap(appState.deferredItems[.preflight])
        XCTAssertEqual(ids.first, list[0].id)
        XCTAssertEqual(Set(ids), Set(list.map(\.id)), "every item, once")
        XCTAssertEqual(ids.count, list.count)
    }

    // MARK: A tap on a checked item (v6.0 review, K-C)

    /// Stepping back reopened the tapped item and everything after it, with no undo. Now only that item
    /// opens, and the same tap checks it again.
    func testATapOnACheckedItemReopensOnlyThatItem() throws {
        let appState = flight()
        let list = visible(appState, .preflight)
        try XCTSkipIf(list.count < 4 || list[0...2].contains(where: \.isHeader))
        for _ in 0..<3 { appState.advanceHighlightedItem(learningMode: appState.effectiveLearningMode) }
        XCTAssertEqual(appState.getHighlightedItem(for: .preflight), 3)

        appState.toggleItem(at: 1)
        XCTAssertEqual(appState.getHighlightedItem(for: .preflight), 3, "the highlight stays")
        XCTAssertEqual(appState.deferredItems[.preflight], [list[1].id], "open, as a deferred item")
        XCTAssertEqual(appState.deferredItemCount, 1)

        appState.toggleItem(at: 1)
        XCTAssertNil(appState.deferredItems[.preflight], "the same tap checks it again")
        XCTAssertEqual(appState.getHighlightedItem(for: .preflight), 3)
    }

    func testReopenedItemsKeepTheListOrder() throws {
        let appState = flight()
        let list = visible(appState, .preflight)
        try XCTSkipIf(list.count < 4 || list[0...2].contains(where: \.isHeader))
        for _ in 0..<3 { appState.advanceHighlightedItem(learningMode: appState.effectiveLearningMode) }
        appState.toggleItem(at: 2)
        appState.toggleItem(at: 0)
        XCTAssertEqual(appState.deferredItems[.preflight], [list[0].id, list[2].id])
    }

    func testATapOnADeferredItemChecksIt() throws {
        let appState = flight()
        let list = visible(appState, .preflight)
        try XCTSkipIf(list.count < 3 || list[0].isHeader)
        appState.deferHighlightedItem()
        XCTAssertEqual(appState.deferredItems[.preflight], [list[0].id])
        appState.toggleItem(at: 0)
        XCTAssertNil(appState.deferredItems[.preflight])
    }

    func testATapAtOrBelowTheHighlightDoesNothing() throws {
        let appState = flight()
        let list = visible(appState, .preflight)
        try XCTSkipIf(list.count < 3 || list[0].isHeader)
        appState.advanceHighlightedItem(learningMode: appState.effectiveLearningMode)
        appState.toggleItem(at: 1)
        appState.toggleItem(at: 2)
        XCTAssertNil(appState.deferredItems[.preflight])
        XCTAssertEqual(appState.getHighlightedItem(for: .preflight), 1)
    }

    // MARK: The phase bar and circuits (v6.0 review, B1)

    /// The device case: tapping ahead on the phase bar left the open items neither checked nor
    /// deferred, and nothing ever listed them again. The phase left part-way keeps its open items one
    /// by one; the phase jumped over is deferred whole. (v6.0 review, J1)
    func testAJumpOnThePhaseBarDefersLikeNext() throws {
        let appState = flight()
        let preflight = items(appState, .preflight)
        let jumped = items(appState, .beforeEngineStart)
        try XCTSkipIf(preflight.count < 2 || jumped.isEmpty, "needs two phases with items")
        appState.advanceHighlightedItem(learningMode: true)          // the first one checked
        let open = appState.openItems(in: .preflight).map(\.id)

        appState.goToPhase(.engineStart)

        XCTAssertEqual(appState.currentPhase, .engineStart)
        XCTAssertEqual(appState.deferredItems[.preflight], open, "the phase left, as NEXT leaves it")
        XCTAssertEqual(appState.phaseCompletionStatus[.preflight], .skipped)
        XCTAssertEqual(appState.deferredChecks, [.beforeEngineStart], "the phase jumped over, whole")
        XCTAssertNil(appState.deferredItems[.beforeEngineStart], "not item by item")
        XCTAssertEqual(appState.phaseCompletionStatus[.beforeEngineStart], .skipped)
        XCTAssertEqual(appState.deferredItemCount, open.count)
        XCTAssertTrue(appState.hasDeferredWork)
    }

    func testAJumpFromAWorkedThroughPhaseLeavesItGreen() {
        let appState = flight()
        appState.markLastItemComplete(learningMode: true)
        appState.goToPhase(.beforeEngineStart)
        XCTAssertEqual(appState.phaseCompletionStatus[.preflight], .completed)
        XCTAssertNil(appState.deferredItems[.preflight])
    }

    /// Back to the phase just left by mistake: its open items are open on screen again, not also
    /// waiting in the deferred list to be checked a second time.
    func testComingBackTakesTheOpenItemsOffTheDeferredList() throws {
        let appState = flight()
        let list = visible(appState, .preflight)
        try XCTSkipIf(list.count < 3 || list[0].isHeader || list[1].isHeader)
        appState.deferHighlightedItem()                               // item 0 deferred with DEFER
        appState.goToPhase(.beforeEngineStart)                        // items 1… deferred by the jump
        XCTAssertEqual(appState.deferredItems[.preflight]?.count, list.filter { !$0.isHeader }.count)

        appState.goToPhase(.preflight)

        XCTAssertEqual(appState.deferredItems[.preflight], [list[0].id], "only what DEFER put off")
        XCTAssertEqual(appState.openItems(in: .preflight).first?.id, list[1].id)
    }

    func testNextBackReopensToo() throws {
        let appState = flight()
        try XCTSkipIf(items(appState, .preflight).isEmpty)
        appState.nextPhase()
        XCTAssertNotNil(appState.deferredItems[.preflight])
        appState.previousPhase()
        XCTAssertEqual(appState.currentPhase, .preflight)
        XCTAssertNil(appState.deferredItems[.preflight])
    }

    func testAJumpInCircuitModeDefersNothingForCruiseAndDescent() {
        let appState = flight()
        appState.isCircuitMode = true
        appState.currentPhase = .climb
        appState.markLastItemComplete(learningMode: true)
        appState.goToPhase(.approach)
        XCTAssertNil(appState.deferredItems[.cruise])
        XCTAssertNil(appState.deferredItems[.descent])
        XCTAssertEqual(appState.deferredItemCount, 0)
        XCTAssertTrue(appState.deferredChecks.isEmpty, "not flown, so not owed")
        XCTAssertTrue(appState.checksPassed(jumpingTo: .approach).isEmpty)
    }

    /// The rule the author confirmed: a new circuit clears what was deferred in the phases it repeats,
    /// and only those, for all three ways a circuit ends. On circuits: a full stop on any other flight
    /// is the landing and clears nothing (`FullStopLandingTests`).
    func testEachNewCircuitClearsOnlyTheRepeatedPhases() {
        let repeated: [(String, ChecklistPhase, (AppState) -> Void)] = [
            ("go-around", .climb, { $0.recordGoAround(at: Date()) }),
            ("touch-and-go", .climb, { $0.recordTouchAndGo(at: Date()) }),
            ("full stop", .taxi, { $0.recordFullStop(at: Date()) }),
        ]
        for (name, first, event) in repeated {
            let appState = flight()
            appState.isCircuitMode = true
            for phase in ChecklistPhase.allCases { appState.deferredItems[phase] = ["x"] }
            appState.deferredChecks = ChecklistPhase.allCases
            event(appState)
            for phase in ChecklistPhase.allCases {
                let cleared = phase.rawValue >= first.rawValue
                    && (first != .taxi || phase.rawValue <= ChecklistPhase.afterLanding.rawValue)
                XCTAssertEqual(appState.deferredItems[phase] == nil, cleared, "\(name): \(phase)")
                XCTAssertEqual(!appState.deferredChecks.contains(phase), cleared, "\(name), check: \(phase)")
            }
        }
    }

    // MARK: Checks deferred whole, and the jump question (v6.0 review, J1-J3)

    private func runToTheEnd(_ appState: AppState, _ phase: ChecklistPhase) {
        var guardCount = 0
        while appState.deferredChecks.contains(phase) && guardCount < 200 {
            appState.checkItem(inDeferredCheck: phase)
            guardCount += 1
        }
    }

    func testAPhaseLeftUntouchedIsDeferredWhole() throws {
        let appState = flight()
        try XCTSkipIf(items(appState, .preflight).isEmpty)
        appState.goToPhase(.beforeEngineStart)
        XCTAssertEqual(appState.deferredChecks, [.preflight])
        XCTAssertNil(appState.deferredItems[.preflight])
        XCTAssertEqual(appState.phaseCompletionStatus[.preflight], .skipped)
    }

    func testNextStillDefersItemByItem() throws {
        let appState = flight()
        try XCTSkipIf(items(appState, .preflight).isEmpty)
        appState.nextPhase()
        XCTAssertTrue(appState.deferredChecks.isEmpty, "NEXT goes through the review, item by item")
        XCTAssertNotNil(appState.deferredItems[.preflight])
    }

    /// J2: a jump that passes over two checks or more asks; one check, or the next phase, doesn't.
    func testTheQuestionComesFromTwoChecksPassed() {
        let appState = flight()
        XCTAssertFalse(appState.jumpNeedsQuestion(to: .beforeEngineStart))
        XCTAssertFalse(appState.jumpNeedsQuestion(to: .engineStart), "one check passed")
        XCTAssertEqual(appState.checksPassed(jumpingTo: .afterEngineStart), [.beforeEngineStart, .engineStart])
        XCTAssertTrue(appState.jumpNeedsQuestion(to: .afterEngineStart))
        XCTAssertFalse(appState.jumpNeedsQuestion(to: .preflight), "never going back")
    }

    func testChecksAlreadyWorkedThroughDontCount() {
        let appState = flight()
        appState.currentPhase = .beforeEngineStart
        appState.markLastItemComplete(learningMode: true)
        appState.currentPhase = .preflight
        XCTAssertEqual(appState.checksPassed(jumpingTo: .afterEngineStart), [.engineStart])
        XCTAssertFalse(appState.jumpNeedsQuestion(to: .afterEngineStart))
    }

    func testNoQuestionWithoutStepByStep() {
        let appState = flight(stepByStep: false)
        XCTAssertFalse(appState.jumpNeedsQuestion(to: .cruise))
    }

    /// J3's DEFER: every check left undone is listed, in flight order, the phase left included.
    func testDeferringTheChecksListsEachOne() {
        let appState = flight()
        appState.goToPhase(.afterEngineStart, skipped: .deferred)
        let owed = [ChecklistPhase.preflight, .beforeEngineStart, .engineStart].filter { !items(appState, $0).isEmpty }
        XCTAssertEqual(appState.deferredChecks, owed)
        XCTAssertEqual(appState.deferredItemCount, 0)
        XCTAssertEqual(appState.deferredCheckList.map(\.phase), owed)
        XCTAssertEqual(appState.deferredCheckList.first?.remaining, appState.deferredCheckList.first?.total)
    }

    /// J3's ALREADY DONE: green and nothing listed; a phase whose own action was never pressed stays red.
    func testAlreadyDoneMarksTheChecksDone() {
        let appState = flight()
        appState.goToPhase(.afterEngineStart, skipped: .alreadyDone)
        XCTAssertTrue(appState.deferredChecks.isEmpty)
        XCTAssertEqual(appState.deferredItemCount, 0)
        XCTAssertEqual(appState.phaseCompletionStatus[.preflight], .completed)
        XCTAssertEqual(appState.phaseCompletionStatus[.beforeEngineStart], .completed)
        XCTAssertEqual(appState.phaseCompletionStatus[.engineStart], .missingAction, "ENGINE START never pressed")
        XCTAssertFalse(appState.hasDeferredWork)
    }

    /// RUN, then CHECK to the end: the check leaves the list and turns green, while the phase being
    /// flown stays where it was.
    func testRunningADeferredCheckToTheEnd() throws {
        let appState = flight()
        try XCTSkipIf(items(appState, .preflight).isEmpty)
        appState.goToPhase(.beforeEngineStart)
        XCTAssertEqual(appState.deferredChecks, [.preflight])

        appState.checkItem(inDeferredCheck: .preflight)
        XCTAssertEqual(appState.getHighlightedItem(for: .preflight), 1)
        XCTAssertEqual(appState.currentPhase, .beforeEngineStart, "the phase flown stays current")

        runToTheEnd(appState, .preflight)
        XCTAssertTrue(appState.deferredChecks.isEmpty)
        XCTAssertEqual(appState.phaseCompletionStatus[.preflight], .completed)
        XCTAssertEqual(appState.currentPhase, .beforeEngineStart)
        XCTAssertEqual(appState.getHighlightedItem(for: .beforeEngineStart), 0, "untouched")
    }

    /// DEFER inside a deferred check: that item stays behind as an item, and the check is orange until
    /// it is checked.
    func testDeferringInsideADeferredCheckLeavesTheItem() throws {
        let appState = flight()
        let list = appState.checkItems(.preflight)
        try XCTSkipIf(list.count < 2 || list[0].isHeader || list[1].isHeader)
        appState.goToPhase(.beforeEngineStart)
        appState.deferItem(inDeferredCheck: .preflight)
        XCTAssertEqual(appState.deferredItems[.preflight], [list[0].id])

        appState.checkDeferredItem(list[0].id, in: .preflight)
        XCTAssertEqual(appState.phaseCompletionStatus[.preflight], .skipped,
                       "the check still has items to run: not green yet")

        appState.deferItem(inDeferredCheck: .preflight)
        runToTheEnd(appState, .preflight)
        XCTAssertTrue(appState.deferredChecks.isEmpty)
        XCTAssertEqual(appState.phaseCompletionStatus[.preflight], .skipped, "one item put off")
        for id in appState.deferredItems[.preflight] ?? [] { appState.checkDeferredItem(id, in: .preflight) }
        XCTAssertEqual(appState.phaseCompletionStatus[.preflight], .completed)
    }

    func testGoingBackToADeferredCheckRunsItInPlace() throws {
        let appState = flight()
        try XCTSkipIf(items(appState, .preflight).isEmpty)
        appState.goToPhase(.beforeEngineStart)
        appState.goToPhase(.preflight)
        XCTAssertEqual(appState.currentPhase, .preflight)
        XCTAssertTrue(appState.deferredChecks.isEmpty, "it is the current phase again, not also listed")
    }

    func testDeferredChecksSurviveACrash() throws {
        let source = flight()
        try XCTSkipIf(items(source, .preflight).isEmpty)
        source.goToPhase(.beforeEngineStart)
        let snapshot = ActiveFlightState(flight: try XCTUnwrap(source.currentFlight), from: source)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ActiveFlightState.self, from: encoder.encode(snapshot))
        let restored = makeTestAppState()
        decoded.restore(to: restored)
        XCTAssertEqual(restored.deferredChecks, [.preflight])
        restored.isFlightActive = false

        // A checkpoint written before deferred checks existed restores with none.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? [String: Any])
        json.removeValue(forKey: "deferredChecks")
        let old = try decoder.decode(ActiveFlightState.self, from: JSONSerialization.data(withJSONObject: json))
        let restoredOld = makeTestAppState()
        old.restore(to: restoredOld)
        XCTAssertTrue(restoredOld.deferredChecks.isEmpty)
        restoredOld.isFlightActive = false
    }
}
