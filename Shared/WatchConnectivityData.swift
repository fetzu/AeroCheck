import Foundation

/// Data structure for syncing flight state to Apple Watch
/// This is a lightweight representation optimized for Watch Connectivity transfer
struct WatchFlightData: Codable {
    // Flight status
    var isFlightActive: Bool
    var isCircuitMode: Bool

    // Current phase
    var currentPhaseRawValue: Int
    var currentPhaseName: String
    var nextPhaseName: String?

    // Timing
    var lineUpTime: Date?
    var landingTime: Date?

    // Settings
    var alwaysUseUTC: Bool

    // GPS data
    var speedMPS: Double?
    var altitudeFeet: Double?
    var course: Double?

    // Navigation plan (when active)
    var hasActiveNavPlan: Bool
    var currentWaypointName: String?
    var currentWaypointIndex: Int?
    var totalWaypoints: Int?
    var distanceToWaypointNM: Double?
    var bearingToWaypoint: Double?
    var eetToWaypointSeconds: TimeInterval?

    // Frequencies
    var currentWaypointFrequency: String?
    var nextWaypointFrequency: String?
    var commonFrequencies: [FrequencyInfo]?

    init() {
        self.isFlightActive = false
        self.isCircuitMode = false
        self.currentPhaseRawValue = 0
        self.currentPhaseName = "PREFLIGHT"
        self.nextPhaseName = nil
        self.lineUpTime = nil
        self.landingTime = nil
        self.alwaysUseUTC = false
        self.speedMPS = nil
        self.altitudeFeet = nil
        self.course = nil
        self.hasActiveNavPlan = false
        self.currentWaypointName = nil
        self.currentWaypointIndex = nil
        self.totalWaypoints = nil
        self.distanceToWaypointNM = nil
        self.bearingToWaypoint = nil
        self.eetToWaypointSeconds = nil
        self.currentWaypointFrequency = nil
        self.nextWaypointFrequency = nil
        self.commonFrequencies = nil
    }
}

/// Frequency information for Watch display
struct FrequencyInfo: Codable, Identifiable {
    var id: String { name }
    let name: String
    let frequency: String
    let type: FrequencyType

    enum FrequencyType: String, Codable {
        case tower
        case approach
        case ground
        case info
        case common
        case waypoint
    }
}

/// Messages from iPhone to Watch
enum WatchMessage: String {
    case flightStarted = "flightStarted"
    case flightEnded = "flightEnded"
    case dataUpdate = "dataUpdate"
    case launchApp = "launchApp"
}

/// Watch connectivity keys
struct WatchConnectivityKeys {
    static let messageType = "messageType"
    static let flightData = "flightData"
    static let timestamp = "timestamp"
}
