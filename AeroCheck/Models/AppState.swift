import Foundation
import SwiftUI

/// Phase completion status
enum PhaseCompletionStatus: String, Codable {
    case notStarted
    case completed       // User pressed NEXT
    case skipped         // User jumped past without pressing NEXT
    case missingAction   // Phase with required button (e.g., engine start) was skipped without pressing button
}

/// The pilot's progress through the checklist, grouped as one cohesive value extracted from four
/// loose @Published properties on AppState: the current phase, the per-phase completion status, the
/// highest phase reached, and the per-phase step-by-step highlight index. AppState owns it via a
/// single `@Published var checklistProgress` and exposes thin forwarding accessors, so the app-wide
/// `appState.currentPhase` / `phaseCompletionStatus` / … call sites keep working and stay reactive.
/// (Phase 4 — AppState decomposition: state extraction)
struct ChecklistProgress {
    var currentPhase: ChecklistPhase = .preflight
    var phaseCompletionStatus: [ChecklistPhase: PhaseCompletionStatus] = [:]
    var highestCompletedPhase: ChecklistPhase = .preflight
    var currentHighlightedItem: [ChecklistPhase: Int] = [:]
}

/// Night-mode preference: off, always on, or follow the device's dark-mode setting. (v4 UI/UX Revamp)
/// The user's cockpit-theme choice. `auto` follows the device's light/dark setting (light→day,
/// dark→night); `day`/`sunlight`/`night` force that palette. Replaces the old `NightModePreference`
/// (off/on/system) — `sunlight` is the high-contrast bright-cockpit palette, now selectable. (v4 UI/UX Revamp)
enum ThemePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, day, sunlight, night
    var id: String { rawValue }
}

/// Application-wide settings
struct AppSettings: Codable, Equatable {
    var selectedAircraft: AircraftType = .wt9Dynamic
    var selectedRemoteAircraftId: String? = nil // ID of selected remote aircraft (e.g., "pa28-181")
    var keepScreenOn: Bool = true
    /// Cockpit theme choice: auto (follow device) / day / sunlight / night. Night dims instruments to
    /// a red/amber palette to protect dark adaptation (UX-09); sunlight is high-contrast for bright
    /// cockpits. (v4 UI/UX Revamp; migrated from the old `nightModePreference`/`nightMode`)
    var themePreference: ThemePreference = .auto

    /// Whether night mode is effectively active, given the device's dark-mode state (only relevant for
    /// `.auto`). Drives the `\.isNightMode` env (instrument dimming). Sunlight is NOT night.
    func effectiveNightMode(systemIsDark: Bool) -> Bool {
        switch themePreference {
        case .night: return true
        case .auto: return systemIsDark
        case .day, .sunlight: return false
        }
    }

    /// The active cockpit theme mode (v4 UI/UX Revamp) resolved against the live device appearance.
    func cockpitThemeMode(systemIsDark: Bool) -> CockpitThemeMode {
        switch themePreference {
        case .day: return .day
        case .sunlight: return .sunlight
        case .night: return .night
        case .auto: return systemIsDark ? .night : .day
        }
    }
    var gpsRecordingInterval: Double = 5.0 // seconds
    var showSpeedReference: Bool = true
    var stepByStepHighlighting: Bool = true // Highlight items one by one
    var learningMode: Bool = false // Hide memorizable checks
    var forceICAOChartLayer: Bool = false // When true, ICAO layer stays at all zoom levels
    var offlineMode: Bool = false // When true, use cached ICAO chart only
    var alwaysUseUTC: Bool = false // When true, all times are displayed in UTC
    var distanceInNauticalMiles: Bool = true // Flight Log distances: true = NM, false = km (toggle on the NM card)
    var showEstimatedAirspeed: Bool = false // When true, shows estimated IAS based on wind data (experimental)
    var stallAlertSound: Bool = false // When true, plays an aural + haptic stall alert (UX-02)

    // Flight Planning
    var enableFlightPlanning: Bool = true // ON by default
    var waypointProximityThreshold: Double = 500 // meters, for auto-advancing waypoints
    var terrainAltitudeUnit: TerrainAltitudeUnit = .feet // feet, meters, or dual

    // Circuit mode
    var enableCircuitMode: Bool = false // When true, shows START CIRCUITS button

    // Aircraft visibility (premium feature)
    var hiddenAircraftIds: Set<String> = [] // Individual aircraft IDs to hide on home screen
    var hiddenAeroclubs: Set<String> = [] // Entire aeroclubs to hide on home screen

    // iCloud Sync
    var iCloudSyncEnabled: Bool = true // When true, syncs settings and flights to iCloud

    // Checklist Language
    var checklistLanguage: ChecklistLanguage = .auto // Language for checklist content

    // Airport data overlay
    var showAirportsOnMap: Bool = true // When true, shows airports on navigation map (requires airport data download) — ON by default
    var showNavaidsOnMap: Bool = true // When true, shows navaids (VOR/DME/NDB) on navigation map (requires navaid data download) — ON by default (v4.1.0)
    var showObstaclesOnMap: Bool = false // When true, shows obstacles (towers/masts/turbines) on navigation map (requires obstacle data download) — OFF by default to avoid clutter (v4.1.0)
    var showReportingPointsOnMap: Bool = true // When true, shows VFR reporting points on navigation map (requires reporting-point data download) — ON by default (v4.1.0)
    var showTrackVector: Bool = true // When true, draws a ground-track trend vector ahead of the aircraft (v4 UI/UX Revamp) — ON by default

    // OpenAIP aviation data overlay
    var showOpenAIPOverlay: Bool = true // When true, draws OpenAIP airspace (vector CTRs from downloaded data) on the nav map — ON by default
    var showOpenAIPTiles: Bool = false // When true, overlays the OpenAIP raster chart tiles (data-first: tiles are an opt-in, separate from the airspace vector) — OFF by default (v4.1.0)
    var openAIPOfflineCountries: [String] = [] // ISO alpha-2 country codes for cached airspace data
    var enableAirspaceStreaming: Bool = false // When true, fetches nearby CTRs from OpenAIP API when no downloaded data

    // Flight logging
    var logEngineHours: Bool = true // When true, prompts for hour meter reading at engine start and stop (ON by default)

    // Onboarding
    var hasCompletedOnboarding: Bool = false // When true, onboarding has been completed or skipped

    // GPS priority
    var gpsPriority: GPSPriority = .precision

    // Share card customization
    var shareCardColorScheme: ShareCardColorScheme = .darkBlue
    var shareCardMapLayer: ShareCardMapLayer = .standard

    // Companion mode
    var enableCompanionMode: Bool = false // When true, companion connectivity is available
    var companionRole: CompanionRoleSetting = .auto // DEPRECATED (v4.1): role is now auto by device type; retained for decode compat only

    // Developer mode: revealed by tapping the version 5× in About. Persisted so it survives launches
    // and gates developer-only surfaces app-wide (e.g. the Companion diagnostics panel). (v4.1)
    var developerMode: Bool = false

    // Marketing mode is NOT persisted - it resets to false on app restart
    var marketingMode: Bool = false // When true, enables shake gesture to show marketing location controls

    /// Whether a remote aircraft is selected
    var isRemoteAircraftSelected: Bool {
        selectedRemoteAircraftId != nil
    }

    /// Checks if an aircraft should be visible on the home screen
    /// - Parameters:
    ///   - aircraftId: The aircraft identifier
    ///   - aeroclub: The aeroclub the aircraft belongs to (nil for bundled aircraft)
    /// - Returns: true if the aircraft should be shown
    func isAircraftVisible(aircraftId: String, aeroclub: String?) -> Bool {
        // Check if individually hidden
        if hiddenAircraftIds.contains(aircraftId) {
            return false
        }
        // Check if aeroclub is hidden (only applies to remote aircraft with aeroclubs)
        if let club = aeroclub, hiddenAeroclubs.contains(club) {
            return false
        }
        return true
    }

    /// Aircraft registration (derived from selected aircraft)
    var defaultAirplane: String {
        // If remote aircraft is selected, return its ID for now
        // This will be resolved to actual registration when loading checklist
        if let remoteId = selectedRemoteAircraftId {
            return remoteId
        }
        return selectedAircraft.registration
    }

