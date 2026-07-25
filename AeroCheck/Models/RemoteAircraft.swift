import Foundation

/// Metadata for an aircraft from the API
/// Per-registration metadata for a multi-registration aircraft, mirrored from the server's additive
/// `/available` `registrations` array (PR-17). Foundation for a future per-registration selector.
struct RemoteAircraftRegistration: Codable, Identifiable, Equatable {
    var id: String { registration }
    let registration: String
    let modelName: String
    let shortModelName: String
    let aeroclub: String?
    let version: String
    let lastUpdated: String
    let availableLanguages: [String]?
}

/// Selection/cache token for a specific tail of a multi-registration aircraft: "id~REG".
/// '~' is RFC 3986-unreserved (never percent-encoded, so the token survives widget deep-link
/// URLs verbatim — '#' would truncate as a fragment), is filename-safe for cache keys, and can
/// appear in neither server ids (lowercase-hyphenated) nor registrations, so the split is
/// unambiguous. The FIRST registration keeps the plain server id, so existing persisted
/// selections and checklist caches stay valid without migration.
enum AircraftRegistrationToken {
    static let separator: Character = "~"

    /// "dr400-140b-gvmn~HB-KFP" → ("dr400-140b-gvmn", "HB-KFP"); a plain id passes through.
    static func split(_ token: String) -> (aircraftId: String, registration: String?) {
        guard let idx = token.firstIndex(of: separator) else { return (token, nil) }
        let reg = String(token[token.index(after: idx)...])
        return (String(token[..<idx]), reg.isEmpty ? nil : reg)
    }

    static func make(aircraftId: String, registration: String) -> String {
        "\(aircraftId)\(separator)\(registration)"
    }

    /// Characters an aircraft id / registration may contain. Deliberately excludes `/`, `\` and `.`
    /// sequences that could escape a directory, and anything needing percent-encoding.
    private static let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")

    /// Whether a token is safe to splice into a filesystem path component **and** a URL path segment.
    ///
    /// The id reaches two sinks that both trust it: `cacheDirectory.appendingPathComponent("\(id).json")`
    /// and the `/aircraft/{id}/checklist` request path. It arrives from the API *and* from a synced
    /// CloudKit `Settings` record, which `clampedForIngest()` previously waved through — it clamped
    /// two numeric fields and validated no string at all. An id of `../../../Documents/leak` resolves
    /// outside the cache and inside the `UIFileSharingEnabled`-exposed Documents folder, so a server
    /// response gets written where the Files app can read it; `.urlPathAllowed` preserves `/` and `..`
    /// so the traversal survives percent-encoding too. (SA-23)
    static func isWellFormed(_ token: String) -> Bool {
        guard !token.isEmpty, token.count <= 96 else { return false }
        // At most one `~`, splitting id from registration.
        let parts = token.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }

        for (index, part) in parts.enumerated() {
            // A trailing `~` with no registration is malformed; the id itself must be non-empty.
            guard !part.isEmpty, part.count <= 64 else { return false }
            guard part.rangeOfCharacter(from: allowed.inverted) == nil else { return false }
            // No `..` anywhere, and no leading dot (a hidden file / relative reference).
            guard !part.contains(".."), part.first != "." else { return false }
            _ = index
        }
        return true
    }
}

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
    /// All registrations of this aircraft (PR-17, additive). Nil for older server responses; the
    /// top-level fields above reflect the first registration for backward compatibility.
    var registrations: [RemoteAircraftRegistration]? = nil

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
            return ["en", "fr"]  // WT9 Dynamic F-HVXA has English and French
        default:
            return ["en"]  // Default to English for unknown aircraft
        }
    }

    /// One metadata entry per tail, so every registration of a multi-registration aircraft is a
    /// separately selectable aircraft (the PR-17 selector). The first registration keeps the plain
    /// server id; additional tails get an "id~REG" token that `AircraftDataService` splits back
    /// into the request path + `reg` query. Entries with a nil/empty/single `registrations` array
    /// pass through unchanged, and expanded entries carry `registrations == nil`, so applying this
    /// twice is a no-op (cached metadata may already be expanded).
    func expandedPerRegistration() -> [RemoteAircraftMetadata] {
        guard let regs = registrations, regs.count > 1 else { return [self] }
        return regs.enumerated().map { index, reg in
            RemoteAircraftMetadata(
                id: index == 0 ? id : AircraftRegistrationToken.make(aircraftId: id, registration: reg.registration),
                aircraftType: aircraftType,
                registration: reg.registration,
                modelName: reg.modelName,
                shortModelName: reg.shortModelName,
                aeroclub: reg.aeroclub ?? aeroclub,
                version: reg.version,
                lastUpdated: reg.lastUpdated,
                isFree: isFree,
                stallSpeed: stallSpeed,
                pageCount: pageCount,
                hasAccess: hasAccess,
                availableLanguages: reg.availableLanguages ?? availableLanguages,
                registrations: nil
            )
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
    let hasParachute: Bool?  // Whether aircraft has ballistic parachute (BRS/CAPS)
    // PR-41 / UX-08: the server reports the language actually served plus whether it fell back from
    // the requested one. Optional + additive — bundled JSONs and older server responses omit them.
    let language: String?
    let requestedLanguage: String?
    let languageFallback: Bool?
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
    /// This allows remote checklists to be used with existing aircraft-data code paths
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
    var hasParachute: Bool { checklist.hasParachute ?? false }
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
