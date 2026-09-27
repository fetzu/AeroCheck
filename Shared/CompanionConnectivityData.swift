import Foundation

#if !os(watchOS)
import UIKit

// MARK: - Connection & Role

/// Connection state for companion mode
enum CompanionConnectionState: Equatable {
    case disconnected
    case pairing         // One-time device pairing via system UI
    case connecting      // Establishing connection to paired device
    case connected       // Active data flow
    case reconnecting    // Temporarily lost, auto-reconnecting
}

/// Role in companion mode
enum CompanionRole: String, Codable {
    case none            // Not in companion mode
    case master          // iPad: broadcasting data
    case viewer          // iPhone: receiving data

    /// The companion role for this device, derived purely from device type. There is NO user setting:
    /// Wi-Fi Aware pairing is inherently asymmetric (one device must advertise, the other must browse),
    /// so the role is assigned automatically — the iPad drives (master/advertises), the iPhone views
    /// (viewer/browses). This matches the cockpit workflow and removes the footgun where two devices
    /// could pick the same role and never discover each other. (v4.1 — pairing UX simplification)
    static func automatic(for idiom: UIUserInterfaceIdiom) -> CompanionRole {
        idiom == .pad ? .master : .viewer
    }
}

/// User-facing role setting.
///
/// DEPRECATED (v4.1): the role is now resolved automatically by device type via
/// `CompanionRole.automatic(for:)` and is no longer user-selectable. This enum is retained only so the
/// persisted `AppSettings.companionRole` field keeps decoding old saves; it is otherwise unused.
enum CompanionRoleSetting: String, Codable, CaseIterable, Identifiable {
    case auto = "Auto"
    case primary = "Primary"
    case companion = "Companion"

    var id: String { rawValue }

    func resolvedRole(for idiom: UIUserInterfaceIdiom) -> CompanionRole {
        switch self {
        case .auto:
            return CompanionRole.automatic(for: idiom)
        case .primary:
            return .master
        case .companion:
            return .viewer
        }
    }
}
#endif

// MARK: - Wire Protocol

/// Wrapper for all messages sent between devices.
///
/// **Versioned, tolerant contract.** The iPad (master) and iPhone (viewer) apps update
/// independently, so the envelope carries `schemaVersion` to let a receiver detect skew, and its
/// decoder reads the version with a default so a pre-versioning envelope still routes. (ARCH)
struct CompanionMessage: Codable {
    enum MessageType: String, Codable {
        case flightData       // Master -> Viewer (periodic 1Hz)
        case flightPlanUpdate // Master -> Viewer (on change)
        case checklistUpdate  // Master -> Viewer (current phase's items + highlight) — companion v2
        case command          // Viewer -> Master
        case disconnect       // Either direction (graceful)
        case peerGPS          // Viewer -> Master (the peer's GPS fix, when the master has none) — shared-GPS
        case viewerHello      // Viewer -> Master (viewer capabilities/entitlement, on connect) — SA-26
    }

    /// Current wire-format version produced by this build.
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let type: MessageType
    let payload: Data     // JSON-encoded inner type
    let timestamp: Date

    init(type: MessageType, payload: Data) {
        self.schemaVersion = CompanionMessage.currentSchemaVersion
        self.type = type
        self.payload = payload
        self.timestamp = Date()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerant on version (0 = pre-versioning sender); type/payload stay required — a message
        // with no routable type is genuinely unusable and should surface as an error.
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        type = try c.decode(MessageType.self, forKey: .type)
        payload = try c.decode(Data.self, forKey: .payload)
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date.distantPast
    }
}

// MARK: - Flight Data (Master -> Viewer, 1Hz)

/// Lightweight periodic update sent from iPad to iPhone at 1Hz
struct CompanionFlightData: Codable {
    // Flight status
    let isFlightActive: Bool
    let currentPhase: String
    let currentPhaseRawValue: Int
    let isCircuitMode: Bool

    // Timing
    let engineStartTime: Date?
    let lineUpTime: Date?
    let landingTime: Date?

    // Settings
    let alwaysUseUTC: Bool

    // GPS data (the master's EFFECTIVE location — its own fix, or a companion's when borrowing)
    let latitude: Double?
    let longitude: Double?
    let speedMPS: Double?
    let altitudeFeet: Double?
    let courseDegrees: Double?
    let gpsSignalStatus: String

