import SwiftUI

// MARK: - The flight's checks (Flight Log)

/// The flight's checks on its page in the Flight Log (6.1, "Checks in flight", build plan 6). It reads like
/// the phase bar as the flight ended: what wasn't simply done gets a line of its own (owed and the cue that
/// passed it, done late, skipped, not sure, confirmed after landing), with its time, and FREDA its count
/// and times. A flight with nothing to look at says one line. Every check is one tap away.
///
/// A view of its own, so `FlightDetailView`'s body holds a reference rather than the whole tree.
struct FlightChecksSection: View {
    let debrief: CheckDebrief
    let useUTC: Bool

    @State private var showsEachCheck: Bool

    init(debrief: CheckDebrief, useUTC: Bool, showsEachCheck: Bool = false) {
        self.debrief = debrief
        self.useUTC = useUTC
        _showsEachCheck = State(initialValue: showsEachCheck)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.Debrief.title)
                .scaledFont(size: 11, weight: .semibold, relativeTo: .caption2)
                .tracking(0.5)
                .foregroundColor(.secondaryText)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 12) {
                if debrief.allDone {
                    AllChecksDoneLine(debrief: debrief)
                } else if debrief.isComplete {
                    CheckPhaseStrip(rows: debrief.rows)
                        // The rows below say the same, in words.
                        .accessibilityHidden(true)
                }
                if showsEachCheck {
                    ForEach(debrief.rows) { CheckDebriefRowView(row: $0, useUTC: useUTC) }
                } else if !debrief.allDone {
                    ForEach(debrief.noted) { CheckDebriefRowView(row: $0, useUTC: useUTC) }
                }
                if let freda = debrief.freda, showsEachCheck || !debrief.allDone {
                    FredaDebriefRowView(freda: freda, useUTC: useUTC)
                }
                if !debrief.allDone, !showsEachCheck, debrief.isComplete, debrief.othersCount > 0 {
                    Text(L10n.Debrief.othersDone(debrief.othersCount))
                        .scaledFont(size: 13, relativeTo: .footnote)
                        .foregroundColor(.secondaryText)
                }
                if debrief.isComplete {
                    eachCheckToggle
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    /// Shows or hides every check, done ones included.
    private var eachCheckToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { showsEachCheck.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(showsEachCheck ? L10n.Debrief.hideEach : L10n.Debrief.showEach)
                Image(systemName: showsEachCheck ? "chevron.up" : "chevron.down")
                    .accessibilityHidden(true)
            }
            .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
            .foregroundColor(.altimeterBlue)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "All checks done", and under it what is worth knowing all the same: the landing check confirmed after
/// the landing, the FREDAs flown.
private struct AllChecksDoneLine: View {
    let debrief: CheckDebrief

    private var notes: [String] {
        var parts = debrief.rows.filter { $0.status == .confirmedAfterLanding }
            .map { L10n.Debrief.confirmedAfterLanding($0.phase.shortTitle) }
        if let done = debrief.freda?.done.count, done > 0 {
            parts.append(L10n.Freda.name + " " + L10n.Debrief.fredaDone(done))
        }
        return parts
    }

    private var spokenNotes: [String] {
        var parts = debrief.rows.filter { $0.status == .confirmedAfterLanding }
            .map { L10n.Debrief.confirmedAfterLanding($0.phase.shortTitle) }
        if let done = debrief.freda?.done.count, done > 0 {
            parts.append(L10n.Freda.name + ", " + L10n.Debrief.fredaDoneSpoken(done))
        }
        return parts
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(size: 16, relativeTo: .body)
                .foregroundColor(.aviationGreen)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.Debrief.allDone)
                    .scaledFont(size: 15, weight: .semibold, relativeTo: .body)
                    .foregroundColor(.primaryText)
                if !notes.isEmpty {
                    Text(notes.joined(separator: " · "))
                        .scaledFont(size: 12, relativeTo: .caption)
                        .foregroundColor(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([L10n.Debrief.allDone] + spokenNotes).joined(separator: ". "))
    }
}

/// The phase bar as the flight ended, small: green done, a green outline confirmed after landing, amber
/// owed or not sure, orange skipped, red an action not done, grey nothing to do or not reached.
struct CheckPhaseStrip: View {
    let rows: [CheckDebrief.Row]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(rows) { row in
                segment(row.status)
                    .frame(height: 6)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func segment(_ status: CheckDebrief.Status) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2)
        switch status {
        case .confirmedAfterLanding:
            shape.fill(Color.cardBackground).overlay(shape.strokeBorder(Color.aviationGreen, lineWidth: 1.5))
        case .open:
            shape.fill(Color.dimText.opacity(0.3)).overlay(shape.strokeBorder(Color.dimText, lineWidth: 1))
        default:
            shape.fill(CheckDebriefStyle.tint(status))
        }
    }
}

/// One check: its name, what was recorded, and when.
struct CheckDebriefRowView: View {
    let row: CheckDebrief.Row
    let useUTC: Bool

    private var detail: String? {
        var parts: [String] = []
        if let owedAt = row.owedAt, row.status == .owed || row.status == .doneLate {
            parts.append("\(L10n.Debrief.cue(row.cue)), \(CheckDebriefStyle.time(owedAt, useUTC: useUTC))")
            if row.owedCount > 1 { parts.append(L10n.Debrief.owedTimes(row.owedCount)) }
        }
        if let at = row.at {
            let time = CheckDebriefStyle.time(at, useUTC: useUTC)
            switch row.status {
            case .doneLate: parts.append(L10n.Debrief.doneAt(time))
            case .owed: parts.append(L10n.Debrief.skippedAt(time))
            case .notSure, .confirmedAfterLanding: parts.append(L10n.Debrief.answeredAt(time))
            case .skipped, .actionMissing: parts.append(time)
            default: break
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ScaledMetric(relativeTo: .body) private var symbolColumn: CGFloat = 22

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: CheckDebriefStyle.symbol(row.status))
                .scaledFont(size: 15, relativeTo: .body)
                .foregroundColor(CheckDebriefStyle.symbolTint(row.status))
                .frame(width: symbolColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                CheckNameAndStatus(name: row.phase.shortTitle, status: L10n.Debrief.status(row.status),
                                   statusTint: CheckDebriefStyle.textTint(row.status))
                if let detail {
                    Text(detail)
                        .scaledFont(size: 12, relativeTo: .caption)
                        .foregroundColor(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// FREDA: how many done and missed, and when.
struct FredaDebriefRowView: View {
    let freda: CheckDebrief.Freda
    let useUTC: Bool

    private struct Entry {
        let date: Date
        let text: String
        let spoken: String
    }

    private var entries: [Entry] {
        let done = freda.done.compactMap { check -> Entry? in
            guard let at = check.doneAt else { return nil }
            let time = CheckDebriefStyle.time(at, useUTC: useUTC)
            let text = "✓ " + time + (check.waypoint.map { " " + $0 } ?? "")
            return Entry(date: at, text: text, spoken: L10n.Debrief.doneAt(time) + (check.waypoint.map { ", " + $0 } ?? ""))
        }
        let missed = freda.missed.compactMap { check -> Entry? in
            guard let due = check.dueAt else { return nil }
            let time = CheckDebriefStyle.time(due, useUTC: useUTC)
            let waypoint = check.waypoint.map { " " + $0 } ?? ""
            return Entry(date: due, text: L10n.Debrief.fredaMissedDue(time) + waypoint,
                         spoken: L10n.Debrief.fredaMissedDueSpoken(time) + (check.waypoint.map { ", " + $0 } ?? ""))
        }
        return (done + missed).sorted { $0.date < $1.date }
    }

    private var counts: String {
        var parts: [String] = []
        if !freda.done.isEmpty { parts.append(L10n.Debrief.fredaDone(freda.done.count)) }
        if !freda.missed.isEmpty { parts.append(L10n.Debrief.fredaMissed(freda.missed.count)) }
        return parts.joined(separator: " · ")
    }

    private var spokenCounts: String {
        var parts: [String] = []
        if !freda.done.isEmpty { parts.append(L10n.Debrief.fredaDoneSpoken(freda.done.count)) }
        if !freda.missed.isEmpty { parts.append(L10n.Debrief.fredaMissedSpoken(freda.missed.count)) }
        return parts.joined(separator: ", ")
    }

    private var tint: Color { freda.missed.isEmpty ? .aviationGreen : .aviationAmber }

    @ScaledMetric(relativeTo: .body) private var symbolColumn: CGFloat = 22

    var body: some View {
        let entries = self.entries
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: freda.missed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .scaledFont(size: 15, relativeTo: .body)
                .foregroundColor(tint)
                .frame(width: symbolColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                CheckNameAndStatus(name: L10n.Freda.name, status: counts,
                                   statusTint: freda.missed.isEmpty ? .aviationGreen : .aviationAmber)
                if !entries.isEmpty {
                    Text(entries.map(\.text).joined(separator: " · "))
                        .scaledFont(size: 12, relativeTo: .caption)
                        .foregroundColor(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([L10n.Freda.name, spokenCounts] + entries.map(\.spoken)).joined(separator: ", "))
    }
}

// MARK: - The trend (Logbook)

/// What keeps coming back across the last flights, in the Logbook's summary: "CLIMB CHECK · owed on 4 of
/// 10 flights". Only patterns; the Logbook shows nothing when there is none. (6.1)
struct ChecksTrendCard: View {
    let trend: CheckTrend

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Debrief.trendTitle(trend.flights))
                .scaledFont(size: 11, weight: .semibold, relativeTo: .caption2)
                .tracking(0.6)
                .foregroundColor(.secondaryText)
                .accessibilityAddTraits(.isHeader)
            ForEach(trend.patterns) { pattern in
                ChecksTrendLine(pattern: pattern, flights: trend.flights)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        )
    }
}

private struct ChecksTrendLine: View {
    let pattern: CheckTrend.Pattern
    let flights: Int

    private var name: String {
        switch pattern.subject {
        case .check(let phase, _): return phase.shortTitle
        case .fredaMissed: return L10n.Freda.name
        }
    }

    private var line: String {
        switch pattern.subject {
        case .check(_, let kind): return L10n.Debrief.trend(kind, pattern.count, of: flights)
        case .fredaMissed: return L10n.Debrief.fredaMissed(pattern.count)
        }
    }

    private var spokenLine: String {
        switch pattern.subject {
        case .check: return line
        case .fredaMissed: return L10n.Debrief.fredaMissedSpoken(pattern.count)
        }
    }

    @ScaledMetric(relativeTo: .footnote) private var symbolColumn: CGFloat = 18

    private var status: CheckDebrief.Status {
        switch pattern.subject {
        case .check(_, .owed): return .owed
        case .check(_, .skipped): return .skipped
        case .check(_, .notSure): return .notSure
        case .fredaMissed: return .owed
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: CheckDebriefStyle.symbol(status))
                .scaledFont(size: 13, relativeTo: .footnote)
                .foregroundColor(CheckDebriefStyle.symbolTint(status))
                .frame(width: symbolColumn)
                .accessibilityHidden(true)
            CheckNameAndStatus(name: name, status: line, statusTint: .secondaryText, size: 12)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(spokenLine)")
    }
}

/// A check's name and its status: on one line where they fit ("CLIMB CHECK  owed, never done"), the
/// status under the name where they don't (the phone, large text). Two fixed candidates: `ViewThatFits`
/// must never get a `ForEach`.
private struct CheckNameAndStatus: View {
    let name: String
    let status: String
    let statusTint: Color
    var size: CGFloat = 13

    private var nameText: some View {
        Text(name)
            .scaledFont(size: size, weight: .semibold, relativeTo: .subheadline)
            .foregroundColor(.primaryText)
    }

    private var statusText: some View {
        Text(status)
            .scaledFont(size: size, relativeTo: .subheadline)
            .foregroundColor(statusTint)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                nameText
                statusText
            }
            VStack(alignment: .leading, spacing: 2) {
                nameText
                statusText.fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Colours, symbols, times

/// The debrief's colours follow the phase bar's (ground screens: the legacy statics), and every status has
/// a symbol too, so nothing is said by colour alone.
enum CheckDebriefStyle {
    static func tint(_ status: CheckDebrief.Status) -> Color {
        switch status {
        case .done, .doneFromMemory, .confirmedAfterLanding, .doneLate: return .aviationGreen
        case .owed, .notSure: return .aviationAmber
        case .skipped: return .orange
        case .actionMissing: return .aviationRed
        case .nothingToDo: return .dimText.opacity(0.5)
        case .open, .notReached: return .dimText.opacity(0.3)
        }
    }

    /// The symbol: the segment's colour, readable where the segment is faint.
    static func symbolTint(_ status: CheckDebrief.Status) -> Color {
        switch status {
        case .nothingToDo, .open, .notReached: return .dimText
        default: return tint(status)
        }
    }

    /// The status's words: the colour of the segment, except where that is too faint to read, and done
    /// late, which reads amber (it was owed first).
    static func textTint(_ status: CheckDebrief.Status) -> Color {
        switch status {
        case .doneLate: return .aviationAmber
        case .nothingToDo, .open, .notReached: return .secondaryText
        default: return tint(status)
        }
    }

    static func symbol(_ status: CheckDebrief.Status) -> String {
        switch status {
        case .done, .doneFromMemory: return "checkmark.circle.fill"
        case .confirmedAfterLanding: return "checkmark.circle"
        case .doneLate: return "clock.badge.checkmark"
        case .owed: return "exclamationmark.triangle.fill"
        case .notSure: return "questionmark.circle.fill"
        case .skipped: return "forward.circle.fill"
        case .actionMissing: return "xmark.circle.fill"
        case .nothingToDo: return "minus.circle"
        case .open: return "circle.dashed"
        case .notReached: return "circle.dotted"
        }
    }

    static func time(_ date: Date, useUTC: Bool) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        if useUTC { formatter.timeZone = TimeZone(identifier: "UTC") }
        return formatter.string(from: date)
    }
}
