import SwiftUI
import CoreLocation

/// The weather block's body (6.6.0; a card of its own with its tick in 6.5.0): the reports before the flight, then where
/// to brief officially, a row per page. The tick and the time of the reports are in the block's head
/// (`FlightBlockCard`); "Weather briefed" and every area forecast underneath, as the author decided (v65-1, q4).
struct ThreadWeatherBody: View {
    let threadId: UUID
    /// The route's aerodromes the reports are for: none in a dry run, after the flight, or without a known aerodrome.
    let fields: [PrepareWeather.Field]
    let route: [CLLocationCoordinate2D]
    /// Every country's weather and area-forecast pages, a page once (`ThreadBriefing.weatherLinks`).
    let links: [ThreadTaskLink]
    let onOpen: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !fields.isEmpty {
                Divider().overlay(Color.white.opacity(0.06))
                PrepareWeatherReports(threadId: threadId, fields: fields, route: route)
            }
            if !links.isEmpty {
                Text(L10n.Thread.briefOfficially.uppercased())
                    .scaledFont(size: 10, weight: .bold, design: .monospaced, relativeTo: .caption2)
                    .foregroundColor(.dimText)
                    .tracking(0.8)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                VStack(spacing: 0) {
                    ForEach(links, id: \.url) { link in
                        ThreadLinkRow(link: link) { onOpen(link.url) }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
        }
        .accessibilityIdentifier("prepare.weather")
    }
}

/// The time of the reports and the refresh, in the weather block's head.
struct PrepareWeatherRefresh: View {
    let threadId: UUID
    let fields: [PrepareWeather.Field]
    let route: [CLLocationCoordinate2D]

    @ObservedObject private var service = PrepareWeatherService.shared

    var body: some View {
        HStack(spacing: 4) {
            if case .loaded(let weather)? = service.state(for: threadId) {
                Text(PrepareWeatherReports.utc(weather.fetchedAt))
                    .scaledFont(size: 11, weight: .semibold, design: .monospaced, relativeTo: .caption2)
                    .foregroundColor(.secondaryText)
            }
            Button {
                Task { await service.load(threadId: threadId, fields: fields, route: route, force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                    .foregroundColor(.aviationGold)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(service.state(for: threadId) == .loading)
            .accessibilityLabel(L10n.PrepareWeather.refresh)
        }
    }
}

/// The reports of the weather block (the author's q1, 22 Oct 2026): each field of the route with its METAR and TAF as
/// published, a field without a TAF pointing to the nearest that has one, the SIGMETs along the route, and where it
/// all comes from. Read before the official briefing, never instead of it: the reports stay raw. (6.5.0)
struct PrepareWeatherReports: View {
    let threadId: UUID
    let fields: [PrepareWeather.Field]
    let route: [CLLocationCoordinate2D]

    @ObservedObject private var service = PrepareWeatherService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch service.state(for: threadId) {
            case .loaded(let weather)?:
                if service.refreshFailed.contains(threadId) {
                    Text(L10n.PrepareWeather.refreshFailed(Self.utc(weather.fetchedAt)))
                        .scaledFont(size: 12, weight: .semibold, relativeTo: .caption)
                        .foregroundColor(.aviationAmber)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.top, 9)
                }
                ForEach(weather.stations) { station in
                    stationRow(station)
                    Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 14)
                }
                sigmetLines(weather.sigmets)
            case .failed?:
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.PrepareWeather.failed)
                        .scaledFont(size: 13, relativeTo: .footnote)
                        .foregroundColor(.secondaryText)
                    Button(L10n.Button.retry) { load(force: true) }
                        .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                        .foregroundColor(.aviationGold)
                        .frame(minHeight: 44)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            case .loading?, nil:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.PrepareWeather.loading)
                        .scaledFont(size: 13, relativeTo: .footnote)
                        .foregroundColor(.secondaryText)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            Text(L10n.PrepareWeather.source)
                .scaledFont(size: 11, relativeTo: .caption2)
                .foregroundColor(.dimText)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .task(id: fields.map(\.ident).joined(separator: " ")) { await service.load(threadId: threadId, fields: fields, route: route) }
    }

