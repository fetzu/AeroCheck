import SwiftUI

/// Settings sub-page for navigation, offline maps, and airport data
struct NavigationMapsSettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var offlineMapManager: OfflineMapManager
    @EnvironmentObject var airportDataService: AirportDataService

    @State private var forceICAOChartLayer: Bool = false
    @State private var offlineMode: Bool = false
    @State private var showAirportsOnMap: Bool = false
    @State private var showDownloadModal: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var isLoadingSettings: Bool = false

    var body: some View {
        Form {
            navigationSection
            offlineMapsSection
            airportDataSection
        }
        .navigationTitle(L10n.Settings.navigationAndMaps)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSettings() }
        .onChange(of: appState.settings) { _, _ in loadSettings() }
        .onChange(of: forceICAOChartLayer) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: offlineMode) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: showAirportsOnMap) { _, _ in if !isLoadingSettings { saveSettings() } }
        .sheet(isPresented: $showDownloadModal) {
            OfflineMapDownloadSheet(offlineMode: $offlineMode)
                .environmentObject(offlineMapManager)
        }
        .alert(L10n.Settings.deleteCacheTitle, isPresented: $showDeleteConfirmation) {
            Button(L10n.Button.cancel, role: .cancel) { }
            Button(L10n.Button.delete, role: .destructive) {
                offlineMapManager.deleteCache()
                offlineMode = false
            }
        } message: {
            Text(L10n.Settings.deleteCacheMessage)
        }
    }

    // MARK: - Navigation Section

    private var navigationSection: some View {
        Section {
            Toggle(L10n.Settings.forceICAO, isOn: $forceICAOChartLayer)
                .disabled(offlineMode)
        } header: {
            Label(L10n.Settings.navigation, systemImage: "map")
        } footer: {
            Text(L10n.Settings.forceICAOFooter)
        }
    }

    // MARK: - Offline Maps Section

    private var offlineMapsSection: some View {
        Section {
            Toggle(L10n.Settings.offlineMode, isOn: $offlineMode)
                .onChange(of: offlineMode) { _, newValue in
                    if newValue && !offlineMapManager.isCacheAvailable {
                        showDownloadModal = true
                    }
                }

            if offlineMapManager.isCacheAvailable || offlineMapManager.isSegelflugCacheAvailable {
                if offlineMapManager.isCacheAvailable {
                    HStack {
                        Text(L10n.Settings.icaoChart)
                        Spacer()
                        Text(offlineMapManager.cacheVersion)
                            .foregroundColor(.secondary)
                    }
                }

                if offlineMapManager.isSegelflugCacheAvailable {
                    HStack {
                        Text(L10n.Settings.segelflugkarte)
                        Spacer()
                        Text(offlineMapManager.segelflugCacheVersion)
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    Text(L10n.Settings.totalCacheSize)
                    Spacer()
                    Text(offlineMapManager.formattedCacheSize)
                        .foregroundColor(.secondary)
                }

                Button(action: { showDownloadModal = true }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text(L10n.Settings.updateCharts)
                    }
                }

                Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                    HStack {
                        Image(systemName: "trash")
                        Text(L10n.Settings.deleteCache)
                    }
                }
            } else {
                Button(action: { showDownloadModal = true }) {
                    HStack {
                        Image(systemName: "arrow.down.circle")
                        Text(L10n.Settings.downloadCharts)
                    }
                }
            }
        } header: {
            Label(L10n.Settings.offlineMaps, systemImage: "arrow.down.circle")
        } footer: {
            offlineMapsFooter
        }
    }

    @ViewBuilder
    private var offlineMapsFooter: some View {
        if offlineMode {
            if offlineMapManager.isSegelflugCacheAvailable {
                Text(L10n.Settings.offlineActive)
            } else {
                Text(L10n.Settings.onlyICAO)
            }
        } else if offlineMapManager.isCacheAvailable {
            Text(L10n.Settings.chartsCached)
        } else {
            Text(L10n.Settings.downloadDesc)
        }
    }

    // MARK: - Airport Data Section

    private var airportDataSection: some View {
        Section {
            if airportDataService.isDownloading {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text(L10n.Settings.downloadingAirports)
                            .font(.body)
                    }
                    ProgressView(value: airportDataService.downloadProgress)
                        .tint(.aviationGold)
                }
            } else if airportDataService.isDataAvailable {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.Settings.airportsLoaded(airportDataService.airportCount))
                            .font(.body)
                        if let lastUpdate = airportDataService.lastUpdated {
                            Text(L10n.Settings.lastUpdatedDate(formatAirportDate(lastUpdate)))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if airportDataService.needsUpdate {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.aviationAmber)
                            .help(L10n.Settings.airportUpdateAvailable)
                    }
                }

                Toggle(L10n.Settings.showAirportsOnMap, isOn: $showAirportsOnMap)

                Button(action: {
                    Task { await airportDataService.downloadData() }
                }) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(L10n.Settings.updateAirportData)
                    }
                }

                Button(role: .destructive, action: {
                    airportDataService.deleteData()
                }) {
                    HStack {
                        Image(systemName: "trash")
                        Text(L10n.Settings.deleteAirportData)
                    }
                }
            } else {
                Button(action: {
                    Task { await airportDataService.downloadData() }
                }) {
                    HStack {
                        Image(systemName: "arrow.down.circle")
                        Text(L10n.Settings.downloadAirportData)
                    }
                }
            }

            if let error = airportDataService.downloadError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.aviationRed)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.aviationRed)
                }
            }
        } header: {
            Label(L10n.Settings.airportData, systemImage: "building.2")
        } footer: {
            Text(L10n.Settings.airportDataFooter)
        }
    }

    private func formatAirportDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    // MARK: - Settings Persistence

    private func loadSettings() {
        isLoadingSettings = true
        forceICAOChartLayer = appState.settings.forceICAOChartLayer
        offlineMode = appState.settings.offlineMode
        showAirportsOnMap = appState.settings.showAirportsOnMap
        DispatchQueue.main.async {
            self.isLoadingSettings = false
        }
    }

    private func saveSettings() {
        appState.settings.forceICAOChartLayer = forceICAOChartLayer
        appState.settings.offlineMode = offlineMode
        appState.settings.showAirportsOnMap = showAirportsOnMap
        appState.saveSettings()
    }
}
