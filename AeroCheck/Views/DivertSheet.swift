import SwiftUI
import CoreLocation

// MARK: - Divert (v5.1)

/// "Where do I go instead?", answered in two taps and no typing: tap a field to see it, tap the big
/// button to go there. An in-flight surface, so it reads the cockpit theme and keeps every target
/// large.
///
/// It changes where the aircraft is navigating to and nothing else. The plan stays as planned, so
/// "Resume route" is one tap, and nothing administrative (tasks, reminders, the flight thread) moves
/// until the ground. Tapping the destination is "direct to", not a diversion.
struct DivertSheet: View {
    let onClose: () -> Void
    /// An aerodrome to open expanded, when the sheet was reached from the map.
    var preselectedIdent: String?

    @Environment(\.cockpitTheme) private var theme
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var locationManager: LocationManager

    @State private var sections: DivertPlanner.Sections?
    @State private var expanded: String?

    private var plan: FlightPlan? { flightPlanManager.activeFlightPlan }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let diversion = plan?.diversion {
                        resumeCard(diversion)
                    }
                    if let sections {
                        content(sections)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(40)
                    }
                    Text(L10n.Trip.notListed)
                        .font(.system(size: 12))
                        .foregroundColor(theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .padding(16)
            }
        }
        .background(theme.background.ignoresSafeArea())
        .task { await load() }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Text(L10n.Trip.divert)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(theme.textPrimary)
            Spacer()
            Button(L10n.Button.close) { onClose() }
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(theme.action)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .overlay(alignment: .bottomLeading) {
            Text(metaLine)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.textDim)
                .padding(.horizontal, 16)
                .offset(y: 16)
        }
        .padding(.bottom, 18)
    }

    private var metaLine: String {
        var parts = [String(format: "GS %d kt", Int(locationManager.currentSpeedKnots.rounded()))]
        if let track = locationManager.currentCourseDegrees { parts.append(String(format: "TRK %03d°", Int(track.rounded()) % 360)) }
        if let location = locationManager.currentLocation {
            parts.append(String(format: "%d ft", Int((location.altitude * 3.28084).rounded())))
        }
        parts.append(Date().formatted(date: .omitted, time: .shortened))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func content(_ sections: DivertPlanner.Sections) -> some View {
        if let destination = sections.destination {
            group(L10n.Trip.destination, [destination], isDestination: true)
        }
        if let alternate = sections.alternate {
            group(L10n.Trip.alternate, [alternate])
        }
        if !sections.ahead.isEmpty {
            group(L10n.Trip.ahead, sections.ahead)
        }
        if !sections.behind.isEmpty {
            group(L10n.Trip.behind, sections.behind)
        }
        if sections.ahead.isEmpty && sections.behind.isEmpty {
            Text(L10n.Trip.noAerodromes)
                .font(.system(size: 14))
                .foregroundColor(theme.textSecondary)
        }
    }

    private func group(_ title: String, _ options: [DivertPlanner.Option], isDestination: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(theme.textDim)
            VStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element.aerodrome.ident) { index, option in
                    row(option, isDestination: isDestination)
                    if index < options.count - 1 {
                        Divider().overlay(theme.panelStroke)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.panelStroke, lineWidth: 1))
        }
    }

    private func row(_ option: DivertPlanner.Option, isDestination: Bool) -> some View {
        let ident = option.aerodrome.ident
        let isExpanded = expanded == ident
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                expanded = isExpanded ? nil : ident
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(ident)
                                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                                    .foregroundColor(theme.textPrimary)
                                if option.aerodrome.isPPR { chip("PPR", color: theme.warning) }
                                if option.crossesBorder, let country = option.aerodrome.country {
                                    chip(L10n.Trip.border(country), color: theme.warning)
                                }
                            }
                            Text(option.aerodrome.name)
                                .font(.system(size: 13))
                                .foregroundColor(theme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 14) {
                            Text(String(format: "%03d°", Int(option.bearing.rounded()) % 360))
                            Text(String(format: "%.1f", option.distanceNM))
                            Text(minutesText(option.minutes))
                                .foregroundColor(theme.action)
                        }
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.textPrimary)
                    }
                    Text(option.aerodrome.frequency ?? L10n.Trip.noFrequency)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(option.aerodrome.frequency == nil ? theme.warning : theme.textDim)
                }
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(detailLine(option))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if option.aerodrome.frequency == nil {
                        Text(L10n.Trip.checkChart)
                            .font(.system(size: 13))
                            .foregroundColor(theme.warning)
                    }
                    Button {
                        go(to: option, isDestination: isDestination)
                    } label: {
                        Text(isDestination ? L10n.Trip.directTo(ident) : L10n.Trip.divertTo(ident))
                            .font(.system(size: 18, weight: .bold))
                            .tracking(0.6)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .foregroundColor(theme.actionText)
                            .background(RoundedRectangle(cornerRadius: 12).fill(theme.action))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(isExpanded ? theme.panel : Color.clear)
    }

    private func resumeCard(_ diversion: Diversion) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.Trip.divertingTo(diversion.ident))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.textPrimary)
                Text(diversion.name)
                    .font(.system(size: 12))
                    .foregroundColor(theme.textDim)
            }
            Spacer()
            Button {
                flightPlanManager.resumeRoute()
                onClose()
            } label: {
                Text(L10n.Trip.resumeRoute)
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .foregroundColor(theme.action)
                    .overlay(Capsule().strokeBorder(theme.action, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.card))
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.4)
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color, lineWidth: 1))
    }

    private func minutesText(_ minutes: Double) -> String {
        guard minutes.isFinite else { return "--" }
        let m = Int(minutes.rounded())
        return m < 60 ? "\(m)′" : String(format: "%d:%02d", m / 60, m % 60)
    }

    private func detailLine(_ option: DivertPlanner.Option) -> String {
        var parts: [String] = []
        if let runway = option.aerodrome.runway { parts.append("RWY \(runway)") }
        if let elevation = option.aerodrome.elevationFeet {
            parts.append(String(format: "%d ft", Int(elevation.rounded())))
        }
        if option.minutes.isFinite {
            let eta = Date().addingTimeInterval(option.minutes * 60)
            parts.append("ETA \(eta.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func go(to option: DivertPlanner.Option, isDestination: Bool) {
        if isDestination, let plan {
            flightPlanManager.directTo(waypointAt: plan.waypoints.count - 1)
        } else {
            flightPlanManager.divert(to: option.aerodrome)
        }
        onClose()
    }

    // MARK: - Data

    private func load() async {
        await airportDataService.ensureLoaded()
        guard let location = locationManager.currentLocation else { sections = .init(ahead: [], behind: []); return }
        let position = location.coordinate
        let nearby = airportDataService.findNearestAirports(to: position, limit: 40,
                                                            maxDistanceNm: DivertPlanner.rangeNM,
                                                            types: AirportType.fixedWing)
            .filter(AirportDataService.isPlanningLandingSite)
            .map(airportDataService.planningAerodrome)

        func aerodrome(ident: String?) -> TripPlanner.Aerodrome? {
            guard let ident, !ident.isEmpty, let airport = airportDataService.findAirport(byIdent: ident)
            else { return nil }
            return airportDataService.planningAerodrome(airport)
        }
        let destination: TripPlanner.Aerodrome? = plan.flatMap { plan in
            guard let last = plan.waypoints.last else { return nil }
            return aerodrome(ident: last.name)
                ?? airportDataService.nearestAirport(to: last.coordinate, maxDistanceNm: 1).map(airportDataService.planningAerodrome)
        }
        let altitudeFeet = location.altitude * 3.28084
        let wind = FlightPlan.windsAloftProvider?(position, altitudeFeet)
        let countries = CountryBoundaries.shared.countries(near: position, bufferNm: 0)
        sections = DivertPlanner.sections(
            from: position,
            track: locationManager.currentCourseDegrees,
            groundSpeedKt: locationManager.currentSpeedKnots,
            cruiseKt: Double(plan.map { FlightPlan.defaultCruiseSpeed(for: $0.aircraftTypeId) } ?? 100),
            wind: wind,
            aerodromes: nearby,
            destination: destination,
            alternate: aerodrome(ident: plan?.alternateAerodrome),
            pinned: aerodrome(ident: preselectedIdent).flatMap { pinned in
                pinned.ident == destination?.ident || pinned.ident == plan?.alternateAerodrome ? nil : pinned
            },
            country: countries.count == 1 ? countries.first : nil
        )
        if let preselectedIdent { expanded = preselectedIdent }
    }
}
