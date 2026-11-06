import SwiftUI

// MARK: - The NOTAMs on the flight page (layout A, decided 6 Nov 2026)

/// What the block says under the official pages: "Also found along your flight" with the copy's time and a refresh, the
/// first few NOTAMs, All 16, each country's line, a row for a country without a list, the notice. It sorts on the device
/// and reads what's on the device; the tick stays the pilot's.
struct NotamListSection: View {
    let flight: NotamFlight
    /// The route's countries, in its order.
    let countries: [String]

    @ObservedObject private var service = NotamService.shared
    @State private var showsAll = false
    @State private var reading: Notam?

    private var now: Date { FlightClock.now }
    private var listed: [String] { countries.filter(service.hasList) }
    private var withoutList: [String] { service.index == nil ? [] : countries.filter { !service.hasList($0) } }

    var body: some View {
        let sorted = service.sorted(for: flight, countries: countries)
        let copy = service.copyState(countries: countries)
        VStack(alignment: .leading, spacing: 8) {
            if service.index == nil || !listed.isEmpty {
                head(copy)
                if service.index == nil {
                    plainLine(L10n.Notams.notLoaded)
                } else if sorted.along.isEmpty {
                    plainLine(L10n.Notams.noneFound)
                        .accessibilityIdentifier("notams.noneFound")
                } else {
                    VStack(spacing: 0) {
                        ForEach(sorted.along.prefix(NotamSorted.shownOnBlock)) { entry in
                            NotamRow(entry: entry, now: now) { reading = entry.notam }
                        }
                    }
                }
                allLink(sorted)
                if copy.couldNotRefresh, let time = copy.time {
                    hint(L10n.Notams.couldNotRefresh(NotamWords.copyTime(time)))
                        .accessibilityIdentifier("notams.couldNotRefresh")
                }
            }
            // Each note names its country, in its own words.
            ForEach(listed.filter { service.note(for: $0) != nil }, id: \.self) { country in
                hint(service.note(for: country) ?? "")
                    .accessibilityIdentifier("notams.note.\(country)")
            }
            ForEach(withoutList, id: \.self) { country in
                noListRow(country)
            }
            // About a list: with none on the route, the rows above say it all.
            if !listed.isEmpty {
                hint(L10n.Notams.notice)
                    .accessibilityIdentifier("notams.notice")
            }
        }
        .padding(.top, 8)
        .sheet(isPresented: $showsAll) {
            NotamAllSheet(flight: flight, countries: countries)
        }
        .sheet(item: $reading) { notam in
            NotamReaderSheet(notams: [notam], title: notam.number)
        }
    }

    /// "ALSO FOUND ALONG YOUR FLIGHT   07:15 UTC ↻": the age in amber past the hour.
    private func head(_ copy: NotamCopyState) -> some View {
        HStack(spacing: 6) {
            Text(L10n.Notams.alongFlight.uppercased())
                .scaledFont(size: 12, weight: .bold, relativeTo: .caption)
                .foregroundColor(.aviationGold)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let age = NotamWords.age(copy, now: now) {
                Text(age)
                    .scaledFont(size: 12, design: .monospaced, relativeTo: .caption)
                    .foregroundColor(copy.isOld(now: now) ? .aviationAmber : .dimText)
                    .accessibilityIdentifier("notams.age")
            }
            Button {
                Task { await service.refreshIfNeeded(countries: countries, force: true, onGround: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .scaledFont(size: 13, weight: .semibold, relativeTo: .caption)
                    .foregroundColor(.altimeterBlue)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .opacity(service.isLoading ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(service.isLoading)
            .accessibilityLabel(L10n.Notams.refresh)
            .accessibilityIdentifier("notams.refresh")
        }
        .frame(minHeight: 44)
    }

    /// "All 16 ›". With nothing near the route, what's away from it stays one tap away.
    @ViewBuilder
    private func allLink(_ sorted: NotamSorted) -> some View {
        if sorted.total > 0 || !sorted.away.isEmpty {
            Button { showsAll = true } label: {
                HStack(spacing: 6) {
                    Text(sorted.total > 0 ? L10n.Notams.all(sorted.total) : "\(L10n.Notams.groupAway) \(sorted.away.count)")
                        .scaledFont(size: 14, weight: .bold, relativeTo: .subheadline)
                    Image(systemName: "chevron.right")
                        .scaledFont(size: 12, weight: .semibold, relativeTo: .caption)
                    Spacer(minLength: 0)
                }
                .foregroundColor(.aviationGold)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("notams.all")
        }
    }

    private func plainLine(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 14, relativeTo: .subheadline)
            .foregroundColor(.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 12, relativeTo: .caption)
            .foregroundColor(.dimText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "Austria. No list here. Too many of its NOTAMs don't reach us.", dashed around.
    private func noListRow(_ country: String) -> some View {
        (Text(OpenAIPConfig.countryName(for: country) + ". ").bold() + Text(L10n.Notams.noListHere))
            .scaledFont(size: 13, relativeTo: .footnote)
            .foregroundColor(.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.dimText.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .accessibilityIdentifier("notams.noList.\(country)")
    }
}

/// One NOTAM in a list: where, what, when. A tap reads it.
struct NotamRow: View {
    let entry: NotamEntry
    let now: Date
    let action: () -> Void

    var body: some View {
        Button(action: action) { NotamRowLabel(entry: entry, now: now) }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("notams.row.\(entry.notam.number)")
    }
}
