import Foundation

// MARK: - Dry run (6.4.0): the world a dry run's flight lives in

/// Everything a dry run's flight touches, of its own, and dropped when it ends: a folder and a defaults suite,
/// an AppState on them with a copy of the pilot's settings, its own plans, threads, detector and
/// LocationManager, an inert Companion manager and a radio that tells the Watch nothing.
///
/// Isolated by construction rather than by a flag in the app's flight code: an AppState on a datastore
/// confined to a folder has no CloudKit, no Live Activity and no EET learning (`AppState.init`); a
/// `LocationManager.dryRun()` never starts Core Location or the barometer; a thread manager with no thread
/// schedules nothing. The real AppState never sees the flight, so the Watch, the Live Activity, the Pro hold,
/// the checkpoint restore and the notification hold of the real app stay as they are. What still reaches
/// out of the app is listed, with its rule, in `DryRunWorldTests`' census. (6.4.0)
@MainActor
final class DryRunWorld {
    /// Where the worlds' folders are, one per dry run: in Caches, nothing a pilot keeps.
    nonisolated static var baseDirectory: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("DryRuns", isDirectory: true)
    }
    /// Each world's defaults suite: this, then its id.
    nonisolated static let suitePrefix = "DryRun."

    let id = UUID()
    let root: URL
    let suiteName: String
    let defaults: UserDefaults
    let persistence: DataPersistenceManager
    let appState: AppState
    let plans: FlightPlanManager
    let threads: FlightThreadManager
    let detector: FlightEventDetector
    let location: LocationManager
    /// Never connects: no Wi-Fi Aware, a suite of the world's (D8, Companion off in a dry run).
    let companion: CompanionConnectivityManager
    /// The Cockpit's frequencies, which tell the Watch nothing (D8).
    let radio: CockpitRadio
    /// The aircraft flown; nil for the WT9.
    let aircraft: AircraftOption?
    private(set) var isTornDown = false

    /// `mapLayer`: the device's chart, which the world's maps show from the start: on its own suite the dry run always
    /// opened on the ICAO chart (the author's device check, 23 Oct 2026). (6.5.0)
    init(settings: AppSettings, aircraft: AircraftOption? = nil, mapLayer: MapLayerType = .icao,
         base: URL = DryRunWorld.baseDirectory) {
        self.aircraft = aircraft
        root = base.appendingPathComponent("DryRun-\(id.uuidString)", isDirectory: true)
        suiteName = Self.suitePrefix + id.uuidString
        // Nil only for the app's own domain or the global one, which this never is.
        defaults = UserDefaults(suiteName: suiteName)!
        persistence = DataPersistenceManager(rootDirectory: root)
        // The pilot's settings, read by the world's AppState as its own: what the Cockpit changes stays here.
        persistence.saveSettings(Self.settings(from: settings, aircraft: aircraft))
        appState = AppState(defaults: defaults, persistence: persistence)
        appState.selectMapLayer(mapLayer)
        plans = FlightPlanManager(defaults: defaults, persistence: persistence)
        // Inert notifications: a flight planned or closed out in the world schedules no reminder (the
        // story's Plan and Close out parts plan and close one).
        threads = FlightThreadManager(defaults: defaults, notifications: .inert(), persistence: persistence)
        detector = FlightEventDetector()
        location = .dryRun()
        companion = CompanionConnectivityManager(defaults: defaults, usesWiFiAware: false)
        radio = CockpitRadio()
        radio.publish = { _ in }

        // As `AeroCheckApp` joins the app's own, short of the threads' and the notifications' (no thread here).
        plans.isFlightInProgress = { [weak appState] in appState?.isFlightActive ?? false }
        appState.anchorETOsOnLineUp = { [weak plans] in plans?.anchorETOsOnLineUp($0) }
        appState.takeLapFullStop = { [weak detector] in detector?.notifyManualEvent(.fullStop) }
    }

    /// The pilot's settings for a dry run: Companion off (D8), and the aircraft chosen, the WT9 when none
    /// (bundled, every install can fly it with no data).
    static func settings(from real: AppSettings, aircraft: AircraftOption? = nil) -> AppSettings {
        var settings = real
        settings.enableCompanionMode = false
        switch aircraft {
        case .remote(let metadata)?:
            settings.selectedRemoteAircraftId = metadata.id
        case .bundled(let type)?:
            settings.selectedAircraft = type
            settings.selectedRemoteAircraftId = nil
        case nil:
            settings.selectedAircraft = .wt9Dynamic
            settings.selectedRemoteAircraftId = nil
        }
        return settings
    }

    /// The aircraft's checklist in the pilot's language, as START FLIGHT loads it: a premium one from the
    /// cache or the server. False when it can't be had (no Pro, no connection and no copy).
    func loadChecklist(aircraftDataService: AircraftDataService) async -> Bool {
        await appState.loadRemoteChecklistIfNeeded(aircraftDataService: aircraftDataService)
        return appState.isPremiumChecklistResolved
    }

    /// A copy of the pilot's route, armed in the world's plans as START FLIGHT takes it. Once the world's
    /// (empty) plans have loaded, or the load would replace it.
    func arm(_ plan: FlightPlan) async {
        for _ in 0..<50 where !plans.hasLoadedPlans {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        plans.add(plan)
        plans.activateFlightPlan(plan)
    }

    /// A copy of a route among the world's routes, not armed (the guided dry run's: the Plan sheet offers it,
    /// START FLIGHT arms the flight's own copy). Once the world's plans have loaded.
    func keep(_ plan: FlightPlan) async {
        for _ in 0..<50 where !plans.hasLoadedPlans {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        plans.add(plan)
    }

    /// Five made-up flights in the world's logbook, earlier in the year (`DryRunLogbook`): the Logbook part's
    /// figures mean something. Once the world's logbook has loaded (empty), or the load would replace them.
    func seedLogbook(at field: DryRunAerodrome, now: Date) async {
        for _ in 0..<50 where appState.isLoadingFlights {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        appState.addMadeUpFlights(DryRunLogbook.flights(at: field, before: now))
    }

    /// Starts the flight and its GPS, the dry run's: as `FlightLauncher` does, without its guards, which are
    /// the real flight's (an aircraft owned, a permission, a fix). `aerodromes`: the detector's besides the
    /// store's, for a store that doesn't have them. False if the AppState refused it.
    @discardableResult
    func startFlight(circuits: Bool, aerodromes: [Airport], airports: AirportDataService) -> Bool {
        let bundled = appState.settings.selectedAircraft
        detector.configure(speeds: appState.activeChecklist.speeds, stallSpeed: appState.activeChecklist.stallSpeed)
        appState.startFlight(withAircraft: appState.settings.defaultAirplane,
                             aircraftRegistration: aircraft?.registration ?? bundled.registration,
                             aircraftType: aircraft?.aircraftType ?? bundled.rawValue,
                             checklistVersion: aircraft?.version ?? bundled.checklistVersion,
                             flightPlanId: circuits ? nil : plans.activeFlightPlan?.id, circuitMode: circuits)
        guard appState.isFlightActive else { return false }
        location.extraDetectorAirports = aerodromes
        location.startTracking(appState: appState, interval: appState.settings.gpsRecordingInterval,
                               airportDataService: airports, flightEventDetector: detector,
                               flightPlanManager: plans, activeChecklist: appState.activeChecklist)
        return true
    }

    /// Drops the world: the GPS stopped, its checkpoint's last write landed, then its folder and its suite
    /// gone. Whatever the flight was, nothing of it stays.
    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        if location.isTracking { location.stopTracking() }
        appState.flushPendingCheckpoint()
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// What a dry run left behind when the app stopped during it (killed, or crashed): its folders and its
    /// suites. At launch, before any dry run, so nothing here is in use; a relaunch never brings a dry run
    /// back (D2). A suite still holding keys loses them; the empty file the system then writes back in its
    /// place (as it does after every dry run's end) goes at a later launch. `preferences`: where the suites'
    /// files are.
    nonisolated static func sweepLeftovers(base: URL = baseDirectory,
                                           preferences: URL? = defaultPreferencesDirectory) {
        try? FileManager.default.removeItem(at: base)
        guard let preferences,
              let files = try? FileManager.default.contentsOfDirectory(atPath: preferences.path) else { return }
        for file in files where file.hasPrefix(suitePrefix) && file.hasSuffix(".plist") {
            let suite = String(file.dropLast(".plist".count))
            let defaults = UserDefaults(suiteName: suite)
            if defaults?.persistentDomain(forName: suite)?.isEmpty == false {
                defaults?.removePersistentDomain(forName: suite)
            } else {
                try? FileManager.default.removeItem(at: preferences.appendingPathComponent(file))
            }
        }
    }

    /// Library/Preferences, where a suite's file is kept.
    nonisolated static var defaultPreferencesDirectory: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Preferences", isDirectory: true)
    }
}

// MARK: - The dry run's logbook

/// Five made-up flights for the guided dry run's logbook, earlier in the year, so its Logbook part has figures
/// that mean something (the author's Q9, "Plan to Logbook"): circuits at the dry run's aerodrome flown by the
/// generator (their track, their times, their landings), each kept as the logbook keeps a flight, its checks
/// included. They are the dry run's world's only, and go with it. (6.4.0)
enum DryRunLogbook {
    /// How long ago each was flown, in days, and the touch-and-goes before its full stop.
    static let flown: [(daysAgo: Int, touchAndGos: Int)] = [(9, 2), (23, 0), (41, 3), (67, 1), (98, 2)]

    static func flights(at field: DryRunAerodrome, before now: Date) -> [Flight] {
        let calendar = Calendar(identifier: .gregorian)
        return flown.enumerated().map { index, flown in
            let day = calendar.date(byAdding: .day, value: -flown.daysAgo, to: now) ?? now
            let start = calendar.date(bySettingHour: 9 + index, minute: 15 * (index % 3), second: 0, of: day) ?? day
            return flight(at: field, start: start, touchAndGos: flown.touchAndGos, index: index)
        }
    }

    private static func flight(at field: DryRunAerodrome, start: Date, touchAndGos: Int, index: Int) -> Flight {
        var landings = Array(repeating: DryRunGenerator.Landing.touchAndGo, count: touchAndGos)
        var pilot = DryRunGenerator.Pilot()
        pilot.landing = { _ in landings.isEmpty ? .fullStop : landings.removeFirst() }
        pilot.afterFullStop = { _ in .vacate }
        let generator = DryRunGenerator(departure: field, mission: .circuits, seed: UInt64(41 + index), pilot: pilot)
        var track: [GPSPoint] = []
        var blockOff: Date?
        for _ in 0..<(2 * 3600) where !generator.isParkedForGood {
            let fix = generator.nextFix()
            let time = start.addingTimeInterval(TimeInterval(fix.t))
            if blockOff == nil, fix.speedMS > 1 { blockOff = time }
            // A fix every five seconds, the recording's default.
            guard fix.t % 5 == 0 else { continue }
            track.append(GPSPoint(latitude: fix.latitude, longitude: fix.longitude, altitude: fix.altitudeM,
                                  timestamp: time, speed: fix.speedMS, course: max(0, fix.course),
                                  horizontalAccuracy: fix.horizontalAccuracyM))
        }
        func at(_ mark: String) -> Date? { generator.mark(mark).map { start.addingTimeInterval(TimeInterval($0)) } }
        let touchdowns = generator.marks.filter { $0.name == "touchdown" }.map { start.addingTimeInterval(TimeInterval($0.t)) }
        let parked = at("parked") ?? start.addingTimeInterval(TimeInterval(generator.t))
        let bundled = AircraftType.wt9Dynamic
        var flight = Flight(aircraftRegistration: bundled.registration, aircraftType: bundled.rawValue,
                            checklistVersion: bundled.checklistVersion, startTime: start,
                            stopTime: parked.addingTimeInterval(120), engineStartTime: start.addingTimeInterval(5),
                            lineUpTime: at("lineUp"), landingTime: touchdowns.last,
                            engineShutdownTime: parked.addingTimeInterval(30), blockOffTime: blockOff,
                            blockOnTime: parked, departureAirportIdent: field.ident, arrivalAirportIdent: field.ident,
                            gpsTrack: track, touchAndGoCount: touchAndGos, fullStopCount: 1,
                            touchAndGoTimes: Array(touchdowns.dropLast()), fullStopTimes: Array(touchdowns.suffix(1)),
                            modifiedAt: start)
        flight.checkOutcomes = outcomes(index)
        return flight
    }

    /// How its checks ended: done, the climb check from memory every other flight, the approach check skipped
    /// once, the landing check confirmed after landing.
    private static func outcomes(_ index: Int) -> [CheckOutcome] {
        ChecklistPhase.allCases.filter { !$0.isSkippedInCircuitMode(true) }.map { phase in
            switch phase {
            case .climb where index % 2 == 0: return CheckOutcome(phase: phase, status: .doneFromMemory)
            case .approach where index == 1: return CheckOutcome(phase: phase, status: .skipped)
            case .landing: return CheckOutcome(phase: phase, status: .confirmedAfterLanding)
            default: return CheckOutcome(phase: phase, status: .done)
            }
        }
    }
}
