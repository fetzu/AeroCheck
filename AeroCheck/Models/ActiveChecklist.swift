import Foundation

/// A fully-resolved, owned snapshot of one aircraft's checklist content **and** speed data.
///
/// This replaces the former global `ChecklistData` statics (`currentAircraft`,
/// `currentRemoteChecklist`, `expectsRemoteChecklist`). Because it is an owned value resolved once
/// for the current selection, it can never fall back to the wrong aircraft: a premium selection
/// whose checklist failed to load resolves to `.unresolved`, which exposes no items and no speeds.
/// A premium flight therefore never shows the bundled WT9's content. (ARCH-01)
struct ActiveChecklist: Equatable {
    enum Source: Equatable {
        /// A bundled aircraft, served from its hardcoded data.
        case bundled(AircraftType)
        /// A resolved remote checklist — either a premium aircraft or a language-specific bundled one.
        case remote(RemoteAircraftChecklist)
        /// A premium aircraft is selected but its checklist hasn't resolved. Exposes nothing.
        case unresolved
    }

    let source: Source

    /// The default bundled aircraft checklist.
    static let bundledDefault = ActiveChecklist(source: .bundled(.wt9Dynamic))

    // MARK: - Items

    func items(for phase: ChecklistPhase) -> [ChecklistItem] {
        switch source {
        case .bundled(let type): return type.items(for: phase)
        case .remote(let checklist): return checklist.items(for: phase)
        case .unresolved: return []
        }
    }

    func learningModeVisibleCount(for phase: ChecklistPhase) -> Int? {
        switch source {
        case .bundled(let type): return type.learningModeVisibleCount(for: phase)
        case .remote(let checklist): return checklist.learningModeVisibleCount(for: phase)
        case .unresolved: return nil
        }
    }

    func visibleItems(for phase: ChecklistPhase, learningMode: Bool) -> [ChecklistItem] {
        switch source {
        case .bundled(let type): return type.visibleItems(for: phase, learningMode: learningMode)
        case .remote(let checklist): return checklist.visibleItems(for: phase, learningMode: learningMode)
        case .unresolved: return []
        }
    }

    func visibleItemCount(for phase: ChecklistPhase, learningMode: Bool) -> Int {
        switch source {
        case .bundled(let type):
            return type.visibleItemCount(for: phase, learningMode: learningMode)
        case .remote(let checklist):
            let items = checklist.items(for: phase)
            if learningMode { return items.count }
            if let count = checklist.learningModeVisibleCount(for: phase) { return count }
            return items.count
        case .unresolved:
            return 0
        }
    }

    func hasHiddenItems(for phase: ChecklistPhase, learningMode: Bool) -> Bool {
        if learningMode { return false }
        switch source {
        case .bundled(let type): return type.hasHiddenItems(for: phase, learningMode: learningMode)
        case .remote(let checklist): return checklist.learningModeVisibleCount(for: phase) != nil
        case .unresolved: return false
        }
    }

    // MARK: - Speeds & metadata

    func targetSpeed(for phase: ChecklistPhase) -> Int? {
        switch source {
        case .bundled(let type): return type.targetSpeed(for: phase)
        case .remote(let checklist): return checklist.targetSpeed(for: phase)
        case .unresolved: return nil
        }
    }

    var registration: String {
        switch source {
        case .bundled(let type): return type.registration
        case .remote(let checklist): return checklist.registration
        case .unresolved: return ""
        }
    }

    var shortModelName: String {
        switch source {
        case .bundled(let type): return type.shortModelName
        case .remote(let checklist): return checklist.shortModelName
        case .unresolved: return ""
        }
    }

    var stallSpeed: Int {
        switch source {
        case .bundled(let type): return type.stallSpeed
        case .remote(let checklist): return checklist.stallSpeed
        case .unresolved: return 0
        }
    }

    var speeds: [SpeedReference] {
        switch source {
        case .bundled(let type): return type.speeds
        case .remote(let checklist): return checklist.localSpeeds
        case .unresolved: return []
        }
    }

    var crosswindLimits: (takeoff: String, landing: String) {
        switch source {
        case .bundled(let type): return type.crosswindLimits
        case .remote(let checklist): return checklist.crosswindLimitsTuple
        case .unresolved: return ("—", "—")
        }
    }

    var hasParachute: Bool {
        switch source {
        case .bundled(let type): return type.hasParachute
        case .remote(let checklist): return checklist.hasParachute ?? false
        case .unresolved: return false
        }
    }
}

/// The aircraft a flight was started on, and its checklist: what the Cockpit shows from START FLIGHT
/// to the end, whatever is selected meanwhile.
///
/// The selection is synced settings, so another device on the same iCloud account (the Companion
/// iPhone, say) can change it while this one flies. Followed in flight, it put a PA-28 on the WT9's
/// checks and speeds (stall 42 kt instead of 50), and a crash restored a WT9 flight on the PA-28, or
/// on nothing at all offline. Taken by `AppState.startFlight` after the ARCH-01 guard, and from the
/// checkpoint by a crash restore.
struct FlightAircraft {
    /// The bundled aircraft selected at the start: the one flown when `remoteId` is nil.
    let bundled: AircraftType
    /// The premium aircraft flown (`id`, or `id~REG` for another tail), nil for the bundled one.
    let remoteId: String?
    /// The checklist language resolved at the start, so a restore reloads the same one.
    let language: String
    /// Its resolved checklist: a premium aircraft's, or the bundled one's in `language`. nil after a
    /// restore until `AppState.loadFlightChecklistIfNeeded` has it back.
    var checklist: RemoteAircraftChecklist?

    /// The id its checklist is fetched under.
    var checklistId: String { remoteId ?? bundled.serverId }

    /// The rule `AppState.activeChecklist` applies to the selection, applied to this aircraft: a
    /// premium flight without its checklist shows nothing, never the WT9's. (ARCH-01)
    var activeChecklist: ActiveChecklist {
        if let checklist { return ActiveChecklist(source: .remote(checklist)) }
        if remoteId != nil { return ActiveChecklist(source: .unresolved) }
        return ActiveChecklist(source: .bundled(bundled))
    }
}

/// Pure step-by-step checklist highlighting rules, extracted from `AppState` so the rules are
/// unit-testable and the @MainActor god-object no longer owns them. `AppState` keeps the
/// `currentHighlightedItem` state and delegates the index math here. (Phase 4 — AppState decomposition)
enum ChecklistHighlighting {
    /// Next highlight index when advancing within a phase — clamped to the last visible item, so the
    /// pilot must press NEXT to leave the phase rather than the highlight running off the end.
    static func advanced(current: Int, visibleCount: Int) -> Int {
        current < visibleCount - 1 ? current + 1 : current
    }

    /// The index that marks the last item complete: one past the last visible item.
    static func lastItemComplete(visibleCount: Int) -> Int {
        visibleCount
    }

    /// Whether every visible item in the phase has been completed.
    static func allItemsCompleted(current: Int, visibleCount: Int) -> Bool {
        current >= visibleCount
    }
}
