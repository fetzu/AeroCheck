import Combine
import CoreLocation
import SwiftUI

// MARK: - Divert from the Companion iPhone (6.2.0)

/// Divert on the phone's NAV screen, beside RECORD ATO for now (the act band's third slot later). Offered
/// as the iPad's own is: while the route has a leg to fly, and only by an iPad that takes the command.
/// Amber while diverting, as on the iPad.
struct CompanionDivertButton: View {
    @EnvironmentObject var companionConnectivityManager: CompanionConnectivityManager
    @Environment(\.cockpitTheme) private var theme
    @State private var showPicker = false

    /// Whether the phone offers Divert: an iPad that takes it (`supportsDivert`), a route not flown to
    /// its end (the iPad hides its Divert then too).
    static func isOffered(plan: CompanionFlightPlanSnapshot?, currentWaypointIndex: Int?) -> Bool {
        guard let plan, plan.supportsDivert else { return false }
        return (currentWaypointIndex ?? plan.currentWaypointIndex) < plan.waypoints.count
    }

    var body: some View {
        let tint = companionConnectivityManager.lastFlightPlanSnapshot?.diversion != nil ? theme.warning : theme.action
        Button { showPicker = true } label: {
            VStack(spacing: 6) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.aero(size: CockpitType.response, weight: .semibold))
                Text(L10n.Trip.divert)
                    .font(.aero(size: CockpitType.label, weight: .bold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 96, minHeight: CockpitTarget.thumb)
            .foregroundColor(tint)
            .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.45), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityIdentifier("companion.divert")
        .accessibilityHint(L10n.Companion.divertHint)
        .sheet(isPresented: $showPicker) {
            CompanionDivertPicker(onClose: { showPicker = false })
                .environment(\.cockpitTheme, theme)
                .preferredColorScheme(.dark)
        }
    }
}

/// "Where do I go instead?", on the phone: the nearest fields from the phone's own airport data, a
/// search, and Resume route while diverting. A tap opens a field, the big button sends it to the iPad,
/// which diverts as its own Divert sheet does; the picker stays until the iPad's plan shows it, sending
/// again meanwhile (`CompanionDivert.Request`), and closes by itself once it does.
struct CompanionDivertPicker: View {
    let onClose: () -> Void

    @Environment(\.cockpitTheme) private var theme
    @EnvironmentObject var companionConnectivityManager: CompanionConnectivityManager
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var locationManager: LocationManager

    @State private var nearest: [CompanionDivert.Row] = []
    @State private var results: [CompanionDivert.Row] = []
    @State private var query = ""
    @State private var isLoading = true
    /// The nearest list was made: there was a position to measure from.
    @State private var hasNearest = false
    @State private var destinationIdent: String?
    @State private var expanded: String?
    @State private var request: CompanionDivert.Request?
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var plan: CompanionFlightPlanSnapshot? { companionConnectivityManager.lastFlightPlanSnapshot }
    private var flightData: CompanionFlightData? { companionConnectivityManager.lastReceivedData }
    private var lastWaypointName: String? { plan?.waypoints.last?.name }
    private var isSearching: Bool { query.trimmingCharacters(in: .whitespaces).count >= 2 }

