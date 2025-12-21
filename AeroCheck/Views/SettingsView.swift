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
    @State private var showEstimatedAirspeed: Bool = false
    @State private var showDownloadModal: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var showEstimatedAirspeedWarning: Bool = false
    @State private var pendingEstimatedAirspeedValue: Bool = false
    @State private var marketingMode: Bool = false
    @State private var showDeveloperOptions: Bool = false
    @State private var versionTapCount: Int = 0
    
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

                // Experimental: Estimated Airspeed section
                Section {
                    Toggle("Show Estimated Airspeed", isOn: Binding(
                        get: { showEstimatedAirspeed },
                        set: { newValue in
                            if newValue {
                                // Show warning before enabling
                                pendingEstimatedAirspeedValue = true
                                showEstimatedAirspeedWarning = true
                            } else {
                                showEstimatedAirspeed = false
                            }
                        }
                    ))
                } header: {
                    HStack {
                        Label("Experimental", systemImage: "exclamationmark.triangle.fill")
                        Text("BETA")
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
                        Text("When enabled, displays an estimated indicated airspeed (IAS) calculated from GPS ground speed and wind data from MeteoSwiss.")
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.aviationAmber)
                            Text("This feature only works in Switzerland and requires a constant cellular connection.")
                                .foregroundColor(.aviationAmber)
                        }
                        .font(.caption)
                    }
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
                    Toggle("Offline Mode", isOn: $offlineMode)
                        .onChange(of: offlineMode) { _, newValue in
                            if newValue && !offlineMapManager.isCacheAvailable {
                                // Show download modal when enabling offline mode without cache
                                showDownloadModal = true
                            }
                        }

                    if offlineMapManager.isCacheAvailable || offlineMapManager.isSegelflugCacheAvailable {
                        // ICAO Cache status
                        if offlineMapManager.isCacheAvailable {
                            HStack {
                                Text("ICAO Chart")
                                Spacer()
                                Text(offlineMapManager.cacheVersion)
                                    .foregroundColor(.secondary)
                            }
                        }

                        // Segelflug Cache status
                        if offlineMapManager.isSegelflugCacheAvailable {
                            HStack {
                                Text("Segelflugkarte")
                                Spacer()
                                Text(offlineMapManager.segelflugCacheVersion)
                                    .foregroundColor(.secondary)
                            }
                        }

                        HStack {
                            Text("Total Cache Size")
                            Spacer()
                            Text(offlineMapManager.formattedCacheSize)
                                .foregroundColor(.secondary)
                        }

                        Button(action: { showDownloadModal = true }) {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("Update/Add Charts")
                            }
                        }

                        Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                            HStack {
                                Image(systemName: "trash")
                                Text("Delete All Cached Charts")
                            }
                        }
                    } else {
                        Button(action: { showDownloadModal = true }) {
                            HStack {
                                Image(systemName: "arrow.down.circle")
                                Text("Download Charts")
                            }
                        }
                    }
                } header: {
                    Label("Offline Maps", systemImage: "arrow.down.circle")
                } footer: {
                    if offlineMode {
                        if offlineMapManager.isSegelflugCacheAvailable {
                            Text("Offline mode active. Both ICAO Chart and Segelflugkarte are available from cache.")
                        } else {
                            Text("Offline mode active. Only ICAO Chart is cached. Download Segelflugkarte for seamless zooming in offline mode.")
                        }
                    } else if offlineMapManager.isCacheAvailable {
                        Text("Charts cached for faster loading. Updated yearly by swisstopo in April.")
                    } else {
                        Text("Download charts for offline navigation. ICAO Chart is required; Segelflugkarte is optional for detailed zooming.")
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
                    // Version row with hidden tap gesture to reveal developer options
                    HStack {
                        Text("App Version")
                            .foregroundColor(.primary)
                        Spacer()
                        HStack(spacing: 4) {
                            Text(appVersion)
                            if !showDeveloperOptions {
                                Link(destination: URL(string: "https://github.com/fetzu/AeroCheck/releases")!) {
                                    Image(systemName: "arrow.up.forward.square")
                                        .font(.caption)
                                }
                            }
                        }
                        .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        versionTapCount += 1
                        if versionTapCount >= 5 {
                            withAnimation {
                                showDeveloperOptions = true
                            }
                        }
                    }

                    Link(destination: URL(string: "https://www.julienbono.ch/")!) {
                        HStack {
                            Text("Author")
                                .foregroundColor(.primary)
                            Spacer()
                            HStack(spacing: 4) {
                                Text("Julien 'fetzu' Bono")
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.caption)
                            }
                            .foregroundColor(.secondary)
                        }
                    }

                    Link(destination: URL(string: "https://www.gvmp.aero/")!) {
                        HStack {
                            Text("Organization")
                                .foregroundColor(.primary)
                            Spacer()
                            HStack(spacing: 4) {
                                Text("Aéroclub du Jura (GVMP)")
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.caption)
                            }
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
                            Text("This app is open source and available on GitHub. ")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            + Text(Image(systemName: "arrow.up.forward.square"))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .baselineOffset(4)
                        }

                        Link(destination: URL(string: "https://raw.githubusercontent.com/fetzu/AeroCheck/refs/heads/main/LICENSE")!) {
                            Text("Released under the MIT License. ")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            + Text(Image(systemName: "arrow.up.forward.square"))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .baselineOffset(4)
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

                // Developer Options section (hidden until revealed)
                if showDeveloperOptions {
                    Section {
                        Toggle("Marketing Mode", isOn: $marketingMode)
                    } header: {
                        HStack {
                            Label("Developer Options", systemImage: "hammer.fill")
                            Text("DEV")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.purple)
                                )
                        }
                    } footer: {
                        Text("Marketing Mode: When enabled, shake your device to show the marketing location controls overlay. This allows you to simulate GPS positions for taking screenshots.")
                    }
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
            .onChange(of: showEstimatedAirspeed) { _, _ in saveSettings() }
            .onChange(of: marketingMode) { _, newValue in
                // Only update in-memory setting, don't persist to disk
                appState.settings.marketingMode = newValue
            }
            .sheet(isPresented: $showDownloadModal) {
                OfflineMapDownloadSheet(offlineMode: $offlineMode)
                    .environmentObject(offlineMapManager)
            }
            .sheet(isPresented: $showEstimatedAirspeedWarning) {
                EstimatedAirspeedWarningSheet(
                    isPresented: $showEstimatedAirspeedWarning,
                    showEstimatedAirspeed: $showEstimatedAirspeed
                )
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

    /// App version from Info.plist (single source of truth via Xcode project settings)
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

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
        showEstimatedAirspeed = appState.settings.showEstimatedAirspeed
        // Marketing mode is NOT loaded from settings - it always starts as false
        // Developer options are hidden by default and require 5 taps to reveal each session
        marketingMode = false
        showDeveloperOptions = false
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
        appState.settings.showEstimatedAirspeed = showEstimatedAirspeed
        // Note: marketingMode is handled separately and NOT persisted
        appState.saveSettings()

        // Apply screen setting
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn
    }
}

