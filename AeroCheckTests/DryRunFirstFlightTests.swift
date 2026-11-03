import XCTest
@testable import AeroCheck

/// Onboarding's circuit on the ground (6.8.0, the author's answer p2 A, 31 Oct 2026): one circuit at home, three
/// moments for the pilot, the rest done for them, in about three minutes; ending on Today with the logbook's line.
@MainActor
final class DryRunFirstFlightTests: XCTestCase {

    func testTheFirstFlightsMapShowsTheCircuitsTheRoutesAndTheTrackVector() {
        // The author's device check r4-41 (2 Nov 2026): on, whatever the pilot's own; the full dry run keeps theirs.
        var pilot = AppSettings()
        pilot.showVFRCircuitsOnMap = false
        pilot.showVFRRoutesOnMap = false
        pilot.showTrackVector = false
        let first = DryRunCenter.worldSettings(pilot, guided: true, firstFlight: true)
        XCTAssertTrue(first.showVFRCircuitsOnMap)
        XCTAssertTrue(first.showVFRRoutesOnMap)
        XCTAssertTrue(first.showTrackVector)
        let story = DryRunCenter.worldSettings(pilot, guided: true)
        XCTAssertFalse(story.showVFRCircuitsOnMap)
        XCTAssertFalse(story.showTrackVector)
    }

    func testItsStepsAreTheStorysWhereTheyCanBe() {
        let steps = DryRunFirstFlight.steps
        XCTAssertEqual(steps.count, Set(steps.map(\.id)).count, "unique ids")
        XCTAssertEqual(steps.first?.id, "startFlight")
        XCTAssertEqual(steps.last?.id, "ffEnd")
        XCTAssertEqual(steps.last?.kind, .partEnd)
        // What the pilot meets: the three moments, END FLIGHT, the end.
        let shown = steps.filter { !$0.auto }.map(\.id)
        XCTAssertEqual(shown, ["startFlight", "ffMeet", "ffList", "ffButtons", "ffCheck", "ffDoneForYou", "ffStrip",
                               "mapTakeoff", "airborne", "ffRadio", "ffApproach", "ffCircuits", "endFlight", "ffEnd"])
        // The third moment is the approach check, said on the downwind; the landing check, a memory item, is done
        // for the pilot (the author's device check r4-20, 1 Nov 2026).
        XCTAssertEqual(steps.first { $0.id == "ffApproach" }?.moment, .downwind(0.2, .check(.approach)))
        XCTAssertEqual(steps.first { $0.id == "ffLanding" }?.auto, true)
        XCTAssertFalse(DryRunStory.steps.contains { $0.id.hasPrefix("ff") }, "the story keeps its own steps")
        XCTAssertEqual(DryRunCoach(start: .firstFlight, steps: steps).startIndex, 1, "START FLIGHT behind the cover")
        XCTAssertEqual(DryRunFirstFlight.moment(ofChapter: 1), 1)
        XCTAssertEqual(DryRunFirstFlight.moment(ofChapter: 4), 2)
        XCTAssertEqual(DryRunFirstFlight.moment(ofChapter: 6), 3)
    }

    func testTheCircuitEndsWithMemoryItemsHidden() throws {
        // The author's device check r4-38 (1 Nov 2026): learning mode off, as a pilot who knows the WT9's memory
        // items flies it; the approach and the landing check then ask for one confirmation each.
        let setup = DryRunSetup(mission: .circuits(.lszq), rate: 0, landings: [.fullStop], guided: .firstFlight)
        let flight = try DryRunHeadless(self, setup: setup, seed: 11)
        flight.appState.settings.learningMode = false
        let session = flight.session
        let coach = try XCTUnwrap(session.coach)
        flight.fastForward()
        var shown: [String] = []
        var stuck = ""
        for _ in 0..<(2 * 3600) {
            if case .over = session.state { break }
            if let step = coach.step {
                if shown.last != step.id { shown.append(step.id) }
                if step.id == "ffEnd" { break }
                switch step.done {
                case .next, .partEnd: coach.next()
                default: coach.actAsPilot(step, session)
                }
                flight.wait(1)
                continue
            }
            flight.wait(1)
        }
        stuck = "\(coach.step?.id ?? "none") at \(flight.appState.currentPhase), index \(coach.index)"
        XCTAssertEqual(shown, ["ffMeet", "ffList", "ffButtons", "ffCheck", "ffDoneForYou", "ffStrip", "mapTakeoff",
                               "airborne", "ffRadio", "ffApproach", "ffCircuits", "endFlight", "ffEnd"], stuck)
        XCTAssertFalse(flight.appState.isFlightActive, "the flight ended: \(stuck)")
    }

    func testTheFlightDataCardComesOnTheTaxiAndTheCircuitsCardOnceStopped() throws {
        // The author's rework of 2 Nov 2026 (r4-41): the strip explained as the aircraft taxis out, moving under the
        // card; circuits once stopped after the landing, before AT THE HANGAR.
        let setup = DryRunSetup(mission: .circuits(.lszq), rate: 0, landings: [.fullStop], guided: .firstFlight)
        let flight = try DryRunHeadless(self, setup: setup, seed: 11)
        let session = flight.session
        let coach = try XCTUnwrap(session.coach)
        flight.fastForward()
        var seen: [String: DryRunGenerator.Activity] = [:]
        var stripSeconds = 0
        for _ in 0..<(2 * 3600) {
            guard let step = coach.step else { flight.wait(1); continue }
            if seen[step.id] == nil { seen[step.id] = session.generator.activity }
            if step.id == "ffEnd" { break }
            if step.id == "ffStrip", stripSeconds < 10 {
                // Read for ten seconds: the aircraft keeps taxiing.
                stripSeconds += 1
                flight.wait(1)
                continue
            }
            switch step.done {
            case .next, .partEnd: coach.next()
            default: coach.actAsPilot(step, session)
            }
            flight.wait(1)
        }
        XCTAssertEqual(seen["ffStrip"], .taxiing)
        XCTAssertEqual(session.generator.mark("liftoff") != nil, true)
        XCTAssertTrue([.stopped, .taxiingIn, .parkedEnd].contains(seen["ffCircuits"]),
                      "\(String(describing: seen["ffCircuits"]))")
    }

