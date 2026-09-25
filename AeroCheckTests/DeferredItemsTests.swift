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

    func testSteppingBackReopensItemsAndTakesThemOffTheDeferredList() throws {
        let appState = flight()
        let list = visible(appState, .preflight)
        try XCTSkipIf(list.count < 4 || list[0].isHeader || list[1].isHeader)
        appState.advanceHighlightedItem(learningMode: appState.effectiveLearningMode)   // 0 checked
        appState.deferHighlightedItem()                                                 // 1 deferred
        appState.advanceHighlightedItem(learningMode: appState.effectiveLearningMode)   // 2 checked
        XCTAssertEqual(appState.getHighlightedItem(for: .preflight), 3)

        appState.stepBack(toItemAt: 1)
        XCTAssertEqual(appState.getHighlightedItem(for: .preflight), 1)
        XCTAssertNil(appState.deferredItems[.preflight], "item 1 is the current one again, not deferred")

        appState.stepBack(toItemAt: 2)
        XCTAssertEqual(appState.getHighlightedItem(for: .preflight), 1, "can't step forward")
    }
}
