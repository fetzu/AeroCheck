import SwiftUI

/// Settings sub-page for iCloud sync, GPS configuration, and data statistics
struct SyncDataSettingsView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject var locationManager: LocationManager
    @ObservedObject private var syncManager = SyncManager.shared

    @State private var iCloudSyncEnabled: Bool = true
    @State private var gpsInterval: Double = 5.0
    @State private var gpsPriority: GPSPriority = .precision
    @State private var isLoadingSettings: Bool = false

    private let tint: Color = .altimeterBlue

    var body: some View {
        SettingsPage {
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
        SettingsGroup(title: L10n.Settings.icloud, tint: tint, footer: iCloudFooterText) {
            SettingsToggleRow(icon: "icloud", title: L10n.Settings.syncToICloud,
                              tint: tint, isOn: $iCloudSyncEnabled)

            if iCloudSyncEnabled {
                if let lastSync = syncManager.lastSyncDate {
                    SettingsValueRow(icon: "clock.arrow.circlepath", title: L10n.Settings.lastSync,
                                     tint: tint, value: formatSyncDate(lastSync))
                }

                syncNowRow
            }
        }
    }

    /// "Sync now" action housed in a custom row to preserve the rotating refresh animation.
    private var syncNowRow: some View {
        Button(action: {
            Task { await syncManager.syncNow() }
        }) {
            HStack(spacing: 10) {
                SettingsRowLabel(
                    icon: "arrow.triangle.2.circlepath",
                    title: syncManager.isSyncing ? L10n.Settings.syncing : L10n.Settings.syncNow,
                    tint: tint
                )
                Image(systemName: "arrow.triangle.2.circlepath")
                    .scaledFont(size: 13, weight: .semibold, relativeTo: .caption)
                    .foregroundColor(tint)
                    .rotationEffect(.degrees(syncManager.isSyncing ? 360 : 0))
                    .animation(
                        syncManager.isSyncing
                            ? Animation.linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: syncManager.isSyncing
                    )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(syncManager.isSyncing)
    }

    private var iCloudFooterText: String {
        iCloudSyncEnabled
            ? "\(L10n.Settings.icloudFooter)\n\(L10n.Settings.flightLogsFooter)"
            : L10n.Settings.icloudFooter
    }

    private func formatSyncDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - GPS Section

    private var gpsSection: some View {
        SettingsGroup(title: L10n.Settings.gps, tint: tint, footer: gpsFooterText) {
            gpsIntervalRow

            SettingsMenuRow(icon: "speedometer", title: L10n.Settings.gpsPriority,
                            tint: tint, selection: $gpsPriority) {
                Text(L10n.Settings.gpsPrecision).tag(GPSPriority.precision)
                Text(L10n.Settings.gpsBatterySaver).tag(GPSPriority.batterySaver)
            }

            SettingsValueRow(icon: "location.fill", title: L10n.GPS.status,
                             tint: tint, value: gpsStatusText, valueColor: gpsStatusColor)

            if locationManager.authorizationStatus == .notDetermined {
                SettingsButtonRow(icon: "lock.shield", title: L10n.GPS.requestPermission,
                                  tint: tint, showsChevron: false) {
                    locationManager.requestAuthorization()
                }
            }
        }
    }

    /// GPS recording interval housed in a custom row to preserve the slider control.
    private var gpsIntervalRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                SettingsRowLabel(icon: "timer", title: L10n.Settings.gpsInterval, tint: tint)
                Text(L10n.Settings.seconds(Int(gpsInterval)))
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
            }
            Slider(value: $gpsInterval, in: 1...30, step: 1)
                .tint(.aviationGold)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var gpsFooterText: String {
        "\(L10n.Settings.gpsFooter)\n\(L10n.Settings.gpsPriorityFooter)"
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
        SettingsGroup(title: L10n.Settings.data, tint: tint) {
            SettingsValueRow(icon: "airplane", title: L10n.Settings.recordedFlights,
                             tint: tint, value: "\(appState.flights.count)")

            SettingsValueRow(icon: "point.topleft.down.curvedto.point.bottomright.up",
                             title: L10n.Settings.totalGPSPoints,
                             tint: tint, value: "\(totalGPSPoints)")
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
