import Foundation
import CoreLocation
import SwiftUI
import Observation

/// Phase completion status
enum PhaseCompletionStatus: String, Codable {
    case notStarted
    case completed       // User pressed NEXT
    case skipped         // User jumped past without pressing NEXT
    case missingAction   // Phase with required button (e.g., engine start) was skipped without pressing button
    /// The phase had nothing to display, so there was nothing for the pilot to work through.
    ///
    /// SEC-C36: previously indistinguishable from `.completed`. `allItemsCompleted(current: 0,
    /// visibleCount: 0)` is `0 >= 0` → true, so ANY zero-visible-item phase was stamped green as if
    /// it had been worked. That is reachable with no attacker at all — an `.unresolved` checklist (a
    /// premium aircraft whose download has not landed) and a learning-mode configuration that hides
    /// every item both produce a visible count of 0. Showing a pilot a green phase they never
    /// touched is the defect; the fix is a state that says "nothing here", not one that claims done.
    case empty
    /// A memory check (every item hidden by the Memory test) that the pilot confirmed with one tap:
    /// done, green, as a check worked through. Such a check used to be recorded `.empty` whatever
    /// happened, since nothing was on screen. (6.1, check slot)
    ///
    /// Older builds don't know this value, and one reading it would drop the whole crash-recovery
    /// checkpoint, so the checkpoint writes it as `.completed` with a side list
    /// (`ActiveFlightState.memoryConfirmedPhases`) that this build reads back.
    case doneFromMemory
    /// The landing check, "yes, it was done" on the landed card after a full-stop landing: settled, drawn
    /// as a green OUTLINE on the phase bar, never solid green, since it was confirmed after the fact.
    /// (6.1, cues from the flight)
    case confirmedAfterLanding
    /// The landing check, "not sure" on the landed card: settled too (it can't be flown any more), amber,
    /// and on the flight for the debrief. (6.1)
    case notSure

    /// Whether the check counts as done: worked through, confirmed from memory, or after the landing.
    var isDone: Bool { self == .completed || self == .doneFromMemory || self == .confirmedAfterLanding }

    /// Answered on the landed card: settled, and nothing reopens or defers it. (6.1)
    var isAnsweredAfterLanding: Bool { self == .confirmedAfterLanding || self == .notSure }

    /// What the crash checkpoint writes for a build that doesn't know the 6.1 statuses: done as done,
    /// "not sure" as skipped (orange, to be looked at). The side lists put them back here.
    var writtenForOlderBuilds: PhaseCompletionStatus {
        switch self {
        case .doneFromMemory, .confirmedAfterLanding: return .completed
        case .notSure: return .skipped
        default: return self
        }
    }
}

extension PhaseCompletionStatus {
    /// A value this build doesn't know (written by a newer one) reads as `.skipped`, orange: owed, to
    /// be looked at, rather than a decode error that loses the whole checkpoint. (6.1)
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PhaseCompletionStatus(rawValue: raw) ?? .skipped
    }
}

/// The pilot's progress through the checklist, grouped as one cohesive value extracted from four
/// loose @Published properties on AppState: the current phase, the per-phase completion status, the
/// highest phase reached, and the per-phase step-by-step highlight index. AppState owns it via a
/// single `var checklistProgress` and exposes thin forwarding accessors, so the app-wide
/// `appState.currentPhase` / `phaseCompletionStatus` / … call sites keep working and stay reactive.
/// (Phase 4 — AppState decomposition: state extraction)
/// Equatable so a one-tap ✓ DONE · NEXT can tell, at UNDO, whether anything happened since. (6.1)
struct ChecklistProgress: Equatable {
    var currentPhase: ChecklistPhase = .preflight
    var phaseCompletionStatus: [ChecklistPhase: PhaseCompletionStatus] = [:]
    var highestCompletedPhase: ChecklistPhase = .preflight
    var currentHighlightedItem: [ChecklistPhase: Int] = [:]
    /// Items the pilot left unchecked when pressing NEXT, by phase: the stable `ChecklistItem.id`s,
    /// kept until they are checked from the deferred list. (v6.0 · B2)
    var deferredItems: [ChecklistPhase: [String]] = [:]
    /// Checks deferred whole, in flight order: a phase jumped over on the phase bar, to be run from
    /// the deferred list. Its progress is the phase's own highlight. (v6.0 review, J1)
    var deferredChecks: [ChecklistPhase] = []
}

/// The sections of the app on the ground, one tab each. In the air the Cockpit replaces all of them.
/// (v6.0 · P1)
enum GroundTab: Hashable {
    case today, plan, logbook, aircraft, settings
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
    /// Retired in 6.0: the screen stays on during a flight and only then (review P7). Still decoded
    /// and synced for older builds.
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

    /// Whether the high-contrast sunlight palette engages by itself in a bright cockpit. (v5.x)
    ///
    /// Sunlight used to be a fourth manual choice sitting in the same picker as auto/day/night, and
    /// `auto` never selected it — so it could only ever be turned on by hand and then stayed on
    /// indoors, where the high-contrast palette is simply harsher for no gain. As a toggle it can
    /// mean what a pilot expects it to mean: engage when the screen is bright enough that direct sun
    /// is the likely reason.
    var sunlightBoost: Bool = false

    /// Screen brightness above which the sunlight palette takes over, when the boost is enabled.
    ///
    /// iOS exposes no ambient-light reading, so screen brightness is the proxy — either the pilot has
    /// wound it up because of the sun, or auto-brightness already has. Not perfect, and it is exactly
    /// why this is opt-in rather than the default.
    static let sunlightBrightnessThreshold: Double = 0.85

    /// The active cockpit theme mode, resolved against the live device appearance and screen
    /// brightness.
    func cockpitThemeMode(systemIsDark: Bool, screenBrightness: Double = 0) -> CockpitThemeMode {
        let base: CockpitThemeMode = {
            switch themePreference {
            case .day: return .day
            case .sunlight: return .sunlight
            case .night: return .night
            case .auto: return systemIsDark ? .night : .day
            }
        }()
        // Only ever escalates a DAY palette. Night exists to protect dark adaptation, and blasting a
        // high-contrast bright palette over it because the screen happens to be turned up would undo
        // the one thing that mode is for.
        guard sunlightBoost, base == .day,
              screenBrightness >= Self.sunlightBrightnessThreshold else { return base }
        return .sunlight
    }
    var gpsRecordingInterval: Double = 5.0 // seconds
    var showSpeedReference: Bool = true
    /// Highlight items one by one. Always on since 6.0: CHECK is this flow, and the switch is gone
    /// (review P7). The off path still works for a file an older build wrote.
    var stepByStepHighlighting: Bool = true
    /// Every check shown. Off is the "Memory test": memorisable checks are hidden until revealed.
    /// On by default since 6.0: the old default hid checks from pilots who never opened Settings.
    var learningMode: Bool = true
    var forceICAOChartLayer: Bool = false // When true, ICAO layer stays at all zoom levels
    var offlineMode: Bool = false // When true, use cached ICAO chart only
    var alwaysUseUTC: Bool = false // When true, all times are displayed in UTC
    var distanceInNauticalMiles: Bool = true // Flight Log distances: true = NM, false = km (toggle on the NM card)

    // Flight Planning
    /// Training mode: this pilot flies dual, with an instructor.
    ///
    /// A licensed pilot logs their own flights as PIC, and defaulting to that is right for them. A
    /// student is the opposite case and just as common — every flight is dual, and AMC1 FCL.050
    /// wants the INSTRUCTOR named in the PIC column, not the student writing the logbook. Without
    /// this the app quietly filled the student's own name into a column that is a statement about
    /// who commanded the aircraft. (v5.x)
    var isStudentPilot: Bool = false
    /// The usual instructor, so a dual flight does not need the name typed onto every plan.
    var instructorName: String = ""
    /// Where this pilot is based (an ident, `HomeAerodrome.normalized`). The nav log's landings at
    /// base are counted there; nil = not set, and the count at base is then unknown. (v6.1)
    var homeAerodromeIdent: String? {
        get { HomeAerodrome.normalized(homeAerodromeCode) }
        set { homeAerodromeCode = HomeAerodrome.normalized(newValue) ?? "" }
    }
    /// How it is stored: "" when not set, so the key is written either way. A record without the key
    /// comes from a build that can't express it; one with "" was cleared on purpose.
    var homeAerodromeCode: String = ""

    /// The logbook's view of who is writing it. Built here so the card, the PDF extract and the
    /// page totals all read the same settings.
    var logbookPilotContext: LogbookLineBuilder.PilotContext {
        LogbookLineBuilder.PilotContext(name: pilotName.isEmpty ? nil : pilotName,
                                        isStudent: isStudentPilot,
                                        instructorName: instructorName.isEmpty ? nil : instructorName)
    }

    /// Whether the fee task and the cost half of the numbers sheet appear. Not every pilot tracks
    /// what a flight cost, and the logbook line stands on its own without it. (v5.0.0)
    var enableCostTracking: Bool = true
    /// Retired in 6.0.1: the radius (metres) around the next waypoint that marked it as passed. The
    /// GPS track's abeam passages replaced it (`catchUpWaypointPassages`), and the slider is gone. Still
    /// decoded and synced, so an older build on another device keeps its value.
    var waypointProximityThreshold: Double = 500
    var terrainAltitudeUnit: TerrainAltitudeUnit = .feet // feet, meters, or dual

    // Circuit mode
    /// Retired in 6.0: CIRCUITS is always offered on Today (review P7). Still decoded and synced, so
    /// an older build on another device keeps its value.
    var enableCircuitMode: Bool = false

    // Aircraft visibility (premium feature)
    var hiddenAircraftIds: Set<String> = [] // Individual aircraft IDs left out of the aircraft you pick from (Today, Your aircraft, Plan new flight)
    var hiddenAeroclubs: Set<String> = [] // Entire aeroclubs left out the same way

    // iCloud Sync
    var iCloudSyncEnabled: Bool = true // When true, syncs settings and flights to iCloud (CloudKit AND the iCloud Drive store). Per device: the datastore's switch is authoritative, see AppState.reconcileSyncSwitch

    // Checklist Language
    var checklistLanguage: ChecklistLanguage = .auto // Language for checklist content

    // Airport data overlay
    var showAirportsOnMap: Bool = true // When true, shows airports on navigation map (requires airport data download) — ON by default
    var showNavaidsOnMap: Bool = true // When true, shows navaids (VOR/DME/NDB) on navigation map (requires navaid data download) — ON by default (v4.1.0)
    var showObstaclesOnMap: Bool = false // When true, shows obstacles (towers/masts/turbines) on navigation map (requires obstacle data download) — OFF by default to avoid clutter (v4.1.0)
    var showReportingPointsOnMap: Bool = true // When true, shows VFR reporting points on navigation map (requires reporting-point data download) — ON by default (v4.1.0)
    var showTrackVector: Bool = true // When true, draws a ground-track trend vector ahead of the aircraft (v4 UI/UX Revamp) — ON by default
    // Aerodrome procedures from open flightmaps (6.2.0): indicative, so OFF by default; the Approach and
    // Everything presets turn on the first two. Glider, UL and helicopter procedures are their own opt-in.
    var showVFRCircuitsOnMap: Bool = false // Powered traffic circuits, with their altitude
    var showVFRRoutesOnMap: Bool = false // VFR arrival and departure routes, with their sectors
    var showNonPoweredCircuitsOnMap: Bool = false // Glider, UL and helicopter circuits (and helicopter routes with the routes)

    // OpenAIP aviation data overlay
    var showOpenAIPOverlay: Bool = true // When true, draws OpenAIP airspace (vector CTRs from downloaded data) on the nav map — ON by default
    var showOpenAIPTiles: Bool = false // When true, overlays the OpenAIP raster chart tiles (data-first: tiles are an opt-in, separate from the airspace vector) — OFF by default (v4.1.0)
    var openAIPOfflineCountries: [String] = [] // ISO alpha-2 country codes for cached airspace data
    var enableAirspaceStreaming: Bool = false // When true, fetches nearby CTRs from OpenAIP API when no downloaded data

    // Numbers (v5.0.0) — all user-entered. Rates and mass & balance data are not published as
    // data anywhere, differ per member category and per registration, and are the pilot's to own.
    /// Name written into the logbook line's PIC column; empty falls back to the "SELF" convention.
    var pilotName: String = ""
    /// Hourly rate + billing basis per aircraft, keyed by registration (falling back to type).
    var aircraftRates: [String: AircraftRateProfile] = [:]
    /// Mass & balance setup per registration. Empty until the pilot enters their aircraft's figures.
    var weightBalanceProfiles: [String: WeightBalanceProfile] = [:]
    /// Usable fuel with full tanks, in litres, per registration: the pilot's figure, used when the
    /// aircraft's data doesn't give one (`FullTanks.resolve`). (on-device review #4, point 3)
    var fullTanksLitres: [String: Double] = [:]
    /// The pilot's own cruise speed per registration, knots indicated: it outranks what the flights
    /// teach and the aircraft's data (`CruiseSpeed.resolve`). Empty until set in the Aircraft tab. (6.1)
    var cruiseSpeedKIAS: [String: Int] = [:]

    /// Which generation of the settings schema wrote this blob.
    ///
    /// Settings sync as ONE unversioned record with last-writer-wins semantics, so a device running
    /// an older build re-encodes the whole struct without the keys it does not know and pushes it
    /// back. Ingest then assigned it wholesale and saved — silently erasing every mass & balance
    /// envelope and hourly rate the pilot had entered, from the only place they live. Stamping the
    /// writer's generation lets ingest tell "the user cleared this" apart from "the writer could
    /// not express it". (review F8)
    var schemaVersion: Int = AppSettings.currentSchemaVersion

    /// Bump whenever a stored property is added that an older build cannot round-trip, and add it
    /// to `protectedFields` below.
    static let currentSchemaVersion = 8

    /// A field a settings schema protects: the schema that brought it (or changed what it means), its
    /// key, and how to keep or compare this device's value. (review F8; one table since 6.1)
    struct ProtectedField {
        let schema: Int
        let key: String
        let keep: (inout AppSettings, AppSettings) -> Void
        let differs: (AppSettings, AppSettings) -> Bool

        init<Value: Equatable>(_ schema: Int, _ key: CodingKeys, _ path: WritableKeyPath<AppSettings, Value>) {
            self.schema = schema
            self.key = key.stringValue
            keep = { merged, local in merged[keyPath: path] = local[keyPath: path] }
            differs = { a, b in a[keyPath: path] != b[keyPath: path] }
        }
    }

    /// Every field an older build can't round-trip. A new one goes here, with `currentSchemaVersion`
    /// bumped, and must be encoded whatever its value (no `nil` left out): a record without its key is
    /// how an older build gives itself away when it relays a newer record.
    static let protectedFields: [ProtectedField] = [
        // Schema 2 (v5.0.0): none of these round-trip through a v4.x writer.
        ProtectedField(2, .pilotName, \.pilotName),
        ProtectedField(2, .isStudentPilot, \.isStudentPilot),
        ProtectedField(2, .instructorName, \.instructorName),
        ProtectedField(2, .sunlightBoost, \.sunlightBoost),
        ProtectedField(2, .aircraftRates, \.aircraftRates),
        ProtectedField(2, .weightBalanceProfiles, \.weightBalanceProfiles),
        ProtectedField(2, .enableCostTracking, \.enableCostTracking),
        // Schema 3 (v6.0): before 6.0 `learningMode` defaulted to off, hiding memorisable checks, so
        // an older writer's value says nothing about what this pilot chose.
        ProtectedField(3, .learningMode, \.learningMode),
        // Schema 4 (v6.0): step-by-step is how every checklist runs now (the Cockpit's CHECK), and
        // there is no switch left to turn it back on, so an older writer can't turn it off.
        ProtectedField(4, .stepByStepHighlighting, \.stepByStepHighlighting),
        // Schema 5 (v6.0): the pilot's full-tanks figures. (on-device review #4, point 3)
        ProtectedField(5, .fullTanksLitres, \.fullTanksLitres),
        // Schema 6 (v6.1): the home aerodrome.
        ProtectedField(6, .homeAerodromeCode, \.homeAerodromeCode),
        // Schema 7 (v6.1): the pilot's cruise speeds.
        ProtectedField(7, .cruiseSpeedKIAS, \.cruiseSpeedKIAS),
        // Schema 8 (v6.2): the aerodrome procedures' switches. An older build would write them back
        // off, and a preset there (which doesn't know them) can't say what the pilot chose.
        ProtectedField(8, .showVFRCircuitsOnMap, \.showVFRCircuitsOnMap),
        ProtectedField(8, .showVFRRoutesOnMap, \.showVFRRoutesOnMap),
        ProtectedField(8, .showNonPoweredCircuitsOnMap, \.showNonPoweredCircuitsOnMap),
    ]

    /// Whether the writer of this record could not express `field`: its schema came before the field,
    /// or the record doesn't carry the key. The second catches an older build relaying a newer record:
    /// it keeps the stamp it read (so a 6.0 device sends "6" back) but writes only the keys it knows,
    /// and taking that record whole erased the newer fields on every device. (6.1)
    func couldNotExpress(_ field: ProtectedField) -> Bool {
        schemaVersion < field.schema || carriedKeys.keys.map { !$0.contains(field.key) } ?? false
    }

    /// Merge an incoming settings record over `self`, keeping local values the writer could not have
    /// carried. A writer that could is taken at its word, including deliberate clearings, and a writer
    /// one schema behind still carries everything before it, so its edits to those win.
    func preservingFieldsUnknownTo(_ incoming: AppSettings) -> AppSettings {
        var merged = incoming
        for field in AppSettings.protectedFields where incoming.couldNotExpress(field) {
            field.keep(&merged, self)
        }
        // Our own stamp, whoever wrote the record: a newer record's stamp kept here would go out again
        // with the next save, without the newer fields, and be taken whole by a newer device. (6.1)
        merged.schemaVersion = AppSettings.currentSchemaVersion
        return merged
    }