    // Custom coding keys to exclude marketingMode from persistence
    enum CodingKeys: String, CodingKey {
        case selectedAircraft
        case selectedRemoteAircraftId
        case keepScreenOn
        case themePreference
        case gpsRecordingInterval
        case showSpeedReference
        case stepByStepHighlighting
        case learningMode
        case forceICAOChartLayer
        case offlineMode
        case alwaysUseUTC
        case distanceInNauticalMiles
        case showEstimatedAirspeed
        case stallAlertSound
        case enableFlightPlanning
        case waypointProximityThreshold
        case terrainAltitudeUnit
        case enableCircuitMode
        case hiddenAircraftIds
        case hiddenAeroclubs
        case iCloudSyncEnabled
        case checklistLanguage
        case showAirportsOnMap
        case showNavaidsOnMap
        case showObstaclesOnMap
        case showReportingPointsOnMap
        case showTrackVector
        case logEngineHours
        case hasCompletedOnboarding
        case gpsPriority
        case shareCardColorScheme
        case shareCardMapLayer
        case showOpenAIPOverlay
        case showOpenAIPTiles
        case openAIPOfflineCountries
        case enableAirspaceStreaming
        case enableCompanionMode
        case companionRole
        case developerMode
        // marketingMode is intentionally excluded
    }

    /// Legacy keys read only for backward-compatible migration (not encoded).
    private enum LegacyCodingKeys: String, CodingKey {
        case nightMode            // oldest: Bool
        case nightModePreference  // v4 UI/UX Revamp: "off"/"on"/"system"
    }

    // Default initializer (needed because we have a custom decoder)
    init() {}

