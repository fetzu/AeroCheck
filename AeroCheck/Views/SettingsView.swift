import SwiftUI

/// Settings view for configuring the app
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var locationManager: LocationManager
    @Environment(\.dismiss) var dismiss

    @State private var selectedAircraft: AircraftType = .wt9Dynamic
    @State private var gpsInterval: Double = 5.0
    @State private var keepScreenOn: Bool = true
    @State private var stepByStepHighlighting: Bool = true
    @State private var learningMode: Bool = false
    @State private var forceICAOChartLayer: Bool = false
    
    var body: some View {
        NavigationView {
            Form {
                // Aircraft section
                Section {
                    Picker("Aircraft in use", selection: $selectedAircraft) {
                        ForEach(AircraftType.allCases) { aircraft in
                            HStack {
                                Text(aircraft.registration)
                                    .font(.system(.body, design: .monospaced))
                                Text("(\(aircraft.shortModelName))")
                                    .foregroundColor(.secondary)
                            }
                            .tag(aircraft)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Label("Aircraft", systemImage: "airplane")
                } footer: {
                    Text("Select the aircraft you will be flying. This determines the checklist and speeds used.")
                }
                
                // GPS section
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Recording Interval")
                            Spacer()
                            Text("\(Int(gpsInterval)) seconds")
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: $gpsInterval, in: 1...30, step: 1)
                            .tint(.aviationGold)
                    }
                    
                    HStack {
                        Text("GPS Status")
                        Spacer()
                        Text(gpsStatusText)
                            .foregroundColor(gpsStatusColor)
                    }
                    
                    if locationManager.authorizationStatus == .notDetermined {
                        Button("Request GPS Permission") {
                            locationManager.requestAuthorization()
                        }
                    }
                } header: {
                    Label("GPS Tracking", systemImage: "location.fill")
                } footer: {
                    Text("Lower intervals provide more detailed tracks but use more storage")
                }
                
                // Display section
                Section {
                    Toggle("Keep Screen On", isOn: $keepScreenOn)
                } header: {
                    Label("Display", systemImage: "sun.max.fill")
                } footer: {
                    Text("Prevents the screen from dimming during flight")
                }

                // Navigation section
                Section {
                    Toggle("Force ICAO Chart Layer", isOn: $forceICAOChartLayer)
                } header: {
                    Label("Navigation", systemImage: "map")
                } footer: {
                    Text("When ON, the ICAO Chart (1:500,000) remains at all zoom levels. When OFF, seamlessly switches to Segelflugkarte (1:300,000) when zooming in.")
                }

                // Checklist section
                Section {
                    Toggle("Step-by-Step Highlighting", isOn: $stepByStepHighlighting)
                    
                    Toggle("Learning Mode (show all checks)", isOn: $learningMode)
                } header: {
                    Label("Checklist", systemImage: "checklist")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Step-by-Step: Highlights items one at a time. Tap anywhere to advance.")
                        Text("Learning Mode: When OFF, memorizable checks are hidden to test your memory. When ON, all checks are shown for studying.")
                    }
                }
                
                // About section
                Section {
                    Link(destination: URL(string: "https://github.com/fetzu/AeroCheck/releases")!) {
                        HStack {
                            Text("App Version")
                                .foregroundColor(.primary)
                            Spacer()
                            Text("1.0.0")
                                .foregroundColor(.secondary)
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Link(destination: URL(string: "https://www.julienbono.ch/")!) {
                        HStack {
                            Text("Author")
                                .foregroundColor(.primary)
                            Spacer()
                            Text("Julien 'fetzu' Bono")
                                .foregroundColor(.secondary)
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Link(destination: URL(string: "https://www.gvmp.aero/")!) {
                        HStack {
                            Text("Organization")
                                .foregroundColor(.primary)
                            Spacer()
                            Text("Aéroclub du Jura (GVMP)")
                                .foregroundColor(.secondary)
                            Image(systemName: "arrow.up.forward.square")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .foregroundColor(.primary)
                            Text("Open Source")
                                .font(.headline)
                        }

                        Link(destination: URL(string: "https://github.com/fetzu/AeroCheck")!) {
                            HStack(spacing: 4) {
                                Text("This app is open source and available on GitHub.")
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.caption)
                            }
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        }

                        Link(destination: URL(string: "https://raw.githubusercontent.com/fetzu/AeroCheck/refs/heads/main/LICENSE")!) {
                            HStack(spacing: 4) {
                                Text("Released under the MIT License.")
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.caption)
                            }
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Label("About", systemImage: "info.circle.fill")
                }

                // Available Checklists section
                Section {
                    ForEach(AircraftType.allCases) { aircraft in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(aircraft.registration)
                                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                                Text(aircraft.shortModelName)
                                    .foregroundColor(.secondary)
                            }
                            HStack {
                                Text("Version \(aircraft.checklistVersion)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("•")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(aircraft.lastUpdated)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Label("Available Checklists", systemImage: "checklist")
                } footer: {
                    Text("Checklist data provided by GVMP")
                }
                
                // Data section
                Section {
                    HStack {
                        Text("Recorded Flights")
                        Spacer()
                        Text("\(appState.flights.count)")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Total GPS Points")
                        Spacer()
                        Text("\(totalGPSPoints)")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Label("Data", systemImage: "externaldrive.fill")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveSettings()
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadSettings()
            }
        }
        .preferredColorScheme(.dark)
    }
    
    // MARK: - Computed Properties
    
    private var gpsStatusText: String {
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return "Authorized"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not Set"
        @unknown default:
            return "Unknown"
        }
    }
    
    private var gpsStatusColor: Color {
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return .green
        case .denied, .restricted:
            return .red
        default:
            return .secondary
        }
    }
    
    private var totalGPSPoints: Int {
        appState.flights.reduce(0) { $0 + $1.gpsTrack.count }
    }
    
    // MARK: - Methods
    
    private func loadSettings() {
        selectedAircraft = appState.settings.selectedAircraft
        gpsInterval = appState.settings.gpsRecordingInterval
        keepScreenOn = appState.settings.keepScreenOn
        stepByStepHighlighting = appState.settings.stepByStepHighlighting
        learningMode = appState.settings.learningMode
        forceICAOChartLayer = appState.settings.forceICAOChartLayer
    }

    private func saveSettings() {
        appState.settings.selectedAircraft = selectedAircraft
        appState.settings.gpsRecordingInterval = gpsInterval
        appState.settings.keepScreenOn = keepScreenOn
        appState.settings.stepByStepHighlighting = stepByStepHighlighting
        appState.settings.learningMode = learningMode
        appState.settings.forceICAOChartLayer = forceICAOChartLayer
        appState.saveSettings()

        // Apply screen setting
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environmentObject(AppState())
        .environmentObject(LocationManager())
}
