import SwiftUI

/// Settings sub-page for iCloud sync, GPS configuration, and data statistics
struct SyncDataSettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var locationManager: LocationManager
    @ObservedObject private var syncManager = SyncManager.shared

    @State private var iCloudSyncEnabled: Bool = true
    @State private var gpsInterval: Double = 5.0
    @State private var gpsPriority: GPSPriority = .precision
    @State private var isLoadingSettings: Bool = false

    var body: some View {
        Form {
            iCloudSyncSection
            gpsSection
            dataSection
        }
        .navigationTitle(L10n.Settings.syncAndData)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSettings() }
        .onChange(of: appState.settings) { _, _ in loadSettings() }
        .onChange(of: iCloudSyncEnabled) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: gpsInterval) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: gpsPriority) { _, newValue in
            if !isLoadingSettings {
                saveSettings()
                locationManager.applyGPSPriority(newValue)
            }
        }
    }

    // MARK: - iCloud Sync Section

    private var iCloudSyncSection: some View {
        Section {
            Toggle(L10n.Settings.syncToICloud, isOn: $iCloudSyncEnabled)

            if iCloudSyncEnabled {
                if let lastSync = syncManager.lastSyncDate {
                    HStack {
                        Text(L10n.Settings.lastSync)
                        Spacer()
                        Text(formatSyncDate(lastSync))
                            .foregroundColor(.secondary)
                    }
                }

                Button(action: {
                    Task { await syncManager.syncNow() }
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
                        Text(syncManager.isSyncing ? L10n.Settings.syncing : L10n.Settings.syncNow)
                    }
                }
                .disabled(syncManager.isSyncing)
            }
        } header: {
            Label(L10n.Settings.icloud, systemImage: "icloud")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.Settings.icloudFooter)
                if iCloudSyncEnabled {
                    Text(L10n.Settings.flightLogsFooter)
                }
            }
        }
    }

    private func formatSyncDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - GPS Section

    private var gpsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L10n.Settings.gpsInterval)
                    Spacer()
                    Text(L10n.Settings.seconds(Int(gpsInterval)))
                        .foregroundColor(.secondary)
                }

                Slider(value: $gpsInterval, in: 1...30, step: 1)
                    .tint(.aviationGold)
            }

            Picker(L10n.Settings.gpsPriority, selection: $gpsPriority) {
                Text(L10n.Settings.gpsPrecision).tag(GPSPriority.precision)
                Text(L10n.Settings.gpsBatterySaver).tag(GPSPriority.batterySaver)
            }

            HStack {
                Text(L10n.GPS.status)
                Spacer()
                Text(gpsStatusText)
                    .foregroundColor(gpsStatusColor)
            }

            if locationManager.authorizationStatus == .notDetermined {
                Button(L10n.GPS.requestPermission) {
                    locationManager.requestAuthorization()
                }
            }
        } header: {
            Label(L10n.Settings.gps, systemImage: "location.fill")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.Settings.gpsFooter)
                Text(L10n.Settings.gpsPriorityFooter)
            }
        }
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

    // MARK: - Data Section

    private var dataSection: some View {
        Section {
            HStack {
                Text(L10n.Settings.recordedFlights)
                Spacer()
                Text("\(appState.flights.count)")
                    .foregroundColor(.secondary)
            }

            HStack {
                Text(L10n.Settings.totalGPSPoints)
                Spacer()
                Text("\(totalGPSPoints)")
                    .foregroundColor(.secondary)
            }
        } header: {
            Label(L10n.Settings.data, systemImage: "externaldrive.fill")
        }
    }

    private var totalGPSPoints: Int {
        appState.flights.reduce(0) { $0 + $1.gpsTrack.count }
    }

    // MARK: - Settings Persistence

    private func loadSettings() {
        isLoadingSettings = true
        iCloudSyncEnabled = appState.settings.iCloudSyncEnabled
        gpsInterval = appState.settings.gpsRecordingInterval
        gpsPriority = appState.settings.gpsPriority
        DispatchQueue.main.async {
            self.isLoadingSettings = false
        }
    }

    private func saveSettings() {
        appState.settings.iCloudSyncEnabled = iCloudSyncEnabled
        appState.settings.gpsRecordingInterval = gpsInterval
        appState.settings.gpsPriority = gpsPriority
        appState.saveSettings()
    }
}
