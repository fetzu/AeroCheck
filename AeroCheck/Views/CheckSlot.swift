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
// the pane on its own. "Due" comes from the flight (FlightCues.swift): the climb check at 500 ft above the
// field, the cruise check at the level-off, the descent check at the descent, the approach check near the
// destination, and the landing check shown, dashed, from circuit height. Once the flight says so, the
// next check comes to the slot too, with its one tap (the descent check in cruise, where FREDA was).
//
// In cruise, once the cruise check is done, the slot holds FREDA (Q6, Freda.swift): "CRUISE CHECK ✓
// 14:24 · FREDA in 6 min" while it counts, amber "FREDA · F · R · E · D · A" when due, one tap done.

/// The current check, as the slot reads it.
enum CheckSlotCheck: Equatable {
    /// Nothing to do in the phase (no items, or a checklist not loaded).
    case none
    /// Every item hidden by the Memory test: done once confirmed.
    case memory(done: Bool)
    /// Items on screen, `open` of them still to check (0 = worked through).
    case list(open: Int)
}

/// FREDA, as the slot reads it: in cruise, the cruise check done. (6.1, Q6)
enum CheckSlotFreda: Equatable {
    /// Counting: what was done last and when, and the minutes left, rounded up.
    case counting(after: FredaSchedule.Since, at: Date, minutesLeft: Int)
    /// Due; `waypoint` is the one passed that made it due (nil: the ten minutes).
    case due(waypoint: String?)
}

/// When the flight says a check is due (FlightCueState): not yet until its cue, due from it, and owed,
/// once, when the flight moved on with the check still open. With no cue source (no take-off detected
/// yet), an open check is due, as before the cues.
enum CheckSlotTiming: Equatable {
    case notYet
    case due
    case owed
}

/// What the slot holds and how it looks. Pure, so every state is tested without a view.
/// Codable: the Companion iPhone draws the iPad's slot from its snapshot. (6.1)
struct CheckSlot: Equatable, Codable {
    enum Tone: Equatable, Codable {
        /// Nothing due: dark, cyan text.
        case idle
        /// Due: amber outline on dark amber.
        case due
        /// Passed with the check still open: filled amber, once.
        case owed
        /// Shown, nothing asked (the landing phase): dashed grey.
        case quiet
    }

    enum Action: String, Equatable, Codable {
        /// Records the current memory check done from memory.
        case confirmFromMemory
        /// Shows the CHECKLIST pane; the map comes back after the last CHECK, by the pane rule.
        case showChecklist
        /// Goes on to the next phase, as NEXT.
        case advance
        /// Records FREDA done. (6.1)
        case confirmFreda
        /// Goes on to the next check and records it done from memory: the flight says it's due. (6.1)
        case advanceAndConfirm
        /// Goes on to the landing check, shown from circuit height. (6.1)
        case goToLanding
    }

    /// What the first line names. (6.1)
    enum Title: Equatable, Codable {
        /// The check: `phase.shortTitle`.
        case check
        /// "FREDA"
        case freda
        /// What FREDA counts from, ticked, with its time: "CRUISE CHECK ✓ 14:24", "FREDA ✓ 14:34".
        case fredaCountsFrom(FredaSchedule.Since, Date)
    }

    enum Line: Equatable, Codable {
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
        /// "FREDA in 6 min" (6.1)
        case fredaIn(minutes: Int)
        /// "F · R · E · D · A", and the waypoint passed that made it due. (6.1)
        case fredaFlow(waypoint: String?)
        /// "owed · you levelled off with it open": the cue that passed it. (6.1)
        case owed(FlightCue?)
        /// "2 items · nothing to press": the landing check as a list, from circuit height. (6.1)
        case itemsQuiet(Int)
    }

    enum Icon: Equatable, Codable {
        case confirm
        case list
        case next
        case freda
    }

    /// The check the slot names.
    let phase: ChecklistPhase
    let line: Line
    let icon: Icon
    let tone: Tone
    let action: Action
    var title: Title = .check

    /// The next check, when the flight says it is due already: what it is, how due, and the cue that
    /// made it owed. The slot then offers it, one tap, where it showed "next check". (6.1)
    struct Upcoming: Equatable {
        let check: CheckSlotCheck
        let timing: CheckSlotTiming
        var owedBy: FlightCue? = nil
    }

