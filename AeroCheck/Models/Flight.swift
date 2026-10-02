import Foundation
import CoreLocation

/// Current export format version
/// - v1: Original format (no fullStopCount, fullStopTimes, flightPlanId, flightPlan)
/// - v2: Added fullStopCount, fullStopTimes, flightPlanId, flightPlan, export metadata
/// - v3: Added block times, departure/arrival airports
/// - v4: Added engine hour meter readings
let currentExportFormatVersion = 4

/// Hard limits for data ingested from untrusted sources (CloudKit records, GPX/JSON import).
/// Shared so the CloudKit ingest cap (SEC-17) and the import caps (SEC-13) never diverge.
enum FlightDataLimits {
    /// Max GPS points in a single flight. A multi-hour flight at 1 Hz is ~tens of thousands, well
    /// under this; exceeding it indicates a corrupt or malicious record.
    static let maxGPSPoints = 100_000
    /// Max waypoints in an imported route.
    static let maxRouteWaypoints = 500
    /// A leg's or a route's time in seconds: at most what `calculateRouteData` can compute from
    /// bounded inputs (every leg of the longest route at the longest distance and the lowest planned
    /// airspeed, plus the two allowances at their longest: 6 and 15 minutes since they are learned,
    /// 6.1). Absurd as a plan, and still far inside `Int` for the minute and hour formatters. (S9-07)
    static let routeTimeSeconds: ClosedRange<Double> =
        0...(Double(maxRouteWaypoints) * PlausibleRange.legDistanceNM.upperBound
             / PlausibleRange.plannedAirspeedKnots.lowerBound * 3600
             + (EETCalibration.departureMinutes.upperBound + EETCalibration.arrivalMinutes.upperBound) * 60)

    // MARK: - ZIP import budgets (SA-24)
    //
    // `extractZipEntries` read the declared `uncompressedSize` and passed it to `decompress`,
    // which ignored the parameter entirely — no per-entry cap, no running total, no entry-count
    // bound. A "flight archive" ZIP received from a club-mate (AirDrop, e-mail, Files) could
    // expand a small deflate stream to several GB in memory and get the app OOM-killed; done
    // mid-flight, that interrupts the flight (the crash-recovery checkpoint limits the damage,
    // but the app dies).

    /// Max decompressed bytes for a single entry. A 100k-point flight JSON is a few MB.
    static let maxImportEntryBytes = 32 * 1024 * 1024
    /// Max decompressed bytes across the whole archive.
    static let maxImportTotalBytes = 128 * 1024 * 1024
    /// Max entries processed from one archive.
    static let maxImportEntries = 500

    /// How far into the future an ingested `modifiedAt` may sit before the record is rejected.
    /// Generous enough to absorb ordinary clock drift and timezone confusion between devices,
    /// tight enough that a poisoned timestamp cannot win merges indefinitely. (SEC-C19)
    static let maxClockSkew: TimeInterval = 24 * 60 * 60

    // MARK: - Plausible per-flight values (S9-10, S9-16)
    //
    // A flight file or CloudKit record carries numbers the Logbook formats, sums and converts to
    // `Int`, and `Int(_:)` traps on anything past ±9.2e18. JSON cannot carry NaN or 1e400 (the
    // decoder refuses both), but 1e300 is a finite Double that passes every `isFinite` check: an
    // imported flight with that as its cached distance crashed the Logbook each time its row was
    // drawn, on every device it synced to. Outside these bounds a value is dropped, or clamped for
    // a count, on ingest and again on local load, which repairs a flight already stored that way.

    /// Distance of one recorded track in km. More than once round the Earth is not a flight.
    static let trackDistanceKm: ClosedRange<Double> = 0...50_000
    /// Length of one flight record in seconds. A flight left running over a long weekend still fits.
    static let recordDurationSeconds: ClosedRange<Double> = 0...(30 * 24 * 3600)
    /// Landings (or go-arounds) of one kind on one flight.
    static let maxLandingsPerFlight = 1_000
    /// Minutes the pilot logs against one flight (night, IFR). A week.
    static let maxLoggedMinutesPerFlight = 7 * 24 * 60
}

/// Pure flight-clock formatting, extracted from `AppState` so the timer/time-of-day rules are
/// unit-testable and de-duplicated. `AppState` keeps the timestamps and delegates formatting.
/// (Phase 4 — AppState decomposition)
enum FlightClock {
    /// Elapsed flight time as `HH:MM:SS` (negative intervals — clock skew — clamp to zero rather
    /// than rendering "-1:-1:..").
    static func formattedDuration(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// A timestamp as a short time-of-day string, with a `" (UTC)"` suffix when the pilot has
    /// forced UTC. The locale/time format itself is left to `DateFormatter`.
    static func formattedTimeOfDay(_ date: Date, useUTC: Bool) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        if useUTC {
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.string(from: date) + " (UTC)"
        }
        return formatter.string(from: date)
    }
}

// MARK: - The flight's "now"

extension FlightClock {
    /// Now, for everything a flight times: the track and its fixes' age, the detector and its cues, the
    /// check slot, FREDA, the landed card, the leg timer, the times over and the logbook's times. A
    /// Release build reads the wall clock, always. A DEBUG ground replay (`GroundReplay`) runs it faster,
    /// so a recorded flight replays on the simulator in minutes with all of those on one clock.
    static var now: Date {
        #if DEBUG
        if let virtual { return virtual.now }
        #endif
        return Date()
    }

    /// The pilot's seconds since `date`, a time on this clock: what an undo toast's six seconds are
    /// counted in, whatever pace a replay runs the flight at. Release: `Date().timeIntervalSince(date)`.
    static func pilotSeconds(since date: Date) -> TimeInterval {
        #if DEBUG
        if let virtual { return virtual.now.timeIntervalSince(date) / max(virtual.rate, 1) }
        #endif
        return Date().timeIntervalSince(date)
    }

    #if DEBUG
    /// DEV-ONLY: a clock that runs `rate` times faster than the wall clock from its anchor (a test may
    /// stop it with 0).
    struct Virtual: Equatable {
        /// The wall clock and the virtual one at the same instant.
        let wallAnchor: Date
        let virtualAnchor: Date
        let rate: Double

        var now: Date { virtual(at: Date()) }

        func virtual(at wall: Date) -> Date {
            virtualAnchor.addingTimeInterval(wall.timeIntervalSince(wallAnchor) * rate)
        }
    }

    /// DEV-ONLY: the replay's clock, nil for the wall clock.
    nonisolated(unsafe) static var virtual: Virtual? = nil
    #endif
}

/// The live flight's timing milestones, grouped as one cohesive value extracted from AppState's
/// four formerly-loose @Published timestamps. Distinct from `Flight`'s own (persisted) timing
/// fields of the same names — this is the in-progress session state. AppState owns it via a single
/// `@Published var flightTiming` and exposes thin forwarding accessors for backward compatibility.
/// (Phase 4 — AppState decomposition: state extraction)
struct FlightTiming: Equatable {
    var engineStartTime: Date?
    var lineUpTime: Date?
    var landingTime: Date?
    var engineShutdownTime: Date?
}

/// Represents a recorded flight with all tracking data
struct Flight: Identifiable, Codable {
    let id: UUID
    var name: String // Custom flight name
    var airplane: String // Aircraft ID (e.g., "pa28-181", "wt9-dynamic")
    var aircraftRegistration: String? // Aircraft tail number (e.g., "HB-PFA", "F-HVXA")
    var aircraftType: String? // Aircraft type identifier (e.g., "WT9", "PA28")
    var checklistVersion: String? // Checklist version used (e.g., "2.1e")
    var flightPlanId: UUID? // Associated flight plan ID (if using navigation planning)
    var flightPlan: FlightPlan? // Full flight plan data (saved with the flight)
    var startTime: Date?
    var stopTime: Date?
    var engineStartTime: Date?
    var lineUpTime: Date?
    var landingTime: Date?
    var engineShutdownTime: Date?

    // Block times and airport detection (v3)
    var blockOffTime: Date?           // First movement after ENGINE START
    var blockOffLatitude: Double?     // Latitude at block off
    var blockOffLongitude: Double?    // Longitude at block off
    var blockOnTime: Date?            // Final stop before ENGINE STOP
    var blockOnLatitude: Double?      // Latitude at block on
    var blockOnLongitude: Double?     // Longitude at block on
    var departureAirportIdent: String?  // Nearest airport ICAO code at block off
    var arrivalAirportIdent: String?    // Nearest airport ICAO code at block on

    // Engine hour meter readings (v4)
    var engineHourStart: Double?        // Tachometer/hour meter reading at engine start
    var engineHourEnd: Double?          // Tachometer/hour meter reading at engine stop
    var engineHourStartInputFormat: String?  // Raw input format used ("decimal" or "time")
    var engineHourEndInputFormat: String?    // Raw input format used ("decimal" or "time")

    var gpsTrack: [GPSPoint]
    var notes: String
    var goAroundCount: Int
    var touchAndGoCount: Int
    var fullStopCount: Int
    var goAroundTimes: [Date]
    var touchAndGoTimes: [Date]
    var fullStopTimes: [Date]

    // Sync / integrity (v5)
    /// Monotonic last-local-modification timestamp; the CloudKit conflict tiebreaker. (ARCH-02)
    var modifiedAt: Date
    /// Record schema version, for forward-compatible CloudKit/import ingest validation. (SEC-17)
    var schemaVersion: Int

