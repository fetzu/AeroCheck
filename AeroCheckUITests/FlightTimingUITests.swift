import XCTest

/// The 6.1.0 page's ETOs (eet-3, eet-4), flown as ground replays: LSZQ → INS → LSGC planned for today,
/// an hour after the replay starts (Plan new flight's flight, its route armed), started with START FLIGHT
/// and "Start anyway"; then READY FOR LINE UP at the holding point, or a jump on the phase bar past it.
/// After END FLIGHT, the flight's page in the Logbook: PLAN vs ACTUAL.
final class FlightTimingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    /// eet-4: READY FOR LINE UP at the holding point: the ETOs count from it plus 2 min, and stay there in
    /// flight (the take-off comes within a minute of that estimate); after END FLIGHT they count from the
    /// take-off measured.
    func testReadyForLineUpAnchorsTheETOs() {
        let pilot = CockpitPilot(self, scenario: "xc-planned")
        defer { pilot.attachResults(testName: name) }
        let s = pilot.scenario
        pilot.launch()
        guard pilot.startFlight() else { return XCTFail("START FLIGHT did not bring the Cockpit up") }
        pilot.workChecks(until: "afterEngineStart")
        pilot.noteRelease(atTrack: 0)
        pilot.workChecks(until: "beforeDeparture")
        let planned = pilot.destinationETA()
        pilot.shot("eet-4", "planned")
        pilot.readyForLineUp()
        let anchored = pilot.destinationETA()
        pilot.shot("eet-4", "line-up")
        pilot.check("eet-4", planned != nil && anchored != nil && planned != anchored,
                    "READY FOR LINE UP moves the ETA: planned \(planned ?? "?") → \(anchored ?? "?")")
        // The LINE UP check's ✓ DONE is on CHECKLIST, and the ETA was just read on ROUTE. (6.2)
        pilot.confirmMemoryCheck()
        // The departure on MAP, ten minutes of it: the track leaves LSZQ on the runway's heading and joins
        // the leg to INS some 9 NM out, 1.0 to 1.6 NM off it until then. OFF ROUTE never shows (6.2, PR 4):
        // the aircraft is on its way to the route, not off it.
        let departure = pilot.watchStatus(untilTrack: s.mark("liftoff") + 600)
        pilot.shot("offroute-1", "xc-planned-departure")
        pilot.recordOffRoute(departure, "xc-planned, the departure to 9 NM out")
        let inFlight = pilot.destinationETA()
        pilot.shot("eet-4", "in-flight")
        pilot.check("eet-4", inFlight == anchored, "in flight the ETA stays on LINE UP + 2 min: \(anchored ?? "?") → \(inFlight ?? "?")")
        pilot.endFlight()
        afterTheFlight(pilot, step: "eet-4", planned: planned, inFlight: inFlight)
    }

    /// eet-3, as 6.2 has it: no READY FOR LINE UP (a jump on the phase bar from the check before departure
    /// to the line-up): within ~30 s of lift-off the destination's ETA jumps to the take-off plus the EET;
    /// after END FLIGHT the departure's ATO is the take-off and its ETO the planned departure.
    func testPhaseBarJumpLetsTheTakeoffAnchorTheETOs() {
        let pilot = CockpitPilot(self, scenario: "xc-planned")
        defer { pilot.attachResults(testName: name) }
        let s = pilot.scenario
        pilot.launch()
        guard pilot.startFlight() else { return XCTFail("START FLIGHT did not bring the Cockpit up") }
        pilot.workChecks(until: "afterEngineStart")
        pilot.noteRelease(atTrack: 0)
        pilot.workChecks(until: "beforeDeparture")
        pilot.checkAllItems()
        let planned = pilot.destinationETA()
        pilot.shot("eet-3", "planned")
        // The jump: the replay's hold at the holding point lets go once the line-up check is reached. On
        // the phase bar on the iPad, in the phase list on the phone.
        pilot.jump(to: "lineUp")
        let ask = pilot.app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'already done'")).firstMatch
        if ask.waitForExistence(timeout: 2) { pilot.tapNow(ask) }
        pilot.check("eet-3", pilot.waitUntil(timeout: 4) { pilot.currentPhase == "lineUp" }, "jumped to \(pilot.currentPhase ?? "?")")
        pilot.noteRelease(atTrack: s.holds.first { $0.until == "lineUp" }?.t ?? 0)
        let beforeTakeoff = pilot.destinationETA()
        pilot.check("eet-3", beforeTakeoff == planned, "no LINE UP recorded: the ETA stays planned (\(planned ?? "?") → \(beforeTakeoff ?? "?"))")
        // The LINE UP check's ✓ DONE is on CHECKLIST, and the ETA was just read on ROUTE. (6.2)
        pilot.confirmMemoryCheck()
        var jumpedAt: Double?
        var latest: String?
        _ = pilot.waitUntil(timeout: pilot.wallUntil(track: s.mark("liftoff") + 60, margin: 10)) {
            latest = pilot.destinationETA()
            if latest != nil && latest != planned { jumpedAt = pilot.trackNow; return true }
            return false
        }
        pilot.shot("eet-3", "after-liftoff")
        pilot.check("eet-3", jumpedAt.map { $0 - s.mark("liftoff") <= 30 + 15 * 1.5 } ?? false,
                    "the ETA jumps to the take-off + EET \(jumpedAt.map { "\(Int($0 - s.mark("liftoff"))) s" } ?? "never") after lift-off: \(planned ?? "?") → \(latest ?? "?") (the take-off is looked for every 15 s)")
        pilot.endFlight()
        afterTheFlight(pilot, step: "eet-3", planned: planned, inFlight: latest)
    }

    /// The flight's page after END FLIGHT: PLAN vs ACTUAL. The departure's ATO is the take-off and its ETO
    /// the planned departure (`FlightPlan.estimatedTimeOver(at: 0)`: `plannedDepartureTime`, what the
    /// editor shows); the destination's ETO counts from the take-off: DEST ETO − departure ATO is the
    /// EET planned, planned DEST ETA − departure ETO. To the minute, as the page shows them.
    private func afterTheFlight(_ pilot: CockpitPilot, step: String, planned: String?, inFlight: String?) {
        guard pilot.openNewestFlightInLogbook() else { return pilot.check(step, false, "no flight in the Logbook") }
        _ = pilot.waitUntil(timeout: 5) { !pilot.planVsActual().isEmpty }
        let rows = pilot.planVsActual()
        let takeoff = pilot.timelineTime("Take-off")
        pilot.scrollTo("PLAN vs ACTUAL")
        pilot.shot(step, "flight-log")
        guard let departure = rows.first, let destination = rows.last, rows.count >= 2,
              let plannedETA = planned else {
            return pilot.check(step, false, "PLAN vs ACTUAL: \(rows), planned ETA \(planned ?? "?")")
        }
        let eetPlanned = CockpitPilot.minutes(from: departure.eto, to: plannedETA)
        let eetFlown = CockpitPilot.minutes(from: departure.ato, to: destination.eto)
        pilot.check(step, departure.ato != "—" && departure.ato != departure.eto,
                    "the departure's ATO is the take-off (\(departure.ato); timeline take-off \(takeoff ?? "?")), its ETO the planned departure (\(departure.eto))")
        pilot.check(step, eetPlanned != nil && eetFlown != nil && abs(eetPlanned! - eetFlown!) <= 1,
                    "the DEST ETO counts from the take-off: \(departure.ato) + \(eetFlown.map(String.init) ?? "?") min = \(destination.eto); planned \(departure.eto) + \(eetPlanned.map(String.init) ?? "?") min = \(plannedETA) (in flight \(inFlight ?? "?")); rows \(rows)")
    }
}
