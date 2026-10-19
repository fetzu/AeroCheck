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
    /// checks rings CHECK (or the slot naming the check, off CHECKLIST), and a control's own step (ENGINE START,
    /// READY FOR LINE UP, ENGINE SHUTDOWN, END FLIGHT) comes when the band shows it, after its check's items
    /// (the author's second dry run checks, st-10).
    func testAControlIsRungOnlyOnceTheBandShowsIt() {
        let steps = DryRunChapters.steps
        let controls: [DryRunCoachStep.Slot] = [.engineStart, .readyForLineUp, .engineShutdown, .endFlight]
        for step in steps {
            if case .shows = step.done {
                XCTAssertEqual(step.target, .check, "\(step.id) rings CHECK on the way")
            }
            if let slot = controls.first(where: { step.moment == .shows($0) || step.moment == .parkedAndShows($0) }) {
                XCTAssertTrue(step.target == .first || step.target == .primary, "\(step.id) rings \(slot)'s control")
            }
        }
        for control in ["engineStart", "readyForLineUp", "engineShutdown", "endFlight"] {
            let step = steps.first { $0.id == control }
            XCTAssertTrue(controls.contains { step?.moment == .shows($0) || step?.moment == .parkedAndShows($0) },
                          "\(control) waits for the band to show it")
        }
        XCTAssertEqual(steps.first { $0.id == "approachCheck" }?.moment, .nearCircuit(.check(.approach)),
                       "the approach check's card waits for the slot to name it, before the downwind (g-7, st-14)")
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

    /// With no call due as the cruise check is done (no route's timeline, NEXT tapped already), the radio's card
    /// is left out and nothing waits for it. (6.4.3)
    func testTheRadioCardIsLeftOutWithNoCallDue() throws {
        let record = try flyTheStory(.story, radioDue: false)
        let expected = DryRunStory.steps.filter { $0.requires != .notFromPlan && $0.id != "radioDue" }.map(\.id)
        XCTAssertEqual(record.shown, expected)
        XCTAssertTrue(record.coach.isFinished)
    }

    /// The radio's card holds the flight until NEXT is tapped: its due call made NOW by the pilot, not the app.
    func testTheRadioCardWaitsForTheTap() throws {
        var held = 0
        let record = try flyTheStory(.story) { step, session in
            guard step.id == "radioDue", held < 5 else { return false }
            XCTAssertTrue(session.isCoachHolding)
            held += 1
            return true
        }
        XCTAssertEqual(held, 5, "five seconds held at the card, NEXT not tapped")
        XCTAssertTrue(record.shown.contains("radioDue"))
        XCTAssertTrue(record.coach.isFinished)
    }

    // MARK: - The second round of device checks (16 Oct)

    /// A pilot ahead of the cards: the climb check worked through as soon as airborne, before it fell due. Its
    /// card has nothing to ask and goes; the story goes on to the go-around and the landing (the author's second
    /// run: the card waited for a check never due again, and came after the landing).
    func testAPilotAheadOfTheCardsIsNotHeldBack() throws {
        let record = try flyTheStory(DryRunStart(part: .fly), answer: { step, session in
            guard step.id == "airborne" else { return false }
            let appState = session.world.appState
            appState.nextPhase()
            DryRunCoach.workThroughCurrentCheck(appState)
            session.coach?.next()
            return true
        })
        XCTAssertFalse(record.shown.contains("climbCheck"), "\(record.shown)")
        XCTAssertTrue(record.shown.contains("goAround"))
        XCTAssertNotNil(record.session.generator.mark("goAround"))
        XCTAssertTrue(record.shown.contains("endFlight"))
    }

    /// The author's seventh round: after the go-around, the folded line still named the climb check once the
    /// aircraft had landed. A check the aircraft has flown past before its card came gives way.
    func testACheckTheAircraftHasFlownPastGivesWay() throws {
        let steps = DryRunStory.steps
        let climbAgain = try XCTUnwrap(steps.first { $0.id == "climbAgain" })
        let approachAgain = try XCTUnwrap(steps.first { $0.id == "approachAgain" })
        let goAroundCard = try XCTUnwrap(steps.first { $0.id == "goAroundCard" })
        let flight = try DryRunHeadless(self, setup: DryRunSetup(mission: .circuits(.lszq), rate: 0, landings: [.goAround]))
        flight.takeOff()
        let generator = flight.session.generator
        XCTAssertTrue(flight.fly(until: { generator.mark("goAround") != nil && generator.activity == .upwind }, within: 1500))
        XCTAssertFalse(DryRunCoach.flownPast(climbAgain, generator), "climbing away: the climb check is ahead")
        XCTAssertFalse(DryRunCoach.flownPast(goAroundCard, generator))
        XCTAssertTrue(flight.fly(until: { generator.activity == .downwind }, within: 600))
        XCTAssertTrue(DryRunCoach.flownPast(climbAgain, generator), "on the downwind")
        XCTAssertTrue(DryRunCoach.flownPast(goAroundCard, generator))
        XCTAssertFalse(DryRunCoach.flownPast(approachAgain, generator), "the approach check is the downwind's")
        XCTAssertTrue(flight.fly(until: { generator.activity == .final }, within: 600))
        XCTAssertTrue(DryRunCoach.flownPast(approachAgain, generator), "on final")
    }

    /// Close out and Your logbook on their own, whatever flight the dry run flies to them behind the cover:
    /// each opens on its first card (the author's fifth round, pt-3: Your logbook ended on the dry run's page).
    func testEveryPartOnItsOwnOpensOnItsFirstCardWhateverTheFlight() throws {
        for seed: UInt64 in [3, 7, 19, 42, 101, 2026] {
            for (part, first) in [(DryRunPart.closeOut, "openFlightPage"), (.logbook, "logbookTab")] {
                let record = try flyTheStory(DryRunStart(part: part), stopAt: first, seed: seed)
                XCTAssertEqual(record.shown.first, first, "\(part), seed \(seed)")
            }
        }
    }

    /// ENGINE SHUTDOWN as the engine stops: once the shutdown check's magnetos item is ticked, not at the
    /// check's end (the author's fifth round, 17 Oct). The WT9's check names them; a check that names neither
    /// the magnetos nor the ignition asks for it at its end.
    func testEngineShutdownComesAtTheMagnetosItem() throws {
        let appState = makeTestAppState()
        let item = try XCTUnwrap(DryRunCoach.engineStopItem(appState), "the WT9's check names the magnetos")
        appState.startFlight()
        appState.goToPhase(.shutdown)
        XCTAssertFalse(DryRunCoach.engineHasStopped(appState))
        for _ in 0...item { DryRunCoach.checkItem(appState) }
        XCTAssertTrue(DryRunCoach.engineHasStopped(appState), "the magnetos off")
        XCTAssertFalse(appState.currentCheckIsDone, "the rest of the check after it")
        XCTAssertTrue(DryRunCoach.shows(.engineShutdown, appState))
    }

    /// A card that speaks of the landing check says it as the pilot flies it: its items to work through, or,
    /// hidden as memory items, from memory (the author's fifth round: "from memory" with the items on the page).
    func testTheLandingCardsSayTheLandingCheckAsItIsFlown() throws {
        let appState = makeTestAppState()
        let step = try XCTUnwrap(DryRunChapters.steps.first { $0.id == "fullStop" })
        appState.settings.learningMode = true
        XCTAssertEqual(step.text(appState), step.body)
        XCTAssertEqual(step.foldText(appState), step.fold)
        appState.settings.learningMode = false
        XCTAssertTrue(appState.isMemoryCheck(.landing))
        XCTAssertEqual(step.text(appState), step.memoryBody)
        XCTAssertEqual(step.foldText(appState), step.memoryFold)
        XCTAssertNotEqual(step.body, step.memoryBody)
    }

    /// No word of a ring on any card: the cards say what to press (the author's fifth round, 17 Oct).
    func testNoCardSpeaksOfARing() {
        for step in DryRunStory.steps {
            for text in [step.body, step.memoryBody, step.fold, step.memoryFold].compactMap({ $0 }) {
                XCTAssertNil(text.range(of: "\\bring\\b", options: [.regularExpression, .caseInsensitive]),
                             "\(step.id): \(text)")
            }
        }
    }

    /// The climb check waits for the take-off: on the runway, the line up check done, NEXT goes nowhere and the
    /// slot opens the checklist, whose NEXT says AFTER TAKE-OFF (the phase bar still goes anywhere, the way out);
    /// once airborne it goes on (the author's fifth
    /// round, 17 Oct: the climb check done before the aircraft took off).
    func testTheClimbCheckWaitsForTheTakeoff() throws {
        var tried = false
        let record = try flyTheStory(DryRunStart(part: .fly), answer: { step, session in
            guard step.id == "lineUpCheck", !tried else { return false }
            tried = true
            let appState = session.world.appState
            DryRunCoach.workThroughCurrentCheck(appState)
            XCTAssertTrue(appState.waitsForTakeoff)
            appState.nextPhase()
            XCTAssertEqual(appState.currentPhase, .lineUp, "no climb check on the runway")
            XCTAssertEqual(CockpitCheckSlot.slot(for: appState).action, .showChecklist)
            return true
        })
        XCTAssertTrue(tried)
        XCTAssertTrue(record.shown.contains("climbCheck"), "\(record.shown)")
        XCTAssertTrue(record.shown.contains("endFlight"))
    }

    /// A real flight's climb check waits for the take-off too, and never traps the pilot: only with a field to
    /// see the take-off from, and not once rolling at 40 kt (the author's answer, 17 Oct).
    func testARealFlightsClimbCheckWaitsButNeverTraps() {
        let appState = makeTestAppState()
        appState.startFlight()
        addTeardownBlock { @MainActor in appState.cancelFlight() }
        appState.goToPhase(.lineUp, skipped: .alreadyDone)
        XCTAssertFalse(appState.waitsForTakeoff, "no field to see the take-off from: as before")
        appState.noteCueSourceReady()
        XCTAssertTrue(appState.waitsForTakeoff)
        appState.noteGroundSpeed(45)
        XCTAssertFalse(appState.waitsForTakeoff, "rolling: the take-off roll")
        appState.noteGroundSpeed(5)
        XCTAssertTrue(appState.waitsForTakeoff)
        appState.noteFlightCue(FlightCueEvent(kind: .leg, time: Date(), implied: false, aerodrome: "LSZQ"))
        XCTAssertFalse(appState.waitsForTakeoff, "the take-off seen")
        appState.nextPhase()
        XCTAssertEqual(appState.currentPhase, .climb)
    }

    /// The phase bar and the phase list go on from the line up check whatever the gate: the way out when the
    /// take-off can't come (the author's sixth round, r6-12: a NEW CIRCUIT tapped by mistake at the parking,
    /// the line up check, and the jump's DEFER or ALREADY DONE doing nothing).
    func testThePhaseBarAlwaysGoesOnFromTheLineUpCheck() {
        let appState = makeTestAppState()
        appState.startFlight()
        addTeardownBlock { @MainActor in appState.cancelFlight() }
        appState.noteCueSourceReady()
        appState.goToPhase(.lineUp, skipped: .alreadyDone)
        XCTAssertTrue(appState.waitsForTakeoff)
        appState.goToPhase(.afterLanding, skipped: .alreadyDone)
        XCTAssertEqual(appState.currentPhase, .afterLanding)
    }

    /// No NEW CIRCUIT in the story, which ends at the parking (r6-12); free practice keeps it.
    func testTheStoryOffersNoNewCircuit() throws {
        let plan = DryRunChapters.route(from: .lszq)
        let story = try DryRunHeadless(self, setup: DryRunSetup(mission: .route(plan, departure: .lszq, destination: .lszq),
                                                                rate: 0, guided: .story), plan: plan)
        XCTAssertFalse(story.appState.newCircuitAllowed)
        let practice = try DryRunHeadless(self, setup: DryRunSetup(mission: .circuits(.lszq), rate: 0))
        XCTAssertTrue(practice.appState.newCircuitAllowed)
    }

    /// The ATC flight plan ticked rather than set aside: either answers its card (st-7).
    func testTheATCFlightPlanTickedAlsoGoesOn() throws {
        let record = try flyTheStory(.story, stopAt: "end.plan", answer: { step, session in
            guard step.id == "notApplicable" else { return false }
            session.setStoryTask(.flightPlanFiled, to: .done)
            return true
        })
        XCTAssertEqual(Array(record.shown.suffix(2)), ["notApplicable", "end.plan"])
    }

    /// The card folds to one line once the pilot does what an unveiled do step asks (an item checked), and
    /// stays open once opened again; the next step opens it.
    func testTheCardFoldsOnceThePilotIsAtItAndOpensAgain() throws {
        let plan = DryRunChapters.route(from: .lszq)
        let setup = DryRunSetup(mission: .route(plan, departure: .lszq, destination: .lszq), rate: 0,
                                guided: DryRunStart(part: .fly, chapter: 2))
        let flight = try DryRunHeadless(self, setup: setup, plan: plan)
        let coach = try XCTUnwrap(flight.session.coach)
        flight.fastForward()
        XCTAssertEqual(coach.step?.id, "toEngineStart")
        XCTAssertFalse(coach.isFolded)
        DryRunCoach.checkItem(flight.appState)
        flight.wait(1)
        XCTAssertTrue(coach.isFolded, "an item checked: the card folds")
        coach.showAgain()
        XCTAssertFalse(coach.isFolded)
        DryRunCoach.checkItem(flight.appState)
        flight.wait(1)
        XCTAssertFalse(coach.isFolded, "opened again by the pilot: it stays open")
        flight.session.end()
    }

    /// How far into its part the card is: the bar along its top edge.
    func testTheCardSaysHowFarIntoItsPart() throws {
        let plan = DryRunChapters.route(from: .lszq)
        let setup = DryRunSetup(mission: .route(plan, departure: .lszq, destination: .lszq), rate: 0, guided: .story)
        let flight = try DryRunHeadless(self, setup: setup, plan: plan)
        let coach = try XCTUnwrap(flight.session.coach)
        flight.wait(1)
        XCTAssertEqual(coach.step?.id, "today")
        let progress = try XCTUnwrap(coach.partProgress)
        XCTAssertEqual(progress.done, 0)
        XCTAssertEqual(progress.total, DryRunStory.steps.filter { $0.part == .plan && $0.kind != .partEnd }.count)
        flight.session.end()
    }

    // MARK: - The third round of device checks (16 Oct)

    /// DEFER's card when nothing can be deferred any more (the check worked through, or a memory check): it goes
    /// by itself, and the chip's card with it; the story goes on (r3-10: DEFER disabled, and no way on).
    func testDEFERNeverHoldsTheStoryWhenNothingCanBeDeferred() throws {
        let record = try flyTheStory(DryRunStart(part: .fly), answer: { step, session in
            guard step.id == "defer" else { return false }
            DryRunCoach.workThroughCurrentCheck(session.world.appState)
            return true
        })
        XCTAssertTrue(record.shown.contains("defer"))
        XCTAssertFalse(record.shown.contains("deferredChip"), "nothing deferred: no chip to show")
        XCTAssertTrue(record.shown.contains("endFlight"), "\(record.shown)")
    }

    /// The memory items in the engine start check, which has some (r3-7): the Menu rung, then its switch once
    /// it is open; closing the Menu goes on to the check's items.
    func testTheMemoryItemsComeInTheEngineStartCheck() {
        let ids = DryRunChapters.steps.map(\.id)
        let memory = try? XCTUnwrap(ids.firstIndex(of: "memoryTest"))
        XCTAssertEqual(DryRunChapters.steps.first { $0.id == "memoryTest" }?.chapter, 2)
        XCTAssertEqual(memory.map { ids[$0 + 1] }, "memorySwitch")
        XCTAssertLessThan(ids.firstIndex(of: "memorySwitch") ?? .max, ids.firstIndex(of: "engineStartCheck") ?? 0)
        let toggle = DryRunChapters.steps.first { $0.id == "memorySwitch" }
        XCTAssertEqual(toggle?.screen, .menu)
        XCTAssertEqual(toggle?.target, .memoryItemsToggle)
    }

    /// A pilot who hides the memory items when the Menu's card shows the switch, as the author did (16 Oct):
    /// every check from then on that is all memory items reads "from memory, one tap when done". The story goes
    /// on to its end all the same (r3-15: it stopped after the landing, its line naming the climb check).
    func testAPilotWhoHidesTheMemoryItemsFliesTheWholeStory() throws {
        let record = try flyTheStory(DryRunStart(part: .fly), answer: { step, session in
            guard step.id == "memorySwitch" else { return false }
            session.world.appState.settings.learningMode = false
            session.coach?.hide(.menu)
            return true
        })
        XCTAssertTrue(record.shown.contains("endFlight"), "\(record.shown)")
        XCTAssertTrue(record.coach.isFinished || record.shown.last == "end.fly", "\(record.shown)")
    }

    /// Folded, a card that sends the pilot through the checks says what to do, with a verb (r3-8).
    func testAFoldedCardSaysWhatToDo() {
        for step in DryRunChapters.steps where step.kind == .act && !step.veils && step.screen == .cockpit
            && step.target == .check {
            XCTAssertNotNil(step.fold, step.id)
        }
    }

    /// The guided dry run shows every item, whatever the pilot hides: its cards wait for checks named due.
    func testTheGuidedWorldShowsEveryItem() {
        var settings = AppSettings()
        settings.learningMode = false
        XCTAssertTrue(DryRunCenter.worldSettings(settings, guided: true).learningMode)
        XCTAssertFalse(DryRunCenter.worldSettings(settings, guided: false).learningMode, "free practice: the pilot's")
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
            // The go-around where the flight is going took up circuits: no cruise or descent check on that
            // lap, so none passed over and deferred at the landing (the author, st-14).
            XCTAssertEqual(flight.appState.deferredItemCount, 0, "chapter \(chapter): nothing deferred on the way")
            XCTAssertEqual(flight.appState.deferredChecks, [], "chapter \(chapter)")
            if chapter == 7 { XCTAssertTrue(flight.appState.isCircuitMode, "circuits from the go-around on") }
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
    /// `answer`: the test's own answer to a step, in place of the pilot's (true: answered).
    /// `radioDue`: the Cockpit's radio as it reads at the level-off, NEXT due (the frequency handover, 6.4.3); the
    /// headless flight has no Cockpit to say it.
    private func flyTheStory(_ start: DryRunStart, stopAt: String? = nil, seed: UInt64 = 11, radioDue: Bool = true,
                             answer: ((DryRunCoachStep, DryRunSession) -> Bool)? = nil) throws -> Record {
        let plan = DryRunChapters.route(from: .lszq)
        let setup = DryRunSetup(mission: .route(plan, departure: .lszq, destination: .lszq), rate: 0, guided: start)
        let flight = try DryRunHeadless(self, setup: setup, plan: plan, seed: seed)
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
        var radioGiven = false

        for _ in 0..<(4 * 3600) {
            if case .over = session.state { break }
            if radioDue, !radioGiven, appState.flightCues.fired[.levelOff] != nil {
                radioGiven = true
                appState.radioNextIsDue = true
            }
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
                if let answer, answer(step, session) {
                    flight.wait(1)
                    continue
                }
                switch step.done {
                case .next, .partEnd: coach.next()
                case .hourMeterClosed:
                    if coach.hourMeter == .beforeStart { appState.currentFlight?.engineHourStart = 1234.5 }
                    if coach.hourMeter == .afterStop { appState.currentFlight?.engineHourEnd = 1235.0 }
                    coach.hourMeter = nil
                case .screen(let screen): coach.show(screen)
                case .screenClosed(let screen): coach.hide(screen)
                case .linkTapped: coach.noteLink()
                case .fullTanksTapped: coach.noteFullTanks()
                // NEXT tapped: the Cockpit's radio no longer has it due.
                case .radioSwitched: appState.radioNextIsDue = false
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