    /// Whether the master has its OWN valid GPS fix. When false, a viewer that has a fix streams a
    /// `peerGPS` message up so the master can run the flight off the companion's location. (v4.1 shared-GPS)
    let ownGPSAvailable: Bool

    /// Which GPS the flight is actually running on, from the master's view: "own" (the iPad's),
    /// "peer" (a borrowed companion fix), or "none". Lets the viewer show WHICH device's GPS is in use.
    /// (companion v2 — GPS clarity)
    let gpsSource: String

    /// The master's resolved cockpit theme ("day" / "sunlight" / "night") so the viewer renders the SAME
    /// day/sunlight/night styling as the iPad, instead of its own device theme. (companion v2 — theme parity)
    let cockpitThemeMode: String

    // Navigation state (lightweight -- full plan sent separately)
    let currentWaypointIndex: Int
    let chronometerStartTime: Date?
    let chronometerElapsed: TimeInterval

    // Aircraft info
    let aircraftRegistration: String
    let aircraftType: String

    // Timestamp for staleness detection
    let timestamp: Date
}

extension CompanionFlightData {
    /// Tolerant decoder: every field defaults, so a field skew between the independently-updated
    /// iPad (master) and iPhone (viewer) builds never throws and drops the 1 Hz update. Declared in
    /// an extension so the sender's memberwise initialiser is preserved. (ARCH — versioned contract)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isFlightActive = try c.decodeIfPresent(Bool.self, forKey: .isFlightActive) ?? false
        currentPhase = try c.decodeIfPresent(String.self, forKey: .currentPhase) ?? "PREFLIGHT"
        currentPhaseRawValue = try c.decodeIfPresent(Int.self, forKey: .currentPhaseRawValue) ?? 0
        isCircuitMode = try c.decodeIfPresent(Bool.self, forKey: .isCircuitMode) ?? false
        engineStartTime = try c.decodeIfPresent(Date.self, forKey: .engineStartTime)
        lineUpTime = try c.decodeIfPresent(Date.self, forKey: .lineUpTime)
        landingTime = try c.decodeIfPresent(Date.self, forKey: .landingTime)
        alwaysUseUTC = try c.decodeIfPresent(Bool.self, forKey: .alwaysUseUTC) ?? false
        // The position goes as a pair or not at all: half a coordinate is no position. Every number
        // below is bounded at the wire, so the viewer only ever draws plausible values. (see
        // CompanionWireLimits)
        let lat = try c.decodeIfPresent(Double.self, forKey: .latitude)
        let lon = try c.decodeIfPresent(Double.self, forKey: .longitude)
        if let lat, let lon, CompanionWireLimits.isValidCoordinate(latitude: lat, longitude: lon) {
            latitude = lat
            longitude = lon
        } else {
            latitude = nil
            longitude = nil
        }
        speedMPS = CompanionWireLimits.bounded(try c.decodeIfPresent(Double.self, forKey: .speedMPS),
                                               in: PlausibleRange.speedMPS)
        altitudeFeet = CompanionWireLimits.bounded(try c.decodeIfPresent(Double.self, forKey: .altitudeFeet),
                                                   in: PlausibleRange.altitudeFeet)
        courseDegrees = CompanionWireLimits.bounded(try c.decodeIfPresent(Double.self, forKey: .courseDegrees),
                                                    in: PlausibleRange.courseDegrees)
        gpsSignalStatus = try c.decodeIfPresent(String.self, forKey: .gpsSignalStatus) ?? "unknown"
        // Default true: a pre-shared-GPS master is assumed to have its own fix, so a viewer won't try to
        // source GPS for it. (v4.1 shared-GPS — backward-compatible)
        ownGPSAvailable = try c.decodeIfPresent(Bool.self, forKey: .ownGPSAvailable) ?? true
        gpsSource = try c.decodeIfPresent(String.self, forKey: .gpsSource) ?? "own"
        cockpitThemeMode = try c.decodeIfPresent(String.self, forKey: .cockpitThemeMode) ?? "day"
        // Clamp a peer-supplied index so it can never become a negative array subscript on the
        // receiver, nor overflow when the viewer looks one waypoint ahead (`index + 1` on Int.max
        // traps). The upper bound against the actual waypoint count is still checked per use.
        currentWaypointIndex = CompanionWireLimits.index(
            try c.decodeIfPresent(Int.self, forKey: .currentWaypointIndex) ?? 0)
        chronometerStartTime = try c.decodeIfPresent(Date.self, forKey: .chronometerStartTime)
        chronometerElapsed = CompanionWireLimits.bounded(
            try c.decodeIfPresent(TimeInterval.self, forKey: .chronometerElapsed),
            in: CompanionWireLimits.elapsedSeconds) ?? 0
        aircraftRegistration = try c.decodeIfPresent(String.self, forKey: .aircraftRegistration) ?? ""
        aircraftType = try c.decodeIfPresent(String.self, forKey: .aircraftType) ?? ""
        // Absent timestamp -> distantPast so a malformed update reads as stale, never as "fresh now".
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date.distantPast
    }
}

