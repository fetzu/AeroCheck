import XCTest
@testable import AeroCheck

/// Memory checks (6.1, "Checks in flight" Q2): a check whose every item the Memory test hides is
/// confirmed with one tap, done from memory (green), with undo. Left unconfirmed it is owed like a check
/// left untouched, never grey. The bundled WT9 flies its line-up and climb checks from memory.
@MainActor
final class MemoryCheckTests: XCTestCase {

    private func flight(memoryTest: Bool = true) -> AppState {
        let appState = makeTestAppState()
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.settings.learningMode = !memoryTest
        appState.settings.stepByStepHighlighting = true
        appState.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9")
        addTeardownBlock { @MainActor in appState.cancelFlight() }
        return appState
    }

    private func requireMemoryChecks(_ appState: AppState, _ phases: [ChecklistPhase] = [.lineUp, .climb]) throws {
        for phase in phases {
            try XCTSkipUnless(appState.isMemoryCheck(phase, learningMode: false), "needs the WT9's memory \(phase)")
        }
    }

    // MARK: What a memory check is

    func testAMemoryCheckWaitsForItsConfirmation() throws {
        let appState = flight()
        try requireMemoryChecks(appState)
        appState.currentPhase = .climb
        XCTAssertTrue(appState.isMemoryCheck(.climb))
        XCTAssertFalse(appState.currentCheckIsDone, "no longer done on arrival")
        XCTAssertTrue(appState.currentCheckAwaitsConfirmation)
    }

    func testWithMemoryTestOffItIsAListLikeAnyOther() {
        let appState = flight(memoryTest: false)
        appState.currentPhase = .climb
        XCTAssertFalse(appState.isMemoryCheck(.climb))
        XCTAssertFalse(appState.currentCheckAwaitsConfirmation)
        appState.nextPhase()
        XCTAssertNotNil(appState.deferredItems[.climb], "NEXT defers its open items one by one, as before")
    }

    func testARevealedMemoryCheckIsAListToWorkThrough() throws {
        let appState = flight()
        try requireMemoryChecks(appState)
        appState.currentPhase = .climb
        appState.hiddenItemsRevealed = true
        XCTAssertFalse(appState.isMemoryCheck(.climb))
        XCTAssertFalse(appState.currentCheckAwaitsConfirmation, "CHECK, not ✓ DONE, while revealed")
        XCTAssertTrue(appState.isMemoryCheck(.climb, learningMode: false), "still one by its configuration")
    }

    // MARK: Confirming

    func testConfirmingRecordsItDoneFromMemory() throws {
        let appState = flight()
        try requireMemoryChecks(appState)
        appState.currentPhase = .climb
        appState.confirmMemoryCheck()
        XCTAssertTrue(appState.currentCheckIsDone)
        XCTAssertFalse(appState.currentCheckAwaitsConfirmation)
        XCTAssertEqual(appState.memoryConfirmation?.phase, .climb)

        appState.nextPhase()
        XCTAssertEqual(appState.currentPhase, .cruise)
        XCTAssertEqual(appState.phaseCompletionStatus[.climb], .doneFromMemory)
        XCTAssertTrue(appState.getPhaseStatus(.climb).isDone)
        XCTAssertTrue(appState.deferredChecks.isEmpty)
    }

    func testConfirmingTwiceChangesNothing() throws {
        let appState = flight()
        try requireMemoryChecks(appState)
        appState.currentPhase = .climb
        appState.confirmMemoryCheck()
        let first = appState.memoryConfirmation?.id
        appState.confirmMemoryCheck()
        XCTAssertEqual(appState.memoryConfirmation?.id, first)
    }

    func testAReadDoCheckCannotBeConfirmedFromMemory() {
        let appState = flight()
        appState.currentPhase = .cruise
        appState.confirmMemoryCheck()
        XCTAssertNil(appState.memoryConfirmation)
        XCTAssertFalse(appState.currentCheckIsDone)
    }

    func testRevealedAndWorkedThroughIsGreenLikeAnyCheck() throws {
        let appState = flight()
        try requireMemoryChecks(appState)
        appState.currentPhase = .climb
        appState.hiddenItemsRevealed = true
        appState.markLastItemComplete(learningMode: true)
        appState.nextPhase()
        XCTAssertEqual(appState.phaseCompletionStatus[.climb], .completed, "no longer grey once worked through")
    }

    func testRevealedWithItemsOpenDefersThemOneByOne() throws {
        let appState = flight()
        try requireMemoryChecks(appState)
        appState.currentPhase = .climb
        appState.hiddenItemsRevealed = true
        appState.nextPhase()
        XCTAssertEqual(appState.phaseCompletionStatus[.climb], .skipped)
        XCTAssertFalse((appState.deferredItems[.climb] ?? []).isEmpty)
        XCTAssertTrue(appState.deferredChecks.isEmpty)
    }

