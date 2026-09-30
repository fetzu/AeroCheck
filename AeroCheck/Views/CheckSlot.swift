import SwiftUI

// MARK: - The check slot (6.1, "Checks in flight" Q1)
//
// On the MAP pane in flight, the first button of the bottom row holds the next thing to do with the
// checklist, and one tap does it: confirm a memory check (done from memory, with undo), open a list
// still to check on the CHECKLIST pane, or, the check done, go on to the next one. It is 104 pt tall on
// the kneeboard (92 on the phone) and always in the same place, so the thumb learns it; before it,
// marking the climb check done from the map took CHECKLIST at the top, then NEXT at the foot.
//
// Its colour says when: dark while nothing is due, amber (outlined) when the check is due, filled amber
// once, when the flight moved on with it still open, and dashed grey in the landing phase, where there
// is nothing to press until the runway is behind. Nothing pulses, nothing beeps, and it never changes
// the pane on its own. In 6.1 "due" is simply the current check left open; the cues from the flight
// (level-off, descent, approach) come later and set `CheckSlotTiming`.

/// The current check, as the slot reads it.
enum CheckSlotCheck: Equatable {
    /// Nothing to do in the phase (no items, or a checklist not loaded).
    case none
    /// Every item hidden by the Memory test: done once confirmed.
    case memory(done: Bool)
    /// Items on screen, `open` of them still to check (0 = worked through).
    case list(open: Int)
}

/// When the flight says the current check is due. Without cues from the flight (6.1) an open check is
/// due; the flight-event cues will hold it at `notYet` until their event, and escalate to `owed`, once,
/// when the flight moves on with the check still open.
enum CheckSlotTiming: Equatable {
    case notYet
    case due
    case owed
}

/// What the slot holds and how it looks. Pure, so every state is tested without a view.
struct CheckSlot: Equatable {
    enum Tone: Equatable {
        /// Nothing due: dark, cyan text.
        case idle
        /// Due: amber outline on dark amber.
        case due
        /// Passed with the check still open: filled amber, once.
        case owed
        /// Shown, nothing asked (the landing phase): dashed grey.
        case quiet
    }

    enum Action: Equatable {
        /// Records the current memory check done from memory.
        case confirmFromMemory
        /// Shows the CHECKLIST pane; the map comes back after the last CHECK, by the pane rule.
        case showChecklist
        /// Goes on to the next phase, as NEXT.
        case advance
    }

    enum Line: Equatable {
        /// "from memory · one tap when done"
        case fromMemory
        /// "from memory · nothing to press" (landing)
        case fromMemoryQuiet
        /// "5 items"
        case items(Int)
        /// The next check, idle.
        case next
        /// The phase's own action (ENGINE START, …) is still to press on the checklist.
        case actionFirst(String)
        /// The last check, done: END FLIGHT is on the checklist.
        case allChecked
    }

    enum Icon: Equatable {
        case confirm
        case list
        case next
    }

    /// The check the slot names.
    let phase: ChecklistPhase
    let line: Line
    let icon: Icon
    let tone: Tone
    let action: Action

    /// The slot for the current `phase`, its `check`, the phase after it (`nil` at the end), the phase's
    /// own action if it is still to press, and the flight's timing.
    static func make(phase: ChecklistPhase, check: CheckSlotCheck, next: ChecklistPhase?,
                     pendingAction: String? = nil, timing: CheckSlotTiming = .due) -> CheckSlot {
        // From final to the runway vacated there is nothing to press: the landing check is shown, never
        // asked (research: AC 91-73B, single-pilot guidance). A tap still confirms it.
        let quiet = phase == .landing
        let openTone: Tone = quiet ? .quiet : {
            switch timing {
            case .notYet: return .idle
            case .due: return .due
            case .owed: return .owed
            }
        }()
        switch check {
        case .memory(done: false):
            return CheckSlot(phase: phase, line: quiet ? .fromMemoryQuiet : .fromMemory, icon: .confirm,
                             tone: openTone, action: .confirmFromMemory)
        case .list(let open) where open > 0:
            return CheckSlot(phase: phase, line: .items(open), icon: .list, tone: openTone, action: .showChecklist)
        default:
            // Done, or nothing to do. The phase's own action first: going on without it would record
            // the check red (missing action), so the slot sends the pilot to the button.
            if let pendingAction {
                return CheckSlot(phase: phase, line: .actionFirst(pendingAction), icon: .list, tone: .due,
                                 action: .showChecklist)
            }
            if let next {
                return CheckSlot(phase: next, line: .next, icon: .next, tone: .idle, action: .advance)
            }
            return CheckSlot(phase: phase, line: .allChecked, icon: .list, tone: .idle, action: .showChecklist)
        }
    }
}

