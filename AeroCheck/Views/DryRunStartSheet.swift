import SwiftUI

// MARK: - Dry run (6.4.0): starting one

/// Fly a dry run on the ground: circuits at an aerodrome (the home aerodrome first, LSZQ when the app has no
/// airport data yet), or the route the sheet was opened from; any of the pilot's aircraft; a pace. It prepares
/// the dry run while it waits (the aircraft's checklist, the route armed), then goes, and the Cockpit covers
/// the app once it has (`DryRunCenter.launchPrepared`, from the app's root). (6.4.0)
struct DryRunStartSheet: View {
    let route: FlightPlan?

    @Environment(AppState.self) private var appState
    @EnvironmentObject private var airportDataService: AirportDataService
    @EnvironmentObject private var aircraftDataService: AircraftDataService
    @ObservedObject private var center = DryRunCenter.shared
    @Environment(\.dismiss) private var dismiss

    @State private var flyRoute = true
    @State private var ident = ""
    @State private var aircraftId = ""
    @State private var rate = DryRunSetup.defaultRate
    @State private var loaded = false
    @State private var problem: String?

    private let tint = Color.aviationGold

    var body: some View {
        NavigationStack {
            SettingsPage {
                Text(L10n.DryRun.startIntro)
                    .font(.aero(.subheadline))
                    .foregroundColor(.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

                if route != nil {
                    SettingsGroup(tint: tint) {
                        SettingsRowLabel(icon: "point.topleft.down.to.point.bottomright.curvepath", title: L10n.DryRun.what, tint: tint)
                        Picker(L10n.DryRun.what, selection: $flyRoute) {
                            Text(L10n.DryRun.theRoute).tag(true)
                            Text(L10n.DryRun.circuits).tag(false)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 11)
                    }
                }

                if let route, flyRoute {
                    SettingsGroup(title: L10n.DryRun.theRoute, tint: tint) {
                        SettingsValueRow(icon: "map", title: route.name, tint: tint, value: routeText)
                        if let routeProblem {
                            SettingsRowLabel(icon: "exclamationmark.triangle", title: routeProblem, tint: .aviationAmber)
                        }
                    }
                } else {
                    SettingsGroup(title: L10n.DryRun.circuits, tint: tint, footer: dataFooter) {
                        HStack(spacing: 10) {
                            Text(L10n.DryRun.aerodrome)
                                .font(.aero(.body))
                            Spacer()
                            TextField("LSZQ", text: $ident)
                                .font(.aero(.body, design: .monospaced))
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .frame(maxWidth: 140)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        SettingsRowLabel(icon: circuitsField == nil ? "exclamationmark.triangle" : "arrow.triangle.turn.up.right.circle",
                                         title: circuitsText, tint: circuitsField == nil ? .aviationAmber : tint)
                    }
                }

                SettingsGroup(title: L10n.DryRun.aircraft, tint: tint) {
                    SettingsMenuRow(icon: "airplane", title: L10n.DryRun.aircraft, tint: tint, selection: $aircraftId) {
                        ForEach(aircraft) { option in
                            Text("\(option.registration) · \(option.modelName)").tag(option.id)
                        }
                    }
                }

                SettingsGroup(title: L10n.DryRun.pace, tint: tint, footer: L10n.DryRun.startFooter) {
                    Picker(L10n.DryRun.pace, selection: $rate) {
                        ForEach(DryRunSetup.rates, id: \.self) { Text(DryRunSetup.paceLabel($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }

                if let problem {
                    Text(problem)
                        .font(.aero(.subheadline))
                        .foregroundColor(.aviationAmber)
                        .padding(.horizontal, 4)
                }

                Button(action: start) {
                    HStack(spacing: 10) {
                        if center.isStarting { ProgressView().tint(.black) }
                        Text(L10n.DryRun.fly)
                            .font(.aero(size: 19, weight: .bold))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 12).fill(setup == nil ? Color.aviationGold.opacity(0.35) : Color.aviationGold))
                }
                .buttonStyle(.plain)
                .disabled(setup == nil || center.isStarting)
            }
            .navigationTitle(L10n.DryRun.startTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.cancel) { dismiss() }
                        .disabled(center.isStarting)
                }
            }
        }
        .interactiveDismissDisabled(center.isStarting)
        .task { await load() }
    }

    // MARK: What it flies

    private var aircraft: [AircraftOption] {
        AircraftOption.flyable(remote: aircraftDataService.availableAircraft, settings: appState.settings,
                               canFly: aircraftDataService.canFly)
    }

    private var chosenAircraft: AircraftOption? { aircraft.first { $0.id == aircraftId } }

    private var circuitsField: DryRunAerodrome? {
        guard loaded else { return nil }
        let code = ident.trimmingCharacters(in: .whitespaces)
        return code.isEmpty ? nil : DryRunCenter.aerodrome(code, airports: airportDataService)
    }

    private var routeFields: (DryRunAerodrome, DryRunAerodrome)? {
        guard loaded, let route, let first = route.waypoints.first, let last = route.waypoints.last,
              route.waypoints.count >= 2,
              let departure = DryRunCenter.aerodrome(DryRunSetup.aerodromeIdent(of: first), airports: airportDataService),
              let destination = DryRunCenter.aerodrome(DryRunSetup.aerodromeIdent(of: last), airports: airportDataService)
        else { return nil }
        return (departure, destination)
    }

    private var setup: DryRunSetup? {
        var mission: DryRunSetup.Mission
        if let route, flyRoute {
            guard let fields = routeFields else { return nil }
            mission = .route(route, departure: fields.0, destination: fields.1)
        } else {
            guard let field = circuitsField else { return nil }
            mission = .circuits(field)
        }
        return DryRunSetup(mission: mission, aircraft: chosenAircraft, rate: rate)
    }

    // MARK: Words

    private var circuitsText: String {
        guard loaded else { return L10n.DryRun.looking }
        let code = ident.trimmingCharacters(in: .whitespaces).uppercased()
        guard let field = circuitsField else { return L10n.DryRun.noRunway(code.isEmpty ? "?" : code) }
        return Self.describe(field)
    }

    private var routeText: String {
        guard let route, let first = route.waypoints.first, let last = route.waypoints.last else { return "" }
        return "\(DryRunSetup.aerodromeIdent(of: first)) → \(DryRunSetup.aerodromeIdent(of: last))"
    }

    private var routeProblem: String? {
        guard loaded, let route else { return nil }
        guard route.waypoints.count >= 2 else { return L10n.DryRun.routeTooShort }
        if routeFields == nil {
            let ends = [route.waypoints.first!, route.waypoints.last!].map(DryRunSetup.aerodromeIdent(of:))
            let missing = ends.first { DryRunCenter.aerodrome($0, airports: airportDataService) == nil } ?? ends[0]
            return L10n.DryRun.noRunway(missing)
        }
        return nil
    }

    private var dataFooter: String? {
        airportDataService.isDataAvailable ? nil : L10n.DryRun.noAirportData
    }

    /// "LSZQ Bressaucourt · runway 07, left-hand circuit at 2,900 ft".
    static func describe(_ field: DryRunAerodrome) -> String {
        let runway = Int((field.runwayHeading / 10).rounded()) % 36
        let designator = String(format: "%02d", runway == 0 ? 36 : runway)
        let altitude = Int((field.patternAltitudeFt / 50).rounded() * 50)
        let side = field.circuitSide == .left ? L10n.DryRun.leftHand(altitude.formatted()) : L10n.DryRun.rightHand(altitude.formatted())
        return "\(field.ident) \(field.name) · \(L10n.DryRun.runway(designator)), \(side)"
    }

    // MARK: Going

    private func load() async {
        await airportDataService.ensureLoaded()
        await OFMDataService.shared.ensureLoaded()
        if ident.isEmpty {
            let home = appState.settings.homeAerodromeIdent?.uppercased()
            ident = home.flatMap { DryRunCenter.aerodrome($0, airports: airportDataService) }.map { _ in home! }
                ?? DryRunAerodrome.lszq.ident
        }
        if aircraftId.isEmpty {
            aircraftId = (aircraft.first { $0.isSelected(in: appState.settings) } ?? aircraft.first)?.id ?? ""
        }
        loaded = true
    }

    private func start() {
        guard let setup else { return }
        problem = nil
        Task {
            let outcome = await center.prepare(setup, settings: { [appState] in appState.settings },
                                               airports: airportDataService, aircraftData: aircraftDataService,
                                               isFlightActive: appState.isFlightActive)
            switch outcome {
            case .started: dismiss()
            case .checklistUnavailable: problem = L10n.DryRun.checklistUnavailable
            case .busy: problem = L10n.DryRun.busy
            case .refused: problem = L10n.DryRun.refused
            }
        }
    }
}
