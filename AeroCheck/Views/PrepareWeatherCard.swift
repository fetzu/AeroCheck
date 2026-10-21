import SwiftUI
import CoreLocation

/// Prepare's weather, above the tasks (the author's q1, 22 Oct 2026): each field of the route with its METAR and
/// TAF as published, a field without a TAF pointing to the nearest that has one, the SIGMETs along the route, and
/// where it all comes from. Read before the official briefing, never instead of it: the reports stay raw. (6.5.0)
struct PrepareWeatherCard: View {
    let threadId: UUID
    let fields: [PrepareWeather.Field]
    let route: [CLLocationCoordinate2D]

    @ObservedObject private var service = PrepareWeatherService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            switch service.state(for: threadId) {
            case .loaded(let weather)?:
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
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        .task(id: fields.map(\.ident).joined(separator: " ")) { await service.load(threadId: threadId, fields: fields, route: route) }
        .accessibilityIdentifier("prepare.weather")
    }

    private func load(force: Bool) {
        Task { await service.load(threadId: threadId, fields: fields, route: route, force: force) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L10n.PrepareWeather.title.uppercased())
                .scaledFont(size: 11, weight: .bold, design: .monospaced, relativeTo: .caption2)
                .foregroundColor(.aviationGold)
                .tracking(0.8)
            Spacer()
            if case .loaded(let weather)? = service.state(for: threadId) {
                Text(Self.utc(weather.fetchedAt))
                    .scaledFont(size: 11, weight: .semibold, design: .monospaced, relativeTo: .caption2)
                    .foregroundColor(.secondaryText)
            }
            Button { load(force: true) } label: {
                Image(systemName: "arrow.clockwise")
                    .scaledFont(size: 13, weight: .semibold, relativeTo: .footnote)
                    .foregroundColor(.aviationGold)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(service.state(for: threadId) == .loading)
            .accessibilityLabel(L10n.PrepareWeather.refresh)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Color.panelBackground)
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
