import XCTest
import CoreLocation
@testable import AeroCheck

/// The guided flight (6.4.0): its route, its steps in order, the whole flight flown headless by a pilot who
/// does what each step asks, a chapter flown on its own, and where it is offered.
@MainActor
final class DryRunGuidedTests: XCTestCase {

    override func tearDown() {
        FlightClock.endVirtual()
        super.tearDown()
    }

    // MARK: - The route and the steps

    func testTheGuidedRouteGoesOutToATurningPointAndBack() {
        let plan = DryRunChapters.route(from: .lszq)
        XCTAssertEqual(plan.waypoints.count, 3)
        XCTAssertEqual(plan.waypoints.map { DryRunSetup.aerodromeIdent(of: $0) }.first, "LSZQ")
        XCTAssertEqual(plan.waypoints.map { DryRunSetup.aerodromeIdent(of: $0) }.last, "LSZQ")
        XCTAssertEqual(Set(plan.waypoints.map(\.id)).count, 3, "three waypoints of their own")
        let turn = CLLocationCoordinate2D(latitude: plan.waypoints[1].latitude, longitude: plan.waypoints[1].longitude)
        XCTAssertEqual(DryRunGeo.distance(DryRunAerodrome.lszq.reference, turn) / DryRunGeo.metresPerNM, 8, accuracy: 0.1)
        XCTAssertEqual(plan.waypoints[1].altitude, DryRunAerodrome.lszq.patternAltitudeFt + 1500)
        // Away from the circuit's side (LSZQ's is to the north, on the left of 07).
        XCTAssertLessThan(turn.latitude, DryRunAerodrome.lszq.reference.latitude)
    }

    func testTheStepsGoThroughTheSevenChaptersInOrder() {
        let steps = DryRunChapters.steps
        XCTAssertEqual(Set(steps.map(\.chapter)), Set(1...7))
        XCTAssertEqual(steps.map(\.chapter), steps.map(\.chapter).sorted())
        // A veil only where the step is one tap on its control.
        for step in steps where step.veils {
            XCTAssertEqual(step.kind, .act)
            XCTAssertNotNil(step.target)
        }
        for chapter in 1...7 {
            XCTAssertFalse(DryRunChapters.title(chapter).isEmpty)
            XCTAssertFalse(DryRunChapters.habit(chapter).isEmpty)
        }
    }

    func testALookStepGoesOnWithNextADoStepOnlyOnceDone() {
        let look = DryRunCoachStep(chapter: 1, kind: .look, target: nil, veils: false, moment: .now, done: .next,
                                   title: "", body: "")
        let act = DryRunCoachStep(chapter: 1, kind: .act, target: .primary, veils: true, moment: .now,
                                  done: .engineStarted, title: "", body: "")
        let coach = DryRunCoach(steps: [act, look])
        coach.next()
        XCTAssertEqual(coach.index, 0, "Next does nothing on a do step")
        let other = DryRunCoach(steps: [look])
        XCTAssertFalse(other.isFinished)
    }

    // MARK: - The whole flight

