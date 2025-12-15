import SwiftUI

/// Settings view for configuring the app
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var offlineMapManager: OfflineMapManager
    @Environment(\.dismiss) var dismiss

    @State private var selectedAircraft: AircraftType = .wt9Dynamic
    @State private var gpsInterval: Double = 5.0
    @State private var keepScreenOn: Bool = true
    @State private var stepByStepHighlighting: Bool = true
    @State private var learningMode: Bool = false
    @State private var forceICAOChartLayer: Bool = false
    @State private var offlineMode: Bool = false
    @State private var alwaysUseUTC: Bool = false
    @State private var showDownloadModal: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    
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
                    Toggle("Always Use UTC Times", isOn: $alwaysUseUTC)
                } header: {
                    Label("Display", systemImage: "sun.max.fill")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Keep Screen On: Prevents the screen from dimming during flight.")
                        Text("Always Use UTC Times: When enabled, all times in the app are displayed in UTC with a (UTC) suffix.")
                    }
                }

                // Navigation section
                Section {
                    Toggle("Force ICAO Chart Layer", isOn: $forceICAOChartLayer)
                        .disabled(offlineMode)
                } header: {
                    Label("Navigation", systemImage: "map")
                } footer: {
                    Text("When ON, the ICAO Chart (1:500,000) remains at all zoom levels. When OFF, seamlessly switches to Segelflugkarte (1:300,000) when zooming in.")
                }

                // Offline Maps section
                Section {
                    Toggle("Offline Mode (ICAO Chart)", isOn: $offlineMode)
                        .onChange(of: offlineMode) { _, newValue in
                            if newValue && !offlineMapManager.isCacheAvailable {
                                // Show download modal when enabling offline mode without cache
                                showDownloadModal = true
                            }
                        }

                    if offlineMapManager.isCacheAvailable {
                        HStack {
                            Text("Cache Version (ICAO Chart)")
                            Spacer()
                            Text(offlineMapManager.cacheVersion)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("Downloaded")
                            Spacer()
                            Text(offlineMapManager.formattedCacheDate)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            Text("Cache Size")
                            Spacer()
                            Text(offlineMapManager.formattedCacheSize)
                                .foregroundColor(.secondary)
                        }

                        Button(action: { showDownloadModal = true }) {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("Update Cache")
                            }
                        }

                        Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                            HStack {
                                Image(systemName: "trash")
                                Text("Delete Cache")
                            }
                        }
                    } else {
                        Button(action: { showDownloadModal = true }) {
                            HStack {
                                Image(systemName: "arrow.down.circle")
                                Text("Download ICAO Chart")
                            }
                        }
                    }
                } header: {
                    Label("Offline Maps (ICAO Chart)", systemImage: "arrow.down.circle")
                } footer: {
                    if offlineMode {
                        Text("Offline mode restricts the map to the cached ICAO Chart only. Layer switching is disabled.")
                    } else if offlineMapManager.isCacheAvailable {
                        Text("ICAO Chart cached for offline use. The chart is updated yearly by SwissTopo in April.")
                    } else {
                        Text("Download the ICAO Chart for offline navigation. Requires approximately 50-100 MB of storage.")
                    }
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                loadSettings()
            }
            // Auto-save settings when they change (Apple HIG compliant)
            .onChange(of: selectedAircraft) { _, _ in saveSettings() }
            .onChange(of: gpsInterval) { _, _ in saveSettings() }
            .onChange(of: keepScreenOn) { _, _ in saveSettings() }
            .onChange(of: stepByStepHighlighting) { _, _ in saveSettings() }
            .onChange(of: learningMode) { _, _ in saveSettings() }
            .onChange(of: forceICAOChartLayer) { _, _ in saveSettings() }
            .onChange(of: offlineMode) { _, _ in saveSettings() }
            .onChange(of: alwaysUseUTC) { _, _ in saveSettings() }
            .sheet(isPresented: $showDownloadModal) {
                OfflineMapDownloadSheet(offlineMode: $offlineMode)
                    .environmentObject(offlineMapManager)
            }
            .alert("Delete Cache?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    offlineMapManager.deleteCache()
                    offlineMode = false
                }
            } message: {
                Text("This will delete the cached ICAO chart. You will need to download it again for offline use.")
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
        offlineMode = appState.settings.offlineMode
        alwaysUseUTC = appState.settings.alwaysUseUTC
    }

    private func saveSettings() {
        appState.settings.selectedAircraft = selectedAircraft
        appState.settings.gpsRecordingInterval = gpsInterval
        appState.settings.keepScreenOn = keepScreenOn
        appState.settings.stepByStepHighlighting = stepByStepHighlighting
        appState.settings.learningMode = learningMode
        appState.settings.forceICAOChartLayer = forceICAOChartLayer
        appState.settings.offlineMode = offlineMode
        appState.settings.alwaysUseUTC = alwaysUseUTC
        appState.saveSettings()

        // Apply screen setting
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn
    }
}