    private var reference: CLLocationCoordinate2D? {
        CompanionDivert.reference(streamedLatitude: flightData?.latitude, streamedLongitude: flightData?.longitude,
                                  ownFix: locationManager.currentLocation, now: Date())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let diversion = plan?.diversion {
                        resumeCard(diversion)
                    }
                    searchField
                    content
                    Text(L10n.Trip.notListed)
                        .font(.aero(size: CockpitType.label))
                        .foregroundColor(theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(theme.background.ignoresSafeArea())
        .task { await load() }
        .onChange(of: query) { _, _ in search() }
        .onReceive(tick) { follow($0) }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Text(L10n.Trip.divert)
                .font(.aero(size: CockpitType.row, weight: .bold))
                .foregroundColor(theme.textPrimary)
            Spacer()
            Button(L10n.Button.close) { onClose() }
                .font(.aero(size: CockpitType.label, weight: .semibold))
                .foregroundColor(theme.action)
                .frame(minWidth: CockpitTarget.control, minHeight: CockpitTarget.control)
                .accessibilityIdentifier("companionDivert.close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(theme.textDim)
            TextField(L10n.Trip.searchAerodrome, text: $query)
                .font(.aero(size: CockpitType.label))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .foregroundColor(theme.textPrimary)
                .accessibilityIdentifier("companionDivert.search")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: CockpitTarget.control)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.panelStroke, lineWidth: 1))
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity).padding(24)
        } else if !airportDataService.isDataAvailable {
            note(L10n.Companion.divertNoAirportData)
        } else if isSearching {
            if results.isEmpty { note(L10n.Companion.divertNoMatch) } else { list(results) }
        } else if !hasNearest {
            note(L10n.Companion.divertNoPosition)
        } else if nearest.isEmpty {
            note(L10n.Trip.noAerodromes)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.Companion.divertNearest.uppercased())
                    .font(.aero(size: CockpitType.label, weight: .semibold))
                    .tracking(0.8)
                    .foregroundColor(theme.textDim)
                list(nearest)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.aero(size: CockpitType.label))
            .foregroundColor(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
    }

    private func list(_ rows: [CompanionDivert.Row]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                self.row(row)
                if index < rows.count - 1 {
                    Divider().overlay(theme.panelStroke)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.panelStroke, lineWidth: 1))
    }

    private func row(_ row: CompanionDivert.Row) -> some View {
        let ident = row.aerodrome.ident
        let isExpanded = expanded == ident
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                expanded = isExpanded ? nil : ident
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ident)
                            .font(.aero(size: CockpitType.row, weight: .bold, design: .monospaced))
                            .foregroundColor(row.isDestination ? theme.route : theme.textPrimary)
                        Text(nameLine(row))
                            .font(.aero(size: CockpitType.label))
                            .foregroundColor(theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(row.bearing.map { String(format: "%03d°", Int($0.rounded()) % 360) } ?? "---°")
                            .font(.aero(size: CockpitType.row, weight: .semibold, design: .monospaced))
                            .foregroundColor(theme.textPrimary)
                        Text(row.distanceNM.map { String(format: "%.1f NM", $0) } ?? "--- NM")
                            .font(.aero(size: CockpitType.label, design: .monospaced))
                            .foregroundColor(theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: CockpitTarget.control + 14, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isExpanded ? .isSelected : [])
            .accessibilityIdentifier("companionDivert.row.\(ident)")

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(row.aerodrome.frequency ?? L10n.Trip.noFrequency)
                        .font(.aero(size: CockpitType.label, design: .monospaced))
                        .foregroundColor(row.aerodrome.frequency == nil ? theme.warning : theme.textSecondary)
                    if let request, request.ident == ident || (request.goal == .destination && row.isDestination) {
                        pending(request, retry: { go(to: row) })
                    } else {
                        goButton(row)
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(isExpanded ? theme.panel : Color.clear)
    }

    /// The name, after "Destination" for the route's own end, and PPR when the field asks for it.
    private func nameLine(_ row: CompanionDivert.Row) -> String {
        var parts: [String] = []
        if row.isDestination { parts.append(L10n.Trip.destination) }
        parts.append(row.aerodrome.name)
        if row.aerodrome.isPPR { parts.append("PPR") }
        return parts.joined(separator: " · ")
    }

    private func goButton(_ row: CompanionDivert.Row) -> some View {
        let ident = row.aerodrome.ident
        return Button { go(to: row) } label: {
            Text(row.isDestination ? L10n.Trip.directTo(ident) : L10n.Trip.divertTo(ident))
                .font(.aero(size: CockpitType.row, weight: .bold))
                .tracking(0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: CockpitTarget.control + 14)
                .foregroundColor(theme.actionText)
                .background(RoundedRectangle(cornerRadius: 12).fill(theme.action))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("companionDivert.go")
    }

    /// Sent, not yet in the iPad's plan: waiting (the iPad may be asking the pilot), or not taken after
    /// `Request.giveUpAfter`, with the button back to try again.
    @ViewBuilder
    private func pending(_ request: CompanionDivert.Request, retry: @escaping () -> Void) -> some View {
        if request.gaveUp {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.Companion.divertNotTaken)
                    .font(.aero(size: CockpitType.label, weight: .semibold))
                    .foregroundColor(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: retry) {
                    Text(L10n.Button.retry)
                        .font(.aero(size: CockpitType.label, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: CockpitTarget.control)
                        .foregroundColor(theme.action)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.action, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ProgressView().tint(theme.action)
                    Text(L10n.Companion.divertWaiting)
                        .font(.aero(size: CockpitType.label, weight: .semibold))
                        .foregroundColor(theme.textPrimary)
                }
                .frame(maxWidth: .infinity, minHeight: CockpitTarget.control, alignment: .leading)
                Text(L10n.Companion.divertAllowOnIPad)
                    .font(.aero(size: CockpitType.label))
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func resumeCard(_ diversion: CompanionWaypoint) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.Trip.divertingTo(diversion.name))
                    .font(.aero(size: CockpitType.label, weight: .semibold))
                    .foregroundColor(theme.warning)
                if !diversion.remarks.isEmpty {
                    Text(diversion.remarks)
                        .font(.aero(size: CockpitType.label))
                        .foregroundColor(theme.textSecondary)
                        .lineLimit(1)
                }
            }
            if let request, request.goal == .resume {
                pending(request, retry: resume)
            } else {
                Button(action: resume) {
                    Text(L10n.Trip.resumeRoute)
                        .font(.aero(size: CockpitType.label, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: CockpitTarget.control)
                        .foregroundColor(theme.action)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.action, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("companionDivert.resume")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.warning.opacity(0.5), lineWidth: 1))
    }

    // MARK: - Actions

    private func go(to row: CompanionDivert.Row) {
        let command = CompanionCommand.divert(field: CompanionDivert.field(row.aerodrome))
        let goal: CompanionDivert.Request.Goal = row.isDestination ? .destination : .divert(ident: row.aerodrome.ident)
        send(CompanionDivert.Request(goal: goal, command: command, sentAt: Date()))
    }

    private func resume() {
        send(CompanionDivert.Request(goal: .resume, command: .resumeRoute, sentAt: Date()))
    }

    private func send(_ new: CompanionDivert.Request) {
        companionConnectivityManager.sendCommand(new.command)
        request = new
    }

    /// Every second: the request followed (closed once the iPad's plan shows it, sent again meanwhile),
    /// and the distances of the fields shown brought up to date, in the order they were shown.
    private func follow(_ now: Date) {
        if var current = request {
            switch current.step(now: now, plan: plan) {
            case .taken:
                request = nil
                onClose()
                return
            case .resend:
                companionConnectivityManager.sendCommand(current.command)
                request = current
            case .gaveUp:
                request = current
            case .wait:
                break
            }
        }
        let here = reference
        // No position when the picker opened, one now: the list it could not make then.
        if !hasNearest, !isLoading, let here { makeNearest(from: here) }
        nearest = CompanionDivert.rows(nearest.map(\.aerodrome), from: here, destinationIdent: destinationIdent,
                                       lastWaypointName: lastWaypointName)
        results = CompanionDivert.rows(results.map(\.aerodrome), from: here, destinationIdent: destinationIdent,
                                       lastWaypointName: lastWaypointName)
    }

    // MARK: - Data

    private func load() async {
        await airportDataService.prepareSearch()
        defer {
            isLoading = false
            // Typed while the airports were loading: that search found nothing to search.
            search()
        }
        if let last = plan?.waypoints.last, last.hasValidCoordinate {
            destinationIdent = airportDataService.routeDestinationIdent(
                name: last.name, coordinate: CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude))
        }
        if let here = reference { makeNearest(from: here) }
    }

    /// The nearest fixed-wing landing sites, as the iPad's sheet takes them, nearest first.
    private func makeNearest(from here: CLLocationCoordinate2D) {
        let found = airportDataService.findNearestAirports(to: here, limit: 40, maxDistanceNm: CompanionDivert.rangeNM,
                                                           types: AirportType.fixedWing)
            .filter(AirportDataService.isPlanningLandingSite)
            .map(airportDataService.planningAerodrome)
        nearest = CompanionDivert.nearest(from: here, aerodromes: found, destinationIdent: destinationIdent,
                                          lastWaypointName: lastWaypointName)
        hasNearest = true
    }

    /// Any fixed-wing landing site by code or name, the nearest first after an exact ident.
    private func search() {
        guard isSearching, !isLoading else { results = []; return }
        let term = query.trimmingCharacters(in: .whitespaces)
        let here = reference
        let found = airportDataService.searchAirports(query: term, limit: 8, near: here, types: AirportType.fixedWing)
            .filter(AirportDataService.isPlanningLandingSite)
            .map(airportDataService.planningAerodrome)
        results = CompanionDivert.rows(found, from: here, destinationIdent: destinationIdent,
                                       lastWaypointName: lastWaypointName)
    }
}
