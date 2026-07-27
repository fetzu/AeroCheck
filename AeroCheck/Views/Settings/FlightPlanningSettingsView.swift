import SwiftUI

/// Settings sub-page for flight planning and experimental airspeed
struct FlightPlanningSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var enableFlightPlanning: Bool = false
    @State private var waypointProximityThreshold: Double = 500
    @State private var terrainAltitudeUnit: TerrainAltitudeUnit = .feet
    @State private var showFlightPlanningWarning: Bool = false
    @State private var isLoadingSettings: Bool = false

    private let tint: Color = .orange

    var body: some View {
        SettingsPage {
            flightPlanningSection
        }
        .navigationTitle(L10n.Settings.flightPlanning)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSettings() }
        .onChange(of: appState.settings) { _, _ in loadSettings() }
        .onChange(of: enableFlightPlanning) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: waypointProximityThreshold) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: terrainAltitudeUnit) { _, _ in if !isLoadingSettings { saveSettings() } }
        .sheet(isPresented: $showFlightPlanningWarning) {
            FlightPlanningWarningSheet(
                isPresented: $showFlightPlanningWarning,
                enableFlightPlanning: $enableFlightPlanning
            )
        }
    }

    // MARK: - Flight Planning Section

    private var flightPlanningSection: some View {
        SettingsGroup(title: L10n.Settings.flightPlanning,
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

    // MARK: - Settings Persistence

    private func loadSettings() {
        isLoadingSettings = true
        enableFlightPlanning = appState.settings.enableFlightPlanning
        waypointProximityThreshold = appState.settings.waypointProximityThreshold
        terrainAltitudeUnit = appState.settings.terrainAltitudeUnit
        DispatchQueue.main.async {
            self.isLoadingSettings = false
        }
    }

    private func saveSettings() {
        appState.settings.enableFlightPlanning = enableFlightPlanning
        appState.settings.waypointProximityThreshold = waypointProximityThreshold
        appState.settings.terrainAltitudeUnit = terrainAltitudeUnit
        appState.saveSettings()
    }
}
