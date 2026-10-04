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
        // departure has no ATO, and nothing past it is marked or skipped. The target on the ramp is the
        // departure itself, which takes the take-off time (FlightPlanManager.catchUpWaypointPassages);
        // N becomes the target at the take-off.
        pilot.openLegs()
        let departure = pilot.leg(0), first = pilot.leg(1)
        let nextCell = pilot.snap("strip.next")?.value as? String
        pilot.check("ato-1", departure != nil && departure?.hasATO == false, "departure row: \(departure.map { "\($0)" } ?? "none")")
        pilot.check("ato-1", first?.state == "ahead" && first?.hasATO == false || first?.state == "next",
                    "N not marked, not skipped: row 2 \(first.map { "\($0)" } ?? "none")")
        pilot.observed("ato-1", "the target on the ramp: NEXT cell \(nextCell ?? "-"), departure row \(departure?.state ?? "?") (the page says the first VRP; the code makes it the departure until the take-off)")
        pilot.shot("ato-1", "parked")

        // ato-2: through to LINE UP, the route flown at 100 kt, the CHECKLIST pane kept (the leg timer
        // started on the map once airborne).
        pilot.showPane("checklist")
        pilot.readyForLineUp()
        if pilot.memoryDone.waitForExistence(timeout: 3) { pilot.tapNow(pilot.memoryDone) }
        // undo-7 (b): no toast for the departure at the line-up (watched from READY FOR LINE UP to N).
        var toasts: Set<String> = []
        func noteToast() { if let t = pilot.toastMessage { toasts.insert(t) } }
        _ = pilot.waitUntil(timeout: pilot.wallUntil(track: s.mark("liftoff") + 20, margin: 0)) { noteToast(); return false }
        pilot.showPane("map")
        pilot.tap("map.startLeg", timeout: 4)
        pilot.showPane("checklist")
        pilot.check("ato-2", pilot.paneShown == "checklist", "airborne on the \(pilot.paneShown ?? "?") pane")
        pilot.shot("ato-2", "checklist-pane")

        // undo-1: past N on the CHECKLIST pane: the toast, outlined UNDO at the foot of the list, nothing
        // covered, gone after 6 s.
        let n = pilot.waitUntil(timeout: pilot.wallUntil(track: s.mark("wp1") + 30, margin: 15)) {
            noteToast()
            return (pilot.toastMessage ?? "").contains("N marked automatically at")
        }
        pilot.shot("undo-1", "toast-checklist")
        pilot.check("undo-1", n, "toast: \(pilot.toastMessage ?? "none") (N passed at track \(Int(s.mark("wp1"))) s)")
        let thumb = ["cockpit.memoryDone", "cockpit.check", "cockpit.next"].lazy.compactMap { pilot.snap($0) }.first
        if let thumb, let undo = pilot.snap(pilot.undo) {
            pilot.check("undo-1", undo.frame.maxY <= thumb.frame.minY + 1,
                        "the toast over the list, not over the thumb bar (UNDO bottom \(Int(undo.frame.maxY)), thumb bar top \(Int(thumb.frame.minY)))")
        }
        pilot.check("undo-1", pilot.waitUntil(timeout: 9) { pilot.snap(pilot.undo) == nil }, "gone after 6 s")
        pilot.observed("undo-1", "outlined UNDO, nothing moves: see the screenshot")
        let departureToasts = toasts.filter { $0.contains("LSGN") }
        pilot.check("undo-7", departureToasts.isEmpty,
                    "no toast for the departure from READY FOR LINE UP to N: \(toasts.isEmpty ? "no toast" : toasts.sorted().joined(separator: " | "))")

        // ato-3: about 15 s after N, MAP: N has its ATO, E is NEXT, the LEG timer counts from N.
        pilot.openLegs()
        let rowN = pilot.leg(1), rowE = pilot.leg(2)
        let markLabel = pilot.label("map.mark")
        pilot.shot("ato-3", "legs")
        pilot.check("ato-3", rowN?.state == "passed" && rowN?.hasATO == true, "N: \(rowN.map { "\($0)" } ?? "none")")
        pilot.check("ato-3", rowE?.state == "next", "E: \(rowE.map { "\($0)" } ?? "none")")
        let leg = markLabel.flatMap(CockpitPilot.legSeconds(in:))
        let sinceN = pilot.trackNow - s.mark("wp1")
        pilot.check("ato-3", leg.map { abs(Double($0) - sinceN) < 45 } ?? false,
                    "LEG from N: \(markLabel ?? "no MARK") (N passed \(Int(sinceN)) s ago)")

        // rp-9: E (LSGC) next: the NEXT cell's value is "E"; on the iPad it shows "E (LSGC)" (6.2: the
        // cell, where the map's card showed it until then).
        let phone = pilot.isPhone
        let nextE = pilot.snap("strip.next")?.value as? String
        pilot.check("rp-9", nextE == "E", "NEXT cell: \(nextE ?? "-")")
        if phone {
            pilot.observed("rp-9", "the phone line: see the screenshot (texts with E: \(pilot.texts(containing: "E").filter { $0.count < 24 }.prefix(8)))")
        } else {
            pilot.check("rp-9", !pilot.texts(containing: "E (LSGC)").isEmpty, "NEXT cell: \(pilot.texts(containing: "(LSGC)"))")
        }
        pilot.shot("rp-9", "next-e")
        pilot.observed("rp-9", "nothing shrinks or moves: see the screenshot")

        // undo-2: past E on the MAP pane: the toast above the frequencies; then a manual MARK, its UNDO.
        let e = pilot.waitUntil(timeout: pilot.wallUntil(track: s.mark("wp2") + 30, margin: 15)) {
            (pilot.toastMessage ?? "").contains("E marked automatically at")
        }
        pilot.shot("undo-2", "toast-map")
        pilot.check("undo-2", e, "toast: \(pilot.toastMessage ?? "none")")
        _ = pilot.waitUntil(timeout: 9) { pilot.snap(pilot.undo) == nil }
        let markSaigne = pilot.label("map.mark")
        pilot.check("undo-2", markSaigne?.contains("MARK SAIGNELEGIER") ?? false, "MARK: \(markSaigne ?? "missing")")
        pilot.tap("map.mark", timeout: 2)
        pilot.check("undo-2", pilot.undo.waitForExistence(timeout: 3) && (pilot.toastMessage ?? "").contains("SAIGNELEGIER passed at"),
                    "MARK's toast: \(pilot.toastMessage ?? "none")")
        pilot.shot("undo-2", "mark-undo")
        pilot.observed("undo-2", "MARK's UNDO filled, the same size (20 pt, 78 pt): see the screenshots")
        pilot.tapNow(pilot.undo)
        pilot.check("undo-2", pilot.waitUntil(timeout: 4) { pilot.leg(3)?.state == "next" && pilot.leg(3)?.hasATO == false },
                    "MARK taken back: SAIGNELEGIER \(pilot.leg(3).map { "\($0)" } ?? "?")")

        // undo-3: SAIGNELEGIER marked on its own: UNDO within 6 s: NEXT again, no ATO, the leg timer from E.
        let saigne = pilot.waitUntil(timeout: pilot.wallUntil(track: s.mark("wp3") + 30, margin: 15)) {
            (pilot.toastMessage ?? "").contains("SAIGNELEGIER marked automatically at")
        }
        pilot.check("undo-3", saigne, "toast: \(pilot.toastMessage ?? "none")")
        pilot.tapNow(pilot.undo)
        pilot.check("undo-3", pilot.waitUntil(timeout: 4) { pilot.leg(3)?.state == "next" && pilot.leg(3)?.hasATO == false },
                    "NEXT again, no ATO: \(pilot.leg(3).map { "\($0)" } ?? "?")")
        let markAfter = pilot.label("map.mark")
        let legAfter = markAfter.flatMap(CockpitPilot.legSeconds(in:))
        let sinceE = pilot.trackNow - s.mark("wp2")
        pilot.check("undo-3", legAfter.map { abs(Double($0) - sinceE) < 60 } ?? false,
                    "the leg timer from E: \(markAfter ?? "no MARK") (E passed \(Int(sinceE)) s ago)")
        pilot.shot("undo-3", "taken-back")

        // undo-4: a minute on: not marked again on its own; MARK by hand; the next one marks and moves on.
        // (Straight after the UNDO: with a relaunch between them the replay flew past ST-URSANNE before
        // the MARK, the app being gone some twenty seconds, three minutes of flight at 10x.)
        // That minute on MAP: SAIGNELEGIER taken back is still the target while the aircraft flies on past
        // it, on the route all the same. OFF ROUTE never shows (6.2, PR 4), the minute where a rule on the
        // leg flown alone would have said "OFF ROUTE 1.7 NM".
        let offRoute = pilot.watchOffRoute(untilTrack: pilot.trackNow + 60)
        pilot.shot("offroute-1", "route-vrps-past-taken-back")
        pilot.check("offroute-1", offRoute.isEmpty,
                    "route-vrps, the minute past SAIGNELEGIER taken back: \(offRoute.isEmpty ? "no OFF ROUTE" : offRoute.joined(separator: " | "))")
        pilot.openLegs()
        pilot.check("undo-4", pilot.leg(3)?.state == "next" && pilot.leg(3)?.hasATO == false,
                    "a minute on, not re-marked: \(pilot.leg(3).map { "\($0)" } ?? "?") (track \(Int(pilot.trackNow)) s, ST-URSANNE at \(Int(s.mark("wp4"))) s)")
        pilot.tap("map.mark")
        let markedBy = pilot.waitUntil(timeout: 3) { (pilot.toastMessage ?? "").contains("SAIGNELEGIER passed at") } ? pilot.toastMessage : nil
        pilot.check("undo-4", pilot.waitUntil(timeout: 4) { pilot.leg(3)?.hasATO == true }, "MARK works: \(pilot.leg(3).map { "\($0)" } ?? "?"), \(markedBy ?? "no toast")")
        let urs = pilot.waitUntil(timeout: pilot.wallUntil(track: s.mark("wp4") + 30, margin: 15)) {
            pilot.leg(4)?.state == "passed" && pilot.leg(4)?.hasATO == true
        }
        pilot.check("undo-4", urs, "ST-URSANNE marked and moved on: \(pilot.leg(4).map { "\($0)" } ?? "?"), \(pilot.toastMessage ?? "no toast")")
        pilot.shot("undo-4", "next-marked")

        // undo-7 (a): RESUME LEG on ST-URSANNE, which the flight marked: it stays the target, through
        // two catch-ups (every 15 s of flight) and more. Since 6.2 the row on ROUTE opens MAP on that leg,
        // whose RESUME LEG asks the same question.
        _ = pilot.waitUntil(timeout: 9) { pilot.snap(pilot.undo) == nil }
        pilot.openLegs()
        // The row's own tap, which scrolls it into view: at its point it may sit under the act band
        // (the phone), and a tap there would land on the slot.
        if let row = pilot.waitFor("legRow.4.passed.ato", timeout: 3) { row.tap() }
        if let onTheMap = pilot.waitFor("map.resumeLeg", timeout: 3) { onTheMap.tap() }
        // The dialog's, not the map's own RESUME LEG under it.
        let resume = pilot.app.buttons
            .matching(NSPredicate(format: "label == 'Resume leg' AND identifier != 'map.resumeLeg'")).firstMatch
        let asked = resume.waitForExistence(timeout: 3)
        pilot.shot("undo-7", "resume-leg-asked")
        if asked { pilot.tapNow(resume) }
        pilot.openLegs()
        pilot.check("undo-7", asked && pilot.waitUntil(timeout: 4) { pilot.leg(4)?.state == "next" && pilot.leg(4)?.hasATO == false },
                    "RESUME LEG: ST-URSANNE \(pilot.leg(4).map { "\($0)" } ?? "?")")
        pilot.waitForTrack(pilot.trackNow + 45)
        pilot.check("undo-7", pilot.leg(4)?.state == "next" && pilot.leg(4)?.hasATO == false,
                    "45 s of flight later, still the target: ST-URSANNE \(pilot.leg(4).map { "\($0)" } ?? "?"), toast \(pilot.toastMessage ?? "none")")
        pilot.shot("undo-7", "still-target")

        // undo-5: killed and relaunched after that take-back (RESUME LEG keeps it in the same
        // takenBackWaypointIds as UNDO; testDivertThenResumeRoute relaunches after an UNDO): "Flight
        // Restored", still not marked, and the replay goes on where it was. Killed a few seconds after,
        // not within the second: the plan is written as a pilot's would be.
        Thread.sleep(forTimeInterval: 2)
        Self.relaunchAndCheckTakenBack(pilot, index: 4, name: "ST-URSANNE", how: "RESUME LEG")

        // The landing at LSZQ, END FLIGHT: ato-5 (the destination's landing time) and undo-6 (the Flight Log).
        if pilot.waitFor("landedCard.yes", timeout: pilot.wallUntil(track: s.mark("stopped") + 20, margin: 30)) != nil {
            pilot.tap("landedCard.yes")
        }
        pilot.endFlight()
        if pilot.openNewestFlightInLogbook() {
            let rows = pilot.planVsActual()
            let landing = pilot.timelineTime("Landing")
            pilot.scrollTo("PLAN vs ACTUAL")
            pilot.shot("undo-6", "flight-log")
            pilot.cite("ato-5", "601-undo-6-flight-log")
            func row(_ name: String) -> CockpitPilot.PlanRow? { rows.first { $0.name.hasPrefix(name) } }
            pilot.check("ato-5", row("LSZQ").map { $0.ato != "—" && $0.ato == landing } ?? false,
                        "LSZQ's ATO is the landing (\(landing ?? "no landing time")): \(rows)")
            let markTime = markedBy.flatMap { $0.components(separatedBy: " at ").last }
            pilot.check("undo-6", row("SAIGNELEGIER").map { $0.ato != "—" && (markTime == nil || $0.ato == markTime) } ?? false,
                        "MARKed later: SAIGNELEGIER \(row("SAIGNELEGIER")?.ato ?? "no row") (MARK \(markTime ?? "?"))")
            pilot.check("undo-6", row("ST-URSANNE")?.ato == "—",
                        "taken back (RESUME LEG) and never MARKed: ST-URSANNE \(row("ST-URSANNE")?.ato ?? "no row")")
        } else {
            pilot.check("undo-6", false, "no flight in the Logbook")
        }
        // ato-5: Settings › Flights has no "Waypoint Proximity" slider.
        let settings = pilot.app.buttons["Settings"].firstMatch
        if settings.waitForExistence(timeout: 5) {
            settings.tap()
            let flights = pilot.app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Flights'")).firstMatch
            if flights.waitForExistence(timeout: 5) { flights.tap() }
            pilot.shot("ato-5", "settings-flights")
            pilot.check("ato-5", pilot.texts(containing: "Proximity").isEmpty, "Settings › Flights: no Waypoint Proximity")
        }
    }
}

