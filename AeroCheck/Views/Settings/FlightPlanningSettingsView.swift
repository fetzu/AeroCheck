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

    var body: some View {
        Form {
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
        Section {
            Toggle(L10n.Settings.enableFlightPlanning, isOn: Binding(
                get: { enableFlightPlanning },
                set: { newValue in
                    if newValue {
                        showFlightPlanningWarning = true
                    } else {
                        enableFlightPlanning = false
                    }
                }
            ))

            if enableFlightPlanning {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L10n.Settings.waypointProximity)
                        Spacer()
                        Text("\(Int(waypointProximityThreshold)) m")
                            .foregroundColor(.secondary)
                    }

                    Slider(value: $waypointProximityThreshold, in: 100...2000, step: 100)
                        .tint(.aviationGold)
                }

                Picker(L10n.Settings.terrainAltitudeUnit, selection: $terrainAltitudeUnit) {
                    ForEach(TerrainAltitudeUnit.allCases) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .pickerStyle(.menu)
            }
        } header: {
            HStack {
                Label(L10n.Settings.flightPlanning, systemImage: "map.fill")
                Text(L10n.Tag.beta)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.aviationAmber)
                    )
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.Settings.flightPlanningFooter)
                if enableFlightPlanning {
                    Text(L10n.Settings.waypointProximityFooter)
                    Text(L10n.Settings.terrainUnitFooter)
                }
            }
        }
    }

    // MARK: - Experimental Airspeed Section

    private var experimentalAirspeedSection: some View {
        Section {
            Toggle(L10n.Settings.showEstimatedAirspeed, isOn: Binding(
                get: { showEstimatedAirspeed },
                set: { newValue in
                    if newValue {
                        pendingEstimatedAirspeedValue = true
                        showEstimatedAirspeedWarning = true
                    } else {
                        showEstimatedAirspeed = false
                    }
                }
            ))
            if showEstimatedAirspeed {
                Toggle(L10n.Settings.stallAlertSound, isOn: $stallAlertSound)
            }
        } header: {
            HStack {
                Label(L10n.Settings.experimental, systemImage: "exclamationmark.triangle.fill")
                Text(L10n.Tag.beta)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.aviationAmber)
                    )
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.Settings.experimentalFooter)
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.aviationAmber)
                    Text(L10n.Settings.switzerlandOnly)
                        .foregroundColor(.aviationAmber)
                }
                .font(.caption)
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