// MARK: - Wire bounds (Master -> Viewer)

/// Bounds for the numbers the master streams to the viewer.
///
/// A paired peer is a trust boundary in this direction too. JSON carries no NaN, but 1e300 decodes
/// to a finite Double and passes every `isFinite` check, and on the viewer such a value trapped in
/// `Int(chronometerElapsed)`, spun the turn arrow's normalising loop forever on the main thread (a
/// course of 1e300 minus 360 is still 1e300), and overflowed `currentWaypointIndex + 1`. The
/// decoders of the master's snapshots bound every number here, at the wire, so the view code
/// downstream only ever sees plausible values: an optional out of range reads as absent ("---" on
/// screen), a required one falls back to its neutral value.
///
/// Lives here and not in `PlausibleRange` because these are companion-wire quantities (indices,
/// chronometer seconds), not aviation ones; the aviation bounds are `PlausibleRange`'s own.
enum CompanionWireLimits {
    /// A waypoint or checklist index, and a count of either. No plan or phase comes anywhere near.
    static let maxIndex = 10_000
    /// A chronometer, a leg time or a route time, in seconds: a week.
    static let elapsedSeconds: ClosedRange<Double> = 0...604_800
    /// A leg or route distance in NM: a leg is under half the Earth, a route may go around it once.
    static let distanceNM: ClosedRange<Double> = 0...25_000
    /// A planned ground speed in knots, as a waypoint carries it and as the viewer may set it.
    static let groundSpeedKnots: ClosedRange<Int> = 1...1_000

    static func index(_ value: Int) -> Int {
        min(max(0, value), maxIndex)
    }

    static func bounded(_ value: Double?, in range: ClosedRange<Double>) -> Double? {
        guard let value, PlausibleRange.isPlausible(value, in: range) else { return nil }
        return value
    }

    static func bounded(_ value: Int?, in range: ClosedRange<Int>) -> Int? {
        guard let value, range.contains(value) else { return nil }
        return value
    }

    static func isValidCoordinate(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite
            && (-90.0...90.0).contains(latitude) && (-180.0...180.0).contains(longitude)
    }
}

// MARK: - Peer GPS (Viewer -> Master, when the master has no fix) — shared-GPS

