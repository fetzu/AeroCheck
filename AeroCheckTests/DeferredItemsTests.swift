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
}
