import Foundation

/// Represents an aircraft type with its associated checklist and metadata
enum AircraftType: String, CaseIterable, Identifiable, Codable {
    case wt9Dynamic = "WT9"
    case pa28Archer = "PA28"

    var id: String { rawValue }

    /// Aircraft registration
    var registration: String {
        switch self {
        case .wt9Dynamic: return "F-HVXA"
        case .pa28Archer: return "HB-PFA"
        }
    }

    /// Full aircraft model name
    var modelName: String {
        switch self {
        case .wt9Dynamic: return "WT9 Dynamic"
        case .pa28Archer: return "Piper Archer II PA-28-181"
        }
    }

    /// Short model name for display
    var shortModelName: String {
        switch self {
        case .wt9Dynamic: return "WT9 Dynamic"
        case .pa28Archer: return "PA-28-181"
        }
    }

    /// Checklist version
    var checklistVersion: String {
        switch self {
        case .wt9Dynamic: return "2.1e"
        case .pa28Archer: return "1.6e"
        }
    }

    /// Last updated date
    var lastUpdated: String {
        switch self {
        case .wt9Dynamic: return "March 2025"
        case .pa28Archer: return "July 2020"
        }
    }

    /// Stall speed (clean) for speed indicator warnings
    var stallSpeed: Int {
        switch self {
        case .wt9Dynamic: return 42
        case .pa28Archer: return 53
        }
    }

    /// Number of checklist pages
    var pageCount: Int {
        switch self {
        case .wt9Dynamic: return 4
        case .pa28Archer: return 4
        }
    }

    /// Get items for a specific phase
    func items(for phase: ChecklistPhase) -> [ChecklistItem] {
        switch self {
        case .wt9Dynamic:
            return WT9ChecklistData.items(for: phase)
        case .pa28Archer:
            return PA28ChecklistData.items(for: phase)
        }
    }

    /// Get learning mode visible count for a phase
    func learningModeVisibleCount(for phase: ChecklistPhase) -> Int? {
        switch self {
        case .wt9Dynamic:
            return WT9ChecklistData.learningModeVisibleCount(for: phase)
        case .pa28Archer:
            return PA28ChecklistData.learningModeVisibleCount(for: phase)
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
        case .pa28Archer:
            return PA28ChecklistData.targetSpeed(for: phase)
        }
    }

    /// Get speed reference data
    var speeds: [SpeedReference] {
        switch self {
        case .wt9Dynamic:
            return WT9ChecklistData.speeds
        case .pa28Archer:
            return PA28ChecklistData.speeds
        }
    }

    /// Get crosswind limits
    var crosswindLimits: (takeoff: String, landing: String) {
        switch self {
        case .wt9Dynamic:
            return ("14 kt", "16 kt")
        case .pa28Archer:
            return ("17 kt", "17 kt")
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