/// A GPS fix streamed from the peer (the device that HAS a fix) up to the flight owner, so an owner
/// with no GPS of its own (e.g. a Wi-Fi-only iPad) can run the flight off the companion's location.
/// Raw sensor units (metres, m/s, degrees); the master converts for display. (v4.1 shared-GPS)
struct CompanionPeerGPS: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    let speedMPS: Double?
    let altitudeMeters: Double?
    let courseDegrees: Double?
    let horizontalAccuracy: Double   // metres; < 0 means invalid
    let signalStatus: String
    let timestamp: Date

    init(latitude: Double, longitude: Double, speedMPS: Double?, altitudeMeters: Double?,
         courseDegrees: Double?, horizontalAccuracy: Double, signalStatus: String, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.speedMPS = speedMPS
        self.altitudeMeters = altitudeMeters
        self.courseDegrees = courseDegrees
        self.horizontalAccuracy = horizontalAccuracy
        self.signalStatus = signalStatus
        self.timestamp = timestamp
    }

    /// Tolerant decoder so a field skew between independently-updated builds never drops the fix — EXCEPT
    /// latitude/longitude, which are required: a fix with no coordinates is useless, and defaulting them to
    /// 0 would inject a (0,0) "Null Island" position. Missing coordinates throw, so the call-site `try?`
    /// drops the message rather than borrowing a bogus fix. (shared-GPS)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        speedMPS = try c.decodeIfPresent(Double.self, forKey: .speedMPS)
        altitudeMeters = try c.decodeIfPresent(Double.self, forKey: .altitudeMeters)
        courseDegrees = try c.decodeIfPresent(Double.self, forKey: .courseDegrees)
        horizontalAccuracy = try c.decodeIfPresent(Double.self, forKey: .horizontalAccuracy) ?? -1
        signalStatus = try c.decodeIfPresent(String.self, forKey: .signalStatus) ?? "unknown"
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date.distantPast
    }

    /// Whether the fix is geometrically usable: finite, in-range coordinates and finite motion values.
    ///
    /// A paired peer is a network trust boundary — a device on an older or modified build, or simply a
    /// buggy one, can put anything on the wire. Every other ingest path in this codebase already
    /// validates (`Flight.validatedForIngest()`, `AirportDataService`, `Navaid`, `Obstacle`,
    /// `ReportingPoint`); the companion path was the one omission. Without this an out-of-range or
    /// non-finite coordinate reaches `MKCoordinateRegion` / `MKAnnotation`, and **MapKit raises on an
    /// invalid coordinate — i.e. the navigation display crashes mid-flight.** The same point is also
    /// appended to the recorded track, corrupting the flight file so that
    /// `Flight.validatedForIngest()` then rejects it on the pilot's other devices and it silently
    /// never syncs. (SA-10)
    ///
    /// Deliberately duplicates `GeoValidation.isValidLatLon` rather than calling it: that helper
    /// lives in `Models/Flight.swift`, which is app-target only, while this file is in `Shared/`
    /// (compiled into the Watch and Widget targets too). `testPeerFixGeometryMatchesFlightIngestPredicate`
    /// asserts the two agree, so the copy cannot silently drift.
    var hasValidGeometry: Bool {
        guard latitude.isFinite, longitude.isFinite,
              (-90.0...90.0).contains(latitude),
              (-180.0...180.0).contains(longitude) else { return false }
        // Optional motion values: absent is fine (they degrade to CoreLocation's "unknown"
        // sentinels), but a present value must be both finite AND physically plausible.
        //
        // SEC-C15: finiteness alone was not enough. A peer could send a finite-but-absurd
        // `speedMPS` (1e19 passes `.isFinite` and `>= 0`), which flowed through
        // `effectiveLocation` -> `injectCompanionLocation` -> `processLocation` and reached
        // `Int(displaySmoothedSpeedMPS * 1.94384)` in LocationManager — an unconditional Swift
        // TRAP that kills the app, in flight, from a nearby paired device. Short of that, a merely
        // implausible value (50 km altitude, Mach 9) was displayed on the master's instruments and
        // written into the recorded track as if it were a real fix. SA-10 closed the coordinate-NaN
        // hole but left the magnitude one open.
        if let altitudeMeters,
           !PlausibleRange.isPlausible(altitudeMeters, in: PlausibleRange.altitudeMeters) {
            return false
        }
        if let speedMPS,
           !PlausibleRange.isPlausible(speedMPS, in: PlausibleRange.speedMPS) {
            return false
        }
        if let courseDegrees,
           !PlausibleRange.isPlausible(courseDegrees, in: PlausibleRange.courseDegrees) {
            return false
        }
        return horizontalAccuracy.isFinite
    }
}

// MARK: - Viewer hello (Viewer -> Master, on connect) — SA-26

/// What the viewer tells the master about itself when the link comes up.
///
/// SA-26: the master streams the full challenge/response text of whatever checklist it is running.
/// Pairing is one system sheet and one confirmation code, after which the devices reconnect
/// automatically whenever in proximity — so without this, someone with no subscription could pair
/// to a subscriber's iPad once and then read the entire premium checklist, phase by phase, and
/// even drive it (`nextChecklistPhase`, `revealHiddenItems`) without touching the iPad. Proximity
/// to a subscriber substituted for a subscription.
///
/// This is defence in depth, not a server gap: the paid content is legitimately on the paying
/// device. A legitimate single user's iPhone shares the subscriber's Apple ID and reports
/// `isSubscribed: true`, so the normal second-screen workflow is unaffected.
///
/// Since the 2026-09 review (S9-30) the claim alone no longer decides: a bare boolean the peer
/// states about itself proves nothing, so the master also requires its OWN entitlement, and takes
/// either this claim or the pilot's Allow for the connection (see
/// `CompanionConnectivityManager.mayStreamItemText`). A master on 6.0 or older gates on the claim
/// alone, so the viewer keeps sending it, truthfully.
struct CompanionViewerHello: Codable, Equatable {
    /// Whether the viewer device itself holds a premium entitlement.
    let isSubscribed: Bool