    /// The slot for the current `phase`, its `check`, the phase after it (`nil` at the end), the phase's
    /// own action if it is still to press, the flight's timing (and the cue that made it owed), FREDA
    /// (cruise, its check done), the next check once due (`upcoming`), and the landing check once shown
    /// from circuit height (`landingShown`, its check).
    static func make(phase: ChecklistPhase, check: CheckSlotCheck, next: ChecklistPhase?,
                     pendingAction: String? = nil, timing: CheckSlotTiming = .due, owedBy: FlightCue? = nil,
                     freda: CheckSlotFreda? = nil, upcoming: Upcoming? = nil,
                     landingShown: CheckSlotCheck? = nil) -> CheckSlot {
        // From circuit height to the runway vacated there is nothing to press: the landing check is shown,
        // dashed, never asked, whatever was open before it (research: AC 91-73B; the proposal's part 4).
        // A tap goes on to it.
        if let landing = landingShown, phase != .landing {
            switch landing {
            case .list(let open) where open > 0:
                return CheckSlot(phase: .landing, line: .itemsQuiet(open), icon: .list, tone: .quiet, action: .goToLanding)
            default:
                return CheckSlot(phase: .landing, line: .fromMemoryQuiet, icon: .confirm, tone: .quiet, action: .goToLanding)
            }
        }
        // In the landing phase too: shown, never asked. A tap still confirms it.
        let quiet = phase == .landing
        let openTone: Tone = quiet ? .quiet : tone(timing)
        let owedLine: Line? = timing == .owed && !quiet ? .owed(owedBy) : nil
        switch check {
        case .memory(done: false):
            return CheckSlot(phase: phase, line: owedLine ?? (quiet ? .fromMemoryQuiet : .fromMemory), icon: .confirm,
                             tone: openTone, action: .confirmFromMemory)
        case .list(let open) where open > 0:
            return CheckSlot(phase: phase, line: owedLine ?? .items(open), icon: .list, tone: openTone,
                             action: .showChecklist)
        default:
            // Done, or nothing to do. In cruise, FREDA: counting, a tap opens the checklist, where NEXT
            // and the FREDA button sit side by side; due, amber, a tap records it done. (6.1, Q6)
            if let freda {
                switch freda {
                case .counting(let since, let at, let minutes):
                    return CheckSlot(phase: phase, line: .fredaIn(minutes: minutes), icon: .freda, tone: .idle,
                                     action: .showChecklist, title: .fredaCountsFrom(since, at))
                case .due(let waypoint):
                    return CheckSlot(phase: phase, line: .fredaFlow(waypoint: waypoint), icon: .freda, tone: .due,
                                     action: .confirmFreda, title: .freda)
                }
            }
            // The phase's own action first: going on without it would record the check red (missing
            // action), so the slot sends the pilot to the button.
            if let pendingAction {
                return CheckSlot(phase: phase, line: .actionFirst(pendingAction), icon: .list, tone: .due,
                                 action: .showChecklist)
            }
            // The next check, once the flight says it's due: one tap to it, and a memory check done with
            // the same tap (the descent check in cruise). Not the landing check: nothing to press there.
            if let next, next != .landing, let upcoming, upcoming.timing != .notYet {
                let line: Line? = upcoming.timing == .owed ? .owed(upcoming.owedBy) : nil
                switch upcoming.check {
                case .memory(done: false):
                    return CheckSlot(phase: next, line: line ?? .fromMemory, icon: .confirm,
                                     tone: tone(upcoming.timing), action: .advanceAndConfirm)
                case .list(let open) where open > 0:
                    return CheckSlot(phase: next, line: line ?? .items(open), icon: .list,
                                     tone: tone(upcoming.timing), action: .advance)
                default:
                    break
                }
            }
            if let next {
                return CheckSlot(phase: next, line: .next, icon: .next, tone: .idle, action: .advance)
            }
            return CheckSlot(phase: phase, line: .allChecked, icon: .list, tone: .idle, action: .showChecklist)
        }
    }

    private static func tone(_ timing: CheckSlotTiming) -> Tone {
        switch timing {
        case .notYet: return .idle
        case .due: return .due
        case .owed: return .owed
        }
    }
}

