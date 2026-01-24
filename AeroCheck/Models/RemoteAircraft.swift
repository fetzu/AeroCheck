import Foundation

/// Metadata for an aircraft from the API
struct RemoteAircraftMetadata: Codable, Identifiable, Equatable {
    let id: String
    let aircraftType: String
    let registration: String
    let modelName: String
    let shortModelName: String
    let aeroclub: String?
    var version: String
    var lastUpdated: String
    let isFree: Bool
    let stallSpeed: Int
    let pageCount: Int
    var hasAccess: Bool
    var availableLanguages: [String]?

    /// Converts to local AircraftType if available
    var localAircraftType: AircraftType? {
        return AircraftType(rawValue: aircraftType)
    }

    /// Whether this aircraft is bundled locally in the app
    var isBundled: Bool {
        return aircraftType == "WT9"
    }

    /// Gets the available checklist languages for this aircraft
    /// Returns hardcoded values until the API provides this information
    var checklistLanguages: [String] {
        // If API provides languages, use those
        if let languages = availableLanguages, !languages.isEmpty {
            return languages
        }

        // Hardcoded fallback based on known aircraft
        // TODO: Remove this once the API consistently provides availableLanguages
        switch id {
        case "pa28-181":
            return ["en", "fr"]  // PA-28-181 HB-PFA has English and French
        case "wt9-dynamic":
            return ["en"]  // WT9 Dynamic F-HVXA is English-only
        default:
            return ["en"]  // Default to English for unknown aircraft
        }
    }
}

/// Speed reference data
struct RemoteSpeedReference: Codable, Identifiable, Equatable {
    var id: String { "\(name)-\(description)" }

    let name: String
    let description: String
    let value: String

    /// Converts to local SpeedReference
    func toLocal() -> SpeedReference {
        return SpeedReference(name: name, description: description, value: value)
    }
}

/// Crosswind limits
struct RemoteCrosswindLimits: Codable, Equatable {
    let takeoff: String
    let landing: String
}

/// A single checklist item from the API
struct RemoteChecklistItem: Codable, Identifiable, Equatable {
    var id: String { "\(number ?? 0)-\(challenge)" }

    let number: Int?
    let challenge: String
    let response: String
    let isHeader: Bool

    /// Converts to local ChecklistItem
    func toLocal() -> ChecklistItem {
        return ChecklistItem(
            number: number,
            challenge: challenge,
            response: response,
            isHeader: isHeader
        )
    }
}

/// Phase data from the API
struct RemoteChecklistPhase: Codable, Equatable {
    let title: String
    let pageNumber: Int
    let items: [RemoteChecklistItem]
}

/// Full aircraft checklist data from the API
struct RemoteAircraftChecklist: Codable, Identifiable, Equatable {
    let id: String
    let aircraftType: String
    let registration: String
    let modelName: String
    let shortModelName: String
    let aeroclub: String?
    let version: String
    let lastUpdated: String
    let isFree: Bool
    let stallSpeed: Int
    let pageCount: Int
    let crosswindLimits: RemoteCrosswindLimits
    let speeds: [RemoteSpeedReference]
    let targetSpeeds: [String: Int?]
    let learningModeVisibleCount: [String: Int?]
    let phases: [String: RemoteChecklistPhase]

    /// Gets items for a specific phase
    func items(for phase: ChecklistPhase) -> [ChecklistItem] {
        let phaseKey = phase.remoteKey
        guard let phaseData = phases[phaseKey] else {
            return []
        }
        return phaseData.items.map { $0.toLocal() }
    }

    /// Gets the target speed for a phase
    func targetSpeed(for phase: ChecklistPhase) -> Int? {
        let phaseKey = phase.remoteKey
        return targetSpeeds[phaseKey] ?? nil
    }

    /// Gets the learning mode visible count for a phase
    func learningModeVisibleCount(for phase: ChecklistPhase) -> Int? {
        let phaseKey = phase.remoteKey
        return learningModeVisibleCount[phaseKey] ?? nil
    }

    /// Gets visible items based on learning mode
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

    /// Gets the crosswind limits as a tuple
    var crosswindLimitsTuple: (takeoff: String, landing: String) {
        return (crosswindLimits.takeoff, crosswindLimits.landing)
    }

    /// Converts speed references to local format
    var localSpeeds: [SpeedReference] {
        return speeds.map { $0.toLocal() }
    }
}

// MARK: - ChecklistPhase Extension

extension ChecklistPhase {
    /// The key used in the remote API for this phase
    var remoteKey: String {
        switch self {
        case .preflight: return "preflight"
        case .beforeEngineStart: return "beforeEngineStart"
        case .engineStart: return "engineStart"
        case .afterEngineStart: return "afterEngineStart"
        case .taxi: return "taxi"
        case .runup: return "runup"
        case .beforeDeparture: return "beforeDeparture"
        case .lineUp: return "lineUp"
        case .climb: return "climb"
        case .cruise: return "cruise"
        case .descent: return "descent"
        case .approach: return "approach"
        case .landing: return "landing"
        case .afterLanding: return "afterLanding"
        case .shutdown: return "shutdown"
        case .hangar: return "hangar"
        }
    }
}

// MARK: - RemoteAircraftChecklist to AircraftType Bridge

extension RemoteAircraftChecklist {
    /// Creates a temporary AircraftType-compatible interface for use with existing code
    /// This allows remote checklists to be used with the existing ChecklistData system
    func toAircraftAdapter() -> RemoteAircraftAdapter {
        return RemoteAircraftAdapter(checklist: self)
    }
}

/// Adapter that allows a RemoteAircraftChecklist to be used with existing code
struct RemoteAircraftAdapter {
    let checklist: RemoteAircraftChecklist

    var registration: String { checklist.registration }
    var modelName: String { checklist.modelName }
    var shortModelName: String { checklist.shortModelName }
    var checklistVersion: String { checklist.version }
    var lastUpdated: String { checklist.lastUpdated }
    var stallSpeed: Int { checklist.stallSpeed }
    var pageCount: Int { checklist.pageCount }
    var speeds: [SpeedReference] { checklist.localSpeeds }
    var crosswindLimits: (takeoff: String, landing: String) { checklist.crosswindLimitsTuple }

    func items(for phase: ChecklistPhase) -> [ChecklistItem] {
        checklist.items(for: phase)
    }

    func learningModeVisibleCount(for phase: ChecklistPhase) -> Int? {
        checklist.learningModeVisibleCount(for: phase)
    }

    func visibleItems(for phase: ChecklistPhase, learningMode: Bool) -> [ChecklistItem] {
        checklist.visibleItems(for: phase, learningMode: learningMode)
    }

    func targetSpeed(for phase: ChecklistPhase) -> Int? {
        checklist.targetSpeed(for: phase)
    }

    var totalChecklistItems: Int {
        ChecklistPhase.allCases.reduce(0) { count, phase in
            count + checklist.items(for: phase).count
        }
    }
}
