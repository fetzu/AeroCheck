import XCTest

/// The 6.1.0 "Checks in flight" page (flight-*, debrief-*), flown as ground replays: the pilot's taps
/// with XCUITest, the flight from a synthetic track (scripts/flightsim), the Memory test on.
final class ChecksInFlightUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    // MARK: - (1) Cross-country, every check on time

    /// LSZQ → INS → LSGC: flight 1-3, 5-9, 11, 12, 14, 16; debrief 1.
    func testCrossCountryEveryCheckOnTime() {
        let pilot = CockpitPilot(self, scenario: "xc-all-checks")
        defer { pilot.attachResults(testName: name) }
        let s = pilot.scenario
        pilot.launch()
        guard pilot.startFlight() else { return XCTFail("START FLIGHT did not bring the Cockpit up") }

        // On the ground up to ENGINE START: the replay waits on its first fix until then.
        pilot.workChecks(until: "afterEngineStart")
        pilot.noteRelease(atTrack: 0)

        // flight-1: the one tap after engine start, and its UNDO.
        let done = pilot.memoryDone
        let doneLabel = done.waitForExistence(timeout: 5) ? (pilot.snap(done)?.label ?? "") : ""
        pilot.check("flight-1", doneLabel.contains("DONE") && doneLabel.contains("NEXT: TAXI CHECK") && doneLabel.contains("from memory"),
                    "thumb bar reads \"\(doneLabel)\"")
        pilot.shot("flight-1", "thumb-bar")
        let barBefore = pilot.phaseBar()
        guard pilot.tapNow(done) else { return pilot.check("flight-1", false, "no ✓ DONE after engine start") }
        pilot.check("flight-1", pilot.waitUntil(timeout: 3) { pilot.currentPhase == "taxi" },
                    "one tap opens \(pilot.currentPhase ?? "?")")
        pilot.check("flight-1", pilot.undo.waitForExistence(timeout: 2), "the toast offers UNDO: \(pilot.toastMessage ?? "none")")
        pilot.shot("flight-1", "undo-toast")
        pilot.tapNow(pilot.undo)
        pilot.check("flight-1", pilot.waitUntil(timeout: 3) { pilot.currentPhase == "afterEngineStart" },
                    "UNDO goes back to \(pilot.currentPhase ?? "?")")
        let barAfter = pilot.phaseBar()
        pilot.check("flight-1", barAfter == barBefore, "the phase bar as it was: \(barAfter == barBefore ? "same" : "\(barBefore) → \(barAfter)")")
        pilot.tapNow(pilot.memoryDone)
        pilot.check("flight-1", pilot.waitUntil(timeout: 3) { pilot.currentPhase == "taxi" }, "open again: \(pilot.currentPhase ?? "?")")
        pilot.shot("flight-1", "taxi-again")
        if pilot.stopsAfter("flight-1") { return }

        // Taxi, run-up, before departure; READY FOR LINE UP lets the replay go from the holding point.
        pilot.workChecks(until: "beforeDeparture")
        let lineUp = pilot.readyForLineUp()

        // flight-2: at line-up, the same one tap, to CLIMB on the map. (Before it, since 6.2: the check
        // before departure's NEXT reads READY FOR LINE UP and leaves it completed.)
        pilot.check("flight-2", lineUp.next.contains("READY FOR LINE UP") && lineUp.beforeDeparture == "completed",
                    "the check before departure's NEXT: \"\(lineUp.next)\", then \(lineUp.beforeDeparture ?? "?")")
        pilot.check("flight-2", pilot.currentPhase == "lineUp" && pilot.memoryDone.exists,
                    "on \(pilot.currentPhase ?? "?"), ✓ DONE \(pilot.memoryDone.exists ? "shown" : "missing")")
        pilot.shot("flight-2", "line-up")
        pilot.tapNow(pilot.memoryDone)
        pilot.check("flight-2", pilot.waitUntil(timeout: 4) { pilot.currentPhase == "climb" && pilot.paneShown == "map" },
                    "after the tap: \(pilot.currentPhase ?? "?") on the \(pilot.paneShown ?? "?") pane")
        pilot.shot("flight-2", "climb-on-map")

        // flight-3: the slot turns amber "CLIMB CHECK" at about 500 ft, not on the take-off roll. The slot
        // is sampled from the line-up to 500 ft: (track s, tone, ft above the field).
        let elevation = Double(s.fieldElevations[s.departure].flatMap { $0 } ?? 0)
        var samples: [(t: Double, tone: String, aal: Int?)] = []
        let takeoffCue = s.cue("takeoff") ?? 300
        _ = pilot.waitUntil(timeout: pilot.wallUntil(track: takeoffCue, margin: 25)) {
            guard let slot = pilot.slot, slot.label.contains("CLIMB CHECK") else { return false }
            let aal = pilot.altitudeFeet.map { Int(Double($0) - elevation) }
            samples.append((pilot.trackNow, slot.tone, aal))
            return slot.tone == "due" && (aal ?? 0) > 300
        }
        pilot.shot("flight-3", "climb-check-due")
        let roll = (s.mark("takeoffRoll"), s.mark("liftoff") + 5)
        let onRoll = samples.filter { $0.t >= roll.0 && $0.t <= roll.1 }
        let timeline = samples.map { "\(Int($0.t))s \($0.tone) \($0.aal.map(String.init) ?? "?")ft" }.joined(separator: ", ")
        let firstDueAloft = samples.first { $0.tone == "due" && ($0.aal ?? 0) > 100 }
        pilot.check("flight-3", firstDueAloft.map { ($0.aal ?? 0) > 300 && ($0.aal ?? 0) < 800 } ?? false,
                    "amber at about 500 ft: first due aloft at \(firstDueAloft.map { "\($0.aal ?? 0) ft (track \(Int($0.t)) s)" } ?? "never") (referee cue \(Int(takeoffCue)) s)")
        pilot.check("flight-3", !onRoll.isEmpty && onRoll.allSatisfy { $0.tone != "due" },
                    "not amber on the take-off roll (track \(Int(roll.0))-\(Int(roll.1)) s): \(onRoll.isEmpty ? "no sample on the roll" : onRoll.map { "\(Int($0.t))s \($0.tone)" }.joined(separator: ", "))")
        // Nor on the runway before it, from the LINE UP check's tap (#276: dark at READY FOR LINE UP).
        let linedUp = samples.filter { $0.t < roll.0 }
        pilot.check("flight-3", !linedUp.isEmpty && linedUp.allSatisfy { $0.tone != "due" },
                    "not amber lined up, before the roll (track to \(Int(roll.0)) s): \(linedUp.isEmpty ? "no sample" : "\(linedUp.filter { $0.tone == "due" }.count) of \(linedUp.count) samples due")")
        pilot.observed("flight-3", "slot timeline: \(timeline)")

        // The climb check done from the slot, the leg timer started, then the cruise check comes due at
        // the level-off.
        pilot.tapSlot()
        pilot.tap("map.startLeg", timeout: 3)
        let levelOff = s.cue("levelOff") ?? s.mark("levelOff") + 60
        let cruiseDue = pilot.waitForSlot(timeout: pilot.wallUntil(track: levelOff, margin: 25)) {
            $0.tone == "due" && $0.label.contains("CRUISE CHECK")
        }
        pilot.shot("flight-5", "cruise-check-due")

        // flight-5: the cruise check from the slot opens the list; after the last CHECK, back on the map.
        pilot.check("flight-5", cruiseDue.ok, "slot at the level-off: \(cruiseDue.slot?.description ?? "none")")
        pilot.tapSlot()
        pilot.check("flight-5", pilot.waitUntil(timeout: 4) { pilot.currentPhase == "cruise" && pilot.paneShown == "checklist" },
                    "the list on \(pilot.paneShown ?? "?") (\(pilot.currentPhase ?? "?"))")
        let cruiseList = pilot.shot("flight-5", "cruise-list")
        // flight-17: the item text's commas and periods, on the list as it is read in flight.
        pilot.cite("flight-17", cruiseList)
        pilot.observed("flight-17", "commas and periods inside the cruise list's item text, centred in their cell: see the screenshot")
        pilot.checkAllItems()
        pilot.check("flight-5", pilot.waitUntil(timeout: 4) { pilot.paneShown == "map" },
                    "after the last CHECK: the \(pilot.paneShown ?? "?") pane")
        pilot.shot("flight-5", "back-on-map")
        if pilot.stopsAfter("flight-5") { return }

        // flight-6: "CRUISE CHECK ✓ hh:mm / FREDA in 10 min", counting down, on the map.
        let counting = pilot.waitForSlot(timeout: 8) { $0.label.contains("CRUISE CHECK ✓") && $0.label.contains("FREDA in") }
        pilot.shot("flight-6", "freda-counting")
        let firstMinutes = counting.slot.flatMap { CockpitPilot.minutes(in: $0.label) }
        pilot.waitForTrack(pilot.trackNow + 75)
        let later = pilot.slot
        let laterMinutes = later.flatMap { CockpitPilot.minutes(in: $0.label) }
        pilot.shot("flight-6", "freda-later")
        pilot.check("flight-6", counting.ok && (firstMinutes ?? 0) >= 9,
                    "slot: \(counting.slot?.description ?? "none")")
        pilot.check("flight-6", firstMinutes != nil && laterMinutes != nil && laterMinutes! < firstMinutes!,
                    "counts down by the minute: \(firstMinutes.map(String.init) ?? "?") → \(laterMinutes.map(String.init) ?? "?") min 75 s later")
        pilot.check("flight-6", pilot.paneShown == "map", "the pane stays on the \(pilot.paneShown ?? "?")")
        pilot.observed("flight-6", "no sound: not observable from a UI test")

        // flight-7: the waypoint passed at least 5 min after the cruise check makes FREDA due, named.
        let freda = pilot.waitForSlot(timeout: pilot.wallUntil(track: s.mark("wp1"), margin: 25)) {
            $0.tone == "due" && $0.action == "confirmFreda"
        }
        pilot.shot("flight-7", "freda-due")
        pilot.check("flight-7", freda.ok && (freda.slot?.label.contains("INS") ?? false),
                    "slot at INS (track \(Int(s.mark("wp1"))) s): \(freda.slot?.description ?? "none")")
        pilot.check("flight-7", pilot.phaseStatus("cruise") == "FREDA due", "cruise segment: \(pilot.phaseStatus("cruise") ?? "?")")
        pilot.tapSlot()
        pilot.check("flight-7", pilot.undo.waitForExistence(timeout: 3), "toast: \(pilot.toastMessage ?? "none")")
        let restarted = pilot.waitForSlot(timeout: 8) { $0.label.contains("FREDA ✓") }
        pilot.shot("flight-7", "freda-done")
        pilot.check("flight-7", restarted.ok, "the count restarts: \(restarted.slot?.description ?? "none")")

        // flight-8: on the CHECKLIST pane, the FREDA button before it is due: recorded and restarted.
        pilot.waitForTrack(pilot.trackNow + 60)
        pilot.showPane("checklist")
        let button = pilot.element("cockpit.freda.counting")
        pilot.check("flight-8", button.waitForExistence(timeout: 4), "FREDA counting beside NEXT: \((pilot.snap(button)?.label ?? "missing"))")
        pilot.shot("flight-8", "freda-button")
        let before = (pilot.snap(button)?.label ?? "missing")
        pilot.tapNow(button)
        pilot.check("flight-8", pilot.undo.waitForExistence(timeout: 3) && (pilot.toastMessage ?? "").contains("FREDA done"),
                    "recorded: \(pilot.toastMessage ?? "no toast")")
        let after = pilot.element("cockpit.freda.counting")
        pilot.check("flight-8", after.waitForExistence(timeout: 4) && (CockpitPilot.minutes(in: pilot.snap(after)?.label ?? "") ?? 0) >= 9,
                    "restarted: \(before) → \((pilot.snap(after)?.label ?? "missing"))")
        pilot.shot("flight-8", "freda-restarted")
        pilot.observed("flight-8", "no hold-to-re-arm: the tap alone recorded it (see the screenshots)")
        pilot.showPane("map")

        // flight-16: the act band with a route: the slot first, "MARK LSGC" with "LEG m:ss / m:ss" under
        // it, Divert and More in place; MARK still marks and offers UNDO.
        let mark = pilot.element("map.mark")
        let markLabel = mark.waitForExistence(timeout: 4) ? (pilot.snap(mark)?.label ?? "") : ""
        pilot.check("flight-16", markLabel.contains("MARK LSGC") && markLabel.contains("LEG"),
                    "MARK: \((pilot.snap(mark)?.label ?? "missing"))")
        let slotFrame = pilot.element(prefix: "checkSlot.").frame
        pilot.check("flight-16", slotFrame.minX < mark.frame.minX, "the slot first (x \(Int(slotFrame.minX)) < \(Int(mark.frame.minX)))")
        // The four slots in their order, one band (6.2): slot, MARK, Divert, More, their tops level.
        let band = [slotFrame, mark.frame, pilot.element("act.divert").frame, pilot.element("act.more").frame]
        pilot.check("flight-16", band.allSatisfy { !$0.isEmpty } && zip(band, band.dropFirst()).allSatisfy { $0.maxX <= $1.minX }
                        && Set(band.map { Int($0.minY.rounded()) }).count == 1,
                    "slot · MARK · Divert · More: \(band.map { "x \(Int($0.minX))-\(Int($0.maxX)) y \(Int($0.minY))" })")
        pilot.shot("flight-16", "bottom-row")
        pilot.tapNow(mark)
        pilot.check("flight-16", pilot.undo.waitForExistence(timeout: 3), "MARK offers UNDO: \(pilot.toastMessage ?? "no toast")")
        pilot.shot("flight-16", "mark-undo")
        pilot.tapNow(pilot.undo)
        pilot.check("flight-16", pilot.waitUntil(timeout: 3) { (pilot.label("map.mark") ?? "").contains("LSGC") },
                    "UNDO: \(pilot.label("map.mark") ?? "no MARK")")

        if pilot.stopsAfter("flight-8") { return }

        // flight-9: the descent: within about 40 s "✓ DESCENT CHECK", FREDA gone; one tap: DESCENT, with UNDO.
        let top = s.mark("topOfDescent")
        let descent = pilot.waitForSlot(timeout: pilot.wallUntil(track: top + 40, margin: 25)) {
            $0.tone == "due" && $0.label.contains("DESCENT CHECK")
        }
        let seenAt = pilot.trackNow
        pilot.shot("flight-9", "descent-due")
        pilot.check("flight-9", descent.ok, "slot: \(descent.slot?.description ?? "none")")
        pilot.check("flight-9", descent.ok && seenAt - top <= 40 + 5 * pilot.rate,
                    "came \(Int(seenAt - top)) s after the top of descent (the slot redraws every 5 s of the wall clock: up to \(Int(5 * pilot.rate)) s more at x\(Int(pilot.rate)))")
        pilot.check("flight-9", !(descent.slot?.label.contains("FREDA") ?? true), "FREDA gone from the slot")
        pilot.tapSlot()
        pilot.check("flight-9", pilot.waitUntil(timeout: 4) { pilot.currentPhase == "descent" }, "one tap: \(pilot.currentPhase ?? "?")")
        pilot.check("flight-9", pilot.undo.waitForExistence(timeout: 3), "with UNDO: \(pilot.toastMessage ?? "no toast")")
        pilot.check("flight-9", pilot.phaseStatus("descent") != nil, "descent segment: \(pilot.phaseStatus("descent") ?? "?")")
        pilot.shot("flight-9", "descent-confirmed")

        // flight-11: the approach check due 5 NM from the route's last point; the landing check dashed at
        // circuit height, GO AROUND and TOUCH-AND-GO beside it, nothing asking for a tap.
        let approach = pilot.waitForSlot(timeout: pilot.wallUntil(track: s.cue("approach") ?? 1500, margin: 25)) {
            $0.tone == "due" && $0.label.contains("APPROACH CHECK")
        }
        pilot.shot("flight-11", "approach-due")
        pilot.check("flight-11", approach.ok, "slot near LSGC (track \(Int(pilot.trackNow)) s, referee 5 NM at \(Int(s.cue("approach") ?? 0)) s): \(approach.slot?.description ?? "none")")
        pilot.observed("flight-11", "where it came due: the DEST distance on the screenshot")
        pilot.tapSlot()
        let landingShown = pilot.waitForSlot(timeout: pilot.wallUntil(track: s.cue("circuit") ?? 1600, margin: 25)) {
            $0.tone == "quiet" && $0.label.contains("LANDING")
        }
        pilot.shot("flight-11", "landing-dashed")
        pilot.check("flight-11", landingShown.ok, "at circuit height: \(landingShown.slot?.description ?? "none")")
        pilot.check("flight-11", pilot.element("map.goAround").exists && pilot.element("map.touchAndGo").exists,
                    "GO AROUND and TOUCH-AND-GO beside it")
        pilot.observed("flight-11", "nothing asks for a tap (no sound, no pulse): see the screenshot")
        // On to the landing check, as the slot offers (it stays unconfirmed: the landed card asks).
        pilot.tapSlot()

        // flight-12: landed and stopped 10 s: the landed card, still up after 20 s and a tap beside it.
        guard pilot.waitFor("landedCard.title", timeout: pilot.wallUntil(track: s.mark("stopped") + 15, margin: 30)) != nil else {
            pilot.check("flight-12", false, "no landed card by track \(Int(pilot.trackNow)) s")
            return
        }
        let title = pilot.landedCardTitle ?? ""
        pilot.shot("flight-12", "landed-card")
        pilot.check("flight-12", title.hasPrefix("LANDED · LSGC · "), "card: \(title)")
        Thread.sleep(forTimeInterval: 21)
        pilot.tapBeside()
        pilot.check("flight-12", pilot.landedCardTitle != nil, "still up after 21 s and a tap beside it")
        pilot.shot("flight-12", "still-up")
        let barBeforeYes = pilot.phaseBar()
        pilot.tap("landedCard.yes")
        pilot.check("flight-12", pilot.waitUntil(timeout: 4) { pilot.currentPhase == "afterLanding" },
                    "YES: \(pilot.currentPhase ?? "?") (not taxi)")
        let barAfterYes = pilot.phaseBar()
        pilot.check("flight-12", barAfterYes["landing"] == "Confirmed after landing",
                    "landing segment: \(barAfterYes["landing"] ?? "?")")
        let earlier = ["preflight", "beforeEngineStart", "engineStart", "afterEngineStart", "taxi", "runup",
                       "beforeDeparture", "lineUp", "climb", "cruise", "descent", "approach"]
        let unchanged = earlier.filter { barBeforeYes[$0] == barAfterYes[$0] }
        pilot.check("flight-12", unchanged.count == earlier.count,
                    "earlier checks as left: \(earlier.map { "\($0) \(barAfterYes[$0] ?? "?")" }.joined(separator: ", "))")
        pilot.shot("flight-12", "after-landing")

        // flight-14: FULL STOP LANDING held after the card: the count stays at 1.
        pilot.showPane("checklist")
        pilot.check("flight-14", pilot.hold("cockpit.fullStop"), "FULL STOP LANDING held")
        let fullStop = pilot.element("cockpit.fullStop")
        let fullStopLabel = pilot.snap(fullStop)?.label ?? ""
        pilot.check("flight-14", fullStopLabel.hasSuffix(", 1"), "the count stays at 1: \"\(fullStopLabel)\"")
        pilot.shot("flight-14", "full-stop-count")

        // The rest of the checks, END FLIGHT at AT THE HANGAR.
        pilot.workChecks(until: "hangar", pressEngineStart: false)
        pilot.checkAllItems()
        pilot.shot("debrief-1", "hangar")
        pilot.endFlight()

        // flight-14 (cont.) and debrief-1: the Logbook's flight: one landing, every check done.
        guard pilot.openNewestFlightInLogbook() else { return pilot.check("debrief-1", false, "no flight in the Logbook") }
        pilot.shot("flight-14", "logbook-flight")
        let allDone = pilot.app.staticTexts["All checks done"]
        pilot.check("debrief-1", allDone.waitForExistence(timeout: 5), "\"All checks done\" under the timeline")
        pilot.revealChecks()
        pilot.shot("debrief-1", "checks")
        pilot.observed("debrief-1", "\"Show each check\" lists the 16: see the screenshot")
        pilot.observed("flight-14", "one landing, at touchdown: see the Logbook screenshot")
    }

    // MARK: - (2) The climb check left open, NEXT past it, NOT SURE on the landed card

    /// LSZQ → INS → LSGC: flight-4 (owed at the level-off), flight-15 (the review, CHECK LATER),
    /// flight-13 (NOT SURE), debrief-2.
    func testClimbCheckLeftOpenThenNotSure() {
        let pilot = CockpitPilot(self, scenario: "xc-climb-owed")
        defer { pilot.attachResults(testName: name) }
        let s = pilot.scenario
        pilot.launch()
        guard pilot.departToClimb() else { return XCTFail("could not get to the climb check") }

        // flight-4: level off without confirming the climb check: owed, filled amber, the segment amber.
        let owed = pilot.waitForSlot(timeout: pilot.wallUntil(track: s.cue("levelOff") ?? 600, margin: 30)) {
            $0.tone == "owed" && $0.label.contains("CLIMB CHECK")
        }
        pilot.shot("flight-4", "owed")
        pilot.check("flight-4", owed.ok && (owed.slot?.label.contains("owed · you levelled off with it open") ?? false),
                    "slot: \(owed.slot?.description ?? "none")")
        pilot.check("flight-4", pilot.phaseStatus("climb") == "Owed", "climb segment: \(pilot.phaseStatus("climb") ?? "?")")

        // flight-15: NEXT on the checklist pane with the memory check unconfirmed: the review says "not
        // confirmed"; CONTINUE, CHECK LATER: the check deferred, orange, "1 deferred check".
        pilot.showPane("checklist")
        pilot.tap("cockpit.nextChip", timeout: 4)
        let review = pilot.app.staticTexts["CLIMB CHECK not confirmed"]
        pilot.check("flight-15", review.waitForExistence(timeout: 4), "the review: \(pilot.snap(review)?.label ?? "no \"not confirmed\"")")
        pilot.shot("flight-15", "review")
        pilot.tap("review.continue", timeout: 4)
        pilot.check("flight-15", pilot.waitUntil(timeout: 4) { pilot.currentPhase == "cruise" }, "on to \(pilot.currentPhase ?? "?")")
        let chip = pilot.app.buttons.matching(NSPredicate(format: "label CONTAINS 'deferred check'")).firstMatch
        pilot.showPane("checklist")
        pilot.check("flight-15", chip.waitForExistence(timeout: 4) && (pilot.snap(chip)?.label ?? "").contains("1 deferred check"),
                    "chip: \((pilot.snap(chip)?.label ?? "none"))")
        pilot.check("flight-15", pilot.phaseStatus("climb") == "skipped", "climb segment (orange): \(pilot.phaseStatus("climb") ?? "?")")
        pilot.shot("flight-15", "deferred")
        pilot.observed("flight-15", "Review › ✓ DONE (green) is flown in testDescentAbandoned: here the climb check stays never done, for debrief-2")

        // The cruise check, FREDA when due, the descent, the approach, to the landing check.
        pilot.checkAllItems()
        pilot.flyCruiseToLanding(confirmFreda: true)

        // flight-13 (NOT SURE): the landed card answered NOT SURE: the landing segment amber.
        guard pilot.waitFor("landedCard.title", timeout: pilot.wallUntil(track: s.mark("stopped") + 15, margin: 30)) != nil else {
            return pilot.check("flight-13", false, "no landed card")
        }
        pilot.shot("flight-13", "landed-card")
        pilot.tap("landedCard.notSure")
        pilot.check("flight-13", pilot.waitUntil(timeout: 4) { pilot.currentPhase == "afterLanding" }, "NOT SURE: on \(pilot.currentPhase ?? "?")")
        pilot.check("flight-13", pilot.phaseStatus("landing") == "Not sure", "landing segment (amber): \(pilot.phaseStatus("landing") ?? "?")")
        pilot.shot("flight-13", "not-sure")

        // debrief-2: CLIMB CHECK owed, never done; LANDING CHECK not sure.
        pilot.endFlight()
        guard pilot.openNewestFlightInLogbook() else { return pilot.check("debrief-2", false, "no flight in the Logbook") }
        pilot.revealChecks()
        let climb = pilot.texts(containing: "owed, never done")
        pilot.check("debrief-2", climb.contains { $0.contains("you levelled off with it open") && $0.contains("skipped") },
                    "climb check line: \(climb)")
        pilot.check("debrief-2", !pilot.texts(containing: "not sure").isEmpty, "landing check: \(pilot.texts(containing: "not sure"))")
        pilot.shot("debrief-2", "checks")
        pilot.observed("debrief-2", "both amber on the strip: see the screenshot")

        // debrief-6, as far as the accessibility tree tells it (no trend card on one flight): each check's
        // line one element, the strip none.
        let tree = pilot.screen()
        let climbLines = tree.filter { $0.label.hasPrefix("CLIMB CHECK") && $0.label.contains("owed") }
        pilot.check("debrief-6", climbLines.contains { $0.label.contains("owed, never done") && $0.label.contains("skipped") },
                    "the climb check's line, one element: \(climbLines.map { "\($0.elementType.rawValue) \"\($0.label)\"" })")
        pilot.dumpTree("debrief-6")
        pilot.observed("debrief-6", "each line one element, the strip skipped, the headers: see the tree attachment; the trend card needs three flights")
    }

    // MARK: - (3) FREDA missed: cruise left with FREDA due

    /// LSZQ → BIEL → LSGC: flight-4 (the owed climb check done with one tap, the cruise check due),
    /// debrief-3 (FREDA missed 1×).
    func testFredaMissedInCruise() {
        let pilot = CockpitPilot(self, scenario: "xc-freda-missed")
        defer { pilot.attachResults(testName: name) }
        let s = pilot.scenario
        pilot.launch()
        guard pilot.departToClimb() else { return XCTFail("could not get to the climb check") }

        // flight-4: owed at the level-off; one tap: done (green), and the cruise check due in the slot.
        let owed = pilot.waitForSlot(timeout: pilot.wallUntil(track: s.cue("levelOff") ?? 600, margin: 30)) {
            $0.tone == "owed" && $0.label.contains("CLIMB CHECK")
        }.slot
        pilot.check("flight-4", owed?.tone == "owed", "at the level-off: \(owed?.description ?? "none")")
        pilot.shot("flight-4", "owed")
        pilot.tapSlot()
        pilot.check("flight-4", pilot.waitUntil(timeout: 4) { pilot.phaseStatus("climb") == "done from memory" },
                    "one tap: climb \(pilot.phaseStatus("climb") ?? "?")")
        let cruise = pilot.waitForSlot(timeout: 6) { $0.tone == "due" && $0.label.contains("CRUISE CHECK") }
        pilot.check("flight-4", cruise.ok, "the cruise check due in the slot: \(cruise.slot?.description ?? "none")")
        pilot.shot("flight-4", "done-cruise-due")

        // The cruise check; FREDA comes due (at BIEL or by the clock) and is left alone; then the descent.
        pilot.tapSlot()
        _ = pilot.waitUntil(timeout: 4) { pilot.paneShown == "checklist" }
        pilot.checkAllItems()
        let due = pilot.waitForSlot(timeout: pilot.wallUntil(track: s.mark("topOfDescent"), margin: 10)) { $0.action == "confirmFreda" }
        pilot.shot("debrief-3", "freda-due")
        pilot.check("debrief-3", due.ok, "FREDA came due: \(due.slot?.description ?? "none")")
        pilot.flyCruiseToLanding(confirmFreda: false)
        if pilot.waitFor("landedCard.yes", timeout: pilot.wallUntil(track: s.mark("stopped") + 15, margin: 30)) != nil {
            pilot.tap("landedCard.yes")
        }

        // debrief-3: FREDA "missed 1×" with its time.
        pilot.endFlight()
        guard pilot.openNewestFlightInLogbook() else { return pilot.check("debrief-3", false, "no flight in the Logbook") }
        pilot.revealChecks()
        let missed = pilot.texts(containing: "missed")
        pilot.check("debrief-3", missed.contains { $0.contains("missed 1×") }, "FREDA line: \(missed)")
        pilot.check("debrief-3", !pilot.texts(containing: "due ").isEmpty || missed.contains { $0.contains(":") },
                    "with its time: \(pilot.texts(containing: "due "))")
        pilot.shot("debrief-3", "checks")
    }

    // MARK: - (4) A descent started, levelled, and climbed back

    /// LSZQ → INS → LSGC with a 600 ft dip after INS: flight-10; and flight-15 in full (the
    /// climb check deferred at the level-off, then Review › ✓ DONE).
    func testDescentAbandoned() {
        let pilot = CockpitPilot(self, scenario: "xc-descent-abandoned")
        defer { pilot.attachResults(testName: name) }
        let s = pilot.scenario
        pilot.launch()
        guard pilot.departToClimb() else { return XCTFail("could not get to the climb check") }

        // flight-15: the climb check left for later from the review, done later from the deferred list.
        _ = pilot.waitForSlot(timeout: pilot.wallUntil(track: s.cue("levelOff") ?? 600, margin: 30)) {
            $0.tone == "owed" && $0.label.contains("CLIMB CHECK")
        }
        pilot.showPane("checklist")
        pilot.tap("cockpit.nextChip", timeout: 4)
        pilot.check("flight-15", pilot.app.staticTexts["CLIMB CHECK not confirmed"].waitForExistence(timeout: 4), "the review says not confirmed")
        pilot.tap("review.continue", timeout: 4)
        pilot.checkAllItems()                      // the cruise check
        let chip = pilot.app.buttons.matching(NSPredicate(format: "label CONTAINS 'deferred check'")).firstMatch
        pilot.showPane("checklist")
        pilot.check("flight-15", chip.waitForExistence(timeout: 4), "deferred: \((pilot.snap(chip)?.label ?? "no chip"))")
        pilot.check("flight-15", pilot.phaseStatus("climb") == "skipped", "climb (orange): \(pilot.phaseStatus("climb") ?? "?")")
        pilot.tapNow(chip)
        let done = pilot.app.buttons["CLIMB CHECK, done from memory"]
        pilot.check("flight-15", done.waitForExistence(timeout: 4), "Review › ✓ DONE offered")
        pilot.shot("flight-15", "review-done")
        pilot.tapNow(done)
        let close = pilot.app.buttons["Done"].firstMatch
        if close.waitForExistence(timeout: 2) { close.tap() }
        pilot.check("flight-15", pilot.waitUntil(timeout: 4) { pilot.phaseStatus("climb") == "done from memory" },
                    "✓ DONE: climb \(pilot.phaseStatus("climb") ?? "?") (green)")
        pilot.shot("flight-15", "green")
        pilot.showPane("map")

        // FREDA at INS, confirmed: it counts.
        if pilot.slotDue("FREDA", by: s.mark("wp1"), tap: true) == nil {
            pilot.observed("flight-10", "FREDA did not come due at INS before the dip")
        }

        // flight-10: down 600 ft: the descent check due, FREDA gone; level, climb back 300 ft: withdrawn,
        // FREDA back.
        let descent = pilot.waitForSlot(timeout: pilot.wallUntil(track: (s.cue("descent", after: s.mark("dipStart")) ?? s.mark("dipStart") + 40), margin: 25)) {
            $0.label.contains("DESCENT CHECK")
        }
        pilot.shot("flight-10", "descent-due")
        pilot.check("flight-10", descent.ok && !(descent.slot?.label.contains("FREDA") ?? true),
                    "on the way down: \(descent.slot?.description ?? "none")")
        let withdrawn = s.cue("descentWithdrawn") ?? s.mark("dipClimb") + 70
        let back = pilot.waitForSlot(timeout: pilot.wallUntil(track: withdrawn, margin: 25)) { $0.label.contains("FREDA in") }
        pilot.shot("flight-10", "freda-back")
        pilot.check("flight-10", back.ok, "climbed back: \(back.slot?.description ?? "none") (referee withdrawal at \(Int(withdrawn)) s)")
        pilot.check("flight-10", pilot.currentPhase == "cruise", "still on \(pilot.currentPhase ?? "?")")
        pilot.endFlight()
    }

    // MARK: - (5) The landed card left unanswered

    /// A local flight at LSZQ: the first full stop's card left unanswered through the taxi, gone on the
    /// next take-off roll; the second answered NOT SURE. flight-12 (the card waits), flight-13.
    func testLandedCardUnanswered() {
        let pilot = CockpitPilot(self, scenario: "local-landed-unanswered")
        defer { pilot.attachResults(testName: name) }
        let s = pilot.scenario
        pilot.launch()
        guard pilot.departToClimb() else { return XCTFail("could not get to the climb check") }
        pilot.slotDue("CLIMB CHECK", by: s.cue("takeoff") ?? 300, notBefore: s.mark("liftoff") + 20)
        pilot.doListCheckFromSlot("CRUISE CHECK", by: s.cue("levelOff") ?? 450)
        pilot.slotDue("DESCENT CHECK", by: s.cue("descent") ?? 720)
        pilot.slotDue("APPROACH CHECK", by: s.cue("approach") ?? 760)

        guard pilot.waitFor("landedCard.title", timeout: pilot.wallUntil(track: s.mark("stopped") + 15, margin: 30)) != nil else {
            return pilot.check("flight-13", false, "no landed card after the first full stop")
        }
        pilot.shot("flight-13", "card-up")
        pilot.tapBeside()
        // The taxi back to the holding point: the card waits.
        pilot.waitForTrack(s.mark("secondDeparture") - 5)
        pilot.check("flight-13", pilot.landedCardTitle != nil, "still up at the holding point (track \(Int(pilot.trackNow)) s)")
        pilot.check("flight-12", pilot.landedCardTitle != nil, "a card left unanswered stays: a tap beside it and the taxi")
        pilot.shot("flight-13", "card-at-holding-point")
        // The next take-off: the card goes on the roll.
        var goneAt: Double?
        _ = pilot.waitUntil(timeout: pilot.wallUntil(track: s.mark("liftoff2") + 30, margin: 10)) {
            if pilot.landedCardTitle == nil { goneAt = pilot.trackNow; return true }
            return false
        }
        pilot.shot("flight-13", "card-gone")
        pilot.check("flight-13", goneAt.map { $0 >= s.mark("takeoffRoll2") - 5 && $0 <= s.mark("liftoff2") + 25 } ?? false,
                    "gone at track \(goneAt.map { String(Int($0)) } ?? "never") s (roll \(Int(s.mark("takeoffRoll2"))) s, lift-off \(Int(s.mark("liftoff2"))) s)")

        // The second landing, answered NOT SURE.
        guard pilot.waitFor("landedCard.notSure", timeout: pilot.wallUntil(track: s.mark("stopped2") + 15, margin: 30)) != nil else {
            return pilot.check("flight-13", false, "no landed card after the second full stop")
        }
        pilot.tap("landedCard.notSure")
        pilot.check("flight-13", pilot.waitUntil(timeout: 4) { pilot.phaseStatus("landing") == "Not sure" },
                    "NOT SURE: landing \(pilot.phaseStatus("landing") ?? "?") (amber)")
        pilot.shot("flight-13", "not-sure")
        pilot.endFlight()
    }
}
