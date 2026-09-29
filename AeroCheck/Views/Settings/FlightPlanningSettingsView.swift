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
    @State private var terrainAltitudeUnit: TerrainAltitudeUnit = .feet
    @State private var isLoadingSettings: Bool = false

    private let tint: Color = .orange

    var body: some View {
        SettingsPage {
            pilotSection
            homeAerodromeSection
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

    // MARK: - Home aerodrome

    /// Where the pilot is based: the nav log's landings at base are counted there. A pilot who logged
    /// flights before it existed is offered the logbook's guess, here and never at launch. (v6.1)
    private var homeAerodromeSection: some View {
        SettingsGroup(title: L10n.HomeAerodrome.title, tint: tint) {
            VStack(alignment: .leading, spacing: 9) {
                SettingsRowLabel(icon: "house",
                                 title: L10n.HomeAerodrome.basedAt,
                                 subtitle: L10n.HomeAerodrome.rowSubtitle,
                                 tint: tint)
                AerodromeIdentField(ident: homeAerodrome,
                                    suggestion: HomeAerodrome.suggestion(from: appState.flights))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    /// Saved as soon as it names an aerodrome, like the rest of this page.
    private var homeAerodrome: Binding<String?> {
        Binding(
            get: { appState.settings.homeAerodromeIdent },
            set: { ident in
                guard ident != appState.settings.homeAerodromeIdent else { return }
                appState.settings.homeAerodromeIdent = ident
                appState.saveSettings()
            }
        )
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
            // The waypoint-proximity slider is gone: waypoints are marked from the GPS track, with
            // no radius to set. (v6.0.1)
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
        appState.settings.terrainAltitudeUnit = terrainAltitudeUnit
        appState.saveSettings()
    }
}
