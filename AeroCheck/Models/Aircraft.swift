import Foundation

/// Represents a bundled aircraft type with its associated checklist and metadata.
/// Only the WT9 Dynamic is bundled with the app. Other aircraft (like PA-28-181)
/// are available through the AeroCheck Pro subscription and delivered via the API.
enum AircraftType: String, CaseIterable, Identifiable, Codable {
    case wt9Dynamic = "WT9"

    var id: String { rawValue }

    /// Aircraft registration
    var registration: String {
        switch self {
        case .wt9Dynamic: return "F-HVXA"
        }
    }

    /// Full aircraft model name
    var modelName: String {
        switch self {
        case .wt9Dynamic: return "WT9 Dynamic"
        }
    }

    /// Short model name for display
    var shortModelName: String {
        switch self {
        case .wt9Dynamic: return "WT9 Dynamic"
        }
    }

    /// Checklist version (sourced from checklist data files)
    var checklistVersion: String {
        switch self {
        case .wt9Dynamic: return WT9ChecklistData.version
        }
    }

    /// Last updated date (sourced from checklist data files)
    var lastUpdated: String {
        switch self {
        case .wt9Dynamic: return WT9ChecklistData.lastUpdated
        }
    }

    /// Available checklist languages
    var checklistLanguages: [String] {
        switch self {
        case .wt9Dynamic: return BundledChecklistService.availableLanguages(for: "wt9-dynamic")
        }
    }

    /// Stall speed (clean) for speed indicator warnings
    var stallSpeed: Int {
        switch self {
        case .wt9Dynamic: return 42
        }
    }

    /// Number of checklist pages
    var pageCount: Int {
        switch self {
        case .wt9Dynamic: return 4
        }
    }

    /// Get items for a specific phase
    func items(for phase: ChecklistPhase) -> [ChecklistItem] {
        switch self {
        case .wt9Dynamic:
            return WT9ChecklistData.items(for: phase)
        }
    }

    /// Get learning mode visible count for a phase
    func learningModeVisibleCount(for phase: ChecklistPhase) -> Int? {
        switch self {
        case .wt9Dynamic:
            return WT9ChecklistData.learningModeVisibleCount(for: phase)
        }
    }

    /// Get visible items based on learning mode
    func visibleItems(for phase: ChecklistPhase, learningMode: Bool) -> [ChecklistItem] {
        let allItems = items(for: phase)

        // Learning mode ON = show everything for studying
        if learningMode {
            return allItems
        }

        // Learning mode OFF = hide memorizable items to test memory
        guard let visibleCount = learningModeVisibleCount(for: phase) else {
            return allItems
        }

        if visibleCount == 0 {
            return []
        }

        return Array(allItems.prefix(visibleCount))
    }

    /// Get visible item count for a phase
    func visibleItemCount(for phase: ChecklistPhase, learningMode: Bool) -> Int {
        if learningMode {
            return items(for: phase).count
        }

        if let count = learningModeVisibleCount(for: phase) {
            return count
        }
        return items(for: phase).count
    }

    /// Whether a phase has hidden items when learning mode is OFF
    func hasHiddenItems(for phase: ChecklistPhase, learningMode: Bool) -> Bool {
        if learningMode {
            return false
        }
        return learningModeVisibleCount(for: phase) != nil
    }

    /// Get target speed for a phase
    func targetSpeed(for phase: ChecklistPhase) -> Int? {
        switch self {
        case .wt9Dynamic:
            return WT9ChecklistData.targetSpeed(for: phase)
        }
    }

    /// Get speed reference data
    var speeds: [SpeedReference] {
        switch self {
        case .wt9Dynamic:
            return WT9ChecklistData.speeds
        }
    }

    /// Get crosswind limits
    var crosswindLimits: (takeoff: String, landing: String) {
        switch self {
        case .wt9Dynamic:
            return ("14 kt", "16 kt")
        }
    }

    /// Total checklist items count
    var totalChecklistItems: Int {
        ChecklistPhase.allCases.reduce(0) { count, phase in
            count + items(for: phase).count
        }
    }
}

/// Speed reference data
struct SpeedReference: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let value: String
}
