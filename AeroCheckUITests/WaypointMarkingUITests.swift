import XCTest

/// The 6.0.1 page's waypoints marked from GPS (ato-*), their UNDO (undo-*) and the reporting points
/// (rp-9), flown as a ground replay: LSGN → N (LSGN) → E (LSGC) → SAIGNELEGIER → ST-URSANNE → LSZQ,
/// armed as a pilot arms a route, started with plain START FLIGHT.
final class WaypointMarkingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testRouteWithReportingPoints() {
        let pilot = CockpitPilot(self, scenario: "route-vrps", page: "601")
        defer { pilot.attachResults(testName: name) }
        let s = pilot.scenario
        pilot.launch()
        guard pilot.startFlight() else { return XCTFail("START FLIGHT did not bring the Cockpit up") }
        pilot.workChecks(until: "afterEngineStart")
        pilot.noteRelease(atTrack: 0)
        pilot.workChecks(until: "beforeDeparture")

        // ato-1: parked on the departure a few minutes (the ground checks), then MAP and the legs: the
        // departure has no ATO, the first VRP is still the target.
        pilot.openLegs()
        let departure = pilot.leg(0)
        let next = pilot.element("strip.next")
        pilot.check("ato-1", departure != nil && departure?.hasATO == false, "departure row: \(departure.map { "\($0)" } ?? "none")")
        pilot.check("ato-1", (next.value as? String) == "N" || pilot.leg(1)?.state == "next",
                    "the target: NEXT cell \((next.value as? String) ?? "-"), row 2 \(pilot.leg(1).map { "\($0)" } ?? "none")")
        pilot.shot("ato-1", "parked")

        // ato-2: through to LINE UP, the route flown at 100 kt, the CHECKLIST pane kept (the leg timer
        // started on the map once airborne).
        pilot.showPane("checklist")
        pilot.readyForLineUp()
        if pilot.memoryDone.waitForExistence(timeout: 3) { pilot.memoryDone.tap() }
        pilot.waitForTrack(s.mark("liftoff") + 20)
        pilot.showPane("map")
        pilot.tap("map.startLeg", timeout: 4)
        pilot.showPane("checklist")
        pilot.check("ato-2", pilot.paneShown == "checklist", "airborne on the \(pilot.paneShown ?? "?") pane")
        pilot.shot("ato-2", "checklist-pane")

        // undo-1: past N on the CHECKLIST pane: the toast, outlined UNDO at the foot of the list, nothing
        // covered, gone after 6 s.
        let n = pilot.waitUntil(timeout: pilot.wallUntil(track: s.mark("wp1") + 30, margin: 15)) {
            (pilot.toastMessage ?? "").contains("N marked automatically at")
        }
        pilot.shot("undo-1", "toast-checklist")
        pilot.check("undo-1", n, "toast: \(pilot.toastMessage ?? "none") (N passed at track \(Int(s.mark("wp1"))) s)")
        let thumb = [pilot.element("cockpit.memoryDone"), pilot.element("cockpit.check"), pilot.element("cockpit.next")].first { $0.exists }
        if let thumb, pilot.undo.exists {
            pilot.check("undo-1", pilot.undo.frame.maxY <= thumb.frame.minY + 1,
                        "the toast over the list, not over the thumb bar (UNDO bottom \(Int(pilot.undo.frame.maxY)), thumb bar top \(Int(thumb.frame.minY)))")
        }
        pilot.check("undo-1", pilot.waitUntil(timeout: 9) { !pilot.undo.exists }, "gone after 6 s")
        pilot.observed("undo-1", "outlined UNDO, nothing moves: see the screenshot")

        // ato-3: about 15 s after N, MAP: N has its ATO, E is NEXT, the LEG timer counts from N.
        pilot.openLegs()
        let rowN = pilot.leg(1), rowE = pilot.leg(2)
        let mark = pilot.element("map.mark")
        pilot.shot("ato-3", "legs")
        pilot.check("ato-3", rowN?.state == "passed" && rowN?.hasATO == true, "N: \(rowN.map { "\($0)" } ?? "none")")
        pilot.check("ato-3", rowE?.state == "next", "E: \(rowE.map { "\($0)" } ?? "none")")
        let leg = mark.exists ? CockpitPilot.legSeconds(in: mark.label) : nil
        let sinceN = pilot.trackNow - s.mark("wp1")
        pilot.check("ato-3", leg.map { abs(Double($0) - sinceN) < 45 } ?? false,
                    "LEG from N: \(mark.exists ? mark.label : "no MARK") (N passed \(Int(sinceN)) s ago)")

