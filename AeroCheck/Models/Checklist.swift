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
        case .preflight: return "PREFLIGHT CHECK"
        case .beforeEngineStart: return "CHECK BEFORE ENGINE START"
        case .engineStart: return "ENGINE START"
        case .afterEngineStart: return "CHECK AFTER ENGINE START"
        case .taxi: return "TAXI CHECK"
        case .runup: return "RUNUP"
        case .beforeDeparture: return "CHECK BEFORE DEPARTURE"
        case .lineUp: return "LINE UP CHECK"
        case .climb: return "CLIMB CHECK"
        case .cruise: return "CRUISE CHECK"
        case .descent: return "DESCENT CHECK"
        case .approach: return "APPROACH CHECK"
        case .landing: return "LANDING CHECK"
        case .afterLanding: return "AFTER LANDING CHECK"
        case .shutdown: return "ENGINE SHUTDOWN AND PARKING CHECK"
        case .hangar: return "AT THE HANGAR"
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
            return "\(shortTitle) COMPLETED"
        }
    }
    
    var shortTitle: String {
        switch self {
        case .preflight: return "PREFLIGHT CHECK"
        case .beforeEngineStart: return "CHECK BEFORE ENGINE START"
        case .engineStart: return "ENGINE START"
        case .afterEngineStart: return "CHECK AFTER ENGINE START"
        case .taxi: return "TAXI CHECK"
        case .runup: return "RUNUP"
        case .beforeDeparture: return "CHECK BEFORE DEPARTURE"
        case .lineUp: return "LINE UP CHECK"
        case .climb: return "CLIMB CHECK"
        case .cruise: return "CRUISE CHECK"
        case .descent: return "DESCENT CHECK"
        case .approach: return "APPROACH CHECK"
        case .landing: return "LANDING CHECK"
        case .afterLanding: return "AFTER LANDING CHECK"
        case .shutdown: return "PARKING CHECK"
        case .hangar: return "AT THE HANGAR"
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
            return "*** Departure briefing *** (tap to view)"
        case .descent:
            return "*** Approach briefing *** (tap to view)"
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
struct ChecklistData {
    /// Current aircraft type (should be set from AppState)
    static var currentAircraft: AircraftType = .wt9Dynamic

    static func items(for phase: ChecklistPhase) -> [ChecklistItem] {
        currentAircraft.items(for: phase)
    }

    // MARK: - Learning Mode Support

    static func learningModeVisibleCount(for phase: ChecklistPhase) -> Int? {
        currentAircraft.learningModeVisibleCount(for: phase)
    }

    static func visibleItems(for phase: ChecklistPhase, learningMode: Bool) -> [ChecklistItem] {
        currentAircraft.visibleItems(for: phase, learningMode: learningMode)
    }

    static func visibleItemCount(for phase: ChecklistPhase, learningMode: Bool) -> Int {
        currentAircraft.visibleItemCount(for: phase, learningMode: learningMode)
    }

    static func hasHiddenItems(for phase: ChecklistPhase, learningMode: Bool) -> Bool {
        currentAircraft.hasHiddenItems(for: phase, learningMode: learningMode)
    }
}