    // MARK: Undo

    func testUndoOpensTheCheckAgain() throws {
        let appState = flight()
        try requireMemoryChecks(appState)
        appState.currentPhase = .climb
        appState.confirmMemoryCheck()
        let id = try XCTUnwrap(appState.memoryConfirmation?.id)
        appState.undoMemoryConfirmation(id)
        XCTAssertNil(appState.memoryConfirmation)
        XCTAssertTrue(appState.currentCheckAwaitsConfirmation)
        XCTAssertNil(appState.phaseCompletionStatus[.climb])
    }

    func testUndoAfterMovingOnDefersTheCheckWhole() throws {
        let appState = flight()
        try requireMemoryChecks(appState)
        appState.currentPhase = .climb
        appState.confirmMemoryCheck()
        let id = try XCTUnwrap(appState.memoryConfirmation?.id)
        appState.nextPhase()
        appState.undoMemoryConfirmation(id)
        XCTAssertEqual(appState.currentPhase, .cruise)
        XCTAssertEqual(appState.deferredChecks, [.climb])
        XCTAssertEqual(appState.phaseCompletionStatus[.climb], .skipped)
    }

    func testAnOldUndoDoesNothing() throws {
        let appState = flight()
        try requireMemoryChecks(appState)
        appState.currentPhase = .climb
        appState.confirmMemoryCheck()
        appState.dismissMemoryConfirmation(try XCTUnwrap(appState.memoryConfirmation?.id))
        appState.undoMemoryConfirmation(UUID())
        XCTAssertTrue(appState.currentCheckIsDone)
    }

    // MARK: Leaving without confirming

    func testLeavingUnconfirmedDefersTheCheckWholeNeverGrey() throws {
        let appState = flight()
        try requireMemoryChecks(appState)
        appState.currentPhase = .climb
        appState.nextPhase()
        XCTAssertEqual(appState.deferredChecks, [.climb])
        XCTAssertEqual(appState.phaseCompletionStatus[.climb], .skipped)
        XCTAssertNil(appState.deferredItems[.climb], "hidden items aren't listed one by one")
        XCTAssertEqual(appState.deferredCheckList.first?.phase, .climb)
    }

    func testAPhaseWithNothingToDoStaysGrey() {
        let appState = flight()
        // A premium aircraft whose checklist hasn't arrived shows nothing at all: still "nothing to do".
        appState.settings.selectedRemoteAircraftId = "not-loaded"
        XCTAssertFalse(appState.isMemoryCheck(.climb))
        appState.currentPhase = .climb
        appState.nextPhase()
        XCTAssertEqual(appState.phaseCompletionStatus[.climb], .empty)
        XCTAssertTrue(appState.deferredChecks.isEmpty)
    }

    func testADeferredMemoryCheckIsConfirmedFromTheList() throws {
        let appState = flight()
        try requireMemoryChecks(appState)
        appState.currentPhase = .climb
        appState.nextPhase()
        appState.confirmMemoryCheck(.climb)
        XCTAssertTrue(appState.deferredChecks.isEmpty)
        XCTAssertEqual(appState.phaseCompletionStatus[.climb], .doneFromMemory)
        XCTAssertEqual(appState.currentPhase, .cruise, "the phase flown stays current")
    }

    func testAnOlderCompanionsRunConfirmsItToo() throws {
        let appState = flight()
        try requireMemoryChecks(appState)
        appState.currentPhase = .climb
        appState.nextPhase()
        // An older phone shows it with RUN, and its CHECK sends this.
        appState.checkItem(inDeferredCheck: .climb)
        XCTAssertTrue(appState.deferredChecks.isEmpty)
        XCTAssertEqual(appState.phaseCompletionStatus[.climb], .doneFromMemory)
    }

    func testGoingBackToItAsksAgain() throws {
        let appState = flight()
        try requireMemoryChecks(appState)
        appState.currentPhase = .climb
        appState.nextPhase()
        appState.previousPhase()
        XCTAssertEqual(appState.currentPhase, .climb)
        XCTAssertTrue(appState.deferredChecks.isEmpty)
        XCTAssertTrue(appState.currentCheckAwaitsConfirmation)
    }

    func testAGoAroundOpensAConfirmedClimbAgain() throws {
        let appState = flight()
        try requireMemoryChecks(appState)
        appState.currentPhase = .climb
        appState.confirmMemoryCheck()
        appState.nextPhase()
        appState.recordGoAround(at: Date())
        XCTAssertEqual(appState.currentPhase, .climb)
        XCTAssertTrue(appState.currentCheckAwaitsConfirmation, "a new circuit, a new climb check")
    }

