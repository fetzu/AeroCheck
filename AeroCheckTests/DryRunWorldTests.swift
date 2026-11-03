import XCTest
import CoreLocation
import UserNotifications
@testable import AeroCheck

/// The dry run's world (6.4.0): a dry run flown end to end without a trace outside its own folder and suite,
/// the census of every call that leaves the app, the pilot's answers to the generator, and the app's guards.
@MainActor
final class DryRunWorldTests: XCTestCase {

    override func tearDown() {
        FlightClock.endVirtual()
        super.tearDown()
    }

    // MARK: - End to end, headless

    /// Circuits at LSZQ flown in a world, the pilot doing what the Cockpit's buttons do: the flight recorded,
    /// its full stop seen, its logbook line written, all in the world; then nothing of it left anywhere.
    func testADryRunFliesInItsWorldAndLeavesNothingBehind() async throws {
        let notificationsBefore = Set(await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier))
        let standardBefore = Set(UserDefaults.standard.dictionaryRepresentation().keys)

        let base = makeTestDirectory()
        let airports = AirportDataService(openAIPAirports: makeTestOpenAIPAirportLayer { _ in [] },
                                          rootDirectory: makeTestDirectory())
        airports.injectForReplay([DryRunAerodrome.lszq.airport])
        var settings = AppSettings()
        settings.enableCompanionMode = true
        let world = DryRunWorld(settings: settings, base: base)
        let session = DryRunSession(world: world, setup: DryRunSetup(mission: .circuits(.lszq), rate: 0), seed: 7)
        let appState = world.appState
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        // Confined, so off CloudKit, the Live Activity and the EET learning, by construction.
        let parts = Dictionary(Mirror(reflecting: appState).children.compactMap { child in
            child.label.map { ($0, child.value) }
        }, uniquingKeysWith: { first, _ in first })
        for label in ["syncManager", "liveActivity"] {
            let value = try XCTUnwrap(parts[label], "AppState has no \(label) any more: update this test")
            XCTAssertTrue("\(value)" == "nil", "\(label) is set on the world's AppState")
        }
        XCTAssertNil(appState.eetCalibration)
        XCTAssertFalse(appState.settings.enableCompanionMode, "Companion off in a dry run (D8)")

        XCTAssertTrue(session.begin(airports: airports, now: start))
        XCTAssertTrue(appState.isFlightActive)
        XCTAssertTrue(world.location.isTracking)
        XCTAssertEqual(FlightClock.now, start, "a dry run at rate 0 stands still")

        // One second of the dry run at a time, the clock pinned there, as its timer would feed it.
        var seconds = 0
        func wait(_ count: Int) {
            for _ in 0..<count {
                seconds += 1
                FlightClock.virtual = FlightClock.Virtual(wallAnchor: Date(),
                                                          virtualAnchor: start.addingTimeInterval(TimeInterval(seconds)),
                                                          rate: 0)
                session.feedDueFixes(upTo: FlightClock.now)
            }
        }
        func fly(until done: () -> Bool, within limit: Int, _ what: String) {
            for _ in 0..<limit where !done() { wait(1) }
            XCTAssertTrue(done(), "\(what), within \(limit) s")
        }

        wait(20)
        XCTAssertNil(session.generator.mark("lineUp"), "it waits for ENGINE START")
        appState.recordEngineStart()
        wait(280)
        XCTAssertNil(session.generator.mark("lineUp"), "it waits for READY FOR LINE UP")
        appState.goToPhase(.beforeDeparture)
        appState.nextPhase()
        XCTAssertEqual(appState.currentPhase, .lineUp)
        fly(until: { session.generator.waitingAt == .takeoff }, within: 120, "lined up")
        wait(30)
        XCTAssertNil(session.generator.mark("takeoffRoll"), "it waits for the line up check")
        DryRunCoach.workThroughCurrentCheck(appState)
        fly(until: { session.generator.mark("touchdown") != nil }, within: 1800, "round the circuit")
        appState.goToPhase(.afterLanding)
        fly(until: { session.generator.mark("stopped") != nil }, within: 120, "stopped on the runway")
        wait(60)
        XCTAssertNil(session.generator.mark("vacated"), "after the landing check, the pilot decides")
        XCTAssertTrue(world.detector.emittedEvents.contains { $0.type == .fullStop && $0.airportIdent == "LSZQ" },
                      "the full stop seen on the runway: \(world.detector.emittedEvents)")
        appState.goToPhase(.shutdown)
        fly(until: { session.generator.isParkedForGood }, within: 600, "parked")
        wait(60)

