import XCTest

// MARK: - Ground replays: the pilot's side
//
// A UI test launches the app on a scenario (`GroundReplay.swift`: the track replayed through the app's
// own GPS pipeline on a clock running `speedFactor` times faster), then taps what the pilot taps, waiting
// on the Cockpit's accessibility identifiers, never on fixed sleeps where a wait is possible. Each step of
// the device-check pages (6.1.0: flight-*, circuits-*, debrief-*, eet-*; 6.0.1: ato-*, undo-*, rp-9) is
// recorded pass, fail or observed (what only a person can judge from the screenshot), with a screenshot
// named "<page>-<step id>-<short>". `scripts/ground-replay.sh` collects them into results.json.

/// A scenario as the UI test reads it: what the app replays, and what the referee expects of it.
struct ReplayScenario: Decodable {
    struct Hold: Decodable { let t: Double; let until: String }
    struct Expected: Decodable {
        struct Event: Decodable { let type: String; let t: Double; let at: String? }
        struct Cue: Decodable { let type: String; let t: Double; let implied: Bool; let at: String? }
        let events: [Event]
        let takeoffs: [Double]
        let cues: [Cue]
    }

    let name: String
    let speedFactor: Double
    let circuits: Bool
    let departure: String
    let destination: String
    let fieldElevations: [String: Int?]
    let marks: [String: Double]
    let holds: [Hold]
    let expected: Expected?

    /// Track seconds of a mark ("liftoff", "touchdown2"...).
    func mark(_ name: String) -> Double {
        guard let t = marks[name] else { fatalError("scenario \(self.name) has no mark \(name)") }
        return t
    }

    /// The first cue of `type` at or after `after` (track seconds), not implied by a later one.
    func cue(_ type: String, after: Double = 0) -> Double? {
        expected?.cues.first { $0.type == type && !$0.implied && $0.t >= after }?.t
    }

    static func load(_ name: String) -> (ReplayScenario, URL) {
        let bundle = Bundle(for: CockpitPilot.self)
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Scenarios")
                ?? bundle.url(forResource: name, withExtension: "json") else {
            fatalError("no scenario \(name) in the test bundle")
        }
        do {
            return (try JSONDecoder().decode(ReplayScenario.self, from: Data(contentsOf: url)), url)
        } catch {
            fatalError("scenario \(name): \(error)")
        }
    }
}

/// What a step came to, for results.json.
struct StepResult: Codable {
    enum Status: String, Codable { case pass, fail, observed }
    let id: String
    var status: Status
    var notes: [String]
    var screenshots: [String]
}

/// The pilot: launches the replay, taps, waits, asserts, and keeps the record of each step.
final class CockpitPilot {
    let app = XCUIApplication()
    let scenario: ReplayScenario
    let scenarioURL: URL
    let page: String
    private unowned let test: XCTestCase
    private(set) var steps: [StepResult] = []
    /// When the replay was let go at a hold (wall clock), and the hold's track time.
    private var released: (wall: Date, track: Double)?

    init(_ test: XCTestCase, scenario name: String, page: String = "610") {
        self.test = test
        (scenario, scenarioURL) = ReplayScenario.load(name)
        self.page = page
    }

    var rate: Double { scenario.speedFactor }

    // MARK: Launch