    // Precomputed summary stats (v5) — computed once at save so the flight-log list never
    // recomputes an O(n) distance per row on every re-render. Optional + backward-compatible:
    // legacy records fall back to a lightweight on-demand computation. (PERF-22)
    var cachedDistanceKm: Double?
    var cachedMaxAltitudeMeters: Double?
    var cachedDurationSeconds: Double?

    /// User-pinned flag. Favorited flights sort to the top of the logbook and show a gold star.
    /// Optional + backward-compatible: legacy records decode to `false`. Toggling bumps `modifiedAt`
    /// so it rides the CloudKit conflict tiebreaker like any other scalar edit. (v4 UI/UX Revamp favorites)
    var isFavorite: Bool

    /// What this flight cost: the aircraft's billed hours at the rate the pilot recorded, plus what
    /// they paid on the ground. Optional and additive — a flight with nothing recorded decodes to
    /// nil and is counted as "no cost recorded" rather than as a free flight. (v5.0.0)
    var costEntry: FlightCostEntry?

    /// The pilot's edits to the derived EASA logbook line (function time, night, remarks). Absent
    /// means "use what the flight says", so the line stays correct after a reconciliation. (v5.0.0)
    var logbook: LogbookOverrides?

    /// Each FREDA of the cruise, done or missed, for the debrief (6.1). Nil on a flight that never had
    /// one (every flight before 6.1). Append-only once recorded, like the landings, so `merge` keeps the
    /// longer list and a copy stripped by an older build can't erase it: no schema bump needed.
    var fredaChecks: [FredaCheck]?

    /// The checks that weren't simply done in time, for the debrief (6.1, cues from the flight): owed (the
    /// flight moved past them open), skipped explicitly, done late, and the landing check answered on the
    /// landed card. Nil on a flight with none. Append-only, like the FREDAs: `merge` keeps the longer list,
    /// so no schema bump is needed.
    var checkRecords: [CheckRecord]?

    /// The phase bar as the flight ended, one status per check, for the debrief (6.1): what lets the Flight
    /// Log say "All checks done", tell done from done from memory or nothing to do, and tell a 6.1 flight
    /// with nothing to report from one recorded before. Nil on a flight recorded before it was kept. Written
    /// once, at END FLIGHT, so `merge` keeps whichever side has it; no schema bump is needed.
    var checkOutcomes: [CheckOutcome]?

    /// Current flight record schema version. Records claiming a higher version come from a newer
    /// app build and are rejected on ingest rather than mis-applied.
    /// Bumped to 2 in v5.0.0 for `costEntry` and `logbook`. Left at 1, a v5 flight was
    /// indistinguishable from a v4.4 one: an older device accepted it (`schemaVersion <= 1`),
    /// dropped the two unknown keys on decode, and the first `touch()` there made its stripped copy
    /// win `merge` — erasing the cost entry and logbook overrides on every device, permanently and
    /// with no visible cue. That rejection is exactly what this constant is for. (review F7)
    static let currentSchemaVersion = 2

    // MARK: - Coding Keys

    enum CodingKeys: String, CodingKey {
        case id, name, airplane, aircraftRegistration, aircraftType, checklistVersion
        case flightPlanId, flightPlan
        case startTime, stopTime, engineStartTime, lineUpTime, landingTime, engineShutdownTime
        case blockOffTime, blockOffLatitude, blockOffLongitude
        case blockOnTime, blockOnLatitude, blockOnLongitude
        case departureAirportIdent, arrivalAirportIdent
        case engineHourStart, engineHourEnd, engineHourStartInputFormat, engineHourEndInputFormat
        case gpsTrack, notes
        case goAroundCount, touchAndGoCount, fullStopCount
        case goAroundTimes, touchAndGoTimes, fullStopTimes
        case modifiedAt, schemaVersion
        case cachedDistanceKm, cachedMaxAltitudeMeters, cachedDurationSeconds
        case isFavorite
        case costEntry, logbook
        case fredaChecks
        case checkRecords
        case checkOutcomes
    }

    // MARK: - Custom Decodable for backward compatibility

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        airplane = try container.decode(String.self, forKey: .airplane)
        aircraftRegistration = try container.decodeIfPresent(String.self, forKey: .aircraftRegistration)
        aircraftType = try container.decodeIfPresent(String.self, forKey: .aircraftType)
        checklistVersion = try container.decodeIfPresent(String.self, forKey: .checklistVersion)

        // New fields in v2 - provide defaults for backward compatibility
        flightPlanId = try container.decodeIfPresent(UUID.self, forKey: .flightPlanId)
        flightPlan = try container.decodeIfPresent(FlightPlan.self, forKey: .flightPlan)

        startTime = try container.decodeIfPresent(Date.self, forKey: .startTime)
        stopTime = try container.decodeIfPresent(Date.self, forKey: .stopTime)
        engineStartTime = try container.decodeIfPresent(Date.self, forKey: .engineStartTime)
        lineUpTime = try container.decodeIfPresent(Date.self, forKey: .lineUpTime)
        landingTime = try container.decodeIfPresent(Date.self, forKey: .landingTime)
        engineShutdownTime = try container.decodeIfPresent(Date.self, forKey: .engineShutdownTime)

        // Block times and airport detection - new in v3, default to nil for backward compatibility
        blockOffTime = try container.decodeIfPresent(Date.self, forKey: .blockOffTime)
        blockOffLatitude = try container.decodeIfPresent(Double.self, forKey: .blockOffLatitude)
        blockOffLongitude = try container.decodeIfPresent(Double.self, forKey: .blockOffLongitude)
        blockOnTime = try container.decodeIfPresent(Date.self, forKey: .blockOnTime)
        blockOnLatitude = try container.decodeIfPresent(Double.self, forKey: .blockOnLatitude)
        blockOnLongitude = try container.decodeIfPresent(Double.self, forKey: .blockOnLongitude)
        departureAirportIdent = try container.decodeIfPresent(String.self, forKey: .departureAirportIdent)
        arrivalAirportIdent = try container.decodeIfPresent(String.self, forKey: .arrivalAirportIdent)

        // Engine hour meter readings - new in v4, default to nil for backward compatibility
        engineHourStart = try container.decodeIfPresent(Double.self, forKey: .engineHourStart)
        engineHourEnd = try container.decodeIfPresent(Double.self, forKey: .engineHourEnd)
        engineHourStartInputFormat = try container.decodeIfPresent(String.self, forKey: .engineHourStartInputFormat)
        engineHourEndInputFormat = try container.decodeIfPresent(String.self, forKey: .engineHourEndInputFormat)

        gpsTrack = try container.decodeIfPresent([GPSPoint].self, forKey: .gpsTrack) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""

        goAroundCount = try container.decodeIfPresent(Int.self, forKey: .goAroundCount) ?? 0
        touchAndGoCount = try container.decodeIfPresent(Int.self, forKey: .touchAndGoCount) ?? 0
        // New in v2 - default to 0 for backward compatibility
        fullStopCount = try container.decodeIfPresent(Int.self, forKey: .fullStopCount) ?? 0

        goAroundTimes = try container.decodeIfPresent([Date].self, forKey: .goAroundTimes) ?? []
        touchAndGoTimes = try container.decodeIfPresent([Date].self, forKey: .touchAndGoTimes) ?? []
        // New in v2 - default to empty for backward compatibility
        fullStopTimes = try container.decodeIfPresent([Date].self, forKey: .fullStopTimes) ?? []

