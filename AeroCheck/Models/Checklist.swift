import Foundation

/// Represents a flight phase with its associated checklist
enum ChecklistPhase: Int, CaseIterable, Identifiable, Codable {
    case preflight = 0
    case beforeEngineStart
    case engineStart
    case afterEngineStart
    case taxi
    case runup
    case beforeDeparture
    case lineUp
    case climb
    case cruise
    case descent
    case approach
    case landing
    case afterLanding
    case shutdown
    case hangar
    
    var id: Int { rawValue }
    
    var title: String {
        switch self {
        case .preflight: return L10n.Phase.preflight
        case .beforeEngineStart: return L10n.Phase.beforeEngineStart
        case .engineStart: return L10n.Phase.engineStart
        case .afterEngineStart: return L10n.Phase.afterEngineStart
        case .taxi: return L10n.Phase.taxi
        case .runup: return L10n.Phase.runup
        case .beforeDeparture: return L10n.Phase.beforeDeparture
        case .lineUp: return L10n.Phase.lineUp
        case .climb: return L10n.Phase.climb
        case .cruise: return L10n.Phase.cruise
        case .descent: return L10n.Phase.descent
        case .approach: return L10n.Phase.approach
        case .landing: return L10n.Phase.landing
        case .afterLanding: return L10n.Phase.afterLanding
        case .shutdown: return L10n.Phase.shutdown
        case .hangar: return L10n.Phase.hangar
        }
    }
    
    var pageNumber: Int {
        switch self {
        case .preflight, .beforeEngineStart, .engineStart: return 1
        case .afterEngineStart, .taxi, .runup, .beforeDeparture: return 2
        case .lineUp, .climb, .cruise, .descent, .approach, .landing: return 3
        case .afterLanding, .shutdown, .hangar: return 4
        }
    }
    
    var completionText: String {
        switch self {
        case .hangar:
            return ""
        default:
            return L10n.Phase.completed(shortTitle)
        }
    }
    
    var shortTitle: String {
        switch self {
        case .preflight: return L10n.Phase.Short.preflight
        case .beforeEngineStart: return L10n.Phase.Short.beforeEngineStart
        case .engineStart: return L10n.Phase.Short.engineStart
        case .afterEngineStart: return L10n.Phase.Short.afterEngineStart
        case .taxi: return L10n.Phase.Short.taxi
        case .runup: return L10n.Phase.Short.runup
        case .beforeDeparture: return L10n.Phase.Short.beforeDeparture
        case .lineUp: return L10n.Phase.Short.lineUp
        case .climb: return L10n.Phase.Short.climb
        case .cruise: return L10n.Phase.Short.cruise
        case .descent: return L10n.Phase.Short.descent
        case .approach: return L10n.Phase.Short.approach
        case .landing: return L10n.Phase.Short.landing
        case .afterLanding: return L10n.Phase.Short.afterLanding
        case .shutdown: return L10n.Phase.Short.shutdown
        case .hangar: return L10n.Phase.Short.hangar
        }
    }
    
    /// Whether this phase shows the "Engine Start" button
    var showsEngineStartButton: Bool {
        self == .engineStart
    }
    
    /// Whether this phase shows the "Ready for Line Up" button
    var showsLineUpButton: Bool {
        self == .beforeDeparture
    }
    
    /// Whether this phase shows the "Engine Shutdown" button
    var showsEngineShutdownButton: Bool {
        self == .shutdown
    }

    /// Whether this phase shows the "Go Around" and "Touch-and-Go" buttons
    var showsGoAroundButtons: Bool {
        self == .landing
    }

    /// Whether this phase shows the "Landed" button
    var showsLandedButton: Bool {
        self == .afterLanding
    }
    
    /// Target speed for the phase (nil means no speed display, e.g. during taxi)
    /// Now delegates to aircraft-specific data
    var targetSpeed: Int? {
        ChecklistData.currentAircraft.targetSpeed(for: self)
    }

    /// Whether this phase should show the speed indicator
    var showsSpeedIndicator: Bool {
        targetSpeed != nil
    }
    
    /// Whether this phase has an interactive briefing
    var hasBriefing: Bool {
        switch self {
        case .beforeDeparture, .descent:
            return true
        default:
            return false
        }
    }
    
    /// Briefing type for this phase
    var briefingType: BriefingType? {
        switch self {
        case .beforeDeparture:
            return .departure
        case .descent:
            return .approach
        default:
            return nil
        }
    }
    
