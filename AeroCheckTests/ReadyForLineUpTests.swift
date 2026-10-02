import XCTest
@testable import AeroCheck

/// READY FOR LINE UP is the check before departure's NEXT (6.2, option A, author's decision of 2 Oct 2026).
///
/// It used to be a button of its own beside DEFER and CHECK, and a check before departure worked through
/// without it was recorded red, as was every NEXT from the Companion iPhone (which has no such button).
/// Now any move on from that check made by the pilot (the thumb bar, the NEXT chip, the check slot, the
/// one-tap memory confirmation, the Companion's NEXT) is the ready moment: the take-off is estimated two
/// minutes from then and the plan's ETOs count from it, the first time only. A jump on the phase bar
/// records nothing. The check's colour depends on its items alone. Flown on the bundled WT9, whose check
/// before departure is a list in either mode.
@MainActor
final class ReadyForLineUpTests: XCTestCase {

    private func flight(circuits: Bool = false) -> AppState {
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

    /// On the check before departure, every item checked: the state the thumb bar says READY FOR LINE UP in.
    private func onTheCheckBeforeDeparture(_ appState: AppState, itemsDone: Bool = true) throws {
        try XCTSkipIf(appState.checkItems(.beforeDeparture).isEmpty, "needs the WT9's check before departure")
        appState.currentPhase = .beforeDeparture
        if itemsDone { appState.markLastItemComplete(learningMode: appState.effectiveLearningMode) }
        XCTAssertEqual(appState.currentCheckIsDone, itemsDone)
    }

    /// Every ETO anchor the plan manager would have been asked for.
    private final class AnchorSpy {
        var anchors: [Date] = []
    }

    private func spy(on appState: AppState) -> AnchorSpy {
        let spy = AnchorSpy()
        appState.anchorETOsOnLineUp = { spy.anchors.append($0) }
        return spy
    }

    // MARK: The ready moment

    func testNextOutOfTheCheckBeforeDepartureIsReadyForLineUp() throws {
        let appState = flight()
        try onTheCheckBeforeDeparture(appState)
        let anchors = spy(on: appState)
        XCTAssertNil(appState.lineUpTime)

        let tapped = Date()
        appState.nextPhase()

        XCTAssertEqual(appState.currentPhase, .lineUp)
        let lineUp = try XCTUnwrap(appState.lineUpTime, "the take-off estimated on the way out")
        XCTAssertEqual(lineUp.timeIntervalSince(tapped), 120, accuracy: 5, "two minutes from the tap, as the button did")
        XCTAssertEqual(appState.currentFlight?.lineUpTime, lineUp, "on the flight, for the logbook")
        XCTAssertEqual(anchors.anchors, [lineUp], "the plan's ETOs count from it, after it is recorded")
        XCTAssertEqual(appState.phaseCompletionStatus[.beforeDeparture], .completed, "green: its items were done")
    }

    func testOnlyTheCheckBeforeDepartureRecordsIt() throws {
        let appState = flight()
        let anchors = spy(on: appState)
        appState.currentPhase = .runup
        appState.markLastItemComplete(learningMode: appState.effectiveLearningMode)
        appState.nextPhase()
        XCTAssertEqual(appState.currentPhase, .beforeDeparture)
        XCTAssertNil(appState.lineUpTime)

        appState.currentPhase = .lineUp
        appState.markLastItemComplete(learningMode: appState.effectiveLearningMode)
        appState.nextPhase()
        XCTAssertEqual(appState.currentPhase, .climb)
        XCTAssertNil(appState.lineUpTime, "the line up check's own NEXT is not the ready moment")
        XCTAssertTrue(anchors.anchors.isEmpty)
    }

    /// Back to the check before departure and on again: the first take-off stays, which the flight time
    /// and Time OFF read. The pilot's own button used to behave the same (a hold to change it).
    func testASecondNextKeepsTheFirstLineUp() throws {
        let appState = flight()
        try onTheCheckBeforeDeparture(appState)
        let anchors = spy(on: appState)
        appState.nextPhase()
        let first = try XCTUnwrap(appState.lineUpTime)

        appState.previousPhase()
        XCTAssertEqual(appState.currentPhase, .beforeDeparture)
        appState.nextPhase()

        XCTAssertEqual(appState.currentPhase, .lineUp)
        XCTAssertEqual(appState.lineUpTime, first)
        XCTAssertEqual(appState.currentFlight?.lineUpTime, first)
        XCTAssertEqual(anchors.anchors, [first], "the ETOs are not moved again")
    }

    /// Circuits: the stop-and-go starts the next lap at TAXI, the check before departure included, and
    /// READY FOR LINE UP is said again on every lap. The first take-off stays the flight's.
    func testEveryCircuitSaysItButTheFirstTakeOffStays() throws {
        let appState = flight(circuits: true)
        try onTheCheckBeforeDeparture(appState)
        appState.nextPhase()
        let first = try XCTUnwrap(appState.lineUpTime)

        appState.recordFullStop()
        XCTAssertEqual(appState.currentPhase, .taxi, "the next circuit starts at TAXI")
        XCTAssertNil(appState.phaseCompletionStatus[.beforeDeparture], "reset for the lap")
        try onTheCheckBeforeDeparture(appState)
        XCTAssertEqual(CockpitNextLabel(leaving: appState.currentPhase, to: .lineUp, deferred: 0).title,
                       L10n.ChecklistAction.readyForLineUp, "the call is made on every lap")
        appState.nextPhase()

        XCTAssertEqual(appState.currentPhase, .lineUp)
        XCTAssertEqual(appState.lineUpTime, first)
        XCTAssertEqual(appState.phaseCompletionStatus[.beforeDeparture], .completed, "green on lap 2 as well")
    }

    func testAJumpOnThePhaseBarRecordsNothing() throws {
        let appState = flight()
        try onTheCheckBeforeDeparture(appState)
        let anchors = spy(on: appState)

        appState.goToPhase(.lineUp)

        XCTAssertEqual(appState.currentPhase, .lineUp)
        XCTAssertNil(appState.lineUpTime, "a deliberate jump; END FLIGHT measures the take-off from the track")
        XCTAssertTrue(anchors.anchors.isEmpty)
        XCTAssertEqual(appState.phaseCompletionStatus[.beforeDeparture], .completed, "and never red")
    }

    func testNothingIsRecordedOutsideAFlight() throws {
        let appState = makeTestAppState()
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.currentPhase = .beforeDeparture
        appState.nextPhase()
        XCTAssertNil(appState.lineUpTime)
    }

    // MARK: Never red for it

    func testTheCheckBeforeDepartureDependsOnItsItemsAlone() throws {
        let worked = flight()
        try onTheCheckBeforeDeparture(worked)
        worked.goToPhase(.climb)
        XCTAssertEqual(worked.phaseCompletionStatus[.beforeDeparture], .completed)
        XCTAssertNil(worked.lineUpTime)

        let open = flight()
        try onTheCheckBeforeDeparture(open, itemsDone: false)
        open.advanceHighlightedItem(learningMode: open.effectiveLearningMode)
        open.nextPhase()
        XCTAssertEqual(open.phaseCompletionStatus[.beforeDeparture], .skipped, "orange with items left, never red")
        XCTAssertNotNil(open.deferredItems[.beforeDeparture])

        let passed = flight()
        passed.currentPhase = .lineUp
        XCTAssertEqual(passed.getPhaseStatus(.beforeDeparture), .skipped, "passed without a status: skipped, not red")
    }

    func testTheCheckRunFromTheDeferredListIsGreen() throws {
        let appState = flight()
        try XCTSkipIf(appState.checkItems(.beforeDeparture).isEmpty)
        appState.currentPhase = .runup
        appState.goToPhase(.lineUp)
        XCTAssertTrue(appState.deferredChecks.contains(.beforeDeparture), "deferred whole by the jump")
        XCTAssertEqual(appState.phaseCompletionStatus[.beforeDeparture], .skipped, "orange, not red")

        for _ in appState.checkItems(.beforeDeparture) where appState.deferredChecks.contains(.beforeDeparture) {
            appState.checkItem(inDeferredCheck: .beforeDeparture)
        }
        XCTAssertFalse(appState.deferredChecks.contains(.beforeDeparture), "run to the end")
        XCTAssertEqual(appState.phaseCompletionStatus[.beforeDeparture], .completed)
    }

    func testTheEngineButtonsStayRequired() throws {
        let appState = flight()
        appState.currentPhase = .engineStart
        appState.markLastItemComplete(learningMode: appState.effectiveLearningMode)
        appState.nextPhase()
        XCTAssertEqual(appState.phaseCompletionStatus[.engineStart], .missingAction, "ENGINE START never pressed")

        appState.currentPhase = .shutdown
        appState.markLastItemComplete(learningMode: appState.effectiveLearningMode)
        appState.nextPhase()
        XCTAssertEqual(appState.phaseCompletionStatus[.shutdown], .missingAction, "ENGINE SHUTDOWN never pressed")

        let pressed = flight()
        pressed.currentPhase = .engineStart
        pressed.recordEngineStart()
        pressed.markLastItemComplete(learningMode: pressed.effectiveLearningMode)
        pressed.nextPhase()
        XCTAssertEqual(pressed.phaseCompletionStatus[.engineStart], .completed)
    }

    func testTheFlightEndingOnTheCheckBeforeDepartureIsNotRed() throws {
        let appState = flight()
        try onTheCheckBeforeDeparture(appState)
        let id = try XCTUnwrap(appState.currentFlight?.id)
        appState.endFlight()
        let saved = try XCTUnwrap(appState.flights.first { $0.id == id })
        XCTAssertEqual(saved.checkOutcomes?.first { $0.phase == .beforeDeparture }?.status, .done)
    }

    // MARK: The Companion iPhone's NEXT

    /// The phone has no line-up button and never had: its NEXT recorded the check red. It is the same
    /// ready moment now, through the command the phone already sends.
    func testTheCompanionsNextIsReadyForLineUp() throws {
        let appState = flight()
        try onTheCheckBeforeDeparture(appState)
        let anchors = spy(on: appState)

        CompanionConnectivityManager.apply(.nextChecklistPhase, appState: appState, flightPlanManager: makeTestPlanManager())

        XCTAssertEqual(appState.currentPhase, .lineUp)
        let lineUp = try XCTUnwrap(appState.lineUpTime)
        XCTAssertEqual(anchors.anchors, [lineUp])
        XCTAssertEqual(appState.phaseCompletionStatus[.beforeDeparture], .completed)
    }

    // MARK: What the primary says

    func testThePrimaryReadsReadyForLineUpOutOfTheCheckBeforeDeparture() {
        let ready = CockpitNextLabel(leaving: .beforeDeparture, to: .lineUp, deferred: 0)
        XCTAssertEqual(ready.title, L10n.ChecklistAction.readyForLineUp)
        XCTAssertEqual(ready.subtitle, L10n.Cockpit.thenCheck(ChecklistPhase.lineUp.shortTitle))
        XCTAssertEqual(ready.icon, "airplane.departure")
        XCTAssertEqual(ready.accessibilityHint, L10n.Cockpit.readyForLineUpHint, "VoiceOver says what the tap records")
        XCTAssertEqual(CockpitNextLabel(leaving: .beforeDeparture, to: .lineUp, deferred: 2), ready,
                       "the same with items deferred: they are listed above the checklist")

        let next = CockpitNextLabel(leaving: .runup, to: .beforeDeparture, deferred: 0)
        XCTAssertEqual(next.title, L10n.Cockpit.next(ChecklistPhase.beforeDeparture.shortTitle))
        XCTAssertEqual(next.subtitle, L10n.Cockpit.allChecked)
        XCTAssertEqual(next.icon, "chevron.right")
        XCTAssertNil(next.accessibilityHint)
        XCTAssertEqual(CockpitNextLabel(leaving: .lineUp, to: .climb, deferred: 2).subtitle, L10n.Deferred.count(2))
        XCTAssertEqual(CockpitNextLabel(leaving: nil, to: nil, deferred: 0).title, L10n.Button.next,
                       "a phone that can't read the phase says NEXT")
    }

    func testTheNewStringsHaveTheirFrench() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "fr", ofType: "lproj"))
        let french = try XCTUnwrap(Bundle(path: path))
        let missing = "\u{1}missing"
        for key in ["cockpit.thenCheck", "cockpit.readyForLineUpHint", "checklist.readyForLineUp"] {
            XCTAssertNotEqual(french.localizedString(forKey: key, value: missing, table: nil), missing, key)
        }
        XCTAssertEqual(String(format: french.localizedString(forKey: "cockpit.thenCheck", value: nil, table: nil),
                              "ALIGNEMENT"), "puis ALIGNEMENT")
    }

    // MARK: The one-tap memory confirmation

    /// A check before departure flown from memory, on a checklist of our own (the WT9 reads it as a
    /// list): ✓ DONE · NEXT goes on, where it used to wait for the line-up button.
    private static let memoryChecklist = #"""
        {"success":true,"data":{"id":"lineup-memory-test","aircraftType":"TEST","registration":"HB-TST",
         "modelName":"Test aircraft","shortModelName":"TEST","aeroclub":null,"version":"1",
         "lastUpdated":"2026","isFree":false,"stallSpeed":45,"pageCount":1,"hasParachute":false,
         "crosswindLimits":{"takeoff":"15 kt","landing":"15 kt"},"speeds":[],"targetSpeeds":{},
         "learningModeVisibleCount":{"beforeDeparture":0,"lineUp":0},
         "phases":{
          "beforeDeparture":{"title":"BD","pageNumber":1,"items":[
            {"number":1,"challenge":"BD ONE","response":"SET","isHeader":false},
            {"number":2,"challenge":"BD TWO","response":"SET","isHeader":false}]},
          "lineUp":{"title":"LU","pageNumber":1,"items":[
            {"number":1,"challenge":"LU ONE","response":"SET","isHeader":false}]},
          "climb":{"title":"CL","pageNumber":1,"items":[
            {"number":1,"challenge":"CL ONE","response":"SET","isHeader":false}]}}}}
        """#

    private func memoryFlight() async throws -> AppState {
        let appState = makeTestAppState()
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.settings.selectedRemoteAircraftId = "lineup-memory-test"
        appState.settings.learningMode = false
        appState.settings.stepByStepHighlighting = true
        let http = AircraftDataServiceSeamTests.FakeHTTPClient(responseData: Data(Self.memoryChecklist.utf8))
        let service = makeTestAircraftDataService(subscriptionManager: AircraftDataServiceSeamTests.FakeGating(),
                                                  httpClient: http)
        await appState.loadRemoteChecklistIfNeeded(aircraftDataService: service)
        appState.startFlight(withAircraft: "HB-TST", aircraftRegistration: "HB-TST", aircraftType: "TEST")
        addTeardownBlock { @MainActor in if appState.isFlightActive { appState.cancelFlight() } }
        try XCTSkipUnless(appState.isFlightActive && appState.isMemoryCheck(.beforeDeparture, learningMode: false),
                          "needs the test checklist loaded")
        appState.currentPhase = .beforeDeparture
        return appState
    }

    func testTheOneTapMemoryConfirmationIsReadyForLineUp() async throws {
        let appState = try await memoryFlight()
        let anchors = spy(on: appState)
        XCTAssertTrue(appState.currentCheckAwaitsConfirmation)
        XCTAssertEqual(appState.memoryConfirmationMovesTo, .lineUp, "no longer held back for the line-up button")

        appState.confirmMemoryCheckAndAdvance()

        XCTAssertEqual(appState.currentPhase, .lineUp)
        let lineUp = try XCTUnwrap(appState.lineUpTime)
        XCTAssertEqual(anchors.anchors, [lineUp])
        XCTAssertEqual(appState.phaseCompletionStatus[.beforeDeparture], .doneFromMemory, "green, done from memory")
    }

    /// UNDO takes the move back, and the estimate with it: the phone would otherwise switch to NAV, and
    /// the next NEXT would keep a time the pilot took back.
    func testUndoingTheOneTapForgetsTheLineUpItRecorded() async throws {
        let appState = try await memoryFlight()
        let anchors = spy(on: appState)
        appState.confirmMemoryCheckAndAdvance()
        let id = try XCTUnwrap(appState.memoryConfirmation?.id)

        appState.undoMemoryConfirmation(id)

        XCTAssertEqual(appState.currentPhase, .beforeDeparture)
        XCTAssertNil(appState.lineUpTime)
        XCTAssertNil(appState.currentFlight?.lineUpTime)

        appState.confirmMemoryCheckAndAdvance()
        XCTAssertEqual(appState.currentPhase, .lineUp)
        XCTAssertNotNil(appState.lineUpTime, "made again, ETOs included")
        XCTAssertEqual(anchors.anchors.count, 2)
    }

    /// An estimate made before (the first circuit) is not the tap's to forget.
    func testUndoKeepsALineUpMadeBefore() async throws {
        let appState = try await memoryFlight()
        let earlier = Date().addingTimeInterval(-600)
        appState.lineUpTime = earlier
        appState.confirmMemoryCheckAndAdvance()
        XCTAssertEqual(appState.lineUpTime, earlier)
        let id = try XCTUnwrap(appState.memoryConfirmation?.id)

        appState.undoMemoryConfirmation(id)

        XCTAssertEqual(appState.currentPhase, .beforeDeparture)
        XCTAssertEqual(appState.lineUpTime, earlier)
    }
}