extension CheckSlot {
    /// The advance out of the check before departure (the only way on to the line up check): it reads
    /// READY FOR LINE UP, then the line up check, as the thumb bar's NEXT does, and the tap is the same
    /// (`AppState.nextPhase` records it). Read off the slot rather than carried in it, so the Companion's
    /// snapshot keeps its shape: an older iPhone still shows the line up check, and its tap does the
    /// same on the iPad. (6.2)
    var readiesForLineUp: Bool {
        action == .advance && phase == .lineUp
    }

    /// The first line. `stacked`: a slot sharing its row on the iPad (beside MARK, in the landscape
    /// column), where "CRUISE CHECK ✓ 14:24" on one line would shrink under 20 pt: the time goes under.
    func titleText(stacked: Bool = false) -> String {
        switch title {
        case .check: return readiesForLineUp ? L10n.ChecklistAction.readyForLineUp : phase.shortTitle
        case .freda: return L10n.Freda.name
        case .fredaCountsFrom(let since, let at):
            let what = since == .cruiseCheck ? ChecklistPhase.cruise.shortTitle : L10n.Freda.name
            let time = at.formatted(date: .omitted, time: .shortened)
            return stacked ? L10n.Freda.tickedStacked(what, time) : L10n.Freda.ticked(what, time)
        }
    }

    /// Whether the title may take two lines: on the phone, and a stacked FREDA title. (6.1)
    func titleWraps(phone: Bool, stacked: Bool) -> Bool {
        phone || (stacked && title != .check)
    }

    /// The second line, as the button shows it: `narrow` (the phone's shared row) and `stacked` (the
    /// iPad's shared row) pick the line's shorter forms; under READY FOR LINE UP, "then LINE UP CHECK".
    func lineText(narrow: Bool = false, stacked: Bool = false) -> String {
        if readiesForLineUp { return L10n.Cockpit.thenCheck(phase.shortTitle) }
        return narrow ? line.shortText : stacked ? line.stackedText : line.text
    }