// MARK: - Offline Map Download Sheet

struct OfflineMapDownloadSheet: View {
    @EnvironmentObject var offlineMapManager: OfflineMapManager
    @Environment(\.dismiss) var dismiss
    @Binding var offlineMode: Bool

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Header icon
                Image(systemName: "map.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.aviationGold)
                    .padding(.top, 40)

                // Title
                Text("ICAO Chart Download")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.primaryText)

                // Description
                Text("Download the Swiss ICAO Aeronautical Chart for offline navigation. This allows you to use the chart without an internet connection.")
                    .font(.system(size: 16))
                    .foregroundColor(.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()

                // Download progress or status
                if offlineMapManager.isDownloading {
                    VStack(spacing: 16) {
                        ProgressView(value: offlineMapManager.downloadProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .aviationGold))
                            .padding(.horizontal, 40)

                        Text("Downloading tiles...")
                            .font(.system(size: 14))
                            .foregroundColor(.secondaryText)

                        Text("\(offlineMapManager.downloadedTileCount) / \(offlineMapManager.totalTileCount)")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.secondaryText)
                    }
                } else if let error = offlineMapManager.downloadError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.aviationRed)

                        Text(error)
                            .font(.system(size: 14))
                            .foregroundColor(.aviationRed)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                } else if offlineMapManager.isCacheAvailable {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.aviationGreen)

                        Text("ICAO Chart cached successfully!")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.aviationGreen)

                        Text("Size: \(offlineMapManager.formattedCacheSize)")
                            .font(.system(size: 14))
                            .foregroundColor(.secondaryText)
                    }
                } else {
                    VStack(spacing: 12) {
                        Text("Requirements")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondaryText)

                        HStack(spacing: 20) {
                            VStack {
                                Image(systemName: "wifi")
                                    .font(.system(size: 24))
                                Text("Wi-Fi")
                                    .font(.system(size: 12))
                            }
                            .foregroundColor(.secondaryText)

                            VStack {
                                Image(systemName: "internaldrive")
                                    .font(.system(size: 24))
                                Text("~100 MB")
                                    .font(.system(size: 12))
                            }
                            .foregroundColor(.secondaryText)
                        }
                    }
                }

                Spacer()

                // Action buttons
                VStack(spacing: 12) {
                    if offlineMapManager.isDownloading {
                        // No action button while downloading
                    } else if offlineMapManager.isCacheAvailable {
                        Button(action: { dismiss() }) {
                            Text("Done")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.aviationGold)
                                )
                        }
                        .padding(.horizontal, 24)
                    } else {
                        Button(action: startDownload) {
                            Text("Download ICAO Chart")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.aviationGold)
                                )
                        }
                        .padding(.horizontal, 24)
                    }
                }
                .padding(.bottom, 40)
            }
            .background(Color.cockpitBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !offlineMapManager.isDownloading {
                        Button("Cancel") {
                            if !offlineMapManager.isCacheAvailable {
                                offlineMode = false
                            }
                            dismiss()
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(offlineMapManager.isDownloading)
    }

    private func startDownload() {
        Task {
            await offlineMapManager.downloadICAOChart()
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environmentObject(AppState())
        .environmentObject(LocationManager())
        .environmentObject(OfflineMapManager())
}