    // Custom decoder for backward compatibility with new fields
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        selectedAircraft = try container.decodeIfPresent(AircraftType.self, forKey: .selectedAircraft) ?? .wt9Dynamic
        selectedRemoteAircraftId = try container.decodeIfPresent(String.self, forKey: .selectedRemoteAircraftId)
        keepScreenOn = try container.decodeIfPresent(Bool.self, forKey: .keepScreenOn) ?? true
        // Theme preference (auto/day/sunlight/night). Migrate older saves:
        //   nightModePreference "off"→.day "on"→.night "system"→.auto  ·  legacy nightMode Bool true→.night.
        if let pref = try container.decodeIfPresent(ThemePreference.self, forKey: .themePreference) {
            themePreference = pref
        } else if let legacyContainer = try? decoder.container(keyedBy: LegacyCodingKeys.self) {
            if let oldPref = try? legacyContainer.decodeIfPresent(String.self, forKey: .nightModePreference) {
                switch oldPref {
                case "on": themePreference = .night
                case "system": themePreference = .auto
                default: themePreference = .day
                }
            } else if let legacy = try? legacyContainer.decodeIfPresent(Bool.self, forKey: .nightMode) {
                themePreference = legacy ? .night : .day
            } else {
                themePreference = .day
            }
        } else {
            themePreference = .day
        }
        gpsRecordingInterval = try container.decodeIfPresent(Double.self, forKey: .gpsRecordingInterval) ?? 5.0
        showSpeedReference = try container.decodeIfPresent(Bool.self, forKey: .showSpeedReference) ?? true
        stepByStepHighlighting = try container.decodeIfPresent(Bool.self, forKey: .stepByStepHighlighting) ?? true
        learningMode = try container.decodeIfPresent(Bool.self, forKey: .learningMode) ?? false
        forceICAOChartLayer = try container.decodeIfPresent(Bool.self, forKey: .forceICAOChartLayer) ?? false
        offlineMode = try container.decodeIfPresent(Bool.self, forKey: .offlineMode) ?? false
        alwaysUseUTC = try container.decodeIfPresent(Bool.self, forKey: .alwaysUseUTC) ?? false
        distanceInNauticalMiles = try container.decodeIfPresent(Bool.self, forKey: .distanceInNauticalMiles) ?? true
        showEstimatedAirspeed = try container.decodeIfPresent(Bool.self, forKey: .showEstimatedAirspeed) ?? false
        stallAlertSound = try container.decodeIfPresent(Bool.self, forKey: .stallAlertSound) ?? false
        enableFlightPlanning = try container.decodeIfPresent(Bool.self, forKey: .enableFlightPlanning) ?? false
        waypointProximityThreshold = try container.decodeIfPresent(Double.self, forKey: .waypointProximityThreshold) ?? 500
        terrainAltitudeUnit = try container.decodeIfPresent(TerrainAltitudeUnit.self, forKey: .terrainAltitudeUnit) ?? .feet
        enableCircuitMode = try container.decodeIfPresent(Bool.self, forKey: .enableCircuitMode) ?? false
        hiddenAircraftIds = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenAircraftIds) ?? []
        hiddenAeroclubs = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenAeroclubs) ?? []
        iCloudSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .iCloudSyncEnabled) ?? true
        checklistLanguage = try container.decodeIfPresent(ChecklistLanguage.self, forKey: .checklistLanguage) ?? .auto
        showAirportsOnMap = try container.decodeIfPresent(Bool.self, forKey: .showAirportsOnMap) ?? false
        showNavaidsOnMap = try container.decodeIfPresent(Bool.self, forKey: .showNavaidsOnMap) ?? true
        showObstaclesOnMap = try container.decodeIfPresent(Bool.self, forKey: .showObstaclesOnMap) ?? false
        showReportingPointsOnMap = try container.decodeIfPresent(Bool.self, forKey: .showReportingPointsOnMap) ?? true
        showTrackVector = try container.decodeIfPresent(Bool.self, forKey: .showTrackVector) ?? false
        logEngineHours = try container.decodeIfPresent(Bool.self, forKey: .logEngineHours) ?? true
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        gpsPriority = try container.decodeIfPresent(GPSPriority.self, forKey: .gpsPriority) ?? .precision
        shareCardColorScheme = try container.decodeIfPresent(ShareCardColorScheme.self, forKey: .shareCardColorScheme) ?? .darkBlue
        shareCardMapLayer = try container.decodeIfPresent(ShareCardMapLayer.self, forKey: .shareCardMapLayer) ?? .standard
        showOpenAIPOverlay = try container.decodeIfPresent(Bool.self, forKey: .showOpenAIPOverlay) ?? false
        showOpenAIPTiles = try container.decodeIfPresent(Bool.self, forKey: .showOpenAIPTiles) ?? false
        openAIPOfflineCountries = try container.decodeIfPresent([String].self, forKey: .openAIPOfflineCountries) ?? []
        enableAirspaceStreaming = try container.decodeIfPresent(Bool.self, forKey: .enableAirspaceStreaming) ?? false
        enableCompanionMode = try container.decodeIfPresent(Bool.self, forKey: .enableCompanionMode) ?? false
        companionRole = try container.decodeIfPresent(CompanionRoleSetting.self, forKey: .companionRole) ?? .auto
        developerMode = try container.decodeIfPresent(Bool.self, forKey: .developerMode) ?? false
        // marketingMode intentionally excluded - always defaults to false
    }

    /// Returns a copy with flight-relevant numeric settings clamped to sane ranges, for applying
    /// settings ingested from an untrusted source (a divergent-schema or corrupt CloudKit record
    /// must never flip a flight-relevant value to an absurd one). (SEC-17)
    func clampedForIngest() -> AppSettings {
        var result = self
        result.gpsRecordingInterval = result.gpsRecordingInterval.clamped(to: 1.0...300.0)
        result.waypointProximityThreshold = result.waypointProximityThreshold.clamped(to: 10.0...50_000.0)
        return result
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Unit for displaying terrain profile altitude
enum TerrainAltitudeUnit: String, Codable, CaseIterable, Identifiable {
    case feet = "Feet"
    case meters = "Meters"
    case dual = "Both"

    var id: String { rawValue }
}

/// GPS accuracy priority — trades battery usage for positional precision
enum GPSPriority: String, Codable, CaseIterable, Identifiable {
    case precision = "Precision"
    case batterySaver = "BatterySaver"

    var id: String { rawValue }
}

/// Crash-recovery snapshot of an active flight session, restored when the app is relaunched
/// after being killed (crash/OOM/swipe-close) mid-flight.
///
/// The stored maps use the `Codable` enums (`ChecklistPhase`, `PhaseCompletionStatus`) directly,
/// so the compiler enforces handling of any new enum case — a new phase or status can no longer
/// be silently dropped through a stringly-typed dictionary. (ARCH-08)
struct ActiveFlightState: Codable {
    /// Bumped when the stored shape changes incompatibly. A snapshot with a different version
    /// (or one that fails to decode) is discarded on restore rather than crashing.
    static let currentSchemaVersion = 2

    var schemaVersion: Int = ActiveFlightState.currentSchemaVersion
    let flight: Flight
    let currentPhase: ChecklistPhase
    let engineStartTime: Date?
    let lineUpTime: Date?
    let landingTime: Date?
    let engineShutdownTime: Date?
    let phaseCompletionStatus: [ChecklistPhase: PhaseCompletionStatus]
    let highestCompletedPhase: ChecklistPhase
    let currentHighlightedItem: [ChecklistPhase: Int]
    let hasLandingBeenDetected: Bool
    let isCircuitMode: Bool
    /// Aircraft selection captured at save time so the correct checklist is re-resolved on
    /// restore — a restored premium flight reloads its own checklist, never the WT9 residue. (ARCH-08)
    let selectedAircraft: AircraftType
    let selectedRemoteAircraftId: String?
    let savedAt: Date

    /// Builds a snapshot from a **non-optional** flight, so a nil `currentFlight` can never
    /// reach this initializer (replaces the previous `currentFlight!` force-unwrap). (ARCH-08)
    @MainActor
    init(flight: Flight, from appState: AppState) {
        self.flight = flight
        self.currentPhase = appState.currentPhase
        self.engineStartTime = appState.engineStartTime
        self.lineUpTime = appState.lineUpTime
        self.landingTime = appState.landingTime
        self.engineShutdownTime = appState.engineShutdownTime
        self.phaseCompletionStatus = appState.phaseCompletionStatus
        self.highestCompletedPhase = appState.highestCompletedPhase
        self.currentHighlightedItem = appState.currentHighlightedItem
        self.hasLandingBeenDetected = appState.hasLandingBeenDetected
        self.isCircuitMode = appState.isCircuitMode
        self.selectedAircraft = appState.settings.selectedAircraft
        self.selectedRemoteAircraftId = appState.settings.selectedRemoteAircraftId
        self.savedAt = Date()
    }

    /// Restore state to AppState
    @MainActor
    func restore(to appState: AppState) {
        appState.currentFlight = flight
        appState.isFlightActive = true
        appState.currentPhase = currentPhase
        appState.engineStartTime = engineStartTime
        appState.lineUpTime = lineUpTime
        appState.landingTime = landingTime
        appState.engineShutdownTime = engineShutdownTime
        appState.phaseCompletionStatus = phaseCompletionStatus
        appState.highestCompletedPhase = highestCompletedPhase
        appState.currentHighlightedItem = currentHighlightedItem
        appState.hasLandingBeenDetected = hasLandingBeenDetected
        appState.isCircuitMode = isCircuitMode
        // Re-apply the captured aircraft selection so the active checklist resolves to the
        // restored flight's aircraft. The premium checklist body is re-fetched at launch (see
        // AeroCheckApp's `.task`); until it resolves, `activeChecklist` reports `.unresolved`
        // rather than falling back to WT9 content. (ARCH-08 / ARCH-01)
        appState.settings.selectedAircraft = selectedAircraft
        appState.settings.selectedRemoteAircraftId = selectedRemoteAircraftId
    }
}

/// Main application state manager
@MainActor
class AppState: ObservableObject {
    // MARK: - Published Properties

    // Checklist progress (current phase, completion status, highest phase reached, highlight index)
    // grouped into one cohesive ChecklistProgress value. The forwarding accessors below keep every
    // existing `appState.currentPhase` / … call site working and reactive. (Phase 4 — decomposition)
    @Published var checklistProgress = ChecklistProgress()

    var currentPhase: ChecklistPhase {
        get { checklistProgress.currentPhase }
        set { checklistProgress.currentPhase = newValue }
    }
    @Published var isFlightActive: Bool = false
    @Published var currentFlight: Flight?

    // MARK: - Cruise check (FREDA) reminder
    /// Re-cruise (FREDA: Fuel, Radio, Engine, Direction, Altimeter) interval — standard VFR practice
    /// is a check every 10–15 minutes in cruise. (v4 UI/UX Revamp)
    static let cruiseCheckInterval: TimeInterval = 15 * 60 // standard VFR re-cruise check every ~15 min
    /// True when a cruise check is due/overdue — drives the amber phase indicator + CRUISE button. (v4 UI/UX Revamp)
    @Published var cruiseCheckDue: Bool = false
    /// When the countdown was started / last re-armed; nil = idle (NOT started). The countdown is
    /// MANUAL — the pilot starts it from the CRUISE button on the Cruise checklist page, so a busy
    /// pilot is never reminded for a check they haven't begun timing. (v4 UI/UX Revamp — manual start)
    @Published var cruiseCheckStartTime: Date?

    /// Seconds remaining until the next cruise check is due — the full interval while idle. (v4 UI/UX Revamp)
    func cruiseCheckRemaining(now: Date = Date()) -> TimeInterval {
        guard let start = cruiseCheckStartTime else { return Self.cruiseCheckInterval }
        return max(0, Self.cruiseCheckInterval - now.timeIntervalSince(start))
    }

    /// Re-evaluate whether a cruise check is due. The countdown only runs once the pilot has started
    /// it (`cruiseCheckStartTime != nil`); leaving cruise clears + idles it. Call periodically while
    /// in cruise. (v4 UI/UX Revamp)
    func evaluateCruiseCheck(now: Date = Date()) {
        guard currentPhase == .cruise else {
            if cruiseCheckDue { cruiseCheckDue = false }
            cruiseCheckStartTime = nil
            return
        }
        guard let start = cruiseCheckStartTime else { return } // idle until the pilot starts it
        if !cruiseCheckDue, now.timeIntervalSince(start) >= Self.cruiseCheckInterval {
            cruiseCheckDue = true
            // Re-arm the Cruise checklist so the pilot re-runs the check: reset its highlight to the
            // first item and clear its completion status (items show undone again). (v4 UI/UX Revamp)
            currentHighlightedItem[.cruise] = 0
            phaseCompletionStatus[.cruise] = nil
        }
    }

    /// Start / re-arm the cruise-check countdown from the full interval. One method backs every gesture:
    /// tap-to-start (idle), tap-to-acknowledge (due), and hold-to-reset (any time). (v4 UI/UX Revamp — manual start)
    func armCruiseCheck() {
        cruiseCheckStartTime = Date()
        cruiseCheckDue = false
    }

    /// Acknowledge a due cruise check — identical to re-arming the countdown. (v4 UI/UX Revamp)
    func acknowledgeCruiseCheck() { armCruiseCheck() }
    /// Set when a flight start is refused (e.g. a premium aircraft's checklist isn't loaded, or
    /// location permission is denied). Observed by the UI to show an explanatory alert. (ARCH-01/UX-13)
    @Published var flightStartError: String?

    /// Set when a flight start is refused because the requested premium aircraft isn't owned.
    /// Observed by the UI to present the subscription paywall. (UX-07)
    @Published var flightStartPaywallRequest: Bool = false

    /// The resolved remote checklist for the current selection — a premium aircraft, or a
    /// language-specific bundled checklist. `nil` means none is loaded (the bundled fallback is
    /// used, unless a premium aircraft is selected, in which case the checklist is unresolved).
    /// Only mutated by `loadRemoteChecklistIfNeeded` / `syncAircraftType`.
    @Published private(set) var resolvedRemoteChecklist: RemoteAircraftChecklist?

    /// The owned, fully-resolved checklist + speeds for the current selection. Every checklist /
    /// speed reader uses this instead of the former global `ChecklistData` statics, so a premium
    /// aircraft never falls back to the bundled WT9's content. (ARCH-01)
    var activeChecklist: ActiveChecklist {
        if let checklist = resolvedRemoteChecklist {
            return ActiveChecklist(source: .remote(checklist))
        }
        if settings.selectedRemoteAircraftId != nil {
            return ActiveChecklist(source: .unresolved)
        }
        return ActiveChecklist(source: .bundled(settings.selectedAircraft))
    }

    /// True unless a premium aircraft is selected but its checklist hasn't resolved.
    /// Callers must not begin a flight (or GPS tracking) when this is false. (ARCH-01)
    var isPremiumChecklistResolved: Bool {
        settings.selectedRemoteAircraftId == nil || resolvedRemoteChecklist != nil
    }
    @Published var flights: [Flight] = []
    @Published var isLoadingFlights: Bool = true
    /// Device-local onboarding gate (NOT the iCloud-synced `settings.hasCompletedOnboarding`). Onboarding
    /// offers per-device setup (data downloads, location), so it must show once per device — including a
    /// reinstall, where the synced flag would otherwise restore from iCloud and suppress it. (bug 1)
    @Published var hasSeenOnboarding: Bool = false
    @Published var settings: AppSettings = AppSettings()
    @Published var showFlightLog: Bool = false

    /// Set when iCloud sync auto-merged (or couldn't merge) a conflicting flight edit, so the UI can
    /// surface it instead of the conflict being silent. (ARCH-02)
    @Published var syncConflictNotice: String?

    /// Set when a just-finished flight could not be written to disk at endFlight. The crash-recovery
    /// checkpoint is deliberately kept (the flight is NOT lost) and restored/retried on next launch;
    /// this surfaces the failure to the pilot instead of it being silent. (PR-14)
    @Published var flightSaveError: String?

    /// Set when a flight was restored from the crash-recovery checkpoint on launch and GPS recording
    /// was resumed automatically, so the pilot knows tracking is live again. (PR-01)
    @Published var flightRestoredNotice: String?

    /// Set when the loaded checklist was served in a different language than requested (the requested
    /// language isn't available for that aircraft), so the pilot is told before flight rather than
    /// silently shown a foreign-language checklist. Surfaced as a non-blocking banner. (PR-41 / UX-08)
    @Published var languageFallbackNotice: String?

    // Navigation view session state (not persisted to disk — resets on app restart).
    // One cohesive value (selected layer + orientation) instead of two loose @Published properties.
    @Published var navigationMapState = NavigationMapState()

    // Recorded times during flight — grouped into one cohesive FlightTiming value (extracted from
    // four loose @Published timestamps). The forwarding accessors below keep every existing call
    // site (`appState.engineStartTime`, …) working and reactive without a risky 177-site rename
    // (Flight has identically-named fields). (Phase 4 — AppState decomposition: state extraction)
    @Published var flightTiming = FlightTiming()

    var engineStartTime: Date? {
        get { flightTiming.engineStartTime }
        set { flightTiming.engineStartTime = newValue }
    }
    var lineUpTime: Date? {
        get { flightTiming.lineUpTime }
        set { flightTiming.lineUpTime = newValue }
    }
    var landingTime: Date? {
        get { flightTiming.landingTime }
        set { flightTiming.landingTime = newValue }
    }
    var engineShutdownTime: Date? {
        get { flightTiming.engineShutdownTime }
        set { flightTiming.engineShutdownTime = newValue }
    }
    
    // Phase completion tracking + step-by-step highlighting — forwarding accessors over the
    // cohesive `checklistProgress` value declared above.
    var phaseCompletionStatus: [ChecklistPhase: PhaseCompletionStatus] {
        get { checklistProgress.phaseCompletionStatus }
        set { checklistProgress.phaseCompletionStatus = newValue }
    }
    var highestCompletedPhase: ChecklistPhase {
        get { checklistProgress.highestCompletedPhase }
        set { checklistProgress.highestCompletedPhase = newValue }
    }
    var currentHighlightedItem: [ChecklistPhase: Int] {
        get { checklistProgress.currentHighlightedItem }
        set { checklistProgress.currentHighlightedItem = newValue }
    }
    
    // Landing detection
    @Published var hasLandingBeenDetected: Bool = false
    private var consecutiveLowSpeedReadings: Int = 0
    private let lowSpeedThreshold: Double = 2.0 // m/s (about 4 knots)
    private let requiredLowSpeedReadings: Int = 3

    // Block time detection
    private var consecutiveMovingReadings: Int = 0
    private var recentStoppedTimestamps: [Date] = [] // Time-window approach for block on
    private var lastStopLocation: (latitude: Double, longitude: Double)?
    private let blockOffSpeedThreshold: Double = 2.0 // m/s (about 4 knots) - sustained movement
    private let blockOnSpeedThreshold: Double = 2.0 // m/s (about 4 knots) - matches GPS noise floor for parked aircraft
    private let requiredMovingReadings: Int = 2 // At 5-second intervals, this is ~10 seconds
    private let blockOnTimeWindow: TimeInterval = 30.0 // 30-second window for block on detection
    private let requiredStoppedInWindow: Int = 2 // 2 low-speed readings within window = stopped

    // Circuit mode - skips CRUISE and DESCENT phases
    @Published var isCircuitMode: Bool = false

    // MARK: - Private Properties

    /// Small pointer kept in UserDefaults (the durable checkpoint itself is a file). Stores the
    /// last checkpoint's `savedAt` so existence/age can be checked without decoding the file.
    private let activeFlightPointerKey = "activeFlightCheckpointSavedAt"
    /// Pre-4.x UserDefaults blob key — removed on the first clear so it can't linger after upgrade.
    private let legacyActiveFlightStateKey = "activeFlightState"

    // MARK: - Active flight checkpointing (crash recovery, PERF-02/PERF-13)
    /// Checkpoint at least every N recorded GPS points…
    private static let checkpointPointInterval = 20
    /// …or at least this often, whichever comes first.
    private static let checkpointTimeInterval: TimeInterval = 30
    /// Serial queue for the off-main checkpoint encode + atomic write (PR-12). Serial so a stale
    /// write can never overtake a newer one; utility QoS so it never competes with the in-flight UI.
    private static let checkpointQueue = DispatchQueue(label: "app.aerocheck.activeFlightCheckpoint", qos: .utility)
    private var pointsSinceCheckpoint = 0
    private var lastCheckpointAt: Date?

    // Reference to persistence manager
    private let persistence = DataPersistenceManager.shared

    // MARK: - Initialization

    init() {
        // Load settings synchronously (fast, needed for initial UI)
        loadSettings()

        // Seed the device-local onboarding gate. We read it from the LOCAL settings BEFORE any iCloud
        // sync can run, so an in-place UPGRADE that already finished onboarding (local flag true) skips
        // it, while a fresh install / reinstall (no local settings → false) shows it — even though the
        // synced flag will later arrive as true on a reinstall. (bug 1)
        if UserDefaults.standard.object(forKey: hasSeenOnboardingKey) == nil {
            hasSeenOnboarding = settings.hasCompletedOnboarding
            UserDefaults.standard.set(hasSeenOnboarding, forKey: hasSeenOnboardingKey)
        } else {
            hasSeenOnboarding = UserDefaults.standard.bool(forKey: hasSeenOnboardingKey)
        }

        syncAircraftType()
        setupSyncCallbacks()

        // Try to restore active flight state if app was closed during a flight
        restoreActiveFlightState()

        // Load flights in background - iCloud file enumeration can be slow
        // and should not block the main thread during startup
        Task { [weak self] in
            guard let self = self else { return }
            await self.loadFlightsAsync()
        }
    }

    /// Load flights asynchronously to avoid blocking startup. The directory enumeration + per-flight
    /// JSON decode (including every GPS track) now runs off the main actor, so a large logbook never
    /// stalls launch; the result is assigned back on the main actor. (PR-24)
    private func loadFlightsAsync() async {
        // Yield to let the first frame render before doing I/O
        await Task.yield()

        flights = await persistence.loadFlightsOffMain()
        isLoadingFlights = false

        // Auto-complete onboarding for existing users (they already know the app)
        if !settings.hasCompletedOnboarding && !flights.isEmpty {
            settings.hasCompletedOnboarding = true
            persistence.saveSettings(settings)
        }
    }

    /// Setup callbacks for sync updates from other devices
    private func setupSyncCallbacks() {
        let syncManager = SyncManager.shared

        syncManager.onSettingsUpdated = { [weak self] settings in
            Task { @MainActor in
                self?.settings = settings
                // Save synced settings to file for future loads
                self?.persistence.saveSettings(settings)
                self?.syncAircraftType()
                AppLog.general.debugLine("Settings updated from iCloud sync")
            }
        }

        syncManager.onFlightsUpdated = { [weak self] flights in
            Task { @MainActor in
                guard let self else { return }
                // PR-09: persist only the flights whose content actually changed (by modifiedAt),
                // instead of rewriting EVERY flight file. Batched OFF the main actor (was a per-flight
                // saveFlight on the main actor — a visible hitch when a large initial sync landed).
                let previousById = Dictionary(self.flights.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                self.flights = flights
                // Sync delivered the logbook — clear the launch spinner in case the initial local
                // load found nothing (e.g. a fresh install whose flights only exist in CloudKit). (fresh-install fix)
                self.isLoadingFlights = false
                let changed = flights.filter { previousById[$0.id]?.modifiedAt != $0.modifiedAt }
                await self.persistence.saveFlightsOffMain(changed)
                AppLog.general.debugLine("Flights updated from iCloud sync")
            }
        }

        syncManager.onSyncConflict = { [weak self] message in
            Task { @MainActor in
                self?.syncConflictNotice = message
                AppLog.general.debugLine("Sync conflict: \(message)")
            }
        }
    }

    /// Reconcile the resolved checklist with the current selection.
    /// Drops any resolved remote checklist when no remote aircraft is selected, so the active
    /// checklist falls back to the bundled aircraft until a (language-specific) checklist loads.
    private func syncAircraftType() {
        if settings.selectedRemoteAircraftId == nil {
            resolvedRemoteChecklist = nil
        }
    }

    /// Load the appropriate checklist for the selected aircraft and language
    /// Call this before starting a flight
    func loadRemoteChecklistIfNeeded(aircraftDataService: AircraftDataService) async {
        let language = settings.checklistLanguage.resolvedLanguage

        // Handle remote (premium) aircraft
        if let remoteId = settings.selectedRemoteAircraftId {
            if let checklist = await aircraftDataService.fetchChecklist(for: remoteId, language: language) {
                resolvedRemoteChecklist = checklist
                noteLanguageFallback(for: checklist, requested: language)
                AppLog.general.debugLine("Loaded remote checklist for \(remoteId) (\(language))")
            } else {
                AppLog.general.debugLine("Failed to load remote checklist for \(remoteId)")
                resolvedRemoteChecklist = nil
            }
            return
        }

        // Handle bundled aircraft with language-specific checklists
        // For bundled aircraft like the WT9, load the language-specific JSON into
        // resolvedRemoteChecklist so the active checklist uses it instead of the hardcoded
        // WT9ChecklistData.
        let aircraftType = settings.selectedAircraft
        if aircraftType == .wt9Dynamic {
            let bundledId = "wt9-dynamic"

            // First try to get a cached/API version for this language
            if let checklist = await aircraftDataService.fetchChecklist(for: bundledId, language: language) {
                resolvedRemoteChecklist = checklist
                noteLanguageFallback(for: checklist, requested: language)
                AppLog.general.debugLine("Loaded checklist for bundled aircraft \(bundledId) (\(language))")
            } else if let bundled = BundledChecklistService.loadBundledChecklist(for: bundledId, language: language) {
                // Fall back to bundled resource
                resolvedRemoteChecklist = bundled
                AppLog.general.debugLine("Loaded bundled checklist for \(bundledId) (\(language))")
            } else {
                // No language-specific checklist available, use hardcoded default
                resolvedRemoteChecklist = nil
                AppLog.general.debugLine("Using default checklist for \(bundledId)")
            }
        } else {
            resolvedRemoteChecklist = nil
        }
    }

    /// Surfaces a non-blocking notice when the loaded checklist was served in a language other than
    /// the one requested (the requested language isn't available for that aircraft). (PR-41 / UX-08)
    private func noteLanguageFallback(for checklist: RemoteAircraftChecklist, requested: String) {
        // Prefer the server's explicit flag; fall back to comparing served vs requested language.
        let served = checklist.language
        let fellBack = checklist.languageFallback ?? (served != nil && served != requested)
        guard fellBack, let served, served != requested else {
            return
        }
        languageFallbackNotice = L10n.Aircraft.checklistLanguageOnly(Self.languageDisplayName(served))
    }

    /// Human-readable language name for a checklist language code (aviation languages only).
    static func languageDisplayName(_ code: String) -> String {
        switch code.lowercased() {
        case "en": return "English"
        case "fr": return "Français"
        case "de": return "Deutsch"
        case "it": return "Italiano"
        default: return code.uppercased()
        }
    }

    // MARK: - Aircraft Selection

    /// Select the aircraft for the next flight by an identifier or registration.
    ///
    /// Matches against bundled aircraft and the supplied remote metadata, by `id` **or**
    /// `registration` — a deep link or widget may pass either token. Updates the persisted
    /// selection (`selectedRemoteAircraftId` for premium, `selectedAircraft` for bundled) via
    /// `saveSettings()`, which reconciles the resolved/active checklist with the selection.
    ///
    /// Returns `false` for an unknown token so a caller (e.g. a deep link) can refuse to start a
    /// flight rather than launch the wrong or empty aircraft. (UX-11)
    @discardableResult
    func selectAircraft(id: String, available: [RemoteAircraftMetadata]) -> Bool {
        // Bundled aircraft — match by enum id (rawValue), server id, or registration. Checked
        // before remote so a bundled aircraft never resolves to its remote/server duplicate.
        if let bundled = AircraftType.allCases.first(where: { $0.rawValue == id || $0.serverId == id || $0.registration == id }) {
            if settings.selectedRemoteAircraftId != nil || settings.selectedAircraft != bundled {
                settings.selectedRemoteAircraftId = nil
                settings.selectedAircraft = bundled
                saveSettings() // syncAircraftType() runs here, clearing any stale remote checklist
            }
            return true
        }

        // Remote / premium aircraft — match by id or registration.
        if let remote = available.first(where: { $0.id == id || $0.registration == id }) {
            if settings.selectedRemoteAircraftId != remote.id {
                settings.selectedRemoteAircraftId = remote.id
                saveSettings()
            }
            return true
        }

        // Unknown token — leave the current selection untouched.
        return false
    }

    // MARK: - Flight Management

    func startFlight() {
        startFlight(
            withAircraft: settings.defaultAirplane,
            aircraftRegistration: settings.selectedAircraft.registration,
            aircraftType: settings.selectedAircraft.rawValue,
            checklistVersion: settings.selectedAircraft.checklistVersion,
            flightPlanId: nil,
            circuitMode: false
        )
    }

    func startFlight(withAircraft aircraft: String, aircraftRegistration: String? = nil, aircraftType: String? = nil, checklistVersion: String? = nil, flightPlanId: UUID? = nil, circuitMode: Bool = false) {
        // ARCH-01: never begin a flight for a premium aircraft without its resolved checklist —
        // this is the single choke point, so deep-link/widget entry points are covered too. A
        // blocked start surfaces an explicit error instead of silently showing WT9 content.
        if !isPremiumChecklistResolved {
            flightStartError = L10n.Alert.checklistNotReady
            AppLog.general.debugLine("Flight start blocked: premium checklist not resolved")
            return
        }
        flightStartError = nil
        currentFlight = Flight(
            airplane: aircraft,
            aircraftRegistration: aircraftRegistration,
            aircraftType: aircraftType,
            checklistVersion: checklistVersion,
            flightPlanId: flightPlanId,
            startTime: Date()
        )
        currentPhase = .preflight
        isFlightActive = true
        isCircuitMode = circuitMode
        engineStartTime = nil
        lineUpTime = nil
        landingTime = nil
        engineShutdownTime = nil
        phaseCompletionStatus = [:]
        highestCompletedPhase = .preflight
        hasLandingBeenDetected = false
        consecutiveLowSpeedReadings = 0
        consecutiveMovingReadings = 0
        recentStoppedTimestamps = []
        lastStopLocation = nil
        currentHighlightedItem = [:] // Reset highlighting
    }
    
    func endFlight(withFlightPlan flightPlan: FlightPlan? = nil) {
        guard var flight = currentFlight else { return }

        flight.stopTime = Date()
        flight.engineStartTime = engineStartTime
        flight.lineUpTime = lineUpTime
        flight.landingTime = landingTime
        flight.engineShutdownTime = engineShutdownTime
        flight.flightPlan = flightPlan
        // Block times are already set on currentFlight, copy them to the final flight
        // (they're already there since we modify currentFlight directly)

        // Precompute summary stats once now that the track is final, so the flight-log list
        // never recomputes an O(n) distance per row. (PERF-22)
        flight.computeSummaryStats()

        flights.insert(flight, at: 0)
        // PR-14: persist the just-finished flight with a CONFIRMED write before discarding the
        // crash-recovery checkpoint (active_flight.json) — the only durable copy of this flight.
        // PR-09: saveFlight persists + syncs ONLY this flight; loadFlights scans the directory, so
        // no whole-logbook rewrite/re-upload is needed when one flight is added.
        let saved = saveFlight(flight)

        currentFlight = nil
        isFlightActive = false
        isCircuitMode = false
        engineStartTime = nil
        lineUpTime = nil
        landingTime = nil
        engineShutdownTime = nil
        phaseCompletionStatus = [:]
        currentPhase = .preflight
        hasLandingBeenDetected = false
        consecutiveMovingReadings = 0
        recentStoppedTimestamps = []
        lastStopLocation = nil

        if saved {
            // Flight ended normally AND was persisted — safe to clear the checkpoint.
            clearActiveFlightState()
        } else {
            // The write failed (disk full / iCloud container error). Keep the checkpoint so the
            // flight is not lost; it is restored and re-saved on next launch. Alert the pilot. (PR-14)
            flightSaveError = L10n.Alert.flightSaveFailed
        }
    }

    func cancelFlight() {
        currentFlight = nil
        isFlightActive = false
        isCircuitMode = false
        engineStartTime = nil
        lineUpTime = nil
        landingTime = nil
        engineShutdownTime = nil
        phaseCompletionStatus = [:]
        currentPhase = .preflight
        hasLandingBeenDetected = false
        consecutiveMovingReadings = 0
        recentStoppedTimestamps = []
        lastStopLocation = nil
        currentHighlightedItem = [:]

        // Clear saved flight state since flight was cancelled
        clearActiveFlightState()
    }
    
    // MARK: - Step-by-Step Highlighting
    
    /// Get the current highlighted item index for a phase (0-based)
    func getHighlightedItem(for phase: ChecklistPhase) -> Int {
        return currentHighlightedItem[phase] ?? 0
    }
    
    /// Advance to the next item in the current phase (rules in `ChecklistHighlighting`). `learningMode`
    /// is the EFFECTIVE mode (the global setting OR temporarily-revealed hidden items), so tap-to-advance
    /// steps through revealed/learning-mode items too. (v4 UI/UX Revamp feedback)
    func advanceHighlightedItem(learningMode: Bool) {
        let currentIndex = currentHighlightedItem[currentPhase] ?? 0
        let visibleCount = activeChecklist.visibleItemCount(for: currentPhase, learningMode: learningMode)
        currentHighlightedItem[currentPhase] = ChecklistHighlighting.advanced(current: currentIndex, visibleCount: visibleCount)
    }

    /// Mark the last item as complete (moves index past the last item). `learningMode` = effective mode.
    func markLastItemComplete(learningMode: Bool) {
        let visibleCount = activeChecklist.visibleItemCount(for: currentPhase, learningMode: learningMode)
        currentHighlightedItem[currentPhase] = ChecklistHighlighting.lastItemComplete(visibleCount: visibleCount)
        // Completing the Cruise checklist auto-starts the cruise-check countdown — running the check IS
        // the trigger, so the pilot never has to remember to start the timer. (v4 UI/UX Revamp)
        if currentPhase == .cruise { armCruiseCheck() }
    }

    /// Check if all items in current phase are completed. `learningMode` = effective mode.
    func areAllItemsCompleted(learningMode: Bool) -> Bool {
        let visibleCount = activeChecklist.visibleItemCount(for: currentPhase, learningMode: learningMode)
        let currentIndex = currentHighlightedItem[currentPhase] ?? 0
        return ChecklistHighlighting.allItemsCompleted(current: currentIndex, visibleCount: visibleCount)
    }
    
    /// Reset highlighted item for a phase
    func resetHighlightedItem(for phase: ChecklistPhase) {
        currentHighlightedItem[phase] = 0
    }
    
    func recordEngineStart() {
        engineStartTime = Date()
        currentFlight?.engineStartTime = engineStartTime
        checkpointActiveFlight(force: true)
    }

    func recordLineUpTime() {
        // Adds 2 minutes to current time as specified
        lineUpTime = Date().addingTimeInterval(120)
        currentFlight?.lineUpTime = lineUpTime
        checkpointActiveFlight(force: true)
    }

    /// A detected stop/landing is back-dated ~1 min (the aircraft was already slowing) but never
    /// before line-up — otherwise flight time (landing − line-up) goes negative. (v4.0.0 review P2)
    private func backDatedStopTime() -> Date {
        let candidate = Date().addingTimeInterval(-60)
        if let lineUp = lineUpTime, candidate < lineUp { return lineUp }
        return candidate
    }

    func recordLanding() {
        // Removes 1 minute (while vacating the runway)
        landingTime = backDatedStopTime()
        currentFlight?.landingTime = landingTime
        hasLandingBeenDetected = true

        // The final landing is always a full-stop landing
        if let time = landingTime {
            currentFlight?.fullStopCount += 1
            currentFlight?.fullStopTimes.append(time)
        }
        checkpointActiveFlight(force: true)
    }

    /// Update landing time to current time minus 1 minute (for long-press update)
    func updateLandingTime() {
        landingTime = backDatedStopTime()
        currentFlight?.landingTime = landingTime
    }
    
    func recordEngineShutdown() {
        engineShutdownTime = Date()
        currentFlight?.engineShutdownTime = engineShutdownTime

        // Fallback: if no block on was detected but block off exists, use engine shutdown time
        // The aircraft is definitely stopped when the pilot records engine shutdown
        if currentFlight?.blockOnTime == nil && currentFlight?.blockOffTime != nil {
            currentFlight?.blockOnTime = engineShutdownTime
            if let lastPoint = currentFlight?.gpsTrack.last {
                currentFlight?.blockOnLatitude = lastPoint.latitude
                currentFlight?.blockOnLongitude = lastPoint.longitude
            }
            AppLog.general.debugLine("Block on time set from engine shutdown (fallback)")
        }
        checkpointActiveFlight(force: true)
    }

    /// Record a go-around and return to climb phase, resetting subsequent phases
    func recordGoAround() {
        let goAroundTime = Date()
        currentFlight?.goAroundCount += 1
        currentFlight?.goAroundTimes.append(goAroundTime)

        // Reset phases from climb onwards
        for phase in ChecklistPhase.allCases {
            if phase.rawValue >= ChecklistPhase.climb.rawValue {
                phaseCompletionStatus[phase] = nil
                currentHighlightedItem[phase] = 0
            }
        }

        // Go to climb phase
        currentPhase = .climb
    }

    /// Record a touch-and-go and return to climb phase, resetting subsequent phases
    func recordTouchAndGo() {
        let touchAndGoTime = Date()
        currentFlight?.touchAndGoCount += 1
        currentFlight?.touchAndGoTimes.append(touchAndGoTime)

        // Reset phases from climb onwards
        for phase in ChecklistPhase.allCases {
            if phase.rawValue >= ChecklistPhase.climb.rawValue {
                phaseCompletionStatus[phase] = nil
                currentHighlightedItem[phase] = 0
            }
        }

        // Go to climb phase
        currentPhase = .climb
    }

    /// Record a full stop landing and return to taxi phase, resetting subsequent phases
    func recordFullStop() {
        let fullStopTime = backDatedStopTime() // Remove 1 min, but never before line-up
        currentFlight?.fullStopCount += 1
        currentFlight?.fullStopTimes.append(fullStopTime)

        // Reset phases from taxi onwards (taxi through afterLanding)
        for phase in ChecklistPhase.allCases {
            if phase.rawValue >= ChecklistPhase.taxi.rawValue && phase.rawValue <= ChecklistPhase.afterLanding.rawValue {
                phaseCompletionStatus[phase] = nil
                currentHighlightedItem[phase] = 0
            }
        }

        // Go to taxi phase
        currentPhase = .taxi
    }

    func addGPSPoint(_ point: GPSPoint, airportDataService: AirportDataService? = nil) {
        currentFlight?.gpsTrack.append(point)

        // Snapshot the auto-detected event fields so a newly-detected event forces a checkpoint.
        let hadBlockOff = currentFlight?.blockOffTime != nil
        let hadBlockOn = currentFlight?.blockOnTime != nil
        let hadLanding = hasLandingBeenDetected

        // Block off detection: after ENGINE START, detect first sustained movement
        if engineStartTime != nil && currentFlight?.blockOffTime == nil {
            checkForBlockOff(point: point, airportDataService: airportDataService)
        }

        // Block on detection: after block off, track last stop location before ENGINE STOP
        if currentFlight?.blockOffTime != nil && engineShutdownTime == nil {
            checkForBlockOn(point: point, airportDataService: airportDataService)
        }

        // Auto-detect landing when in After Landing phase
        if currentPhase == .afterLanding && !hasLandingBeenDetected {
            checkForLanding(speed: point.speed)
        }

        // Durable crash-recovery checkpoint: throttled by cadence, but forced immediately when a
        // major event (block off/on, landing) was just detected so it survives a crash. (PERF-02)
        pointsSinceCheckpoint += 1
        let majorEvent = (currentFlight?.blockOffTime != nil && !hadBlockOff)
            || (currentFlight?.blockOnTime != nil && !hadBlockOn)
            || (hasLandingBeenDetected && !hadLanding)
        checkpointActiveFlight(force: majorEvent)
    }
    
    private func checkForLanding(speed: Double) {
        // speed < 0 (CLLocation returns -1 for indeterminate speed) indicates stationary
        if speed < 0 || speed < lowSpeedThreshold {
            consecutiveLowSpeedReadings += 1
            if consecutiveLowSpeedReadings >= requiredLowSpeedReadings {
                // Plane has stopped - record landing time (minus 1 minute)
                landingTime = backDatedStopTime()
                currentFlight?.landingTime = landingTime
                hasLandingBeenDetected = true
            }
        } else {
            consecutiveLowSpeedReadings = 0
        }
    }

    /// Check for block off time (first sustained movement after ENGINE START)
    private func checkForBlockOff(point: GPSPoint, airportDataService: AirportDataService?) {
        if point.speed >= blockOffSpeedThreshold {
            consecutiveMovingReadings += 1
            if consecutiveMovingReadings >= requiredMovingReadings {
                // Aircraft is moving - record block off
                let blockOffTime = Date()
                currentFlight?.blockOffTime = blockOffTime
                currentFlight?.blockOffLatitude = point.latitude
                currentFlight?.blockOffLongitude = point.longitude

                // Find nearest airport
                if let airportService = airportDataService {
                    let coordinate = point.coordinate
                    let nearestAirports = airportService.findNearestAirports(to: coordinate, limit: 1, maxDistanceNm: 5.0)
                    if let nearest = nearestAirports.first {
                        currentFlight?.departureAirportIdent = nearest.ident
                        AppLog.general.debugLine("Block off detected at \(nearest.ident) (\(nearest.name))")
                    }
                }
                AppLog.general.debugLine("Block off time recorded: \(blockOffTime)")
            }
        } else {
            consecutiveMovingReadings = 0
        }
    }

    /// Check for block on time (sustained stop before ENGINE STOP)
    /// Uses a time-window approach: if enough low-speed readings occur within a window,
    /// the aircraft is considered stopped. This handles GPS gaps and noise gracefully.
    /// CLLocation speed of -1 (indeterminate) is treated as stopped since it typically
    /// occurs when the device is stationary.
    private func checkForBlockOn(point: GPSPoint, airportDataService: AirportDataService?) {
        let now = Date()

        if point.speed < 0 || point.speed < blockOnSpeedThreshold {
            // Low speed or indeterminate (-1) — record as a stopped reading
            recentStoppedTimestamps.append(now)

            // Prune timestamps older than the time window
            recentStoppedTimestamps = recentStoppedTimestamps.filter { now.timeIntervalSince($0) <= blockOnTimeWindow }

            if recentStoppedTimestamps.count >= requiredStoppedInWindow {
                // Aircraft has stopped - update block on time (keep updating until engine shutdown)
                let blockOnTime = now
                currentFlight?.blockOnTime = blockOnTime
                currentFlight?.blockOnLatitude = point.latitude
                currentFlight?.blockOnLongitude = point.longitude

                // Find nearest airport (only if changed or not set)
                if let airportService = airportDataService {
                    let coordinate = point.coordinate
                    let nearestAirports = airportService.findNearestAirports(to: coordinate, limit: 1, maxDistanceNm: 5.0)
                    if let nearest = nearestAirports.first {
                        // Only update if different from current or not set
                        if currentFlight?.arrivalAirportIdent != nearest.ident {
                            currentFlight?.arrivalAirportIdent = nearest.ident
                            AppLog.general.debugLine("Block on location updated: \(nearest.ident) (\(nearest.name))")
                        }
                    }
                }
            }
        } else {
            // Aircraft is moving — clear stopped timestamps
            recentStoppedTimestamps = []
        }
    }
    
    // MARK: - Navigation
    
    func nextPhase() {
        guard let currentIndex = ChecklistPhase.allCases.firstIndex(of: currentPhase),
              currentIndex + 1 < ChecklistPhase.allCases.count else { return }
        
        // Advancing from the current phase: .missingAction if a required button wasn't pressed; else
        // .completed ONLY if the checklist was actually worked through (all step-by-step items reached),
        // otherwise .skipped. Since NEXT is tappable while a phase is still incomplete, pressing past an
        // un-worked phase must read as skipped (orange), not done (green). (round 6 regression fix)
        let checklistWorkedThrough = !settings.stepByStepHighlighting
            || areAllItemsCompleted(learningMode: settings.learningMode)
        if currentPhase.hasMissingRequiredAction(
            engineStarted: engineStartTime != nil,
            linedUp: lineUpTime != nil,
            engineShutDown: engineShutdownTime != nil) {
            phaseCompletionStatus[currentPhase] = .missingAction
        } else {
            phaseCompletionStatus[currentPhase] = checklistWorkedThrough ? .completed : .skipped
        }
        
        // Update highest completed phase
        if currentPhase.rawValue >= highestCompletedPhase.rawValue {
            highestCompletedPhase = currentPhase
        }

        // Calculate the next phase, skipping CRUISE and DESCENT in circuit mode (marking each
        // skipped phase as .skipped along the way — that side effect stays here).
        var nextIndex = currentIndex + 1
        while nextIndex < ChecklistPhase.allCases.count {
            let nextPhase = ChecklistPhase.allCases[nextIndex]
            if nextPhase.isSkippedInCircuitMode(isCircuitMode) {
                phaseCompletionStatus[nextPhase] = .skipped
                nextIndex += 1
            } else {
                break
            }
        }

        if nextIndex < ChecklistPhase.allCases.count {
            currentPhase = ChecklistPhase.allCases[nextIndex]
        }
    }

    func previousPhase() {
        // The previous-navigable rule (with circuit-mode skipping) lives on ChecklistPhase.
        if let target = currentPhase.previousNavigable(circuitMode: isCircuitMode) {
            currentPhase = target
        }
    }

    func goToPhase(_ phase: ChecklistPhase) {
        // In circuit mode, don't allow navigation to CRUISE or DESCENT
        if phase.isSkippedInCircuitMode(isCircuitMode) {
            return
        }

        // When jumping to a phase, mark any skipped phases appropriately
        if let currentIndex = ChecklistPhase.allCases.firstIndex(of: currentPhase),
           let targetIndex = ChecklistPhase.allCases.firstIndex(of: phase) {

            if targetIndex > currentIndex {
                // Jumping forward - mark skipped phases
                for i in currentIndex..<targetIndex {
                    let skippedPhase = ChecklistPhase.allCases[i]
                    if phaseCompletionStatus[skippedPhase] == nil {
                        // Jumped over this phase: .missingAction if it had an unpressed required button, else .skipped.
                        phaseCompletionStatus[skippedPhase] = skippedPhase.hasMissingRequiredAction(
                            engineStarted: engineStartTime != nil,
                            linedUp: lineUpTime != nil,
                            engineShutDown: engineShutdownTime != nil) ? .missingAction : .skipped
                    }
                }
            }
        }
        currentPhase = phase
    }
    
    /// Get the completion status for a phase
    func getPhaseStatus(_ phase: ChecklistPhase) -> PhaseCompletionStatus {
        // If we have an explicit status recorded, use it
        if let status = phaseCompletionStatus[phase] {
            return status
        }
        
        // Current phase is always "in progress" (not started)
        if phase == currentPhase {
            return .notStarted
        }
        
        // Future phases (after current) are not started
        if phase.rawValue > currentPhase.rawValue {
            return .notStarted
        }
        
        // Past phases (before current) that weren't marked should be skipped
        // This handles the case where user jumped forward without completing
        if phase.rawValue < currentPhase.rawValue {
            // Check if this phase had a required action
            if phase.showsEngineStartButton && engineStartTime == nil {
                return .missingAction
            } else if phase.showsLineUpButton && lineUpTime == nil {
                return .missingAction
            } else if phase.showsEngineShutdownButton && engineShutdownTime == nil {
                return .missingAction
            }
            return .skipped
        }
        
        return .notStarted
    }
    
    // MARK: - Flight Log Management

    func deleteFlight(_ flight: Flight) {
        flights.removeAll { $0.id == flight.id }

        // Delete the individual flight file from iCloud
        persistence.deleteFlight(flight)

        // Sync deletion to iCloud (CloudKit)
        if settings.iCloudSyncEnabled {
            SyncManager.shared.deleteFlight(flight.id)
        }
    }

    func deleteFlight(at indexSet: IndexSet) {
        // Get flights before removal for file cleanup and sync
        let flightsToDelete = indexSet.map { flights[$0] }

        flights.remove(atOffsets: indexSet)

        // Delete individual flight files from iCloud
        for flight in flightsToDelete {
            persistence.deleteFlight(flight)
        }

        // Sync deletions to iCloud (CloudKit)
        if settings.iCloudSyncEnabled {
            for flight in flightsToDelete {
                SyncManager.shared.deleteFlight(flight.id)
            }
        }
    }
    
    func importFlight(from data: Data) -> Bool {
        // Try GPX first, then JSON
        if let flight = Flight.fromGPX(data) {
            flights.insert(flight, at: 0)
            saveFlights()
            return true
        }
        if let flight = Flight.fromJSONOptional(data) {
            flights.insert(flight, at: 0)
            saveFlights()
            return true
        }
        return false
    }
    
    func updateFlightNotes(_ flight: Flight, notes: String) {
        if let index = flights.firstIndex(where: { $0.id == flight.id }) {
            flights[index].notes = notes
            flights[index].touch() // stamp local edit for CloudKit conflict resolution (ARCH-02)
            // PR-09: persist + sync ONLY this flight. Editing one note previously rewrote every
            // flight file on the main actor and re-queued the whole logbook to CloudKit.
            saveFlight(flights[index])
        }
    }

    func updateFlightName(_ flight: Flight, name: String) {
        if let index = flights.firstIndex(where: { $0.id == flight.id }) {
            flights[index].name = name
            flights[index].touch()
            saveFlight(flights[index]) // PR-09: persist + sync only this flight
        }
    }

    /// Toggle the user-pinned "favorite" flag. Favorited flights pin to the top of the logbook.
    /// Mirrors `updateFlightName`: mutate in place, stamp `modifiedAt`, persist + sync only this
    /// flight so the star rides CloudKit's conflict tiebreaker. (v4 UI/UX Revamp favorites)
    func toggleFavorite(_ flight: Flight) {
        if let index = flights.firstIndex(where: { $0.id == flight.id }) {
            flights[index].isFavorite.toggle()
            flights[index].touch()
            saveFlight(flights[index])
        }
    }
    
    // MARK: - Persistence

    private func saveFlights() {
        // Save each flight to its own file in iCloud
        persistence.saveFlights(flights)

        // Sync to iCloud (CloudKit) if enabled
        if settings.iCloudSyncEnabled {
            SyncManager.shared.syncAllFlights(flights)
        }
    }

    /// Save a single flight (for sync efficiency).
    /// Returns `true` only if the local file write was confirmed. (PR-14)
    @discardableResult
    func saveFlight(_ flight: Flight) -> Bool {
        // Save just this flight to its own file
        let saved = persistence.saveFlight(flight)

        if settings.iCloudSyncEnabled {
            SyncManager.shared.syncFlight(flight, allFlights: flights)
        }
        return saved
    }

    /// Reload flights from disk (called after sync updates). Decode runs off the main actor. (PR-24)
    func reloadFlights() {
        Task { [weak self] in
            guard let self = self else { return }
            await Task.yield()
            self.flights = await self.persistence.loadFlightsOffMain()
        }
    }

    func saveSettings() {
        // Save to file-based storage
        persistence.saveSettings(settings)

        // Update sync manager with current sync preference
        SyncManager.shared.isSyncEnabled = settings.iCloudSyncEnabled

        // Sync settings to iCloud if enabled
        if settings.iCloudSyncEnabled {
            SyncManager.shared.syncSettings(settings)
        }

        syncAircraftType()
    }

    // MARK: - Onboarding gate

    /// Device-local key backing `hasSeenOnboarding` (see that property).
    private let hasSeenOnboardingKey = "hasSeenOnboarding"

    /// Mark onboarding finished on THIS device (the gate) and record completion in the synced settings.
    /// Always persists — onboarding (incl. a replay from Settings) can change the feature toggles.
    func completeOnboarding() {
        hasSeenOnboarding = true
        UserDefaults.standard.set(true, forKey: hasSeenOnboardingKey)
        settings.hasCompletedOnboarding = true
        saveSettings()
    }

    /// Re-show onboarding from Settings. Device-local — replaying it here doesn't reset other devices.
    func replayOnboarding() {
        hasSeenOnboarding = false
        UserDefaults.standard.set(false, forKey: hasSeenOnboardingKey)
    }

    private func loadSettings() {
        if let loadedSettings = persistence.loadSettings() {
            settings = loadedSettings

            // Update sync manager with loaded preference
            SyncManager.shared.isSyncEnabled = settings.iCloudSyncEnabled
        }
    }

    // MARK: - Active Flight State Persistence

    /// Full checkpoint — used on scene-phase transitions (belt-and-suspenders) and whenever an
    /// immediate, guaranteed write is wanted. A nil current flight clears the file.
    func saveActiveFlightState() {
        guard let flight = currentFlight else {
            clearActiveFlightState()
            return
        }
        // Scene-background / explicit save: write synchronously so it's guaranteed on disk before
        // the app can suspend. The throttled per-tick checkpointActiveFlight uses the async path.
        persistActiveFlightState(flight: flight, synchronous: true)
    }

    /// Throttled crash-recovery checkpoint driven by GPS cadence and major timing events,
    /// independent of `scenePhase` so a foreground crash/OOM can't lose the in-flight track.
    /// (PERF-02 / PERF-13)
    ///
    /// The atomic write targets a **local** file (not iCloud), which keeps it fast. The encode +
    /// write run off the main actor on a serial queue (PR-12), so they're strictly ordered (a
    /// stale write can never clobber newer track data) without blocking the in-flight UI — the
    /// encode of a multi-hour, up-to-1 Hz track is NOT cheap and must not run on the main actor.
    func checkpointActiveFlight(force: Bool) {
        guard isFlightActive, let flight = currentFlight else { return }
        if !force {
            let enoughPoints = pointsSinceCheckpoint >= Self.checkpointPointInterval
            let enoughTime = lastCheckpointAt.map {
                Date().timeIntervalSince($0) >= Self.checkpointTimeInterval
            } ?? true
            guard enoughPoints || enoughTime else { return }
        }
        persistActiveFlightState(flight: flight)
    }

    /// Persist the crash-recovery checkpoint. The cheap value-type snapshot is taken on the main
    /// actor; the heavy `JSONEncoder().encode` of the whole track + atomic write run on a serial
    /// background queue (PR-12) — previously this ran synchronously on the main actor every ~30 s,
    /// which is not "small" for a multi-hour, up-to-1 Hz track. The serial queue keeps writes
    /// strictly ordered (a stale write never clobbers a newer one) and `writeActiveFlightStateData`
    /// keeps each write atomic.
    /// - Parameter synchronous: when true (scene-background save), block until the write completes
    ///   so the checkpoint is guaranteed on disk before the app can suspend.
    private func persistActiveFlightState(flight: Flight, synchronous: Bool = false) {
        let state = ActiveFlightState(flight: flight, from: self)
        let url = persistence.activeFlightStateURL
        let savedAt = state.savedAt
        let pointerKey = activeFlightPointerKey

        let write: @Sendable () -> Void = {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(state)
                try DataPersistenceManager.writeActiveFlightStateData(data, to: url)
                UserDefaults.standard.set(savedAt, forKey: pointerKey)
            } catch {
                AppLog.general.debugLine("Failed to checkpoint active flight: \(error.localizedDescription)")
            }
        }

        // Advance the main-actor throttle now: the next tick must not re-encode the same track
        // while this write is in flight. A failed write simply retries on the next interval.
        pointsSinceCheckpoint = 0
        lastCheckpointAt = savedAt

        if synchronous {
            Self.checkpointQueue.sync(execute: write)
        } else {
            Self.checkpointQueue.async(execute: write)
        }
    }

    /// Block until any pending asynchronous checkpoint write (PR-12) has completed. The serial queue
    /// guarantees ordering, so a no-op `sync` flushes everything queued before it. Used by tests for
    /// deterministic assertions; harmless in production.
    func flushPendingCheckpoint() {
        Self.checkpointQueue.sync {}
    }

    /// Restore the active flight state if a recent checkpoint exists.
    /// Returns true if a flight state was restored.
    @discardableResult
    func restoreActiveFlightState() -> Bool {
        guard let data = persistence.loadActiveFlightStateData() else {
            // No file checkpoint — drop any pre-4.x UserDefaults blob so it can't linger.
            clearActiveFlightState()
            return false
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(ActiveFlightState.self, from: data)

            // A snapshot from an incompatible build is discarded, not crashed on.
            guard state.schemaVersion == ActiveFlightState.currentSchemaVersion else {
                AppLog.general.debugLine("Discarding active flight state with schema \(state.schemaVersion)")
                clearActiveFlightState()
                return false
            }

            // Old sessions shouldn't be restored (within 24 hours).
            let maxAge: TimeInterval = 24 * 60 * 60
            if Date().timeIntervalSince(state.savedAt) > maxAge {
                clearActiveFlightState()
                return false
            }

            state.restore(to: self)
            lastCheckpointAt = state.savedAt
            AppLog.general.debugLine("Restored active flight state from \(state.savedAt)")
            return true
        } catch {
            // Unreadable / old-format snapshot: discard rather than crash. (ARCH-08)
            AppLog.general.debugLine("Failed to restore active flight state: \(error.localizedDescription)")
            clearActiveFlightState()
            return false
        }
    }

    /// Clear the saved active flight state (file + pointer + legacy blob).
    func clearActiveFlightState() {
        persistence.clearActiveFlightStateFile()
        UserDefaults.standard.removeObject(forKey: activeFlightPointerKey)
        UserDefaults.standard.removeObject(forKey: legacyActiveFlightStateKey)
        pointsSinceCheckpoint = 0
        lastCheckpointAt = nil
    }

    /// Check if there is a saved active flight state.
    var hasActiveFlightState: Bool {
        persistence.hasActiveFlightStateFile
    }
}

// MARK: - Computed Properties Extension

extension AppState {
    var canGoToPreviousPhase: Bool {
        currentPhase != .preflight
    }
    
    var canGoToNextPhase: Bool {
        currentPhase != .hangar
    }
    
    var isLastPhase: Bool {
        currentPhase == .hangar
    }
    
    /// Flight duration from engine start (or, before engine start, the session start) to now.
    var flightDuration: String {
        // Engine-start time wins; before that, fall back to the session start. Nil → placeholder.
        guard let start = engineStartTime ?? currentFlight?.startTime else { return "--:--" }
        return FlightClock.formattedDuration(seconds: Date().timeIntervalSince(start))
    }
    
    var formattedEngineStartTime: String? {
        guard let time = engineStartTime else { return nil }
        return formatTime(time)
    }

    var formattedLineUpTime: String? {
        guard let time = lineUpTime else { return nil }
        return formatTime(time)
    }

    var formattedLandingTime: String? {
        guard let time = landingTime else { return nil }
        return formatTime(time)
    }

    var formattedEngineShutdownTime: String? {
        guard let time = engineShutdownTime else { return nil }
        return formatTime(time)
    }

    /// Format a time according to current UTC settings (rules in `FlightClock`).
    func formatTime(_ date: Date) -> String {
        FlightClock.formattedTimeOfDay(date, useUTC: settings.alwaysUseUTC)
    }
}
