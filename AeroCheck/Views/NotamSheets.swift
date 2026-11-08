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

/// Which text the NOTAM cards show: the original, or the abbreviations spelled out. One switch for every card, kept on
/// the device from one reading to the next (the author's choice, 8 Nov 2026, decision page 8YkwKvUpdGcvbnpsgtn9fL: A, q2 A).
/// Until then each card showed both, one under the other, and a card of four NOTAMs said eight messages.
enum NotamTextMode: String {
    case original, spelledOut
    static let storageKey = "notams.textMode"
}

/// The switch under a reader's title. Shown only when one of its NOTAMs has a spelled-out version. In flight at the
/// Cockpit's sizes.
struct NotamTextSwitch: View {
    @Binding var mode: NotamTextMode
    var large = false

    var body: some View {
        HStack(spacing: 3) {
            segment(.original, L10n.Notams.original)
            segment(.spelledOut, L10n.Notams.spelledOut)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.panelBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notams.textSwitch")
    }

    private func segment(_ value: NotamTextMode, _ title: String) -> some View {
        Button { mode = value } label: {
            Text(title.uppercased())
                .scaledFont(size: large ? CockpitType.label : 13, weight: .bold, relativeTo: .subheadline)
                .foregroundColor(mode == value ? .primaryText : .dimText)
                .frame(maxWidth: .infinity, minHeight: large ? CockpitTarget.control : 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(mode == value ? Color.white.opacity(0.16) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == value ? .isSelected : [])
        .accessibilityIdentifier("notams.textSwitch.\(value.rawValue)")
    }
}

/// See all's page for one NOTAM: its card, under the switch.
struct NotamDetail: View {
    let notam: Notam

    @AppStorage(NotamTextMode.storageKey) private var mode: NotamTextMode = .original

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                NotamDetailContent(notam: notam, mode: mode)
                if mode == .spelledOut, notam.hasPlain { NotamSpelledOutHint() }
            }
            .padding(16)
        }
        .safeAreaInset(edge: .top) {
            if notam.hasPlain {
                NotamTextSwitch(mode: $mode).padding(.horizontal, 16).padding(.vertical, 8).background(Color.cockpitBackground)
            }
        }
        .background(Color.cockpitBackground.ignoresSafeArea())
        .navigationTitle(notam.number)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One NOTAM as a card: a header that reads as one (the number boxed, the place, when it ends and how high), then the
/// message once, in the switch's text, then the whole NOTAM on a tap (q3 A). The header used to share the gold label of
/// "Spelled out" (the author's device check, 8 Nov). `large`: read in flight, at the Cockpit's sizes.
struct NotamDetailContent: View {
    let notam: Notam
    var large = false
    var mode: NotamTextMode = .original

    @State private var showsFull = false

    private var bodySize: CGFloat { large ? CockpitType.label : 14 }
    private var smallSize: CGFloat { large ? CockpitType.row - 4 : 12 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(notam.number)
                    .scaledFont(size: smallSize, weight: .bold, design: .monospaced, relativeTo: .caption)
                    .foregroundColor(.primaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.dimText, lineWidth: 1))
                if !notam.location.isEmpty {
                    Text(notam.location)
                        .scaledFont(size: smallSize, weight: .bold, relativeTo: .caption)
                        .foregroundColor(.aviationGold)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Text(NotamWords.facts(notam, now: FlightClock.now))
                .scaledFont(size: smallSize, relativeTo: .caption)
                .foregroundColor(.dimText)
                .fixedSize(horizontal: false, vertical: true)
            message
            if let schedule = notam.schedule, !schedule.isEmpty {
                Text(schedule)
                    .scaledFont(size: bodySize, design: .monospaced, relativeTo: .body)
                    .foregroundColor(.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !notam.icao.isEmpty && notam.icao != notam.text {
                Button { showsFull.toggle() } label: {
                    HStack(spacing: 6) {
                        Text(L10n.Notams.fullNotam)
                            .scaledFont(size: smallSize, weight: .semibold, relativeTo: .caption)
                        Image(systemName: showsFull ? "chevron.up" : "chevron.down")
                            .scaledFont(size: smallSize - 2, weight: .semibold, relativeTo: .caption)
                    }
                    .foregroundColor(.altimeterBlue)   // the links' blue, as the official page's link
                    .frame(minHeight: large ? CockpitTarget.control : 32, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("notams.full")
                if showsFull {
                    Text(notam.icao)
                        .scaledFont(size: smallSize, design: .monospaced, relativeTo: .caption)
                        .foregroundColor(.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("notams.icao")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.panelBackground))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }

    /// The message once: spelled out where the switch says so and the server has it, else the original, which a NOTAM
    /// without a spelled-out version says rather than showing nothing.
    @ViewBuilder
    private var message: some View {
        if mode == .spelledOut, let plain = notam.plain, !plain.isEmpty {
            Text(plain)
                .scaledFont(size: bodySize, relativeTo: .body)
                .foregroundColor(.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("notams.plain")
        } else {
            Text(notam.shownText)
                .scaledFont(size: bodySize, design: .monospaced, relativeTo: .body)
                .foregroundColor(.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("notams.original")
            if mode == .spelledOut {
                Text(L10n.Notams.noSpelledOut)
                    .scaledFont(size: smallSize, relativeTo: .caption)
                    .italic()
                    .foregroundColor(.dimText)
            }
        }
    }
}

/// What "spelled out" is, once at a reader's foot.
struct NotamSpelledOutHint: View {
    var body: some View {
        Text(L10n.Notams.spelledOutHint)
            .scaledFont(size: 12, relativeTo: .caption)
            .foregroundColor(.dimText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What a tap reads: a NOTAM from a list, a field's from its card (also in flight, from what's on the device), an area
/// from the map. Every one as a card, under the switch. Close at the top left (Apple's rule, #518).
struct NotamReaderSheet: View {
    let notams: [Notam]
    let title: String

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @ObservedObject private var service = NotamService.shared
    @AppStorage(NotamTextMode.storageKey) private var mode: NotamTextMode = .original

    private var large: Bool { appState.isFlightActive }
    private var anySpelledOut: Bool { notams.contains(where: \.hasPlain) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(notams) { notam in
                        NotamDetailContent(notam: notam, large: large, mode: mode)
                    }
                    if mode == .spelledOut, anySpelledOut { NotamSpelledOutHint() }
                    if let time = service.copyState(countries: []).time {
                        Text(L10n.Notams.copyFooter(NotamWords.copyTime(time)))
                            .scaledFont(size: 12, relativeTo: .caption)
                            .foregroundColor(.dimText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
            .safeAreaInset(edge: .top) {
                if anySpelledOut {
                    NotamTextSwitch(mode: $mode, large: large)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color.cockpitBackground)
                }
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

struct NotamReading: Identifiable {
    let notams: [Notam]
    let title: String
    var id: String { notams.map(\.id).joined(separator: "|") }
}