    /// The app on the scenario, in English, with the Memory test on (the 6.1.0 page's setup). `resume`:
    /// a relaunch mid-flight, the replay going on where it was.
    func launch(memoryTest: Bool = true, resume: Bool = false) {
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_CH"]
        app.launchEnvironment["AEROCHECK_REPLAY"] = scenarioURL.path
        app.launchEnvironment["AEROCHECK_REPLAY_SPEED"] = String(Int(rate))
        app.launchEnvironment["AEROCHECK_MEMORY_TEST"] = memoryTest ? "1" : "0"
        app.launchEnvironment["AEROCHECK_REPLAY_RESUME"] = resume ? "1" : "0"
        app.launch()
        dismissSystemAlerts()
        guard !resume else { return }
        // A fresh replay starts on Today, a flight left over from an earlier run abandoned. Seen once: the
        // first launch after an install came up on that flight's Cockpit, the launch hook not run (as the
        // scenes sometimes do after an install). Once more, then.
        let home = element("home.startFlight")
        if !home.waitForExistence(timeout: 15), element("cockpit.menu").exists {
            launchNotes.append("relaunched: the first launch showed an earlier flight's Cockpit")
            app.terminate()
            app.launch()
            dismissSystemAlerts()
            _ = home.waitForExistence(timeout: 15)
        }
    }

    /// What the harness had to do to get going, for the record.
    private(set) var launchNotes: [String] = []

    func terminate() { app.terminate() }

    /// START FLIGHT (or CIRCUITS) on Today, and the Cockpit up. On failure the screen and the tree are
    /// attached, to tell a harness problem from the app's.
    @discardableResult
    func startFlight(_ button: String = "home.startFlight") -> Bool {
        guard tap(button, timeout: 30) else {
            shot("setup", "no-start-button")
            dumpTree("no-start-button")
            return false
        }
        if element("cockpit.check").waitForExistence(timeout: 20) { return true }
        // A start refused while GPS warms up says so in an alert: once more.
        let ok = app.alerts.buttons.firstMatch
        if ok.exists { ok.tap(); tap(button, timeout: 5) }
        if element("cockpit.check").waitForExistence(timeout: 20) { return true }
        shot("setup", "no-cockpit")
        dumpTree("no-cockpit")
        return false
    }