    /// Whether `preservingFieldsUnknownTo(incoming)` gave back a value `incoming` doesn't hold: the
    /// record in CloudKit then lacks it, and this device sends the merged one back, so the next device
    /// to fetch gets the newer record again. (6.1)
    func restoresFields(missingFrom incoming: AppSettings) -> Bool {
        AppSettings.protectedFields.contains { incoming.couldNotExpress($0) && $0.differs(self, incoming) }
    }

    /// The keys of the record this value was decoded from; nil for one built in code, which is taken
    /// at its stamp. Not persisted, and no part of `==`: it only says what the writer could express.
    var carriedKeys = CarriedKeys()

    struct CarriedKeys: Equatable {
        var keys: Set<String>?
        static func == (lhs: CarriedKeys, rhs: CarriedKeys) -> Bool { true }
    }

    /// Settings a pre-6.0 build saved on this device, brought to the current schema. Local files
    /// only; an incoming sync record goes through `preservingFieldsUnknownTo(_:)`.
    /// - Schema 3: every check shown again, once. The old default hid memorisable checks, and most
    ///   pilots never chose it. A later "Memory test" choice sticks. (v6.0 · A7)
    /// - Schema 4: step-by-step on. The Cockpit's CHECK is that flow, and its switch is gone. (v6.0 · P7)
    /// - A file a newer build wrote (after a downgrade) takes this build's stamp, as a synced one does.
    func migratedLocally() -> AppSettings {
        guard schemaVersion != AppSettings.currentSchemaVersion else { return self }
        var migrated = self
        if schemaVersion < 3 { migrated.learningMode = true }
        if schemaVersion < 4 { migrated.stepByStepHighlighting = true }
        migrated.schemaVersion = AppSettings.currentSchemaVersion
        return migrated
    }

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

    // Marketing mode is NOT persisted - it resets to false on app restart
    var marketingMode: Bool = false // When true, enables shake gesture to show marketing location controls

    // Developer mode is NOT persisted - revealed by tapping the version 5× in About, it resets to false
    // on app restart. Gates developer-only surfaces for the current run (e.g. the Companion diagnostics
    // panel). (v4.1)
    var developerMode: Bool = false

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
        case enableCostTracking
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
        case showVFRCircuitsOnMap, showVFRRoutesOnMap, showNonPoweredCircuitsOnMap
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
        case pilotName, aircraftRates, weightBalanceProfiles, sunlightBoost
        case fullTanksLitres
        case cruiseSpeedKIAS
        case schemaVersion
        case isStudentPilot, instructorName
        case homeAerodromeCode = "homeAerodromeIdent"
        // marketingMode and developerMode are intentionally excluded (non-persisted, reset each launch)
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
        // What the writer could express, for `preservingFieldsUnknownTo(_:)`. (6.1)
        carriedKeys = CarriedKeys(keys: Set(container.allKeys.map(\.stringValue)))

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
        learningMode = try container.decodeIfPresent(Bool.self, forKey: .learningMode) ?? true
        forceICAOChartLayer = try container.decodeIfPresent(Bool.self, forKey: .forceICAOChartLayer) ?? false
        offlineMode = try container.decodeIfPresent(Bool.self, forKey: .offlineMode) ?? false
        alwaysUseUTC = try container.decodeIfPresent(Bool.self, forKey: .alwaysUseUTC) ?? false
        distanceInNauticalMiles = try container.decodeIfPresent(Bool.self, forKey: .distanceInNauticalMiles) ?? true
        enableCostTracking = try container.decodeIfPresent(Bool.self, forKey: .enableCostTracking) ?? true
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
        // New in 6.2: absent on every older save, which reads as off, the default. `try?`: a value that
        // isn't a Bool must not throw the whole settings away.
        showVFRCircuitsOnMap = (try? container.decodeIfPresent(Bool.self, forKey: .showVFRCircuitsOnMap)) ?? false
        showVFRRoutesOnMap = (try? container.decodeIfPresent(Bool.self, forKey: .showVFRRoutesOnMap)) ?? false
        showNonPoweredCircuitsOnMap = (try? container.decodeIfPresent(Bool.self, forKey: .showNonPoweredCircuitsOnMap)) ?? false
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
        // marketingMode and developerMode intentionally excluded - always default to false each launch
        // v5.0.0 numbers. Absent on every existing save; empty dictionaries mean "not set up yet",
        // which is exactly how the calculators treat them.
        pilotName = try container.decodeIfPresent(String.self, forKey: .pilotName) ?? ""
        isStudentPilot = try container.decodeIfPresent(Bool.self, forKey: .isStudentPilot) ?? false
        instructorName = try container.decodeIfPresent(String.self, forKey: .instructorName) ?? ""
        // New in 6.1: absent on every older save, which reads as "not set". `try?`: a value that isn't
        // a string must not throw the whole settings away (see the profiles below).
        homeAerodromeCode = HomeAerodrome.normalized(
            (try? container.decodeIfPresent(String.self, forKey: .homeAerodromeCode)) ?? nil) ?? ""
        // A pilot who had picked the old `sunlight` mode wanted the bright palette, so the boost
        // starts on for them and their preference falls back to day.
        sunlightBoost = try container.decodeIfPresent(Bool.self, forKey: .sunlightBoost)
            ?? (themePreference == .sunlight)
        // `.sunlight` is no longer offered by any picker, so a save still holding it would show an
        // empty selection and pin the palette on regardless of the boost.
        if themePreference == .sunlight { themePreference = .day }
        // `try?`, not `try`: these are the first nested custom structs in AppSettings, and
        // `decodeIfPresent` only tolerates an ABSENT key — a present-but-unparseable value throws,
        // and the throw escapes all the way out to a caller that swallows it into a default
        // AppSettings, losing every OTHER setting too and then persisting the defaults. Degrading
        // to "profiles not set up" is bad; silently resetting the whole store is worse.
        aircraftRates = (try? container.decodeIfPresent([String: AircraftRateProfile].self, forKey: .aircraftRates)) ?? [:]
        weightBalanceProfiles = (try? container.decodeIfPresent([String: WeightBalanceProfile].self, forKey: .weightBalanceProfiles)) ?? [:]
        fullTanksLitres = (try? container.decodeIfPresent([String: Double].self, forKey: .fullTanksLitres)) ?? [:]
        cruiseSpeedKIAS = (try? container.decodeIfPresent([String: Int].self, forKey: .cruiseSpeedKIAS)) ?? [:]
        // Absent means a writer from before the version existed, which is exactly schema 1.
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1

    }

    /// Returns a copy with flight-relevant numeric settings clamped to sane ranges, for applying
    /// settings ingested from an untrusted source (a divergent-schema or corrupt CloudKit record
    /// must never flip a flight-relevant value to an absurd one). (SEC-17)
    func clampedForIngest() -> AppSettings {
        var result = self
        result.gpsRecordingInterval = result.gpsRecordingInterval.clamped(to: 1.0...300.0)
        // Retired, but still carried to older builds that use it.
        result.waypointProximityThreshold = result.waypointProximityThreshold.clamped(to: 10.0...50_000.0)
        // SA-23: this used to clamp two numeric fields and validate NO string. The aircraft id is
        // applied verbatim and then spliced into a filesystem path component and a URL path
        // segment, bypassing the whitelist check that `selectAircraft(id:available:)` applies on
        // the deep-link path — so someone with access to the user's iCloud account could write a
        // Settings record with `../../../Documents/leak` and land a server response inside the
        // file-sharing-exposed Documents folder. Dropping the id degrades to "no premium aircraft
        // selected", which the rest of the app already handles.
        if let id = result.selectedRemoteAircraftId, !AircraftRegistrationToken.isWellFormed(id) {
            result.selectedRemoteAircraftId = nil
        }
        // A full-tanks figure is what Full tanks sets fuel on board to: drop one no tank holds.
        result.fullTanksLitres = result.fullTanksLitres.filter { FullTanks.isPlausible($0.value) }
        // A cruise speed times every leg of the aircraft: drop one no aircraft cruises at.
        result.cruiseSpeedKIAS = result.cruiseSpeedKIAS.filter { CruiseSpeedModel.plausibleKIAS.contains(Double($0.value)) }
        // The home aerodrome is matched against idents and shown as text: drop what can't be one.
        result.homeAerodromeIdent = HomeAerodrome.normalized(result.homeAerodromeIdent)
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
    /// v2 = full snapshot with the whole GPS track inline. v3 = slim snapshot (empty track);
    /// the track lives in the append-only NDJSON delta file (PERF-29). Restore accepts both.
    static let currentSchemaVersion = 3
    static let legacyFullTrackSchemaVersion = 2

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
    /// Optional so a checkpoint written before 6.0 still decodes. (v6.0 · B2)
    let deferredItems: [ChecklistPhase: [String]]?
    /// Optional for the same reason. (v6.0 review, J1)
    let deferredChecks: [ChecklistPhase]?
    let hasLandingBeenDetected: Bool
    let isCircuitMode: Bool
    /// The flight's aircraft (`AppState.flightAircraft`), so the correct checklist is re-resolved on
    /// restore — a restored premium flight reloads its own checklist, never the WT9 residue. (ARCH-08)
    /// Named after the selection it was read from until a synced selection could replace it in
    /// flight; the names stay so a checkpoint reads the same either side of an update.
    let selectedAircraft: AircraftType
    let selectedRemoteAircraftId: String?
    /// The flight's checklist language, which is synced settings too. Optional so an older
    /// checkpoint still decodes (it reloads in the language selected at the restore).
    let checklistLanguage: String?
    /// Captured alongside `isCircuitMode`, and for the same reason: it decides which thread END
    /// FLIGHT closes out. Left out of the snapshot, a jetsam mid-flight — routine on a two-hour
    /// flight with background GPS and map tiles — restored the flight with the pilot's explicit
    /// "not this one" silently cleared, and close-out then adopted the flight they avoided.
    /// Optional so an older checkpoint still decodes. (review F3)
    let flightIsUnplanned: Bool?
    /// The checks confirmed from memory. `phaseCompletionStatus` carries them as `.completed`, which an
    /// older build reads (green, as they are); this list turns them back into `.doneFromMemory` here.
    /// Optional so an older checkpoint still decodes. (6.1, check slot)
    let memoryConfirmedPhases: [ChecklistPhase]?
    /// The landed card's answers (`.confirmedAfterLanding`, `.notSure`), which `phaseCompletionStatus`
    /// carries as `.completed` and `.skipped` for an older build. Optional so an older checkpoint still
    /// decodes. (6.1, cues from the flight)
    let answeredAfterLanding: [ChecklistPhase: PhaseCompletionStatus]?
    /// What the flight says is due and owed, this leg. Optional for the same reason. (6.1)
    let flightCues: FlightCueState?
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
        // An older build can't decode `.doneFromMemory` and would drop the whole checkpoint: written
        // as `.completed`, with the list beside it.
        self.phaseCompletionStatus = appState.phaseCompletionStatus.mapValues(\.writtenForOlderBuilds)
        self.memoryConfirmedPhases = appState.phaseCompletionStatus
            .filter { $0.value == .doneFromMemory }.keys.sorted { $0.rawValue < $1.rawValue }
        let answered = appState.phaseCompletionStatus.filter { $0.value.isAnsweredAfterLanding }
        self.answeredAfterLanding = answered.isEmpty ? nil : answered
        self.flightCues = appState.flightCues
        self.highestCompletedPhase = appState.highestCompletedPhase
        self.currentHighlightedItem = appState.currentHighlightedItem
        self.deferredItems = appState.deferredItems
        self.deferredChecks = appState.deferredChecks
        self.hasLandingBeenDetected = appState.hasLandingBeenDetected
        self.isCircuitMode = appState.isCircuitMode
        self.flightIsUnplanned = appState.flightIsUnplanned
        // The flight's aircraft, not the selection: another device may have picked another one since
        // START. A flight made active without `startFlight` has none and keeps the selection.
        if let aircraft = appState.flightAircraft {
            self.selectedAircraft = aircraft.bundled
            self.selectedRemoteAircraftId = aircraft.remoteId
            self.checklistLanguage = aircraft.language
        } else {
            self.selectedAircraft = appState.settings.selectedAircraft
            self.selectedRemoteAircraftId = appState.settings.selectedRemoteAircraftId
            self.checklistLanguage = nil
        }
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
        var statuses = phaseCompletionStatus
        for phase in memoryConfirmedPhases ?? [] where statuses[phase] == .completed {
            statuses[phase] = .doneFromMemory
        }
        for (phase, answer) in answeredAfterLanding ?? [:] where answer.isAnsweredAfterLanding {
            statuses[phase] = answer
        }
        appState.phaseCompletionStatus = statuses
        appState.flightCues = flightCues ?? FlightCueState()
        appState.highestCompletedPhase = highestCompletedPhase
        appState.currentHighlightedItem = currentHighlightedItem
        appState.deferredItems = deferredItems ?? [:]
        appState.deferredChecks = deferredChecks ?? []
        appState.hasLandingBeenDetected = hasLandingBeenDetected
        appState.isCircuitMode = isCircuitMode
        appState.flightIsUnplanned = flightIsUnplanned ?? false
        // The flight gets its aircraft back, and the selection with it (as before). Its checklist is
        // re-fetched at launch (`loadFlightChecklistIfNeeded`, from AeroCheckApp's `.task`); until it
        // resolves, `activeChecklist` reports `.unresolved` for a premium flight rather than
        // falling back to WT9 content. (ARCH-08 / ARCH-01)
        appState.settings.selectedAircraft = selectedAircraft
        appState.settings.selectedRemoteAircraftId = selectedRemoteAircraftId
        appState.flightAircraft = FlightAircraft(
            bundled: selectedAircraft,
            remoteId: selectedRemoteAircraftId,
            language: checklistLanguage ?? appState.settings.checklistLanguage.resolvedLanguage,
            checklist: nil
        )
    }
}

/// Main application state manager
@MainActor
@Observable
class AppState {
    // MARK: - Published Properties

    // Checklist progress (current phase, completion status, highest phase reached, highlight index)
    // grouped into one cohesive ChecklistProgress value. The forwarding accessors below keep every
    // existing `appState.currentPhase` / … call site working and reactive. (Phase 4 — decomposition)
    var checklistProgress = ChecklistProgress()

    var currentPhase: ChecklistPhase {
        get { checklistProgress.currentPhase }
        set {
            // Changing phase clears any temporary hidden-items reveal (matches the per-phase reset the
            // checklist view used to own — now centralised so a companion-driven phase change resets too).
            let leaving = checklistProgress.currentPhase
            if leaving != newValue { hiddenItemsRevealed = false }
            checklistProgress.currentPhase = newValue
            // Leaving cruise stops FREDA, whichever way it is left; one due and not done is recorded
            // missed. Here, where every phase change passes, rather than on a timer. (6.1)
            if leaving == .cruise && newValue != .cruise { stopFreda() }
        }
    }

    /// Whether the current phase's memorizable items are temporarily revealed (hold-to-reveal). Lifted
    /// out of `FlightView`'s local @State so it is a single source of truth: the checklist snapshot
    /// streamed to a companion reflects it, and a companion's hold-to-reveal sets it here — so revealing
    /// on either device reveals on BOTH. Transient (never persisted); reset on phase change above.
    var hiddenItemsRevealed: Bool = false

    /// The effective learning mode = the user's learning-mode setting OR a temporary reveal. Drives which
    /// checklist items are visible/stepped-through. (Was computed in FlightView; centralised for the
    /// companion path.)
    var effectiveLearningMode: Bool { settings.learningMode || hiddenItemsRevealed }

    /// The DEVICE's real light/dark appearance, published from `AppRootView` (which reads it before the
    /// app forces its dark presentation). The companion manager streams the theme resolved against THIS
    /// so the viewer mirrors exactly what the iPad displays — using the force-dark window trait instead
    /// made `.auto` always resolve to night on the companion. (companion v2 — theme default fix)
    var deviceIsDark: Bool = false

    var isFlightActive: Bool = false
    var currentFlight: Flight?

    /// What the flight says is due, and what it has passed with the check still open, this leg: set by
    /// the detector's cues (`noteFlightCue`), read by the check slot and the phase bar. (6.1, cues from
    /// the flight)
    var flightCues = FlightCueState()

    /// The landed card, up after a full-stop landing on a flight that isn't circuits, until answered or
    /// the next take-off roll. (6.1, M4)
    private(set) var landedCard: LandedCard?

    // MARK: - FREDA in cruise (6.1, "Checks in flight" Q6)
    // The rules are `FredaSchedule`'s (Freda.swift); this is where the flight keeps and records them.

    /// When FREDA is due. Runs in cruise once the cruise check is done; stopped by leaving cruise.
    private(set) var freda = FredaSchedule()

    /// FREDA is due: the slot and the thumb bar's FREDA button turn amber, and so does the cruise
    /// segment of the phase bar. Nothing else: no pane change, no sound, no haptic.
    var fredaDue: Bool { freda.due != nil }

    /// FREDA runs in this flight's cruise: not in circuits, which have none.
    private var fredaApplies: Bool { isFlightActive && currentPhase == .cruise && !isCircuitMode }

    /// The cruise check has just been done: FREDA's count starts, unless it runs already.
    private func startFredaAfterCruiseCheck(at date: Date = Date()) {
        guard fredaApplies, !freda.isRunning, !flightCues.descentBegun else { return }
        freda.start(at: date, after: .cruiseCheck)
    }

    /// Call periodically in flight (the Cockpit's 5 s timer) with the last waypoint the flight passed.
    /// In cruise with its check done, FREDA runs (from now, if it didn't: back in cruise from descent,
    /// say) and comes due as `FredaSchedule` says. Anywhere else it is stopped.
    func evaluateFreda(now: Date = Date(), lastPassage: FredaWaypointPassage? = nil) {
        // Once the descent has begun, the slot holds the descent check instead (6.1, cues); a descent the
        // flight climbs back from is withdrawn, and FREDA counts again from then.
        guard fredaApplies, !flightCues.descentBegun else {
            stopFreda()
            return
        }
        guard currentCheckIsDone else { return }
        if !freda.isRunning { freda.start(at: now, after: .cruiseCheck) }
        freda.evaluate(now: now, lastPassage: lastPassage)
    }