        // New in v5 - legacy records default modifiedAt to their stop/start time (a reasonable
        // "last touched" proxy) and schema version 1.
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt)
            ?? stopTime ?? startTime ?? Date.distantPast
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1

        // v5 precomputed stats — nil for legacy records (computed lazily on demand).
        cachedDistanceKm = try container.decodeIfPresent(Double.self, forKey: .cachedDistanceKm)
        cachedMaxAltitudeMeters = try container.decodeIfPresent(Double.self, forKey: .cachedMaxAltitudeMeters)
        cachedDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .cachedDurationSeconds)

        // New in 3.3 — legacy records (and imports) default to not-favorited.
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false

        // New in v5.0.0 — nil on every existing record, which reads as "nothing recorded".
        costEntry = try container.decodeIfPresent(FlightCostEntry.self, forKey: .costEntry)
        logbook = try container.decodeIfPresent(LogbookOverrides.self, forKey: .logbook)

        // New in 6.1 — nil on every existing record.
        fredaChecks = try container.decodeIfPresent([FredaCheck].self, forKey: .fredaChecks)
        checkRecords = try container.decodeIfPresent([CheckRecord].self, forKey: .checkRecords)
        checkOutcomes = try container.decodeIfPresent([CheckOutcome].self, forKey: .checkOutcomes)
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        airplane: String = "wt9-dynamic",
        aircraftRegistration: String? = nil,
        aircraftType: String? = nil,
        checklistVersion: String? = nil,
        flightPlanId: UUID? = nil,
        flightPlan: FlightPlan? = nil,
        startTime: Date? = nil,
        stopTime: Date? = nil,
        engineStartTime: Date? = nil,
        lineUpTime: Date? = nil,
        landingTime: Date? = nil,
        engineShutdownTime: Date? = nil,
        blockOffTime: Date? = nil,
        blockOffLatitude: Double? = nil,
        blockOffLongitude: Double? = nil,
        blockOnTime: Date? = nil,
        blockOnLatitude: Double? = nil,
        blockOnLongitude: Double? = nil,
        departureAirportIdent: String? = nil,
        arrivalAirportIdent: String? = nil,
        engineHourStart: Double? = nil,
        engineHourEnd: Double? = nil,
        engineHourStartInputFormat: String? = nil,
        engineHourEndInputFormat: String? = nil,
        gpsTrack: [GPSPoint] = [],
        notes: String = "",
        goAroundCount: Int = 0,
        touchAndGoCount: Int = 0,
        fullStopCount: Int = 0,
        goAroundTimes: [Date] = [],
        touchAndGoTimes: [Date] = [],
        fullStopTimes: [Date] = [],
        modifiedAt: Date = Date(),
        schemaVersion: Int = Flight.currentSchemaVersion,
        cachedDistanceKm: Double? = nil,
        cachedMaxAltitudeMeters: Double? = nil,
        cachedDurationSeconds: Double? = nil,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.name = name
        self.airplane = airplane
        self.aircraftRegistration = aircraftRegistration
        self.aircraftType = aircraftType
        self.checklistVersion = checklistVersion
        self.flightPlanId = flightPlanId
        self.flightPlan = flightPlan
        self.startTime = startTime
        self.stopTime = stopTime
        self.engineStartTime = engineStartTime
        self.lineUpTime = lineUpTime
        self.landingTime = landingTime
        self.engineShutdownTime = engineShutdownTime
        self.blockOffTime = blockOffTime
        self.blockOffLatitude = blockOffLatitude
        self.blockOffLongitude = blockOffLongitude
        self.blockOnTime = blockOnTime
        self.blockOnLatitude = blockOnLatitude
        self.blockOnLongitude = blockOnLongitude
        self.departureAirportIdent = departureAirportIdent
        self.arrivalAirportIdent = arrivalAirportIdent
        self.engineHourStart = engineHourStart
        self.engineHourEnd = engineHourEnd
        self.engineHourStartInputFormat = engineHourStartInputFormat
        self.engineHourEndInputFormat = engineHourEndInputFormat
        self.gpsTrack = gpsTrack
        self.notes = notes
        self.goAroundCount = goAroundCount
        self.touchAndGoCount = touchAndGoCount
        self.fullStopCount = fullStopCount
        self.goAroundTimes = goAroundTimes
        self.touchAndGoTimes = touchAndGoTimes
        self.fullStopTimes = fullStopTimes
        self.modifiedAt = modifiedAt
        self.schemaVersion = schemaVersion
        self.cachedDistanceKm = cachedDistanceKm
        self.cachedMaxAltitudeMeters = cachedMaxAltitudeMeters
        self.cachedDurationSeconds = cachedDurationSeconds
        self.isFavorite = isFavorite
    }

    /// Stamp the flight as locally modified (drives the CloudKit conflict tiebreaker). (ARCH-02)
    mutating func touch() {
        modifiedAt = Date()
    }

    /// Conflict-merge two versions of the same flight. The newer `modifiedAt` wins for scalar
    /// metadata (name, notes, …), but append-only / monotonic data — the GPS track and landing
    /// counts/times — keeps the **richer** side, so a metadata edit on one device can never drop a
    /// longer track or a higher landing count recorded on the other. (ARCH-02)
    static func merge(_ a: Flight, _ b: Flight) -> Flight {
        var result = a.modifiedAt >= b.modifiedAt ? a : b
        result.gpsTrack = a.gpsTrack.count >= b.gpsTrack.count ? a.gpsTrack : b.gpsTrack
        result.goAroundCount = max(a.goAroundCount, b.goAroundCount)
        result.touchAndGoCount = max(a.touchAndGoCount, b.touchAndGoCount)
        result.fullStopCount = max(a.fullStopCount, b.fullStopCount)
        result.goAroundTimes = a.goAroundTimes.count >= b.goAroundTimes.count ? a.goAroundTimes : b.goAroundTimes
        result.touchAndGoTimes = a.touchAndGoTimes.count >= b.touchAndGoTimes.count ? a.touchAndGoTimes : b.touchAndGoTimes
        result.fullStopTimes = a.fullStopTimes.count >= b.fullStopTimes.count ? a.fullStopTimes : b.fullStopTimes
        result.fredaChecks = (a.fredaChecks?.count ?? 0) >= (b.fredaChecks?.count ?? 0) ? a.fredaChecks : b.fredaChecks
        result.checkRecords = (a.checkRecords?.count ?? 0) >= (b.checkRecords?.count ?? 0) ? a.checkRecords : b.checkRecords
        result.checkOutcomes = (a.checkOutcomes?.count ?? 0) >= (b.checkOutcomes?.count ?? 0) ? a.checkOutcomes : b.checkOutcomes
        result.modifiedAt = max(a.modifiedAt, b.modifiedAt)
        return result
    }

    /// Validate a flight decoded from an untrusted source (CloudKit ingest / file import) before it
    /// is applied to local state. Returns nil when the record is structurally unsafe — a newer
    /// (unknown) schema, an unbounded point count, or any non-finite/out-of-range coordinate — so a
    /// corrupt or divergent-schema record can never silently overwrite or persist. (SEC-17)
    ///
    /// An accepted record comes back with its numbers bounded (`withPlausibleValues()`). Those are
    /// dropped or clamped rather than rejected: rejecting would stop a legitimate old record from
    /// syncing over one bad value, the lesson of RES-02. (S9-10, S9-16)
    func validatedForIngest() -> Flight? {
        guard schemaVersion <= Flight.currentSchemaVersion else { return nil }
        guard gpsTrack.count <= FlightDataLimits.maxGPSPoints else { return nil }
        // SEC-C19: `merge` picks the greater `modifiedAt` for scalar fields, and `touch()` can only
        // ever set real wall-clock time — so a far-future timestamp (a device with a wrong clock,
        // no malice required) wins forever, and every later legitimate edit to that flight's
        // name/notes is silently discarded on every synced device. Reject implausible timestamps at
        // the boundary instead of letting one poison the merge history permanently.
        guard modifiedAt <= Date().addingTimeInterval(FlightDataLimits.maxClockSkew) else { return nil }
        for point in gpsTrack {
            guard point.latitude.isFinite, point.longitude.isFinite, point.altitude.isFinite,
                  (-90.0...90.0).contains(point.latitude),
                  (-180.0...180.0).contains(point.longitude) else {
                return nil
            }
        }
        return withPlausibleValues()
    }

    /// Salvage a flight decoded from the app's OWN local datastore, dropping bad GPS points rather
    /// than discarding the whole record. (RES-02)
    ///
    /// `validatedForIngest()` is an all-or-nothing gate, which is right for genuinely untrusted
    /// input — a CloudKit record or an imported file that fails validation should not be applied at
    /// all. It is the wrong policy for our own flight files: there, rejecting the record means a
    /// completed flight silently vanishes from the pilot's logbook with no error, no count
    /// discrepancy and no way to recover it, because `FlightLogView` renders solely from the
    /// in-memory array that `decodeFlights` populates.
    ///
    /// The asymmetry matters because a flight file is the ONLY copy of a recorded flight. Losing
    /// the whole logbook entry to salvage-able damage is strictly worse than showing a track with a
    /// few points missing — a pilot can see a small gap in a track; they cannot see an absent flight.
    ///
    /// Mirrors the write-side filter: drop individual invalid points, cap the track, and clamp a
    /// future `modifiedAt` instead of rejecting on it. The one genuinely uninterpretable case — a
    /// record written by a NEWER app build, whose fields this build cannot be trusted to understand
    /// — is still a hard reject, so a downgrade cannot silently rewrite newer data.
    func sanitizedForLocalLoad() -> Flight? {
        // A newer schema is the only unrecoverable case: we cannot know what we are dropping.
        guard schemaVersion <= Flight.currentSchemaVersion else { return nil }

        var salvaged = self

        // Drop only the individual points that are unusable, keeping the rest of the track.
        let cleanTrack = gpsTrack.filter { point in
            point.latitude.isFinite && point.longitude.isFinite && point.altitude.isFinite
                && GeoValidation.isValidLatLon(point.latitude, point.longitude)
        }
        if cleanTrack.count != gpsTrack.count {
            AppLog.general.debugLine(
                "Salvaged flight \(id): dropped \(gpsTrack.count - cleanTrack.count) invalid GPS point(s)")
        }
        salvaged.gpsTrack = Array(cleanTrack.prefix(FlightDataLimits.maxGPSPoints))

        // A far-future timestamp poisons the merge history (SEC-C19), but that is a reason to clamp
        // it, not to destroy the flight. Clamping loses ordering precision; rejecting loses the flight.
        let ceiling = Date().addingTimeInterval(FlightDataLimits.maxClockSkew)
        if salvaged.modifiedAt > ceiling {
            AppLog.general.debugLine("Salvaged flight \(id): clamped implausible modifiedAt")
            salvaged.modifiedAt = ceiling
        }

        // A flight imported or synced before the ingest gate bounded its numbers is stored as it
        // came, and crashed the Logbook on every launch. Repair it here. (S9-10, S9-16)
        return salvaged.withPlausibleValues()
    }

    /// The flight with every number the app formats, sums or converts to `Int` brought inside a
    /// plausible envelope. Never rejects. (S9-10, S9-16)
    ///
    /// - A cached stat out of range becomes nil and is computed again from the track on demand.
    /// - An engine hour reading out of range becomes nil and reads as not logged.
    /// - Landing counts and the pilot's logbook minutes are clamped, so their sums cannot overflow.
    /// - A track point at an impossible altitude is dropped, as `sanitizedForLocalLoad()` drops a
    ///   point at an impossible position. An impossible speed or course becomes -1, CoreLocation's
    ///   own "not known".
    /// - The flight plan it carries is bounded the same way (`FlightPlan.salvagedForFlight()`).
    func withPlausibleValues() -> Flight {
        var bounded = self

        if !gpsTrack.allSatisfy(\.hasPlausibleValues) {
            let kept = gpsTrack.compactMap(\.plausibleCopy)
            if kept.count != gpsTrack.count {
                AppLog.general.debugLine(
                    "Bounded flight \(id): dropped \(gpsTrack.count - kept.count) point(s) at an impossible altitude")
            }
            bounded.gpsTrack = kept
        }

        func inRange(_ value: Double?, _ range: ClosedRange<Double>) -> Double? {
            value.flatMap { PlausibleRange.isPlausible($0, in: range) ? $0 : nil }
        }
        bounded.cachedDistanceKm = inRange(cachedDistanceKm, FlightDataLimits.trackDistanceKm)
        bounded.cachedMaxAltitudeMeters = inRange(cachedMaxAltitudeMeters, PlausibleRange.altitudeMeters)
        bounded.cachedDurationSeconds = inRange(cachedDurationSeconds, FlightDataLimits.recordDurationSeconds)
        bounded.engineHourStart = inRange(engineHourStart, PlausibleRange.engineHours)
        bounded.engineHourEnd = inRange(engineHourEnd, PlausibleRange.engineHours)

        func clamped(_ value: Int, _ upper: Int) -> Int { min(max(0, value), upper) }
        let maxLandings = FlightDataLimits.maxLandingsPerFlight
        bounded.goAroundCount = clamped(goAroundCount, maxLandings)
        bounded.touchAndGoCount = clamped(touchAndGoCount, maxLandings)
        bounded.fullStopCount = clamped(fullStopCount, maxLandings)
        if var overrides = logbook {
            let maxMinutes = FlightDataLimits.maxLoggedMinutesPerFlight
            overrides.nightMinutes = overrides.nightMinutes.map { clamped($0, maxMinutes) }
            overrides.ifrMinutes = overrides.ifrMinutes.map { clamped($0, maxMinutes) }
            overrides.landingsNight = overrides.landingsNight.map { clamped($0, maxLandings) }
            bounded.logbook = overrides
        }

        bounded.flightPlan = flightPlan?.salvagedForFlight()
        if let records = checkRecords, records.count > CheckRecord.maxPerFlight {
            bounded.checkRecords = Array(records.prefix(CheckRecord.maxPerFlight))
        }
        if let checks = fredaChecks, checks.count > FredaCheck.maxPerFlight {
            bounded.fredaChecks = Array(checks.prefix(FredaCheck.maxPerFlight))
        }
        if let outcomes = checkOutcomes, outcomes.count > CheckOutcome.maxPerFlight {
            bounded.checkOutcomes = Array(outcomes.prefix(CheckOutcome.maxPerFlight))
        }
        return bounded
    }

    /// Total landings (touch and go + full stops, which now includes the final landing)
    var totalLandings: Int {
        // Saturating: `+` traps on overflow, and the Logbook row reads this for every flight. The
        // counts are bounded on ingest and load (`withPlausibleValues()`). (S9-10)
        let (sum, overflow) = touchAndGoCount.addingReportingOverflow(fullStopCount)
        return overflow ? (touchAndGoCount < 0 ? Int.min : Int.max) : sum
    }
    
    /// Display name: "Custom Name (Registration)" or just "Registration" if no name
    /// Falls back to airplane ID if registration is not available (for backwards compatibility)
    /// The Live Activity labels the aircraft with it. A flight's title is `title`, not this.
    var displayName: String {
        let displayIdentifier = aircraftRegistration ?? airplane
        if name.isEmpty {
            return displayIdentifier
        }
        return "\(name) (\(displayIdentifier))"
    }
    
    /// Flight duration from engine start to engine shutdown
    var duration: TimeInterval? {
        guard let start = engineStartTime else { return nil }
        let end = engineShutdownTime ?? stopTime ?? Date()
        return end.timeIntervalSince(start)
    }
    
    /// Block time duration (from first movement to last stop)
    var blockTime: TimeInterval? {
        guard let off = blockOffTime, let on = blockOnTime else { return nil }
        let interval = on.timeIntervalSince(off)
        // Same guard as `flightTime` below, and for the same reason: block-on recorded before
        // block-off (clock skew / out-of-order events) reads negative. The logbook consumes this
        // raw, so an unguarded negative was SUBTRACTED from TOTAL THIS PAGE while the row itself
        // rendered blank — a page that silently disagreed with its own rows. (review F25)
        return interval >= 0 ? interval : nil
    }

    // MARK: Logged durations (v5.2)

    /// Minutes between two times AS A LOGBOOK WRITES THEM: each time to the minute (a clock reading,
    /// 16:33:48 is 16:33), then subtracted.
    ///
    /// Not the exact interval rounded. Block off 16:33:48 and block on 17:04:16 print as 16:33 and
    /// 17:04, and 30 min 28 s rounds to 0:30 — so the line said 16:33 → 17:04 = 0:30, a sum that
    /// does not add up, on the one page pilots copy into a legal document and auditors add up.
    /// Every logged duration goes through here so the times and the durations beside them agree.
    static func loggedMinutes(from start: Date, to end: Date) -> Int {
        // Epoch minutes are UTC minutes, and every time zone is a whole number of minutes off UTC,
        // so this truncates exactly like the local or UTC HH:mm printed beside it.
        Int((end.timeIntervalSince1970 / 60).rounded(.down)) - Int((start.timeIntervalSince1970 / 60).rounded(.down))
    }

    /// Block time as logged: block on minus block off, to the minute. Nil when either is missing or
    /// they are out of order.
    var blockMinutes: Int? {
        guard let off = blockOffTime, let on = blockOnTime, on >= off else { return nil }
        return Self.loggedMinutes(from: off, to: on)
    }

    /// Flight time as logged: landing minus take-off, to the minute.
    var flightMinutes: Int? {
        guard let takeoff = lineUpTime, let landing = landingTime, landing >= takeoff else { return nil }
        return Self.loggedMinutes(from: takeoff, to: landing)
    }

    /// How a flight reads in the Flight Log. (v5.2)
    enum RouteShape: Equatable {
        /// From one aerodrome to another, with a circuits tag when there were touch-and-goes on the way.
        case between(departure: String, arrival: String, withCircuits: Bool)
        /// Back where it started (or no arrival known), with touch-and-goes: a circuits session.
        case circuits(at: String)
        /// Back where it started with no touch-and-go: a local or round flight. (v6.1)
        case roundTrip(at: String)
        /// One end known, the other not: an aerodrome the airport data lacks (an outlanding, a strip),
        /// or a recording that started or stopped away from one. Exactly one of the two is set. (v6.1)
        case oneEnd(departure: String?, arrival: String?)
        /// No aerodromes known.
        case unnamed
    }

    /// Touch-and-goes do not make a flight "circuits". Warming up with a few at home and then flying
    /// somewhere else is common, and calling that "LSZQ circuits" hid that it went to LSZG. The
    /// arrival decides the shape; the touch-and-goes only add the tag.
    var routeShape: RouteShape {
        let departure = departureAirportIdent.flatMap(Self.nonBlank)
        let arrival = arrivalAirportIdent.flatMap(Self.nonBlank)
        if let departure, let arrival, departure != arrival {
            return .between(departure: departure, arrival: arrival, withCircuits: touchAndGoCount > 0)
        }
        if touchAndGoCount > 0, let at = departure ?? arrival { return .circuits(at: at) }
        if let departure, arrival != nil { return .roundTrip(at: departure) }
        if departure != nil || arrival != nil { return .oneEnd(departure: departure, arrival: arrival) }
        return .unnamed
    }

    // MARK: Title (v6.1)

    /// What the flight is called wherever it is listed or shown: where it flew. The Logbook row, the
    /// flight's own header, Today's last flight, the share card and the GPX all read this, so they
    /// can no longer disagree.
    ///
    /// - Back where it started: "LSZQ" (circuits keep their "↻ circuits" treatment in the row).
    /// - From one aerodrome to another: "LSZQ → LSGE".
    /// - One end not found: "LSZQ → ?" or "? → LSGE". The arrow says the flight went somewhere;
    ///   "LSZQ" alone would claim it came back.
    /// - Neither end known: the pilot's name for the flight, else the registration.
    ///
    /// The pilot's name never replaces a route: it goes above it (`titleEyebrow`). Until 6.1 the
    /// Logbook fell back to "name (registration)" whenever an aerodrome was missing, so renaming a
    /// flight whose arrival had not been found looked like renaming its title.
    var title: String {
        switch routeShape {
        case let .between(departure, arrival, _):
            return "\(departure) → \(arrival)"
        case let .circuits(at), let .roundTrip(at):
            return at
        case let .oneEnd(departure, arrival):
            return "\(departure ?? Self.unknownAerodrome) → \(arrival ?? Self.unknownAerodrome)"
        case .unnamed:
            return Self.nonBlank(name) ?? aircraftRegistration ?? airplane
        }
    }

    /// The pilot's own name for the flight, shown small ABOVE `title`. Nil when there is none, or when
    /// it had to be the title because no aerodrome is known.
    var titleEyebrow: String? {
        guard routeShape != .unnamed else { return nil }
        return Self.nonBlank(name)
    }

    /// The title on one line, where there is no room for an eyebrow above it (a GPX file's name).
    var titleWithName: String {
        titleEyebrow.map { "\($0) · \(title)" } ?? title
    }

    /// The end of a route that is not known.
    static let unknownAerodrome = "?"

    /// The title as VoiceOver says it: "LSZQ to LSGE", "LSZQ to unknown aerodrome". Read aloud, the
    /// glyphs were "right arrow" and "question mark". (v6.1)
    var spokenTitle: String {
        switch routeShape {
        case let .between(departure, arrival, _):
            return L10n.FlightTitle.spokenRoute(departure, arrival)
        case let .oneEnd(departure, arrival):
            return L10n.FlightTitle.spokenRoute(departure ?? L10n.FlightTitle.unknownAerodrome,
                                                arrival ?? L10n.FlightTitle.unknownAerodrome)
        case .circuits, .roundTrip, .unnamed:
            return title
        }
    }

    /// `spokenTitle` with the pilot's name before it, for a label that stands for the whole flight.
    var spokenTitleWithName: String {
        titleEyebrow.map { "\($0), \(spokenTitle)" } ?? spokenTitle
    }

    static func nonBlank(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    // MARK: Departure and arrival aerodromes (v6.1)

    /// How far the aerodrome may be from where the flight started or ended and still be the one it
    /// started from or ended at. The live block-off and block-on detection, END FLIGHT and the
    /// Logbook's repair of older flights all use it (`AirportDataService.aerodromeIdent(at:)`).
    static let aerodromeRadiusNm = 5.0

    /// Where the flight started: the block-off position, else the first fix of the track when the
    /// aircraft was still on the ground there. A track that starts in the air says nothing.
    var departurePosition: CLLocationCoordinate2D? {
        Self.position(blockOffLatitude, blockOffLongitude) ?? gpsTrack.first.flatMap(Self.groundPosition)
    }

    /// Where the flight ended: the block-on position (measured from the whole track at END FLIGHT),
    /// else the last fix of the track when the aircraft was back on the ground.
    ///
    /// Not the landing's position: without a block on, the landing is often a LANDED tap, which can
    /// be anywhere, while the last fix on the ground is where the aircraft actually stopped. On every
    /// recorded flight so far where both exist, they name the same aerodrome.
    var arrivalPosition: CLLocationCoordinate2D? {
        Self.position(blockOnLatitude, blockOnLongitude) ?? gpsTrack.last.flatMap(Self.groundPosition)
    }

    /// Whether the departure or the arrival is missing while there is a position to find it from.
    var canFillAerodromes: Bool {
        (departureAirportIdent == nil && departurePosition != nil)
            || (arrivalAirportIdent == nil && arrivalPosition != nil)
    }

    /// Fill a missing departure or arrival from where the flight started or ended. An aerodrome that
    /// is already set is never replaced, and one the resolver does not know stays missing.
    /// - Returns: which ends were filled.
    @discardableResult
    mutating func fillMissingAerodromes(
        nearestAerodrome: (CLLocationCoordinate2D) -> String?
    ) -> (departure: Bool, arrival: Bool) {
        var filled = (departure: false, arrival: false)
        if departureAirportIdent == nil, let position = departurePosition, let ident = nearestAerodrome(position) {
            departureAirportIdent = ident
            filled.departure = true
        }
        if arrivalAirportIdent == nil, let position = arrivalPosition, let ident = nearestAerodrome(position) {
            arrivalAirportIdent = ident
            filled.arrival = true
        }
        return filled
    }

    /// END FLIGHT, after the block-on refit: fill what is missing, then let the measured block on
    /// correct a live arrival that names another aerodrome.
    ///
    /// The live detection keeps the aerodrome of the last stop of two slow fixes, and a one-fix stop
    /// at the destination leaves it on an earlier stop (the holding point at the departure field, which
    /// then reads as a round flight). The refit's block on is where the aircraft finally stopped. It
    /// corrects only toward an aerodrome: with none near the block on, the live one stays.
    ///
    /// The departure has no such failure: the live detection takes it once, at the first movement,
    /// which is the moment the refit's block off measures too, so there is no earlier stop to be stuck
    /// on. It is only filled when missing.
    /// - Returns: which ends were set, and whether the arrival replaced a live one.
    @discardableResult
    mutating func settleAerodromesAfterRefit(
        nearestAerodrome: (CLLocationCoordinate2D) -> String?
    ) -> (departure: Bool, arrival: Bool, correctedArrival: Bool) {
        let filled = fillMissingAerodromes(nearestAerodrome: nearestAerodrome)
        guard !filled.arrival, let live = arrivalAirportIdent,
              let blockOn = Self.position(blockOnLatitude, blockOnLongitude),
              let measured = nearestAerodrome(blockOn), measured != live
        else { return (filled.departure, filled.arrival, false) }
        arrivalAirportIdent = measured
        return (filled.departure, true, true)
    }

    private static func position(_ latitude: Double?, _ longitude: Double?) -> CLLocationCoordinate2D? {
        guard let latitude, let longitude, GeoValidation.isValidLatLon(latitude, longitude) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// A fix's position when it was taken on the ground: slower than a take-off roll
    /// (`TrackTimes.rollSpeedKt`). A negative speed is CoreLocation's "unknown", which it reports
    /// for a device standing still.
    private static func groundPosition(_ point: GPSPoint) -> CLLocationCoordinate2D? {
        guard point.speed < TrackTimes.rollSpeedKt * 0.514444 else { return nil }
        return position(point.latitude, point.longitude)
    }

    /// What the Flight Log sums: the logged block minutes, else the logged flight minutes, else the
    /// engine run. In seconds, for the totals that were already in seconds. (v5.2)
    var loggedSeconds: TimeInterval {
        if let minutes = blockMinutes ?? flightMinutes { return TimeInterval(minutes * 60) }
        return duration ?? 0
    }

    /// Flight time duration (from lineup/takeoff to landing)
    var flightTime: TimeInterval? {
        guard let takeoff = lineUpTime, let landing = landingTime else { return nil }
        let interval = landing.timeIntervalSince(takeoff)
        // A landing recorded before line-up (clock skew / out-of-order events) would read negative;
        // treat it as unavailable rather than show a garbled duration. (v4.0.0 review P2)
        return interval >= 0 ? interval : nil
    }

    /// Engine hours flown (difference between end and start readings)
    var engineHoursFlown: Double? {
        guard let start = engineHourStart, let end = engineHourEnd else { return nil }
        return end - start
    }

    /// Format engine hours as decimal string (e.g., "1234.5")
    static func formatHoursDecimal(_ hours: Double) -> String {
        String(format: "%.2f", hours)
    }

    /// Format engine hours as time string (e.g., "1234:30")
    static func formatHoursTime(_ hours: Double) -> String {
        // `Int(hours)` trapped on a reading imported from a file. The readings are bounded on ingest
        // and load now; this stays safe for whatever reaches it anyway. (S9-10)
        guard let wholePart = hours.safeInt else { return "--:--" }
        let minutesPart = Int(round((hours - Double(wholePart)) * 60))
        return String(format: "%d:%02d", wholePart, minutesPart)
    }

    /// Format engine hours flown as dual format (e.g., "1.5 / 1:30")
    var engineHoursFlownFormatted: String? {
        guard let flown = engineHoursFlown else { return nil }
        return "\(Flight.formatHoursDecimal(flown)) / \(Flight.formatHoursTime(flown))"
    }

    var formattedFlightTime: String {
        guard let minutes = flightMinutes else { return "--:--" }
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    var formattedDuration: String {
        guard let duration = duration else { return "--:--" }
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        return String(format: "%02d:%02d", hours, minutes)
    }
    
    var formattedDate: String {
        guard let start = startTime else { return "No date" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: start)
    }
    
    /// Total distance travelled in kilometers. Uses the value precomputed at save when available;
    /// otherwise computes on demand with a lightweight haversine (no per-segment CLLocation
    /// allocations), so the flight-log list never pays an O(n) `CLLocation.distance` per row. (PERF-22)
    var distanceKilometers: Double {
        if let cached = cachedDistanceKm { return cached }
        return Flight.computeDistanceKm(gpsTrack)
    }

    /// Haversine great-circle distance in metres between two coordinates (no allocations).
    static func haversineMeters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let earthRadius = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    static func computeDistanceKm(_ track: [GPSPoint]) -> Double {
        guard track.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<track.count {
            total += haversineMeters(track[i - 1].latitude, track[i - 1].longitude,
                                     track[i].latitude, track[i].longitude)
        }
        return total / 1000.0
    }

    /// Precomputes the summary stats (distance, max altitude, duration) once — call at save, when
    /// the GPS track is final — so the flight-log list reads cached values instead of recomputing. (PERF-22)
    mutating func computeSummaryStats() {
        cachedDistanceKm = Flight.computeDistanceKm(gpsTrack)
        cachedMaxAltitudeMeters = gpsTrack.map(\.altitude).max()
        if let start = startTime, let stop = stopTime {
            cachedDurationSeconds = stop.timeIntervalSince(start)
        }
    }

    /// Export file name, without extension: `AeroCheck_YYYYMMDD_HHMM_<route>_<registration>`, e.g.
    /// `AeroCheck_20260929_1134_LSZQ-LSGE_F-HVXA`. The date and time are the flight's start (local),
    /// so two flights of a day never share a name. (v6.1: the route joins the registration)
    ///
    /// The route is `fileRoute`; a flight with no aerodrome known carries its name there instead, as
    /// its title does, and one with neither goes by the registration alone.
    var exportFilename: String {
        let dateFormatter = DateFormatter()
        let timeFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        timeFormatter.dateFormat = "HHmm"

        // Use flight start time if available, otherwise current date
        let flightDate = startTime ?? Date()
        let dateStr = dateFormatter.string(from: flightDate)
        let timeStr = timeFormatter.string(from: flightDate)

        let parts = [fileRoute ?? Self.nonBlank(name), aircraftRegistration ?? airplane]
            .compactMap { $0.map(Self.fileSafe) }
            .filter { !$0.isEmpty }
        return (["AeroCheck", dateStr, timeStr] + parts).joined(separator: "_")
    }

    /// The route as a file name carries it: "LSZQ-LSGE", "LSZQ" for a flight back where it started
    /// (circuits included), "LSZQ-ZZZZ" with an end not found. ZZZZ is what an ICAO flight plan
    /// writes for an aerodrome without an indicator; "?" is not safe in a file name. Nil with no
    /// aerodrome known.
    var fileRoute: String? {
        switch routeShape {
        case let .between(departure, arrival, _):
            return "\(departure)-\(arrival)"
        case let .circuits(at), let .roundTrip(at):
            return at
        case let .oneEnd(departure, arrival):
            return "\(departure ?? "ZZZZ")-\(arrival ?? "ZZZZ")"
        case .unnamed:
            return nil
        }
    }

    /// One file-name part that any file system and any archive tool takes: letters (accents
    /// included), digits, "-" and "."; everything else, spaces and "/" among them, becomes "_", with
    /// no run of them and none at either end, and at most 60 characters. "Vol Solo #2.1" becomes
    /// "Vol_Solo_2.1".
    static func fileSafe(_ text: String) -> String {
        var result = ""
        for character in text.precomposedStringWithCanonicalMapping {
            if character.isLetter || character.isNumber || character == "-" || character == "." {
                result.append(character)
            } else if result.last != "_" {
                result.append("_")
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "_."))
        return String(trimmed.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "_."))
    }
}

/// A single GPS coordinate with timestamp
struct GPSPoint: Codable, Identifiable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let timestamp: Date
    let speed: Double
    let course: Double
    let horizontalAccuracy: Double?
    /// RAW relative barometric altitude in meters (CMAltimeter session datum), when the
    /// device has a barometer. Relative only — never MSL (weather drift makes absolute
    /// pressure altitude meaningless). Optional so pre-baro flight JSON keeps decoding
    /// (synthesized Codable uses decodeIfPresent for optionals); export is additive.
    let baroAltitude: Double?

    init(
        id: UUID = UUID(),
        latitude: Double,
        longitude: Double,
        altitude: Double,
        timestamp: Date = Date(),
        speed: Double = 0,
        course: Double = 0,
        horizontalAccuracy: Double? = nil,
        baroAltitude: Double? = nil
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.timestamp = timestamp
        self.speed = speed
        self.course = course
        self.horizontalAccuracy = horizontalAccuracy
        self.baroAltitude = baroAltitude
    }

    /// `timestampOverride` re-stamps the point with a chosen clock. Used when recording a *borrowed*
    /// companion fix (whose `location.timestamp` is the peer device's clock) so the persisted track and
    /// the flight-event timeline share the master's single clock domain. (v4.1.0 pre-tag fix)
    init(from location: CLLocation, timestampOverride: Date? = nil, baroAltitude: Double? = nil) {
        self.id = UUID()
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.altitude = location.altitude
        self.timestamp = timestampOverride ?? location.timestamp
        self.speed = location.speed
        self.course = location.course
        self.horizontalAccuracy = location.horizontalAccuracy
        self.baroAltitude = baroAltitude
    }
    
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Altitude inside the envelope, and a speed and course that are real values or -1. (S9-10)
    var hasPlausibleValues: Bool {
        PlausibleRange.isPlausible(altitude, in: PlausibleRange.altitudeMeters)
            && GPSPoint.plausibleOrUnknown(speed, in: PlausibleRange.speedMPS) == speed
            && GPSPoint.plausibleOrUnknown(course, in: PlausibleRange.courseDegrees) == course
    }

    /// Nil when the altitude is impossible. Otherwise the point, with an impossible speed or course
    /// replaced by -1: the Logbook's speed chart converted 1e300 m/s to `Int` and trapped.
    var plausibleCopy: GPSPoint? {
        guard PlausibleRange.isPlausible(altitude, in: PlausibleRange.altitudeMeters) else { return nil }
        return GPSPoint(id: id, latitude: latitude, longitude: longitude, altitude: altitude,
                        timestamp: timestamp,
                        speed: GPSPoint.plausibleOrUnknown(speed, in: PlausibleRange.speedMPS),
                        course: GPSPoint.plausibleOrUnknown(course, in: PlausibleRange.courseDegrees),
                        horizontalAccuracy: horizontalAccuracy, baroAltitude: baroAltitude)
    }

    /// The value, or -1 (CoreLocation's "not known", which it records itself) when it is outside `range`.
    private static func plausibleOrUnknown(_ value: Double, in range: ClosedRange<Double>) -> Double {
        PlausibleRange.isPlausible(value, in: range) ? value : -1
    }
}