extension WaypointMarkingUITests {
    /// ato-6: the route armed, CIRCUITS flown over it instead: nothing marked, the route still armed on
    /// Today after END FLIGHT, with no times, and the circuits with no nav log; then the same with
    /// ABANDON FLIGHT; and a flight started with the route and abandoned leaves no route armed.
    func testCircuitsLeaveTheArmedRouteAlone() {
        let pilot = CockpitPilot(self, scenario: "route-vrps", page: "601")
        defer { pilot.attachResults(testName: name) }
        let s = pilot.scenario
        pilot.launch()
        guard pilot.departToClimb(circuits: true) else { return XCTFail("could not get to the climb check") }
        // Past N and E: in circuits nothing is marked (the legs list is the armed route's).
        var toasts: Set<String> = []
        _ = pilot.waitUntil(timeout: pilot.wallUntil(track: s.mark("wp2") + 40, margin: 0)) {
            if let t = pilot.toastMessage { toasts.insert(t) }
            return false
        }
        pilot.check("ato-6", !toasts.contains { $0.contains("marked automatically") },
                    "no automatic mark past N and E: \(toasts.isEmpty ? "no toast" : toasts.sorted().joined(separator: " | "))")
        pilot.shot("ato-6", "circuits-past-e")
        pilot.endFlight()
        let armed = pilot.waitUntil(timeout: 8) { pilot.armedRouteOnToday != nil }
        pilot.check("ato-6", armed, "after END FLIGHT, Today still shows the route on the map: \(pilot.armedRouteOnToday ?? "none")")
        pilot.shot("ato-6", "today-route-armed")
        // The circuits in the Logbook: no PLAN vs ACTUAL (no nav log attached).
        if pilot.openNewestFlightInLogbook() {
            _ = pilot.waitUntil(timeout: 4) { !pilot.texts(containing: "TIMELINE").isEmpty }
            let rows = pilot.planVsActual()
            pilot.check("ato-6", rows.isEmpty && pilot.texts(containing: "PLAN vs ACTUAL").isEmpty,
                        "the circuits' page has no PLAN vs ACTUAL: \(rows)")
            pilot.shot("ato-6", "circuits-flight-page")
        }
        // Today again, then CIRCUITS once more, ABANDON FLIGHT: the route stays armed.
        let today = pilot.app.buttons["Today"].firstMatch
        if today.waitForExistence(timeout: 5) { today.tap() }
        if pilot.startFlight("home.circuits") {
            pilot.check("ato-6", pilot.abandonFlight(), "circuits abandoned")
            pilot.check("ato-6", pilot.waitUntil(timeout: 5) { pilot.armedRouteOnToday != nil },
                        "after ABANDON FLIGHT (circuits), the route still on the map: \(pilot.armedRouteOnToday ?? "none")")
            pilot.shot("ato-6", "abandoned-circuits")
        } else {
            pilot.check("ato-6", false, "CIRCUITS did not start a second time")
        }
        // And a flight started with the route, abandoned: no route left armed.
        if pilot.startFlight() {
            pilot.check("ato-6", pilot.abandonFlight(), "the route's flight abandoned")
            pilot.check("ato-6", pilot.waitUntil(timeout: 5) { pilot.armedRouteOnToday == nil },
                        "a flight started with the route and abandoned leaves none on the map: \(pilot.armedRouteOnToday ?? "none")")
            pilot.shot("ato-6", "abandoned-with-route")
        } else {
            pilot.check("ato-6", false, "START FLIGHT did not start the route's flight")
        }
        pilot.observed("ato-6", "no times on the armed route: see the Today screenshots")
    }

