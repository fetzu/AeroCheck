import SwiftUI

// MARK: - See all

/// Every NOTAM of the route's countries: along the flight first, the rest folded with their counts, nothing left out. A
/// line says what the sorting used, so nobody takes a filter for the truth.
struct NotamAllSheet: View {
    let flight: NotamFlight
    let countries: [String]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject private var service = NotamService.shared
    @ObservedObject private var registry = BriefingRegistryService.shared
    @State private var open: Set<Group> = []

    private enum Group: Hashable { case notDuring, above, ifr, away }
    private var now: Date { FlightClock.now }

    var body: some View {
        let sorted = service.sorted(for: flight, countries: countries)
        let time = service.copyState(countries: countries).time
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text(NotamWords.sortedBy(flight, now: now))
                        .scaledFont(size: 13, relativeTo: .footnote)
                        .foregroundColor(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("notams.sortedBy")
                    sectionHead(L10n.Notams.alongFlight.uppercased(), count: sorted.along.count)
                    if sorted.along.isEmpty {
                        Text(L10n.Notams.noneFound)
                            .scaledFont(size: 14, relativeTo: .subheadline)
                            .foregroundColor(.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        rows(sorted.along)
                    }
                    if !sorted.region.isEmpty {
                        sectionHead(L10n.Notams.groupRegion.uppercased(), count: sorted.region.count)
                            .padding(.top, 8)
                        rows(sorted.region)
                    }
                    fold(.notDuring, L10n.Notams.groupNotDuring, sorted.notDuring)
                    fold(.above, L10n.Notams.groupAbove, sorted.above)
                    fold(.ifr, L10n.Notams.groupIFR, sorted.ifrOnly)
                    fold(.away, L10n.Notams.groupAway, sorted.away)
                    noListSection
                    if let time {
                        Text(L10n.Notams.copyFooter(NotamWords.copyTime(time)))
                            .scaledFont(size: 12, relativeTo: .caption)
                            .foregroundColor(.dimText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 6)
                    }
                }
                .padding(16)
            }
            .background(Color.cockpitBackground.ignoresSafeArea())
            .navigationTitle("NOTAMs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.close) { dismiss() }
                        .accessibilityIdentifier("notams.close")
                }
            }
            .navigationDestination(for: Notam.self) { NotamDetail(notam: $0) }
        }
        .preferredColorScheme(.dark)
    }

    private func sectionHead(_ title: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .scaledFont(size: 12, weight: .bold, relativeTo: .caption)
                .foregroundColor(.aviationGold)
            if let count {
                Text(String(count))
                    .scaledFont(size: 12, design: .monospaced, relativeTo: .caption)
                    .foregroundColor(.dimText)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func rows(_ entries: [NotamEntry]) -> some View {
        ForEach(entries) { entry in
            NavigationLink(value: entry.notam) {
                NotamRowLabel(entry: entry, now: now)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("notams.row.\(entry.notam.number)")
        }
    }

    /// A folded group: its name and count, always there; a tap opens it where it stands.
    @ViewBuilder
    private func fold(_ group: Group, _ title: String, _ entries: [NotamEntry]) -> some View {
        Button {
            if open.contains(group) { open.remove(group) } else { open.insert(group) }
        } label: {
            HStack {
                Text(title)
                    .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                    .foregroundColor(.primaryText)
                Spacer(minLength: 8)
                Text(String(entries.count))
                    .scaledFont(size: 13, design: .monospaced, relativeTo: .footnote)
                    .foregroundColor(.dimText)
                Image(systemName: open.contains(group) ? "chevron.down" : "chevron.right")
                    .scaledFont(size: 12, weight: .semibold, relativeTo: .caption)
                    .foregroundColor(.dimText)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
        .disabled(entries.isEmpty)
        .accessibilityIdentifier("notams.group.\(group)")
        if open.contains(group) { rows(entries) }
    }

    /// A country without a list keeps its official page.
    @ViewBuilder
    private var noListSection: some View {
        let missing = service.index == nil ? [] : countries.filter { !service.hasList($0) }
        if !missing.isEmpty {
            sectionHead(L10n.Notams.noListSection, count: nil)
                .padding(.top, 6)
            ForEach(missing, id: \.self) { country in
                let link = registry.registry?.country(country)?.notam.first
                Button {
                    if let url = link?.url { openURL(url) }
                } label: {
                    HStack {
                        Text(OpenAIPConfig.countryName(for: country))
                            .scaledFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                            .foregroundColor(.altimeterBlue)
                        Spacer(minLength: 8)
                        Text(L10n.Notams.readOfficialPage)
                            .scaledFont(size: 12, relativeTo: .caption)
                            .foregroundColor(.secondaryText)
                        Image(systemName: "arrow.up.right")
                            .scaledFont(size: 12, weight: .semibold, relativeTo: .caption)
                            .foregroundColor(.altimeterBlue)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(link == nil)
            }
        }
    }
}

/// A row's three lines, for a list that pushes the detail.
struct NotamRowLabel: View {
    let entry: NotamEntry
    let now: Date

    var body: some View {
        let title = NotamWords.title(entry)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title.where)
                    .scaledFont(size: 13, weight: .bold, relativeTo: .footnote)
                    .foregroundColor(.primaryText)
                if let tag = title.tag {
                    Text(tag)
                        .scaledFont(size: 11, relativeTo: .caption2)
                        .foregroundColor(.dimText)
                }
                Spacer(minLength: 0)
            }
            Text(entry.notam.shownText)
                .scaledFont(size: 14, design: .monospaced, relativeTo: .subheadline)
                .foregroundColor(.primaryText)
                .multilineTextAlignment(.leading)
                .lineLimit(4)
            Text(NotamWords.meta(entry.notam, now: now))
                .scaledFont(size: 12, relativeTo: .caption)
                .foregroundColor(.dimText)
                .multilineTextAlignment(.leading)
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }
}

// MARK: - The detail

/// A NOTAM: the original first, in monospace, then the abbreviations spelled out when the server has that. No AI, nothing
/// reworded here (q3 A).
struct NotamDetail: View {
    let notam: Notam

    var body: some View {
        ScrollView {
            NotamDetailContent(notam: notam)
                .padding(16)
        }
        .background(Color.cockpitBackground.ignoresSafeArea())
        .navigationTitle(notam.number)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A NOTAM's text, in the detail and the reader. `large`: read in flight, at the Cockpit's sizes.
struct NotamDetailContent: View {
    let notam: Notam
    var large = false

    private var bodySize: CGFloat { large ? CockpitType.label : 14 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(notam.number)
                .scaledFont(size: 12, weight: .bold, relativeTo: .caption)
                .foregroundColor(.aviationGold)
                .accessibilityAddTraits(.isHeader)
            Text(notam.icao.isEmpty ? notam.shownText : notam.icao)
                .scaledFont(size: bodySize, design: .monospaced, relativeTo: .body)
                .foregroundColor(.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("notams.original")
            if let schedule = notam.schedule, !schedule.isEmpty, notam.icao.isEmpty {
                Text(schedule)
                    .scaledFont(size: bodySize, design: .monospaced, relativeTo: .body)
                    .foregroundColor(.primaryText)
            }
            if let plain = notam.plain, !plain.isEmpty {
                Text(L10n.Notams.spelledOut.uppercased())
                    .scaledFont(size: 12, weight: .bold, relativeTo: .caption)
                    .foregroundColor(.aviationGold)
                    .padding(.top, 6)
                    .accessibilityAddTraits(.isHeader)
                Text(plain)
                    .scaledFont(size: bodySize, relativeTo: .body)
                    .foregroundColor(.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("notams.plain")
                Text(L10n.Notams.spelledOutHint)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.dimText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What a tap reads: a NOTAM from a list, a field's from its card (also in flight, from what's on the device), an area
/// from the map. One opens at once; several are listed. Close at the top left (Apple's rule, #518).
struct NotamReaderSheet: View {
    let notams: [Notam]
    let title: String

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @ObservedObject private var service = NotamService.shared

    private var large: Bool { appState.isFlightActive }
    private var now: Date { FlightClock.now }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(notams.enumerated()), id: \.element.id) { index, notam in
                        if index > 0 { Divider().overlay(Color.white.opacity(0.12)) }
                        NotamDetailContent(notam: notam, large: large)
                        if !notam.icao.isEmpty || notams.count > 1 {
                            Text(NotamWords.when(notam, now: now))
                                .scaledFont(size: 12, relativeTo: .caption)
                                .foregroundColor(.dimText)
                        }
                    }
                    if let time = service.copyState(countries: []).time {
                        Text(L10n.Notams.copyFooter(NotamWords.copyTime(time)))
                            .scaledFont(size: 12, relativeTo: .caption)
                            .foregroundColor(.dimText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
            .background(Color.cockpitBackground.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.close) { dismiss() }
                        .accessibilityIdentifier("notams.close")
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// A set of NOTAMs to read, from the card or the map.
struct NotamReading: Identifiable {
    let notams: [Notam]
    let title: String
    var id: String { notams.map(\.id).joined(separator: "|") }
}