// MARK: - GPX Export/Import

extension Flight {
    /// Export flight to GPX format with all timing data in extensions
    func toGPX() -> String {
        // PR-18: user-controlled strings are XML-escaped (see String.xmlEscaped) so a flight
        // named "Touch & Go" (or with < > " ') can't produce malformed XML that XMLParser aborts on.
        let dateFormatter = ISO8601DateFormatter()
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        var gpx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="AéroCheck v\(appVersion)"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
             xmlns:pc="http://aerocheck.app/gpx/1"
             xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
          <metadata>
            <name>\(titleWithName.xmlEscaped) - \(formattedDate)</name>
            <desc>Flight recorded with AéroCheck app</desc>
        """

        if let start = startTime {
            gpx += "\n    <time>\(dateFormatter.string(from: start))</time>"
        }

        gpx += """

          </metadata>
          <trk>
            <name>\(airplane.xmlEscaped)</name>
            <extensions>
              <pc:flightData>
                <pc:formatVersion>\(currentExportFormatVersion)</pc:formatVersion>
                <pc:appVersion>\(appVersion)</pc:appVersion>
                <pc:name>\(name.xmlEscaped)</pc:name>
                <pc:airplane>\(airplane.xmlEscaped)</pc:airplane>
        """

        if let aircraftType = aircraftType {
            gpx += "\n        <pc:aircraftType>\(aircraftType)</pc:aircraftType>"
        }
        if let checklistVersion = checklistVersion {
            gpx += "\n        <pc:checklistVersion>\(checklistVersion)</pc:checklistVersion>"
        }

        gpx += ""
        
        if let start = startTime {
            gpx += "\n        <pc:startTime>\(dateFormatter.string(from: start))</pc:startTime>"
        }
        if let engineStart = engineStartTime {
            gpx += "\n        <pc:engineStartTime>\(dateFormatter.string(from: engineStart))</pc:engineStartTime>"
        }
        if let lineUp = lineUpTime {
            gpx += "\n        <pc:lineUpTime>\(dateFormatter.string(from: lineUp))</pc:lineUpTime>"
        }
        if let landing = landingTime {
            gpx += "\n        <pc:landingTime>\(dateFormatter.string(from: landing))</pc:landingTime>"
        }
        if let shutdown = engineShutdownTime {
            gpx += "\n        <pc:engineShutdownTime>\(dateFormatter.string(from: shutdown))</pc:engineShutdownTime>"
        }
        if let stop = stopTime {
            gpx += "\n        <pc:stopTime>\(dateFormatter.string(from: stop))</pc:stopTime>"
        }

        // Block times and airport detection (v3)
        if let blockOff = blockOffTime {
            gpx += "\n        <pc:blockOffTime>\(dateFormatter.string(from: blockOff))</pc:blockOffTime>"
        }
        if let lat = blockOffLatitude {
            gpx += "\n        <pc:blockOffLatitude>\(lat)</pc:blockOffLatitude>"
        }
        if let lon = blockOffLongitude {
            gpx += "\n        <pc:blockOffLongitude>\(lon)</pc:blockOffLongitude>"
        }
        if let blockOn = blockOnTime {
            gpx += "\n        <pc:blockOnTime>\(dateFormatter.string(from: blockOn))</pc:blockOnTime>"
        }
        if let lat = blockOnLatitude {
            gpx += "\n        <pc:blockOnLatitude>\(lat)</pc:blockOnLatitude>"
        }
        if let lon = blockOnLongitude {
            gpx += "\n        <pc:blockOnLongitude>\(lon)</pc:blockOnLongitude>"
        }
        if let dep = departureAirportIdent {
            gpx += "\n        <pc:departureAirportIdent>\(dep)</pc:departureAirportIdent>"
        }
        if let arr = arrivalAirportIdent {
            gpx += "\n        <pc:arrivalAirportIdent>\(arr)</pc:arrivalAirportIdent>"
        }

        // Engine hour meter readings (v4)
        if let hourStart = engineHourStart {
            gpx += "\n        <pc:engineHourStart>\(String(format: "%.2f", hourStart))</pc:engineHourStart>"
        }
        if let hourEnd = engineHourEnd {
            gpx += "\n        <pc:engineHourEnd>\(String(format: "%.2f", hourEnd))</pc:engineHourEnd>"
        }

        gpx += "\n        <pc:distanceKm>\(String(format: "%.2f", distanceKilometers))</pc:distanceKm>"

        if goAroundCount > 0 {
            gpx += "\n        <pc:goAroundCount>\(goAroundCount)</pc:goAroundCount>"
            for goAroundTime in goAroundTimes {
                gpx += "\n        <pc:goAroundTime>\(dateFormatter.string(from: goAroundTime))</pc:goAroundTime>"
            }
        }

        if touchAndGoCount > 0 {
            gpx += "\n        <pc:touchAndGoCount>\(touchAndGoCount)</pc:touchAndGoCount>"
            for touchAndGoTime in touchAndGoTimes {
                gpx += "\n        <pc:touchAndGoTime>\(dateFormatter.string(from: touchAndGoTime))</pc:touchAndGoTime>"
            }
        }

        if fullStopCount > 0 {
            gpx += "\n        <pc:fullStopCount>\(fullStopCount)</pc:fullStopCount>"
            for fullStopTime in fullStopTimes {
                gpx += "\n        <pc:fullStopTime>\(dateFormatter.string(from: fullStopTime))</pc:fullStopTime>"
            }
        }

        if !notes.isEmpty {
            // PR-18: a literal "]]>" in notes would terminate the CDATA section early; split it.
            let safeNotes = notes.cdataSafe
            gpx += "\n        <pc:notes><![CDATA[\(safeNotes)]]></pc:notes>"
        }
        
        gpx += """
        
              </pc:flightData>
            </extensions>
            <trkseg>
        
        """
        
        for point in gpsTrack {
            gpx += """
              <trkpt lat="\(point.latitude)" lon="\(point.longitude)">
                <ele>\(point.altitude)</ele>
                <time>\(dateFormatter.string(from: point.timestamp))</time>
                <extensions>
                  <pc:speed>\(point.speed)</pc:speed>
                  <pc:course>\(point.course)</pc:course>
                  <pc:horizontalAccuracy>\(point.horizontalAccuracy ?? -1)</pc:horizontalAccuracy>
                </extensions>
              </trkpt>
            
            """
        }
        
        gpx += """
            </trkseg>
          </trk>
        </gpx>
        """
        
        return gpx
    }
    
    /// Export flight to JSON format (includes all data with metadata)
    func toJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let exportWrapper = FlightExportWrapper(flight: self, flightPlan: nil)
            return try encoder.encode(exportWrapper)
        } catch {
            AppLog.general.debugLine("Failed to encode flight to JSON: \(error.localizedDescription)")
            return nil
        }
    }

    /// Export flight to JSON format with optional flight plan data
    /// - Parameter flightPlan: Optional flight plan to include in export
    /// - Returns: JSON data including both flight and navigation plan data
    func toJSON(withFlightPlan flightPlan: FlightPlan?) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let exportWrapper = FlightExportWrapper(flight: self, flightPlan: flightPlan)
            return try encoder.encode(exportWrapper)
        } catch {
            AppLog.general.debugLine("Failed to encode flight with navigation to JSON: \(error.localizedDescription)")
            return nil
        }
    }
}

/// Export metadata structure
struct FlightExportMetadata: Codable {
    let appName: String
    let appVersion: String
    let formatVersion: Int
    let exportDate: Date

    static var current: FlightExportMetadata {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return FlightExportMetadata(
            appName: "AéroCheck",
            appVersion: appVersion,
            formatVersion: currentExportFormatVersion,
            exportDate: Date()
        )
    }
}

/// Wrapper structure for JSON exports with metadata (v2 format)
struct FlightExportWrapper: Codable {
    let metadata: FlightExportMetadata
    let flight: Flight
    let flightPlan: FlightPlan?

    init(flight: Flight, flightPlan: FlightPlan?) {
        self.metadata = .current
        self.flight = flight
        self.flightPlan = flightPlan
    }
}

/// Combined export structure for flight with navigation data (legacy, kept for compatibility)
struct FlightWithNavigationExport: Codable {
    let flight: Flight
    let flightPlan: FlightPlan?
}

// MARK: - Flight Import

extension Flight {
    /// Errors that can occur during flight import
    enum ImportError: Error, LocalizedError {
        case invalidJSON(underlying: Error)
        case invalidGPX
        case invalidCoordinates

        var errorDescription: String? {
            switch self {
            case .invalidJSON(let underlying):
                return "Invalid JSON format: \(underlying.localizedDescription)"
            case .invalidGPX:
                return "Invalid GPX format"
            case .invalidCoordinates:
                return "Import contains invalid coordinates (out of range or not a number)"
            }
        }
    }

    /// Import flight from JSON data, supporting multiple format versions:
    /// - v2: FlightExportWrapper with metadata, flight, and optional flightPlan
    /// - v1: Direct Flight object (backward compatibility)
    /// - Legacy: FlightWithNavigationExport with flight and flightPlan (no metadata)
    ///
    /// - Parameter data: JSON data to decode
    /// - Returns: Decoded Flight object
    /// - Throws: ImportError.invalidJSON if decoding fails
    static func fromJSON(_ data: Data) throws -> Flight {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let imported: Flight
        // Try v2 format first (FlightExportWrapper with metadata)
        if let wrapper = try? decoder.decode(FlightExportWrapper.self, from: data) {
            AppLog.general.debugLine("Imported flight from v2 format (formatVersion: \(wrapper.metadata.formatVersion))")
            imported = wrapper.flight
        } else if let legacyExport = try? decoder.decode(FlightWithNavigationExport.self, from: data) {
            // Legacy FlightWithNavigationExport format (no metadata)
            AppLog.general.debugLine("Imported flight from legacy FlightWithNavigationExport format")
            imported = legacyExport.flight
        } else {
            // v1 format (direct Flight object - oldest format)
            do {
                imported = try decoder.decode(Flight.self, from: data)
                AppLog.general.debugLine("Imported flight from v1 format (direct Flight object)")
            } catch {
                AppLog.general.debugLine("Failed to decode flight from JSON: \(error)")
                throw ImportError.invalidJSON(underlying: error)
            }
        }

        // SEC-08 + SEC-C18: run the SAME validator the CloudKit ingest path uses, rather than a
        // coordinates-only subset. This path previously checked coordinates but not the point
        // COUNT — the cap its own GPX sibling and the sync path both enforce — so an import could
        // carry an unbounded gpsTrack straight into memory and the flight store.
        guard imported.importedCoordinatesAreValid, let validated = imported.validatedForIngest() else {
            AppLog.general.debugLine("Rejected flight import: failed ingest validation")
            throw ImportError.invalidCoordinates
        }
        return validated.withSummaryStatsFromTrack()
    }

    /// A flight read from a file, with its distance, maximum altitude and duration computed from its
    /// own track instead of taken from the file. The track is the evidence; the cached figures are a
    /// claim anyone can edit, and they feed the Logbook's totals. A file without a track keeps the
    /// figures it carries, already bounded by `validatedForIngest()`. (S9-10)
    func withSummaryStatsFromTrack() -> Flight {
        guard !gpsTrack.isEmpty else { return self }
        var computed = self
        computed.computeSummaryStats()
        return computed
    }

    /// Import flight from JSON data (non-throwing version for backward compatibility)
    /// - Parameter data: JSON data to decode
    /// - Returns: Decoded Flight object, or nil if decoding fails
    static func fromJSONOptional(_ data: Data) -> Flight? {
        try? fromJSON(data)
    }

    /// Import flight from GPX data
    static func fromGPX(_ data: Data) -> Flight? {
        fromGPXWithSuggestedName(data)?.flight
    }

    /// The flight, and the name a GPX from another app gives its track (nil for an AeroCheck file,
    /// whose own name for the flight is restored as the flight's name). (v6.1)
    static func fromGPXWithSuggestedName(_ data: Data) -> (flight: Flight, suggestedName: String?)? {
        let parser = GPXParser(data: data)
        // SEC-C18: same validator as every other ingest path.
        guard let flight = parser.parse()?.validatedForIngest()?.withSummaryStatsFromTrack() else { return nil }
        return (flight, parser.suggestedName)
    }
}

/// Validation helpers for imported geographic data (SEC-08): reject NaN/Inf/out-of-range
/// so ElevationService / export never operate on garbage coordinates.
extension String {
    /// Escapes a `]]>` sequence so the string can be embedded in an XML CDATA section.
    ///
    /// PR-18 / SEC-C22: this was an inline one-liner in the Flight GPX writer and simply absent
    /// from the FlightPlan one, so a plan or waypoint remark containing `]]>` produced malformed
    /// XML in a file handed to Dynon/Garmin avionics — and re-imported by this app. Shared so the
    /// two writers cannot drift apart again.
    var cdataSafe: String {
        replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>")
    }
}

enum GeoValidation {
    static func isValidLatLon(_ lat: Double, _ lon: Double) -> Bool {
        lat.isFinite && lon.isFinite && (-90.0...90.0).contains(lat) && (-180.0...180.0).contains(lon)
    }
    /// Returns the latitude if finite and in range, else nil.
    static func validLatitude(_ v: Double?) -> Double? {
        guard let v, v.isFinite, (-90.0...90.0).contains(v) else { return nil }
        return v
    }
    /// Returns the longitude if finite and in range, else nil.
    static func validLongitude(_ v: Double?) -> Double? {
        guard let v, v.isFinite, (-180.0...180.0).contains(v) else { return nil }
        return v
    }
    /// Returns the value if finite, else nil (for optional numeric fields).
    static func finite(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return v
    }
}

extension Flight {
    /// True if every imported route coordinate (and any block coordinate pair) is finite
    /// and in range. Used to reject a whole import rather than yield a silently-clean route.
    var importedCoordinatesAreValid: Bool {
        for p in gpsTrack where !GeoValidation.isValidLatLon(p.latitude, p.longitude) {
            return false
        }
        if let lat = blockOffLatitude, let lon = blockOffLongitude,
           !GeoValidation.isValidLatLon(lat, lon) {
            return false
        }
        if let lat = blockOnLatitude, let lon = blockOnLongitude,
           !GeoValidation.isValidLatLon(lat, lon) {
            return false
        }
        return true
    }
}

/// Simple GPX parser for importing flights
class GPXParser: NSObject, XMLParserDelegate {
    private var data: Data
    private var flight: Flight?
    private var currentElement = ""
    private var currentText = ""
    private var currentPoint: GPSPoint?
    private var points: [GPSPoint] = []
    private var attributes: [String: String] = [:]
    /// Set if any track point carries an invalid (NaN/Inf/out-of-range) coordinate, in which
    /// case the whole import is rejected rather than yielding a partial/garbage track. (SEC-08)
    private var hasInvalidCoordinate = false
    /// Set if the track exceeds the hard point cap — a crafted file can't OOM/hang the import; it
    /// is rejected with a clear error rather than silently truncated. (SEC-13)
    private var hasTooManyPoints = false
    private var goAroundTimes: [Date] = []
    private var touchAndGoTimes: [Date] = []
    private var fullStopTimes: [Date] = []
    /// Whether the file is an AeroCheck export, which says what the flight was called (`pc:name`,
    /// empty when the pilot named it nothing).
    private var carriesAeroCheckName = false
    /// The first name the track itself has: in an AeroCheck file the aircraft, in another app's the
    /// only name there is.
    private var trackName: String?

    /// What another app called the track, for the pilot to take or leave; nil for an AeroCheck
    /// file, whose name is restored as it was. (v6.1)
    var suggestedName: String? { carriesAeroCheckName ? nil : trackName }

    private let dateFormatter = ISO8601DateFormatter()
    
    init(data: Data) {
        self.data = data
        super.init()
    }

    /// An hour meter reading from the file, or nil when it is not one a meter can show.
    static func engineHourReading(_ text: String) -> Double? {
        guard let hours = Double(text), PlausibleRange.isPlausible(hours, in: PlausibleRange.engineHours) else {
            return nil
        }
        return hours
    }

    func parse() -> Flight? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        // Defense-in-depth on an attacker-supplied-file import path: never resolve external
        // entities (XXE), so the safe behavior survives any future refactor. (SEC-20)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.parse()
        return (hasInvalidCoordinate || hasTooManyPoints) ? nil : flight
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        currentText = ""
        self.attributes = attributeDict
        
        if elementName == "trk" {
            flight = Flight()
        } else if elementName == "trkpt" {
            if let latStr = attributeDict["lat"], let lonStr = attributeDict["lon"],
               let lat = Double(latStr), let lon = Double(lonStr),
               GeoValidation.isValidLatLon(lat, lon) {
                currentPoint = GPSPoint(latitude: lat, longitude: lon, altitude: 0)
            } else {
                // A trkpt with missing/unparseable/out-of-range coordinates invalidates the import.
                hasInvalidCoordinate = true
            }
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Handle both prefixed and non-prefixed element names
        let elementKey = elementName.replacingOccurrences(of: "pc:", with: "")

        switch elementKey {
        case "name":
            if elementName == "pc:name" {
                // The flight's own name: restored, as a JSON import always did. Until 6.1 a GPX
                // import dropped it, and the flight came back unnamed. (v6.1)
                flight?.name = text
                carriesAeroCheckName = true
            } else if flight != nil {
                if trackName == nil, !text.isEmpty { trackName = text }
                if flight?.airplane == "F-HVXA" {
                    flight?.airplane = text
                }
            }
        case "airplane":
            flight?.airplane = text
        case "aircraftType":
            flight?.aircraftType = text
        case "checklistVersion":
            flight?.checklistVersion = text
        case "notes":
            flight?.notes = text
        case "time":
            if let date = dateFormatter.date(from: text) {
                if flight?.startTime == nil {
                    flight?.startTime = date
                } else if let point = currentPoint {
                    currentPoint = GPSPoint(
                        id: point.id,
                        latitude: point.latitude,
                        longitude: point.longitude,
                        altitude: point.altitude,
                        timestamp: date,
                        speed: point.speed,
                        course: point.course,
                        horizontalAccuracy: point.horizontalAccuracy
                    )
                }
            }
        case "startTime":
            flight?.startTime = dateFormatter.date(from: text)
        case "engineStartTime":
            flight?.engineStartTime = dateFormatter.date(from: text)
        case "lineUpTime":
            flight?.lineUpTime = dateFormatter.date(from: text)
        case "landingTime":
            flight?.landingTime = dateFormatter.date(from: text)
        case "engineShutdownTime":
            flight?.engineShutdownTime = dateFormatter.date(from: text)
        case "stopTime":
            flight?.stopTime = dateFormatter.date(from: text)
        case "blockOffTime":
            flight?.blockOffTime = dateFormatter.date(from: text)
        case "blockOffLatitude":
            flight?.blockOffLatitude = GeoValidation.validLatitude(Double(text))
        case "blockOffLongitude":
            flight?.blockOffLongitude = GeoValidation.validLongitude(Double(text))
        case "blockOnTime":
            flight?.blockOnTime = dateFormatter.date(from: text)
        case "blockOnLatitude":
            flight?.blockOnLatitude = GeoValidation.validLatitude(Double(text))
        case "blockOnLongitude":
            flight?.blockOnLongitude = GeoValidation.validLongitude(Double(text))
        case "departureAirportIdent":
            flight?.departureAirportIdent = text
        case "arrivalAirportIdent":
            flight?.arrivalAirportIdent = text
        // `Double(_:)` reads "nan", "inf" and "1e300" as numbers, and `formatHoursTime` then trapped
        // on them. A reading must be finite and one an hour meter can show. (S9-10)
        case "engineHourStart":
            flight?.engineHourStart = Self.engineHourReading(text)
        case "engineHourEnd":
            flight?.engineHourEnd = Self.engineHourReading(text)
        case "goAroundCount":
            flight?.goAroundCount = Int(text) ?? 0
        case "goAroundTime":
            if let date = dateFormatter.date(from: text) {
                goAroundTimes.append(date)
            }
        case "touchAndGoCount":
            flight?.touchAndGoCount = Int(text) ?? 0
        case "touchAndGoTime":
            if let date = dateFormatter.date(from: text) {
                touchAndGoTimes.append(date)
            }
        case "fullStopCount":
            flight?.fullStopCount = Int(text) ?? 0
        case "fullStopTime":
            if let date = dateFormatter.date(from: text) {
                fullStopTimes.append(date)
            }
        case "ele":
            if let point = currentPoint, let alt = Double(text), alt.isFinite {
                currentPoint = GPSPoint(
                    id: point.id,
                    latitude: point.latitude,
                    longitude: point.longitude,
                    altitude: alt,
                    timestamp: point.timestamp,
                    speed: point.speed,
                    course: point.course,
                    horizontalAccuracy: point.horizontalAccuracy
                )
            }
        case "speed":
            if let point = currentPoint, let spd = Double(text), spd.isFinite {
                currentPoint = GPSPoint(
                    id: point.id,
                    latitude: point.latitude,
                    longitude: point.longitude,
                    altitude: point.altitude,
                    timestamp: point.timestamp,
                    speed: spd,
                    course: point.course,
                    horizontalAccuracy: point.horizontalAccuracy
                )
            }
        case "course":
            if let point = currentPoint, let crs = Double(text), crs.isFinite {
                currentPoint = GPSPoint(
                    id: point.id,
                    latitude: point.latitude,
                    longitude: point.longitude,
                    altitude: point.altitude,
                    timestamp: point.timestamp,
                    speed: point.speed,
                    course: crs,
                    horizontalAccuracy: point.horizontalAccuracy
                )
            }
        case "horizontalAccuracy":
            if let point = currentPoint, let acc = Double(text), acc.isFinite {
                currentPoint = GPSPoint(
                    id: point.id,
                    latitude: point.latitude,
                    longitude: point.longitude,
                    altitude: point.altitude,
                    timestamp: point.timestamp,
                    speed: point.speed,
                    course: point.course,
                    horizontalAccuracy: acc
                )
            }
        case "trkpt":
            if let point = currentPoint {
                if points.count >= FlightDataLimits.maxGPSPoints {
                    hasTooManyPoints = true // stop appending so a crafted file can't OOM the import
                } else {
                    points.append(point)
                }
            }
            currentPoint = nil
        case "trk":
            flight?.gpsTrack = points
            flight?.goAroundTimes = goAroundTimes
            flight?.touchAndGoTimes = touchAndGoTimes
            flight?.fullStopTimes = fullStopTimes
            if flight?.stopTime == nil, let lastPoint = points.last {
                flight?.stopTime = lastPoint.timestamp
            }
        default:
            break
        }
    }
}

// MARK: - XML escaping

extension String {
    /// Escapes the five XML predefined entities (`&` first) so user-controlled text can be
    /// embedded in GPX/XML output without producing malformed markup. Single source of truth
    /// for GPX (`Flight`/`FlightPlan`) and route export (`FlightPlanExportService`).
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