    /// ato-4: DIVERT near the route after N, flown on past E, then RESUME ROUTE: no ATO while diverting,
    /// E's within 15 s of the resume.
    func testDivertThenResumeRoute() {
        let pilot = CockpitPilot(self, scenario: "route-vrps", page: "601")
        defer { pilot.attachResults(testName: name) }
        let s = pilot.scenario
        pilot.launch()
        guard pilot.departToClimb() else { return XCTFail("could not get to the climb check") }
        pilot.waitForTrack(s.mark("liftoff") + 20)
        pilot.showPane("map")
        pilot.tap("map.startLeg", timeout: 4)
        // N marked (the legs list open, where the rows are read), then at once the diversion, well before
        // E: to the first field the sheet lists that is not the destination.
        pilot.openLegs()
        _ = pilot.waitUntil(timeout: pilot.wallUntil(track: s.mark("wp1") + 30, margin: 15)) { pilot.leg(1)?.hasATO == true }
        pilot.check("ato-4", pilot.leg(1)?.hasATO == true && pilot.leg(2)?.hasATO == false,
                    "N marked before the diversion, E not yet (track \(Int(pilot.trackNow)) s, E at \(Int(s.mark("wp2"))) s): N \(pilot.leg(1).map { "\($0)" } ?? "?"), E \(pilot.leg(2).map { "\($0)" } ?? "?")")
        let divert = pilot.app.buttons["Divert"].firstMatch
        guard divert.waitForExistence(timeout: 4), pilot.tapNow(divert) else {
            return pilot.check("ato-4", false, "no Divert button on the map")
        }
        var field: String?
        for ident in ["LSZJ", "LSGC", "FR-0332", "LSGN"] {
            let row = pilot.app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", ident)).firstMatch
            if row.waitForExistence(timeout: field == nil ? 5 : 1) {
                row.tap()
                let go = pilot.app.buttons["DIVERT TO \(ident)"].firstMatch
                if go.waitForExistence(timeout: 3) { go.tap(); field = ident; break }
            }
        }
        let divertedAt = pilot.trackNow
        pilot.shot("ato-4", "diverting")
        guard let field else {
            pilot.dumpTree("divert-sheet")
            return pilot.check("ato-4", false, "no field to divert to in the sheet")
        }
        pilot.check("ato-4", divertedAt < s.mark("wp2") - 15 && pilot.leg(2)?.hasATO == false,
                    "diverting to \(field) before E: track \(Int(divertedAt)) s, E at \(Int(s.mark("wp2"))) s, E \(pilot.leg(2).map { "\($0)" } ?? "?")")
        // On past E while diverting: no ATO.
        pilot.waitForTrack(s.mark("wp2") + 40)
        pilot.openLegs()
        let whileDiverting = pilot.leg(2)
        pilot.check("ato-4", whileDiverting?.hasATO == false,
                    "diverting to \(field), 40 s past E: E \(whileDiverting.map { "\($0)" } ?? "?")")
        pilot.shot("ato-4", "past-e-diverting")
        // RESUME ROUTE: E's ATO within 15 s (of flight) of it.
        let resume = pilot.app.buttons["Resume route"].firstMatch
        if !resume.waitForExistence(timeout: 3), pilot.tapNow(divert) { _ = resume.waitForExistence(timeout: 5) }
        let resumedAt = pilot.trackNow
        let resumed = pilot.tapNow(resume)
        var markedAt: Double?
        _ = pilot.waitUntil(timeout: 15 / pilot.rate + 10) {
            if pilot.leg(2)?.hasATO == true { markedAt = pilot.trackNow; return true }
            return false
        }
        pilot.check("ato-4", resumed && markedAt != nil,
                    "RESUME ROUTE: E's ATO \(markedAt.map { "\(Int($0 - resumedAt)) s of flight after it" } ?? "never") (the catch-up runs every 15 s; a query is seconds of flight at 10x)")
        pilot.shot("ato-4", "resumed")

        // undo-5 with an UNDO: SAIGNELEGIER marked on its own, taken back within the six seconds, the app
        // killed and relaunched: after "Flight Restored" still not marked. Nothing after it needs the
        // replay's pace, so the time the app is gone costs nothing here.
        let saigne = pilot.waitUntil(timeout: pilot.wallUntil(track: s.mark("wp3") + 30, margin: 15)) {
            (pilot.toastMessage ?? "").contains("SAIGNELEGIER marked automatically at")
        }
        pilot.tapNow(pilot.undo)
        pilot.check("undo-5", saigne && pilot.waitUntil(timeout: 4) { pilot.leg(3)?.state == "next" && pilot.leg(3)?.hasATO == false },
                    "SAIGNELEGIER marked on its own and taken back: \(pilot.leg(3).map { "\($0)" } ?? "?")")
        Thread.sleep(forTimeInterval: 2)
        // Not "still the target": the relaunch may outlast the leg, and ST-URSANNE passed moves the target on.
        WaypointMarkingUITests.relaunchAndCheckTakenBack(pilot, index: 3, name: "SAIGNELEGIER", how: "UNDO",
                                                         stillTarget: false)

        // A flight started with the route and abandoned leaves no route armed (ato-6's last line).
        pilot.check("ato-6", pilot.abandonFlight(), "the route's flight abandoned in the air")
        pilot.check("ato-6", pilot.waitUntil(timeout: 5) { pilot.armedRouteOnToday == nil },
                    "abandoned: no route on the map on Today (\(pilot.armedRouteOnToday ?? "none"))")
        pilot.shot("ato-6", "abandoned-diverted")
    }
}

