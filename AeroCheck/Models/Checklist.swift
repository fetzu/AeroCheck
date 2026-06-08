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

// Checklist content and speed data are resolved into an owned `ActiveChecklist` value (see
// ActiveChecklist.swift), owned by `AppState` and resolved once per flight. The former global
// `ChecklistData` statics were removed so a premium flight can never read the bundled aircraft's
// data. (ARCH-01)
