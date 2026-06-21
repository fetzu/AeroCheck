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
}

/// User-facing role setting
enum CompanionRoleSetting: String, Codable, CaseIterable, Identifiable {
    case auto = "Auto"
    case primary = "Primary"
    case companion = "Companion"

    var id: String { rawValue }

    func resolvedRole(for idiom: UIUserInterfaceIdiom) -> CompanionRole {
        switch self {
        case .auto:
            return idiom == .pad ? .master : .viewer
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
        case command          // Viewer -> Master
        case disconnect       // Either direction (graceful)
        case peerGPS          // Viewer -> Master (the peer's GPS fix, when the master has none) — shared-GPS
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
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        speedMPS = try c.decodeIfPresent(Double.self, forKey: .speedMPS)
        altitudeFeet = try c.decodeIfPresent(Double.self, forKey: .altitudeFeet)
        courseDegrees = try c.decodeIfPresent(Double.self, forKey: .courseDegrees)
        gpsSignalStatus = try c.decodeIfPresent(String.self, forKey: .gpsSignalStatus) ?? "unknown"
        // Default true: a pre-shared-GPS master is assumed to have its own fix, so a viewer won't try to
        // source GPS for it. (v4.1 shared-GPS — backward-compatible)
        ownGPSAvailable = try c.decodeIfPresent(Bool.self, forKey: .ownGPSAvailable) ?? true
        // Clamp a peer-supplied index to >= 0 so it can never become a negative array subscript on
        // the receiver (the upper bound is checked per-use against the actual waypoint count).
        currentWaypointIndex = max(0, try c.decodeIfPresent(Int.self, forKey: .currentWaypointIndex) ?? 0)
        chronometerStartTime = try c.decodeIfPresent(Date.self, forKey: .chronometerStartTime)
        chronometerElapsed = try c.decodeIfPresent(TimeInterval.self, forKey: .chronometerElapsed) ?? 0
        aircraftRegistration = try c.decodeIfPresent(String.self, forKey: .aircraftRegistration) ?? ""
        aircraftType = try c.decodeIfPresent(String.self, forKey: .aircraftType) ?? ""
        // Absent timestamp -> distantPast so a malformed update reads as stale, never as "fresh now".
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date.distantPast
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

    /// Tolerant decoder so a field skew between independently-updated builds never drops the fix.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude) ?? 0
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude) ?? 0
        speedMPS = try c.decodeIfPresent(Double.self, forKey: .speedMPS)
        altitudeMeters = try c.decodeIfPresent(Double.self, forKey: .altitudeMeters)
        courseDegrees = try c.decodeIfPresent(Double.self, forKey: .courseDegrees)
        horizontalAccuracy = try c.decodeIfPresent(Double.self, forKey: .horizontalAccuracy) ?? -1
        signalStatus = try c.decodeIfPresent(String.self, forKey: .signalStatus) ?? "unknown"
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date.distantPast
    }
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
    /// Max age (seconds) for a fix to still count as fresh.
    var maxFixAge: TimeInterval = 5
    /// Max horizontal accuracy (metres) for a fix to count as valid (a negative accuracy is invalid).
    var maxAccuracy: Double = 100

    func isValid(accuracy: Double?, age: TimeInterval?) -> Bool {
        guard let accuracy, accuracy >= 0, accuracy <= maxAccuracy,
              let age, age >= 0, age <= maxFixAge else { return false }
        return true
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

    static func == (lhs: CompanionFlightPlanSnapshot, rhs: CompanionFlightPlanSnapshot) -> Bool {
        lhs.planId == rhs.planId &&
        lhs.waypoints.count == rhs.waypoints.count &&
        lhs.currentWaypointIndex == rhs.currentWaypointIndex
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
}