extension WaypointMarkingUITests {
    /// rp-9 on the phone (`scripts/ground-replay.sh --iphone --only WaypointMarkingUITests/testReportingPointOnThePhone`):
    /// with E (LSGC) next, the phone's next line reads "E", without its aerodrome; with the legs open too.
    /// The line is in the read band, over every page, since 6.2 (it was over the chart). (The iPad's NEXT
    /// cell is testRouteWithReportingPoints'.)
    func testReportingPointOnThePhone() {
        let pilot = CockpitPilot(self, scenario: "route-vrps", page: "601")
        defer { pilot.attachResults(testName: name) }
        let s = pilot.scenario
        pilot.launch()
        guard pilot.departToClimb() else { return XCTFail("could not get to the climb check") }
        pilot.showPane("map")
        // The read band's next line, "NEXT E  172° · 2.4 NM / 1 min · 11:58", the button that opens ROUTE.
        // VoiceOver reads it "Next, E, bearing 172 degrees, …".
        func line() -> String? { pilot.label("read.nextLine") }
        func readsE(_ label: String?) -> Bool {
            (label ?? "").components(separatedBy: ", ").contains("E")
        }
        let next = pilot.waitUntil(timeout: pilot.wallUntil(track: s.mark("wp1") + 40, margin: 10)) {
            readsE(line())
        }
        let seen = line()
        let cell = pilot.snap("strip.next")?.value as? String
        pilot.shot("rp-9", "phone-line")
        pilot.check("rp-9", next && !(seen ?? "").contains("LSGC"),
                    "with E next (track \(Int(pilot.trackNow)) s, N at \(Int(s.mark("wp1"))) s), the line reads \"\(seen ?? "nothing")\"; NEXT cell \(cell ?? "none on this layout")")
        pilot.openLegs()
        pilot.shot("rp-9", "phone-line-legs-open")
        pilot.observed("rp-9", "on the phone, nothing shrinks or moves, the legs open: see the two screenshots")
        pilot.endFlight()
    }

