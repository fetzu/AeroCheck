import SwiftUI

/// Settings sub-page for navigation, offline maps, and airport data
struct NavigationMapsSettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var offlineMapManager: OfflineMapManager
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var openAIPCacheManager: OpenAIPCacheManager
    @EnvironmentObject var openAIPDataService: OpenAIPDataService

    @State private var forceICAOChartLayer: Bool = false
    @State private var offlineMode: Bool = false
    @State private var showAirportsOnMap: Bool = false
    @State private var showOpenAIPOverlay: Bool = false
    @State private var showDownloadModal: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var showOpenAIPDownloadSheet: Bool = false
    @State private var showOpenAIPDeleteConfirmation: Bool = false
    @State private var isLoadingSettings: Bool = false

    var body: some View {
        Form {
            navigationSection
            offlineMapsSection
            openAIPSection
            airportDataSection
        }
        .navigationTitle(L10n.Settings.navigationAndMaps)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadSettings() }
        .onChange(of: appState.settings) { _, _ in loadSettings() }
        .onChange(of: forceICAOChartLayer) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: offlineMode) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: showAirportsOnMap) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: showOpenAIPOverlay) { _, _ in if !isLoadingSettings { saveSettings() } }
        .sheet(isPresented: $showDownloadModal) {
            OfflineMapDownloadSheet(offlineMode: $offlineMode)
                .environmentObject(offlineMapManager)
        }
        .sheet(isPresented: $showOpenAIPDownloadSheet) {
            OpenAIPDownloadSheet()
                .environmentObject(openAIPCacheManager)
                .environmentObject(openAIPDataService)
                .environmentObject(appState)
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
        .alert(L10n.Settings.deleteOpenAIPTitle, isPresented: $showOpenAIPDeleteConfirmation) {
            Button(L10n.Button.cancel, role: .cancel) { }
            Button(L10n.Button.delete, role: .destructive) {
                openAIPCacheManager.deleteCache()
                openAIPDataService.deleteData()
            }
        } message: {
            Text(L10n.Settings.deleteOpenAIPMessage)
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

    // MARK: - OpenAIP Section

    private var openAIPSection: some View {
        Section {
            Toggle(L10n.Settings.airspaceOverlay, isOn: $showOpenAIPOverlay)

            if openAIPDataService.isDownloading {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text(L10n.Settings.downloadingAirspaceData)
                            .font(.body)
                    }
                    ProgressView(value: openAIPDataService.downloadProgress)
                        .tint(.aviationGold)
                }
            } else if openAIPDataService.isDataAvailable {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.Settings.airspacesLoaded(openAIPDataService.airspaceCount))
                            .font(.body)
                        if !openAIPDataService.downloadedCountries.isEmpty {
                            Text(openAIPDataService.downloadedCountries
                                .map { OpenAIPConfig.countryName(for: $0) }
                                .joined(separator: ", "))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if let lastUpdate = openAIPDataService.lastUpdated {
                            Text(L10n.Settings.updatedDate(formatAirportDate(lastUpdate)))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if openAIPDataService.needsUpdate {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.aviationAmber)
                    }
                }
            }

            if openAIPCacheManager.isCacheAvailable {
                HStack {
                    Text(L10n.Settings.tileCache)
                    Spacer()
                    Text(openAIPCacheManager.formattedCacheSize)
                        .foregroundColor(.secondary)
                }
            }

            Button(action: { showOpenAIPDownloadSheet = true }) {
                HStack {
                    Image(systemName: openAIPDataService.isDataAvailable ? "arrow.triangle.2.circlepath" : "arrow.down.circle")
                    Text(openAIPDataService.isDataAvailable ? L10n.Settings.updateData : L10n.Settings.downloadData)
                }
            }

            if openAIPDataService.isDataAvailable || openAIPCacheManager.isCacheAvailable {
                Button(role: .destructive, action: { showOpenAIPDeleteConfirmation = true }) {
                    HStack {
                        Image(systemName: "trash")
                        Text(L10n.Settings.deleteOpenAIPData)
                    }
                }
            }

            if let error = openAIPDataService.downloadError ?? openAIPCacheManager.downloadError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.aviationRed)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.aviationRed)
                }
            }
        } header: {
            Label(L10n.Settings.openAIPAirspace, systemImage: "shield")
        } footer: {
            Text(L10n.Settings.openAIPFooter)
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
        showOpenAIPOverlay = appState.settings.showOpenAIPOverlay
        DispatchQueue.main.async {
            self.isLoadingSettings = false
        }
    }

    private func saveSettings() {
        appState.settings.forceICAOChartLayer = forceICAOChartLayer
        appState.settings.offlineMode = offlineMode
        appState.settings.showAirportsOnMap = showAirportsOnMap
        appState.settings.showOpenAIPOverlay = showOpenAIPOverlay
        appState.saveSettings()
    }
}