    /// FREDA stops; one due and not done goes on the flight as missed.
    private func stopFreda() {
        guard freda.isRunning else { return }
        if let missed = freda.stop() { recordFreda(.missed(missed)) }
    }

    private func recordFreda(_ check: FredaCheck) {
        guard let flight = currentFlight else { return }
        // Read before the write: with optional chaining, the right-hand side of `currentFlight?.x = …`
        // is evaluated inside the write access to `currentFlight`, an exclusivity violation.
        let checks = (flight.fredaChecks ?? []) + [check]
        currentFlight?.fredaChecks = checks
        checkpointActiveFlight(force: true)
    }

    /// A FREDA just done, offered back by the undo toast for six seconds, as a memory check is.
    struct FredaConfirmation: Identifiable, Equatable {
        let id: UUID
        let doneAt: Date
        fileprivate let previous: FredaSchedule
        fileprivate let recordId: UUID
    }

    /// Set by FREDA done, cleared by its toast (UNDO, or the six seconds up).
    private(set) var fredaConfirmation: FredaConfirmation?

    /// FREDA done: the slot (when due), or the FREDA button (due, or early, at a turning point of the
    /// pilot's own). Recorded on the flight, and the count starts again from now.
    func confirmFreda(at date: Date = Date()) {
        guard fredaApplies, freda.isRunning else { return }
        let previous = freda
        let record = FredaCheck.done(at: date, due: freda.due)
        recordFreda(record)
        freda.start(at: date, after: .freda)
        fredaConfirmation = FredaConfirmation(id: UUID(), doneAt: date, previous: previous, recordId: record.id)
    }

    /// UNDO on FREDA's toast: the record goes, and the count is as it was. Cruise left since, a FREDA
    /// that was due is missed after all.
    func undoFredaConfirmation(_ id: UUID) {
        guard let confirmation = fredaConfirmation, confirmation.id == id else { return }
        fredaConfirmation = nil
        if let flight = currentFlight {
            let kept = (flight.fredaChecks ?? []).filter { $0.id != confirmation.recordId }
            currentFlight?.fredaChecks = kept.isEmpty ? nil : kept
        }
        if fredaApplies {
            freda = confirmation.previous
        } else if let due = confirmation.previous.due {
            recordFreda(.missed(due))
        }
        checkpointActiveFlight(force: true)
    }

    /// The toast's six seconds are up.
    func dismissFredaConfirmation(_ id: UUID) {
        if fredaConfirmation?.id == id { fredaConfirmation = nil }
    }

    #if DEBUG
    /// DEV-ONLY (`AEROCHECK_FREDA`, captures): FREDA's count as if the cruise check was done at `date`.
    func startFredaForCapture(at date: Date) {
        guard fredaApplies else { return }
        freda.start(at: date, after: .cruiseCheck)
    }
    #endif
    /// Set when a flight start is refused (e.g. a premium aircraft's checklist isn't loaded, or
    /// location permission is denied). Observed by the UI to show an explanatory alert. (ARCH-01/UX-13)
    var flightStartError: String?

    /// Set when a flight start is refused because the requested premium aircraft isn't owned.
    /// Observed by the UI to present the subscription paywall. (UX-07)
    var flightStartPaywallRequest: Bool = false

    /// The registration of a premium aircraft a flight start was refused for because AéroCheck Pro
    /// isn't active (never bought, or lapsed). The UI says so, and offers the plans and a restore.
    /// (on-device review #4, point 1)
    var flightStartNeedsPro: String?

    /// The resolved remote checklist for the current selection — a premium aircraft, or a
    /// language-specific bundled checklist. `nil` means none is loaded (the bundled fallback is
    /// used, unless a premium aircraft is selected, in which case the checklist is unresolved).
    /// Only mutated by `loadRemoteChecklistIfNeeded` / `syncAircraftType`.
    private(set) var resolvedRemoteChecklist: RemoteAircraftChecklist?

    /// The aircraft and checklist of the flight in progress, taken at START FLIGHT: in flight the
    /// Cockpit reads this, never the selection, which iCloud syncs (see `FlightAircraft`). Set only by
    /// `startFlight`, a checkpoint restore and `loadFlightChecklistIfNeeded`; cleared when the flight
    /// ends.
    fileprivate(set) var flightAircraft: FlightAircraft?

