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

    // GPS data (from iPad's LocationManager)
    let latitude: Double?
    let longitude: Double?
    let speedMPS: Double?
    let altitudeFeet: Double?
    let courseDegrees: Double?
    let gpsSignalStatus: String

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