    func testTheCockpitShowsMapAfterTheApproachCheckAndChecklistForEndFlight() throws {
        // The author's device check r4-38 (1 Nov 2026): MAP once the approach check is done, to watch the circuit
        // end; CHECKLIST when END FLIGHT's card comes, the only band with END FLIGHT.
        let setup = DryRunSetup(mission: .circuits(.lszq), rate: 0, landings: [.fullStop], guided: .firstFlight)
        let flight = try DryRunHeadless(self, setup: setup, seed: 11)
        let session = flight.session
        let coach = try XCTUnwrap(session.coach)
        flight.fastForward()
        var asked: [CockpitPage] = []
        var lastSerial = 0
        for _ in 0..<(2 * 3600) {
            if let request = coach.pageRequest, request.serial != lastSerial {
                asked.append(request.page)
                lastSerial = request.serial
            }
            guard let step = coach.step else { flight.wait(1); continue }
            if step.id == "endFlight" { break }
            switch step.done {
            case .next, .partEnd: coach.next()
            default: coach.actAsPilot(step, session)
            }
            flight.wait(1)
        }
        XCTAssertEqual(coach.step?.id, "endFlight")
        XCTAssertEqual(asked, [.checklist, .checklist, .checklist, .map, .checklist],
                       "CHECKLIST for the cockpit's cards, MAP after the approach check, CHECKLIST for END FLIGHT")
    }

    func testENDAtEndFlightEndsTheCircuitAsEndFlightDoes() throws {
        // The author's device check r4-38: END (the dry run's own) with only END FLIGHT left ended the circuit
        // unticked; it now ends it as END FLIGHT does, logged, with the last card to come.
        let setup = DryRunSetup(mission: .circuits(.lszq), rate: 0, landings: [.fullStop], guided: .firstFlight)
        let flight = try DryRunHeadless(self, setup: setup, seed: 11)
        let session = flight.session
        let coach = try XCTUnwrap(session.coach)
        flight.fastForward()
        for _ in 0..<(2 * 3600) {
            guard let step = coach.step else { flight.wait(1); continue }
            if step.id == "endFlight" { break }
            switch step.done {
            case .next, .partEnd: coach.next()
            default: coach.actAsPilot(step, session)
            }
            flight.wait(1)
        }
        XCTAssertEqual(coach.step?.id, "endFlight")
        session.stop()
        flight.wait(1)
        XCTAssertFalse(flight.appState.isFlightActive, "the flight ended")
        let logged = try XCTUnwrap(flight.appState.flights.max { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) })
        XCTAssertEqual(logged.totalLandings, 1, "logged as END FLIGHT logs it")
        XCTAssertEqual(coach.step?.id, "ffEnd", "the last card follows")
    }

    func testOneCircuitInAboutThreeMinutesOfThePilotsTime() throws {
        let setup = DryRunSetup(mission: .circuits(.lszq), rate: 0, landings: [.fullStop], guided: .firstFlight)
        let flight = try DryRunHeadless(self, setup: setup, seed: 11)
        let session = flight.session
        let coach = try XCTUnwrap(session.coach)
        let appState = flight.appState
        XCTAssertTrue(coach.isFastForwarding)
        flight.fastForward()
        var shown: [String] = []
        var pilotSeconds = 0.0
        var approachShownAt: (activity: DryRunGenerator.Activity, fraction: Double?)?
        for _ in 0..<(2 * 3600) {
            if case .over = session.state { break }
            if let step = coach.step {
                if shown.last != step.id { shown.append(step.id) }
                if step.id == "ffApproach", approachShownAt == nil {
                    approachShownAt = (session.generator.activity, session.generator.downwindFraction)
                }
                if step.id == "ffEnd" { break }
                switch step.done {
                case .next, .partEnd: coach.next()
                default: coach.actAsPilot(step, session)
                }
                flight.wait(1)
                pilotSeconds += 5   // reading a card, a tap or a check: a few seconds each
                continue
            }
            flight.wait(1)
            if session.pace > 0 { pilotSeconds += 1 / session.pace }
        }
        XCTAssertEqual(shown, ["ffMeet", "ffList", "ffButtons", "ffCheck", "ffDoneForYou", "ffStrip", "mapTakeoff",
                               "airborne", "ffRadio", "ffApproach", "ffCircuits", "endFlight", "ffEnd"])
        let approach = try XCTUnwrap(approachShownAt)
        XCTAssertEqual(approach.activity, .downwind, "the approach check's card on the downwind")
        let fraction = try XCTUnwrap(approach.fraction)
        XCTAssertGreaterThanOrEqual(fraction, 0.2)
        XCTAssertLessThan(fraction, 0.35, "a fifth of the way down, not at its end: \(fraction)")
        XCTAssertFalse(appState.isFlightActive, "the flight ended")
        // The newest: the dry run's made-up logbook flights are older.
        let logged = try XCTUnwrap(appState.flights.max { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) })
        XCTAssertEqual(logged.totalLandings, 1, "one full stop")
        XCTAssertLessThan(pilotSeconds, 240, "about three minutes, not the story's fifteen: \(Int(pilotSeconds)) s")
    }
}
