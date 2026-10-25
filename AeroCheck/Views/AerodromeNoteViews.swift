import MapKit
import SwiftUI
import UIKit

// MARK: - The pilot's note in an aerodrome's callout (6.7.0, n2 A)
//
// Every map's aerodrome callout: under the name and frequencies, the note's first line, and a button
// that opens it (More) or starts one (Add a note). In flight a note only reads, and none is started
// (n3 A). Built when the marker is drawn and again when it is selected, so a note written since shows.

extension AerodromeRef: Identifiable {
    var id: String { ident }
}

enum AerodromeNoteCallout {
    /// The callout's detail view, or nil when it would hold nothing.
    /// - Parameters:
    ///   - frequencyLines: the field's name and frequencies, as the nav map shows them; nil on maps without.
    ///   - onOpen: opens the note's sheet; nil where the map can't (no button then).
    @MainActor
    static func detailView(airport: Airport, frequencyLines: String?, note: AerodromeNote?, inFlight: Bool,
                           metrics: CalloutMetrics, tint: UIColor, onOpen: (() -> Void)?) -> UIView? {
        var rows: [UIView] = []
        if let frequencyLines {
            let label = UILabel()
            label.numberOfLines = 0
            let text = NSMutableAttributedString(string: airport.name + "\n", attributes: [
                .font: UIFont.aero(size: 12, weight: .medium), .foregroundColor: UIColor.label])
            text.append(NSAttributedString(string: frequencyLines, attributes: [
                .font: UIFont.aero(size: 12, monospaced: true), .foregroundColor: UIColor.secondaryLabel]))
            label.attributedText = text
            rows.append(label)
        }
        if let note, !note.isEmpty {
            let label = UILabel()
            label.numberOfLines = 2
            label.preferredMaxLayoutWidth = 260
            let title = (note.hasArrival ? L10n.AerodromeNotes.yourNoteArrival : L10n.AerodromeNotes.yourNote).uppercased()
            let text = NSMutableAttributedString(string: title + "\n", attributes: [
                .font: UIFont.aero(size: 10, weight: .bold, monospaced: true), .kern: 0.8,
                .foregroundColor: UIColor(Color.aviationGold)])
            text.append(NSAttributedString(string: note.firstLine, attributes: [
                .font: UIFont.aero(size: 13), .foregroundColor: UIColor.label]))
            label.attributedText = text
            label.accessibilityIdentifier = "callout.note.text"
            rows.append(label)
        }
        let hasNote = note.map { !$0.isEmpty } ?? false
        if let onOpen, hasNote || !inFlight {
            let button = UIButton(type: .system)
            button.setTitle(hasNote ? L10n.AerodromeNotes.more : L10n.AerodromeNotes.add, for: .normal)
            button.titleLabel?.font = UIFont.aero(size: metrics.fontSize, weight: .semibold)
            button.tintColor = tint
            button.contentHorizontalAlignment = .leading
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: metrics.target).isActive = true
            button.addAction(UIAction { _ in onOpen() }, for: .touchUpInside)
            button.accessibilityIdentifier = hasNote ? "callout.note.open" : "callout.note.add"
            rows.append(button)
        }
        guard !rows.isEmpty else { return nil }
        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }
}

// MARK: - The flight's page (6.7.0, n2 A and n4 A)

extension AerodromeRef {
    /// The flight's aerodromes, departure first, then its stops and its destination: the route's aerodromes
    /// the data knows, each once. A route's own points (a VRP, a pilot's point) are left out.
    @MainActor
    static func flightAerodromes(of plan: FlightPlan?, airports: AirportDataService) -> [AerodromeRef] {
        flightAerodromes(of: plan) { airports.findAirport(byIdent: $0) }
    }