extension CheckSlot.Line {
    var text: String {
        switch self {
        case .fromMemory: return L10n.CheckSlot.fromMemoryOneTap
        case .fromMemoryQuiet: return L10n.CheckSlot.fromMemoryNothingToPress
        case .items(let count): return L10n.CheckSlot.items(count)
        case .next: return L10n.CheckSlot.nextCheck
        case .actionFirst(let action): return L10n.CheckSlot.actionFirst(action)
        case .allChecked: return L10n.Cockpit.allChecked
        }
    }

    /// The same, where the slot is narrow (the phone's shared row): what the tap does goes, the colour
    /// and the frame say it.
    var shortText: String {
        switch self {
        case .fromMemory: return L10n.Cockpit.fromMemory
        case .fromMemoryQuiet: return L10n.CheckSlot.nothingToPress
        default: return text
        }
    }
}

/// The slot's button: the check's name, what a tap does under it, the icon on the left, in the tone's
/// colours (the proposal's mockups, M1 to M3). `prominent`: a wide slot (the row with no route) sets its
/// name at the thumb bar's button size.
struct CheckSlotButton: View {
    let slot: CheckSlot
    var prominent: Bool = false
    let action: () -> Void

    @Environment(\.cockpitTheme) private var theme

    /// The slot's height: the thumb bar's, 104 pt on the kneeboard and 92 on the phone.
    static var height: CGFloat { CockpitTarget.thumb }

