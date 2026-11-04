import XCTest

/// The reminder to report the departure (6.9.0, the page's rd-*), flown on the simulator's own data and the sandbox's
/// flight plan rules. report-lfga goes LSZQ → LFGA planned for today, across the border, from an aerodrome with no
/// tower or AFIS. The flight plan's tick is the pilot's, on the flight page, as on the day.
final class ReportDepartureUITests: XCTestCase {
    private let reminder = "status.reportDeparture"
    private let chip = "cockpit.reportDepartureChip"

    override func setUp() {
        continueAfterFailure = true
    }

    /// rd-1: the flight page says why. rd-2: the climb check done brings the reminder at once, well before its three
    /// minutes, as a chip on CHECKLIST and on the map, and it says who to call. rd-3: a tap is Done, and it doesn't come back.
    func testTheClimbCheckBringsTheReminderAndATapDoesIt() throws {
        let pilot = try CockpitPilot.onDeviceData(self, scenario: "report-lfga", page: "690")
        defer { pilot.attachResults(testName: name) }
        pilot.launch()
        guard fileThePlan(pilot) else { return }
        guard pilot.departToClimb() else { return XCTFail("never reached the climb check") }

        pilot.check("rd-2", !pilot.element(chip).exists, "no chip while the climb check is open, at \(Int(pilot.trackNow)) s")
        pilot.checkAllItems()
        pilot.confirmMemoryCheck()
        let doneAt = pilot.trackNow
        pilot.check("rd-2", pilot.waitFor(chip, timeout: 4) != nil, "the chip on CHECKLIST, the climb check done at \(Int(doneAt)) s")
        pilot.shot("rd-2", "chip")

        pilot.showPane("map")
        let shown = pilot.waitFor(reminder, timeout: 4) != nil
        let label = pilot.label(reminder) ?? ""
        pilot.shot("rd-2", "slot")
        pilot.check("rd-2", shown, "on the map at \(Int(pilot.trackNow)) s: \"\(label)\"")
        pilot.check("rd-2", label.contains("REPORT YOUR DEPARTURE") && label.contains("·"),
                    "it names the station and why: \"\(label)\"")

        pilot.tap(reminder, timeout: 3)
        let log = SlotEntry.watch(pilot, untilTrack: pilot.trackNow + 300)
        pilot.check("rd-3", !log.contains { $0.state == "reportDeparture" },
                    "after the tap, five minutes: \(SlotEntry.summary(log))")
        pilot.showPane("checklist")
        pilot.check("rd-3", !pilot.element(chip).exists, "the chip went with it")
        pilot.shot("rd-3", "gone")
    }

    /// rd-4: left alone, the climb check still open: it comes by itself three minutes after the take-off and goes a
    /// quarter of an hour later. Read on CHECKLIST, where nothing outranks it: on the map, an amber AIRSPACE AHEAD does.
    func testLeftAloneItComesAndGoesByItself() throws {
        let pilot = try CockpitPilot.onDeviceData(self, scenario: "report-lfga", page: "690")
        defer { pilot.attachResults(testName: name) }
        let s = pilot.scenario
        pilot.launch()
        guard fileThePlan(pilot) else { return }
        guard pilot.departToClimb() else { return XCTFail("never reached the climb check") }
        pilot.showPane("checklist")

        // The take-off the app counts from is the line-up's estimate, some 90 s after the tap, so two margins.
        let lineUp = s.mark("lineUp")
        var cameAt: Double?, wentAt: Double?
        _ = pilot.waitUntil(timeout: (lineUp + 1500 - pilot.trackNow) / pilot.rate) {
            let there = pilot.element(chip).exists
            if there, cameAt == nil { cameAt = pilot.trackNow; pilot.shot("rd-4", "chip") }
            if !there, cameAt != nil { wentAt = pilot.trackNow; return true }
            return false
        }
        pilot.check("rd-4", cameAt.map { $0 - lineUp > 150 && $0 - lineUp < 360 } ?? false,
                    "came \(cameAt.map { "\(Int($0 - lineUp)) s after the line-up" } ?? "never")")
        let stayed = cameAt.flatMap { came in wentAt.map { $0 - came } }
        pilot.check("rd-4", stayed.map { $0 > 840 && $0 < 960 } ?? false,
                    "stayed \(stayed.map { "\(Int($0)) s" } ?? "and never went")")
        pilot.shot("rd-4", "gone")
    }

    /// rd-5: the same flight with the plan not ticked: nothing to report, nothing shown.
    func testNoFiledPlanNoReminder() throws {
        let pilot = try CockpitPilot.onDeviceData(self, scenario: "report-lfga", page: "690")
        defer { pilot.attachResults(testName: name) }
        let s = pilot.scenario
        pilot.launch()
        guard pilot.departToClimb() else { return XCTFail("never reached the climb check") }
        pilot.checkAllItems()
        pilot.confirmMemoryCheck()
        pilot.showPane("map")
        let log = SlotEntry.watch(pilot, untilTrack: s.mark("lineUp") + 300)
        pilot.showPane("checklist")
        pilot.check("rd-5", !log.contains { $0.state == "reportDeparture" } && !pilot.element(chip).exists,
                    "never shown, five minutes after the line-up: \(SlotEntry.summary(log))")
    }

    /// From Today to the flight page, its reason read, the plan ticked, and back.
    private func fileThePlan(_ pilot: CockpitPilot) -> Bool {
        let card = pilot.app.buttons.matching(NSPredicate(format: "label CONTAINS 'LFGA'")).firstMatch
        guard card.waitForExistence(timeout: 20), pilot.tapNow(card) else {
            pilot.dumpTree("no-flight-card")
            pilot.check("rd-1", false, "no card for the flight on Today")
            return false
        }
        // The rules come from the sandbox at launch, after the page may have opened: a minute at most.
        let word = "crosses a border"
        pilot.scrollTo("ATC flight plan")
        let read = pilot.waitUntil(timeout: 20) { !pilot.texts(containing: word).isEmpty }
        pilot.shot("rd-1", "flight-page")
        pilot.check("rd-1", read, "the flight page says why: \(pilot.texts(containing: word))")
        let tick = pilot.app.buttons["ATC flight plan"].firstMatch
        guard tick.waitForExistence(timeout: 5), pilot.tapNow(tick) else {
            pilot.dumpTree("no-tick")
            pilot.check("rd-1", false, "no tick on the flight plan's block")
            return false
        }
        pilot.shot("rd-1", "ticked")
        pilot.app.buttons["Close"].firstMatch.tap()
        return pilot.element("home.startFlight").waitForExistence(timeout: 8)
    }
}