    private func load(force: Bool) {
        Task { await service.load(threadId: threadId, fields: fields, route: route, force: force) }
    }

    private func stationRow(_ station: PrepareWeather.Station) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(station.ident)
                    .scaledFont(size: 14, weight: .bold, design: .monospaced, relativeTo: .subheadline)
                    .foregroundColor(.primaryText)
                Text(station.roles.map(Self.roleWord).joined(separator: " · ").uppercased())
                    .scaledFont(size: 10, weight: .bold, design: .monospaced, relativeTo: .caption2)
                    .foregroundColor(.dimText)
                    .tracking(0.6)
            }
            if let metar = station.metar { report(Self.labelled(metar, as: "METAR", or: ["METAR", "SPECI"])) }
            if let taf = station.taf { report(Self.labelled(taf, as: "TAF", or: ["TAF"])) }
            if let note = Self.note(for: station) {
                Text(note)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private func report(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 12, design: .monospaced, relativeTo: .caption)
            .foregroundColor(.secondaryText)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func sigmetLines(_ sigmets: AviationWeatherService.RouteSigmets?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch sigmets {
            case nil:
                Text(L10n.PrepareWeather.sigmetFailed)
                    .scaledFont(size: 12, relativeTo: .caption)
                    .foregroundColor(.aviationAmber)
            case let sigmets? where sigmets.hazards.isEmpty:
                Text(sigmets.received > 0 ? L10n.PrepareWeather.noSigmetAlongRoute(sigmets.received)
                                          : L10n.PrepareWeather.noSigmetReceived)
                    .scaledFont(size: 12, weight: .semibold, relativeTo: .caption)
                    .foregroundColor(sigmets.received > 0 ? .aviationGreen : .aviationAmber)
            case let sigmets?:
                Text(L10n.PrepareWeather.sigmetsAlongRoute.uppercased())
                    .scaledFont(size: 10, weight: .bold, design: .monospaced, relativeTo: .caption2)
                    .foregroundColor(.aviationAmber)
                ForEach(sigmets.hazards) { hazard in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(SigmetFormat.hazardName(hazard))
                            .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                            .foregroundColor(.aviationAmber)
                        Text(SigmetFormat.detail(hazard))
                            .scaledFont(size: 12, design: .monospaced, relativeTo: .caption)
                            .foregroundColor(.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Words

    static func roleWord(_ role: PrepareWeather.Role) -> String {
        switch role {
        case .departure: return L10n.PrepareWeather.departure
        case .destination: return L10n.PrepareWeather.destination
        case .alternate: return L10n.PrepareWeather.alternate
        case .nearest: return L10n.PrepareWeather.nearest
        }
    }

    /// What the row says beside its reports: what it lacks, and where the nearest TAF is.
    static func note(for station: PrepareWeather.Station) -> String? {
        guard station.roles != [.nearest] else { return nil }
        switch (station.metar, station.taf, station.nearest) {
        case (nil, nil, let nearest?):
            return with(L10n.PrepareWeather.noMetarOrTaf(nearest: nearest.ident, distanceNm: nearest.distanceNm), nearest)
        case (_, nil, let nearest?):
            return with(L10n.PrepareWeather.noTaf(nearest: nearest.ident, distanceNm: nearest.distanceNm), nearest)
        case (nil, nil, nil):
            return L10n.PrepareWeather.nothingWithin
        case (_, nil, nil):
            return L10n.PrepareWeather.noTafWithin
        case (nil, _, _):
            return L10n.PrepareWeather.noMetar
        default:
            return nil
        }
    }

    private static func with(_ text: String, _ nearest: PrepareWeather.Nearest) -> String {
        nearest.shownAbove ? "\(text) \(L10n.PrepareWeather.above)" : text
    }

    /// A report as published, with its kind in front where the report doesn't start with it (AWC's METARs don't).
    static func labelled(_ raw: String, as kind: String, or prefixes: [String]) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return prefixes.contains(where: { text.hasPrefix($0 + " ") }) ? text : "\(kind) \(text)"
    }

    /// "22:30 UTC": the reports' own clock.
    static func utc(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: date)) UTC"
    }
}
