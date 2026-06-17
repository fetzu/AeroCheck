import SwiftUI

/// Settings sub-page for flight planning and experimental airspeed
struct FlightPlanningSettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var enableFlightPlanning: Bool = false
    @State private var waypointProximityThreshold: Double = 500
    @State private var terrainAltitudeUnit: TerrainAltitudeUnit = .feet
    @State private var showEstimatedAirspeed: Bool = false
    @State private var stallAlertSound: Bool = false
    @State private var showFlightPlanningWarning: Bool = false
    @State private var showEstimatedAirspeedWarning: Bool = false
    @State private var pendingEstimatedAirspeedValue: Bool = false
    @State private var isLoadingSettings: Bool = false

    private let tint: Color = .orange

    var body: some View {
        SettingsPage {
            flightPlanningSection
            experimentalAirspeedSection
        }
        .navigationTitle(L10n.Settings.flightPlanning)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSettings() }
        .onChange(of: appState.settings) { _, _ in loadSettings() }
        .onChange(of: enableFlightPlanning) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: waypointProximityThreshold) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: terrainAltitudeUnit) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: showEstimatedAirspeed) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: stallAlertSound) { _, _ in if !isLoadingSettings { saveSettings() } }
        .sheet(isPresented: $showFlightPlanningWarning) {
            FlightPlanningWarningSheet(
                isPresented: $showFlightPlanningWarning,
                enableFlightPlanning: $enableFlightPlanning
            )
        }
        .sheet(isPresented: $showEstimatedAirspeedWarning) {
            EstimatedAirspeedWarningSheet(
                isPresented: $showEstimatedAirspeedWarning,
                showEstimatedAirspeed: $showEstimatedAirspeed
            )
        }
    }

    // MARK: - Flight Planning Section

    private var flightPlanningSection: some View {
        SettingsGroup(title: "\(L10n.Settings.flightPlanning) · \(L10n.Tag.beta)",
                      tint: tint,
                      footer: L10n.Settings.flightPlanningFooter) {
            SettingsToggleRow(
                icon: "map.fill",
                title: L10n.Settings.enableFlightPlanning,
                tint: tint,
                isOn: Binding(
                    get: { enableFlightPlanning },
                    set: { newValue in
                        if newValue {
                            showFlightPlanningWarning = true
                        } else {
                            enableFlightPlanning = false
                        }
                    }
                )
            )

            if enableFlightPlanning {
                VStack(alignment: .leading, spacing: 9) {
                    SettingsRowLabel(
                        icon: "scope",
                        title: L10n.Settings.waypointProximity,
                        subtitle: L10n.Settings.waypointProximityFooter,
                        tint: tint
                    )
                    HStack {
                        Slider(value: $waypointProximityThreshold, in: 100...2000, step: 100)
                            .tint(.aviationGold)
                        Text("\(Int(waypointProximityThreshold)) m")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                SettingsMenuRow(
                    icon: "mountain.2.fill",
                    title: L10n.Settings.terrainAltitudeUnit,
                    subtitle: L10n.Settings.terrainUnitFooter,
                    tint: tint,
                    selection: $terrainAltitudeUnit
                ) {
                    ForEach(TerrainAltitudeUnit.allCases) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
            }
        }
    }

    // MARK: - Experimental Airspeed Section

    private var experimentalAirspeedSection: some View {
        SettingsGroup(title: "\(L10n.Settings.experimental) · \(L10n.Tag.beta)",
                      tint: tint,
                      footer: "\(L10n.Settings.experimentalFooter)\n\(L10n.Settings.switzerlandOnly)") {
            SettingsToggleRow(
                icon: "exclamationmark.triangle.fill",
                title: L10n.Settings.showEstimatedAirspeed,
                tint: tint,
                isOn: Binding(
                    get: { showEstimatedAirspeed },
                    set: { newValue in
                        if newValue {
                            pendingEstimatedAirspeedValue = true
                            showEstimatedAirspeedWarning = true
                        } else {
                            showEstimatedAirspeed = false
                        }
                    }
                )
            )
            if showEstimatedAirspeed {
                SettingsToggleRow(
                    icon: "speaker.wave.2.fill",
                    title: L10n.Settings.stallAlertSound,
                    tint: tint,
                    isOn: $stallAlertSound
                )
            }
        }
    }

    // MARK: - Settings Persistence

    private func loadSettings() {
        isLoadingSettings = true
        enableFlightPlanning = appState.settings.enableFlightPlanning
        waypointProximityThreshold = appState.settings.waypointProximityThreshold
        terrainAltitudeUnit = appState.settings.terrainAltitudeUnit
        showEstimatedAirspeed = appState.settings.showEstimatedAirspeed
        stallAlertSound = appState.settings.stallAlertSound
        DispatchQueue.main.async {
            self.isLoadingSettings = false
        }
    }

    private func saveSettings() {
        appState.settings.enableFlightPlanning = enableFlightPlanning
        appState.settings.waypointProximityThreshold = waypointProximityThreshold
        appState.settings.terrainAltitudeUnit = terrainAltitudeUnit
        appState.settings.showEstimatedAirspeed = showEstimatedAirspeed
        appState.settings.stallAlertSound = stallAlertSound
        appState.saveSettings()
    }
}
