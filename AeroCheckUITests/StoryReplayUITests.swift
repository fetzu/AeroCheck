import XCTest

/// The website's story page (/flight): one flight flown through the Cockpit, stopped at each of its frames. The scenario
/// is made outside this repository (`story`, a recorded flight), so the test skips without it. At each `frame:<id>` hold
/// the clock stands still until the test lets it go (`GroundReplayFrames`), so a frame is set up and taken at leisure at
/// any rate. It writes `<n>-<key>.want` into the capture's folder and waits for the host's `.done`.
final class StoryReplayUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    func testTheFlightStory() throws {
        let pilot = try CockpitPilot.onDeviceData(self, scenario: "story", page: "story")
        defer { pilot.attachResults(testName: name) }
        guard let path = ProcessInfo.processInfo.environment["AEROCHECK_APP_REPLAY_FRAMES"], !path.isEmpty else {
            throw XCTSkip("no capture folder: TEST_RUNNER_AEROCHECK_APP_REPLAY_FRAMES")
        }
        let frames = StoryFrames(folder: URL(fileURLWithPath: path, isDirectory: true), pilot: pilot)
        pilot.extraLaunchArguments = ["-map.selectedLayer", "ICAO Chart"]
        pilot.hourMeterReadings = ["4573", "4574.9"]
        pilot.launch(memoryTest: false)

        // The evening before, and the morning: the flight's page, its route.
        pilot.check("story-1", frames.openTheFlight("LSZQ"), "the flight's page from Today")
        // The pencil's menu, then Edit route: once more if the editor didn't come (a tap while the menu still opens).
        var editor = false
        for _ in 0..<3 where !editor {
            pilot.tap("thread.editMenu", timeout: 10)
            let route = pilot.app.buttons["Edit route"].firstMatch
            guard route.waitForExistence(timeout: 5) else { continue }
            Thread.sleep(forTimeInterval: 0.8)
            route.tap()
            editor = pilot.app.buttons["Close"].firstMatch.waitForExistence(timeout: 5)
                && !pilot.app.buttons["Edit route"].firstMatch.exists
        }
        pilot.check("story-1", editor, "the route editor, from the pencil's menu")
        frames.take("route", after: 3)
        pilot.tapNow(pilot.app.buttons["Close"].firstMatch)
        frames.take("prepare", after: 2)
        pilot.tapNow(pilot.app.buttons["Close"].firstMatch)

        // The ground, a person's pace: the scenario's holds keep the clock at 1x here.
        guard pilot.startFlight() else { return XCTFail("no Cockpit") }
        pilot.workChecks(until: "afterEngineStart")
        pilot.workChecks(until: "beforeDeparture")
        pilot.readyForLineUp()

