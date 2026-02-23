import Foundation

// MARK: - iOS-only types (not needed on watchOS)

#if !os(watchOS)
import UIKit

/// Connection state for companion mode
enum CompanionConnectionState: Equatable {
    case disconnected
    case searching       // iPhone: browsing for iPad
    case advertising     // iPad: waiting for iPhone
    case connecting      // Handshake in progress
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

/// A discovered peer available for connection
struct DiscoveredPeer: Identifiable, Equatable {
    let id: UUID
    let name: String
    let endpoint: String  // Serialized endpoint description for display

    static func == (lhs: DiscoveredPeer, rhs: DiscoveredPeer) -> Bool {
        lhs.id == rhs.id
    }
}

/// Exchanged on initial connection to identify devices
struct CompanionHandshake: Codable {
    let deviceName: String
    let appVersion: String
    let role: CompanionRole
    let sessionId: UUID?  // Non-nil when reconnecting to existing session
}
#endif

// MARK: - Wire Protocol

/// Wrapper for all messages sent between devices
struct CompanionMessage: Codable {
    enum MessageType: String, Codable {
        case flightData       // Master → Viewer (periodic 1Hz)
        case flightPlanUpdate // Master → Viewer (on change)
        case command          // Viewer → Master
        case handshake        // Bidirectional (initial connection)
        case disconnect       // Either direction (graceful)
    }

    let type: MessageType
    let payload: Data     // JSON-encoded inner type
    let timestamp: Date

    init(type: MessageType, payload: Data) {
        self.type = type
        self.payload = payload
        self.timestamp = Date()
    }
}

// MARK: - Flight Data (Master → Viewer, 1Hz)

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

    // Navigation state (lightweight — full plan sent separately)
    let currentWaypointIndex: Int
    let chronometerStartTime: Date?
    let chronometerElapsed: TimeInterval

    // Aircraft info
    let aircraftRegistration: String
    let aircraftType: String

    // Timestamp for staleness detection
    let timestamp: Date
}

// MARK: - Flight Plan Snapshot (Master → Viewer, on connect + on change)

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

// MARK: - Commands (Viewer → Master)

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