        XCTAssertGreaterThan(appState.currentFlight?.gpsTrack.count ?? 0, 100)
        XCTAssertEqual(appState.currentFlight?.departureAirportIdent, "LSZQ")
        XCTAssertEqual(world.detector.takeoffTimes.count, 1)

        // END FLIGHT, as the Cockpit does it: the logbook line goes to the world's store.
        appState.recordEngineShutdown()
        world.location.stopTracking()
        appState.endFlight()
        XCTAssertEqual(appState.flights.count, 1)
        let written = FileManager.default.enumerator(at: world.root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.path.contains("/Flights/") && $0.pathExtension == "json" } ?? []
        XCTAssertEqual(written.count, 1, "the flight in the world's folder")

        session.end()
        XCTAssertTrue(session.hasEnded)
        XCTAssertNil(FlightClock.virtual, "the wall clock back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.root.path), "the world's folder gone")
        XCTAssertTrue(UserDefaults.standard.persistentDomain(forName: world.suiteName)?.isEmpty ?? true,
                      "the world's suite gone")
        XCTAssertEqual(Set(UserDefaults.standard.dictionaryRepresentation().keys).subtracting(standardBefore), [],
                       "nothing added to the app's own defaults")
        let notificationsAfter = Set(await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier))
        XCTAssertEqual(notificationsAfter.subtracting(notificationsBefore), [], "nothing scheduled")
    }

    // MARK: - The census

    /// Every call in the app of an API that leaves it, or that reaches the app's own state rather than a
    /// flight's: the notifications, the Watch, the widget, the Live Activity, CloudKit, the app's datastore and
    /// defaults, the Companion, the device's GPS and barometer. Each with the rule that keeps a dry run out of
    /// it. A new call fails this test until it has one: say here why a dry run never reaches it, or make it so.
    /// (Comments don't count.)
    func testEveryCallThatLeavesTheAppHasItsDryRunRule() throws {
        let census: [String: [String: (count: Int, rule: String)]] = [
            "AeroCheckApp.swift": [
                "AircraftRequestStore.shared": (3, "the app's polls, which wait during a dry run"),
                "CompanionConnectivityManager.shared": (1, "the app's manager; the world has an inert one"),
                "EETCalibrationStore.shared": (3, "the app's store, following the app's AppState only"),
                "FlightActivityController.shared": (2, "the app's Live Activity; the world's AppState has none"),
                "NotificationService.shared": (10, "the app's handlers: a reminder tapped waits for the dry run's end, banners are held as in flight"),
                "WatchConnectivityManager.shared": (1, "the app's Watch, fed by the app's AppState only"),
            ],
            "Models/AppState.swift": [
                "DataPersistenceManager.shared": (1, "the default; the world's AppState is on its own datastore"),
                "EETCalibrationStore.shared": (1, "only on the app's datastore, never a confined one"),
                "FlightActivityController.shared": (1, "only on the app's datastore, never a confined one"),
                "SyncManager.shared": (1, "only on the app's datastore, never a confined one"),
            ],
            "Models/FlightPlanManager.swift": [
                "DataPersistenceManager.shared": (1, "the default; the world passes its own"),
            ],
            "Models/AerodromeNoteStore.swift": [
                "DataPersistenceManager.shared": (1, "the default; the pilot's own notes, which a dry run neither shows nor writes"),
            ],
            "Models/FlightThreadManager.swift": [
                "DataPersistenceManager.shared": (1, "the default; the world passes its own"),
                "NotificationService.shared": (1, "the default; the world's manager is given `.inert()`, which schedules nothing"),
            ],
            "Services/AircraftRequests.swift": ["DataPersistenceManager.shared": (1, "the Aircraft tab, never under a dry run")],
            "Services/AirfieldTariffService.swift": ["DataPersistenceManager.shared": (1, "a cache of the server's tariffs, every flight's")],
            "Services/BarometricAltitudeService.swift": ["CMAltimeter()": (1, "started by a real flight's tracking only (D3)")],
            "Services/DataPersistenceManager.swift": ["UserDefaults.standard": (2, "the app's store; the world's is confined")],
            "Services/DryRunSession.swift": ["UserDefaults.standard": (2, "the app's own flags that the guided flight and the first flight were flown (Today's cards), never the world's")],
            "Views/DryRunGuidedViews.swift": ["@AppStorage": (3, "Today's card: the app's own flags, read on the ground, never by the world")],
            "Views/GettingStartedCard.swift": ["@AppStorage": (5, "Today's Getting started card, the app's own flags; not on a dry run's Today")],
            "Views/Settings/AboutSettingsView.swift": [
                "@AppStorage": (1, "the tips' reset, the app's own flag; Settings, never under a dry run"),
                "UserDefaults.standard": (1, "the tips' reset, the app's own flag; Settings, never under a dry run"),
            ],
            "Services/BriefingRegistryService.swift": ["DataPersistenceManager.shared": (1, "a cache of public data, every flight's")],
            "Services/FISAreaService.swift": ["DataPersistenceManager.shared": (1, "a cache of public data, every flight's")],
            "Services/NASRPatternService.swift": ["DataPersistenceManager.shared": (1, "a cache of public data, every flight's")],
            "Services/FlightLauncher.swift": ["CompanionConnectivityManager.shared": (4, "a real flight's start, which refuses during a dry run")],
            "Services/LocationManager.swift": ["CLLocationManager()": (1, "never started by a dry run's (`isDryRun`)")],
            "Services/MarketingLocationProvider.swift": ["WatchConnectivityManager.shared": (1, "a DEBUG screenshot scene's flight, never a dry run")],
            "Services/NotificationService.swift": [
                "NotificationService.shared": (2, "the service itself"),
                "UNUserNotificationCenter": (3, "the service itself"),
            ],
            "Services/OFMDataService.swift": ["UserDefaults.standard": (1, "a cache of public data, every flight's")],
            "Services/OfficialChartService.swift": ["DataPersistenceManager.shared": (1, "a cache of public data, every flight's")],
            "Services/OfflineMapManager.swift": [
                "DataPersistenceManager.shared": (1, "the offline maps, every flight's"),
                "UserDefaults.standard": (11, "the offline maps, every flight's"),
            ],
            "Services/OpenAIPCacheManager.swift": ["DataPersistenceManager.shared": (1, "a cache of public data, every flight's")],
            "Services/PhaseFrequencyPlanner.swift": ["WatchConnectivityManager.shared": (1, "the radio's default; a dry run's tells the Watch nothing (D8)")],
            "Services/SyncManager.swift": [
                "CKContainer": (3, "the service itself"),
                "DataPersistenceManager.shared": (2, "the service itself"),
            ],
            "Services/WatchConnectivityManager.swift": ["WCSession": (9, "the service itself")],
            "Services/WidgetBridge.swift": ["WidgetCenter": (1, "the widget, from the aircraft list")],
            "Views/AircraftRequestSheet.swift": [
                "@AppStorage": (2, "the Aircraft tab, never under a dry run"),
                "AircraftRequestStore.shared": (2, "the Aircraft tab, never under a dry run"),
                "NotificationService.shared": (1, "the Aircraft tab, never under a dry run"),
            ],
            "Views/CompanionPairingView.swift": ["CompanionConnectivityManager.shared": (2, "Settings, never under a dry run")],
            "Views/FlightLogView.swift": ["@AppStorage": (3, "the share card's look, the pilot's own choice wherever it is made, the dry run's logbook included")],
            "Views/FlightPlanningView.swift": ["NotificationService.shared": (1, "planning, on the ground")],
            "Views/FlightView.swift": ["CompanionConnectivityManager.shared": (3, "the in-flight menu's Companion toggle, hidden in a dry run (`isDryRun`)")],
            "Views/NavigationView.swift": ["WatchConnectivityManager.shared": (1, "Plan › Map, never open in flight")],
            "Views/Settings/SyncDataSettingsView.swift": ["SyncManager.shared": (1, "Settings, never under a dry run")],
            "Views/ShareCardSheet.swift": ["@AppStorage": (4, "the share card's look, the pilot's own choice wherever it is made, the dry run's logbook included")],
        ]
        let apis: [(name: String, pattern: String)] = [
            "NotificationService.shared", "UNUserNotificationCenter", "WatchConnectivityManager.shared", "WCSession",
            "WidgetCenter", "FlightActivityController.shared", "SyncManager.shared", "CKContainer",
            "DataPersistenceManager.shared", "UserDefaults.standard", "@AppStorage", "CompanionConnectivityManager.shared",
            "EETCalibrationStore.shared", "AircraftRequestStore.shared", "CLLocationManager()", "CMAltimeter()",
        ].map { name in
            let escaped = NSRegularExpression.escapedPattern(for: name)
            return (name, (name.first?.isLetter == true ? #"\b"# : "") + escaped + (name.last?.isLetter == true ? #"\b"# : ""))
        }

        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AeroCheck", isDirectory: true)
        var found: [String: [String: Int]] = [:]
        let paths = (FileManager.default.subpaths(atPath: app.path) ?? []).filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(paths.count, 100, "the app's sources, read from \(app.path)")
        for path in paths {
            let file = app.appendingPathComponent(path)
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            for line in lines where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let code = line.range(of: " //").map { String(line[..<$0.lowerBound]) } ?? line
                for api in apis {
                    let count = try NSRegularExpression(pattern: api.pattern)
                        .numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
                    if count > 0 { found[path, default: [:]][api.name, default: 0] += count }
                }
            }
        }

        var problems: [String] = []
        for (path, calls) in found.sorted(by: { $0.key < $1.key }) {
            for (api, count) in calls.sorted(by: { $0.key < $1.key }) where census[path]?[api]?.count != count {
                problems.append("\(path): \(api) ×\(count), the census says ×\(census[path]?[api]?.count ?? 0)")
            }
        }
        for (path, calls) in census {
            for (api, entry) in calls where found[path]?[api] == nil {
                problems.append("\(path): \(api) ×0, the census says ×\(entry.count)")
            }
        }
        XCTAssertEqual(problems, [], "Say in the census why a dry run never reaches each new call, or make it so")
    }

    // MARK: - The pilot's answers

    func testTheGeneratorGoesOnWhenThePilotDoes() {
        XCTAssertFalse(DryRunSession.mayGo(from: .engineStart, engineStarted: false, phase: .engineStart))
        XCTAssertTrue(DryRunSession.mayGo(from: .engineStart, engineStarted: true, phase: .afterEngineStart))
        XCTAssertFalse(DryRunSession.mayGo(from: .lineUp, engineStarted: true, phase: .beforeDeparture))
        for phase in [ChecklistPhase.lineUp, .climb, .cruise, .approach] {
            XCTAssertTrue(DryRunSession.mayGo(from: .lineUp, engineStarted: true, phase: phase), "\(phase)")
        }
        for phase in [ChecklistPhase.landing, .afterLanding, .shutdown] {
            XCTAssertFalse(DryRunSession.mayGo(from: .lineUp, engineStarted: true, phase: phase), "\(phase)")
        }
        XCTAssertFalse(DryRunSession.mayGo(from: .parked, engineStarted: true, phase: .hangar))
    }

    /// The author's seventh round (r7-14): a pilot who jumped to the line up check without ENGINE START found
    /// the aircraft parked for good; another saw the roll begin with the line up check still open.
    func testTheCheckGoneOnStartsTheEngineAndTheLineUpCheckWaitsForTheRoll() {
        XCTAssertTrue(DryRunSession.mayGo(from: .engineStart, engineStarted: false, phase: .lineUp))
        XCTAssertTrue(DryRunSession.mayGo(from: .engineStart, engineStarted: false, phase: .taxi))
        XCTAssertFalse(DryRunSession.mayGo(from: .engineStart, engineStarted: false, phase: .beforeEngineStart))
        XCTAssertFalse(DryRunSession.mayGo(from: .takeoff, engineStarted: true, phase: .lineUp))
        XCTAssertTrue(DryRunSession.mayGo(from: .takeoff, engineStarted: true, phase: .lineUp, lineUpDone: true))
        XCTAssertTrue(DryRunSession.mayGo(from: .takeoff, engineStarted: true, phase: .climb), "past it with the phase bar")
        XCTAssertFalse(DryRunSession.mayGo(from: .takeoff, engineStarted: true, phase: .afterLanding))
    }

    func testAfterAFullStopItGoesWhereThePilotsChecksSay() {
        // NEW CIRCUIT, or straight on to the line-up: round again.
        XCTAssertEqual(DryRunSession.afterFullStop(phase: .beforeDeparture, circuits: true), .goAgain)
        XCTAssertEqual(DryRunSession.afterFullStop(phase: .lineUp, circuits: true), .goAgain)
        // PARKING, or the shutdown reached any way: off the runway.
        XCTAssertEqual(DryRunSession.afterFullStop(phase: .shutdown, circuits: true), .vacate)
        XCTAssertEqual(DryRunSession.afterFullStop(phase: .hangar, circuits: false), .vacate)
        // A route never goes round again: a line-up check left showing waits for the pilot.
        XCTAssertNil(DryRunSession.afterFullStop(phase: .lineUp, circuits: false))
        // The after landing check: circuits wait for the pilot's choice; a flight that isn't vacates.
        XCTAssertNil(DryRunSession.afterFullStop(phase: .afterLanding, circuits: true))
        XCTAssertEqual(DryRunSession.afterFullStop(phase: .afterLanding, circuits: false), .vacate)
        // A check of the air still showing: the pilot hasn't caught up yet.
        for phase in [ChecklistPhase.climb, .approach, .landing] {
            XCTAssertNil(DryRunSession.afterFullStop(phase: phase, circuits: true), "\(phase)")
        }
    }

    // MARK: - The session's clock

    func testPauseStopsTheClockAndTheSpeedGoesOnFromWhereItIs() {
        let session = DryRunSession(world: DryRunWorld(settings: AppSettings(), base: makeTestDirectory()),
                                    setup: DryRunSetup(mission: .circuits(.lszq), rate: 4), seed: 1)
        addTeardownBlock { @MainActor in session.end() }
        XCTAssertTrue(session.begin(airports: AirportDataService(openAIPAirports: makeTestOpenAIPAirportLayer { _ in [] },
                                                                 rootDirectory: makeTestDirectory())))
        XCTAssertEqual(FlightClock.virtual?.rate, 4)
        session.pause()
        XCTAssertTrue(session.isPaused)
        XCTAssertEqual(FlightClock.virtual?.rate, 0)
        session.setRate(10)
        XCTAssertEqual(FlightClock.virtual?.rate, 0, "paused, whatever the pace")
        session.resume()
        XCTAssertEqual(FlightClock.virtual?.rate, 10)
        session.end()
        XCTAssertNil(FlightClock.virtual)
        XCTAssertFalse(session.world.appState.isFlightActive == true && session.world.location.isTracking,
                       "the world's GPS stopped")
    }

    // MARK: - The world

    func testTheWorldFliesTheWT9WithItsOwnCopyOfTheSettings() {
        var settings = AppSettings()
        settings.enableCompanionMode = true
        settings.selectedRemoteAircraftId = "pa28-181"
        settings.learningMode = false
        let world = DryRunWorld(settings: settings, base: makeTestDirectory())
        addTeardownBlock { @MainActor in world.tearDown() }
        XCTAssertFalse(world.appState.settings.enableCompanionMode)
        XCTAssertNil(world.appState.settings.selectedRemoteAircraftId)
        XCTAssertEqual(world.appState.settings.selectedAircraft, .wt9Dynamic)
        XCTAssertFalse(world.appState.settings.learningMode, "the pilot's own settings otherwise")
        XCTAssertTrue(world.location.isDryRun)
        XCTAssertEqual(world.location.authorizationStatus, .authorizedWhenInUse, "its GPS is the dry run's")
    }

    func testLeftoversAreSweptAtLaunch() throws {
        let base = makeTestDirectory()
        let leftover = base.appendingPathComponent("DryRun-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        let preferences = makeTestDirectory()
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        // A suite with its keys (the app stopped during the dry run), and one emptied at a dry run's end.
        let full = DryRunWorld.suitePrefix + UUID().uuidString
        let empty = DryRunWorld.suitePrefix + UUID().uuidString
        UserDefaults(suiteName: full)?.set(true, forKey: "left")
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: full) }
        for name in [full, empty, "com.example.other"] {
            try Data().write(to: preferences.appendingPathComponent("\(name).plist"))
        }
        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: preferences.appendingPathComponent("\(name).plist").path)
        }

        DryRunWorld.sweepLeftovers(base: base, preferences: preferences)

        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
        XCTAssertNil(UserDefaults(suiteName: full)?.object(forKey: "left"), "its keys gone")
        XCTAssertFalse(exists(empty), "an empty one's file gone")
        XCTAssertTrue(exists("com.example.other"), "only a dry run's")
    }

    // MARK: - The app around it

    func testOneDryRunAtATimeNeverDuringAFlightAndWhatWaitsRunsAtItsEnd() async {
        let center = DryRunCenter.shared
        XCTAssertFalse(center.isRunning)
        let airports = AirportDataService(openAIPAirports: makeTestOpenAIPAirportLayer { _ in [] },
                                          rootDirectory: makeTestDirectory())
        airports.injectForReplay([DryRunAerodrome.lszq.airport])

        var ran = 0
        center.whenNotRunning { ran += 1 }
        XCTAssertEqual(ran, 1, "at once, with no dry run")

        let aircraftData = makeTestAircraftDataService(subscriptionManager: makeTestSubscriptionManager())
        let setup = DryRunSetup(mission: .circuits(.lszq))
        func begin(flying: Bool) async -> DryRunCenter.Outcome {
            await center.begin(setup, settings: { AppSettings() }, airports: airports, aircraftData: aircraftData,
                               isFlightActive: flying)
        }
        let refused = await begin(flying: true)
        XCTAssertEqual(refused, .busy, "never during a real flight")
        let started = await begin(flying: false)
        XCTAssertEqual(started, .started)
        addTeardownBlock { @MainActor in DryRunCenter.shared.end() }
        let second = await begin(flying: false)
        XCTAssertEqual(second, .busy, "one at a time")

        center.whenNotRunning { ran += 1 }
        XCTAssertEqual(ran, 1, "held while the dry run runs")
        let root = center.session?.world.root
        center.end()
        XCTAssertEqual(ran, 2, "run at its end")
        XCTAssertFalse(center.isRunning)
        XCTAssertNil(FlightClock.virtual)
        XCTAssertFalse(root.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
    }

    func testNoRealFlightStartsDuringADryRun() async {
        let appState = makeTestAppState()
        var launcher = FlightLauncher(
            appState: appState, locationManager: LocationManager(),
            aircraftDataService: makeTestAircraftDataService(subscriptionManager: makeTestSubscriptionManager()),
            airportDataService: AirportDataService(), flightEventDetector: FlightEventDetector(),
            flightPlanManager: makeTestPlanManager())
        launcher.isDryRunning = { true }
        let outcome = await launcher.begin(circuitMode: false)
        XCTAssertEqual(outcome, .blockedActiveFlight)
        XCTAssertFalse(appState.isFlightActive)
    }

    func testTheScreenStaysOnDuringADryRun() {
        XCTAssertTrue(ScreenAwakeRule.keepsAwake(isFlightActive: false, companionRole: .master,
                                                 companionState: .disconnected, isDryRunning: true))
        XCTAssertFalse(ScreenAwakeRule.keepsAwake(isFlightActive: false, companionRole: .master,
                                                  companionState: .disconnected, isDryRunning: false))
    }

    func testBannersAreHeldInADryRunAsInAFlight() {
        // The rule the app's hold follows, given the dry run's AppState while one runs (AeroCheckApp).
        XCTAssertFalse(NotificationPresentationRule.mayInterrupt(isFlightActive: true, phase: .cruise))
        XCTAssertTrue(NotificationPresentationRule.mayInterrupt(isFlightActive: true, phase: .hangar))
    }
}
