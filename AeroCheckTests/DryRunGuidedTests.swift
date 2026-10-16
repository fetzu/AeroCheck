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

    /// The guided route from LSZQ (the proposal's Q8): a triangle, straight out to the first turning point 6 NM
    /// ahead of runway 07, the second 2.5 NM outside where ARR SECTOR EAST begins, home by that arrival, which
    /// joins the circuit before its downwind; both points at 1,500 ft over the circuit.
    func testTheGuidedRouteIsATriangleHomeByThePublishedArrival() {
        let lszq = DryRunAerodrome.lszq
        let plan = DryRunChapters.route(from: lszq)
        XCTAssertEqual(plan.waypoints.count, 4)
        XCTAssertEqual(plan.waypoints.map { DryRunSetup.aerodromeIdent(of: $0) }.first, "LSZQ")
        XCTAssertEqual(plan.waypoints.map { DryRunSetup.aerodromeIdent(of: $0) }.last, "LSZQ")
        XCTAssertEqual(Set(plan.waypoints.map(\.id)).count, 4, "four waypoints of their own")
        func point(_ i: Int) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: plan.waypoints[i].latitude, longitude: plan.waypoints[i].longitude)
        }
        XCTAssertEqual(DryRunGeo.distance(lszq.reference, point(1)) / DryRunGeo.metresPerNM, 6, accuracy: 0.1)
        XCTAssertEqual(DryRunGeo.bearing(from: lszq.reference, to: point(1)), lszq.runwayHeading, accuracy: 1, "straight out")
        let east = lszq.arrivals[0].line[0]
        XCTAssertEqual(DryRunGeo.distance(east, point(2)) / DryRunGeo.metresPerNM, 2.5, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(DryRunGeo.distance(point(1), point(2)) / DryRunGeo.metresPerNM, 2.5)
        XCTAssertEqual(plan.waypoints[1].altitude, lszq.patternAltitudeFt + 1500)
        XCTAssertEqual(plan.waypoints[2].altitude, lszq.patternAltitudeFt + 1500)
        XCTAssertEqual(lszq.guidedEntry.point.latitude, east.latitude, accuracy: 1e-9, "ARR SECTOR EAST, before the downwind")
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

    // MARK: - The whole story

    /// The whole story, as a pilot goes through it ("Plan to Logbook"): the flight planned on Today, a task
    /// ticked and one set aside, START FLIGHT, the flight with its checks, a go-around and a full stop, END
    /// FLIGHT, the close-out (the logbook line, the debrief, Finish), then the Logbook. Every step in order,
    /// the pages between the parts, the habits of the parts and the chapters on the page at the end.
    func testTheWholeStoryFromThePlanToTheLogbook() throws {
        let record = try flyTheStory(.story)
        let expected = DryRunStory.steps.filter { $0.requires != .notFromPlan }.map(\.id)
        XCTAssertEqual(record.shown, expected, "every step, in order")
        XCTAssertTrue(record.coach.isFinished)
        XCTAssertTrue(record.finished, "the Today card is told")
        let world = record.session.world
        XCTAssertEqual(world.appState.flights.count, DryRunLogbook.flown.count + 1, "the flight beside the made-up ones")
        XCTAssertEqual(record.session.storyThread?.state, .done)
        XCTAssertFalse(world.threads.notificationService === NotificationService.shared, "no reminder can be scheduled")
        XCTAssertNotNil(record.session.generator.mark("goAround"))
        XCTAssertNotNil(record.session.generator.mark("stopped"))
        guard case .over(let summary) = record.session.state else { return XCTFail("no page") }
        XCTAssertTrue(summary.isStory)
        XCTAssertEqual(summary.habits, [L10n.DryRunCoach.habitPlan] + (1...7).map(DryRunChapters.habit)
                       + [L10n.DryRunCoach.habitClose, L10n.DryRunCoach.habitLogbook])
        XCTAssertEqual(summary.goArounds, 1)
        XCTAssertEqual(summary.landings, 1)
    }

    /// Stop here, on the page after a part: the dry run's page at once, the habits of what was done.
    func testStopHereEndsTheStory() throws {
        let record = try flyTheStory(.story, stopAt: "end.plan")
        guard case .over(let summary) = record.session.state else { return XCTFail("no page") }
        XCTAssertEqual(summary.habits, [L10n.DryRunCoach.habitPlan])
        XCTAssertFalse(record.coach.isFinished)
        XCTAssertFalse(record.finished, "not the whole story: Today's card still offers it")
    }

    /// The author's limit (16 Oct): never more than 10 to 15 seconds without something for the pilot. Each
    /// stretch between two steps, in the pilot's seconds at the pace the flight ran at, is 13 at the most.
    func testNoStretchRunsLongerThan13SecondsWithoutACardOrATap() throws {
        let record = try flyTheStory(DryRunStart(part: .fly))
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
                                    guided: DryRunStart(part: .fly, chapter: chapter))
            let flight = try DryRunHeadless(self, setup: setup, plan: plan)
            let coach = try XCTUnwrap(flight.session.coach)
            XCTAssertTrue(coach.isFastForwarding)
            flight.fastForward()
            XCTAssertFalse(coach.isFastForwarding, "chapter \(chapter) reached")
            let first = DryRunChapters.steps.first { $0.chapter == chapter && $0.requires == .always && $0.screen == .cockpit }
            XCTAssertEqual(coach.step?.id, first?.id, "chapter \(chapter) opens on its first step")
            XCTAssertNotNil(flight.session.storyThread, "chapter \(chapter): its flight planned, as for the Plan part")
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
        let setup = DryRunSetup(mission: .route(plan, departure: .lszq, destination: .lszq), rate: 0,
                                guided: DryRunStart(part: .fly, chapter: 6))
        let flight = try DryRunHeadless(self, setup: setup, plan: plan)
        flight.fastForward()
        XCTAssertNotNil(flight.session.generator.mark("wp1"), "the generator passed the turning point itself")
        XCTAssertEqual(flight.session.coach?.step?.id, "approachCheck")
    }

    /// Close out and the Logbook on their own: the flight they need planned, flown and ended behind the
    /// cover, as the pilot would, then the part's first step on the ground.
    func testAPartOnItsOwnHasTheFlightItNeeds() throws {
        let plan = DryRunChapters.route(from: .lszq)
        for (part, first, state) in [(DryRunPart.closeOut, "openFlightPage", FlightThreadState.closeOut),
                                     (.logbook, "logbookTab", .done)] {
            let setup = DryRunSetup(mission: .route(plan, departure: .lszq, destination: .lszq), rate: 0,
                                    guided: DryRunStart(part: part))
            let flight = try DryRunHeadless(self, setup: setup, plan: plan)
            flight.fastForward()
            let coach = try XCTUnwrap(flight.session.coach)
            XCTAssertFalse(coach.isFastForwarding, "\(part) reached")
            XCTAssertEqual(coach.step?.id, first)
            XCTAssertEqual(coach.part, part, "the band names the part")
            XCTAssertFalse(flight.appState.isFlightActive, "on the ground")
            XCTAssertEqual(flight.session.storyThread?.state, state)
            XCTAssertEqual(flight.appState.flights.count, DryRunLogbook.flown.count + 1)
            flight.session.end()
        }
    }

    /// The made-up flights: circuits at the aerodrome, earlier in the year, each with its track, its times,
    /// its landings and its checks, as the logbook keeps a flight.
    func testTheDryRunsLogbookHasFiveMadeUpFlights() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let flights = DryRunLogbook.flights(at: .lszq, before: now)
        XCTAssertEqual(flights.count, 5)
        for (flight, flown) in zip(flights, DryRunLogbook.flown) {
            XCTAssertLessThan(flight.startTime ?? now, now)
            XCTAssertGreaterThan(flight.gpsTrack.count, 100)
            XCTAssertEqual(flight.touchAndGoCount, flown.touchAndGos)
            XCTAssertEqual(flight.fullStopCount, 1)
            XCTAssertEqual(flight.departureAirportIdent, "LSZQ")
            XCTAssertNotNil(flight.lineUpTime)
            XCTAssertNotNil(flight.landingTime)
            XCTAssertFalse(flight.checkOutcomes?.isEmpty ?? true)
        }
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
        center.requestGuided(DryRunStart(part: .fly, chapter: 3), presenter: "settings")
        XCTAssertEqual(center.presenter, "settings")
        XCTAssertEqual(center.guidedRequest?.start, DryRunStart(part: .fly, chapter: 3))
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

    /// The guided dry run from `start`, a pilot doing at once what each step asks, the app's screens coming up
    /// as the app opens them, the Cockpit's engine hours' prompt played as `FlightView` shows it. `stopAt`: Stop
    /// here on that page. Each stretch between two steps is timed in the pilot's seconds: a second of the flight
    /// at pace p is 1/p of the pilot's.
    private func flyTheStory(_ start: DryRunStart, stopAt: String? = nil) throws -> Record {
        let plan = DryRunChapters.route(from: .lszq)
        let setup = DryRunSetup(mission: .route(plan, departure: .lszq, destination: .lszq), rate: 0, guided: start)
        let flight = try DryRunHeadless(self, setup: setup, plan: plan)
        let session = flight.session
        let coach = try XCTUnwrap(session.coach)
        let appState = flight.appState
        appState.settings.logEngineHours = true
        if coach.isFastForwarding { flight.fastForward() }
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
            if appState.isFlightActive, appState.currentPhase == .engineStart,
               appState.currentFlight?.engineHourStart == nil, !prompted.contains("start") {
                prompted.insert("start")
                coach.hourMeter = .beforeStart
            }
            if appState.engineShutdownTime != nil, appState.currentFlight?.engineHourEnd == nil, !prompted.contains("stop") {
                prompted.insert("stop")
                coach.hourMeter = .afterStop
            }
            if let step = coach.step {
                if step.holds, step.screen == .cockpit { XCTAssertTrue(session.isCoachHolding, "the flight waits at \(step.id)") }
                if shown.last != step.id {
                    if stretch > 0 { gaps.append(Gap(after: shown.last ?? "start", before: step.id, seconds: stretch)) }
                    stretch = 0
                    shown.append(step.id)
                }
                if step.id == stopAt {
                    session.stop()
                    break
                }
                switch step.done {
                case .next, .partEnd: coach.next()
                case .hourMeterClosed:
                    if coach.hourMeter == .beforeStart { appState.currentFlight?.engineHourStart = 1234.5 }
                    if coach.hourMeter == .afterStop { appState.currentFlight?.engineHourEnd = 1235.0 }
                    coach.hourMeter = nil
                case .screen(let screen): coach.show(screen)
                case .screenClosed(let screen): coach.hide(screen)
                case .chipTapped: coach.noteChip(.prepare)
                case .linkTapped: coach.noteLink()
                case .flightStarted:
                    // START FLIGHT closes the flight's page and the ground, as the app does.
                    coach.actAsPilot(step, session)
                    coach.hide(.flightPage)
                    coach.hide(.today)
                default: coach.actAsPilot(step, session)
                }
                // The step's answer reaches the coach with the next fix, as in the Cockpit.
                flight.wait(1)
                continue
            }
            // A screen the app opens by itself (the flight's page once created): up.
            if coach.index < coach.steps.count, case .screen(let screen) = coach.steps[coach.index].moment {
                coach.show(screen)
            }
            flight.wait(1)
            if session.pace > 0 { stretch += 1 / session.pace }
            if coach.step == nil, appState.isFlightActive, session.foldedLine == nil, case .flying = session.state {
                linesMissing.append("\(session.generator.t)")
            }
        }
        return Record(session: session, coach: coach, shown: shown, gaps: gaps, finished: finished,
                      linesMissing: linesMissing)
    }
}
