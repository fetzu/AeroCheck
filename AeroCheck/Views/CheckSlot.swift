import SwiftUI

// MARK: - The check slot (6.1, "Checks in flight" Q1)
//
// In flight, the act band's first slot holds the next thing to do with the checklist (on MAP always, on
// CHECKLIST outside the engine phases and cruise, since 6.2), and one tap does it: confirm a memory check (done from memory, with undo), open a list
// still to check on the CHECKLIST page, or, the check done, go on to the next one. It is 104 pt tall on
// the kneeboard (92 on the phone) and always in the same place, so the thumb learns it; before it,
// marking the climb check done from the map took CHECKLIST at the top, then NEXT at the foot.
//
// Its colour says when: dark while nothing is due, amber (outlined) when the check is due, filled amber
// once, when the flight moved on with it still open, and dashed grey in the landing phase, where there
// is nothing to press until the runway is behind. Nothing pulses, nothing beeps, and it never changes
// the page on its own. "Due" comes from the flight (FlightCues.swift): the climb check at 500 ft above the
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
        /// Shows the CHECKLIST page; the map comes back after the last CHECK, by the page rule.
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
    /// `locale`: the clock the time is written in, the device's.
    func titleText(stacked: Bool = false, locale: Locale = .autoupdatingCurrent) -> String {
        firstLine(stacked: stacked) { $0.formatted(Self.clock(locale)) }
    }

    /// The first line, the tick's time written by `time`.
    private func firstLine(stacked: Bool, time: (Date) -> String) -> String {
        switch title {
        case .check: return readiesForLineUp ? L10n.ChecklistAction.readyForLineUp : phase.shortTitle
        case .freda: return L10n.Freda.name
        case .fredaCountsFrom(let since, let at):
            let what = since == .cruiseCheck ? ChecklistPhase.cruise.shortTitle : L10n.Freda.name
            let written = time(at)
            return stacked ? L10n.Freda.tickedStacked(what, written) : L10n.Freda.ticked(what, written)
        }
    }

    /// The tick's time as the device writes it: "14:24", or "2:24 PM" on a 12-hour clock.
    private static func clock(_ locale: Locale) -> Date.FormatStyle {
        Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
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

    /// The room the first line keeps: its words, the time at its widest, "CRUISE CHECK ✓ 00:00", so the
    /// time it reads changes nothing. (6.1, the slot's text centred)
    ///
    /// The time is written at 22:58 whatever the tick's, as the read band's clock is
    /// (`NextWaypointReadout.widestETA`): on a 12-hour clock the room was "✓ 00:00 AM" for a tick at 9:05
    /// and "✓ 00:00 PM" for one at 14:24. (6.2)
    func titleRoom(stacked: Bool = false, locale: Locale = .autoupdatingCurrent) -> String {
        Self.widestFigures(firstLine(stacked: stacked) { _ in Self.roomTime.formatted(Self.clock(locale)) }, atLeast: 2)
    }

    /// Two figures to its hour, and PM on a 12-hour clock.
    private static var roomTime: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 22, minute: 58)) ?? .distantPast
    }

    /// The room the second line keeps: the state's words, FREDA's minutes at the 10 they count down from
    /// ("FREDA in 10 min"), so 10 turning 9 keeps the same room, and a count with as many figures as it
    /// has, in its plural. Only a change of state changes it. A count kept at two figures could take two
    /// lines where "5 items" takes one, and leave the empty line this is about: a list going from ten
    /// items to nine is the one tick that can change the room. (6.1, the slot's text centred)
    func lineRoom(narrow: Bool = false, stacked: Bool = false) -> String {
        let widest = CheckSlot(phase: phase, line: line.widest, icon: icon, tone: tone, action: action, title: title)
        return Self.widestFigures(widest.lineText(narrow: narrow, stacked: stacked), atLeast: 1)
    }

    /// `text` with every figure a zero, and every number at least `atLeast` figures: with 2, "✓ 9:05"
    /// reads "✓ 00:00". B612's figures are all one width, so no number is wider than its zeros.
    static func widestFigures(_ text: String, atLeast minimum: Int) -> String {
        var result = ""
        var figures = 0
        func flush() {
            if figures > 0 { result += String(repeating: "0", count: max(minimum, figures)) }
            figures = 0
        }
        for character in text {
            if character.wholeNumberValue != nil {
                figures += 1
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
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

    /// The same line at its widest for the state: FREDA's minutes at the 10 they count down from, a
    /// count in its plural ("2 items", where "1 item" is shorter).
    var widest: CheckSlot.Line {
        switch self {
        case .items(let count): return .items(max(count, 2))
        case .itemsQuiet(let count): return .itemsQuiet(max(count, 2))
        case .fredaIn(let minutes): return .fredaIn(minutes: max(minutes, 10))
        default: return self
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
    @Environment(\.actSlotHeight) private var slotHeight

    /// The slot's height: the thumb bar's, 104 pt on the kneeboard and 92 on the phone; its slot's in the
    /// act band (76 pt in the phone's grid on its side).
    static var height: CGFloat { CockpitTarget.thumb }

    var body: some View {
        let phone = CockpitScale.current == .phone
        // The phone's slot in the act band is about 100 pt wide: no icon (the colour and the frame say
        // the state), the name and the short line set to fit it (`CheckSlotLabel`).
        let narrow = phone && !prominent
        Button(action: action) {
            // The name and its line in the middle of the slot's height, the icon beside them.
            HStack(spacing: phone ? 8 : 16) {
                if !narrow {
                    Image(systemName: iconName)
                        .font(.aero(size: prominent ? CockpitType.size(kneeboard: 38, phone: 28)
                                                    : CockpitType.size(kneeboard: 32, phone: 24),
                                    weight: .semibold))
                }
                CheckSlotLabel(slot: slot, prominent: prominent, lineColor: lineColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundColor(textColor)
            // The phone's act band slot is about 100 pt wide (6.2): its words 8 pt in, 5 pt clear of the
            // amber border, set to fit (`ActFace`). At 6 pt "CROISIÈRE" ran into the border.
            .padding(.horizontal, narrow ? ActFace.inset : phone ? 10 : 22)
            .frame(maxWidth: .infinity, minHeight: slotHeight ?? Self.height, maxHeight: slotHeight ?? Self.height)
            .background(background)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        // The state for a UI test, which reads no colour: "checkSlot.due.confirmFromMemory". Never read out.
        .accessibilityIdentifier("checkSlot.\(slot.tone).\(slot.action.rawValue)")
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

/// The slot's name and the line under it, which the button centres in its height. Each keeps the room
/// its state takes at its widest (`CheckSlot.titleRoom`, `lineRoom`), laid out as the text is, filled or
/// not: "FREDA in 10 min" turning "9 min", a time, or a line shrinking to fit never moves the name. The room
/// changes with the state alone (a check coming due, done, owed), and the two lines then centre again
/// in the same frame. Until 6.1.0 the room for two lines was kept in every state, and a one-line
/// "5 items" sat high in the slot over an empty line. (6.1, the slot's text centred)
struct CheckSlotLabel: View {
    let slot: CheckSlot
    var prominent: Bool = false
    var lineColor: Color = .secondary
    /// The device's; the tests lay the phone's out on an iPad.
    var scale: CockpitScale = .current

    var body: some View {
        if prominent {
            wideLabel
        } else {
            // In the act band: the phone's slot, about 100 pt wide, and the iPad's beside MARK or the hold
            // buttons (about 160 pt of text in portrait, 340 on its side). The name and its line set to fit
            // it (`ActFace`): a number kept with its noun ("2 éléments"), nothing cut, never under the
            // in-flight label size where the words fit at it. Each sized by its room, so a value ticking
            // moves nothing. Left to SwiftUI, the phone's broke "2" from "éléments" and the iPad's cut "de
            // mémoire · un appui quand c'est fait" after "c'est". (6.2)
            ActFaceText(blocks: Self.blocks(slot, scale: scale, lineColor: lineColor), alignment: .leading)
        }
    }

    /// The name, then its line, as the band's slot sets them on `scale`'s device: the phone's short line
    /// (`CheckSlot.Line.shortText`), the iPad's whole one (`stackedText`).
    static func blocks(_ slot: CheckSlot, scale: CockpitScale, lineColor: Color? = nil) -> [ActFaceBlock] {
        let phone = scale == .phone
        return blocks(title: slot.titleText(stacked: true), titleRoom: slot.titleRoom(stacked: true),
                      line: slot.lineText(narrow: phone, stacked: !phone),
                      lineRoom: slot.lineRoom(narrow: phone, stacked: !phone), scale: scale, lineColor: lineColor)
    }

    /// The name at 19 pt on the phone (up to three lines), 25 on the iPad (up to two, one where it stays at
    /// the label size or over: "CRUISE CHECK" on one line, as it was); the line at the label size, up to
    /// three; neither under the label size where the words fit at it.
    static func blocks(title: String, titleRoom: String? = nil, line: String, lineRoom: String? = nil,
                       scale: CockpitScale, lineColor: Color? = nil) -> [ActFaceBlock] {
        let label = CockpitType.label(for: scale)
        return [ActFaceBlock(text: title, size: CockpitType.size(kneeboard: 25, phone: 19, scale: scale),
                             maxLines: scale == .phone ? 3 : 2, floor: label, room: titleRoom,
                             prefersFewerLines: scale != .phone),
                ActFaceBlock(text: line, size: label, bold: false, maxLines: 3, floor: label, room: lineRoom,
                             color: lineColor)]
    }

    /// The Companion iPhone's wide slot (`prominent`): the name at the button size, its line under it, on
    /// two lines each.
    private var wideLabel: some View {
        let phone = scale == .phone
        let lines = phone ? 2 : 1
        return VStack(alignment: .leading, spacing: 4) {
            Self.text(slot.titleText(), room: slot.titleRoom(),
                      font: .aero(size: CockpitType.button(for: scale), weight: .bold), lines: lines, minimumScale: 0.6)
            Self.text(slot.lineText(), room: slot.lineRoom(), font: .aero(size: CockpitType.label(for: scale), weight: .medium),
                      lines: lines, minimumScale: 0.8)
                .foregroundColor(lineColor)
        }
    }

    /// `text` from the top of the room `room` takes, laid out as `text` is (in at most `lines` lines,
    /// shrinking as far as `minimumScale` to fit). The text is drawn within that room and never sizes
    /// it: as wide or narrower than the room's, it fits it, shrinking a little more if it must.
    private static func text(_ text: String, room: String, font: Font, lines: Int,
                             minimumScale: CGFloat) -> some View {
        Text(verbatim: room)
            .font(font)
            .lineLimit(lines)
            .minimumScaleFactor(minimumScale)
            .hidden()
            .accessibilityHidden(true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                Text(verbatim: text)
                    .font(font)
                    .lineLimit(lines)
                    .minimumScaleFactor(minimumScale)
            }
    }
}

/// The slot as the Cockpit's act band shows it: the current check from `AppState`, and what a tap does.
/// A view of its own, so the band's body only holds a reference to it (see `SeparateView`).
struct CockpitCheckSlot: View {
    /// Shows the CHECKLIST page (on MAP), or brings the list's current item into view (on CHECKLIST).
    let onShowChecklist: () -> Void
    var prominent: Bool = false

    @Environment(AppState.self) private var appState

    var body: some View {
        // FREDA counting shows its minutes: redrawn as they pass. Due, the next evaluation redraws it.
        if appState.freda.isRunning && !appState.fredaDue {
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                button(Self.slot(for: appState, now: FlightClock.now))
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
    static func slot(for appState: AppState, now: Date = FlightClock.now) -> CheckSlot {
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
    static func freda(in appState: AppState, now: Date = FlightClock.now) -> CheckSlotFreda? {
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

/// GO AROUND or TOUCH-AND-GO in the act band, from the approach to the runway (mockup M3): what the
/// checklist's event row does, at the band's height. Hold 1 s to confirm, as there; a single tap in
/// circuits, for a quick correction of a missed detection. GO AROUND takes MARK's slot, TOUCH-AND-GO
/// Divert's, the narrow one, on two lines ("TOUCH-" over "AND-GO") at the in-flight label size or
/// larger. (6.1; act band 6.2)
struct MapFlightEventButton: View {
    enum Event { case goAround, touchAndGo }
    let event: Event
    /// The words only, no icon: on the phone, and in the band's narrow slot. (6.1)
    var narrow: Bool = CockpitScale.current == .phone
    /// The words broken on two lines (`ActBandText.twoLines`).
    var twoLines: Bool = false
    /// The words' inset from the edges, where the slot sets another than the narrow slot's.
    var horizontalInset: CGFloat? = nil

    @Environment(AppState.self) private var appState
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.actSlotHeight) private var slotHeight
    @EnvironmentObject private var flightEventDetector: FlightEventDetector

    var body: some View {
        let language = appState.settings.checklistLanguage.resolvedLanguage
        let name = event == .goAround ? L10n.ChecklistAction.goAround(language: language)
                                      : L10n.ChecklistAction.touchAndGo(language: language)
        let title = twoLines ? ActBandText.twoLines(name) : name
        let icon = event == .goAround ? "arrow.up.right.circle.fill" : "arrow.triangle.2.circlepath"
        let identifier = event == .goAround ? "map.goAround" : "map.touchAndGo"
        let height = slotHeight ?? CockpitTarget.thumb
        // On the phone GO AROUND has a wide slot, its words 8 pt in; TOUCH-AND-GO the narrow one. Set to fit
        // (`ActFace`) on both devices; on the iPad GO AROUND keeps its icon and its count beside. (6.2)
        let phone = CockpitScale.current == .phone
        let padding: CGFloat? = horizontalInset
            ?? (narrow ? (phone && event == .goAround ? ActFace.inset : ActBandMetrics.narrowPadding()) : nil)
        if appState.isCircuitMode {
            CockpitThumbButton(title: title, icon: narrow ? nil : icon, style: .outlined(tint: theme.action),
                               titleLines: 2, horizontalPadding: padding ?? 14, minHeight: height,
                               fitted: true, action: perform)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(name)
        } else {
            HoldToConfirmButton(title: title, systemImage: icon, tint: theme.action,
                                count: narrow ? 0 : event == .goAround ? appState.currentFlight?.goAroundCount ?? 0
                                                                       : appState.currentFlight?.touchAndGoCount ?? 0,
                                kneeboard: true, height: height,
                                stacked: narrow, titleLines: twoLines ? 2 : 1, horizontalPadding: padding,
                                spokenTitle: name, fitted: true, action: perform)
                .accessibilityIdentifier(identifier)
        }
    }

    /// As the checklist page's: the detector is told first, so it doesn't prompt for the same event, and
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

/// FREDA in the act band's first slot on CHECKLIST, in cruise: where the cruise countdown was (6.1, Q6;
/// the band 6.2). Until the cruise check is done it waits, dimmed. Then it counts down the ten minutes, and a
/// tap records FREDA done: early (a turning point of the pilot's own) or when due, amber. The old button
/// re-armed the countdown with a hold and re-ran the cruise list; this one records the flow. Nothing
/// pulses, nothing beeps.
struct FredaThumbButton: View {
    @Environment(AppState.self) private var appState
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.actSlotHeight) private var slotHeight

    private enum Stage: Equatable {
        /// The cruise check is still open: FREDA doesn't run yet.
        case waiting
        case counting(TimeInterval)
        case due

        /// For the accessibility identifier a UI test reads.
        var testName: String {
            switch self {
            case .waiting: return "waiting"
            case .counting: return "counting"
            case .due: return "due"
            }
        }
    }

    var body: some View {
        if appState.currentPhase == .cruise && !appState.isCircuitMode {
            if appState.freda.isRunning && !appState.fredaDue {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    button(.counting(appState.freda.remaining(now: FlightClock.now) ?? FredaSchedule.interval))
                }
            } else {
                button(appState.fredaDue ? .due : .waiting)
            }
        }
    }

    private func button(_ stage: Stage) -> some View {
        let phone = CockpitScale.current == .phone
        return Button { appState.confirmFreda() } label: {
            Group {
                // Set to fit the slot (`ActFace`), the countdown in figures that keep their place; the
                // iPad's icon beside. (6.2)
                if phone {
                    ActFaceText(blocks: Self.blocks(line: subtitle(stage, phone: true), scale: .phone))
                } else {
                    ActFaceText(blocks: Self.blocks(line: subtitle(stage, phone: false), scale: .kneeboard),
                                icon: "arrow.triangle.2.circlepath", iconSize: CockpitType.response, iconSpacing: 8)
                }
            }
            .foregroundColor(textColor(stage))
            .padding(.horizontal, phone ? ActFace.inset : 12)
            .frame(maxWidth: .infinity, minHeight: slotHeight ?? CockpitTarget.thumb)
            .background(background(stage))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .disabled(stage == .waiting)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("cockpit.freda.\(stage.testName)")
        .accessibilityLabel(accessibilityLabel(stage))
        .accessibilityHint(stage == .waiting ? "" : L10n.Freda.confirmHint)
    }

    /// FREDA over its countdown or its letters, as the slot sets them on `scale`'s device. The letters
    /// spaced out ("F · R · E · D · A", the iPad's) stay on one line.
    static func blocks(line: String, scale: CockpitScale) -> [ActFaceBlock] {
        let label = CockpitType.label(for: scale)
        let line = line == L10n.Freda.flow ? line.replacingOccurrences(of: " ", with: "\u{00A0}") : line
        return [ActFaceBlock(text: L10n.Freda.name, size: CockpitType.button(for: scale), maxLines: 1, floor: label),
                ActFaceBlock(text: line, size: label, maxLines: 2, floor: label,
                             room: CheckSlot.widestFigures(line, atLeast: 1))]
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