// MARK: - Estimated Airspeed Warning Sheet

struct EstimatedAirspeedWarningSheet: View {
    @Binding var isPresented: Bool
    @Binding var showEstimatedAirspeed: Bool

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Warning icon
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.aviationAmber)
                    .padding(.top, 40)

                // Title
                Text("Experimental Feature")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.primaryText)

                // Warning message
                VStack(alignment: .leading, spacing: 16) {
                    WarningItem(
                        icon: "airplane",
                        text: "The estimated indicated airspeed (IAS) shown is calculated from GPS ground speed and wind data from MeteoSwiss weather stations."
                    )

                    WarningItem(
                        icon: "exclamationmark.circle.fill",
                        text: "This estimation can be highly inaccurate due to local wind variations, altitude differences, and station distance."
                    )

                    WarningItem(
                        icon: "gauge.with.needle",
                        text: "Always rely on your aircraft's onboard airspeed indicator for actual IAS readings."
                    )

                    WarningItem(
                        icon: "network",
                        text: "This feature requires a constant cellular connection and only works within Switzerland."
                    )
                }
                .padding(.horizontal, 24)

                Spacer()

                // Buttons
                VStack(spacing: 12) {
                    Button(action: {
                        showEstimatedAirspeed = true
                        isPresented = false
                    }) {
                        Text("I Understand - Enable Feature")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.aviationAmber)
                            )
                    }
                    .padding(.horizontal, 24)

                    Button(action: {
                        isPresented = false
                    }) {
                        Text("Cancel")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.secondaryText)
                    }
                }
                .padding(.bottom, 40)
            }
            .background(Color.cockpitBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct WarningItem: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.aviationAmber)
                .frame(width: 24)

            Text(text)
                .font(.system(size: 15))
                .foregroundColor(.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Offline Map Download Sheet

struct OfflineMapDownloadSheet: View {
    @EnvironmentObject var offlineMapManager: OfflineMapManager
    @Environment(\.dismiss) var dismiss
    @Binding var offlineMode: Bool
    @State private var selectedCacheOption: CacheOption = .icaoOnly

    /// Storage estimate for each option
    private func storageEstimate(for option: CacheOption) -> String {
        switch option {
        case .icaoOnly: return "~100 MB"
        case .icaoAndSegelflug: return "~250 MB"
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Header icon
                Image(systemName: "map.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.aviationGold)
                    .padding(.top, 24)

                // Title
                Text("Download Charts")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.primaryText)

                // Description
                Text("Download Swiss aeronautical charts for offline navigation and faster loading.")
                    .font(.system(size: 14))
                    .foregroundColor(.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                // Cache option picker (only show when not downloading and no complete cache)
                if !offlineMapManager.isDownloading {
                    VStack(spacing: 12) {
                        Text("Select Charts to Download")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondaryText)

                        ForEach(CacheOption.allCases) { option in
                            CacheOptionRow(
                                option: option,
                                storageEstimate: storageEstimate(for: option),
                                isSelected: selectedCacheOption == option,
                                isAlreadyCached: isCached(option)
                            ) {
                                selectedCacheOption = option
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }

                Spacer()

                // Download progress or status
                if offlineMapManager.isDownloading {
                    VStack(spacing: 12) {
                        ProgressView(value: offlineMapManager.downloadProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .aviationGold))
                            .padding(.horizontal, 40)

                        if let layer = offlineMapManager.currentDownloadingLayer {
                            Text("Downloading \(layer.displayName)...")
                                .font(.system(size: 14))
                                .foregroundColor(.secondaryText)
                        } else {
                            Text("Downloading tiles...")
                                .font(.system(size: 14))
                                .foregroundColor(.secondaryText)
                        }

                        Text("\(offlineMapManager.downloadedTileCount) / \(offlineMapManager.totalTileCount)")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.secondaryText)

                        // Estimated time remaining
                        if let eta = offlineMapManager.estimatedTimeRemaining, eta > 0 {
                            Text("Estimated time remaining: \(formattedTimeRemaining(eta))")
                                .font(.system(size: 13))
                                .foregroundColor(.dimText)
                        }
                    }
                } else if let error = offlineMapManager.downloadError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.aviationRed)

                        Text(error)
                            .font(.system(size: 13))
                            .foregroundColor(.aviationRed)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }

                // Current cache status
                if !offlineMapManager.isDownloading && (offlineMapManager.isCacheAvailable || offlineMapManager.isSegelflugCacheAvailable) {
                    VStack(spacing: 8) {
                        HStack(spacing: 16) {
                            if offlineMapManager.isCacheAvailable {
                                CacheStatusBadge(name: "ICAO", isAvailable: true)
                            }
                            if offlineMapManager.isSegelflugCacheAvailable {
                                CacheStatusBadge(name: "Segelflug", isAvailable: true)
                            }
                        }
                        Text("Total: \(offlineMapManager.formattedCacheSize)")
                            .font(.system(size: 12))
                            .foregroundColor(.dimText)
                    }
                }

                Spacer()

                // Action buttons
                VStack(spacing: 12) {
                    if offlineMapManager.isDownloading {
                        // No action button while downloading
                    } else {
                        Button(action: startDownload) {
                            Text(downloadButtonText)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.aviationGold)
                                )
                        }
                        .padding(.horizontal, 24)

                        if offlineMapManager.isCacheAvailable || offlineMapManager.isSegelflugCacheAvailable {
                            Button(action: { dismiss() }) {
                                Text("Done")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.secondaryText)
                            }
                        }
                    }
                }
                .padding(.bottom, 24)
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
        .onAppear {
            // Default to ICAO + Segelflug if ICAO is already cached but Segelflug isn't
            if offlineMapManager.isCacheAvailable && !offlineMapManager.isSegelflugCacheAvailable {
                selectedCacheOption = .icaoAndSegelflug
            }
        }
    }

    private var downloadButtonText: String {
        if offlineMapManager.isCacheAvailable && offlineMapManager.isSegelflugCacheAvailable {
            return "Re-download Charts"
        } else if offlineMapManager.isCacheAvailable && selectedCacheOption == .icaoAndSegelflug {
            return "Download Segelflugkarte"
        } else {
            return "Download \(selectedCacheOption.displayName)"
        }
    }

    private func isCached(_ option: CacheOption) -> Bool {
        switch option {
        case .icaoOnly:
            return offlineMapManager.isCacheAvailable
        case .icaoAndSegelflug:
            return offlineMapManager.isCacheAvailable && offlineMapManager.isSegelflugCacheAvailable
        }
    }

    private func startDownload() {
        Task {
            await offlineMapManager.downloadCharts(option: selectedCacheOption)
        }
    }

    /// Format time interval as human-readable string (e.g., "2m 30s" or "45s")
    private func formattedTimeRemaining(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60

        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
}

// MARK: - Cache Option Row

struct CacheOptionRow: View {
    let option: CacheOption
    let storageEstimate: String
    let isSelected: Bool
    let isAlreadyCached: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(option.displayName)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.primaryText)
                        if isAlreadyCached {
                            Text("CACHED")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.aviationGreen)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.aviationGreen.opacity(0.2))
                                )
                        }
                    }
                    Text(storageEstimate)
                        .font(.system(size: 12))
                        .foregroundColor(.dimText)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(isSelected ? .aviationGold : .dimText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.aviationGold.opacity(0.1) : Color.panelBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? Color.aviationGold : Color.clear, lineWidth: 1)
                    )
            )
        }
    }
}

// MARK: - Cache Status Badge

struct CacheStatusBadge: View {
    let name: String
    let isAvailable: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                .font(.system(size: 12))
            Text(name)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(isAvailable ? .aviationGreen : .dimText)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isAvailable ? Color.aviationGreen.opacity(0.15) : Color.panelBackground)
        )
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environmentObject(AppState())
        .environmentObject(LocationManager())
        .environmentObject(OfflineMapManager())
}