    /// undo-5: the app killed and relaunched mid-flight: the Cockpit back ("Flight Restored"), and the
    /// waypoint taken back (`how`) at `index` still without a time, still the target.
    static func relaunchAndCheckTakenBack(_ pilot: CockpitPilot, index: Int, name: String, how: String,
                                          stillTarget: Bool = true) {
        pilot.terminate()
        pilot.launch(resume: true)
        let restored = pilot.element("cockpit.menu").waitForExistence(timeout: 30)
        let notice = pilot.app.alerts.firstMatch
        _ = notice.waitForExistence(timeout: 3)
        pilot.shot("undo-5", "restored-\(name.lowercased())")
        let noticeText = pilot.snap(notice)?.label ?? pilot.texts(containing: "Restored").first ?? "none"
        pilot.tapNow(notice.buttons.firstMatch)
        pilot.check("undo-5", restored && noticeText.contains("Restored"),
                    "the flight back in the Cockpit after the relaunch (notice: \(noticeText))")
        pilot.openLegs()
        let row = pilot.leg(index)
        pilot.check("undo-5", row?.hasATO == false && (!stillTarget || row?.state == "next"),
                    "taken back by \(how), after the relaunch \(name) still not marked\(stillTarget ? ", still the target" : ""): \(row.map { "\($0)" } ?? "?") (track \(Int(pilot.trackNow)) s)")
        pilot.shot("undo-5", "still-taken-back-\(name.lowercased())")
    }
}

extension CockpitPilot {
    /// "MARK E LEG 2:05 / 17:32" (the phone: "MARK E · 2:05") → 125 (the leg so far).
    static func legSeconds(in text: String) -> Int? {
        guard let range = text.range(of: #"(LEG|·) (\d+):(\d\d)"#, options: .regularExpression) else { return nil }
        let parts = text[range].split(separator: " ").last?.split(separator: ":").compactMap { Int($0) } ?? []
        return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
    }

    /// An iPhone (the Cockpit's phone layout), not the kneeboard.
    var isPhone: Bool {
        (snap(app)?.frame.width ?? 1000) < 600
    }
}