    // MARK: Jumps on the phase bar

    func testAJumpCountsTheMemoryChecksItPasses() throws {
        let appState = flight()
        try requireMemoryChecks(appState)
        appState.currentPhase = .beforeDeparture
        appState.markLastItemComplete(learningMode: true)
        XCTAssertEqual(appState.checksPassed(jumpingTo: .cruise), [.lineUp, .climb])
        XCTAssertTrue(appState.jumpNeedsQuestion(to: .cruise))
    }

    func testDeferringTheJumpDefersThemWhole() throws {
        let appState = flight()
        try requireMemoryChecks(appState)
        appState.currentPhase = .lineUp
        appState.goToPhase(.cruise, skipped: .deferred)
        XCTAssertEqual(appState.deferredChecks, [.lineUp, .climb], "the line-up left untouched, the climb passed")
        XCTAssertEqual(appState.phaseCompletionStatus[.lineUp], .skipped)
        XCTAssertEqual(appState.phaseCompletionStatus[.climb], .skipped)
    }

    func testAlreadyDoneRecordsThemDoneFromMemory() throws {
        let appState = flight()
        try requireMemoryChecks(appState)
        appState.currentPhase = .lineUp
        appState.goToPhase(.cruise, skipped: .alreadyDone)
        XCTAssertTrue(appState.deferredChecks.isEmpty)
        XCTAssertEqual(appState.phaseCompletionStatus[.lineUp], .doneFromMemory)
        XCTAssertEqual(appState.phaseCompletionStatus[.climb], .doneFromMemory)
    }

    func testAConfirmedCheckIsNotPassedAgain() throws {
        let appState = flight()
        try requireMemoryChecks(appState)
        appState.currentPhase = .climb
        appState.confirmMemoryCheck()
        appState.currentPhase = .lineUp
        XCTAssertEqual(appState.checksPassed(jumpingTo: .cruise), [])
    }

    // MARK: Where it travels

    func testDoneFromMemorySurvivesACrash() throws {
        let source = flight()
        try requireMemoryChecks(source)
        source.currentPhase = .climb
        source.confirmMemoryCheck()
        source.nextPhase()

        let snapshot = ActiveFlightState(flight: try XCTUnwrap(source.currentFlight), from: source)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let restored = makeTestAppState()
        try decoder.decode(ActiveFlightState.self, from: data).restore(to: restored)
        XCTAssertEqual(restored.phaseCompletionStatus[.climb], .doneFromMemory)
        restored.isFlightActive = false
    }

    /// An older build reads the checkpoint's statuses strictly: it finds `.completed` (green, as the
    /// check is), never a value it would drop the whole checkpoint over.
    func testTheCheckpointStaysReadableByAnOlderBuild() throws {
        let source = flight()
        try requireMemoryChecks(source)
        source.currentPhase = .climb
        source.confirmMemoryCheck()
        source.nextPhase()

        let snapshot = ActiveFlightState(flight: try XCTUnwrap(source.currentFlight), from: source)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let text = try XCTUnwrap(String(data: encoder.encode(snapshot), encoding: .utf8))
        XCTAssertFalse(text.contains("doneFromMemory"))
        XCTAssertEqual(snapshot.phaseCompletionStatus[.climb], .completed)
        XCTAssertEqual(snapshot.memoryConfirmedPhases, [.climb])
    }