    init(isSubscribed: Bool) {
        self.isSubscribed = isSubscribed
    }

    /// Tolerant decode, but note the DEFAULT IS FALSE: an older viewer that does not send this
    /// message, or a malformed one, is treated as unentitled and gets the redacted stream. Failing
    /// closed here costs an old viewer some text; failing open would defeat the whole check.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isSubscribed = try c.decodeIfPresent(Bool.self, forKey: .isSubscribed) ?? false
    }
}

// MARK: - Companion stream timing

/// One knob for the ~1 Hz companion stream's freshness/liveness window (seconds). The three uses are
/// intentionally coupled to that cadence so they can't drift apart: a borrowed peer GPS fix older than
/// this is stale (GPSSourceElection.maxFixAge), the link is treated as dropped if no traffic arrives
/// within it (CompanionConnectivityManager.receiveStaleAfter), and the viewer shows frozen-data once the
/// last flight-data is this old (CompanionFlightView.isDataStale). (companion v2)
enum CompanionTiming {
    static let streamStaleAfter: TimeInterval = 5
}

// MARK: - GPS source election — shared-GPS

/// Which GPS feeds the flight owner.
enum CompanionGPSSource: String, Equatable {
    case own    // the owner's own device fix
    case peer   // a companion's fix, borrowed over the link
    case none   // no usable fix anywhere
}

/// Pure, testable policy deciding the owner's effective GPS source: prefer the owner's OWN fix when it
/// is valid + fresh, otherwise a recent peer fix. The freshness window doubles as hysteresis — a fix
/// "stays valid" across a few missed updates, so the source doesn't flap on a momentary blip.
/// (v4.1 shared-GPS — runs below iOS 26, hence testable.)
struct GPSSourceElection {
    /// Max age (seconds) for a fix to still count as fresh — the shared companion-stream window.
    var maxFixAge: TimeInterval = CompanionTiming.streamStaleAfter
    /// Max horizontal accuracy (metres) for a fix to count as valid (a negative accuracy is invalid).
    var maxAccuracy: Double = 100

    func isValid(accuracy: Double?, age: TimeInterval?) -> Bool {
        guard let accuracy, accuracy.isFinite, accuracy >= 0, accuracy <= maxAccuracy,
              let age, age.isFinite, age >= 0, age <= maxFixAge else { return false }
        return true
    }

    /// Validity of a peer fix: the accuracy/age policy above PLUS the fix's own geometry.
    ///
    /// `isValid(accuracy:age:)` inspects only accuracy and age, so a peer could pair a plausible
    /// 10 m accuracy with a nonsense coordinate and be elected. Election is the last gate before
    /// `effectiveLocation` builds a `CLLocation` from the raw wire values and feeds it into the
    /// flight pipeline, so the geometry has to be checked here too. (SA-10)
    func isPeerFixValid(_ fix: CompanionPeerGPS?, age: TimeInterval?) -> Bool {
        guard let fix, fix.hasValidGeometry else { return false }
        return isValid(accuracy: fix.horizontalAccuracy, age: age)
    }

    /// Elect the source from the current validity of each side. Own always wins when valid.
    func elect(ownValid: Bool, peerValid: Bool) -> CompanionGPSSource {
        if ownValid { return .own }
        if peerValid { return .peer }
        return .none
    }
}

// MARK: - Flight Plan Snapshot (Master -> Viewer, on connect + on change)

/// Full flight plan state sent when companion connects or plan changes
struct CompanionFlightPlanSnapshot: Codable, Equatable {
    let planId: UUID
    let planName: String
    let waypoints: [CompanionWaypoint]
    let currentWaypointIndex: Int
    let totalDistance: Double
    let totalEET: TimeInterval
    let plannedDepartureTime: Date?
    let chronometerStartTime: Date?
    /// The aerodrome the master diverted to, when it did. Optional and last, so a viewer on an older
    /// build ignores it and a snapshot from an older master decodes as "no diversion". (v5.1)
    var diversion: CompanionWaypoint? = nil

