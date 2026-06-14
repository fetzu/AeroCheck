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
    @State private var nightModePreference: NightModePreference = .off
    @State private var isLoadingSettings: Bool = false

    var body: some View {
        Form {
            checklistSection
            flightLoggingSection
            displaySection
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
        .onChange(of: nightModePreference) { _, _ in if !isLoadingSettings { saveSettings() } }
    }

    // MARK: - Checklist Section

    private var checklistSection: some View {
        Section {
            Toggle(L10n.Settings.stepByStep, isOn: $stepByStepHighlighting)
            Toggle(L10n.Settings.learningMode, isOn: $learningMode)
            Toggle(L10n.Settings.circuitMode, isOn: $enableCircuitMode)

            Picker(L10n.Settings.checklistLanguage, selection: $checklistLanguage) {
                ForEach(ChecklistLanguage.availableLanguages) { language in
                    Text(language.displayName).tag(language)
                }
            }
        } header: {
            Label(L10n.Settings.checklist, systemImage: "checklist")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.Settings.stepByStepFooter)
                Text(L10n.Settings.learningModeFooter)
                Text(L10n.Settings.circuitModeFooter)
                Text(L10n.Settings.checklistLanguageFooter)
            }
        }
    }

    // MARK: - Flight Logging Section

    private var flightLoggingSection: some View {
        Section {
            Toggle(L10n.Settings.logEngineHours, isOn: $logEngineHours)
        } header: {
            Label(L10n.Settings.flightLogging, systemImage: "clock.badge.checkmark")
        } footer: {
            Text(L10n.Settings.logEngineHoursFooter)
        }
    }

    // MARK: - Display Section

    private var displaySection: some View {
        Section {
            Toggle(L10n.Settings.keepScreenOn, isOn: $keepScreenOn)
            Toggle(L10n.Settings.alwaysUseUTC, isOn: $alwaysUseUTC)
            Picker(L10n.Settings.nightMode, selection: $nightModePreference) {
                Text(L10n.Settings.nightModeOff).tag(NightModePreference.off)
                Text(L10n.Settings.nightModeOn).tag(NightModePreference.on)
                Text(L10n.Settings.nightModeSystem).tag(NightModePreference.system)
            }
        } header: {
            Label(L10n.Settings.display, systemImage: "sun.max.fill")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.Settings.keepScreenOnFooter)
                Text(L10n.Settings.alwaysUseUTCFooter)
                Text(L10n.Settings.nightModeFooter)
            }
        }
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
        nightModePreference = appState.settings.nightModePreference
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
        appState.settings.nightModePreference = nightModePreference
        appState.saveSettings()
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn
    }
}