    /// The owned, fully-resolved checklist + speeds: the flight's while one is in progress, the
    /// current selection's otherwise. Every checklist / speed reader uses this instead of the former
    /// global `ChecklistData` statics, so a premium aircraft never falls back to the bundled WT9's
    /// content. (ARCH-01)
    var activeChecklist: ActiveChecklist {
        if isFlightActive, let flightAircraft {
            return flightAircraft.activeChecklist
        }
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

    /// Whether `activeChecklist` is a premium aircraft's: the flight's while one is in progress, the
    /// selection's otherwise. Companion's text gate asks this, so a WT9 selected on another device
    /// in flight never opens a premium checklist's words to an unsubscribed phone. (SA-26)
    var activeAircraftIsPremium: Bool {
        if isFlightActive, let flightAircraft {
            return flightAircraft.remoteId != nil
        }
        return settings.isRemoteAircraftSelected
    }
    var flights: [Flight] = []
    var isLoadingFlights: Bool = true
    /// Device-local onboarding gate (NOT the iCloud-synced `settings.hasCompletedOnboarding`). Onboarding
    /// offers per-device setup (data downloads, location), so it must show once per device — including a
    /// reinstall, where the synced flag would otherwise restore from iCloud and suppress it. (bug 1)
    var hasSeenOnboarding: Bool = false

    /// Version of the safety notice this device has acknowledged; 0 = never. Gates the app behind
    /// `DisclaimerView` until it reaches `AppState.currentDisclaimerVersion`.
    ///
    /// Device-local and deliberately NOT synced through iCloud, unlike most of `settings`: an
    /// acknowledgement is made by a person on a device, and a pilot picking up a second iPad should
    /// be shown it there too rather than have it silently pre-accepted from the cloud. A reinstall
    /// re-asks for the same reason.
    var acceptedDisclaimerVersion: Int = 0
    var settings: AppSettings = AppSettings()
    var showFlightLog: Bool = false

    /// The ground tab on screen. Held here so any screen, deep link or notification can send the
    /// pilot to a section. (v6.0 · P1)
    var groundTab: GroundTab = .today
    /// A Settings page to open the next time the Settings tab shows (the Data chip on Today). (v6.0 · P1)
    var pendingSettingsSection: SettingsView.Section?
    /// A Plan section to open the next time the Plan tab shows (Today's route strip opens Routes).
    var pendingPlanSection: PlanTabView.Section?

    /// Set when iCloud sync auto-merged (or couldn't merge) a conflicting flight edit, so the UI can
    /// surface it instead of the conflict being silent. (ARCH-02)
    var syncConflictNotice: String?

    /// Set when a just-finished flight could not be written to disk at endFlight. The crash-recovery
    /// checkpoint is deliberately kept (the flight is NOT lost) and restored/retried on next launch;
    /// this surfaces the failure to the pilot instead of it being silent. (PR-14)
    var flightSaveError: String?

    /// Set when a flight was restored from the crash-recovery checkpoint on launch and GPS recording
    /// was resumed automatically, so the pilot knows tracking is live again. (PR-01)
    var flightRestoredNotice: String?

    /// Set when the loaded checklist was served in a different language than requested (the requested
    /// language isn't available for that aircraft), so the pilot is told before flight rather than
    /// silently shown a foreign-language checklist. Surfaced as a non-blocking banner. (PR-41 / UX-08)
    var languageFallbackNotice: String?

    /// A flight thread the app should open — set when the pilot taps a thread notification. Consumed
    /// and cleared by the root router, same one-shot contract as the notices above. (v5.0.0)
    var pendingThreadToOpen: UUID?

    /// A followed flight to start, asked for by a screen that can't run the launch itself (Plan ›
    /// Flights). Consumed and cleared by the root, which starts it as a thread notification would.
    /// (round 6)
    var pendingFlightStart: PendingFlightStart?

    // Navigation view session state (not persisted to disk — resets on app restart).
    // One cohesive value (selected layer + orientation) instead of two loose @Published properties.
    var navigationMapState = NavigationMapState()

    // Recorded times during flight — grouped into one cohesive FlightTiming value (extracted from
    // four loose @Published timestamps). The forwarding accessors below keep every existing call
    // site (`appState.engineStartTime`, …) working and reactive without a risky 177-site rename
    // (Flight has identically-named fields). (Phase 4 — AppState decomposition: state extraction)
    var flightTiming = FlightTiming()

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
    var deferredItems: [ChecklistPhase: [String]] {
        get { checklistProgress.deferredItems }
        set { checklistProgress.deferredItems = newValue }
    }
    var deferredChecks: [ChecklistPhase] {
        get { checklistProgress.deferredChecks }
        set { checklistProgress.deferredChecks = newValue }
    }
    
    // Landing detection
    var hasLandingBeenDetected: Bool = false
    private var consecutiveLowSpeedReadings: Int = 0
    private let lowSpeedThreshold: Double = 2.0 // m/s (about 4 knots)
    private let requiredLowSpeedReadings: Int = 3

    // Block time detection (both stamps are run-start backdated — see checkForBlockOff/On)
    private var consecutiveMovingReadings: Int = 0
    private var movementRunStart: (time: Date, latitude: Double, longitude: Double)?
    private var stillnessRunStart: (time: Date, latitude: Double, longitude: Double)?
    private var stillnessRunReadings: Int = 0
    private var movingWhileParkedRun: Int = 0
    private let blockOffSpeedThreshold: Double = 2.0 // m/s (about 4 knots) - sustained movement
    private let blockOnSpeedThreshold: Double = 2.0 // m/s (about 4 knots) - matches GPS noise floor for parked aircraft
    private let requiredMovingReadings: Int = 2 // At 5-second intervals, this is ~10 seconds
    private let requiredStoppedInWindow: Int = 2 // 2 stationary readings confirm a stillness run

    // Circuit mode - skips CRUISE and DESCENT phases
    var isCircuitMode: Bool = false
    /// Set when the pilot chose "Fly without a plan" over a flight they had planned. Transient, like
    /// `isCircuitMode`: it exists so END FLIGHT does not adopt the followed flight they deliberately
    /// stepped around. (v5.x)
    var flightIsUnplanned: Bool = false

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
    /// How many leading track points are already in the NDJSON delta file (PERF-29). Advanced only
    /// after a confirmed append (via a hop back to the main actor), so a failed write retries the
    /// same points next checkpoint. A late hop can re-append a few points — restore dedupes by id.
    private var deltaPointsWritten = 0

    // Reference to persistence manager
    private let persistence: DataPersistenceManager
    /// Device-local flags (onboarding, safety notice) and the checkpoint pointer.
    private let defaults: UserDefaults
    /// CloudKit sync and the Live Activity: process-wide surfaces that belong to the app's own
    /// AppState. Both are nil for an AppState on a datastore confined to a directory (a test's). That
    /// one must not push its settings and flights to the pilot's iCloud (sync is on by default), take
    /// `SyncManager.shared`'s callbacks away from the app's AppState, or touch the Live Activity: the
    /// controller adopts whatever activity is running, so a test flight started extra ones on the
    /// device, overwrote the real flight's with its own content, or ended it.
    private let syncManager: SyncManager?
    private let liveActivity: FlightActivityController?
    /// What the logbook teaches planning (allowances, cruise speeds), learned again as flights are
    /// added. The app's AppState takes the shared store; a confined one (a test's) none, unless given
    /// one: it must not overwrite what the app learned from the pilot's real logbook. (6.1)
    @ObservationIgnored let eetCalibration: EETCalibrationStore?

    /// The latest load of the logbook from disk (at launch, or after the switch moved the store).
    /// CloudKit's catch-up waits for it: before it lands, `flights` is empty or the old store's.
    @ObservationIgnored private var flightsLoad: Task<Void, Never>?

    // MARK: - Initialization

    /// `defaults` and `persistence` are injectable for the same reason as the plan and thread
    /// managers': the test host IS the app, so `.standard` and `.shared` are the simulator app's own.
    /// A test AppState restored the real in-progress flight, cleared the real crash-recovery
    /// checkpoint, and wrote its settings and flights into the real datastore.
    ///
    /// `syncManager` is for the tests that drive the switch against a stand-in engine; left nil, the
    /// app's AppState takes `SyncManager.shared` and a confined one takes none.
    init(defaults: UserDefaults = .standard, persistence: DataPersistenceManager? = nil,
         syncManager: SyncManager? = nil, eetCalibration: EETCalibrationStore? = nil) {
        let persistence = persistence ?? DataPersistenceManager.shared
        self.persistence = persistence
        self.defaults = defaults
        self.syncManager = syncManager ?? (persistence.followsICloud ? SyncManager.shared : nil)
        self.liveActivity = persistence.followsICloud ? FlightActivityController.shared : nil
        self.eetCalibration = eetCalibration ?? (persistence.followsICloud ? EETCalibrationStore.shared : nil)

        // Load settings synchronously (fast, needed for initial UI)
        loadSettings()

        // Seed the device-local onboarding gate. We read it from the LOCAL settings BEFORE any iCloud
        // sync can run, so an in-place UPGRADE that already finished onboarding (local flag true) skips
        // it, while a fresh install / reinstall (no local settings → false) shows it — even though the
        // synced flag will later arrive as true on a reinstall. (bug 1)
        if defaults.object(forKey: hasSeenOnboardingKey) == nil {
            hasSeenOnboarding = settings.hasCompletedOnboarding
            defaults.set(hasSeenOnboarding, forKey: hasSeenOnboardingKey)
        } else {
            hasSeenOnboarding = defaults.bool(forKey: hasSeenOnboardingKey)
        }

        // Safety notice. Absent key = 0 = never acknowledged, which is the right answer for a fresh
        // install AND for an in-place upgrade from a build that predates the notice: an existing user
        // has never been shown it either, so they see it once on the next launch.
        acceptedDisclaimerVersion = defaults.integer(forKey: acceptedDisclaimerVersionKey)

        syncAircraftType()
        setupSyncCallbacks()

        // Try to restore active flight state if app was closed during a flight
        restoreActiveFlightState()
        // Put the Live Activities in order for what was restored: the resumed flight adopts its own,
        // and anything left behind by a quit or a crash goes. Nothing else would until the next
        // flight started. (Live Activities, 6.0)
        liveActivity?.sync(from: self)

        // Load flights in background - iCloud file enumeration can be slow
        // and should not block the main thread during startup
        flightsLoad = Task { [weak self] in
            guard let self = self else { return }
            await self.loadFlightsAsync()
        }

        // Async settings top-up: loadSettings() skips (returns nil for) an evicted iCloud
        // settings.json rather than blocking launch on its download (PERF-25). Adopt the file once
        // it is readable — but only if nothing changed settings in the meantime: a user edit or a
        // CloudKit settings ingest wins over the stale file.
        let launchSettings = settings
        Task { [weak self] in
            guard let self = self else { return }
            guard var fileSettings = await self.persistence.loadSettingsOffMain() else { return }
            // The switch is this device's, not the file's (see reconcileSyncSwitch).
            fileSettings.iCloudSyncEnabled = self.persistence.usesICloudDrive
            guard fileSettings != launchSettings,
                  self.settings == launchSettings else { return }
            self.settings = fileSettings.clampedForIngest().migratedLocally() // SEC-C25
            self.saveSettings()
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
        // First use, or a logbook changed since (a flight synced in while the app was closed). (6.1)
        eetCalibration?.refresh(from: flights)

        // Auto-complete onboarding for existing users (they already know the app)
        if !settings.hasCompletedOnboarding && !flights.isEmpty {
            settings.hasCompletedOnboarding = true
            persistence.saveSettings(settings)
        }
    }

    /// Setup callbacks for sync updates from other devices
    private func setupSyncCallbacks() {
        guard let syncManager else { return }

        // Both run inside the sync engine's event, which waits for them (see
        // `SyncManager.queueWhatCloudKitLacks`).
        syncManager.onSettingsUpdated = { @MainActor [weak self] settings in
            guard let self else { return }
            // Preserve device-local, non-persisted fields. They aren't encoded (so the incoming record
            // always has them at their defaults); a wholesale assign would reset them on every sync —
            // which is why developer mode kept switching itself off when the paired device synced. (v4.1)
            // Keep the device-local, non-persisted fields (they aren't encoded, so the incoming
            // record always has them at their defaults) AND anything the writer's schema could
            // not express — otherwise a device on an older build erases the pilot's mass &
            // balance profiles and hourly rates for every device. (v4.1 + review F8)
            var merged = self.settings.preservingFieldsUnknownTo(settings)
            merged.developerMode = self.settings.developerMode
            merged.marketingMode = self.settings.marketingMode
            // Where this device keeps its data is its own choice, never another device's.
            merged.iCloudSyncEnabled = self.settings.iCloudSyncEnabled
            self.settings = merged
            // Save synced settings to file for future loads
            self.persistence.saveSettings(merged)
            // The record lacked what we kept (an older build wrote it, or relayed a newer one): send
            // the merged record back, or the next device to fetch takes the older one. (6.1)
            if merged.restoresFields(missingFrom: settings) {
                self.syncManager?.syncSettings(merged)
            }
            self.syncAircraftType()
            AppLog.general.debugLine("Settings updated from iCloud sync")
        }

        syncManager.onFlightsUpdated = { @MainActor [weak self] flights in
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
            // Delete the local file for any flight the sync removed (a cloud-initiated delete from
            // another device). Without this the orphaned *.json survives on disk, and because the
            // logbook is rebuilt by enumerating the flights directory, the deleted flight resurrects
            // on the next launch. (v4.1.0 pre-tag fix)
            let incomingIds = Set(flights.map { $0.id })
            for (id, previous) in previousById where !incomingIds.contains(id) {
                self.persistence.deleteFlight(previous)
            }
            self.eetCalibration?.refresh(from: flights)
            AppLog.general.debugLine("Flights updated from iCloud sync")
        }

        // What CloudKit may lack, read when its engine comes up: at launch, when the switch turns
        // on, after an iCloud sign-in. The logbook as loaded from disk, so it waits for the load.
        syncManager.localSnapshot = { @MainActor [weak self] in
            guard let self else { return nil }
            await self.flightsLoad?.value
            return (self.flights, self.settings)
        }

        // The deletion records of the store in use (6.1): what CloudKit is owed when it comes up (a
        // flight deleted with the switch off), and what a fetch must not bring back.
        syncManager.flightDeletionRecords = { @MainActor [weak self] in
            await self?.persistence.deletionLedgerOffMain(kinds: [.flight]) ?? .empty
        }

        // Another device deleted these through CloudKit: recorded here too, unless its own record
        // is here already (6.1). Never from the "missing from incoming" loop above.
        syncManager.onFlightsDeletedInCloudKit = { @MainActor [weak self] deleted in
            guard let self else { return }
            for flight in deleted {
                self.persistence.recordDeletionIfAbsent(.flight, id: flight.id, stamp: flight.stamp)
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
    /// Drops a premium checklist once no premium aircraft is selected, so the active checklist falls
    /// back to the bundled aircraft until its language-specific checklist loads.
    ///
    /// The bundled aircraft's own checklist stays. `loadRemoteChecklistIfNeeded` resolves the WT9 in
    /// the pilot's language with no premium aircraft selected, and this runs on every `saveSettings()`
    /// and settings sync: dropping it put a flight in progress back on the hard-coded English
    /// `WT9ChecklistData` (not the same checks as the JSON) under the pilot's highlight, after a
    /// Memory test or map-layer toggle. (A flight in progress reads `flightAircraft` since, so this
    /// only reaches the ground screens now.) Its JSON carries the aircraft's `serverId` as `id`
    /// (bundled, cached or API alike). A premium selection keeps what is resolved until its own load
    /// replaces it.
    private func syncAircraftType() {
        guard settings.selectedRemoteAircraftId == nil, let resolved = resolvedRemoteChecklist,
              resolved.id != settings.selectedAircraft.serverId else { return }
        resolvedRemoteChecklist = nil
    }

    /// Load the appropriate checklist for the selected aircraft and language
    /// Call this before starting a flight
    func loadRemoteChecklistIfNeeded(aircraftDataService: AircraftDataService) async {
        let language = settings.checklistLanguage.resolvedLanguage

        // Handle remote (premium) aircraft
        if let remoteId = settings.selectedRemoteAircraftId {
            let checklist = await aircraftDataService.fetchChecklist(for: remoteId, language: language)
            // A load outlives its selection: pick X on a weak signal, switch to Y, press START, and X's
            // answer (up to 40 s later) replaced Y's checklist and speeds, or blanked them if it failed.
            // An answer for an aircraft or a language no longer selected is dropped. (v6.0 review)
            guard settings.selectedRemoteAircraftId == remoteId,
                  settings.checklistLanguage.resolvedLanguage == language else { return }
            if let checklist {
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
            let fetched = await aircraftDataService.fetchChecklist(for: bundledId, language: language)
            // The same rule as above: the WT9 must still be the one selected. (v6.0 review)
            guard settings.selectedRemoteAircraftId == nil, settings.selectedAircraft == .wt9Dynamic,
                  settings.checklistLanguage.resolvedLanguage == language else { return }
            if let checklist = fetched {
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

    /// Reload the checklist of a flight restored from its checkpoint: its own aircraft in its own
    /// language, whatever is selected now. `AeroCheckApp` calls it once the aircraft list is in. A
    /// premium flight shows nothing until it is back (offline, the cache has it from the start); the
    /// WT9 falls back to its bundled JSON. (ARCH-08)
    func loadFlightChecklistIfNeeded(aircraftDataService: AircraftDataService) async {
        guard isFlightActive, let aircraft = flightAircraft, aircraft.checklist == nil,
              let flightId = currentFlight?.id else { return }
        var checklist = await aircraftDataService.fetchChecklist(for: aircraft.checklistId, language: aircraft.language)
        // The answer is this flight's only: one ended (or replaced) during the fetch doesn't take it.
        guard isFlightActive, currentFlight?.id == flightId, flightAircraft?.checklist == nil else { return }
        if let checklist {
            noteLanguageFallback(for: checklist, requested: aircraft.language)
        } else if aircraft.remoteId == nil {
            checklist = BundledChecklistService.loadBundledChecklist(for: aircraft.checklistId, language: aircraft.language)
        }
        flightAircraft?.checklist = checklist
        AppLog.general.debugLine("Restored flight's checklist for \(aircraft.checklistId) (\(aircraft.language)): \(checklist == nil ? "not loaded" : "loaded")")
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

    func startFlight(withAircraft aircraft: String, aircraftRegistration: String? = nil, aircraftType: String? = nil, checklistVersion: String? = nil, flightPlanId: UUID? = nil, circuitMode: Bool = false, unplanned: Bool = false) {
        // ARCH-01: never begin a flight for a premium aircraft without its resolved checklist —
        // this is the single choke point, so deep-link/widget entry points are covered too. A
        // blocked start surfaces an explicit error instead of silently showing WT9 content.
        if !isPremiumChecklistResolved {
            flightStartError = L10n.Alert.checklistNotReady
            AppLog.general.debugLine("Flight start blocked: premium checklist not resolved")
            return
        }
        flightStartError = nil
        // A fresh flight must start from a clean checkpoint: the track delta file is append-only
        // (PERF-29), so a stale delta from an unrestored previous session would otherwise leak
        // that session's points into this flight's recovery data.
        clearActiveFlightState()
        // The flight keeps what it starts on, checklist and speeds included: a selection changed later
        // (on this device or synced from another one) is the next flight's.
        flightAircraft = FlightAircraft(bundled: settings.selectedAircraft,
                                        remoteId: settings.selectedRemoteAircraftId,
                                        language: settings.checklistLanguage.resolvedLanguage,
                                        checklist: resolvedRemoteChecklist)
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
        flightIsUnplanned = unplanned
        engineStartTime = nil
        lineUpTime = nil
        landingTime = nil
        engineShutdownTime = nil
        phaseCompletionStatus = [:]
        memoryConfirmation = nil
        freda = FredaSchedule()
        fredaConfirmation = nil
        flightCues = FlightCueState()
        landedCard = nil
        deferredItems = [:]
        deferredChecks = []
        highestCompletedPhase = .preflight
        hasLandingBeenDetected = false
        consecutiveLowSpeedReadings = 0
        consecutiveMovingReadings = 0
        movementRunStart = nil
        stillnessRunStart = nil
        stillnessRunReadings = 0
        movingWhileParkedRun = 0
        currentHighlightedItem = [:] // Reset highlighting
        // Surface the new flight on the Lock Screen / Dynamic Island right away. (UX-25)
        liveActivity?.sync(from: self)
    }

    func endFlight(withFlightPlan flightPlan: FlightPlan? = nil) {
        // Measured times first, whatever path ended the flight. (v5.2)
        refineTimingFromTrack()
        // Ended in cruise with FREDA due: missed, on the flight before it is saved. (6.1)
        stopFreda()
        guard var flight = currentFlight else { return }

        flight.stopTime = Date()
        // The phase bar as it ends, for the Flight Log's checks. (6.1)
        flight.checkOutcomes = checkOutcomesAtEndOfFlight()
        flight.engineStartTime = engineStartTime
        flight.lineUpTime = lineUpTime
        flight.landingTime = landingTime
        flight.engineShutdownTime = engineShutdownTime
        flight.flightPlan = flightPlan
        // Block times are already set on currentFlight, copy them to the final flight
        // (they're already there since we modify currentFlight directly)

        // SEC-C26: drop individually bad GPS points before the track is measured and written.
        // The crash-recovery checkpoint is restored into `currentFlight` without validation, so a
        // corrupt or tampered checkpoint's out-of-range coordinates would otherwise be baked into
        // the cached distance stats and the exported GPX. Individual points are filtered rather
        // than the whole flight rejected — this is the pilot's own in-progress logbook data, and
        // losing all of it to one bad sample would be the worse failure.
        let originalPointCount = flight.gpsTrack.count
        flight.gpsTrack = flight.gpsTrack.filter { point in
            GeoValidation.isValidLatLon(point.latitude, point.longitude) && point.altitude.isFinite
        }
        if flight.gpsTrack.count != originalPointCount {
            AppLog.general.debugLine(
                "Dropped \(originalPointCount - flight.gpsTrack.count) implausible GPS point(s) when ending flight"
            )
        }

        // Precompute summary stats once now that the track is final, so the flight-log list
        // never recomputes an O(n) distance per row. (PERF-22)
        flight.computeSummaryStats()

        flights.insert(flight, at: 0)
        // What this flight teaches the next plans: its departure, its arrival, its cruise. (6.1)
        eetCalibration?.refresh(from: flights, force: true)
        // PR-14: persist the just-finished flight with a CONFIRMED write before discarding the
        // crash-recovery checkpoint (active_flight.json) — the only durable copy of this flight.
        // PR-09: saveFlight persists + syncs ONLY this flight; loadFlights scans the directory, so
        // no whole-logbook rewrite/re-upload is needed when one flight is added.
        let saved = saveFlight(flight)

        currentFlight = nil
        flightAircraft = nil
        isFlightActive = false
        isCircuitMode = false
        flightIsUnplanned = false
        engineStartTime = nil
        lineUpTime = nil
        landingTime = nil
        engineShutdownTime = nil
        phaseCompletionStatus = [:]
        memoryConfirmation = nil
        freda = FredaSchedule()
        fredaConfirmation = nil
        flightCues = FlightCueState()
        landedCard = nil
        deferredItems = [:]
        deferredChecks = []
        currentPhase = .preflight
        hasLandingBeenDetected = false
        consecutiveMovingReadings = 0
        movementRunStart = nil
        stillnessRunStart = nil
        stillnessRunReadings = 0
        movingWhileParkedRun = 0

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
        // Nothing of an abandoned flight is kept, its FREDAs included.
        freda = FredaSchedule()
        fredaConfirmation = nil
        flightCues = FlightCueState()
        landedCard = nil
        currentFlight = nil
        flightAircraft = nil
        isFlightActive = false
        isCircuitMode = false
        flightIsUnplanned = false
        engineStartTime = nil
        lineUpTime = nil
        landingTime = nil
        engineShutdownTime = nil
        phaseCompletionStatus = [:]
        memoryConfirmation = nil
        deferredItems = [:]
        deferredChecks = []
        currentPhase = .preflight
        hasLandingBeenDetected = false
        consecutiveMovingReadings = 0
        movementRunStart = nil
        stillnessRunStart = nil
        stillnessRunReadings = 0
        movingWhileParkedRun = 0
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
        // The cruise check done starts FREDA's count: running the check is the trigger, so there is no
        // timer to remember to start. (v4 UI/UX Revamp; FREDA since 6.1)
        if currentPhase == .cruise { startFredaAfterCruiseCheck() }
        settleOwedCheck(currentPhase, done: true)
    }

    /// Check if all items in current phase are completed. `learningMode` = effective mode.
    func areAllItemsCompleted(learningMode: Bool) -> Bool {
        let visibleCount = activeChecklist.visibleItemCount(for: currentPhase, learningMode: learningMode)
        let currentIndex = currentHighlightedItem[currentPhase] ?? 0
        return ChecklistHighlighting.allItemsCompleted(current: currentIndex, visibleCount: visibleCount)
    }

    // MARK: Deferred items (v6.0 · B2)
    //
    // A paper checklist cannot remind anyone of an item that was put off, and those are the items
    // that get forgotten (Degani & Wiener, 1993: the crew that deferred the fuel check and departed
    // unfuelled). The FAA's EFB guidance asks that leaving an incomplete checklist list the open
    // items for review first. NEXT now does that, and what is left unchecked stays listed here.

    /// The items of `phase` not checked yet: everything from the step-by-step highlight on, among
    /// the items on screen. Empty when step-by-step is off, since then nothing is tracked.
    /// `learningMode` defaults to what the current phase shows; a phase that isn't on screen has no
    /// reveal of its own, so pass the setting for those.
    func openItems(in phase: ChecklistPhase, learningMode: Bool? = nil) -> [ChecklistItem] {
        guard settings.stepByStepHighlighting else { return [] }
        let items = activeChecklist.visibleItems(for: phase, learningMode: learningMode ?? effectiveLearningMode)
        let checked = currentHighlightedItem[phase] ?? 0
        return items.dropFirst(checked).filter { !$0.isHeader }
    }

    /// The deferred items still to check, phase by phase in flight order. Ids that no longer resolve
    /// (a checklist updated mid-flight) are left out.
    var deferredChecklist: [(phase: ChecklistPhase, items: [ChecklistItem])] {
        ChecklistPhase.allCases.compactMap { phase in
            guard let ids = deferredItems[phase], !ids.isEmpty else { return nil }
            let all = activeChecklist.visibleItems(for: phase, learningMode: true)
            let items = ids.compactMap { id in all.first { $0.id == id } }
            return items.isEmpty ? nil : (phase, items)
        }
    }

    var deferredItemCount: Int { deferredChecklist.reduce(0) { $0 + $1.items.count } }

    /// Check a deferred item. Once a skipped phase has nothing deferred left, it was worked through
    /// after all and turns green; a phase missing its ENGINE START / LINE UP / SHUTDOWN press stays red.
    func checkDeferredItem(_ id: String, in phase: ChecklistPhase) {
        guard var ids = deferredItems[phase] else { return }
        ids.removeAll { $0 == id }
        deferredItems[phase] = ids.isEmpty ? nil : ids
        // A check still deferred whole has items left to run: it stays orange until it is run.
        if ids.isEmpty, phaseCompletionStatus[phase] == .skipped, !deferredChecks.contains(phase) {
            phaseCompletionStatus[phase] = .completed
            settleOwedCheck(phase, done: true)
        }
        checkpointActiveFlight(force: true)
    }

    /// Keep the current item for later and move on: the Cockpit's DEFER. The item joins the deferred
    /// list, which follows the pilot until it is checked. A section header isn't an item to defer;
    /// the highlight just moves past it. (v6.0 · P2)
    func deferHighlightedItem() {
        let items = activeChecklist.visibleItems(for: currentPhase, learningMode: effectiveLearningMode)
        let index = currentHighlightedItem[currentPhase] ?? 0
        guard items.indices.contains(index) else { return }
        let item = items[index]
        if !item.isHeader {
            var ids = deferredItems[currentPhase] ?? []
            if !ids.contains(item.id) { ids.append(item.id) }
            deferredItems[currentPhase] = ids
        }
        if index >= items.count - 1 {
            markLastItemComplete(learningMode: effectiveLearningMode)
        } else {
            advanceHighlightedItem(learningMode: effectiveLearningMode)
        }
        checkpointActiveFlight(force: true)
    }

    /// A tap on an item above the highlight (v6.0 review, K-C). A checked item is open again, on its
    /// own: it joins the deferred list and is drawn as open, while the highlight and every other tick
    /// stay where they are. An open one (reopened, or put off with DEFER) is checked. The same gesture
    /// undoes itself.
    ///
    /// It replaces stepping back, which reopened the item and everything after it, with no undo: on
    /// the phone, where a tap on the list also checks, a tap a little too high cost the whole list.
    func toggleItem(at index: Int) {
        let items = activeChecklist.visibleItems(for: currentPhase, learningMode: effectiveLearningMode)
        guard items.indices.contains(index), index < (currentHighlightedItem[currentPhase] ?? 0),
              !items[index].isHeader else { return }
        let id = items[index].id
        if deferredItems[currentPhase]?.contains(id) == true {
            checkDeferredItem(id, in: currentPhase)
            return
        }
        let order = activeChecklist.visibleItems(for: currentPhase, learningMode: true).map(\.id)
        let all = Set(deferredItems[currentPhase] ?? []).union([id])
        deferredItems[currentPhase] = order.filter(all.contains)
        checkpointActiveFlight(force: true)
    }

    // MARK: Deferred checks (v6.0 review, J1-J3)
    //
    // A jump on the phase bar used to defer every open item of every phase it passed, one by one:
    // Preflight to Cruise listed 72 items nobody would work through. A phase jumped over is now
    // deferred WHOLE, as one entry, and run from the deferred list; a phase left part-way keeps its
    // open items one by one, as NEXT does. A jump over two checks or more asks first: defer them, or
    // they were already done (on paper, before the app).

    /// What a forward jump does with the checks it passes.
    enum SkippedChecks {
        /// Listed, each to be run from the deferred list.
        case deferred
        /// The pilot says they were done: checked, green, nothing listed.
        case alreadyDone
    }

    /// A jump over this many checks or more asks first. (J2)
    static let jumpQuestionThreshold = 2

    /// The checks a jump to `target` passes over: the flown phases strictly between here and there
    /// (cruise and descent aren't flown in circuit mode). Empty for a jump back, or to the next phase.
    func checksPassed(jumpingTo target: ChecklistPhase) -> [ChecklistPhase] {
        guard let from = ChecklistPhase.allCases.firstIndex(of: currentPhase),
              let to = ChecklistPhase.allCases.firstIndex(of: target), to > from + 1 else { return [] }
        return ChecklistPhase.allCases[(from + 1)..<to].filter {
            !$0.isSkippedInCircuitMode(isCircuitMode) && !checkIsDone($0)
        }
    }

    /// Whether the jump to `target` asks first.
    func jumpNeedsQuestion(to target: ChecklistPhase) -> Bool {
        settings.stepByStepHighlighting && checksPassed(jumpingTo: target).count >= Self.jumpQuestionThreshold
    }

    /// Nothing ticked in this phase yet, and nothing put off in it: leaving it now leaves the whole
    /// check to do, not some of its items.
    func checkIsUntouched(_ phase: ChecklistPhase) -> Bool {
        (currentHighlightedItem[phase] ?? 0) == 0 && (deferredItems[phase] ?? []).isEmpty
            && (!checkItems(phase).isEmpty || isMemoryCheck(phase, learningMode: settings.learningMode))
    }

    /// The items a deferred check runs through: those on screen when the phase is shown (hidden
    /// memory items stay hidden, as they would be there).
    func checkItems(_ phase: ChecklistPhase) -> [ChecklistItem] {
        activeChecklist.visibleItems(for: phase, learningMode: settings.learningMode)
    }

    private func checkIsDone(_ phase: ChecklistPhase) -> Bool {
        // A memory check has nothing on screen, and is done once confirmed (or run with its items shown).
        if isMemoryCheck(phase, learningMode: settings.learningMode) { return memoryCheckIsDone(phase) }
        let items = checkItems(phase)
        return items.isEmpty || (currentHighlightedItem[phase] ?? 0) >= items.count
    }

    /// The deferred checks, with how many of their items are still to run.
    var deferredCheckList: [(phase: ChecklistPhase, remaining: Int, total: Int)] {
        deferredChecks.map { phase in
            let items = checkItems(phase)
            let done = min(currentHighlightedItem[phase] ?? 0, items.count)
            let remaining = items.dropFirst(done).filter { !$0.isHeader }.count
            return (phase, remaining, items.filter { !$0.isHeader }.count)
        }
    }

    /// Anything owed: a deferred check or a deferred item. The Cockpit's deferred row shows while it is.
    var hasDeferredWork: Bool { !deferredChecks.isEmpty || deferredItemCount > 0 }

    /// CHECK while running a deferred check: the item highlighted in THAT phase is done.
    func checkItem(inDeferredCheck phase: ChecklistPhase) {
        guard deferredChecks.contains(phase) else { return }
        // A memory check has no item to step through: CHECK confirms it, as its DONE does. (An older
        // Companion shows it with RUN and sends this.)
        if isMemoryCheck(phase, learningMode: settings.learningMode) {
            confirmMemoryCheck(phase)
            return
        }
        let count = checkItems(phase).count
        let index = currentHighlightedItem[phase] ?? 0
        currentHighlightedItem[phase] = index >= count - 1
            ? ChecklistHighlighting.lastItemComplete(visibleCount: count)
            : ChecklistHighlighting.advanced(current: index, visibleCount: count)
        concludeDeferredCheckIfRun(phase)
        checkpointActiveFlight(force: true)
    }

    /// DEFER while running a deferred check: the item stays behind as a deferred item.
    func deferItem(inDeferredCheck phase: ChecklistPhase) {
        guard deferredChecks.contains(phase) else { return }
        let items = checkItems(phase)
        let index = currentHighlightedItem[phase] ?? 0
        guard items.indices.contains(index) else { return }
        if !items[index].isHeader {
            var ids = deferredItems[phase] ?? []
            if !ids.contains(items[index].id) { ids.append(items[index].id) }
            deferredItems[phase] = ids
        }
        currentHighlightedItem[phase] = index >= items.count - 1
            ? ChecklistHighlighting.lastItemComplete(visibleCount: items.count)
            : ChecklistHighlighting.advanced(current: index, visibleCount: items.count)
        concludeDeferredCheckIfRun(phase)
        checkpointActiveFlight(force: true)
    }

    /// Run to the end: the check leaves the list. Green when nothing in it was put off; orange, with
    /// the items listed, when something was; red when its phase's own action (ENGINE START, ENGINE
    /// SHUTDOWN) was never pressed.
    private func concludeDeferredCheckIfRun(_ phase: ChecklistPhase) {
        guard checkIsDone(phase) else { return }
        deferredChecks.removeAll { $0 == phase }
        phaseCompletionStatus[phase] = status(ofCheckRunIn: phase)
        settleOwedCheck(phase, done: true)
    }

    private func status(ofCheckRunIn phase: ChecklistPhase) -> PhaseCompletionStatus {
        if phase.hasMissingRequiredAction(engineStarted: engineStartTime != nil,
                                          engineShutDown: engineShutdownTime != nil) {
            return .missingAction
        }
        return (deferredItems[phase] ?? []).isEmpty ? .completed : .skipped
    }

    /// A check jumped over, or left untouched: deferred whole, or done, as the pilot said.
    private func conclude(passedCheck phase: ChecklistPhase, as skipped: SkippedChecks) {
        // A memory check passed over is owed like any other, never grey: deferred whole, or, when the
        // pilot says it was done, done from memory. (6.1)
        if isMemoryCheck(phase, learningMode: settings.learningMode) {
            switch skipped {
            case .alreadyDone:
                markDoneFromMemory(phase)
            case .deferred:
                guard !memoryCheckIsDone(phase) else { return }
                deferWhole(phase)
            }
            return
        }
        let items = checkItems(phase)
        guard !items.isEmpty else {
            if phaseCompletionStatus[phase] == nil { phaseCompletionStatus[phase] = .empty }
            return
        }
        switch skipped {
        case .alreadyDone:
            currentHighlightedItem[phase] = ChecklistHighlighting.lastItemComplete(visibleCount: items.count)
            deferredChecks.removeAll { $0 == phase }
            phaseCompletionStatus[phase] = status(ofCheckRunIn: phase)
            settleOwedCheck(phase, done: true)
        case .deferred:
            guard !checkIsDone(phase) else { return }
            deferWhole(phase)
        }
    }

    /// The check joins the deferred checks, whole, in flight order: orange, or red when its phase's
    /// own action was never pressed.
    private func deferWhole(_ phase: ChecklistPhase) {
        if !deferredChecks.contains(phase) {
            deferredChecks.append(phase)
            deferredChecks.sort { $0.rawValue < $1.rawValue }
        }
        phaseCompletionStatus[phase] = phase.hasMissingRequiredAction(
            engineStarted: engineStartTime != nil,
            engineShutDown: engineShutdownTime != nil) ? .missingAction : .skipped
        // Skipped explicitly: NEXT past it, a jump over it, the landed card's move on. (6.1)
        recordSkipped(phase)
        settleOwedCheck(phase, done: false)
    }

    // MARK: Memory checks (6.1, check slot)
    //
    // A check the Memory test hides whole (its phase configured `learningModeVisibleCount = 0`) is
    // flown from memory. It used to count as done on arrival, since nothing was on screen to tick, and
    // was recorded grey, "nothing to do" (SEC-C36): the app never showed green for a check nobody
    // touched, but it never asked either, and one left undone looked the same as one done. It is now
    // confirmed with one tap, done from memory (green), with six seconds to take it back. Left
    // unconfirmed, it is owed like a check left untouched: listed for review, then deferred whole.
    // Research: memory flows keep their redundancy when confirmed; skipping has to be explicit; the
    // app records, it never ticks by itself (proposal "Checks in flight", principles 1, 4 and 5).

    /// A check with items to do, every one of them hidden: shown in `learningMode` (the current phase's
    /// by default, so a hold-to-reveal makes it a list to work through again).
    func isMemoryCheck(_ phase: ChecklistPhase, learningMode: Bool? = nil) -> Bool {
        guard settings.stepByStepHighlighting else { return false }
        let mode = learningMode ?? (phase == currentPhase ? effectiveLearningMode : settings.learningMode)
        guard !mode, activeChecklist.visibleItemCount(for: phase, learningMode: false) == 0 else { return false }
        return activeChecklist.items(for: phase).contains { !$0.isHeader }
    }

    /// Every item of the check, hidden or not: what "done from memory" stands for.
    private func allItemCount(_ phase: ChecklistPhase) -> Int {
        activeChecklist.visibleItemCount(for: phase, learningMode: true)
    }

    /// A memory check is done once confirmed, or once its items were revealed and worked through: both
    /// leave the highlight past the last item.
    private func memoryCheckIsDone(_ phase: ChecklistPhase) -> Bool {
        (currentHighlightedItem[phase] ?? 0) >= allItemCount(phase)
    }

    /// The current check is done: its items on screen worked through, or, for a memory check, confirmed.
    /// What CHECK gives way to NEXT on, what the pane rule and the check slot read.
    var currentCheckIsDone: Bool {
        guard settings.stepByStepHighlighting else { return true }
        if isMemoryCheck(currentPhase) { return memoryCheckIsDone(currentPhase) }
        return areAllItemsCompleted(learningMode: effectiveLearningMode)
    }

    /// The current check is a memory check still to confirm: the thumb bar's ✓ DONE and the slot's.
    var currentCheckAwaitsConfirmation: Bool {
        isMemoryCheck(currentPhase) && !memoryCheckIsDone(currentPhase)
    }

    /// The last confirmation, offered back for six seconds by the undo toast on either pane.
    struct MemoryConfirmation: Identifiable, Equatable {
        let id: UUID
        let phase: ChecklistPhase
        let confirmedAt: Date
        fileprivate let previousHighlight: Int?
        fileprivate let previousStatus: PhaseCompletionStatus?
        fileprivate let previousFreda: FredaSchedule
        /// Owed before the tap, and the "done late" it recorded: UNDO puts the one back and takes the other
        /// off the flight. (6.1, cues)
        fileprivate var previousOwed: FlightCueState.Owed?
        fileprivate var lateRecordId: UUID?
        /// Set when the same tap moved on to the next check (the checklist pane's ✓ DONE · NEXT).
        fileprivate var movedOn: MovedOn?

        /// Where the tap went, and the checklist as it stood before it and right after it: UNDO puts
        /// the "before" back when nothing has happened since. (6.1)
        fileprivate struct MovedOn: Equatable {
            let to: ChecklistPhase
            let before: ChecklistProgress
            let after: ChecklistProgress
            /// The move was READY FOR LINE UP and recorded the take-off estimate: UNDO forgets it. (6.2)
            var recordedLineUp = false
        }
    }

    /// Set by a confirmation, cleared by its toast (UNDO, or the six seconds up).
    private(set) var memoryConfirmation: MemoryConfirmation?

    /// How long a confirmation can be taken back: the undo toast's six seconds.
    static let memoryConfirmationUndoWindow: TimeInterval = 6

    /// ✓ DONE on a memory check: the current one (the thumb bar, the slot, the Companion) or one
    /// deferred whole (the deferred list). Recorded done from memory, green; the deferred list lets go
    /// of it. Nothing happens to a check that isn't a memory check or is already done.
    func confirmMemoryCheck(_ phase: ChecklistPhase? = nil) {
        let phase = phase ?? currentPhase
        guard isMemoryCheck(phase, learningMode: settings.learningMode), !memoryCheckIsDone(phase) else { return }
        var confirmation = MemoryConfirmation(id: UUID(), phase: phase, confirmedAt: Date(),
                                              previousHighlight: currentHighlightedItem[phase],
                                              previousStatus: phaseCompletionStatus[phase],
                                              previousFreda: freda,
                                              previousOwed: flightCues.owed[phase])
        markDoneFromMemory(phase, stayingInPhase: phase == currentPhase)
        if confirmation.previousOwed != nil {
            confirmation.lateRecordId = currentFlight?.checkRecords?.last { $0.kind == .doneLate }?.id
        }
        memoryConfirmation = confirmation
        // The cruise check done starts FREDA's count, however it was done.
        if phase == .cruise && phase == currentPhase { startFredaAfterCruiseCheck() }
        checkpointActiveFlight(force: true)
    }

    /// Where the checklist pane's ✓ DONE moves on to, in the same tap: the next check. Nil when it only
    /// confirms: no memory check to confirm, the last check, or the phase's own action (ENGINE START,
    /// ENGINE SHUTDOWN) still to press, since going on would record the check red. Out of the check
    /// before departure, the tap is READY FOR LINE UP too (`nextPhase`). (6.1, author's decision: one
    /// tap on the CHECKLIST page)
    var memoryConfirmationMovesTo: ChecklistPhase? {
        guard currentCheckAwaitsConfirmation,
              !currentPhase.hasMissingRequiredAction(engineStarted: engineStartTime != nil,
                                                    engineShutDown: engineShutdownTime != nil) else { return nil }
        return currentPhase.nextNavigable(circuitMode: isCircuitMode)
    }

    /// ✓ <CHECK> DONE · NEXT: <CHECK> on the checklist pane (and the Companion's): the memory check
    /// recorded done from memory and the next check opened, in one tap. The toast's UNDO takes both back
    /// (`undoMemoryConfirmation`). Where it can't move on (`memoryConfirmationMovesTo` is nil) it only
    /// confirms. The map's check slot keeps its confirm that stays on the check.
    func confirmMemoryCheckAndAdvance() {
        guard memoryConfirmationMovesTo != nil else {
            confirmMemoryCheck()
            return
        }
        let phase = currentPhase
        let before = checklistProgress
        let lineUpBefore = lineUpTime
        confirmMemoryCheck()
        guard var confirmation = memoryConfirmation, confirmation.phase == phase else { return }
        nextPhase()
        confirmation.movedOn = .init(to: currentPhase, before: before, after: checklistProgress,
                                     recordedLineUp: lineUpBefore == nil && lineUpTime != nil)
        memoryConfirmation = confirmation
        checkpointActiveFlight(force: true)
    }

    /// Done from memory: every item reached, off the deferred list, green. `stayingInPhase`: the check
    /// being flown keeps `.doneFromMemory` until it is left, where a phase action still unpressed turns
    /// it red, as for any check; one left behind is red at once.
    private func markDoneFromMemory(_ phase: ChecklistPhase, stayingInPhase: Bool = false) {
        currentHighlightedItem[phase] = ChecklistHighlighting.lastItemComplete(visibleCount: allItemCount(phase))
        deferredChecks.removeAll { $0 == phase }
        let actionMissing = phase.hasMissingRequiredAction(
            engineStarted: engineStartTime != nil, engineShutDown: engineShutdownTime != nil)
        phaseCompletionStatus[phase] = actionMissing && !stayingInPhase ? .missingAction : .doneFromMemory
        settleOwedCheck(phase, done: true)
    }

    /// UNDO on the confirmation's toast.
    ///
    /// - Still on that check: it is open again, as it was.
    /// - The same tap moved on (✓ DONE · NEXT), and the pilot is still on the check it opened: back to
    ///   the confirmed check, open again. Nothing done since, the checklist is exactly as before the tap
    ///   (phase bar, deferred list, highlights). Something done since in the check moved to (a CHECK,
    ///   say): that stays, as when going back on the phase bar, and the confirmed check is open again.
    /// - Moved on further since (NEXT within the six seconds): it was left unconfirmed after all, so
    ///   it is deferred whole.
    func undoMemoryConfirmation(_ id: UUID) {
        guard let confirmation = memoryConfirmation, confirmation.id == id else { return }
        memoryConfirmation = nil
        // Owed before the tap: owed again, and the "done late" goes. (6.1, cues)
        if let owed = confirmation.previousOwed {
            removeCheckRecord(confirmation.lateRecordId)
            flightCues.restoreOwed(confirmation.phase, owed)
        }
        if let movedOn = confirmation.movedOn, currentPhase == movedOn.to {
            // The same tap was READY FOR LINE UP: the estimate goes with it, and the NEXT that follows
            // makes it again, ETOs included. (6.2)
            if movedOn.recordedLineUp {
                lineUpTime = nil
                currentFlight?.lineUpTime = nil
            }
            if checklistProgress == movedOn.after {
                checklistProgress = movedOn.before
            } else {
                currentHighlightedItem[confirmation.phase] = confirmation.previousHighlight
                phaseCompletionStatus[confirmation.phase] = confirmation.previousStatus
                if highestCompletedPhase == confirmation.phase {
                    highestCompletedPhase = movedOn.before.highestCompletedPhase
                }
                enterPhase(confirmation.phase)
            }
            hiddenItemsRevealed = false
            if currentPhase != .cruise { stopFreda() }
            if confirmation.phase == .cruise { freda = confirmation.previousFreda }
            checkpointActiveFlight(force: true)
            return
        }
        currentHighlightedItem[confirmation.phase] = confirmation.previousHighlight
        if confirmation.phase == currentPhase {
            phaseCompletionStatus[confirmation.phase] = confirmation.previousStatus
            if confirmation.phase == .cruise { freda = confirmation.previousFreda }
        } else {
            deferWhole(confirmation.phase)
        }
        checkpointActiveFlight(force: true)
    }

    /// The toast's six seconds are up.
    func dismissMemoryConfirmation(_ id: UUID) {
        if memoryConfirmation?.id == id { memoryConfirmation = nil }
    }

    // MARK: Cues from the flight (6.1, "Checks in flight", build plan 4)
    //
    // The detector's cues (FlightCues.swift) say when a check is due: the slot turns amber then, and not
    // before. A cue that passes a check still open turns it owed, once: filled amber until it is done or
    // skipped explicitly. Detection never ticks an item and never changes the phase; the one exception is
    // the landed card, whose answer takes the pilot on to AFTER LANDING.

    /// A cue from the detector (`FlightEventDetector.onCue`).
    func noteFlightCue(_ event: FlightCueEvent) {
        guard isFlightActive else { return }
        switch event.kind {
        case .leg:
            flightCues.startLeg()
            // The next take-off roll takes an unanswered landed card away, as it does the full-stop card:
            // the review at END FLIGHT offers that landing again.
            landedCard = nil
        case .fired(let cue):
            let owed = flightCues.fire(cue, at: event.time, circuitMode: isCircuitMode, isOpen: checkIsOpen)
            for phase in owed {
                recordCheck(CheckRecord(phase: phase, kind: .owed, at: event.time, cue: cue))
            }
            // The descent: FREDA gives way to the descent check, and one due now is missed, as when cruise
            // is left. (#234 decision 1)
            if cue == .descent, !isCircuitMode, currentPhase == .cruise { stopFreda() }
        case .withdrawn(let cue):
            flightCues.withdraw(cue)
        }
        checkpointActiveFlight(force: true)
    }

    /// The detector has a field near the aircraft to anchor the take-off to: from now on the cued checks
    /// wait for their cue, the first take-off's included (`FlightCueState.hasCueSource`). Called on every
    /// detected fix; writes once. (6.1.0)
    func noteCueSourceReady() {
        guard isFlightActive, !flightCues.hasCueSource else { return }
        flightCues.noteCueSource()
    }

    /// When the slot shows `phase`'s check: not yet, due, or owed.
    func cueTiming(for phase: ChecklistPhase) -> CheckSlotTiming {
        flightCues.timing(for: phase, circuitMode: isCircuitMode)
    }

    /// The flight is at circuit height near the field (circuits: on base), and the Cockpit not yet on
    /// the landing check: the slot shows it, dashed, whatever was open before it. (6.1)
    var landingCheckShown: Bool {
        flightCues.landingShown(circuitMode: isCircuitMode)
            && currentPhase.rawValue >= ChecklistPhase.climb.rawValue
            && currentPhase.rawValue < ChecklistPhase.landing.rawValue
    }

    /// The cue that made `phase`'s check owed, if it is.
    func owedCue(for phase: ChecklistPhase) -> FlightCue? {
        flightCues.owed[phase]?.cue
    }

    /// A check still to do, not yet left behind: what a cue can find open.
    private func checkIsOpen(_ phase: ChecklistPhase) -> Bool {
        guard phase.rawValue >= currentPhase.rawValue, allItemCount(phase) > 0 else { return false }
        if let status = phaseCompletionStatus[phase], status.isDone || status.isAnsweredAfterLanding { return false }
        return phase == currentPhase ? !currentCheckIsDone : !checkIsDone(phase)
    }

    /// The check was done or skipped: owed no more. Done while owed, the flight records it done late.
    private func settleOwedCheck(_ phase: ChecklistPhase, done: Bool) {
        guard flightCues.resolve(phase) != nil, done else { return }
        recordCheck(CheckRecord(phase: phase, kind: .doneLate, at: Date()))
    }

    /// Skipped explicitly, on the flight for the debrief: once per skip, not per path that sees it.
    private func recordSkipped(_ phase: ChecklistPhase) {
        guard isFlightActive, allItemCount(phase) > 0 else { return }
        if let last = currentFlight?.checkRecords?.last(where: { $0.phaseRawValue == phase.rawValue }),
           last.kind == .skipped { return }
        recordCheck(CheckRecord(phase: phase, kind: .skipped, at: Date()))
    }

    /// On the flight, for the debrief (bounded, like the FREDAs).
    private func recordCheck(_ record: CheckRecord) {
        // Read before the write: `currentFlight?.x = f(currentFlight)` is an exclusivity violation.
        guard let flight = currentFlight else { return }
        let records = flight.checkRecords ?? []
        guard records.count < CheckRecord.maxPerFlight else { return }
        currentFlight?.checkRecords = records + [record]
    }

    private func removeCheckRecord(_ id: UUID?) {
        guard let id, let flight = currentFlight, let records = flight.checkRecords else { return }
        let kept = records.filter { $0.id != id }
        currentFlight?.checkRecords = kept.isEmpty ? nil : kept
    }

    /// The slot's one tap to the next check once the flight says it is due (the descent check in cruise,
    /// say): on to it, and a memory check recorded done from memory, in one tap. The toast's UNDO takes
    /// both back. (6.1; #234 removed the slot's way to the descent check until this cue)
    func advanceAndConfirmMemoryCheck() {
        guard currentCheckIsDone, let next = currentPhase.nextNavigable(circuitMode: isCircuitMode) else { return }
        let before = checklistProgress
        let lineUpBefore = lineUpTime
        nextPhase()
        guard currentPhase == next, currentCheckAwaitsConfirmation else { return }
        confirmMemoryCheck()
        guard var confirmation = memoryConfirmation, confirmation.phase == next else { return }
        confirmation.movedOn = .init(to: next, before: before, after: checklistProgress,
                                     recordedLineUp: lineUpBefore == nil && lineUpTime != nil)
        memoryConfirmation = confirmation
        checkpointActiveFlight(force: true)
    }

    // MARK: The checks in the debrief (6.1, "Checks in flight", build plan 6)

    /// The phase bar as the flight ends, kept on the flight for the Flight Log: each check flown, as it was
    /// recorded; the one the flight ends on, as it stands (done, or still open); those after it, not
    /// reached. Circuits fly no cruise and no descent, so those have none.
    func checkOutcomesAtEndOfFlight() -> [CheckOutcome] {
        ChecklistPhase.allCases.compactMap { phase in
            guard !phase.isSkippedInCircuitMode(isCircuitMode) else { return nil }
            if phase == currentPhase { return CheckOutcome(phase: phase, status: outcomeOfCurrentCheck()) }
            if phase.rawValue > currentPhase.rawValue {
                // Gone back to an earlier check: what was recorded further on stays as recorded.
                guard let recorded = phaseCompletionStatus[phase], recorded != .notStarted else {
                    return CheckOutcome(phase: phase, status: .notReached)
                }
                return CheckOutcome(phase: phase, recorded: recorded)
            }
            return CheckOutcome(phase: phase, recorded: getPhaseStatus(phase))
        }
    }

    /// The check the flight ends on, as NEXT would have recorded it, without leaving it: END FLIGHT is
    /// pressed on the last check, which has no NEXT, or from the Menu on any check.
    private func outcomeOfCurrentCheck() -> CheckOutcome.Status {
        let phase = currentPhase
        if let answered = phaseCompletionStatus[phase], answered.isAnsweredAfterLanding {
            return answered == .notSure ? .notSure : .confirmedAfterLanding
        }
        if phase.hasMissingRequiredAction(engineStarted: engineStartTime != nil,
                                          engineShutDown: engineShutdownTime != nil) {
            return .actionMissing
        }
        if allItemCount(phase) == 0
            || (!isMemoryCheck(phase) && currentPhaseHasNoVisibleItems(learningMode: effectiveLearningMode)) {
            return .nothingToDo
        }
        guard currentCheckIsDone else { return .open }
        if !(deferredItems[phase] ?? []).isEmpty { return .skipped }
        return phaseCompletionStatus[phase] == .doneFromMemory ? .doneFromMemory : .done
    }

    // MARK: The landed card (6.1, M4)

    /// The detector's full stop on a flight that isn't circuits: the landed card, in place of the
    /// full-stop card. Circuits keep that card and its stop-and-go to TAXI.
    func presentLandedCard(touchdown: Date, aerodrome: String?) {
        guard isFlightActive, !isCircuitMode, landedCard?.touchdown != touchdown else { return }
        landedCard = LandedCard(touchdown: touchdown, aerodrome: aerodrome)
    }

    /// The detector's full stop, if it is the landed card's: a flight that isn't circuits. True when it
    /// took it; the caller then lets the detector's own card go.
    @discardableResult
    func takeFullStopForLandedCard(_ event: DetectedFlightEvent?) -> Bool {
        guard let event, event.type == .fullStop, isFlightActive, !isCircuitMode else { return false }
        presentLandedCard(touchdown: event.timestamp, aerodrome: event.airport?.ident)
        return true
    }

    /// The landing check was done before the touchdown (or has nothing to do): the card only takes the
    /// pilot on, with nothing to ask.
    var landingCheckSettled: Bool {
        if let status = phaseCompletionStatus[.landing], status.isDone || status.isAnsweredAfterLanding { return true }
        return allItemCount(.landing) == 0 || checkIsDone(.landing)
    }

    /// The pilot's answer. Yes: the landing check confirmed after landing (a green outline, never solid
    /// green). Not sure: recorded for the debrief. Either way the landing is recorded as the full-stop
    /// card's CONFIRM recorded it, and AFTER LANDING comes next.
    func answerLandedCard(_ answer: LandedAnswer) {
        guard let card = landedCard else { return }
        landedCard = nil
        if !landingCheckSettled {
            switch answer {
            case .yes: settleLandingCheckAfterTouchdown(.confirmedAfterLanding)
            case .notSure: settleLandingCheckAfterTouchdown(.notSure)
            case .next: break
            }
        }
        recordFullStop(at: card.touchdown)
    }

    /// Nothing answered: the next take-off roll, or a landing recorded by hand.
    func dismissLandedCard() {
        landedCard = nil
    }

    private func settleLandingCheckAfterTouchdown(_ status: PhaseCompletionStatus) {
        currentHighlightedItem[.landing] = ChecklistHighlighting.lastItemComplete(visibleCount: allItemCount(.landing))
        deferredItems[.landing] = nil
        deferredChecks.removeAll { $0 == .landing }
        phaseCompletionStatus[.landing] = status
        flightCues.resolve(.landing)
        recordCheck(CheckRecord(phase: .landing, kind: status == .notSure ? .notSure : .confirmedAfterLanding, at: Date()))
    }

    #if DEBUG
    /// DEV-ONLY (`AEROCHECK_CUES`, captures): the cues of a leg, and a check owed, without a detector.
    func applyCuesForCapture(_ cues: [FlightCue], owed: [ChecklistPhase: FlightCue] = [:], at time: Date = Date()) {
        noteFlightCue(FlightCueEvent(kind: .leg, time: time.addingTimeInterval(-600), implied: false, aerodrome: nil))
        for (i, cue) in cues.enumerated() {
            noteFlightCue(FlightCueEvent(kind: .fired(cue), time: time.addingTimeInterval(Double(i - cues.count) * 60),
                                         implied: false, aerodrome: nil))
        }
        for (phase, cue) in owed { flightCues.owe(phase, cue: cue, at: time) }
    }

    /// DEV-ONLY (`AEROCHECK_SCENE=landed`): the landed card up.
    func presentLandedCardForCapture(touchdown: Date, aerodrome: String) {
        landedCard = LandedCard(touchdown: touchdown, aerodrome: aerodrome)
    }
    #endif

    /// The items of the current phase deferred with DEFER, for drawing them as deferred rather than done.
    var currentPhaseDeferredIds: Set<String> {
        Set(deferredItems[currentPhase] ?? [])
    }

    /// Whether the current phase has nothing to show at all. (SEC-C36)
    func currentPhaseHasNoVisibleItems(learningMode: Bool) -> Bool {
        activeChecklist.visibleItemCount(for: currentPhase, learningMode: learningMode) == 0
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

    /// Replace the live estimates of block off, take-off, landing and block on with what the whole
    /// recorded track shows (`TrackTimes`). Idempotent. Called by END FLIGHT before anything reads
    /// the times — the plan's times over, the flight thread, the saved flight — and again by
    /// `endFlight` for any other path that ends a flight. (v5.2)
    ///
    /// Take-off lands in `lineUpTime`, which has only ever been used as the take-off time (flight
    /// time, the departure's ATO, the nav log). Until now it was the Line Up tap plus 2 minutes; on
    /// six real flights that was 8 s to 2 min 10 s off. The checklist estimate stays when the track
    /// shows no take-off (a track too sparse, or a flight that never flew).
    ///
    /// Landing: the detector stamps the first fix on the runway, 0–6 s after the touchdown; the track
    /// places it inside that interval. The recorded time stays when the track shows no landing.
    func refineTimingFromTrack() {
        guard var flight = currentFlight else { return }
        let times = TrackTimes.analyze(track: flight.gpsTrack,
                                       engineStart: engineStartTime ?? flight.engineStartTime,
                                       engineShutdown: engineShutdownTime ?? flight.engineShutdownTime)
        if let blockOff = times.blockOff {
            flight.blockOffTime = blockOff
            flight.blockOffLatitude = times.blockOffCoordinate?.latitude ?? flight.blockOffLatitude
            flight.blockOffLongitude = times.blockOffCoordinate?.longitude ?? flight.blockOffLongitude
        }
        if let blockOn = times.blockOn {
            flight.blockOnTime = blockOn
            flight.blockOnLatitude = times.blockOnCoordinate?.latitude ?? flight.blockOnLatitude
            flight.blockOnLongitude = times.blockOnCoordinate?.longitude ?? flight.blockOnLongitude
        }
        if let takeoff = times.takeoff {
            lineUpTime = takeoff
            flight.lineUpTime = takeoff
        }
        if let landing = times.landing, landing > (flight.lineUpTime ?? .distantPast) {
            // The full stop recorded for this touchdown (by the detector, or a LANDED tap) moves with
            // it, so the chart and the landing list show one time for one landing.
            let gaps = flight.fullStopTimes.map { abs($0.timeIntervalSince(landing)) }
            if let closest = gaps.indices.min(by: { gaps[$0] < gaps[$1] }), gaps[closest] < 180 {
                flight.fullStopTimes[closest] = landing
            }
            landingTime = landing
            flight.landingTime = landing
        }
        currentFlight = flight
    }

    // MARK: - Departure and arrival aerodromes (v6.1)

    /// END FLIGHT, right after `refineTimingFromTrack()`: find a departure or an arrival the live
    /// detection missed, from the measured block-off and block-on positions, and let the measured
    /// block on correct a live arrival that names another aerodrome (`settleAerodromesAfterRefit`).
    ///
    /// The live detection names the arrival only after two slow fixes at the final stop, and the 5 m
    /// distance filter often records one before the engine stops (29 Sep 2026, LSZQ → LSGE: the
    /// flight was saved with no arrival, and the Logbook titled it by its registration). The refit
    /// always has a block on when the aircraft moved, so the arrival is found here.
    func settleAerodromesAtEndOfFlight(nearestAerodrome: (CLLocationCoordinate2D) -> String?) {
        guard var flight = currentFlight else { return }
        let settled = flight.settleAerodromesAfterRefit(nearestAerodrome: nearestAerodrome)
        guard settled.departure || settled.arrival else { return }
        currentFlight = flight
        let ends = [settled.departure ? "departure" : nil,
                    settled.correctedArrival ? "arrival (corrected)" : settled.arrival ? "arrival" : nil].compactMap { $0 }
        AppLog.general.publicLine("END FLIGHT set the \(ends.joined(separator: " and ")) from the track")
    }

    /// Flights the Logbook's repair tried with airport data loaded and could not place: their
    /// aerodrome is not in the data. Remembered on this device so opening the Logbook does not load
    /// the airport data again for them at every launch. They are tried again whenever the repair
    /// runs for another flight.
    private let unplacedAerodromeFlightsKey = "aerodromeRepairUnplacedFlightIds"

    /// Whether the logbook holds a flight the repair has not tried yet: a departure or an arrival
    /// missing, with a position to find it from. Waits for the logbook to load.
    func hasFlightsAwaitingAerodromes() async -> Bool {
        await flightsLoad?.value
        let unplaced = Set(defaults.stringArray(forKey: unplacedAerodromeFlightsKey) ?? [])
        return flights.contains { $0.canFillAerodromes && !unplaced.contains($0.id.uuidString) }
    }

    /// Fill the departure or the arrival of stored flights saved without one: before 6.1 an arrival was
    /// found only by the live detection (see `settleAerodromesAtEndOfFlight(nearestAerodrome:)`), and the
    /// oldest flights predate the detection altogether. Only a missing end is filled, from the
    /// block-off or block-on position, else the first or last fix on the ground; a flight whose
    /// aerodrome is not in the data stays as it is. Each filled flight is saved and synced like any
    /// edit. Waits for the logbook to load; the caller loads the airport data.
    ///
    /// - Returns: the number of flights filled.
    @discardableResult
    func repairMissingAerodromes(nearestAerodrome: (CLLocationCoordinate2D) -> String?) async -> Int {
        await flightsLoad?.value
        var unplaced = Set(defaults.stringArray(forKey: unplacedAerodromeFlightsKey) ?? [])
        var repaired = 0, departures = 0, arrivals = 0
        for index in flights.indices where flights[index].canFillAerodromes {
            var flight = flights[index]
            let filled = flight.fillMissingAerodromes(nearestAerodrome: nearestAerodrome)
            if filled.departure || filled.arrival {
                flight.touch()
                flights[index] = flight
                saveFlight(flight)
                repaired += 1
                departures += filled.departure ? 1 : 0
                arrivals += filled.arrival ? 1 : 0
            }
            if flight.canFillAerodromes {
                unplaced.insert(flight.id.uuidString)
            } else {
                unplaced.remove(flight.id.uuidString)
            }
        }
        // Forget flights that are gone, so the list only ever holds what the logbook still has.
        unplaced.formIntersection(flights.map(\.id.uuidString))
        defaults.set(unplaced.sorted(), forKey: unplacedAerodromeFlightsKey)
        if repaired > 0 || !unplaced.isEmpty {
            AppLog.general.publicLine("Aerodrome repair: \(repaired) flight(s) filled (\(departures) departure(s), \(arrivals) arrival(s)), \(unplaced.count) not in the airport data")
        }
        return repaired
    }

    func recordLineUpTime() {
        // Adds 2 minutes to current time as specified
        lineUpTime = Date().addingTimeInterval(120)
        currentFlight?.lineUpTime = lineUpTime
        checkpointActiveFlight(force: true)
    }

    /// Wired at launch to the plan manager's `anchorETOsOnLineUp`: AppState has no reference to it, and
    /// READY FOR LINE UP moves the active plan's ETOs. Nil until then (and in the tests that don't set
    /// it), which moves nothing. (6.2)
    @ObservationIgnored var anchorETOsOnLineUp: (@MainActor (Date) -> Void)?

    /// READY FOR LINE UP: the pilot going on from the check before departure, whichever way (the thumb
    /// bar, the NEXT chip and its review, the check slot, the one-tap memory confirmation, the
    /// Companion's NEXT). The take-off is estimated two minutes from now and the plan's ETOs count from
    /// it, as the button did before 6.2. The first time only: a later circuit, or the check flown again,
    /// keeps the first take-off, which the flight time and the logbook's Time OFF read. A jump on the
    /// phase bar records nothing (END FLIGHT measures the take-off from the track anyway).
    private func recordReadyForLineUp() {
        guard isFlightActive, currentPhase.readiesForLineUp, lineUpTime == nil else { return }
        recordLineUpTime()
        if let lineUpTime { anchorETOsOnLineUp?(lineUpTime) }
    }

    /// Record the (final) landing. `time` is the physical touchdown time when the caller
    /// knows it (the v2 detector's rollout carries it — see notifyManualEvent); "now"
    /// otherwise. The old backDatedStopTime() 1-minute guess is retired: the detector
    /// stamps full stops at the actual touchdown, and the post-flight reconciliation
    /// (PR-B) corrects purely-manual entries.
    func recordLanding(at time: Date? = nil) {
        let landing = clampedToLineUp(time ?? Date())
        landingTime = landing
        currentFlight?.landingTime = landing
        hasLandingBeenDetected = true

        // The final landing is always a full-stop landing — but never double-count one
        // physical landing (a manual LANDED right after a confirmed full stop).
        if !isDuplicateLandingEvent(at: landing) {
            currentFlight?.fullStopCount += 1
            currentFlight?.fullStopTimes.append(landing)
        }
        checkpointActiveFlight(force: true)
    }

    /// Update landing time (long-press update): "now", since there is no detector context here.
    func updateLandingTime() {
        landingTime = clampedToLineUp(Date())
        currentFlight?.landingTime = landingTime
    }

    /// A landing can never precede line-up — otherwise flight time (landing − line-up)
    /// goes negative. (v4.0.0 review P2, kept from the backDatedStopTime era)
    private func clampedToLineUp(_ candidate: Date) -> Date {
        if let lineUp = lineUpTime, candidate < lineUp { return lineUp }
        return candidate
    }

    /// Two landings (T&G or full stop) closer than this are one physical event — these
    /// aircraft cannot land twice in under a minute. Guards manual double-taps and
    /// manual/auto duplicates; the corpus contains real pairs 7–35 s apart. (R5)
    private let landingDedupeWindow: TimeInterval = 60.0

    private func isDuplicateLandingEvent(at time: Date) -> Bool {
        guard let flight = currentFlight else { return false }
        let last = [flight.touchAndGoTimes.last, flight.fullStopTimes.last].compactMap { $0 }.max()
        guard let last else { return false }
        return abs(time.timeIntervalSince(last)) < landingDedupeWindow
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

    /// Record a go-around and return to climb phase, resetting subsequent phases.
    /// `time` is the physical timestamp (the approach's lowest point, decision D4) when
    /// the detector knows it; "now" for a purely manual entry.
    func recordGoAround(at time: Date? = nil) {
        let goAroundTime = time ?? Date()
        // Duplicate guard: a second go-around within a minute is the same physical event.
        if let last = currentFlight?.goAroundTimes.last,
           abs(goAroundTime.timeIntervalSince(last)) < landingDedupeWindow {
            AppLog.flightEvents.debugLine("Go-around ignored (duplicate within \(Int(landingDedupeWindow)) s)")
            return
        }
        currentFlight?.goAroundCount += 1
        currentFlight?.goAroundTimes.append(goAroundTime)

        // Reset phases from climb onwards. The new circuit starts them clean, deferred items included:
        // what was put off on the last lap is asked again on this one. (v6.0 review, confirmed rule)
        for phase in ChecklistPhase.allCases {
            if phase.rawValue >= ChecklistPhase.climb.rawValue {
                phaseCompletionStatus[phase] = nil
                currentHighlightedItem[phase] = 0
                deferredItems[phase] = nil
                deferredChecks.removeAll { $0 == phase }
            }
        }

        // Go to climb phase
        currentPhase = .climb
    }

    /// Record a touch-and-go and return to climb phase, resetting subsequent phases.
    /// `time` is the physical touchdown time when the detector knows it; "now" otherwise.
    func recordTouchAndGo(at time: Date? = nil) {
        let touchAndGoTime = time ?? Date()
        if isDuplicateLandingEvent(at: touchAndGoTime) {
            AppLog.flightEvents.debugLine("Touch-and-go ignored (duplicate landing within \(Int(landingDedupeWindow)) s)")
            return
        }
        currentFlight?.touchAndGoCount += 1
        currentFlight?.touchAndGoTimes.append(touchAndGoTime)

        // Reset phases from climb onwards. The new circuit starts them clean, deferred items included:
        // what was put off on the last lap is asked again on this one. (v6.0 review, confirmed rule)
        for phase in ChecklistPhase.allCases {
            if phase.rawValue >= ChecklistPhase.climb.rawValue {
                phaseCompletionStatus[phase] = nil
                currentHighlightedItem[phase] = 0
                deferredItems[phase] = nil
                deferredChecks.removeAll { $0 == phase }
            }
        }

        // Go to climb phase
        currentPhase = .climb
    }

    /// Record a full stop landing: the detector's card confirmed, or a manual stop-and-go.
    /// `time` is the physical TOUCHDOWN time when the detector knows it (v2 stamps full
    /// stops at touchdown, not at the end of the stillness dwell); "now" otherwise.
    /// Stop-and-gos count as full stops (decision D1) — the flight log labels every
    /// non-final full stop "stop-and-go" at display time.
    ///
    /// Where the Cockpit goes next depends on the flight (6.1.0, author decision):
    /// - Circuits (`isCircuitMode`: started with CIRCUITS, or a local-profile thread) fly
    ///   stop-and-gos: the next circuit starts at TAXI, taxi through after landing reset.
    /// - Any other flight has landed: AFTER LANDING, every check kept as it stands. (Until
    ///   6.1 it went to TAXI as well, a check already run, and the pilot had to go and find
    ///   the after landing check.) The landing time, the count and the logbook are the same
    ///   either way: only the checklist differs.
    func recordFullStop(at time: Date? = nil) {
        let fullStopTime = clampedToLineUp(time ?? Date())
        if isDuplicateLandingEvent(at: fullStopTime) {
            AppLog.flightEvents.debugLine("Full stop ignored (duplicate landing within \(Int(landingDedupeWindow)) s)")
            return
        }
        currentFlight?.fullStopCount += 1
        currentFlight?.fullStopTimes.append(fullStopTime)
        // A full stop is a landing: keep landingTime tracking the latest one (the final
        // full stop of the flight is the flight's landing time). Set before the phase
        // changes, so AFTER LANDING's own stop fallback (`addGPSPoint`) never re-stamps it.
        landingTime = fullStopTime
        currentFlight?.landingTime = fullStopTime
        hasLandingBeenDetected = true

        if isCircuitMode {
            // Reset phases from taxi onwards (taxi through afterLanding), deferred items included,
            // as for a touch-and-go. (v6.0 review, confirmed rule)
            for phase in ChecklistPhase.allCases {
                if phase.rawValue >= ChecklistPhase.taxi.rawValue && phase.rawValue <= ChecklistPhase.afterLanding.rawValue {
                    phaseCompletionStatus[phase] = nil
                    currentHighlightedItem[phase] = 0
                    deferredItems[phase] = nil
                    deferredChecks.removeAll { $0 == phase }
                }
            }
            currentPhase = .taxi
        } else if currentPhase.rawValue < ChecklistPhase.afterLanding.rawValue {
            // Forward only, as a tap on AFTER LANDING in the phase bar would go: the check left
            // keeps what was ticked and defers what wasn't, and a check passed over is deferred
            // whole. The detection never marks a check done. A pilot already on AFTER LANDING or
            // beyond stays where they are.
            goToPhase(.afterLanding, skipped: .deferred)
        }
        // A landing is logbook data: on disk now, not at the next throttled checkpoint.
        checkpointActiveFlight(force: true)
    }

    // MARK: - Post-flight reconciliation (D2)

    /// The review diff computed right after END FLIGHT, when the offline re-segmentation
    /// disagrees with what was confirmed in flight. Non-nil drives the review sheet
    /// (`FlightReconciliationView` via ContentView); cleared by apply or keep.
    var pendingReconciliation: FlightReconciliation.Result?

    /// Apply the reviewed diff to the just-saved flight: rewrite its events from the
    /// review rows, back-fill missing block times, refresh stats, persist and re-sync.
    ///
    /// `landings` counts a flight's landings against the home aerodrome. The plan attached to the flight
    /// takes the new count where it still holds END FLIGHT's (a landing confirmed only here used to leave
    /// it at 0 / 0), and both counts come back so the plan list's copy can follow. (v6.1)
    @discardableResult
    func applyReconciliation(
        _ result: FlightReconciliation.Result,
        landings: (Flight) -> LandingTally = { LandingTally(total: $0.totalLandings, atHome: nil) }
    ) -> (previous: LandingTally, updated: LandingTally)? {
        defer { pendingReconciliation = nil }
        guard let index = flights.firstIndex(where: { $0.id == result.flightId }) else { return nil }
        var flight = flights[index]
        let previous = landings(flight)
        FlightReconciliation.apply(result, to: &flight)
        let updated = landings(flight)
        flight.flightPlan = flight.flightPlan?.settlingLandings(updated, replacing: previous)
        flight.computeSummaryStats()
        flights[index] = flight
        _ = saveFlight(flight)
        AppLog.flightEvents.debugLine("Reconciliation applied to flight \(result.flightId): \(flight.fullStopCount) FS, \(flight.touchAndGoCount) TG, \(flight.goAroundCount) GA")
        return (previous, updated)
    }

    /// "Keep as recorded": confirmed events stay untouched (D2). Missing block times are
    /// still back-filled — that is additive, not a change to anything the pilot entered.
    func keepRecordedReconciliation() {
        guard let result = pendingReconciliation else { return }
        pendingReconciliation = nil
        backfillBlockTimes(result)
    }

    /// Additive block-time back-fill, used both by "keep as recorded" and directly when
    /// the analysis found no event diff at all (no sheet shown for block times alone).
    func backfillBlockTimes(_ result: FlightReconciliation.Result) {
        guard result.backfillsBlockOff || result.backfillsBlockOn,
              let index = flights.firstIndex(where: { $0.id == result.flightId }) else { return }
        var flight = flights[index]
        FlightReconciliation.backfillBlockTimes(result, to: &flight)
        flight.modifiedAt = Date()
        flights[index] = flight
        _ = saveFlight(flight)
        AppLog.flightEvents.debugLine("Block times back-filled from track for flight \(result.flightId)")
    }

    /// Apply the detector's end-of-flight flush: a landing that was in progress when
    /// recording stopped (rollout with touchdown evidence, stillness dwell never
    /// completed). Called from LocationManager.stopTracking() BEFORE endFlight() snapshots
    /// the timing fields. Skipped when the pilot already recorded a landing near the
    /// touchdown — the flush recovers *missed* landings, it never double-counts.
    func applyEndOfFlightLanding(_ event: DetectedFlightEvent) {
        guard currentFlight != nil else { return }
        let dedupeWindow: TimeInterval = 180
        let landingTimes = (currentFlight?.fullStopTimes ?? []) + (currentFlight?.touchAndGoTimes ?? [])
        if landingTimes.contains(where: { abs($0.timeIntervalSince(event.timestamp)) < dedupeWindow }) {
            AppLog.flightEvents.debugLine("End-of-flight flush skipped (landing already recorded near \(event.timestamp))")
            return
        }
        currentFlight?.fullStopCount += 1
        currentFlight?.fullStopTimes.append(event.timestamp)
        if landingTime == nil || landingTime! < event.timestamp {
            landingTime = event.timestamp
            currentFlight?.landingTime = event.timestamp
        }
        hasLandingBeenDetected = true
        AppLog.flightEvents.debugLine("End-of-flight flush: recorded full stop at \(event.timestamp)")
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
                // Plane has stopped — record landing time (the detector's confirmed full
                // stop carries the real touchdown time and supersedes this fallback)
                landingTime = clampedToLineUp(Date())
                currentFlight?.landingTime = landingTime
                hasLandingBeenDetected = true
            }
        } else {
            consecutiveLowSpeedReadings = 0
        }
    }

    /// Check for block off time (first sustained movement after ENGINE START).
    /// EASA FCL.010: "first moves for the purpose of taking off" — so when the 2-reading
    /// movement filter confirms, the stamp is BACKDATED to the first moving fix of the
    /// run, not "now" (+7 s median late before, measured over 34 corpus flights).
    private func checkForBlockOff(point: GPSPoint, airportDataService: AirportDataService?) {
        if point.speed >= blockOffSpeedThreshold {
            if movementRunStart == nil {
                movementRunStart = (point.timestamp, point.latitude, point.longitude)
            }
            consecutiveMovingReadings += 1
            if consecutiveMovingReadings >= requiredMovingReadings, let start = movementRunStart {
                currentFlight?.blockOffTime = start.time
                currentFlight?.blockOffLatitude = start.latitude
                currentFlight?.blockOffLongitude = start.longitude

                // The aerodrome it left from
                if let ident = airportDataService?.aerodromeIdent(at: point.coordinate) {
                    currentFlight?.departureAirportIdent = ident
                    AppLog.general.debugLine("Block off detected at \(ident)")
                }
                AppLog.general.debugLine("Block off time recorded (backdated to first moving fix): \(start.time)")
            }
        } else {
            consecutiveMovingReadings = 0
            movementRunStart = nil
        }
    }

    /// Check for block on time (final coming-to-rest before ENGINE STOP).
    /// EASA FCL.010: "finally comes to rest" — block on is the START of the stillness run
    /// that lasts until shutdown, not the last still moment before engine stop. The old
    /// implementation overwrote it with "now" on every stationary sample (+55 s median /
    /// +159 s worst late ≈ +1 min of logged block time per flight). A new stillness run
    /// after more taxiing supersedes the previous candidate; a single noisy "moving"
    /// sample does not break a run (two consecutive moving samples do — mirrors the
    /// validated track-derived rule, −0.1 min median vs the club's entries).
    /// CLLocation speed of -1 (indeterminate) is treated as stopped since it typically
    /// occurs when the device is stationary.
    private func checkForBlockOn(point: GPSPoint, airportDataService: AirportDataService?) {
        if point.speed < 0 || point.speed < blockOnSpeedThreshold {
            movingWhileParkedRun = 0
            if stillnessRunStart == nil {
                stillnessRunStart = (point.timestamp, point.latitude, point.longitude)
                stillnessRunReadings = 0
            }
            stillnessRunReadings += 1

            if stillnessRunReadings >= requiredStoppedInWindow, let start = stillnessRunStart,
               currentFlight?.blockOnTime != start.time {
                currentFlight?.blockOnTime = start.time
                currentFlight?.blockOnLatitude = start.latitude
                currentFlight?.blockOnLongitude = start.longitude
                AppLog.general.debugLine("Block on candidate (start of stillness run): \(start.time)")

                // The aerodrome it stopped at (only if changed or not set). Two slow fixes are often
                // more than the 5 m distance filter lets through before shutdown; END FLIGHT then
                // finds the arrival from the measured block on (`settleAerodromesAtEndOfFlight`).
                if let ident = airportDataService?.aerodromeIdent(at: point.coordinate),
                   currentFlight?.arrivalAirportIdent != ident {
                    currentFlight?.arrivalAirportIdent = ident
                    AppLog.general.debugLine("Block on location updated: \(ident)")
                }
            }
        } else {
            // Moving — but require two consecutive moving samples before discarding the
            // run, so one noisy parked sample can't restart the block-on clock.
            movingWhileParkedRun += 1
            if movingWhileParkedRun >= 2 {
                stillnessRunStart = nil
                stillnessRunReadings = 0
            }
        }
    }
    
    // MARK: - Navigation
    
    func nextPhase() {
        guard let currentIndex = ChecklistPhase.allCases.firstIndex(of: currentPhase),
              currentIndex + 1 < ChecklistPhase.allCases.count else { return }

        // Every NEXT goes through here: out of the check before departure, it is READY FOR LINE UP.
        recordReadyForLineUp()
        leaveCurrentPhase()

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
            enterPhase(ChecklistPhase.allCases[nextIndex])
        }
    }

    /// Leaving the current phase, by NEXT or by a forward jump on the phase bar: its status, and its
    /// unchecked items onto the deferred list. The two used to differ, and a jump dropped the open
    /// items on the floor: not checked, not deferred, never listed again. (v6.0 review, B1)
    private func leaveCurrentPhase() {
        // The landing check answered on the landed card is settled: nothing it had is reopened or
        // deferred on the way to AFTER LANDING. (6.1)
        if let answered = phaseCompletionStatus[currentPhase], answered.isAnsweredAfterLanding {
            if currentPhase.rawValue >= highestCompletedPhase.rawValue { highestCompletedPhase = currentPhase }
            return
        }
        // Advancing from the current phase: .missingAction if a required button wasn't pressed; else
        // .completed ONLY if the checklist was actually worked through (all step-by-step items reached),
        // otherwise .skipped. Since NEXT is tappable while a phase is still incomplete, pressing past an
        // un-worked phase must read as skipped (orange), not done (green). (round 6 regression fix)
        // Counted over the items on screen (hidden items included once revealed), like the NEXT button
        // and the deferred list, so an orange phase always has its unchecked items listed. (v6.0 · B2)
        let checklistWorkedThrough = !settings.stepByStepHighlighting
            || areAllItemsCompleted(learningMode: effectiveLearningMode)
        // Whatever is left unchecked follows the pilot as deferred items until checked (v6.0 · B2),
        // together with what was deferred inside the phase with DEFER (v6.0 · P2), in list order.
        let open = openItems(in: currentPhase).map(\.id)
        let deferredHere = deferredItems[currentPhase] ?? []
        if !open.isEmpty {
            let order = activeChecklist.visibleItems(for: currentPhase, learningMode: true).map(\.id)
            let all = Set(deferredHere).union(open)
            deferredItems[currentPhase] = order.filter(all.contains)
        }
        let leftSomethingDeferred = !(deferredItems[currentPhase] ?? []).isEmpty
        let actionMissing = currentPhase.hasMissingRequiredAction(
            engineStarted: engineStartTime != nil,
            engineShutDown: engineShutdownTime != nil)
        if isMemoryCheck(currentPhase) {
            // A memory check, its items hidden: done once confirmed (6.1). Left unconfirmed, it is owed
            // whole, never grey: the Cockpit listed it for review before this.
            if !memoryCheckIsDone(currentPhase) {
                deferWhole(currentPhase)
            } else if actionMissing {
                phaseCompletionStatus[currentPhase] = .missingAction
            } else if leftSomethingDeferred {
                phaseCompletionStatus[currentPhase] = .skipped
            } else if phaseCompletionStatus[currentPhase] != .completed {
                // Worked through with its items revealed, then flown again hidden: stays `.completed`.
                phaseCompletionStatus[currentPhase] = .doneFromMemory
            }
        } else if actionMissing {
            phaseCompletionStatus[currentPhase] = .missingAction
        } else if currentPhaseHasNoVisibleItems(learningMode: effectiveLearningMode) {
            // SEC-C36: nothing was displayed, so nothing was worked through. Report that honestly
            // instead of inheriting `.completed` from the 0 >= 0 comparison. Since 6.1 that is a phase
            // with no items at all (or a checklist not loaded): a memory check is handled above.
            phaseCompletionStatus[currentPhase] = .empty
        } else {
            // Every item reached, but one of them deferred: not done yet. It turns green once the last
            // deferred item is checked (`checkDeferredItem`). A memory check whose items were revealed
            // and worked through is a check like any other, green. Confirmed from memory, then revealed
            // (every item then shows ticked), it keeps what it was.
            let confirmed = phaseCompletionStatus[currentPhase] == .doneFromMemory
            phaseCompletionStatus[currentPhase] = checklistWorkedThrough && !leftSomethingDeferred
                ? (confirmed ? .doneFromMemory : .completed) : .skipped
            // Left with items open: skipped explicitly (NEXT's review, or a jump). (6.1)
            if phaseCompletionStatus[currentPhase] == .skipped {
                recordSkipped(currentPhase)
                settleOwedCheck(currentPhase, done: false)
            }
        }
        
        // Update highest completed phase
        if currentPhase.rawValue >= highestCompletedPhase.rawValue {
            highestCompletedPhase = currentPhase
        }
    }

    /// Arriving in a phase. What is still open on its list, from the highlight down, is open again
    /// on screen, so it leaves the deferred list; a deferred check is simply run in place.
    /// Without this, coming back to a phase left with items open had them listed twice, and a CHECK
    /// on the list drew them as deferred rather than done: an accidental jump then cost the pilot
    /// every item a second time, in the deferred list. (v6.0 review, B1)
    private func enterPhase(_ phase: ChecklistPhase) {
        currentPhase = phase
        // A deferred check you go back to is run where it stands, as the current phase.
        deferredChecks.removeAll { $0 == phase }
        guard settings.stepByStepHighlighting, let ids = deferredItems[phase] else { return }
        let checked = currentHighlightedItem[phase] ?? 0
        let reopened = Set(activeChecklist.visibleItems(for: phase, learningMode: effectiveLearningMode)
            .dropFirst(checked).map(\.id))
        let kept = ids.filter { !reopened.contains($0) }
        deferredItems[phase] = kept.isEmpty ? nil : kept
    }

    func previousPhase() {
        // The previous-navigable rule (with circuit-mode skipping) lives on ChecklistPhase.
        if let target = currentPhase.previousNavigable(circuitMode: isCircuitMode) {
            enterPhase(target)
        }
    }

    /// A jump on the phase bar or the phase list. Forward, the phase left goes the way NEXT takes it
    /// (its open items deferred one by one) unless nothing in it was ticked, in which case it is a
    /// whole check like the phases passed over; those are deferred whole, or marked done, as
    /// `skipped` says. The Cockpit asks which above the threshold (`jumpNeedsQuestion`); below it,
    /// they are deferred. (v6.0 review, B1 and J1-J3)
    func goToPhase(_ phase: ChecklistPhase, skipped: SkippedChecks = .deferred) {
        // In circuit mode, don't allow navigation to CRUISE or DESCENT
        if phase.isSkippedInCircuitMode(isCircuitMode) {
            return
        }

        if let currentIndex = ChecklistPhase.allCases.firstIndex(of: currentPhase),
           let targetIndex = ChecklistPhase.allCases.firstIndex(of: phase),
           targetIndex > currentIndex {
            if settings.stepByStepHighlighting {
                let passed = checksPassed(jumpingTo: phase)
                if checkIsUntouched(currentPhase) {
                    conclude(passedCheck: currentPhase, as: skipped)
                    if currentPhase.rawValue >= highestCompletedPhase.rawValue { highestCompletedPhase = currentPhase }
                } else {
                    leaveCurrentPhase()
                }
                for check in passed { conclude(passedCheck: check, as: skipped) }
            } else {
                // Nothing is tracked without step-by-step: the phase left and the phases passed only
                // get their colour.
                leaveCurrentPhase()
            }
            // Whatever the jump passed and didn't conclude (cruise and descent in circuit mode, a
            // phase already worked through): the colour it had, or skipped / missing action.
            for i in (currentIndex + 1)..<targetIndex {
                let skippedPhase = ChecklistPhase.allCases[i]
                if phaseCompletionStatus[skippedPhase] == nil {
                    phaseCompletionStatus[skippedPhase] = skippedPhase.hasMissingRequiredAction(
                        engineStarted: engineStartTime != nil,
                        engineShutDown: engineShutdownTime != nil) ? .missingAction : .skipped
                }
            }
        }
        enterPhase(phase)
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

        // Recorded before the file goes: the other store's copy stays deleted too. (6.1)
        persistence.recordDeletion(.flight, id: flight.id, stamp: flight.modifiedAt)
        // Delete the individual flight file from iCloud
        persistence.deleteFlight(flight)

        // Sync deletion to iCloud (CloudKit). With the switch off, the record above stands for it:
        // CloudKit is owed the delete when it comes up (`SyncManager.queueWhatCloudKitLacks`).
        if settings.iCloudSyncEnabled {
            syncManager?.deleteFlight(flight.id)
        }
    }

    func deleteFlight(at indexSet: IndexSet) {
        // Get flights before removal for file cleanup and sync
        let flightsToDelete = indexSet.map { flights[$0] }

        flights.remove(atOffsets: indexSet)

        // Delete individual flight files from iCloud, each recorded first (6.1)
        for flight in flightsToDelete {
            persistence.recordDeletion(.flight, id: flight.id, stamp: flight.modifiedAt)
            persistence.deleteFlight(flight)
        }

        // Sync deletions to iCloud (CloudKit)
        if settings.iCloudSyncEnabled {
            for flight in flightsToDelete {
                syncManager?.deleteFlight(flight.id)
            }
        }
    }
    
    func importFlight(from data: Data) -> Bool {
        importedFlight(from: data) != nil
    }

    /// Import one flight file into the logbook. Returns the flight and, for a GPX from another app
    /// that has no AeroCheck name for it, the file's own track name, which the Logbook offers the
    /// pilot when it asks for a name. (v6.1)
    @discardableResult
    func importedFlight(from data: Data) -> (flight: Flight, suggestedName: String?)? {
        // Try GPX first, then JSON
        var imported: (flight: Flight, suggestedName: String?)
        if let gpx = Flight.fromGPXWithSuggestedName(data) {
            imported = gpx
        } else if let flight = Flight.fromJSONOptional(data) {
            imported = (flight, nil)
        } else {
            return nil
        }
        // A JSON export keeps the flight's id and `modifiedAt`: the export of a deleted flight,
        // imported back, would be dead to its deletion record at the next load. An import is an edit,
        // so it is stamped as one, after the record. (6.1)
        if let mark = persistence.deletionMark(.flight, id: imported.flight.id) {
            imported.flight.modifiedAt = DeletionRecords.stamp(after: mark.deletedAt)
        }
        flights.insert(imported.flight, at: 0)
        saveFlights()
        return imported
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

    /// Record what a flight cost. Same single-flight persist as the other per-field edits. (v5.0.0)
    func updateFlightCost(_ flight: Flight, cost: FlightCostEntry?) {
        if let index = flights.firstIndex(where: { $0.id == flight.id }) {
            flights[index].costEntry = (cost?.isEmpty ?? true) ? nil : cost
            flights[index].touch()
            saveFlight(flights[index])
        }
    }

    /// Record the pilot's edits to the derived logbook line. (v5.0.0)
    func updateFlightLogbook(_ flight: Flight, overrides: LogbookOverrides?) {
        if let index = flights.firstIndex(where: { $0.id == flight.id }) {
            flights[index].logbook = (overrides?.isEmpty ?? true) ? nil : overrides
            flights[index].touch()
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
            syncManager?.syncAllFlights(flights)
        }
    }

    /// Save a single flight (for sync efficiency).
    /// Returns `true` only if the local file write was confirmed. (PR-14)
    @discardableResult
    func saveFlight(_ flight: Flight) -> Bool {
        // Save just this flight to its own file
        let saved = persistence.saveFlight(flight)

        if settings.iCloudSyncEnabled {
            syncManager?.syncFlight(flight, allFlights: flights)
        }
        return saved
    }

    /// Reload flights from disk after `saveSettings()` moves the datastore between the local and the
    /// iCloud Drive store (the move can bring in flights). Decode runs off the main actor. (PR-24)
    func reloadFlights() {
        flightsLoad = Task { [weak self] in
            guard let self = self else { return }
            await Task.yield()
            self.flights = await self.persistence.loadFlightsOffMain()
        }
    }

    func saveSettings() {
        // The switch covers the iCloud Drive store too: move the datastore first, so the settings
        // land in the store they now belong to. A move brings in what the other store adds.
        if persistence.setUsesICloudDrive(settings.iCloudSyncEnabled) {
            reloadFlights()
        }

        // Save to file-based storage
        persistence.saveSettings(settings)

        // Update sync manager with current sync preference. Turning it on starts CloudKit now, and
        // once it is up, the flights recorded while it was off and these settings go out.
        syncManager?.isSyncEnabled = settings.iCloudSyncEnabled

        // Sync settings to iCloud if enabled
        if settings.iCloudSyncEnabled {
            syncManager?.syncSettings(settings)
        }

        syncAircraftType()
    }

    // MARK: - Onboarding gate

    /// Device-local key backing `hasSeenOnboarding` (see that property).
    private let hasSeenOnboardingKey = "hasSeenOnboarding"

    /// Device-local key backing `acceptedDisclaimerVersion` (see that property).
    private let acceptedDisclaimerVersionKey = "acceptedDisclaimerVersion"

    /// Current revision of the safety notice. **Bump this when the notice changes materially** — a
    /// new limitation, a new data source with its own caveat, a reworded responsibility clause — and
    /// every device is asked to acknowledge the new text once. Do NOT bump it for a typo or a layout
    /// change: re-prompting for nothing is how a gate becomes something people tap through.
    static let currentDisclaimerVersion = 1

    /// True until this device has acknowledged the current safety notice. Drives the gate in
    /// `ContentView`, ahead of onboarding.
    var needsDisclaimerAcceptance: Bool {
        acceptedDisclaimerVersion < AppState.currentDisclaimerVersion
    }

    /// Record acknowledgement of the current safety notice on THIS device.
    func acceptDisclaimer() {
        acceptedDisclaimerVersion = AppState.currentDisclaimerVersion
        defaults.set(acceptedDisclaimerVersion, forKey: acceptedDisclaimerVersionKey)
        AppLog.general.info("Safety notice v\(AppState.currentDisclaimerVersion) acknowledged")
    }

    /// Mark onboarding finished on THIS device (the gate) and record completion in the synced settings.
    /// Always persists — onboarding (incl. a replay from Settings) can change the feature toggles.
    func completeOnboarding() {
        hasSeenOnboarding = true
        defaults.set(true, forKey: hasSeenOnboardingKey)
        settings.hasCompletedOnboarding = true
        saveSettings()
    }

    /// Re-show onboarding from Settings. Device-local — replaying it here doesn't reset other devices.
    func replayOnboarding() {
        hasSeenOnboarding = false
        defaults.set(false, forKey: hasSeenOnboardingKey)
    }

    private func loadSettings() {
        if let loadedSettings = persistence.loadSettings() {
            // SEC-C25: settings.json lives in the same user-visible iCloud Drive container as
            // Flights/ and NavigationPlans/, so it is exactly as untrusted as a synced record.
            // SyncManager.settingsFromRecord already clamps; this sibling path did not, leaving
            // the numeric ranges (e.g. gpsRecordingInterval) unguarded on the file route.
            settings = loadedSettings.clampedForIngest().migratedLocally()
            if settings.schemaVersion != loadedSettings.schemaVersion { persistence.saveSettings(settings) }
        }
        reconcileSyncSwitch()

        // Update sync manager with the switch
        syncManager?.isSyncEnabled = settings.iCloudSyncEnabled
    }

    /// "Sync to iCloud" decides where this device keeps its data, so it is the device's own: the
    /// datastore reads it before settings.json can be found, since that file lives in the store
    /// the switch picks. A value in the file, or from another device, does not override it.
    ///
    /// A device with no stored choice yet (a fresh install) takes the value it just loaded, and a
    /// file saying off then moves the datastore to local, as the switch would.
    private func reconcileSyncSwitch() {
        if persistence.hasStoredSyncPreference {
            settings.iCloudSyncEnabled = persistence.usesICloudDrive
        } else {
            persistence.setUsesICloudDrive(settings.iCloudSyncEnabled)
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
        // Piggyback the Live Activity refresh on the checkpoint cadence: sync() diffs the content
        // state and no-ops when nothing changed, so this is cheap per GPS tick and catches every
        // phase/timing/landing change promptly. (UX-25)
        liveActivity?.sync(from: self)
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
        // PERF-29: the snapshot no longer carries the GPS track — per-checkpoint work was
        // O(whole track) every ~30 s (quadratic over a flight). The snapshot is now a slim,
        // constant-size metadata write, and only the points recorded since the last confirmed
        // append go to the NDJSON delta file.
        var slimFlight = flight
        let track = flight.gpsTrack
        let alreadyWritten = min(deltaPointsWritten, track.count)
        let newPoints = Array(track[alreadyWritten...])
        slimFlight.gpsTrack = []
        let state = ActiveFlightState(flight: slimFlight, from: self)
        let url = persistence.activeFlightStateURL
        let deltaURL = persistence.activeFlightTrackDeltaURL
        let savedAt = state.savedAt
        let pointerKey = activeFlightPointerKey
        // UserDefaults is documented as thread-safe, but the SDK doesn't mark it Sendable. The
        // injected instance (tests use their own) is written once, off the main actor, below.
        nonisolated(unsafe) let defaults = self.defaults
        let writtenThrough = alreadyWritten + newPoints.count

        let write: @Sendable () -> Void = { [weak self] in
            do {
                try DataPersistenceManager.appendActiveFlightTrackPoints(newPoints, to: deltaURL)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(state)
                try DataPersistenceManager.writeActiveFlightStateData(data, to: url)
                defaults.set(savedAt, forKey: pointerKey)
                // Confirm the append on the main actor. If a newer checkpoint already ran (stale
                // watermark), max() keeps the furthest confirmed position; the few re-appended
                // points are deduped by id on restore.
                Task { @MainActor in
                    guard let self else { return }
                    self.deltaPointsWritten = max(self.deltaPointsWritten, writtenThrough)
                }
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
            // v3 = slim snapshot + NDJSON track delta; v2 = legacy full-track snapshot (PERF-29).
            let supportedVersions = [ActiveFlightState.currentSchemaVersion,
                                     ActiveFlightState.legacyFullTrackSchemaVersion]
            guard supportedVersions.contains(state.schemaVersion) else {
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

            // RES-12: endFlight() writes the flight file and only then clears this checkpoint, with
            // no suspension point between the two — but a process kill in that window leaves a
            // checkpoint describing a flight that was already durably saved. Restoring it would put
            // the app back "in flight" on a completed flight and, on the next endFlight(), write a
            // second file under a fresh id: one flight, logged twice. If the flight is already on
            // disk the checkpoint has done its job and is simply stale.
            if persistence.flightFileExists(for: state.flight) {
                AppLog.general.debugLine("Discarding stale checkpoint: flight \(state.flight.id) is already saved")
                clearActiveFlightState()
                return false
            }

            state.restore(to: self)
            if state.schemaVersion == ActiveFlightState.currentSchemaVersion {
                // Rehydrate the track from the append-only delta. Duplicate lines (a re-appended
                // tail after an unconfirmed write) are deduped by point id, preserving order.
                let raw = DataPersistenceManager.readActiveFlightTrackDelta(at: persistence.activeFlightTrackDeltaURL)
                var seenIds = Set<UUID>()
                var points: [GPSPoint] = []
                for point in raw where seenIds.insert(point.id).inserted {
                    points.append(point)
                }
                currentFlight?.gpsTrack = state.flight.gpsTrack + points
                deltaPointsWritten = points.count
            } else {
                // Legacy full-track snapshot: the track came inline; any stale delta file belongs
                // to an older session. Start the delta fresh on the next checkpoint.
                try? FileManager.default.removeItem(at: persistence.activeFlightTrackDeltaURL)
                deltaPointsWritten = 0
            }
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
        // Flush the checkpoint queue FIRST: `persistActiveFlightState` writes asynchronously
        // (PR-12), so a checkpoint queued moments before this clear (e.g. the forced write on
        // block-off detection, seconds before the pilot abandons the flight) would otherwise
        // land AFTER the delete and resurrect the checkpoint — and a resurrected checkpoint
        // for a CANCELLED flight is restored on next launch as a phantom "Flight Restored"
        // (the RES-12 already-saved guard only covers flights that reached endFlight()).
        // The serial queue makes this a strict barrier; the write closure never blocks back
        // on the main actor, so a main-actor sync here cannot deadlock. Cost is at most one
        // slim (PERF-29) metadata encode + write, on flight-end paths only.
        flushPendingCheckpoint()
        persistence.clearActiveFlightStateFile()
        defaults.removeObject(forKey: activeFlightPointerKey)
        defaults.removeObject(forKey: legacyActiveFlightStateKey)
        pointsSinceCheckpoint = 0
        lastCheckpointAt = nil
        deltaPointsWritten = 0
        // Every flight-end path funnels through here — retire the Live Activity with it. (UX-25)
        if !isFlightActive { liveActivity?.end() }
    }
}

// MARK: - Computed Properties Extension

extension AppState {
    var isLastPhase: Bool {
        currentPhase == .hangar
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

/// See `AppState.pendingFlightStart`.
struct PendingFlightStart: Equatable {
    let threadId: UUID
    let circuits: Bool
}
