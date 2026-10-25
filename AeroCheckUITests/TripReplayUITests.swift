import XCTest

/// A trip flown past its stop, as ground replays (6.6.0, t3 and t6): LSZQ → LSZP → LSZG planned for today, LSZP
/// the route's usual stop, so Plan new flight's trip has two legs; the track flies past LSZP and lands at LSZG,
/// leg 2's destination. With Fly on in the Divert sheet before LSZP, the flight goes on to LSZG on its own route;
/// without it, the landing at LSZG asks whether the stop was skipped.
final class TripReplayUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    /// trip-1: in cruise, before LSZP, Divert › LSZG › Fly on: DEST becomes LSZG and stays it to the landing.
    /// After END FLIGHT nothing asks about a diversion: the flight landed where its route ends.
    func testFlyingOnPastTheStopTakesTheRouteToTheNextLegsField() {
        let pilot = CockpitPilot(self, scenario: "trip-past-stop", page: "660")
        defer { pilot.attachResults(testName: name) }
        let s = pilot.scenario
        takeOff(pilot)
        // A minute into the cruise, some nine minutes before LSZP.
        pilot.waitForTrack(s.mark("levelOff") + 60)
        let before = pilot.destinationLabel()
        pilot.check("trip-1", before?.contains("LSZP") == true, "DEST is leg 1's, LSZP: \(before ?? "?")")
        guard pilot.tap("act.divert") else { return pilot.check("trip-1", false, "no Divert in the act band") }
        guard pilot.tap("divert.flyOn.LSZG") else {
            pilot.shot("trip-1", "sheet")
            return pilot.check("trip-1", false, "no Fly on for LSZG in the Divert sheet")
        }
        let confirm = pilot.app.buttons["Fly on to LSZG"].firstMatch
        pilot.shot("trip-1", "question")
        guard confirm.waitForExistence(timeout: 5), pilot.tapNow(confirm) else {
            return pilot.check("trip-1", false, "the question's Fly on to LSZG never came")
        }
        _ = pilot.waitUntil(timeout: 5) { pilot.destinationLabel()?.contains("LSZG") == true }
        let after = pilot.destinationLabel()
        pilot.shot("trip-1", "route")
        pilot.check("trip-1", after?.contains("LSZG") == true, "DEST after Fly on: \(after ?? "?")")

        // Past LSZP the route goes on: DEST is still LSZG.
        pilot.waitForTrack(s.mark("wp1") + 30)
        let past = pilot.destinationLabel()
        pilot.check("trip-1", past?.contains("LSZG") == true, "DEST past LSZP: \(past ?? "?")")
        pilot.waitForTrack(s.mark("vacated") + 20)
        pilot.endFlight()
        pilot.shot("trip-1", "today")
        pilot.check("trip-1", !pilot.element("landed.skipStop").exists && !pilot.element("landed.continue").exists,
                    "after END FLIGHT, no question about a diversion or a skipped stop")
    }

    /// trip-2: no tap. The route ends at LSZP, the flight flies on and lands at LSZG. After END FLIGHT, Today
    /// asks "You landed at LSZG, leg 2's destination"; Skip the stop at LSZP takes leg 2 off the trip, and
    /// nothing offers to continue to LSZP.
    func testALandingAtTheNextLegsFieldAsksAboutTheSkippedStop() {
        let pilot = CockpitPilot(self, scenario: "trip-past-stop", page: "660")
        defer { pilot.attachResults(testName: name) }
        let s = pilot.scenario
        takeOff(pilot)
        pilot.waitForTrack(s.mark("vacated") + 20)
        pilot.endFlight()
        let skip = pilot.element("landed.skipStop")
        let asked = skip.waitForExistence(timeout: 10)
        pilot.shot("trip-2", "question")
        guard asked else { return pilot.check("trip-2", false, "Today never asked about the stop at LSZP") }
        pilot.check("trip-2", pilot.element("landed.itWasADiversion").exists, "the question has both answers")
        pilot.tapNow(skip)
        let gone = pilot.waitUntil(timeout: 5) { !pilot.element("landed.skipStop").exists }
        pilot.shot("trip-2", "skipped")
        pilot.check("trip-2", gone && !pilot.element("landed.continue").exists,
                    "after Skip the stop, no question and no Continue to LSZP")
    }

    /// Today's START FLIGHT on leg 1, the checks to the holding point, READY FOR LINE UP, the line-up done:
    /// the replay flies on by itself from there. (As the ETO replays do: the climb check comes with the take-off.)
    private func takeOff(_ pilot: CockpitPilot) {
        pilot.launch()
        guard pilot.startFlight() else { return XCTFail("START FLIGHT did not bring the Cockpit up") }
        pilot.workChecks(until: "afterEngineStart")
        pilot.noteRelease(atTrack: 0)
        pilot.workChecks(until: "beforeDeparture")
        pilot.readyForLineUp()
        pilot.confirmMemoryCheck()
    }
}