    static func flightAerodromes(of plan: FlightPlan?, find: (String) -> Airport?) -> [AerodromeRef] {
        guard let plan, !plan.waypoints.isEmpty else { return [] }
        var result: [AerodromeRef] = []
        for (index, waypoint) in plan.waypoints.enumerated() {
            let isEnd = index == 0 || index == plan.waypoints.count - 1
            guard isEnd || waypoint.stopover != nil || waypoint.pointKind == .aerodrome else { continue }
            let ident = (waypoint.pointKind == .aerodrome ? waypoint.sourceId : nil) ?? waypoint.name
            guard let airport = find(ident.trimmingCharacters(in: .whitespaces).uppercased()),
                  !result.contains(where: { $0.ident == airport.ident }) else { continue }
            result.append(AerodromeRef(airport))
        }
        return result
    }
}

/// A line per aerodrome of the flight in its route block, with the pilot's note or an offer to write one.
/// Never a task, never counted, nothing to tick.
struct AerodromeNoteLines: View {
    let aerodromes: [AerodromeRef]
    let onOpen: (AerodromeRef) -> Void
    @ObservedObject private var store = AerodromeNoteStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(aerodromes) { ref in
                let note = store.note(for: ref)
                Button { onOpen(ref) } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(L10n.AerodromeNotes.yourNote.uppercased())
                                    .scaledFont(size: 10, weight: .bold, design: .monospaced, relativeTo: .caption2)
                                    .tracking(1)
                                    .foregroundColor(.aviationGold)
                                Text("\(ref.ident) \(ref.name)")
                                    .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                                    .foregroundColor(.primaryText)
                                    .lineLimit(1)
                            }
                            Text(note.map(\.firstLine) ?? L10n.AerodromeNotes.none)
                                .scaledFont(size: 12, relativeTo: .caption)
                                .foregroundColor(.secondaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text(note == nil ? L10n.AerodromeNotes.add : L10n.AerodromeNotes.more)
                            .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                            .foregroundColor(.aviationGold)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("flightPage.note.\(ref.ident)")
            }
        }
    }
}

/// CLOSE, after landing: the field landed at, and a word to remember about it for next time.
struct AerodromeNoteCloseOffer: View {
    let aerodrome: AerodromeRef
    let onOpen: () -> Void
    @ObservedObject private var store = AerodromeNoteStore.shared

    var body: some View {
        let note = store.note(for: aerodrome)
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: "note.text")
                    .scaledFont(size: 17, relativeTo: .body)
                    .foregroundColor(.aviationGold)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(note == nil ? L10n.AerodromeNotes.closeOffer(aerodrome.name)
                         : L10n.AerodromeNotes.yourNoteOn(aerodrome.ident))
                        .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                        .foregroundColor(.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(note?.firstLine ?? L10n.AerodromeNotes.closeOfferHint(aerodrome.ident))
                        .scaledFont(size: 13, relativeTo: .caption)
                        .foregroundColor(.secondaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 6)
                Text(note == nil ? L10n.AerodromeNotes.write : L10n.AerodromeNotes.edit)
                    .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                    .foregroundColor(.aviationGold)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        .accessibilityIdentifier("closeOut.aerodromeNote")
    }
}

// MARK: - In flight: the approach briefing (n3 A)

/// The destination's Arrival part, read in flight at the Cockpit's sizes; nothing without one.
struct AerodromeNoteBriefingSection: View {
    @Environment(\.cockpitTheme) private var theme
    let aerodrome: Airport?
    @ObservedObject private var store = AerodromeNoteStore.shared

    var body: some View {
        if let aerodrome, let note = store.note(for: aerodrome), note.hasArrival {
            BriefingSection(title: L10n.AerodromeNotes.yourNoteArrival.uppercased()) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AerodromeNoteText.attributed(AerodromeNote.trimmed(note.arrival)))
                        .font(.aero(size: CockpitType.label))
                        .foregroundColor(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(note.updatedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.aero(size: CockpitType.label - 4))
                        .foregroundColor(theme.textDim)
                }
            }
            .accessibilityIdentifier("briefing.aerodromeNote")
        }
    }
}
