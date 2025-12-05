import SwiftUI

/// Settings view for configuring the app
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var locationManager: LocationManager
    @Environment(\.dismiss) var dismiss
    
    @State private var airplane: String = ""
    @State private var gpsInterval: Double = 5.0
    @State private var keepScreenOn: Bool = true
    @State private var stepByStepHighlighting: Bool = true
    @State private var learningMode: Bool = false
    
    var body: some View {
        NavigationView {
            Form {
                // Aircraft section
                Section {
                    HStack {
                        Text("Default Aircraft")
                        Spacer()
                        TextField("Registration", text: $airplane)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)
                            .multilineTextAlignment(.center)
                            .textCase(.uppercase)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Label("Aircraft", systemImage: "airplane")
                } footer: {
                    Text("This will be used for new flights")
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
                    HStack {
                        Text("App Version")
                        Spacer()
                        Text("1.0.0 (beta)")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Author")
                        Spacer()
                        Text("Julien 'fetzu' Bono")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Aircraft Type")
                        Spacer()
                        Text("WT9 Dynamic")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Checklist Version")
                        Spacer()
                        Text("2.1e")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Organization")
                        Spacer()
                        Text("Aéroclub du Jura GVMP")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Last Updated")
                        Spacer()
                        Text("March 2025")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Label("About", systemImage: "info.circle.fill")
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
        airplane = appState.settings.defaultAirplane
        gpsInterval = appState.settings.gpsRecordingInterval
        keepScreenOn = appState.settings.keepScreenOn
        stepByStepHighlighting = appState.settings.stepByStepHighlighting
        learningMode = appState.settings.learningMode
    }
    
    private func saveSettings() {
        appState.settings.defaultAirplane = airplane.isEmpty ? "F-HVXA" : airplane.uppercased()
        appState.settings.gpsRecordingInterval = gpsInterval
        appState.settings.keepScreenOn = keepScreenOn
        appState.settings.stepByStepHighlighting = stepByStepHighlighting
        appState.settings.learningMode = learningMode
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
