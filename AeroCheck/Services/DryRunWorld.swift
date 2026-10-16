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

    init(settings: AppSettings, aircraft: AircraftOption? = nil, base: URL = DryRunWorld.baseDirectory) {
        self.aircraft = aircraft
        root = base.appendingPathComponent("DryRun-\(id.uuidString)", isDirectory: true)
        suiteName = Self.suitePrefix + id.uuidString
        // Nil only for the app's own domain or the global one, which this never is.
        defaults = UserDefaults(suiteName: suiteName)!
        persistence = DataPersistenceManager(rootDirectory: root)
        // The pilot's settings, read by the world's AppState as its own: what the Cockpit changes stays here.
        persistence.saveSettings(Self.settings(from: settings, aircraft: aircraft))
        appState = AppState(defaults: defaults, persistence: persistence)
        plans = FlightPlanManager(defaults: defaults, persistence: persistence)
        threads = FlightThreadManager(defaults: defaults, persistence: persistence)
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
