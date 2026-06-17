import SwiftUI

/// Settings sub-page for checklist behavior, flight logging, and display options
struct ChecklistFlightSettingsView: View {
    @EnvironmentObject var appState: AppState

    @State private var stepByStepHighlighting: Bool = true
    @State private var learningMode: Bool = false
    @State private var enableCircuitMode: Bool = false
    @State private var checklistLanguage: ChecklistLanguage = .auto
    @State private var logEngineHours: Bool = false
    @State private var keepScreenOn: Bool = true
    @State private var alwaysUseUTC: Bool = false
    @State private var themePreference: ThemePreference = .day
    @State private var isLoadingSettings: Bool = false

    private let tint: Color = .altimeterBlue

    var body: some View {
        SettingsPage {
            SettingsGroup(title: L10n.Settings.checklist, tint: tint) {
                SettingsToggleRow(icon: "checklist", title: L10n.Settings.stepByStep,
                                  subtitle: L10n.Settings.stepByStepFooter, tint: tint, isOn: $stepByStepHighlighting)
                SettingsToggleRow(icon: "graduationcap", title: L10n.Settings.learningMode,
                                  subtitle: L10n.Settings.learningModeFooter, tint: tint, isOn: $learningMode)
                SettingsToggleRow(icon: "arrow.triangle.2.circlepath", title: L10n.Settings.circuitMode,
                                  subtitle: L10n.Settings.circuitModeFooter, tint: tint, isOn: $enableCircuitMode)
                SettingsMenuRow(icon: "character.bubble", title: L10n.Settings.checklistLanguage,
                                subtitle: L10n.Settings.checklistLanguageFooter, tint: tint, selection: $checklistLanguage) {
                    ForEach(ChecklistLanguage.availableLanguages) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            }

            SettingsGroup(title: L10n.Settings.flightLogging, tint: tint) {
                SettingsToggleRow(icon: "clock.badge.checkmark", title: L10n.Settings.logEngineHours,
                                  subtitle: L10n.Settings.logEngineHoursFooter, tint: tint, isOn: $logEngineHours)
            }

            SettingsGroup(title: L10n.Settings.display, tint: tint) {
                SettingsToggleRow(icon: "sun.max", title: L10n.Settings.keepScreenOn,
                                  subtitle: L10n.Settings.keepScreenOnFooter, tint: tint, isOn: $keepScreenOn)
                SettingsToggleRow(icon: "globe", title: L10n.Settings.alwaysUseUTC,
                                  subtitle: L10n.Settings.alwaysUseUTCFooter, tint: tint, isOn: $alwaysUseUTC)
                themeRow
            }
        }
        .navigationTitle(L10n.Settings.checklistAndFlight)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSettings() }
        .onChange(of: appState.settings) { _, _ in loadSettings() }
        .onChange(of: stepByStepHighlighting) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: learningMode) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: enableCircuitMode) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: checklistLanguage) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: logEngineHours) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: keepScreenOn) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: alwaysUseUTC) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: themePreference) { _, _ in if !isLoadingSettings { saveSettings() } }
    }

    // MARK: - Theme (segmented, label above)

    private var themeRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            SettingsRowLabel(icon: "circle.lefthalf.filled", title: L10n.Settings.theme, subtitle: L10n.Settings.themeFooter, tint: tint)
            Picker(L10n.Settings.theme, selection: $themePreference) {
                Text(L10n.Settings.themeAuto).tag(ThemePreference.auto)
                Text(L10n.Settings.themeDay).tag(ThemePreference.day)
                Text(L10n.Settings.themeSunlight).tag(ThemePreference.sunlight)
                Text(L10n.Settings.themeNight).tag(ThemePreference.night)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Settings Persistence

    private func loadSettings() {
        isLoadingSettings = true
        stepByStepHighlighting = appState.settings.stepByStepHighlighting
        learningMode = appState.settings.learningMode
        enableCircuitMode = appState.settings.enableCircuitMode
        checklistLanguage = appState.settings.checklistLanguage
        logEngineHours = appState.settings.logEngineHours
        keepScreenOn = appState.settings.keepScreenOn
        alwaysUseUTC = appState.settings.alwaysUseUTC
        themePreference = appState.settings.themePreference
        DispatchQueue.main.async {
            self.isLoadingSettings = false
        }
    }

    private func saveSettings() {
        appState.settings.stepByStepHighlighting = stepByStepHighlighting
        appState.settings.learningMode = learningMode
        appState.settings.enableCircuitMode = enableCircuitMode
        appState.settings.checklistLanguage = checklistLanguage
        appState.settings.logEngineHours = logEngineHours
        appState.settings.keepScreenOn = keepScreenOn
        appState.settings.alwaysUseUTC = alwaysUseUTC
        appState.settings.themePreference = themePreference
        appState.saveSettings()
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn
    }
}
