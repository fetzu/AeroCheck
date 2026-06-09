import Foundation

/// Data structure for syncing flight state to Apple Watch
/// This is a lightweight representation optimized for Watch Connectivity transfer.
///
/// **Versioned, tolerant contract.** The iPhone app and the Watch app ship and update
/// independently, so a payload is routinely produced by a *different* build than the one decoding
/// it. `schemaVersion` lets a receiver detect/adapt to skew, and the custom `init(from:)` decodes
/// every field with a default — so adding or removing a field never makes the other side throw and
/// silently drop the whole flight update. Bump `currentSchemaVersion` only when the *meaning* of an
/// existing field changes; purely additive fields don't need a bump. (ARCH — versioned contract)
struct WatchFlightData: Codable {
    /// Current wire-format version produced by this build.
    static let currentSchemaVersion = 1
    /// Version of the payload as decoded (0 if the sender predates versioning).
    var schemaVersion: Int = WatchFlightData.currentSchemaVersion

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
        self.schemaVersion = WatchFlightData.currentSchemaVersion
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

    /// Tolerant decoder: every field is optional-with-default so a payload from a different app
    /// version (a field added, removed, or renamed) still decodes to a usable struct instead of
    /// throwing and dropping the whole update. (ARCH — versioned connectivity contract)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 0 marks a pre-versioning sender — the receiver can fall back to legacy assumptions.
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        isFlightActive = try c.decodeIfPresent(Bool.self, forKey: .isFlightActive) ?? false
        isCircuitMode = try c.decodeIfPresent(Bool.self, forKey: .isCircuitMode) ?? false
        currentPhaseRawValue = try c.decodeIfPresent(Int.self, forKey: .currentPhaseRawValue) ?? 0
        currentPhaseName = try c.decodeIfPresent(String.self, forKey: .currentPhaseName) ?? "PREFLIGHT"
        nextPhaseName = try c.decodeIfPresent(String.self, forKey: .nextPhaseName)
        lineUpTime = try c.decodeIfPresent(Date.self, forKey: .lineUpTime)
        landingTime = try c.decodeIfPresent(Date.self, forKey: .landingTime)
        alwaysUseUTC = try c.decodeIfPresent(Bool.self, forKey: .alwaysUseUTC) ?? false
        speedMPS = try c.decodeIfPresent(Double.self, forKey: .speedMPS)
        altitudeFeet = try c.decodeIfPresent(Double.self, forKey: .altitudeFeet)
        course = try c.decodeIfPresent(Double.self, forKey: .course)
        hasActiveNavPlan = try c.decodeIfPresent(Bool.self, forKey: .hasActiveNavPlan) ?? false
        currentWaypointName = try c.decodeIfPresent(String.self, forKey: .currentWaypointName)
        currentWaypointIndex = try c.decodeIfPresent(Int.self, forKey: .currentWaypointIndex)
        totalWaypoints = try c.decodeIfPresent(Int.self, forKey: .totalWaypoints)
        distanceToWaypointNM = try c.decodeIfPresent(Double.self, forKey: .distanceToWaypointNM)
        bearingToWaypoint = try c.decodeIfPresent(Double.self, forKey: .bearingToWaypoint)
        eetToWaypointSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .eetToWaypointSeconds)
        currentWaypointFrequency = try c.decodeIfPresent(String.self, forKey: .currentWaypointFrequency)
        nextWaypointFrequency = try c.decodeIfPresent(String.self, forKey: .nextWaypointFrequency)
        commonFrequencies = try c.decodeIfPresent([FrequencyInfo].self, forKey: .commonFrequencies)
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
