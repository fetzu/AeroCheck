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
    /// deferred, and nothing ever listed them again.
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
        XCTAssertEqual(appState.deferredItems[.beforeEngineStart], jumped.map(\.id), "the phase jumped over")
        XCTAssertEqual(appState.deferredItemCount, open.count + jumped.count)
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
    }

    /// The rule the author confirmed: a new circuit clears what was deferred in the phases it repeats,
    /// and only those, for all three ways a circuit ends.
    func testEachNewCircuitClearsOnlyTheRepeatedPhases() {
        let repeated: [(String, ChecklistPhase, (AppState) -> Void)] = [
            ("go-around", .climb, { $0.recordGoAround(at: Date()) }),
            ("touch-and-go", .climb, { $0.recordTouchAndGo(at: Date()) }),
            ("full stop", .taxi, { $0.recordFullStop(at: Date()) }),
        ]
        for (name, first, event) in repeated {
            let appState = flight()
            for phase in ChecklistPhase.allCases { appState.deferredItems[phase] = ["x"] }
            event(appState)
            for phase in ChecklistPhase.allCases {
                let cleared = phase.rawValue >= first.rawValue
                    && (first != .taxi || phase.rawValue <= ChecklistPhase.afterLanding.rawValue)
                XCTAssertEqual(appState.deferredItems[phase] == nil, cleared, "\(name): \(phase)")
            }
        }
    }
}
