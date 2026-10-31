import XCTest
@testable import AeroCheck

/// Onboarding's circuit on the ground (6.8.0, the author's answer p2 A, 31 Oct 2026): one circuit at home, three
/// moments for the pilot, the rest done for them, in about three minutes; ending on Today with the logbook's line.
@MainActor
final class DryRunFirstFlightTests: XCTestCase {

    func testItsStepsAreTheStorysWhereTheyCanBe() {
        let steps = DryRunFirstFlight.steps
        XCTAssertEqual(steps.count, Set(steps.map(\.id)).count, "unique ids")
        XCTAssertEqual(steps.first?.id, "startFlight")
        XCTAssertEqual(steps.last?.id, "ffEnd")
        XCTAssertEqual(steps.last?.kind, .partEnd)
        // What the pilot meets: the three moments, END FLIGHT, the end.
        let shown = steps.filter { !$0.auto }.map(\.id)
        XCTAssertEqual(shown, ["startFlight", "ffWelcome", "ffCheck", "ffDoneForYou", "mapTakeoff", "airborne", "ffRadio",
                               "ffLanding", "endFlight", "ffEnd"])
        XCTAssertFalse(DryRunStory.steps.contains { $0.id.hasPrefix("ff") }, "the story keeps its own steps")
        XCTAssertEqual(DryRunCoach(start: .firstFlight, steps: steps).startIndex, 1, "START FLIGHT behind the cover")
        XCTAssertEqual(DryRunFirstFlight.moment(ofChapter: 1), 1)
        XCTAssertEqual(DryRunFirstFlight.moment(ofChapter: 4), 2)
        XCTAssertEqual(DryRunFirstFlight.moment(ofChapter: 6), 3)
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
                pilotSeconds += 5   // reading a card, a tap or a check: a few seconds each
                continue
            }
            flight.wait(1)
            if session.pace > 0 { pilotSeconds += 1 / session.pace }
        }
        XCTAssertEqual(shown, ["ffWelcome", "ffCheck", "ffDoneForYou", "mapTakeoff", "airborne", "ffRadio", "ffLanding",
                               "endFlight", "ffEnd"])
        XCTAssertFalse(appState.isFlightActive, "the flight ended")
        // The newest: the dry run's made-up logbook flights are older.
        let logged = try XCTUnwrap(appState.flights.max { ($0.startTime ?? .distantPast) < ($1.startTime ?? .distantPast) })
        XCTAssertEqual(logged.totalLandings, 1, "one full stop")
        XCTAssertLessThan(pilotSeconds, 240, "about three minutes, not the story's fifteen: \(Int(pilotSeconds)) s")
    }
}