    static func == (lhs: CompanionFlightPlanSnapshot, rhs: CompanionFlightPlanSnapshot) -> Bool {
        lhs.planId == rhs.planId &&
        lhs.waypoints.count == rhs.waypoints.count &&
        lhs.currentWaypointIndex == rhs.currentWaypointIndex &&
        lhs.diversion?.name == rhs.diversion?.name
    }
}

/// A waypoint in the companion flight plan snapshot
struct CompanionWaypoint: Codable, Identifiable {
    let id: UUID
    let name: String
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let frequency: String?
    let magneticCourse: Double?
    let distance: Double?
    let plannedGroundSpeed: Int?
    let estimatedElapsedTime: TimeInterval?
    let legEETExtra: TimeInterval?
    let cumulativeEET: TimeInterval?
    let estimatedTimeOver: Date?
    let actualTimeOver: Date?
    let remarks: String
}

extension CompanionFlightPlanSnapshot {
    /// The synthesised decoder's keys and strictness, with the numbers bounded (CompanionWireLimits).
    /// Declared in an extension so the sender's memberwise initialiser is preserved.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        planId = try c.decode(UUID.self, forKey: .planId)
        planName = try c.decode(String.self, forKey: .planName)
        waypoints = try c.decode([CompanionWaypoint].self, forKey: .waypoints)
        currentWaypointIndex = CompanionWireLimits.index(try c.decode(Int.self, forKey: .currentWaypointIndex))
        totalDistance = CompanionWireLimits.bounded(try c.decode(Double.self, forKey: .totalDistance),
                                                    in: CompanionWireLimits.distanceNM) ?? 0
        totalEET = CompanionWireLimits.bounded(try c.decode(TimeInterval.self, forKey: .totalEET),
                                               in: CompanionWireLimits.elapsedSeconds) ?? 0
        plannedDepartureTime = try c.decodeIfPresent(Date.self, forKey: .plannedDepartureTime)
        chronometerStartTime = try c.decodeIfPresent(Date.self, forKey: .chronometerStartTime)
        diversion = try c.decodeIfPresent(CompanionWaypoint.self, forKey: .diversion)
    }
}