        // On the runway: the line-up check done, AFTER TAKE-OFF on the button.
        frames.stop(at: "lineup") {
            pilot.checkAllItems()
            pilot.confirmMemoryCheck(timeout: 1)
            pilot.check("story-3", pilot.waitFor("cockpit.afterTakeoff", timeout: 5) != nil, "AFTER TAKE-OFF on the runway")
            frames.take("lineup")
        }
        frames.stop(at: "climb") {
            pilot.check("story-4", pilot.tap("cockpit.next", timeout: 5), "NEXT once airborne")
            _ = pilot.waitUntil(timeout: 5) { pilot.currentPhase == "climb" }
            pilot.checkAllItems()
        }
        // BENOT a minute ahead: the cruise check open, Bern's tower taken when it is due.
        frames.stop(at: "cruise") {
            pilot.showPane("checklist")
            pilot.tap("cockpit.next", timeout: 5)
            _ = pilot.waitUntil(timeout: 5) { pilot.currentPhase == "cruise" }
            pilot.showPane("checklist")
            pilot.observed("story-5", "NOW \(pilot.label("read.now") ?? "?"), NEXT \(pilot.label("read.next") ?? "?")")
            for _ in 0..<2 where !(pilot.label("read.now") ?? "").contains("LSZB") {
                pilot.tap("read.next", timeout: 2)
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        frames.stop(at: "automark") {
            pilot.check("story-5", pilot.undo.waitForExistence(timeout: 5),
                        "UNDO over BENOT's mark: \(pilot.toastMessage ?? "no toast")")
            // UNDO has six seconds on the wall: one screenshot, at once.
            frames.take("automark", after: 0.6, still: false)
            pilot.checkAllItems()
        }
        // Towards the Julier, on the National Map (the hold chose it).
        frames.stop(at: "alps") {
            pilot.showPane("map")
            for _ in 0..<2 { pilot.tap("map.zoomOut", timeout: 3) }
            pilot.observed("story-6", "the slot: \(pilot.mapStatus.map { "\($0.state) \"\($0.label)\"" } ?? "dark")")
            frames.take("alps", after: 3)
        }
        frames.stop(at: "descent") {
            pilot.tap("read.next", timeout: 2)
            if pilot.slot?.label.contains("DESCENT") == true {
                pilot.tapSlot()
                _ = pilot.waitUntil(timeout: 4) { pilot.paneShown == "checklist" }
                pilot.checkAllItems()
            }
        }
        // W ahead, on the Atlas, close in: Samedan's patterns.
        frames.stop(at: "approach") {
            pilot.showPane("map")
            pilot.tap("map.zoomIn", timeout: 3)
            pilot.observed("story-7", "the slot: \(pilot.slot.map { "\($0)" } ?? "none")")
            frames.take("approach", after: 3)
            pilot.tapSlot()
            _ = pilot.waitUntil(timeout: 4) { pilot.paneShown == "checklist" }
            pilot.checkAllItems()
        }
        frames.stop(at: "final") {
            pilot.observed("story-8", "the slot on final: \(pilot.slot.map { "\($0)" } ?? "none")")
            pilot.tapSlot()
            _ = pilot.waitUntil(timeout: 4) { pilot.paneShown == "checklist" }
            pilot.checkAllItems()
        }
        // Parked at Samedan: the last checks, ENGINE SHUTDOWN and its reading, END FLIGHT.
        frames.stop(at: "parked") {
            pilot.workChecks(until: "hangar")
            pilot.skipHourMeterIfAsked()
            pilot.checkAllItems()
            pilot.endFlight()
        }

        pilot.check("story-9", frames.openTheFlight("LSZQ"), "the flight's page in close-out")
        frames.take("closeout", after: 2)
        pilot.tapNow(pilot.app.buttons.matching(NSPredicate(format: "label ==[c] 'Mark closed'")).firstMatch)
        let finish = pilot.app.buttons.matching(NSPredicate(format: "label ==[c] 'Finish'")).firstMatch
        if finish.waitForExistence(timeout: 5) { finish.tap() }
        _ = pilot.waitUntil(timeout: 5) { pilot.snap("flightPage.status") == nil }
        pilot.check("story-10", pilot.openNewestFlightInLogbook(), "the flight in the logbook")
        frames.take("log", after: 3)
    }
}

/// A capture's side of the folder it shares with the replay and the host.
private final class StoryFrames {
    let folder: URL
    let pilot: CockpitPilot
    private var count = 0

    init(folder: URL, pilot: CockpitPilot) {
        self.folder = folder
        self.pilot = pilot
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    private func touch(_ name: String) {
        FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data())
    }

    /// Today's next flight card, by its route's words, opened.
    func openTheFlight(_ word: String) -> Bool {
        pilot.dismissSystemAlerts()
        let card = pilot.app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND NOT (identifier == 'home.startFlight')", word)).firstMatch
        guard card.waitForExistence(timeout: 15) else {
            pilot.dumpTree("no-flight-card")
            return false
        }
        pilot.tapNow(card)
        return pilot.waitFor("flightPage.status", timeout: 10) != nil
    }

    /// Waits for the replay to stand at `id`, does `work`, lets it go.
    func stop(at id: String, timeout: TimeInterval = 360, _ work: () -> Void) {
        let held = pilot.waitUntil(timeout: timeout) { self.exists("\(id).held") }
        pilot.check("frame-\(id)", held, "the replay stood at \(id)")
        if held { work() }
        touch("\(id).go")
    }

    /// The host's screenshot of what is on screen, `after` seconds from now. It retakes until the screen is still.
    func take(_ key: String, after seconds: TimeInterval = 0.5, still: Bool = true) {
        Thread.sleep(forTimeInterval: seconds)
        count += 1
        let name = "\(count)-\(key)"
        FileManager.default.createFile(atPath: folder.appendingPathComponent("\(name).want").path,
                                       contents: still ? Data() : Data("once".utf8))
        let done = pilot.waitUntil(timeout: 60) { self.exists("\(name).done") }
        pilot.check("frame-\(key)", done, "the host took \(name)")
    }
}
