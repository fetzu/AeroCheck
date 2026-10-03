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
        dismissSystemAlerts()
        guard tap(button, timeout: 30) else {
            shot("setup", "no-start-button")
            dumpTree("no-start-button")
            return false
        }
        // A flight planned for today with its preparation open asks first: started anyway, as a pilot
        // who prepared on paper would.
        let anyway = app.buttons["Start anyway"]
        if anyway.waitForExistence(timeout: 3) { tapNow(anyway) }
        if element("cockpit.check").waitForExistence(timeout: 20) { return true }
        // A start refused while GPS warms up says so in an alert: once more.
        let ok = app.alerts.buttons.firstMatch
        if tapNow(ok) { tap(button, timeout: 5) }
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

    /// The element as it is now, in one query, or nil when it isn't there. Every read goes through it:
    /// `exists` then `label` is two queries, and a toast or a card gone between them fails the test
    /// ("Failed to get matching snapshot").
    func snap(_ e: XCUIElement) -> XCUIElementSnapshot? {
        try? e.snapshot()
    }

    func snap(_ identifier: String) -> XCUIElementSnapshot? {
        snap(element(identifier))
    }

    /// The label of `identifier`, if it is on screen.
    func label(_ identifier: String) -> String? {
        snap(identifier)?.label
    }

    /// Whatever is on screen, in one query, in reading order: for reads over many elements (the phase
    /// bar, the Flight Log's tables), where a query per element is seconds of flight at 10x.
    func screen() -> [XCUIElementSnapshot] {
        guard let root = snap(app) else { return [] }
        var out: [XCUIElementSnapshot] = []
        func walk(_ s: XCUIElementSnapshot) {
            out.append(s)
            s.children.forEach(walk)
        }
        walk(root)
        return out
    }

    @discardableResult
    func waitFor(_ identifier: String, timeout: TimeInterval = 10) -> XCUIElement? {
        let e = element(identifier)
        return e.waitForExistence(timeout: timeout) ? e : nil
    }

    /// Taps the element where it is now, if it is there: false when it isn't. A tap on an element gone
    /// since the last look (the toast's UNDO after six seconds, NEXT when the phase moved on) would fail
    /// the test, so the tap goes to the point it was seen at. Off screen (a row scrolled away), the
    /// usual tap, which scrolls it into view.
    @discardableResult
    func tapNow(_ e: XCUIElement) -> Bool {
        guard let s = snap(e), !s.frame.isEmpty else { return false }
        let centre = CGPoint(x: s.frame.midX, y: s.frame.midY)
        if windowFrame.contains(centre) {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: centre.x, dy: centre.y)).tap()
        } else {
            e.tap()
        }
        return true
    }

    /// The app's window, read once it can be (a test never turns the device).
    private var windowFrameRead: CGRect?
    private var windowFrame: CGRect {
        if let windowFrameRead { return windowFrameRead }
        guard let frame = snap(app)?.frame, !frame.isEmpty else { return .zero }
        windowFrameRead = frame
        return frame
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

    /// Taps `identifier` once it exists. False when it never came (or went before the tap).
    @discardableResult
    func tap(_ identifier: String, timeout: TimeInterval = 10) -> Bool {
        guard let e = waitFor(identifier, timeout: timeout) else { return false }
        return tapNow(e)
    }

    /// Holds a hold-to-confirm button (1 s) down.
    @discardableResult
    func hold(_ identifier: String, seconds: TimeInterval = 1.6, timeout: TimeInterval = 10) -> Bool {
        guard let e = waitFor(identifier, timeout: timeout), let s = snap(e) else { return false }
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: s.frame.midX, dy: s.frame.midY)).press(forDuration: seconds)
        return true
    }

    // MARK: The check slot and the phase bar

    struct Slot: CustomStringConvertible {
        let tone: String
        let action: String
        let label: String
        var description: String { "\(tone)/\(action) \"\(label)\"" }
    }

    /// The check slot, as drawn now: tone and action from its identifier, its words. It is the act band's
    /// first slot on MAP, and on CHECKLIST outside the engine phases and cruise (6.2): one band, one slot.
    var slot: Slot? {
        guard let e = snap(element(prefix: "checkSlot.")) else { return nil }
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
        snap("phaseBar.\(phase)")?.value as? String
    }

    /// The phase the Cockpit is on: the selected segment.
    var currentPhase: String? {
        let segments = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'phaseBar.' AND selected == true"))
        return snap(segments.firstMatch).map { String($0.identifier.dropFirst("phaseBar.".count)) }
    }

    /// The page CHECKLIST · MAP · ROUTE shows. One query: at 10x every query is flight time.
    var paneShown: String? {
        let e = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pane.' AND selected == true")).firstMatch
        return snap(e).map { String($0.identifier.dropFirst("pane.".count)) }
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
        let b = app.buttons.matching(NSPredicate(format: "label IN {'Skip', 'SKIP', 'Cancel'}")).firstMatch
        if let s = snap(b), s.isEnabled { tapNow(b) }
    }

    /// CHECK through the current list (at most `max` items), until CHECK gives way. One query a CHECK:
    /// under load each is up to a few seconds, tens of seconds of flight at 10x.
    func checkAllItems(max: Int = 30) {
        showPane("checklist")
        skipHourMeterIfAsked()
        for _ in 0..<max {
            guard tapNow(element("cockpit.check")) else { return }
        }
    }

    /// The current check done, the pilot's usual way: its list CHECKed, or a memory check confirmed
    /// (which, by the act band's one tap, also goes on). Then NEXT when it shows. Returns the phase it
    /// left, as the phase bar said.
    @discardableResult
    func completeCurrentCheckAndGoOn() -> String? {
        let from = currentPhase
        skipHourMeterIfAsked()
        showPane("checklist")
        if tapNow(element("cockpit.memoryDone")) {
            // The one tap goes on, unless it only confirms (the phase's own action, the last check).
            waitUntil(timeout: 3) { self.currentPhase != from || self.snap("cockpit.next") != nil }
            if currentPhase == from { tapNow(element("cockpit.next")) }
        } else {
            checkAllItems()
            if element("cockpit.next").waitForExistence(timeout: 3) { tapNow(element("cockpit.next")) }
        }
        waitUntil(timeout: 5) { self.currentPhase != from }
        return from
    }

    /// Works the checks up to (not including) `phase`, pressing ENGINE START (when `pressEngineStart`) and
    /// ENGINE SHUTDOWN on the way. At the check before departure its NEXT is READY FOR LINE UP (6.2).
    func workChecks(until phase: String, pressEngineStart: Bool = true, maxSteps: Int = 16) {
        func notRecorded(_ identifier: String) -> Bool {
            guard let s = snap(identifier) else { return false }
            return (s.value as? String)?.lowercased().contains("not recorded") ?? true
        }
        for _ in 0..<maxSteps {
            skipHourMeterIfAsked()
            guard let current = currentPhase, current != phase else { return }
            if current == "engineStart", pressEngineStart, notRecorded("cockpit.engineStart") {
                tap("cockpit.engineStart", timeout: 1)
                skipHourMeterIfAsked()
            }
            if current == "shutdown", notRecorded("cockpit.engineShutdown") {
                checkAllItems()
                tap("cockpit.engineShutdown", timeout: 1)
                skipHourMeterIfAsked()
            }
            completeCurrentCheckAndGoOn()
        }
    }

    // MARK: What the Cockpit shows

    var memoryDone: XCUIElement { element("cockpit.memoryDone") }
    var undo: XCUIElement { element("undoToast.undo") }
    var toastMessage: String? {
        label("undoToast.message")
    }

    /// The phase bar, segment by segment: phase → its spoken status.
    func phaseBar() -> [String: String] {
        var out: [String: String] = [:]
        for s in screen() where s.identifier.hasPrefix("phaseBar.") {
            out[String(s.identifier.dropFirst("phaseBar.".count))] = (s.value as? String) ?? ""
        }
        return out
    }

    /// The strip's altitude, feet (nil when not shown or no GPS).
    var altitudeFeet: Int? {
        let e = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Altitude'")).firstMatch
        guard let value = snap(e)?.value as? String else { return nil }
        return Int(value.components(separatedBy: CharacterSet.decimalDigits.inverted).joined())
    }

    /// The landed card's title ("LANDED · LSGC · 14:37"), when it is up.
    var landedCardTitle: String? {
        label("landedCard.title")
    }

    /// A tap on the backdrop, away from any button: the top left corner, under the status bar.
    func tapBeside() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.06)).tap()
    }

    /// The text of every static text on screen containing `fragment`.
    func texts(containing fragment: String) -> [String] {
        screen().filter { $0.elementType == .staticText && $0.label.contains(fragment) }.map(\.label)
    }

    /// The check slot's one tap, on the MAP page (on CHECKLIST it brings the current item into view).
    func tapSlot() {
        showPane("map")
        let e = element(prefix: "checkSlot.")
        if e.waitForExistence(timeout: 5) { tapNow(e) }
    }

    /// "FREDA in 6 min" → 6. The figure and "min" are held together by a no-break space (6.2).
    static func minutes(in text: String) -> Int? {
        guard let range = text.range(of: #"in (\d+)\s+min"#, options: .regularExpression) else { return nil }
        return Int(text[range].components(separatedBy: CharacterSet.decimalDigits.inverted).joined())
    }

    // MARK: The route

    /// The legs list: the ROUTE page (6.2; until then the MAP pane's legs panel). It stays there.
    func openLegs() {
        showPane("route")
        _ = element(prefix: "legRow.").waitForExistence(timeout: 3)
    }

    /// The plan's ETO over the destination ("14:37"), as the Flight Log's DEST ETO: the value of
    /// ROUTE's DEST line, whose own figures are live since 6.2. (Until then the legs list's "ETA 14:37".)
    func destinationETA() -> String? {
        openLegs()
        let e = element("dest.line")
        guard e.waitForExistence(timeout: 3), let value = snap(e)?.value as? String, !value.isEmpty else { return nil }
        return value
    }

    /// A row of the legs list: "next", "passed", "ahead", and whether it has a time over.
    func leg(_ index: Int) -> (state: String, hasATO: Bool)? {
        guard let e = snap(element(prefix: "legRow.\(index).")) else { return nil }
        let parts = e.identifier.split(separator: ".").map(String.init)
        return (parts.count > 2 ? parts[2] : "?", parts.last == "ato")
    }

    // MARK: After the flight

    /// END FLIGHT from the act band (the last check) or from the Menu, confirmed.
    func endFlight() {
        let notTheButtons = NSPredicate(format: "label ==[c] 'END FLIGHT' AND NOT (identifier IN {'menu.endFlight', 'cockpit.endFlight'})")
        if !tapNow(element("cockpit.endFlight")) {
            tap("cockpit.menu")
            tap("menu.endFlight")
        }
        // The alert's (act band) or the confirmation dialog's (Menu) END FLIGHT.
        let confirm = app.buttons.matching(notTheButtons).firstMatch
        if confirm.waitForExistence(timeout: 5) { tapNow(confirm) }
        dismissAfterFlightSheets()
    }

    /// ABANDON FLIGHT: the aircraft's name in the Cockpit's header held 1.5 s, then the alert's
    /// Abandon Flight. True when the Cockpit gave way to Today.
    @discardableResult
    func abandonFlight(registration: String = "F-HVXA") -> Bool {
        showPane("checklist")
        let name = app.staticTexts[registration].firstMatch
        guard name.waitForExistence(timeout: 5), let s = snap(name) else { return false }
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: s.frame.midX, dy: s.frame.midY)).press(forDuration: 2.2)
        let abandon = app.alerts.buttons["Abandon Flight"].firstMatch
        guard abandon.waitForExistence(timeout: 5) else { return false }
        abandon.tap()
        return element("home.startFlight").waitForExistence(timeout: 10)
    }

    /// Today's card for the route on the map ("ON THE MAP", its route), when one is armed.
    var armedRouteOnToday: String? {
        // The card is one button: "Flight plan, ON THE MAP, LSGN → LSZQ, …".
        screen().first { $0.label.contains("ON THE MAP") }?.label
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

    /// One row of the flight page's PLAN vs ACTUAL: the waypoint, its ETO and ATO ("—" when none).
    struct PlanRow: CustomStringConvertible {
        let name: String
        let eto: String
        let ato: String
        var description: String { "\(name) ETO \(eto) ATO \(ato)" }
    }

    /// The flight page's PLAN vs ACTUAL, read in one query (empty when the page has none).
    func planVsActual() -> [PlanRow] {
        let texts = screen().filter { $0.elementType == .staticText }.map(\.label)
        guard let start = texts.firstIndex(of: "PLAN vs ACTUAL"),
              let header = texts[start...].firstIndex(of: "Δ") else { return [] }
        let time = #"^(\d{1,2}:\d\d|—)$"#
        let delta = #"^([+-]?\d+:\d\d|—)$"#
        var rows: [PlanRow] = []
        var i = header + 1
        while i + 3 < texts.count, texts[i + 1].range(of: time, options: .regularExpression) != nil,
              texts[i + 2].range(of: time, options: .regularExpression) != nil,
              texts[i + 3].range(of: delta, options: .regularExpression) != nil {
            rows.append(PlanRow(name: texts[i], eto: texts[i + 1], ato: texts[i + 2]))
            i += 4
        }
        return rows
    }

    /// A time of the flight page's TIMELINE ("Take-off", "Landing"), as shown.
    func timelineTime(_ label: String) -> String? {
        let texts = screen().filter { $0.elementType == .staticText }.map(\.label)
        guard let i = texts.firstIndex(of: label), i + 1 < texts.count else { return nil }
        return texts[i + 1]
    }

    /// Scrolls the page until the static text `label` is on screen (at most `swipes` swipes).
    func scrollTo(_ label: String, swipes: Int = 8) {
        let text = app.staticTexts[label].firstMatch
        let height = snap(app)?.frame.height ?? 1000
        // By its frame: a SwiftUI scroll view's rows below the fold still say they are hittable. Dragged
        // along the left margin, not swiped in the middle, where the flight page's track map takes the
        // gesture and pans instead.
        for _ in 0..<swipes {
            guard let frame = snap(text)?.frame else { return }
            if frame.minY > 80 && frame.minY < height * 0.45 { return }
            let up = frame.minY > 80
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.012, dy: up ? 0.8 : 0.3))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.012, dy: up ? 0.35 : 0.75))
            from.press(forDuration: 0.05, thenDragTo: to)
        }
    }

    /// Minutes from "hh:mm" `a` to `b` (nil when either is not a time).
    static func minutes(from a: String, to b: String) -> Int? {
        func value(_ s: String) -> Int? {
            let parts = s.split(separator: ":").compactMap { Int($0) }
            return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
        }
        guard let x = value(a), let y = value(b) else { return nil }
        return ((y - x) % 1440 + 1440 + 720) % 1440 - 720
    }

    // MARK: Development

    /// `TEST_RUNNER_REPLAY_STOP_AFTER=<step id>` stops a test after that step, to work on one part.
    func stopsAfter(_ step: String) -> Bool {
        ProcessInfo.processInfo.environment["REPLAY_STOP_AFTER"] == step
    }

    /// The accessibility tree as the test sees it, attached (to find an element).
    func dumpTree(_ name: String) {
        // The tree, and each element's attributes (its traits among them), for what a person reads off it.
        let attributes = screen().filter { !$0.label.isEmpty }
            .map { "\($0.elementType.rawValue) \"\($0.label)\" \($0.dictionaryRepresentation.filter { "\($0.key)".lowercased().contains("trait") })" }
        let attachment = XCTAttachment(string: app.debugDescription + "\n\n" + attributes.joined(separator: "\n"))
        attachment.name = "tree-\(name)"
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }

    // MARK: The usual departure

    /// Before Departure, the pilot's way: its items CHECKed, then the act band's NEXT, which reads
    /// READY FOR LINE UP there (6.2): it records the line-up, lets the replay go from the holding point
    /// and opens the LINE UP check. The one place that knows how the Cockpit asks for the line-up.
    /// Returns what NEXT read, and the check before departure's status once left.
    @discardableResult
    func readyForLineUp() -> (next: String, beforeDeparture: String?) {
        checkAllItems()
        let next = element("cockpit.next")
        let label = next.waitForExistence(timeout: 5) ? (snap(next)?.label ?? "") : ""
        tapNow(next)
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
        if memoryDone.waitForExistence(timeout: 3) { tapNow(memoryDone) }
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
        _ = app.staticTexts["CHECKS"].waitForExistence(timeout: 5)
        scrollTo("CHECKS")
        let each = app.buttons["Show each check"]
        tapNow(each)
        scrollTo("CHECKS")
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

    /// A screenshot taken for another step that shows this one too.
    func cite(_ step: String, _ screenshot: String) {
        if let i = steps.firstIndex(where: { $0.id == step }) {
            steps[i].screenshots.append(screenshot)
        } else {
            steps.append(StepResult(id: step, status: .observed, notes: [], screenshots: [screenshot]))
        }
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