    /// What VoiceOver reads for the second line.
    var lineAccessibilityText: String {
        readiesForLineUp ? lineText() : line.accessibilityText
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
        case .fredaIn(let minutes): return L10n.Freda.inMinutes(minutes)
        case .fredaFlow(let waypoint):
            return waypoint.map { L10n.Freda.flowAfterWaypoint($0) } ?? L10n.Freda.flow
        case .owed(let cue): return L10n.CheckSlot.owed(after: cue)
        case .itemsQuiet(let count): return L10n.CheckSlot.itemsNothingToPress(count)
        }
    }

    /// The same where the slot shares its row on the iPad (beside MARK, the landscape column): the
    /// letters over the waypoint's name, each on a line of its own at 20 pt. (6.1)
    var stackedText: String {
        switch self {
        case .fredaFlow(let waypoint): return waypoint.map { "\(L10n.Freda.flowCompact)\n\($0)" } ?? L10n.Freda.flowCompact
        default: return text
        }
    }

    /// The same, where the slot is narrow (the phone's shared row): what the tap does goes, the colour
    /// and the frame say it.
    var shortText: String {
        switch self {
        case .fromMemory: return L10n.Cockpit.fromMemory
        case .fromMemoryQuiet, .itemsQuiet: return L10n.CheckSlot.nothingToPress
        case .fredaFlow: return L10n.Freda.flowCompact
        case .owed: return L10n.CheckSlot.owedShort
        default: return text
        }
    }

    /// What VoiceOver reads: the flow spelled out rather than five letters.
    var accessibilityText: String {
        switch self {
        case .fredaFlow(let waypoint):
            return waypoint.map { "\(L10n.Freda.flowSpelledOut), \(L10n.Freda.waypointPassed($0))" } ?? L10n.Freda.flowSpelledOut
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
        // The iPad's slot sharing its row (beside MARK, the landscape column): about 160 pt of text.
        let stacked = !phone && !prominent
        Button(action: action) {
            HStack(spacing: phone ? 8 : 16) {
                if !narrow {
                    Image(systemName: iconName)
                        .font(.aero(size: prominent ? CockpitType.size(kneeboard: 38, phone: 28)
                                                    : CockpitType.size(kneeboard: 32, phone: 24),
                                    weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(slot.titleText(stacked: stacked || narrow))
                        .font(.aero(size: prominent ? CockpitType.button : CockpitType.size(kneeboard: 25, phone: 19),
                                    weight: .bold))
                        .lineLimit(slot.titleWraps(phone: phone, stacked: stacked) ? 2 : 1)
                        .minimumScaleFactor(0.6)
                    // Two lines where the slot shares the row (beside MARK, between the hold
                    // buttons): "from memory · one tap when done" is the line that matters.
                    Text(slot.lineText(narrow: narrow, stacked: stacked))
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
        .accessibilityLabel("\(slot.titleText()), \(slot.lineAccessibilityText)")
        .accessibilityHint(accessibilityHint)
    }

    private var iconName: String {
        if slot.readiesForLineUp { return "airplane.departure" }
        switch slot.icon {
        case .confirm: return "checkmark.circle"
        case .list: return "list.bullet"
        case .next: return "chevron.right.circle"
        case .freda: return "arrow.triangle.2.circlepath"
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
        case .advance:
            return slot.readiesForLineUp ? L10n.Cockpit.readyForLineUpHint : L10n.Cockpit.nextPhaseA11y(slot.phase.title)
        case .confirmFreda: return L10n.Freda.confirmHint
        case .advanceAndConfirm: return L10n.CheckSlot.advanceAndConfirmHint
        case .goToLanding: return L10n.CheckSlot.goToLandingHint
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
        // FREDA counting shows its minutes: redrawn as they pass. Due, the next evaluation redraws it.
        if appState.freda.isRunning && !appState.fredaDue {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                button(Self.slot(for: appState, now: context.date))
            }
        } else {
            button(Self.slot(for: appState))
        }
    }

    private func button(_ slot: CheckSlot) -> some View {
        CheckSlotButton(slot: slot, prominent: prominent) {
            Self.perform(slot.action, appState: appState, onShowChecklist: onShowChecklist)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: appState.memoryConfirmation?.id)
    }

    /// What the slot's tap does, on the iPad or sent from the Companion iPhone.
    @MainActor
    static func perform(_ action: CheckSlot.Action, appState: AppState, onShowChecklist: () -> Void) {
        switch action {
        case .confirmFromMemory: appState.confirmMemoryCheck()
        case .showChecklist: onShowChecklist()
        case .advance: appState.nextPhase()
        case .confirmFreda: appState.confirmFreda()
        case .advanceAndConfirm: appState.advanceAndConfirmMemoryCheck()
        // Straight to it, as the phase bar's jump for one or two checks; from circuit height nothing
        // should ask a question. (6.1)
        case .goToLanding: appState.goToPhase(.landing)
        }
    }

    /// The slot for the flight as it stands.
    @MainActor
    static func slot(for appState: AppState, now: Date = Date()) -> CheckSlot {
        let phase = appState.currentPhase
        let next = phase.nextNavigable(circuitMode: appState.isCircuitMode)
        // The next check, when its cue came: offered in the slot as soon as this one is done. Only on the
        // flight's word: on the ground, and before any take-off was detected, the slot shows the next check
        // as it did before the cues. (6.1)
        let upcoming = next.flatMap { next -> CheckSlot.Upcoming? in
            guard appState.flightCues.cueHasCome(for: next, circuitMode: appState.isCircuitMode) else { return nil }
            return CheckSlot.Upcoming(check: check(of: next, in: appState), timing: appState.cueTiming(for: next),
                                      owedBy: appState.owedCue(for: next))
        }
        return CheckSlot.make(phase: phase, check: check(in: appState), next: next,
                              pendingAction: pendingAction(in: appState),
                              timing: appState.cueTiming(for: phase), owedBy: appState.owedCue(for: phase),
                              freda: freda(in: appState, now: now), upcoming: upcoming,
                              landingShown: appState.landingCheckShown ? check(of: .landing, in: appState) : nil)
    }

    /// FREDA while it runs (cruise, its check done). (6.1)
    @MainActor
    static func freda(in appState: AppState, now: Date = Date()) -> CheckSlotFreda? {
        let schedule = appState.freda
        guard appState.currentPhase == .cruise, let anchor = schedule.anchor else { return nil }
        if let due = schedule.due { return .due(waypoint: due.waypoint) }
        let remaining = schedule.remaining(now: now) ?? FredaSchedule.interval
        return .counting(after: schedule.since, at: anchor, minutesLeft: max(1, Int((remaining / 60).rounded(.up))))
    }

    /// A check the Cockpit isn't on (the next one, the landing check from circuit height), as it will be
    /// shown there: its items with the Memory test's setting, none checked unless worked through.
    @MainActor
    static func check(of phase: ChecklistPhase, in appState: AppState) -> CheckSlotCheck {
        guard phase != appState.currentPhase else { return check(in: appState) }
        let learning = appState.settings.learningMode
        if appState.isMemoryCheck(phase, learningMode: learning) {
            return .memory(done: appState.getPhaseStatus(phase).isDone
                || appState.getHighlightedItem(for: phase) >= appState.activeChecklist.visibleItemCount(for: phase, learningMode: true))
        }
        let visible = appState.activeChecklist.visibleItemCount(for: phase, learningMode: learning)
        guard visible > 0 else { return .none }
        return .list(open: max(0, appState.openItems(in: phase, learningMode: learning).count))
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

    /// ENGINE START or ENGINE SHUTDOWN, while unpressed in their phase: the ones a phase is recorded red
    /// without. (READY FOR LINE UP is the slot's advance out of the check before departure since 6.2.)
    @MainActor
    static func pendingAction(in appState: AppState) -> String? {
        let phase = appState.currentPhase
        guard phase.hasMissingRequiredAction(engineStarted: appState.engineStartTime != nil,
                                             engineShutDown: appState.engineShutdownTime != nil) else { return nil }
        let language = appState.settings.checklistLanguage.resolvedLanguage
        if phase.showsEngineStartButton { return L10n.ChecklistAction.engineStart(language: language) }
        return L10n.ChecklistAction.engineShutdown(language: language)
    }
}

/// The map's thumb controls in the iPad's landscape column, top to bottom. The check slot always heads
/// them on a row of its own, the column's width, in the same place in every phase. Beside Routes, with
/// no route, it had about 150 pt for its words and showed "CRUISE CH…" over "FREDA in 6…". Pure, so it
/// is tested without a view. (6.1)
enum MapThumbColumn: Equatable {
    /// Approach and landing: the slot, then GO AROUND and TOUCH-AND-GO.
    case slotOverFlightEvents
    /// A route to fly: the slot, then MARK with Divert and More.
    case slotOverMark
    /// No route: the slot, then Routes at the thumb bar's height, where MARK would be.
    case slotOverRoutes
    /// In flight with no slot: the leg timer and Divert, then MARK and More.
    case legTimerOverMark
    /// Not in flight (Plan › Map): Routes alone.
    case routes

    static func make(showsCheckSlot: Bool, showsEventButtons: Bool, hasRoute: Bool, flightActive: Bool) -> MapThumbColumn {
        if showsEventButtons { return .slotOverFlightEvents }
        if showsCheckSlot { return hasRoute ? .slotOverMark : .slotOverRoutes }
        if flightActive && hasRoute { return .legTimerOverMark }
        return .routes
    }

    /// Whether the slot has a row of its own.
    var slotHasOwnRow: Bool {
        switch self {
        case .slotOverFlightEvents, .slotOverMark, .slotOverRoutes: return true
        case .legTimerOverMark, .routes: return false
        }
    }
}

/// GO AROUND or TOUCH-AND-GO in the map's bottom row, in approach and landing (mockup M3): what the
/// checklist pane's buttons do, at the thumb bar's height. Hold 1 s to confirm, as there; a single tap in
/// circuits, as the checklist's thumb bar has them, for a quick correction of a missed detection. (6.1)
struct MapFlightEventButton: View {
    enum Event { case goAround, touchAndGo }
    let event: Event
    /// The words only, no icon: on the phone, and two to a row in the iPad's landscape column, where
    /// the icon left "TOUCH-AND…" about 120 pt. (6.1)
    var narrow: Bool = CockpitScale.current == .phone

    @Environment(AppState.self) private var appState
    @Environment(\.cockpitTheme) private var theme
    @EnvironmentObject private var flightEventDetector: FlightEventDetector

    var body: some View {
        let language = appState.settings.checklistLanguage.resolvedLanguage
        let title = event == .goAround ? L10n.ChecklistAction.goAround(language: language)
                                       : L10n.ChecklistAction.touchAndGo(language: language)
        let icon = event == .goAround ? "arrow.up.right.circle.fill" : "arrow.triangle.2.circlepath"
        if appState.isCircuitMode {
            CockpitThumbButton(title: title, icon: narrow ? nil : icon,
                               style: .outlined(tint: theme.action), action: perform)
        } else {
            HoldToConfirmButton(title: title, systemImage: icon, tint: theme.action,
                                count: event == .goAround ? appState.currentFlight?.goAroundCount ?? 0
                                                          : appState.currentFlight?.touchAndGoCount ?? 0,
                                kneeboard: true, height: CockpitTarget.thumb,
                                stacked: narrow, action: perform)
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

/// FREDA on the CHECKLIST pane's thumb bar, in cruise: where the cruise countdown was, the same size
/// (6.1, Q6). Until the cruise check is done it waits, dimmed. Then it counts down the ten minutes, and a
/// tap records FREDA done: early (a turning point of the pilot's own) or when due, amber. The old button
/// re-armed the countdown with a hold and re-ran the cruise list; this one records the flow. Nothing
/// pulses, nothing beeps.
struct FredaThumbButton: View {
    @Environment(AppState.self) private var appState
    @Environment(\.cockpitTheme) private var theme

    private enum Stage: Equatable {
        /// The cruise check is still open: FREDA doesn't run yet.
        case waiting
        case counting(TimeInterval)
        case due
    }

    var body: some View {
        if appState.currentPhase == .cruise && !appState.isCircuitMode {
            if appState.freda.isRunning && !appState.fredaDue {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    button(.counting(appState.freda.remaining(now: context.date) ?? FredaSchedule.interval))
                }
            } else {
                button(appState.fredaDue ? .due : .waiting)
            }
        }
    }

    private func button(_ stage: Stage) -> some View {
        let phone = CockpitScale.current == .phone
        return Button { appState.confirmFreda() } label: {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    if !phone {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.aero(size: CockpitType.response, weight: .bold))
                    }
                    Text(verbatim: L10n.Freda.name)
                        .font(.aero(size: CockpitType.button, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Text(subtitle(stage, phone: phone))
                    .font(.aero(size: CockpitType.label, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundColor(textColor(stage))
            .padding(.horizontal, phone ? 6 : 12)
            .frame(maxWidth: .infinity, minHeight: CockpitTarget.thumb)
            .background(background(stage))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .disabled(stage == .waiting)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(stage))
        .accessibilityHint(stage == .waiting ? "" : L10n.Freda.confirmHint)
    }

    private func subtitle(_ stage: Stage, phone: Bool) -> String {
        switch stage {
        case .waiting: return Self.countdown(FredaSchedule.interval)
        case .counting(let remaining): return Self.countdown(remaining)
        case .due: return phone ? L10n.Freda.flowCompact : L10n.Freda.flow
        }
    }

    /// "M:SS"
    static func countdown(_ remaining: TimeInterval) -> String {
        let seconds = max(0, Int(remaining.rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func accessibilityLabel(_ stage: Stage) -> String {
        switch stage {
        case .waiting: return L10n.Freda.afterCruiseCheck
        case .counting(let remaining): return L10n.Freda.inMinutes(max(1, Int((remaining / 60).rounded(.up))))
        case .due: return L10n.Freda.flowSpelledOut
        }
    }

    private func textColor(_ stage: Stage) -> Color {
        switch stage {
        case .waiting: return theme.textSecondary
        case .counting: return theme.action
        case .due: return theme.warning
        }
    }

    /// Dim while waiting; cyan, a thing to press, while counting; the slot's amber outline when due.
    @ViewBuilder
    private func background(_ stage: Stage) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18)
        switch stage {
        case .waiting:
            shape.fill(Color.subtleOverlay(0.05))
                .overlay(shape.stroke(Color.subtleOverlay(0.12), lineWidth: 1))
        case .counting:
            shape.fill(theme.action.opacity(0.12))
                .overlay(shape.stroke(theme.action.opacity(0.5), lineWidth: 1.5))
        case .due:
            shape.fill(theme.warning.opacity(0.16))
                .overlay(shape.strokeBorder(theme.warning, lineWidth: 3))
        }
    }
}
