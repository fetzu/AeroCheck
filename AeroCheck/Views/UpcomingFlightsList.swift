import SwiftUI

// MARK: - Upcoming flights (v5.0.0)
//
// The other half of the Flights destination. Flown flights live in Past; these are the ones still
// owed something — planned, being prepared, in the air, or waiting to be closed out.
//
// Close-out comes FIRST, always, and not because it is newest. It is the only state in this app with
// a real-world consequence for being ignored, and a pilot who has just landed opens this screen for
// exactly one reason.

struct UpcomingFlightsList: View {
    let threads: [FlightThread]
    let onOpen: (UUID) -> Void
    let onPlanNew: () -> Void

    private var needsAttention: [FlightThread] { threads.filter { $0.state == .closeOut } }
    private var ahead: [FlightThread] { threads.filter { $0.state != .closeOut } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                planButton

                if threads.isEmpty {
                    emptyState
                } else {
                    if !needsAttention.isEmpty {
                        section(L10n.Flights.needsAttention, tint: .aviationRed, threads: needsAttention)
                    }
                    if !ahead.isEmpty {
                        section(L10n.Flights.upcoming, tint: .secondaryText, threads: ahead)
                    }
                }
            }
            .padding(16)
        }
    }

    private var planButton: some View {
        Button(action: onPlanNew) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.plus")
                    .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                Text(L10n.Flights.planNewFlight)
                    .scaledFont(size: 15, weight: .bold, relativeTo: .subheadline)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle())
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.Flights.nothingPlanned)
                .scaledFont(size: 17, weight: .semibold, relativeTo: .title3)
                .foregroundColor(.primaryText)
            Text(L10n.Flights.homeExplainer)
                .scaledFont(size: 13, relativeTo: .callout)
                .foregroundColor(.dimText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.panelBackground))
    }

    private func section(_ title: String, tint: Color, threads: [FlightThread]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .scaledFont(size: 11, weight: .bold, design: .monospaced, relativeTo: .caption2)
                .foregroundColor(tint)
                .tracking(0.8)
            ForEach(threads) { thread in
                row(thread)
            }
        }
    }

    private func row(_ thread: FlightThread) -> some View {
        let closing = thread.state == .closeOut
        let progress = closing ? thread.closeOutProgress : thread.preFlightProgress
        return Button { onOpen(thread.id) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(thread.routeLabel)
                        .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                        .foregroundColor(.primaryText)
                        .lineLimit(1)
                    Text(detail(thread))
                        .scaledFont(size: 12, design: .monospaced, relativeTo: .caption)
                        .foregroundColor(.dimText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(badge(thread))
                    .scaledFont(size: 10, weight: .bold, design: .monospaced, relativeTo: .caption2)
                    .tracking(0.6)
                    .foregroundColor(closing ? .aviationRed : .aviationGold)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(closing ? Color.aviationRed : Color.aviationGold, lineWidth: 1)
                    )
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.cardBackground)
                    .overlay(alignment: .leading) {
                        // A rail rather than a full border: the close-out row has to be findable
                        // without reading, and only that row earns the colour.
                        if closing {
                            Rectangle().fill(Color.aviationRed).frame(width: 3)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(thread.routeLabel), \(badge(thread)), \(detail(thread))")
            .accessibilityValue(Text(verbatim: "\(progress.done)/\(progress.total)"))
        }
        .buttonStyle(.plain)
    }

    private func badge(_ thread: FlightThread) -> String {
        switch thread.state {
        case .planned:  return L10n.Thread.chapterPlan
        case .ready:    return L10n.Thread.chapterPrepare
        case .flying:   return L10n.Thread.chapterFly
        case .closeOut, .done: return L10n.Thread.chapterClose
        }
    }

    /// What is actually left, rather than a timestamp. A pilot scanning this list is deciding what to
    /// pick up next, and "2 to do" answers that where "updated 3 h ago" does not.
    private func detail(_ thread: FlightThread) -> String {
        var parts: [String] = []
        if let departure = thread.scheduledDeparture {
            parts.append(departure.formatted(date: .abbreviated, time: .shortened))
        }
        if let registration = thread.aircraftRegistration, !registration.isEmpty {
            parts.append(registration)
        }
        let progress = thread.state == .closeOut ? thread.closeOutProgress : thread.preFlightProgress
        let remaining = max(0, progress.total - progress.done)
        if remaining > 0 { parts.append(L10n.Flights.toDo(remaining)) }
        return parts.joined(separator: " · ")
    }
}