    /// A pilot who does what each step asks, as the Cockpit's buttons would: every step shown in turn, the
    /// flight held at each, a go-around and a full stop, END FLIGHT, and the seven habits on the page.
    func testTheWholeGuidedFlightAsAPilotWouldFlyIt() throws {
        let plan = DryRunChapters.route(from: .lszq)
        let setup = DryRunSetup(mission: .route(plan, departure: .lszq, destination: .lszq), rate: 0, guidedChapter: 1)
        let flight = try DryRunHeadless(self, setup: setup, plan: plan)
        let coach = try XCTUnwrap(flight.session.coach)
        var finished = false
        flight.session.onGuidedFinished = { finished = true }
        let appState = flight.appState
        var shown: [String] = []

        for _ in 0..<(4 * 3600) {
            if case .over = flight.session.state { break }
            if let step = coach.step {
                XCTAssertTrue(flight.session.isCoachHolding, "the flight waits at \(step.title)")
                if shown.last != step.title { shown.append(step.title) }
                switch step.done {
                case .next: coach.next()
                case .itemChecked: appState.advanceHighlightedItem(learningMode: true)
                case .engineStarted:
                    appState.goToPhase(.engineStart)
                    appState.recordEngineStart()
                case .deferred:
                    appState.goToPhase(.taxi)
                    appState.deferHighlightedItem()
                case .phaseAtLeast(let phase): appState.goToPhase(phase)
                case .linedUp:
                    appState.goToPhase(.beforeDeparture)
                    appState.nextPhase()
                case .page(let page): coach.page = page
                case .finalChoice(let landing): flight.session.finalChoice = landing
                case .engineShutdown:
                    appState.goToPhase(.shutdown)
                    appState.recordEngineShutdown()
                case .flightEnded:
                    flight.world.location.stopTracking()
                    appState.endFlight()
                }
            }
            flight.wait(1)
        }

        XCTAssertEqual(shown.count, DryRunChapters.steps.count, "\(shown)")
        XCTAssertTrue(coach.isFinished)
        XCTAssertTrue(finished, "the Today card is told")
        XCTAssertNotNil(flight.session.generator.mark("goAround"))
        XCTAssertNotNil(flight.session.generator.mark("stopped"))
        guard case .over(let summary) = flight.session.state else { return XCTFail("no page") }
        XCTAssertEqual(summary.habits, (1...7).map(DryRunChapters.habit))
        XCTAssertEqual(summary.title, L10n.DryRunCoach.flightName)
        XCTAssertEqual(summary.nextTime, L10n.DryRunCoach.nextFree)
        XCTAssertEqual(summary.goArounds, 1)
        XCTAssertEqual(summary.landings, 1)
    }

    /// Chapter 6 on its own: the flight there at 30×, the earlier steps done for the pilot, the chapter's
    /// first step shown with the aircraft on its way back, the checks before it taken as done.
    func testAChapterOnItsOwnStartsWhereItBegins() throws {
        let plan = DryRunChapters.route(from: .lszq)
        let setup = DryRunSetup(mission: .route(plan, departure: .lszq, destination: .lszq), rate: 0, guidedChapter: 6)
        let flight = try DryRunHeadless(self, setup: setup, plan: plan)
        let coach = try XCTUnwrap(flight.session.coach)
        XCTAssertTrue(coach.isPreluding)
        XCTAssertEqual(FlightClock.virtual?.rate, DryRunSession.skipRate, "on its way at Next check's pace")
        XCTAssertTrue(flight.fly(until: { coach.step != nil }, within: 3600), "the chapter's first step")
        XCTAssertFalse(coach.isPreluding)
        XCTAssertEqual(coach.step?.chapter, 6)
        XCTAssertEqual(coach.step?.title, L10n.DryRunCoach.c6s1Title)
        XCTAssertEqual(coach.chaptersDone, [1, 2, 3, 4, 5])
        XCTAssertTrue(flight.session.generator.isAirborne)
        XCTAssertEqual(flight.appState.currentPhase, .approach)
        XCTAssertNotNil(flight.appState.engineStartTime)
        XCTAssertNotNil(flight.appState.lineUpTime)
        XCTAssertEqual(flight.appState.deferredChecks.count + flight.appState.deferredItemCount, 0,
                       "the checks before the chapter taken as done, nothing deferred")
    }

    // MARK: - Where it is offered

    func testTodaysCardWhileTheLogbookIsEmptyUntilFlownOrPutAway() {
        XCTAssertTrue(DryRunTodayCard.isOffered(logbookEmpty: true, dismissed: false, guidedFlown: false))
        XCTAssertFalse(DryRunTodayCard.isOffered(logbookEmpty: false, dismissed: false, guidedFlown: false))
        XCTAssertFalse(DryRunTodayCard.isOffered(logbookEmpty: true, dismissed: true, guidedFlown: false), "Not now, for good (D7)")
        XCTAssertFalse(DryRunTodayCard.isOffered(logbookEmpty: true, dismissed: false, guidedFlown: true))
    }

    func testAGuidedRequestIsShownWhereItWasAsked() {
        let center = DryRunCenter.shared
        center.requestGuided(chapter: 3, presenter: "settings")
        XCTAssertEqual(center.presenter, "settings")
        XCTAssertEqual(center.guidedRequest?.chapter, 3)
        center.guidedRequest = nil
    }
}