// MARK: - OpenAIP Download Sheet

/// Sheet for selecting countries and downloading OpenAIP data (tiles + airspace)
struct OpenAIPDownloadSheet: View {
    @EnvironmentObject var openAIPCacheManager: OpenAIPCacheManager
    @EnvironmentObject var openAIPDataService: OpenAIPDataService
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    /// All available countries for download, sorted by name
    private let availableCountries: [(code: String, name: String)] = {
        OpenAIPConfig.countryBounds.keys.sorted().map { code in
            (code: code, name: OpenAIPConfig.countryName(for: code))
        }.sorted { $0.name < $1.name }
    }()

    @State private var selectedCountries: Set<String> = []
    @State private var isDownloading = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Country selection list
                List {
                    Section {
                        ForEach(availableCountries, id: \.code) { country in
                            Button(action: { toggleCountry(country.code) }) {
                                HStack {
                                    Text(country.name)
                                        .foregroundColor(.primaryText)
                                    Spacer()
                                    if selectedCountries.contains(country.code) {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.aviationGold)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(L10n.Settings.selectCountries)
                    } footer: {
                        if !selectedCountries.isEmpty {
                            let countries = Array(selectedCountries)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.Settings.estimatedTileCache(openAIPCacheManager.estimatedDownloadSize(for: countries)))
                                Text(L10n.Settings.tileCountLabel(openAIPCacheManager.tileCount(for: countries)))
                            }
                        }
                    }
                }

                // Download progress
                if openAIPCacheManager.isDownloading || openAIPDataService.isDownloading {
                    VStack(spacing: 12) {
                        if openAIPCacheManager.isDownloading {
                            VStack(spacing: 4) {
                                Text(L10n.Settings.downloadingTiles)
                                    .font(.system(size: 14, weight: .medium))
                                ProgressView(value: openAIPCacheManager.downloadProgress)
                                    .tint(.aviationGold)
                                Text("\(openAIPCacheManager.downloadedTileCount) / \(openAIPCacheManager.totalTileCount)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.secondaryText)
                            }
                        }
                        if openAIPDataService.isDownloading {
                            VStack(spacing: 4) {
                                Text(L10n.Settings.downloadingAirspaceData)
                                    .font(.system(size: 14, weight: .medium))
                                ProgressView(value: openAIPDataService.downloadProgress)
                                    .tint(.aviationGold)
                            }
                        }
                    }
                    .padding()
                    .background(Color.panelBackground)
                }

                // Download button
                if !openAIPCacheManager.isDownloading && !openAIPDataService.isDownloading {
                    Button(action: startDownload) {
                        Text(L10n.Settings.download)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(selectedCountries.isEmpty ? Color.gray : Color.aviationGold)
                            )
                    }
                    .disabled(selectedCountries.isEmpty)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
            .background(Color.cockpitBackground)
            .navigationTitle(L10n.Settings.openAIPDataTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.done) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Pre-select previously downloaded countries
            selectedCountries = Set(appState.settings.openAIPOfflineCountries)
            if selectedCountries.isEmpty {
                // Default to Switzerland
                selectedCountries = ["CH"]
            }
        }
    }

    private func toggleCountry(_ code: String) {
        if selectedCountries.contains(code) {
            selectedCountries.remove(code)
        } else {
            selectedCountries.insert(code)
        }
    }

    private func startDownload() {
        let countries = Array(selectedCountries).sorted()

        // Save country selection
        appState.settings.openAIPOfflineCountries = countries
        appState.saveSettings()

        // Download tiles and airspace data in parallel
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await openAIPCacheManager.downloadTiles(for: countries)
                }
                group.addTask {
                    await openAIPDataService.downloadData(for: countries)
                }
                await group.waitForAll()
            }
        }
    }
}
