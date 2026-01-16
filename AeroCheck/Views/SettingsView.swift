import SwiftUI

/// Settings view for configuring the app
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var offlineMapManager: OfflineMapManager
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var aircraftDataService: AircraftDataService
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var syncManager = SyncManager.shared

    @State private var showSubscriptionView = false
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

    // Flight Planning settings
    @State private var enableFlightPlanning: Bool = false
    @State private var waypointProximityThreshold: Double = 500
    @State private var terrainAltitudeUnit: TerrainAltitudeUnit = .feet
    @State private var showFlightPlanningWarning: Bool = false

    // Circuit mode
    @State private var enableCircuitMode: Bool = false

    // iCloud Sync
    @State private var iCloudSyncEnabled: Bool = true

    @State private var isLoadingSettings: Bool = false

    var body: some View {
        NavigationView {
            settingsForm
        }
        .preferredColorScheme(.dark)
    }

    private var settingsForm: some View {
        formContent
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear { loadSettings() }
            .onChange(of: appState.settings) { _, _ in
                loadSettings()
            }
            .modifier(SettingsChangeModifier(
                selectedAircraft: selectedAircraft,
                gpsInterval: gpsInterval,
                keepScreenOn: keepScreenOn,
                stepByStepHighlighting: stepByStepHighlighting,
                learningMode: learningMode,
                forceICAOChartLayer: forceICAOChartLayer,
                offlineMode: offlineMode,
                alwaysUseUTC: alwaysUseUTC,
                showEstimatedAirspeed: showEstimatedAirspeed,
                enableFlightPlanning: enableFlightPlanning,
                waypointProximityThreshold: waypointProximityThreshold,
                terrainAltitudeUnit: terrainAltitudeUnit,
                enableCircuitMode: enableCircuitMode,
                iCloudSyncEnabled: iCloudSyncEnabled,
                marketingMode: marketingMode,
                saveSettings: { if !isLoadingSettings { saveSettings() } },
                updateMarketingMode: { appState.settings.marketingMode = $0 }
            ))
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
            .sheet(isPresented: $showFlightPlanningWarning) {
                FlightPlanningWarningSheet(
                    isPresented: $showFlightPlanningWarning,
                    enableFlightPlanning: $enableFlightPlanning
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

    private var formContent: some View {
        Form {
            Group {
                subscriptionSection
                aircraftSection
                gpsSection
                experimentalAirspeedSection
            }
            Group {
                flightPlanningSection
                displaySection
                navigationSection
            }
            Group {
                iCloudSyncSection
                offlineMapsSection
                checklistSection
            }
            Group {
                checklistCacheSection
                aboutSection
                availableChecklistsSection
                dataSection
                developerOptionsSection
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
        }
    }

    // MARK: - Form Sections

    private var subscriptionSection: some View {
        Section {
            Button(action: { showSubscriptionView = true }) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AeroCheck Pro")
                            .font(.headline)
                            .foregroundColor(.primary)

                        Text(subscriptionManager.subscriptionStatus.displayText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if subscriptionManager.subscriptionStatus.isSubscribed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.aviationGreen)
                    } else {
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .sheet(isPresented: $showSubscriptionView) {
                SubscriptionView()
                    .environmentObject(subscriptionManager)
            }

            if subscriptionManager.subscriptionStatus.isSubscribed {
                Button(action: syncSubscription) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Sync with Server")
                    }
                }
            }
        } header: {
            Label("Subscription", systemImage: "star.fill")
        } footer: {
            if subscriptionManager.subscriptionStatus.isSubscribed {
                Text("You have access to all premium aircraft checklists. Tap 'Sync with Server' if premium aircraft still appear locked.")
            } else {
                Text("Subscribe to unlock additional aircraft checklists.")
            }
        }
    }

    private func syncSubscription() {
        Task {
            await subscriptionManager.syncWithServer()
            // Refresh aircraft list to get updated hasAccess values
            await aircraftDataService.fetchAvailableAircraft()
        }
    }

    private var aircraftSection: some View {
        Section {
            // Show bundled aircraft
            ForEach(AircraftType.allCases) { aircraft in
                Button(action: {
                    selectedAircraft = aircraft
                    appState.settings.selectedRemoteAircraftId = nil
                    saveSettings()
                }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(aircraft.registration)
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)

                            Text(aircraft.shortModelName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if selectedAircraft == aircraft && appState.settings.selectedRemoteAircraftId == nil {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.aviationGold)
                        }
                    }
                }
            }

            // Show remote aircraft
            if aircraftDataService.isLoading {
                HStack {
                    ProgressView()
                    Text("Loading aircraft...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach(aircraftDataService.availableAircraft) { remoteAircraft in
                    Button(action: {
                        if remoteAircraft.hasAccess {
                            appState.settings.selectedRemoteAircraftId = remoteAircraft.id
                            saveSettings()
                        } else {
                            showSubscriptionView = true
                        }
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(remoteAircraft.registration)
                                        .font(.system(.body, design: .monospaced))
                                        .fontWeight(.semibold)
                                        .foregroundColor(.primary)

                                    if !remoteAircraft.isFree {
                                        Image(systemName: "star.fill")
                                            .font(.caption)
                                            .foregroundColor(.aviationGold)
                                    }
                                }

                                Text(remoteAircraft.shortModelName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if !remoteAircraft.hasAccess {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(.secondary)
                            } else if appState.settings.selectedRemoteAircraftId == remoteAircraft.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.aviationGold)
                            }
                        }
                    }
                    .disabled(!remoteAircraft.hasAccess && !remoteAircraft.isFree)
                    .opacity(remoteAircraft.hasAccess ? 1.0 : 0.6)
                }
            }
        } header: {
            Label("Aircraft", systemImage: "airplane")
        } footer: {
            if aircraftDataService.availableAircraft.contains(where: { !$0.hasAccess }) {
                Text("Select the aircraft you will be flying. Premium aircraft (marked with ⭐) require an AeroCheck Pro subscription.")
            } else {
                Text("Select the aircraft you will be flying. This determines the checklist and speeds used.")
            }
        }
    }

    private var gpsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                let intervalText = "\(Int(gpsInterval)) seconds"
                HStack {
                    Text("Recording Interval")
                    Spacer()
                    Text(intervalText)
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
    }

    private var experimentalAirspeedSection: some View {
        Section {
            Toggle("Show Estimated Airspeed", isOn: Binding(
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
    }

    private var flightPlanningSection: some View {
        Section {
            Toggle("Enable Flight Planning", isOn: Binding(
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
                        Text("Waypoint Proximity")
                        Spacer()
                        Text("\(Int(waypointProximityThreshold)) m")
                            .foregroundColor(.secondary)
                    }

                    Slider(value: $waypointProximityThreshold, in: 100...2000, step: 100)
                        .tint(.aviationGold)
                }

                Picker("Terrain Altitude Unit", selection: $terrainAltitudeUnit) {
                    ForEach(TerrainAltitudeUnit.allCases) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .pickerStyle(.menu)
            }
        } header: {
            HStack {
                Label("Flight Planning", systemImage: "map.fill")
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
                Text("Plan flight routes with waypoints, time/distance calculations, and terrain visualization.")
                if enableFlightPlanning {
                    Text("Waypoint Proximity: Distance at which waypoints auto-advance during flight.")
                    Text("Terrain Altitude Unit: Unit for displaying terrain profile elevation.")
                }
            }
        }
    }

    private var displaySection: some View {
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
    }

    private var navigationSection: some View {
        Section {
            Toggle("Force ICAO Chart Layer", isOn: $forceICAOChartLayer)
                .disabled(offlineMode)
        } header: {
            Label("Navigation", systemImage: "map")
        } footer: {
            Text("When ON, the ICAO Chart (1:500,000) remains at all zoom levels. When OFF, seamlessly switches to Segelflugkarte (1:300,000) when zooming in.")
        }
    }

    private var iCloudSyncSection: some View {
        Section {
            Toggle("Sync to iCloud", isOn: $iCloudSyncEnabled)

            if iCloudSyncEnabled {
                if let lastSync = syncManager.lastSyncDate {
                    HStack {
                        Text("Last Sync")
                        Spacer()
                        Text(formatSyncDate(lastSync))
                            .foregroundColor(.secondary)
                    }
                }

                Button(action: {
                    Task {
                        await syncManager.syncNow()
                    }
                }) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .rotationEffect(.degrees(syncManager.isSyncing ? 360 : 0))
                            .animation(
                                syncManager.isSyncing
                                    ? Animation.linear(duration: 1).repeatForever(autoreverses: false)
                                    : .default,
                                value: syncManager.isSyncing
                            )
                        Text(syncManager.isSyncing ? "Syncing..." : "Sync Now")
                    }
                }
                .disabled(syncManager.isSyncing)
            }
        } header: {
            Label("iCloud Sync", systemImage: "icloud")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("When enabled, your settings and flight logs are synced across all your devices signed into the same iCloud account.")
                if iCloudSyncEnabled {
                    Text("Your flight logs are stored in the AéroCheck folder in Files and can be accessed from any device.")
                }
            }
        }
    }

    /// Format sync date as DD.MM.YYYY HH:MM
    private func formatSyncDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter.string(from: date)
    }

    private var offlineMapsSection: some View {
        Section {
            Toggle("Offline Mode", isOn: $offlineMode)
                .onChange(of: offlineMode) { _, newValue in
                    if newValue && !offlineMapManager.isCacheAvailable {
                        showDownloadModal = true
                    }
                }

            if offlineMapManager.isCacheAvailable || offlineMapManager.isSegelflugCacheAvailable {
                if offlineMapManager.isCacheAvailable {
                    HStack {
                        Text("ICAO Chart")
                        Spacer()
                        Text(offlineMapManager.cacheVersion)
                            .foregroundColor(.secondary)
                    }
                }

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
            offlineMapsFooter
        }
    }

    @ViewBuilder
    private var offlineMapsFooter: some View {
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

    private var checklistSection: some View {
        Section {
            Toggle("Step-by-Step Highlighting", isOn: $stepByStepHighlighting)

            Toggle("Learning Mode (show all checks)", isOn: $learningMode)

            Toggle("Enable Circuit Mode", isOn: $enableCircuitMode)
        } header: {
            Label("Checklist", systemImage: "checklist")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Step-by-Step: Highlights items one at a time. Tap anywhere to advance.")
                Text("Learning Mode: When OFF, memorizable checks are hidden to test your memory. When ON, all checks are shown for studying.")
                Text("Circuit Mode: When ON, shows a START CIRCUITS button on the home screen. Circuit flights skip CRUISE and DESCENT checklists.")
            }
        }
    }

    private var checklistCacheSection: some View {
        Section {
            // List cached aircraft
            let cachedAircraft = aircraftDataService.availableAircraft.filter { aircraft in
                aircraftDataService.isChecklistCached(aircraftId: aircraft.id)
            }

            if cachedAircraft.isEmpty {
                Text("No cached checklists")
                    .foregroundColor(.secondaryText)
            } else {
                ForEach(cachedAircraft) { aircraft in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(aircraft.registration)
                                    .font(.system(.body, design: .monospaced))
                                    .fontWeight(.semibold)
                                if !aircraft.isFree {
                                    Image(systemName: "star.fill")
                                        .font(.caption)
                                        .foregroundColor(.aviationGold)
                                }
                            }

                            if let cacheDate = aircraftDataService.getCacheDate(aircraftId: aircraft.id) {
                                let isValid = aircraftDataService.isCacheValid(aircraftId: aircraft.id)
                                HStack(spacing: 4) {
                                    Text(isValid ? "Valid until" : "Expired")
                                        .font(.caption)
                                        .foregroundColor(isValid ? .green : .orange)
                                    Text(cacheDate.addingTimeInterval(24 * 60 * 60).formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundColor(.secondaryText)
                                }
                            }
                        }

                        Spacer()

                        Button(action: {
                            aircraftDataService.clearCache(for: aircraft.id)
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Clear all button if there are multiple cached aircraft
                if cachedAircraft.count > 1 {
                    Button(role: .destructive, action: {
                        aircraftDataService.clearAllCaches()
                    }) {
                        HStack {
                            Image(systemName: "trash.fill")
                            Text("Clear All Cached Checklists")
                        }
                    }
                }
            }
        } header: {
            Label("Checklist Cache", systemImage: "externaldrive")
        } footer: {
            Text("Downloaded checklists are cached for offline use. Cache expires after 24 hours but will still be used if the server is unavailable.")
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text("App Version")
                    .foregroundColor(.primary)
                Spacer()
                HStack(spacing: 4) {
                    Text(appVersion)
                    if !showDeveloperOptions {
                        Link(destination: URL(string: "https://aerocheck.app/changelog")!) {
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

            Link(destination: URL(string: "https://aerocheck.app/")!) {
                HStack {
                    Text("Website")
                        .foregroundColor(.primary)
                    Spacer()
                    HStack(spacing: 4) {
                        Text("AeroCheck.app")
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Image(systemName: "arrow.up.forward.square")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
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
    }

    private var availableChecklistsSection: some View {
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
        }
    }

    private var dataSection: some View {
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

    @ViewBuilder
    private var developerOptionsSection: some View {
        if showDeveloperOptions {
            Section {
                Toggle("Marketing Mode", isOn: $marketingMode)

                Toggle("Force 'Not Subscribed' State", isOn: $subscriptionManager.debugForceNotSubscribed)
                    .onChange(of: subscriptionManager.debugForceNotSubscribed) { _, _ in
                        Task {
                            await subscriptionManager.updateSubscriptionStatus()
                        }
                    }

                Button(role: .destructive, action: resetSubscription) {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset Subscription State")
                    }
                }
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("Marketing Mode: When enabled, shake your device to show the marketing location controls overlay. This allows you to simulate GPS positions for taking screenshots.")
                    Text("Force 'Not Subscribed': Ignores actual subscription status and pretends you're not subscribed. Useful for testing the free experience even with an active subscription.")
                    Text("Reset Subscription: Clears cached subscription state and re-checks with StoreKit.")
                }
            }
        }
    }

    private func resetSubscription() {
        Task {
            await subscriptionManager.resetSubscriptionState()
        }
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
        isLoadingSettings = true
        selectedAircraft = appState.settings.selectedAircraft
        gpsInterval = appState.settings.gpsRecordingInterval
        keepScreenOn = appState.settings.keepScreenOn
        stepByStepHighlighting = appState.settings.stepByStepHighlighting
        learningMode = appState.settings.learningMode
        forceICAOChartLayer = appState.settings.forceICAOChartLayer
        offlineMode = appState.settings.offlineMode
        alwaysUseUTC = appState.settings.alwaysUseUTC
        showEstimatedAirspeed = appState.settings.showEstimatedAirspeed
        // Flight Planning settings
        enableFlightPlanning = appState.settings.enableFlightPlanning
        waypointProximityThreshold = appState.settings.waypointProximityThreshold
        terrainAltitudeUnit = appState.settings.terrainAltitudeUnit
        // Circuit mode
        enableCircuitMode = appState.settings.enableCircuitMode
        // iCloud Sync
        iCloudSyncEnabled = appState.settings.iCloudSyncEnabled
        
        // Reset loading flag in next runloop to avoid triggering save loops
        DispatchQueue.main.async {
            self.isLoadingSettings = false
        }
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
        // Flight Planning settings
        appState.settings.enableFlightPlanning = enableFlightPlanning
        appState.settings.waypointProximityThreshold = waypointProximityThreshold
        appState.settings.terrainAltitudeUnit = terrainAltitudeUnit
        // Circuit mode
        appState.settings.enableCircuitMode = enableCircuitMode
        // iCloud Sync
        appState.settings.iCloudSyncEnabled = iCloudSyncEnabled
        // Note: marketingMode is handled separately and NOT persisted
        appState.saveSettings()

        // Apply screen setting
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn
    }
}

// MARK: - Flight Planning Warning Sheet

struct FlightPlanningWarningSheet: View {
    @Binding var isPresented: Bool
    @Binding var enableFlightPlanning: Bool

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Warning icon
                Image(systemName: "map.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.aviationAmber)
                    .padding(.top, 40)

                // Title
                Text("Beta Feature")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.primaryText)

                // Warning message
                VStack(alignment: .leading, spacing: 16) {
                    WarningItem(
                        icon: "exclamationmark.triangle.fill",
                        text: "Flight Planning is a beta feature. It is provided for planning purposes only and should not replace proper flight preparation."
                    )

                    WarningItem(
                        icon: "map",
                        text: "Plan routes with waypoints, calculate times and distances, and visualize terrain along your route."
                    )

                    WarningItem(
                        icon: "location.fill",
                        text: "During flight, the app can automatically advance waypoints based on your GPS position."
                    )

                    WarningItem(
                        icon: "mountain.2.fill",
                        text: "Terrain visualization is only available within Switzerland using swisstopo data."
                    )
                }
                .padding(.horizontal, 24)

                Spacer()

                // Buttons
                VStack(spacing: 12) {
                    Button(action: {
                        enableFlightPlanning = true
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

// MARK: - Settings Change Modifier

struct SettingsChangeModifier: ViewModifier {
    let selectedAircraft: AircraftType
    let gpsInterval: Double
    let keepScreenOn: Bool
    let stepByStepHighlighting: Bool
    let learningMode: Bool
    let forceICAOChartLayer: Bool
    let offlineMode: Bool
    let alwaysUseUTC: Bool
    let showEstimatedAirspeed: Bool
    let enableFlightPlanning: Bool
    let waypointProximityThreshold: Double
    let terrainAltitudeUnit: TerrainAltitudeUnit
    let enableCircuitMode: Bool
    let iCloudSyncEnabled: Bool
    let marketingMode: Bool
    let saveSettings: () -> Void
    let updateMarketingMode: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: selectedAircraft) { _, _ in saveSettings() }
            .onChange(of: gpsInterval) { _, _ in saveSettings() }
            .onChange(of: keepScreenOn) { _, _ in saveSettings() }
            .onChange(of: stepByStepHighlighting) { _, _ in saveSettings() }
            .onChange(of: learningMode) { _, _ in saveSettings() }
            .onChange(of: forceICAOChartLayer) { _, _ in saveSettings() }
            .onChange(of: offlineMode) { _, _ in saveSettings() }
            .onChange(of: alwaysUseUTC) { _, _ in saveSettings() }
            .onChange(of: showEstimatedAirspeed) { _, _ in saveSettings() }
            .onChange(of: enableFlightPlanning) { _, _ in saveSettings() }
            .onChange(of: waypointProximityThreshold) { _, _ in saveSettings() }
            .onChange(of: terrainAltitudeUnit) { _, _ in saveSettings() }
            .onChange(of: enableCircuitMode) { _, _ in saveSettings() }
            .onChange(of: iCloudSyncEnabled) { _, _ in saveSettings() }
            .onChange(of: marketingMode) { _, newValue in updateMarketingMode(newValue) }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environmentObject(AppState())
        .environmentObject(LocationManager())
        .environmentObject(OfflineMapManager())
}