extension CompanionWaypoint {
    /// Same keys and strictness as the synthesised decoder, numbers bounded (CompanionWireLimits).
    ///
    /// The coordinate is kept as sent: a waypoint cannot be dropped (the viewer sends indices back,
    /// `recordATO(waypointIndex:)`), so `hasValidCoordinate` tells the view whether to trust it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        altitude = CompanionWireLimits.bounded(try c.decodeIfPresent(Double.self, forKey: .altitude),
                                               in: PlausibleRange.altitudeFeet)
        frequency = try c.decodeIfPresent(String.self, forKey: .frequency)
        magneticCourse = CompanionWireLimits.bounded(try c.decodeIfPresent(Double.self, forKey: .magneticCourse),
                                                     in: PlausibleRange.courseDegrees)
        distance = CompanionWireLimits.bounded(try c.decodeIfPresent(Double.self, forKey: .distance),
                                               in: CompanionWireLimits.distanceNM)
        plannedGroundSpeed = CompanionWireLimits.bounded(try c.decodeIfPresent(Int.self, forKey: .plannedGroundSpeed),
                                                         in: CompanionWireLimits.groundSpeedKnots)
        estimatedElapsedTime = CompanionWireLimits.bounded(
            try c.decodeIfPresent(TimeInterval.self, forKey: .estimatedElapsedTime), in: CompanionWireLimits.elapsedSeconds)
        legEETExtra = CompanionWireLimits.bounded(
            try c.decodeIfPresent(TimeInterval.self, forKey: .legEETExtra), in: CompanionWireLimits.elapsedSeconds)
        cumulativeEET = CompanionWireLimits.bounded(
            try c.decodeIfPresent(TimeInterval.self, forKey: .cumulativeEET), in: CompanionWireLimits.elapsedSeconds)
        estimatedTimeOver = try c.decodeIfPresent(Date.self, forKey: .estimatedTimeOver)
        actualTimeOver = try c.decodeIfPresent(Date.self, forKey: .actualTimeOver)
        remarks = try c.decode(String.self, forKey: .remarks)
    }

    /// Whether the waypoint's coordinate can be navigated to (finite, in range).
    var hasValidCoordinate: Bool {
        CompanionWireLimits.isValidCoordinate(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Commands (Viewer -> Master)

/// Commands sent from iPhone companion to iPad master
enum CompanionCommand: Codable {
    case recordATO(waypointIndex: Int)
    case updateGroundSpeed(waypointIndex: Int, newGS: Int)
    case advanceWaypoint
    case goToPreviousWaypoint
    case startChronometer
    case resetChronometer
    case ping
    // Companion v2 — synced checklist control (the iPhone drives the iPad's shared checklist).
    case advanceChecklistItem
    case nextChecklistPhase
    case previousChecklistPhase
    case revealHiddenItems   // hold-to-reveal hidden (memorizable) items — reveals on BOTH devices
    // CHECK and DEFER as on the iPad (v6.0 review, decision 2). An older iPad can't decode these and
    // drops them, so the viewer only offers them when the snapshot says `supportsDefer`.
    case deferChecklistItem
    case checkDeferredItem(phaseRawValue: Int, itemId: String)
    // A deferred check run from the phone, and a tap on a checked row, as on the iPad (v6.0 review,
    // J1 and K-C). Same release as the two above, so `supportsDefer` covers them too.
    case checkInDeferredCheck(phaseRawValue: Int)
    case deferInDeferredCheck(phaseRawValue: Int)
    /// Reopens a checked item of the current phase alone, or checks it again. By id and phase, so a tap
    /// on a row the iPad has since moved past does nothing rather than toggle another item.
    case toggleChecklistItem(phaseRawValue: Int, itemId: String)
}

/// A check deferred whole (v6.0 review, J1): what the viewer's deferred list shows, and what it needs to
/// run it. The title and counts carry no checklist text and always go; the items, like the rest, only
/// to a viewer entitled to them (SA-26).
struct CompanionDeferredCheck: Codable, Equatable {
    let phaseRawValue: Int
    let phaseTitle: String
    let remaining: Int
    let total: Int
    let items: [CompanionChecklistItem]
    let highlightedIndex: Int
    let deferredItemIds: [String]
}

extension CompanionDeferredCheck {
    /// Same keys and strictness as the synthesised decoder, the counts bounded (CompanionWireLimits).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phaseRawValue = try c.decode(Int.self, forKey: .phaseRawValue)
        phaseTitle = try c.decode(String.self, forKey: .phaseTitle)
        remaining = CompanionWireLimits.index(try c.decode(Int.self, forKey: .remaining))
        total = CompanionWireLimits.index(try c.decode(Int.self, forKey: .total))
        items = try c.decode([CompanionChecklistItem].self, forKey: .items)
        highlightedIndex = CompanionWireLimits.index(try c.decode(Int.self, forKey: .highlightedIndex))
        deferredItemIds = try c.decode([String].self, forKey: .deferredItemIds)
    }
}

/// One phase's deferred items, for the viewer's deferred list. Sent only to a viewer entitled to the
/// checklist's text (SA-26). (v6.0 review, decision 2)
struct CompanionDeferredGroup: Codable, Equatable {
    let phaseRawValue: Int
    let phaseTitle: String
    let items: [CompanionChecklistItem]
}

// MARK: - Checklist Snapshot (Master -> Viewer)

/// A single checklist line, mirrored to the viewer for display.
struct CompanionChecklistItem: Codable, Identifiable, Equatable {
    let id: String
    let challenge: String
    let response: String
    let isHeader: Bool
}

/// The master's current checklist phase + its visible items + which item is highlighted, so the iPhone
/// can show and advance the same checklist the iPad is on. (companion v2 — synced checklist)
struct CompanionChecklistSnapshot: Codable, Equatable {
    let phaseTitle: String        // e.g. "Preflight Check"
    let phaseRawValue: Int        // ChecklistPhase.rawValue, for ordering/skip awareness
    let highlightedIndex: Int     // index into `items` of the currently highlighted line
    let visibleCount: Int         // number of non-header items (for "x / y" progress)
    let completedCount: Int       // how many items have been worked through
    let items: [CompanionChecklistItem]
    /// Count of memorizable items currently HIDDEN (learning mode off, not yet revealed). > 0 → the
    /// viewer shows the same "Hidden Checklist Content" placeholder as the iPad. 0 once revealed.
    /// (companion v2 — hidden-content parity)
    let hiddenItemCount: Int
    /// The items of this phase deferred rather than checked, so the viewer draws them as the iPad
    /// does instead of as done. (v6.0 review, B2)
    let deferredItemIds: [String]
    /// Every deferred item still to check, all phases together: the iPad's deferred-items row.
    let deferredItemCount: Int
    /// The deferred items themselves, by phase, so the viewer can list and check them. Empty for a
    /// viewer not entitled to the text. (v6.0 review, decision 2)
    let deferredGroups: [CompanionDeferredGroup]
    /// Items of this phase not checked yet, for the viewer's review before NEXT (the count also goes to
    /// an unentitled viewer, which has no item text to list).
    let openItemCount: Int
    /// This iPad takes `deferChecklistItem`, `checkDeferredItem` and the deferred-check and toggle
    /// commands. False from an older iPad, which never sends the field. (v6.0 review, decision 2)
    let supportsDefer: Bool
    /// Checks deferred whole, in flight order. (v6.0 review, J1)
    let deferredChecks: [CompanionDeferredCheck]

    init(phaseTitle: String, phaseRawValue: Int, highlightedIndex: Int, visibleCount: Int,
         completedCount: Int, items: [CompanionChecklistItem], hiddenItemCount: Int,
         deferredItemIds: [String] = [], deferredItemCount: Int = 0,
         deferredGroups: [CompanionDeferredGroup] = [], openItemCount: Int = 0, supportsDefer: Bool = false,
         deferredChecks: [CompanionDeferredCheck] = []) {
        self.phaseTitle = phaseTitle
        self.phaseRawValue = phaseRawValue
        self.highlightedIndex = highlightedIndex
        self.visibleCount = visibleCount
        self.completedCount = completedCount
        self.items = items
        self.hiddenItemCount = hiddenItemCount
        self.deferredItemIds = deferredItemIds
        self.deferredItemCount = deferredItemCount
        self.deferredGroups = deferredGroups
        self.openItemCount = openItemCount
        self.supportsDefer = supportsDefer
        self.deferredChecks = deferredChecks
    }

    /// Tolerant decoder: every field defaults so a field skew between independently-updated builds never
    /// drops the checklist update. (ARCH — versioned contract) The index and the counts are bounded
    /// like the rest of the master's stream (CompanionWireLimits).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let index = CompanionWireLimits.index
        phaseTitle = try c.decodeIfPresent(String.self, forKey: .phaseTitle) ?? ""
        phaseRawValue = try c.decodeIfPresent(Int.self, forKey: .phaseRawValue) ?? 0
        highlightedIndex = index(try c.decodeIfPresent(Int.self, forKey: .highlightedIndex) ?? 0)
        visibleCount = index(try c.decodeIfPresent(Int.self, forKey: .visibleCount) ?? 0)
        completedCount = index(try c.decodeIfPresent(Int.self, forKey: .completedCount) ?? 0)
        items = try c.decodeIfPresent([CompanionChecklistItem].self, forKey: .items) ?? []
        hiddenItemCount = index(try c.decodeIfPresent(Int.self, forKey: .hiddenItemCount) ?? 0)
        // Absent from an iPad on 5.x or 6.0: nothing deferred, as that iPad knew no better.
        deferredItemIds = try c.decodeIfPresent([String].self, forKey: .deferredItemIds) ?? []
        deferredItemCount = index(try c.decodeIfPresent(Int.self, forKey: .deferredItemCount) ?? 0)
        deferredGroups = try c.decodeIfPresent([CompanionDeferredGroup].self, forKey: .deferredGroups) ?? []
        openItemCount = index(try c.decodeIfPresent(Int.self, forKey: .openItemCount) ?? 0)
        supportsDefer = try c.decodeIfPresent(Bool.self, forKey: .supportsDefer) ?? false
        deferredChecks = try c.decodeIfPresent([CompanionDeferredCheck].self, forKey: .deferredChecks) ?? []
    }
}