    /// Location, notifications: answered so they never sit over the Cockpit.
    func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow While Using App", "Allow", "Always Allow", "Change to Always Allow", "Don’t Allow", "OK"] {
            let button = springboard.buttons[label]
            if button.exists { button.tap() }
        }
    }

    // MARK: Elements

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The first element whose identifier starts with `prefix` ("checkSlot").
    func element(prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    @discardableResult
    func waitFor(_ identifier: String, timeout: TimeInterval = 10) -> XCUIElement? {
        let e = element(identifier)
        return e.waitForExistence(timeout: timeout) ? e : nil
    }

    /// Polls `condition` every 0.25 s for up to `timeout` wall seconds.
    @discardableResult
    func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < end
        return condition()
    }

    /// Taps `identifier` once it exists. False when it never came.
    @discardableResult
    func tap(_ identifier: String, timeout: TimeInterval = 10) -> Bool {
        guard let e = waitFor(identifier, timeout: timeout) else { return false }
        e.tap()
        return true
    }

    /// Holds a hold-to-confirm button (1 s) down.
    @discardableResult
    func hold(_ identifier: String, seconds: TimeInterval = 1.6, timeout: TimeInterval = 10) -> Bool {
        guard let e = waitFor(identifier, timeout: timeout) else { return false }
        e.press(forDuration: seconds)
        return true
    }

    // MARK: The check slot and the phase bar

    struct Slot: CustomStringConvertible {
        let tone: String
        let action: String
        let label: String
        var description: String { "\(tone)/\(action) \"\(label)\"" }
    }

    /// The check slot on the MAP pane, as drawn now: tone and action from its identifier, its words.
    var slot: Slot? {
        let e = element(prefix: "checkSlot.")
        guard e.exists else { return nil }
        let parts = e.identifier.split(separator: ".").map(String.init)
        return Slot(tone: parts.count > 1 ? parts[1] : "", action: parts.count > 2 ? parts[2] : "", label: e.label)
    }

    /// Waits until the slot satisfies `condition`; the last slot seen either way.
    @discardableResult
    func waitForSlot(timeout: TimeInterval, _ condition: (Slot) -> Bool) -> (ok: Bool, slot: Slot?) {
        var last: Slot?
        let ok = waitUntil(timeout: timeout) {
            last = slot
            return last.map(condition) ?? false
        }
        return (ok, last)
    }

    /// The phase bar's word for a check: "completed", "done from memory", "Owed", "skipped"...
    func phaseStatus(_ phase: String) -> String? {
        let e = element("phaseBar.\(phase)")
        return e.exists ? (e.value as? String) : nil
    }

    /// The phase the Cockpit is on: the selected segment.
    var currentPhase: String? {
        let segments = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'phaseBar.' AND selected == true"))
        let e = segments.firstMatch
        return e.exists ? String(e.identifier.dropFirst("phaseBar.".count)) : nil
    }

    var paneShown: String? {
        if element("pane.map").exists && element("pane.map").isSelected { return "map" }
        if element("pane.checklist").exists && element("pane.checklist").isSelected { return "checklist" }
        return nil
    }

    func showPane(_ pane: String) {
        if paneShown != pane { tap("pane.\(pane)") }
    }

    // MARK: Time

    /// The replay was let go now, at the hold at `track` seconds.
    func noteRelease(atTrack track: Double) {
        released = (Date(), track)
    }

    /// Where the replay is in the track, as far as the test can tell (since the last release).
    var trackNow: Double {
        guard let released else { return 0 }
        return released.track + Date().timeIntervalSince(released.wall) * rate
    }

    /// Wall seconds until the track reaches `t`, plus `margin` (wall seconds).
    func wallUntil(track t: Double, margin: TimeInterval = 15) -> TimeInterval {
        max(margin, (t - trackNow) / rate + margin)
    }

    /// Waits (wall clock) until the track reaches `t`.
    func waitForTrack(_ t: Double) {
        let wait = (t - trackNow) / rate
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
    }

    // MARK: The pilot's checklist work

    /// The hour meter asks at ENGINE START when the reading is logged (the default): skipped here.
    func skipHourMeterIfAsked() {
        for label in ["Skip", "SKIP", "Cancel"] {
            let b = app.buttons[label]
            if b.exists && b.isHittable { b.tap(); return }
        }
    }

    /// CHECK through the current list (at most `max` items), until CHECK gives way.
    func checkAllItems(max: Int = 30) {
        for _ in 0..<max {
            skipHourMeterIfAsked()
            let check = element("cockpit.check")
            guard check.exists else { return }
            check.tap()
        }
    }

    /// The current check done, the pilot's usual way: its list CHECKed, or a memory check confirmed
    /// (which, by the thumb bar's one tap, also goes on). Then NEXT when it shows. Returns the phase it
    /// left, as the phase bar said.
    @discardableResult
    func completeCurrentCheckAndGoOn() -> String? {
        let from = currentPhase
        skipHourMeterIfAsked()
        showPane("checklist")
        if element("cockpit.memoryDone").exists {
            element("cockpit.memoryDone").tap()
            // The one tap goes on, unless it only confirms (the phase's own action, the last check).
            waitUntil(timeout: 3) { self.currentPhase != from || self.element("cockpit.next").exists }
            if currentPhase == from, element("cockpit.next").exists { element("cockpit.next").tap() }
        } else {
            checkAllItems()
            if element("cockpit.next").waitForExistence(timeout: 3) { element("cockpit.next").tap() }
        }
        waitUntil(timeout: 5) { self.currentPhase != from }
        return from
    }

    /// Works the checks up to (not including) `phase`, pressing ENGINE START (when `pressEngineStart`) and
    /// ENGINE SHUTDOWN on the way. At the check before departure its NEXT is READY FOR LINE UP (6.2).
    func workChecks(until phase: String, pressEngineStart: Bool = true, maxSteps: Int = 16) {
        for _ in 0..<maxSteps {
            skipHourMeterIfAsked()
            guard let current = currentPhase, current != phase else { return }
            if current == "engineStart", pressEngineStart, element("cockpit.engineStart").exists,
               (element("cockpit.engineStart").value as? String)?.lowercased().contains("not recorded") ?? true {
                element("cockpit.engineStart").tap()
                skipHourMeterIfAsked()
            }
            if current == "shutdown", element("cockpit.engineShutdown").exists,
               (element("cockpit.engineShutdown").value as? String)?.lowercased().contains("not recorded") ?? true {
                checkAllItems()
                element("cockpit.engineShutdown").tap()
                skipHourMeterIfAsked()
            }
            completeCurrentCheckAndGoOn()
        }
    }

    // MARK: What the Cockpit shows

    var memoryDone: XCUIElement { element("cockpit.memoryDone") }
    var undo: XCUIElement { element("undoToast.undo") }
    var toastMessage: String? {
        let e = element("undoToast.message")
        return e.exists ? e.label : nil
    }

    /// The phase bar, segment by segment: phase → its spoken status.
    func phaseBar() -> [String: String] {
        var out: [String: String] = [:]
        let segments = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'phaseBar.'"))
        for i in 0..<segments.count {
            let e = segments.element(boundBy: i)
            out[String(e.identifier.dropFirst("phaseBar.".count))] = (e.value as? String) ?? ""
        }
        return out
    }

    /// The strip's altitude, feet (nil when not shown or no GPS).
    var altitudeFeet: Int? {
        let e = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Altitude'")).firstMatch
        guard e.exists, let value = e.value as? String else { return nil }
        return Int(value.components(separatedBy: CharacterSet.decimalDigits.inverted).joined())
    }

    /// The landed card's title ("LANDED · LSGC · 14:37"), when it is up.
    var landedCardTitle: String? {
        let e = element("landedCard.title")
        return e.exists ? e.label : nil
    }

    /// A tap on the backdrop, away from any button: the top left corner, under the status bar.
    func tapBeside() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.06)).tap()
    }

    /// The text of every static text on screen containing `fragment`.
    func texts(containing fragment: String) -> [String] {
        let q = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fragment))
        return (0..<q.count).map { q.element(boundBy: $0).label }
    }

    /// The check slot's one tap (on the MAP pane, where it is).
    func tapSlot() {
        showPane("map")
        let e = element(prefix: "checkSlot.")
        if e.waitForExistence(timeout: 5) { e.tap() }
    }

    /// "FREDA in 6 min" → 6.
    static func minutes(in text: String) -> Int? {
        guard let range = text.range(of: #"in (\d+) min"#, options: .regularExpression) else { return nil }
        return Int(text[range].components(separatedBy: CharacterSet.decimalDigits.inverted).joined())
    }

    // MARK: The route

    /// The legs list open on the MAP pane (it stays open).
    func openLegs() {
        showPane("map")
        if !element(prefix: "legRow.").exists { tap("map.legsToggle", timeout: 5) }
        _ = element(prefix: "legRow.").waitForExistence(timeout: 3)
    }

    /// "ETA 14:37" on the legs list's DEST line.
    func destinationETA() -> String? {
        openLegs()
        let e = element("legs.destinationETA")
        return e.waitForExistence(timeout: 3) ? e.label : nil
    }

    /// A row of the legs list: "next", "passed", "ahead", and whether it has a time over.
    func leg(_ index: Int) -> (state: String, hasATO: Bool)? {
        let e = element(prefix: "legRow.\(index).")
        guard e.exists else { return nil }
        let parts = e.identifier.split(separator: ".").map(String.init)
        return (parts.count > 2 ? parts[2] : "?", parts.last == "ato")
    }

    // MARK: After the flight

    /// END FLIGHT from the thumb bar (the last check) or from the Menu, confirmed.
    func endFlight() {
        let notTheButtons = NSPredicate(format: "label ==[c] 'END FLIGHT' AND NOT (identifier IN {'menu.endFlight', 'cockpit.endFlight'})")
        if element("cockpit.endFlight").exists {
            element("cockpit.endFlight").tap()
        } else {
            tap("cockpit.menu")
            tap("menu.endFlight")
        }
        // The alert's (thumb bar) or the confirmation dialog's (Menu) END FLIGHT.
        let confirm = app.buttons.matching(notTheButtons).firstMatch
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        dismissAfterFlightSheets()
    }

    /// The reconciliation review (keep as recorded) and the circuits' close-out, if either comes up.
    func dismissAfterFlightSheets() {
        _ = element("home.startFlight").waitForExistence(timeout: 8)
        for label in ["Keep as recorded", "Keep As Recorded", "Not now", "Later", "Done"] {
            let b = app.buttons[label]
            if b.exists && b.isHittable { b.tap() }
        }
    }

    /// The Logbook's newest flight, opened.
    @discardableResult
    func openNewestFlightInLogbook() -> Bool {
        let tab = app.buttons["Logbook"].firstMatch
        guard tab.waitForExistence(timeout: 10) else { return false }
        tab.tap()
        let row = element("logbook.flight")
        guard row.waitForExistence(timeout: 10) else { return false }
        row.tap()
        return true
    }

    // MARK: Development

    /// `TEST_RUNNER_REPLAY_STOP_AFTER=<step id>` stops a test after that step, to work on one part.
    func stopsAfter(_ step: String) -> Bool {
        ProcessInfo.processInfo.environment["REPLAY_STOP_AFTER"] == step
    }

    /// The accessibility tree as the test sees it, attached (to find an element).
    func dumpTree(_ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "tree-\(name)"
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }

    // MARK: The usual departure

    /// Before Departure, the pilot's way: its items CHECKed, then the thumb bar's NEXT, which reads
    /// READY FOR LINE UP there (6.2): it records the line-up, lets the replay go from the holding point
    /// and opens the LINE UP check. The one place that knows how the Cockpit asks for the line-up.
    /// Returns what NEXT read, and the check before departure's status once left.
    @discardableResult
    func readyForLineUp() -> (next: String, beforeDeparture: String?) {
        checkAllItems()
        let next = element("cockpit.next")
        let label = next.waitForExistence(timeout: 5) ? next.label : ""
        next.tap()
        if let hold = scenario.holds.first(where: { $0.until == "lineUp" }) { noteRelease(atTrack: hold.t) }
        _ = waitUntil(timeout: 4) { self.currentPhase == "lineUp" }
        return (label, phaseStatus("beforeDeparture"))
    }

    /// From Today to the runway: START FLIGHT (or CIRCUITS), the ground checks, ENGINE START (the replay
    /// starts), READY FOR LINE UP at the holding point, and LINE UP's one tap to the climb check.
    @discardableResult
    func departToClimb(circuits: Bool = false) -> Bool {
        guard startFlight(circuits ? "home.circuits" : "home.startFlight") else { return false }
        workChecks(until: "afterEngineStart")
        noteRelease(atTrack: 0)
        workChecks(until: "beforeDeparture")
        readyForLineUp()
        if memoryDone.waitForExistence(timeout: 3) { memoryDone.tap() }
        return waitUntil(timeout: 5) { self.currentPhase == "climb" }
    }

    /// Waits for the slot to come due on `check` (its words, "CLIMB CHECK") until the track reaches
    /// `track` (plus a margin), then taps it when `tap`.
    /// `notBefore`: not before the track reaches it (the climb check is amber from the line-up already).
    @discardableResult
    func slotDue(_ check: String, by track: Double, tap: Bool = true, margin: TimeInterval = 25,
                 notBefore: Double = 0) -> Slot? {
        let r = waitForSlot(timeout: wallUntil(track: track, margin: margin)) {
            ($0.tone == "due" || $0.tone == "owed") && $0.label.contains(check) && self.trackNow >= notBefore
        }
        if r.ok && tap { tapSlot() }
        return r.ok ? r.slot : nil
    }

    /// A list check opened from the slot, worked through, back on the map.
    func doListCheckFromSlot(_ check: String, by track: Double) {
        guard slotDue(check, by: track) != nil else { return }
        _ = waitUntil(timeout: 4) { self.paneShown == "checklist" }
        checkAllItems()
        _ = waitUntil(timeout: 4) { self.paneShown == "map" }
    }

    /// From the cruise check done to the landing check: FREDA confirmed when due (or left alone), the
    /// descent and approach checks from the slot as they come, then on to the landing check.
    func flyCruiseToLanding(confirmFreda: Bool) {
        let s = scenario
        let end = s.mark("touchdown")
        var descended = false
        _ = waitUntil(timeout: wallUntil(track: end, margin: 30)) {
            guard let slot = self.slot else { return self.currentPhase == "landing" || self.landedCardTitle != nil }
            if slot.action == "confirmFreda" && confirmFreda { self.tapSlot() }
            if slot.label.contains("DESCENT CHECK") && slot.tone != "idle" { self.tapSlot(); descended = true }
            if slot.label.contains("APPROACH CHECK") && slot.tone != "idle" && descended { self.tapSlot() }
            if slot.action == "goToLanding" { self.tapSlot(); return true }
            return self.currentPhase == "landing" || self.landedCardTitle != nil
        }
    }

    /// The flight page's checks section, scrolled to and opened ("Show each check").
    func revealChecks() {
        for _ in 0..<6 {
            if app.staticTexts["CHECKS"].exists && app.staticTexts["CHECKS"].isHittable { break }
            app.swipeUp()
        }
        let each = app.buttons["Show each check"]
        if each.exists { each.tap() }
        app.swipeUp()
    }

    // MARK: Recording

    /// A screenshot, kept with the result: "<page>-<step>-<short>".
    @discardableResult
    func shot(_ step: String, _ short: String) -> String {
        let name = "\(page)-\(step)-\(short)"
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
        if let i = steps.firstIndex(where: { $0.id == step }) {
            steps[i].screenshots.append(name)
        } else {
            steps.append(StepResult(id: step, status: .observed, notes: [], screenshots: [name]))
        }
        return name
    }

    /// Records `step` as passed or failed on `condition`, with what was seen; a failure fails the test
    /// too, without stopping it.
    func check(_ step: String, _ condition: Bool, _ note: @autoclosure () -> String,
               file: StaticString = #filePath, line: UInt = #line) {
        let text = note()
        record(step, condition ? .pass : .fail, text)
        if !condition { XCTFail("\(step): \(text)", file: file, line: line) }
    }

    /// What only a person can judge from the screenshot: never a pass.
    func observed(_ step: String, _ note: String) {
        record(step, .observed, note)
    }

    private func record(_ step: String, _ status: StepResult.Status, _ note: String) {
        if let i = steps.firstIndex(where: { $0.id == step }) {
            steps[i].notes.append("\(status.rawValue): \(note)")
        } else {
            steps.append(StepResult(id: step, status: status, notes: ["\(status.rawValue): \(note)"], screenshots: []))
        }
        // A step is as good as its weakest part: one failed assertion fails it, one part only a person can
        // judge leaves it observed, and it passes when everything in it was asserted.
        let i = steps.firstIndex { $0.id == step }!
        let kinds = steps[i].notes.compactMap { $0.split(separator: ":").first.map(String.init) }
        steps[i].status = kinds.contains("fail") ? .fail : kinds.contains("observed") ? .observed : .pass
    }

    /// The step records, attached for the runner (results.json). Call at the end of the test (defer).
    func attachResults(testName: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(StepsFile(test: testName, scenario: scenario.name, page: page,
                                                       harness: launchNotes, steps: steps)) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "steps-\(testName)"
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }

    struct StepsFile: Codable {
        let test: String
        let scenario: String
        let page: String
        let harness: [String]
        let steps: [StepResult]
    }
}
