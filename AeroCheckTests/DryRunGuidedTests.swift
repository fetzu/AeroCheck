import XCTest
import CoreLocation
@testable import AeroCheck

/// The guided flight (6.4.0): its route, its steps, the whole flight flown headless by a pilot who does what each
/// step asks, its pace (no stretch longer than 13 s without a card or a tap), a chapter flown on its own, and where
/// it is offered.
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
        XCTAssertEqual(Set(steps.map(\.id)).count, steps.count, "an id each")
        for step in steps {
            XCTAssertFalse(step.title.isEmpty, step.id)
            XCTAssertFalse(step.body.isEmpty, step.id)
            // A veil only where the step is one tap on its control.
            if step.veils {
                XCTAssertEqual(step.kind, .act, step.id)
                XCTAssertNotNil(step.target, step.id)
            }
            // The flight runs on only where the pilot works through the checks, the aircraft waiting by itself
            // or taxiing on.
            if !step.holds {
                guard case .shows = step.done else { return XCTFail("\(step.id) lets the flight run on") }
            }
            if step.kind == .look { XCTAssertEqual(step.done, .next, step.id) }
        }
        for chapter in 1...7 {
            XCTAssertFalse(DryRunChapters.title(chapter).isEmpty)
            XCTAssertFalse(DryRunChapters.habit(chapter).isEmpty)
        }
    }

    /// A ring is only ever on a control that shows what the card names: a step that sends the pilot through the
    /// checks to a control rings CHECK, and the control's own step comes when the band shows it.
    func testAControlIsRungOnlyOnceTheBandShowsIt() {
        let steps = DryRunChapters.steps
        for (index, step) in steps.enumerated() {
            guard case .shows(let slot) = step.done else { continue }
            XCTAssertEqual(step.target, .primary, "\(step.id) rings CHECK on the way")
            let following = steps[(index + 1)...].first { $0.requires == .always }
            XCTAssertEqual(following?.moment == .shows(slot) || following?.moment == .parkedAndShows(slot), true,
                           "after \(step.id), the next step waits for the band to show it")
        }
        XCTAssertEqual(steps.first { $0.id == "approachCheck" }?.moment, .shows(.check(.approach)),
                       "the approach check's card waits for the slot to name it (g-7)")
    }

    func testALookStepGoesOnWithNextADoStepOnlyOnceDone() {
        let look = DryRunCoachStep(id: "look", chapter: 1, kind: .look, target: nil, veils: false, holds: true,
                                   moment: .now, done: .next, title: "", body: "")
        let act = DryRunCoachStep(id: "act", chapter: 1, kind: .act, target: .primary, veils: true, holds: true,
                                  moment: .now, done: .engineStarted, title: "", body: "")
        let coach = DryRunCoach(steps: [act, look])
        coach.next()
        XCTAssertEqual(coach.index, 0, "Next does nothing on a do step")
        let other = DryRunCoach(steps: [look])
        XCTAssertFalse(other.isFinished)
    }

    // MARK: - The whole flight

    /// A pilot who does what each step asks, as the Cockpit's buttons would: every step shown in turn, the flight
    /// held at each that holds, a go-around and a full stop, END FLIGHT, and the seven habits on the page.
    func testTheWholeGuidedFlightAsAPilotWouldFlyIt() throws {
        let record = try flyTheGuidedFlight(chapter: 1)
        let expected = DryRunChapters.steps.map(\.id)
        XCTAssertEqual(record.shown, expected, "every step, in order")
        XCTAssertTrue(record.coach.isFinished)
        XCTAssertTrue(record.finished, "the Today card is told")
        XCTAssertNotNil(record.session.generator.mark("goAround"))
        XCTAssertNotNil(record.session.generator.mark("stopped"))
        guard case .over(let summary) = record.session.state else { return XCTFail("no page") }
        XCTAssertEqual(summary.habits, (1...7).map(DryRunChapters.habit))
        XCTAssertEqual(summary.title, L10n.DryRunCoach.flightName)
        XCTAssertEqual(summary.nextTime, L10n.DryRunCoach.nextFree)
        XCTAssertEqual(summary.goArounds, 1)
        XCTAssertEqual(summary.landings, 1)
    }

    /// The author's limit (16 Oct): never more than 10 to 15 seconds without something for the pilot. Each
    /// stretch between two steps, in the pilot's seconds at the pace the flight ran at, is 13 at the most.
    func testNoStretchRunsLongerThan13SecondsWithoutACardOrATap() throws {
        let record = try flyTheGuidedFlight(chapter: 1)
        let longest = record.gaps.max { $0.seconds < $1.seconds }
        XCTAssertLessThanOrEqual(longest?.seconds ?? 0, 13,
                                 "\(record.gaps.map { "\($0.after) → \($0.before): \(String(format: "%.1f", $0.seconds)) s" })")
        // The folded card says something all along a stretch.
        XCTAssertTrue(record.linesMissing.isEmpty, "\(record.linesMissing)")
    }

    // MARK: - A chapter on its own

    /// Each chapter on its own: the flight taken there behind the cover (nothing shown, nothing asked), then the
    /// chapter's first step over the Cockpit, the flight held, the checks before it worked through.
    func testAChapterOnItsOwnOpensOnItsFirstStep() throws {
        let plan = DryRunChapters.route(from: .lszq)
        for chapter in 2...7 {
            let setup = DryRunSetup(mission: .route(plan, departure: .lszq, destination: .lszq), rate: 0,
                                    guidedChapter: chapter)
            let flight = try DryRunHeadless(self, setup: setup, plan: plan)
            let coach = try XCTUnwrap(flight.session.coach)
            XCTAssertTrue(coach.isFastForwarding)
            flight.fastForward()
            XCTAssertFalse(coach.isFastForwarding, "chapter \(chapter) reached")
            let first = DryRunChapters.steps.first { $0.chapter == chapter && $0.requires == .always }
            XCTAssertEqual(coach.step?.id, first?.id, "chapter \(chapter) opens on its first step")
            XCTAssertEqual(coach.chaptersDone, Array(1..<chapter))
            // After the go-around the app starts the checks again at the climb check, and the landing passes
            // over the cruise, descent and approach checks of that lap: the app's rule for any landing, which
            // keeps them, deferred (a question for the author, device checks r641).
            let lap: Set<ChecklistPhase> = chapter == 7 ? [.cruise, .descent, .approach] : []
            XCTAssertEqual(flight.appState.deferredItemCount, 0, "chapter \(chapter): nothing deferred on the way")
            XCTAssertTrue(Set(flight.appState.deferredChecks).isSubset(of: lap),
                          "chapter \(chapter): \(flight.appState.deferredChecks)")
            XCTAssertNil(flight.world.detector.pendingGoAround, "nothing asked on the way")
            XCTAssertNil(flight.appState.landedCard)
            if coach.step?.holds == true {
                XCTAssertTrue(flight.session.isCoachHolding, "chapter \(chapter): the flight waits at its first step")
                XCTAssertEqual(flight.session.pace, 0)
            }
            flight.session.end()
        }
    }

    /// Chapter 6 on its own showed no card at all on the iPad (c-1, 16 Oct): the app wrote the turning point's
    /// time over a second before the generator reached it, which took it for a Direct To and lost its own
    /// passage. A natural passage is the generator's.
    func testTheAppsOwnTimeOverIsNotTakenForADirectTo() throws {
        let plan = DryRunChapters.route(from: .lszq)
        let setup = DryRunSetup(mission: .route(plan, departure: .lszq, destination: .lszq), rate: 0, guidedChapter: 6)
        let flight = try DryRunHeadless(self, setup: setup, plan: plan)
        flight.fastForward()
        XCTAssertNotNil(flight.session.generator.mark("wp1"), "the generator passed the turning point itself")
        XCTAssertEqual(flight.session.coach?.step?.id, "approachCheck")
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

    // MARK: - Flying it

    private struct Gap {
        let after: String
        let before: String
        let seconds: Double
    }

    private struct Record {
        let session: DryRunSession
        let coach: DryRunCoach
        let shown: [String]
        let gaps: [Gap]
        let finished: Bool
        /// Seconds of a stretch where the folded card had nothing to say.
        let linesMissing: [String]
    }

    /// The guided flight from `chapter`, a pilot doing at once what each step asks, the Cockpit's engine hours'
    /// prompt played as `FlightView` shows it. Each stretch between two steps is timed in the pilot's seconds:
    /// a second of the flight at pace p is 1/p of the pilot's.
    private func flyTheGuidedFlight(chapter: Int) throws -> Record {
        let plan = DryRunChapters.route(from: .lszq)
        let setup = DryRunSetup(mission: .route(plan, departure: .lszq, destination: .lszq), rate: 0, guidedChapter: chapter)
        let flight = try DryRunHeadless(self, setup: setup, plan: plan)
        let session = flight.session
        let coach = try XCTUnwrap(session.coach)
        let appState = flight.appState
        appState.settings.logEngineHours = true
        var finished = false
        session.onGuidedFinished = { finished = true }
        var shown: [String] = []
        var gaps: [Gap] = []
        var stretch = 0.0
        var linesMissing: [String] = []
        var prompted: Set<String> = []

        for _ in 0..<(4 * 3600) {
            if case .over = session.state { break }
            // The engine hours' prompt, as the Cockpit raises it: entering the engine start, at ENGINE SHUTDOWN.
            if appState.currentPhase == .engineStart, appState.currentFlight?.engineHourStart == nil,
               !prompted.contains("start") {
                prompted.insert("start")
                coach.hourMeter = .beforeStart
            }
            if appState.engineShutdownTime != nil, appState.currentFlight?.engineHourEnd == nil, !prompted.contains("stop") {
                prompted.insert("stop")
                coach.hourMeter = .afterStop
            }
            if let step = coach.step {
                if step.holds { XCTAssertTrue(session.isCoachHolding, "the flight waits at \(step.id)") }
                if shown.last != step.id {
                    if stretch > 0 { gaps.append(Gap(after: shown.last ?? "start", before: step.id, seconds: stretch)) }
                    stretch = 0
                    shown.append(step.id)
                }
                switch step.done {
                case .next: coach.next()
                case .hourMeterClosed:
                    if coach.hourMeter == .beforeStart { appState.currentFlight?.engineHourStart = 1234.5 }
                    if coach.hourMeter == .afterStop { appState.currentFlight?.engineHourEnd = 1235.0 }
                    coach.hourMeter = nil
                default: coach.actAsPilot(step, session)
                }
                // The step's answer reaches the coach with the next fix, as in the Cockpit.
                flight.wait(1)
                continue
            }
            flight.wait(1)
            if session.pace > 0 { stretch += 1 / session.pace }
            if coach.step == nil, session.foldedLine == nil, case .flying = session.state {
                linesMissing.append("\(session.generator.t)")
            }
        }
        return Record(session: session, coach: coach, shown: shown, gaps: gaps, finished: finished,
                      linesMissing: linesMissing)
    }
}