    var body: some View {
        let phone = CockpitScale.current == .phone
        // The phone's slot beside MARK or between the hold buttons is about 100 pt wide: no icon (the
        // colour and the frame say the state), the name on two lines, the short line.
        let narrow = phone && !prominent
        Button(action: action) {
            HStack(spacing: phone ? 8 : 16) {
                if !narrow {
                    Image(systemName: iconName)
                        .font(.aero(size: prominent ? CockpitType.size(kneeboard: 38, phone: 28)
                                                    : CockpitType.size(kneeboard: 32, phone: 24),
                                    weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(slot.phase.shortTitle)
                        .font(.aero(size: prominent ? CockpitType.button : CockpitType.size(kneeboard: 25, phone: 19),
                                    weight: .bold))
                        .lineLimit(phone ? 2 : 1)
                        .minimumScaleFactor(0.6)
                    // Two lines where the slot shares the row (beside MARK, between the hold
                    // buttons): "from memory · one tap when done" is the line that matters.
                    Text(narrow ? slot.line.shortText : slot.line.text)
                        .font(.aero(size: CockpitType.label, weight: .medium))
                        .foregroundColor(lineColor)
                        .lineLimit(prominent && !phone ? 1 : 2)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundColor(textColor)
            .padding(.horizontal, phone ? 10 : 22)
            .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
            .background(background)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(slot.phase.shortTitle), \(slot.line.text)")
        .accessibilityHint(accessibilityHint)
    }

    private var iconName: String {
        switch slot.icon {
        case .confirm: return "checkmark.circle"
        case .list: return "list.bullet"
        case .next: return "chevron.right.circle"
        }
    }

    private var textColor: Color {
        switch slot.tone {
        case .idle: return theme.action
        case .due: return theme.warning
        case .owed: return .black
        case .quiet: return theme.textSecondary
        }
    }

    private var lineColor: Color {
        switch slot.tone {
        case .idle, .quiet: return theme.textSecondary
        case .due: return theme.warning.opacity(0.8)
        case .owed: return .black.opacity(0.75)
        }
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        switch slot.tone {
        case .idle:
            shape.fill(theme.action.opacity(0.12))
                .overlay(shape.stroke(theme.action.opacity(0.45), lineWidth: 1))
        case .due:
            shape.fill(theme.warning.opacity(0.16))
                .overlay(shape.strokeBorder(theme.warning, lineWidth: 3))
        case .owed:
            shape.fill(theme.warning)
        case .quiet:
            // Dashed: seen, never asked.
            shape.fill(theme.textPrimary.opacity(0.03))
                .overlay(shape.strokeBorder(theme.textDim, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
        }
    }

    private var accessibilityHint: String {
        switch slot.action {
        case .confirmFromMemory: return L10n.CheckSlot.confirmHint
        case .showChecklist: return L10n.CheckSlot.showChecklistHint
        case .advance: return L10n.Cockpit.nextPhaseA11y(slot.phase.title)
        }
    }
}

/// The slot as the Cockpit's map shows it: the current check from `AppState`, and what a tap does. A
/// view of its own, so the map's body only holds a reference to it (see `SeparateView`).
struct CockpitCheckSlot: View {
    /// Shows the CHECKLIST pane (the Cockpit's).
    let onShowChecklist: () -> Void
    var prominent: Bool = false

    @Environment(AppState.self) private var appState

    var body: some View {
        let slot = Self.slot(for: appState)
        CheckSlotButton(slot: slot, prominent: prominent) {
            switch slot.action {
            case .confirmFromMemory: appState.confirmMemoryCheck()
            case .showChecklist: onShowChecklist()
            case .advance: appState.nextPhase()
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: appState.memoryConfirmation?.id)
    }

    /// The slot for the flight as it stands.
    @MainActor
    static func slot(for appState: AppState) -> CheckSlot {
        let phase = appState.currentPhase
        return CheckSlot.make(phase: phase, check: check(in: appState),
                              next: phase.nextNavigable(circuitMode: appState.isCircuitMode),
                              pendingAction: pendingAction(in: appState))
    }

    @MainActor
    static func check(in appState: AppState) -> CheckSlotCheck {
        let phase = appState.currentPhase
        if appState.isMemoryCheck(phase) { return .memory(done: appState.currentCheckIsDone) }
        let visible = appState.activeChecklist.visibleItemCount(for: phase, learningMode: appState.effectiveLearningMode)
        guard visible > 0 else { return .none }
        if appState.currentCheckIsDone { return .list(open: 0) }
        return .list(open: max(1, appState.openItems(in: phase).count))
    }

    /// ENGINE START, READY FOR LINE UP or ENGINE SHUTDOWN, while unpressed in their phase: the ones a
    /// phase is recorded red without.
    @MainActor
    static func pendingAction(in appState: AppState) -> String? {
        let phase = appState.currentPhase
        guard phase.hasMissingRequiredAction(engineStarted: appState.engineStartTime != nil,
                                             linedUp: appState.lineUpTime != nil,
                                             engineShutDown: appState.engineShutdownTime != nil) else { return nil }
        let language = appState.settings.checklistLanguage.resolvedLanguage
        if phase.showsEngineStartButton { return L10n.ChecklistAction.engineStart(language: language) }
        if phase.showsLineUpButton { return L10n.ChecklistAction.readyForLineUp(language: language) }
        return L10n.ChecklistAction.engineShutdown(language: language)
    }
}

/// GO AROUND or TOUCH-AND-GO in the map's bottom row, in approach and landing (mockup M3): what the
/// checklist pane's buttons do, at the thumb bar's height. Hold 1 s to confirm, as there; a single tap in
/// circuits, as the checklist's thumb bar has them, for a quick correction of a missed detection. (6.1)
struct MapFlightEventButton: View {
    enum Event { case goAround, touchAndGo }
    let event: Event

    @Environment(AppState.self) private var appState
    @Environment(\.cockpitTheme) private var theme
    @EnvironmentObject private var flightEventDetector: FlightEventDetector

    var body: some View {
        let language = appState.settings.checklistLanguage.resolvedLanguage
        let title = event == .goAround ? L10n.ChecklistAction.goAround(language: language)
                                       : L10n.ChecklistAction.touchAndGo(language: language)
        let icon = event == .goAround ? "arrow.up.right.circle.fill" : "arrow.triangle.2.circlepath"
        if appState.isCircuitMode {
            CockpitThumbButton(title: title, icon: CockpitScale.current == .phone ? nil : icon,
                               style: .outlined(tint: theme.action), action: perform)
        } else {
            HoldToConfirmButton(title: title, systemImage: icon, tint: theme.action,
                                count: event == .goAround ? appState.currentFlight?.goAroundCount ?? 0
                                                          : appState.currentFlight?.touchAndGoCount ?? 0,
                                kneeboard: true, height: CockpitTarget.thumb,
                                stacked: CockpitScale.current == .phone, action: perform)
        }
    }

    /// As the checklist pane's: the detector is told first, so it doesn't prompt for the same event, and
    /// gives back the physical time when it knows one.
    private func perform() {
        switch event {
        case .goAround:
            appState.recordGoAround(at: flightEventDetector.notifyManualEvent(.goAround))
        case .touchAndGo:
            appState.recordTouchAndGo(at: flightEventDetector.notifyManualEvent(.touchAndGo))
        }
    }
}