    /// Notes or briefing text to show before the checklist
    var briefingText: String? {
        switch self {
        case .beforeDeparture:
            return L10n.Briefing.departure
        case .descent:
            return L10n.Briefing.approach
        default:
            return nil
        }
    }
}

/// Briefing types
enum BriefingType {
    case departure
    case approach
}

/// A single checklist item
struct ChecklistItem: Identifiable {
    let id = UUID()
    let number: Int?
    let challenge: String
    let response: String
    let isHeader: Bool
    
    init(number: Int? = nil, challenge: String, response: String = "", isHeader: Bool = false) {
        self.number = number
        self.challenge = challenge
        self.response = response
        self.isHeader = isHeader
    }
}

/// Bridge to checklist data - delegates to appropriate aircraft type
/// This maintains backward compatibility with existing code
///
/// Thread Safety: The currentAircraft property uses nonisolated(unsafe) to allow
/// access from non-main-actor contexts (like ChecklistPhase computed properties).
/// This is safe because:
/// 1. Writes only happen from AppState.syncAircraftType() on the main actor
/// 2. The value is an enum (value type) so reads are atomic
/// 3. A stale read during aircraft switch is acceptable (UI will update immediately)
struct ChecklistData {
    /// Current aircraft type (synced from AppState.settings.selectedAircraft)
    /// Only mutate this from AppState.syncAircraftType()
    nonisolated(unsafe) static var currentAircraft: AircraftType = .wt9Dynamic

    /// Current remote aircraft checklist (if a remote aircraft is selected)
    /// Only mutate this from AppState
    nonisolated(unsafe) static var currentRemoteChecklist: RemoteAircraftChecklist? = nil

    /// True when a remote (premium) aircraft is selected, so a remote checklist is expected.
    /// When this is set but `currentRemoteChecklist` is nil (the load failed), ChecklistData
    /// must NOT fall back to the bundled WT9 content — a premium flight must never display the
    /// wrong aircraft's items. Flight start is also blocked in this state. (ARCH-01)
    nonisolated(unsafe) static var expectsRemoteChecklist: Bool = false

    /// True when a remote checklist is expected but hasn't resolved (load failed/pending).
    static var isAwaitingUnresolvedRemoteChecklist: Bool {
        expectsRemoteChecklist && currentRemoteChecklist == nil
    }

    static func items(for phase: ChecklistPhase) -> [ChecklistItem] {
        if let remote = currentRemoteChecklist {
            return remote.items(for: phase)
        }
        // Never serve bundled WT9 items when a premium checklist was expected. (ARCH-01)
        if expectsRemoteChecklist { return [] }
        return currentAircraft.items(for: phase)
    }

    // MARK: - Learning Mode Support

    static func learningModeVisibleCount(for phase: ChecklistPhase) -> Int? {
        if let remote = currentRemoteChecklist {
            return remote.learningModeVisibleCount(for: phase)
        }
        if expectsRemoteChecklist { return nil }
        return currentAircraft.learningModeVisibleCount(for: phase)
    }

    static func visibleItems(for phase: ChecklistPhase, learningMode: Bool) -> [ChecklistItem] {
        if let remote = currentRemoteChecklist {
            return remote.visibleItems(for: phase, learningMode: learningMode)
        }
        if expectsRemoteChecklist { return [] }
        return currentAircraft.visibleItems(for: phase, learningMode: learningMode)
    }

    static func visibleItemCount(for phase: ChecklistPhase, learningMode: Bool) -> Int {
        if let remote = currentRemoteChecklist {
            let items = remote.items(for: phase)
            if learningMode {
                return items.count
            }
            if let count = remote.learningModeVisibleCount(for: phase) {
                return count
            }
            return items.count
        }
        return currentAircraft.visibleItemCount(for: phase, learningMode: learningMode)
    }

    static func hasHiddenItems(for phase: ChecklistPhase, learningMode: Bool) -> Bool {
        if learningMode {
            return false
        }
        if let remote = currentRemoteChecklist {
            return remote.learningModeVisibleCount(for: phase) != nil
        }
        return currentAircraft.hasHiddenItems(for: phase, learningMode: learningMode)
    }

    /// Get the registration of the current aircraft (remote or bundled)
    static var currentAircraftRegistration: String {
        if let remote = currentRemoteChecklist {
            return remote.registration
        }
        return currentAircraft.registration
    }
}