    func testACheckpointFromBefore61Restores() throws {
        let source = flight()
        source.phaseCompletionStatus[.preflight] = .completed
        let snapshot = ActiveFlightState(flight: try XCTUnwrap(source.currentFlight), from: source)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? [String: Any])
        json.removeValue(forKey: "memoryConfirmedPhases")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(ActiveFlightState.self, from: JSONSerialization.data(withJSONObject: json))
        let restored = makeTestAppState()
        old.restore(to: restored)
        XCTAssertEqual(restored.phaseCompletionStatus[.preflight], .completed)
        restored.isFlightActive = false
    }

    func testTheStatusDecodes() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode([PhaseCompletionStatus].self, from: Data(#"["doneFromMemory"]"#.utf8)),
                       [.doneFromMemory])
        XCTAssertEqual(try decoder.decode([PhaseCompletionStatus].self, from: Data(#"["completed","empty"]"#.utf8)),
                       [.completed, .empty])
        // A value from a newer build: owed, orange, rather than a checkpoint lost.
        XCTAssertEqual(try decoder.decode([PhaseCompletionStatus].self, from: Data(#"["confirmedAfterLanding"]"#.utf8)),
                       [.skipped])
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode([PhaseCompletionStatus.doneFromMemory]), encoding: .utf8))
        XCTAssertEqual(encoded, #"["doneFromMemory"]"#)
    }

    // MARK: The pane (Q7)

    func testMemoryChecksShowTheMapFromClimbToAfterLanding() {
        for phase in [ChecklistPhase.climb, .cruise, .descent, .approach, .landing, .afterLanding] {
            XCTAssertEqual(CockpitPaneRule.defaultPane(phase: phase, checklistDone: false, memoryCheck: true), .map, "\(phase)")
            XCTAssertEqual(CockpitPaneRule.defaultPane(phase: phase, checklistDone: true, memoryCheck: true), .map, "\(phase)")
        }
    }

    func testReadDoChecksKeepTodaysRule() {
        for phase in [ChecklistPhase.approach, .landing, .afterLanding] {
            XCTAssertEqual(CockpitPaneRule.defaultPane(phase: phase, checklistDone: true), .checklist, "\(phase)")
            XCTAssertEqual(CockpitPaneRule.defaultPane(phase: phase, checklistDone: false), .checklist, "\(phase)")
        }
        XCTAssertEqual(CockpitPaneRule.defaultPane(phase: .cruise, checklistDone: false), .checklist)
        XCTAssertEqual(CockpitPaneRule.defaultPane(phase: .cruise, checklistDone: true), .map)
    }

    func testOnTheGroundAMemoryCheckStaysOnTheChecklist() {
        for phase in [ChecklistPhase.afterEngineStart, .taxi, .lineUp] {
            XCTAssertEqual(CockpitPaneRule.defaultPane(phase: phase, checklistDone: false, memoryCheck: true), .checklist,
                           "\(phase)")
        }
    }

    // MARK: Companion

    func testTheCompanionIsToldAndConfirms() throws {
        let appState = flight()
        try requireMemoryChecks(appState)
        appState.currentPhase = .climb
        var snapshot = CompanionConnectivityManager.checklistSnapshot(of: appState, mayStreamItemText: true)
        XCTAssertTrue(snapshot.memoryCheck)
        XCTAssertFalse(snapshot.memoryCheckDone)
        XCTAssertTrue(snapshot.supportsMemoryConfirm)

        let plans = makeTestPlanManager()
        CompanionConnectivityManager.apply(.confirmMemoryCheck(phaseRawValue: ChecklistPhase.cruise.rawValue),
                                           appState: appState, flightPlanManager: plans)
        XCTAssertTrue(appState.currentCheckAwaitsConfirmation, "not the phase flown: nothing")

        CompanionConnectivityManager.apply(.confirmMemoryCheck(phaseRawValue: ChecklistPhase.climb.rawValue),
                                           appState: appState, flightPlanManager: plans)
        XCTAssertTrue(appState.currentCheckIsDone)
        snapshot = CompanionConnectivityManager.checklistSnapshot(of: appState, mayStreamItemText: true)
        XCTAssertTrue(snapshot.memoryCheckDone)

        CompanionConnectivityManager.apply(.undoMemoryCheck(phaseRawValue: ChecklistPhase.climb.rawValue),
                                           appState: appState, flightPlanManager: plans)
        XCTAssertTrue(appState.currentCheckAwaitsConfirmation, "taken back from the phone")
    }

    func testTheCompanionConfirmsADeferredMemoryCheck() throws {
        let appState = flight()
        try requireMemoryChecks(appState)
        appState.currentPhase = .climb
        appState.nextPhase()
        let snapshot = CompanionConnectivityManager.checklistSnapshot(of: appState, mayStreamItemText: false)
        XCTAssertEqual(snapshot.deferredChecks.map(\.fromMemory), [true])

        CompanionConnectivityManager.apply(.confirmMemoryCheck(phaseRawValue: ChecklistPhase.climb.rawValue),
                                           appState: appState, flightPlanManager: makeTestPlanManager())
        XCTAssertEqual(appState.phaseCompletionStatus[.climb], .doneFromMemory)
    }

    func testAnOlderIPadsSnapshotHasNothingToConfirm() throws {
        let appState = flight()
        let current = CompanionConnectivityManager.checklistSnapshot(of: appState, mayStreamItemText: true)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        for key in ["memoryCheck", "memoryCheckDone", "supportsMemoryConfirm"] { json.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(CompanionChecklistSnapshot.self,
                                           from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(old.memoryCheck)
        XCTAssertFalse(old.supportsMemoryConfirm)
    }

    func testTheNewCommandsRoundTrip() throws {
        for command in [CompanionCommand.confirmMemoryCheck(phaseRawValue: 8), .undoMemoryCheck(phaseRawValue: 8)] {
            let data = try JSONEncoder().encode(command)
            let decoded = try JSONDecoder().decode(CompanionCommand.self, from: data)
            XCTAssertEqual(String(describing: decoded), String(describing: command))
        }
    }
}