        // rp-9: E (LSGC) next: the Cockpit's NEXT cell reads "E", the map card "E (LSGC)".
        pilot.check("rp-9", (pilot.element("strip.next").value as? String) == "E",
                    "NEXT cell: \((pilot.element("strip.next").value as? String) ?? "-")")
        pilot.check("rp-9", !pilot.texts(containing: "E (LSGC)").isEmpty, "map card: \(pilot.texts(containing: "(LSGC)"))")
        pilot.shot("rp-9", "next-e")
        pilot.observed("rp-9", "the phone line and nothing shrinking or moving: an iPad run, see the screenshot")

        // undo-2: past E on the MAP pane: the toast above the frequencies; then a manual MARK, its UNDO.
        let e = pilot.waitUntil(timeout: pilot.wallUntil(track: s.mark("wp2") + 30, margin: 15)) {
            (pilot.toastMessage ?? "").contains("E marked automatically at")
        }
        pilot.shot("undo-2", "toast-map")
        pilot.check("undo-2", e, "toast: \(pilot.toastMessage ?? "none")")
        _ = pilot.waitUntil(timeout: 9) { !pilot.undo.exists }
        let markSaigne = pilot.element("map.mark")
        pilot.check("undo-2", markSaigne.exists && markSaigne.label.contains("MARK SAIGNELEGIER"),
                    "MARK: \(markSaigne.exists ? markSaigne.label : "missing")")
        if markSaigne.exists { markSaigne.tap() }
        pilot.check("undo-2", pilot.undo.waitForExistence(timeout: 3) && (pilot.toastMessage ?? "").contains("SAIGNELEGIER passed at"),
                    "MARK's toast: \(pilot.toastMessage ?? "none")")
        pilot.shot("undo-2", "mark-undo")
        pilot.observed("undo-2", "MARK's UNDO filled, the same size (20 pt, 78 pt): see the screenshots")
        if pilot.undo.exists { pilot.undo.tap() }
        pilot.check("undo-2", pilot.waitUntil(timeout: 4) { pilot.leg(3)?.state == "next" && pilot.leg(3)?.hasATO == false },
                    "MARK taken back: SAIGNELEGIER \(pilot.leg(3).map { "\($0)" } ?? "?")")

        // undo-3: SAIGNELEGIER marked on its own: UNDO within 6 s: NEXT again, no ATO, the leg timer from E.
        let saigne = pilot.waitUntil(timeout: pilot.wallUntil(track: s.mark("wp3") + 30, margin: 15)) {
            (pilot.toastMessage ?? "").contains("SAIGNELEGIER marked automatically at")
        }
        pilot.check("undo-3", saigne, "toast: \(pilot.toastMessage ?? "none")")
        if pilot.undo.exists { pilot.undo.tap() }
        pilot.check("undo-3", pilot.waitUntil(timeout: 4) { pilot.leg(3)?.state == "next" && pilot.leg(3)?.hasATO == false },
                    "NEXT again, no ATO: \(pilot.leg(3).map { "\($0)" } ?? "?")")
        let legAfter = CockpitPilot.legSeconds(in: pilot.element("map.mark").label)
        let sinceE = pilot.trackNow - s.mark("wp2")
        pilot.check("undo-3", legAfter.map { abs(Double($0) - sinceE) < 60 } ?? false,
                    "the leg timer from E: \(pilot.element("map.mark").label) (E passed \(Int(sinceE)) s ago)")
        pilot.shot("undo-3", "taken-back")

        // undo-5: killed and relaunched: "Flight Restored", the taken-back waypoint still not marked, and
        // the replay goes on where it was. Killed a few seconds after the UNDO, not within the second:
        // the plan is written to the defaults as a pilot's would be.
        Thread.sleep(forTimeInterval: 3)
        pilot.terminate()
        pilot.launch(resume: true)
        let restored = pilot.element("cockpit.menu").waitForExistence(timeout: 30)
        pilot.shot("undo-5", "restored")
        let notice = pilot.app.alerts.firstMatch
        let noticeText = notice.exists ? notice.label : (pilot.texts(containing: "Restored").first ?? "none")
        if notice.exists { notice.buttons.firstMatch.tap() }
        pilot.check("undo-5", restored, "the flight back in the Cockpit after the relaunch (notice: \(noticeText))")
        pilot.openLegs()
        pilot.check("undo-5", pilot.leg(3)?.hasATO == false, "SAIGNELEGIER still not marked: \(pilot.leg(3).map { "\($0)" } ?? "?")")
        pilot.shot("undo-5", "still-taken-back")

