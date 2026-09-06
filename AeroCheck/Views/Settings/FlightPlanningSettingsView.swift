import SwiftUI

/// Settings for flights: who is flying, what a flight costs, and how the route builder behaves.
///
/// The master "enable flight planning" toggle is gone. It was a BETA gate, complete with a warning
/// sheet, and planning is now the spine of the app — Home offers to plan a flight on every launch.
/// A switch that turns the primary feature off, behind a dialog implying it is risky, is a footgun
/// whatever it was in v4. (v5.0.0)
struct FlightPlanningSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var pilotName: String = ""
    @State private var isStudentPilot = false
    @State private var instructorName: String = ""
    @State private var enableCostTracking: Bool = true
    @State private var waypointProximityThreshold: Double = 500
    @State private var terrainAltitudeUnit: TerrainAltitudeUnit = .feet
    @State private var isLoadingSettings: Bool = false

    private let tint: Color = .orange

    var body: some View {
        SettingsPage {
            pilotSection
            costSection
            flightPlanningSection
        }
        .navigationTitle(L10n.Flights.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSettings() }
        .onChange(of: appState.settings) { _, _ in loadSettings() }
        .onChange(of: pilotName) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: isStudentPilot) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: instructorName) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: enableCostTracking) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: waypointProximityThreshold) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: terrainAltitudeUnit) { _, _ in if !isLoadingSettings { saveSettings() } }
    }

    // MARK: - Pilot

    /// The pilot's own name. It was added with the logbook work and never given an editor, so the
    /// PDF extract's "Holder" line and the PIC column had no way of being filled in. (v5.0.0)
    private var pilotSection: some View {
        SettingsGroup(title: L10n.Settings.pilot,
                      tint: tint,
                      footer: L10n.Settings.pilotNameFooter) {
            VStack(alignment: .leading, spacing: 9) {
                SettingsRowLabel(icon: "person.text.rectangle",
                                 title: L10n.Settings.pilotName,
                                 subtitle: nil,
                                 tint: tint)
                TextField(L10n.Settings.pilotNamePlaceholder, text: $pilotName)
                    .textInputAutocapitalization(.words)
                    .scaledFont(size: 16, relativeTo: .body)
                    .foregroundColor(.primaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.cardBackground))

                Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 3)

                // A licensed pilot logs PIC; a student logs DUAL with the instructor named in the
                // PIC column, because that column says who commanded the aircraft. The app cannot
                // tell the two apart from a flight, so it asks once. (v5.x)
                Toggle(isOn: $isStudentPilot) {
                    SettingsRowLabel(icon: "graduationcap",
                                     title: L10n.Settings.studentPilot,
                                     subtitle: L10n.Settings.studentPilotSubtitle,
                                     tint: tint)
                }
                .tint(.aviationGreen)

                if isStudentPilot {
                    TextField(L10n.Settings.instructorNamePlaceholder, text: $instructorName)
                        .textInputAutocapitalization(.words)
                        .scaledFont(size: 16, relativeTo: .body)
                        .foregroundColor(.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.cardBackground))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    // MARK: - Cost

    private var costSection: some View {
        SettingsGroup(title: L10n.Cost.title,
                      tint: tint,
                      footer: L10n.Settings.costTrackingFooter) {
            SettingsToggleRow(icon: "banknote",
                              title: L10n.Settings.costTracking,
                              tint: tint,
                              isOn: $enableCostTracking)
        }
    }

    // MARK: - Flight Planning Section

    private var flightPlanningSection: some View {
        SettingsGroup(title: L10n.Settings.flightPlanning,
                      tint: tint,
                      footer: L10n.Settings.flightPlanningFooter) {
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

    // MARK: - Settings Persistence

    private func loadSettings() {
        isLoadingSettings = true
        pilotName = appState.settings.pilotName
        isStudentPilot = appState.settings.isStudentPilot
        instructorName = appState.settings.instructorName
        enableCostTracking = appState.settings.enableCostTracking
        waypointProximityThreshold = appState.settings.waypointProximityThreshold
        terrainAltitudeUnit = appState.settings.terrainAltitudeUnit
        DispatchQueue.main.async {
            self.isLoadingSettings = false
        }
    }

    private func saveSettings() {
        appState.settings.pilotName = pilotName.trimmingCharacters(in: .whitespaces)
        appState.settings.isStudentPilot = isStudentPilot
        appState.settings.instructorName = instructorName.trimmingCharacters(in: .whitespaces)
        appState.settings.enableCostTracking = enableCostTracking
        appState.settings.waypointProximityThreshold = waypointProximityThreshold
        appState.settings.terrainAltitudeUnit = terrainAltitudeUnit
        appState.saveSettings()
    }
}