        // undo-4: a minute on: not marked again on its own; MARK by hand; the next one marks and moves on.
        pilot.waitForTrack(pilot.trackNow + 60)
        pilot.check("undo-4", pilot.leg(3)?.hasATO == false, "a minute on, not re-marked: \(pilot.leg(3).map { "\($0)" } ?? "?")")
        pilot.tap("map.mark")
        pilot.check("undo-4", pilot.waitUntil(timeout: 4) { pilot.leg(3)?.hasATO == true }, "MARK works: \(pilot.leg(3).map { "\($0)" } ?? "?")")
        let urs = pilot.waitUntil(timeout: pilot.wallUntil(track: s.mark("wp4") + 30, margin: 15)) {
            pilot.leg(4)?.state == "passed" && pilot.leg(4)?.hasATO == true
        }
        pilot.check("undo-4", urs, "ST-URSANNE marked and moved on: \(pilot.leg(4).map { "\($0)" } ?? "?"), \(pilot.toastMessage ?? "no toast")")
        pilot.shot("undo-4", "next-marked")

        // The landing at LSZQ, END FLIGHT: ato-5 (the destination's landing time) and undo-6 (the Flight Log).
        if pilot.waitFor("landedCard.yes", timeout: pilot.wallUntil(track: s.mark("stopped") + 20, margin: 30)) != nil {
            pilot.tap("landedCard.yes")
        }
        pilot.endFlight()
        if pilot.openNewestFlightInLogbook() {
            for _ in 0..<4 { pilot.app.swipeUp() }
            pilot.shot("undo-6", "flight-log")
            pilot.shot("ato-5", "flight-log")
        }
        pilot.observed("ato-5", "the destination's landing time: see the Flight Log screenshot")
        pilot.observed("undo-6", "taken back and never MARKed \"-\", MARKed later its MARK time: see the Flight Log screenshot")
        // ato-5: Settings › Flights has no "Waypoint Proximity" slider.
        let settings = pilot.app.buttons["Settings"].firstMatch
        if settings.waitForExistence(timeout: 5) {
            settings.tap()
            let flights = pilot.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Flights'")).firstMatch
            if flights.waitForExistence(timeout: 5) { flights.tap() }
            pilot.shot("ato-5", "settings-flights")
            pilot.check("ato-5", !pilot.app.staticTexts["Waypoint Proximity"].exists && pilot.texts(containing: "Proximity").isEmpty,
                        "Settings › Flights: no Waypoint Proximity")
        }
    }
}

extension WaypointMarkingUITests {
    /// ato-6: the route armed, CIRCUITS flown over it instead: nothing marked, the route still armed on
    /// Today after END FLIGHT, with no times.
    func testCircuitsLeaveTheArmedRouteAlone() {
        let pilot = CockpitPilot(self, scenario: "route-vrps", page: "601")
        defer { pilot.attachResults(testName: name) }
        let s = pilot.scenario
        pilot.launch()
        guard pilot.departToClimb(circuits: true) else { return XCTFail("could not get to the climb check") }
        // Past N and E: in circuits nothing is marked (the legs list is the armed route's).
        pilot.waitForTrack(s.mark("wp2") + 40)
        pilot.check("ato-6", pilot.toastMessage == nil || !(pilot.toastMessage ?? "").contains("marked automatically"),
                    "no automatic mark: \(pilot.toastMessage ?? "no toast")")
        pilot.shot("ato-6", "circuits-past-e")
        pilot.endFlight()
        let route = pilot.app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'LSGN → LSZQ'")).firstMatch
        pilot.check("ato-6", route.waitForExistence(timeout: 8), "Today still shows the route armed: \(route.exists ? route.label : "no LSGN → LSZQ")")
        pilot.shot("ato-6", "today-route-armed")
        pilot.observed("ato-6", "no times on the route, no nav log for the circuits, ABANDON FLIGHT: not flown here")
    }
}

extension CockpitPilot {
    /// "MARK E LEG 2:05 / 17:32" → 125 (the leg so far).
    static func legSeconds(in text: String) -> Int? {
        guard let range = text.range(of: #"LEG (\d+):(\d\d)"#, options: .regularExpression) else { return nil }
        let parts = text[range].dropFirst(4).split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
    }
}
