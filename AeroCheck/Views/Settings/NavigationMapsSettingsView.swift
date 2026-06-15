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
    @State private var showTrackVector: Bool = false
    @State private var showOpenAIPOverlay: Bool = false
    @State private var enableAirspaceStreaming: Bool = false
    @State private var showAirspaceStreamingWarning: Bool = false
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
        .onChange(of: showTrackVector) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: showOpenAIPOverlay) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: enableAirspaceStreaming) { _, _ in if !isLoadingSettings { saveSettings() } }
        .sheet(isPresented: $showAirspaceStreamingWarning) {
            AirspaceStreamingWarningSheet(
                isPresented: $showAirspaceStreamingWarning,
                enableAirspaceStreaming: $enableAirspaceStreaming
            )
        }
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
            Toggle(L10n.Nav.trackVector, isOn: $showTrackVector)
            Text(L10n.Nav.trackVectorDesc)
                .font(.caption)
                .foregroundColor(.secondaryText)
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

            Toggle(L10n.Settings.airspaceStreaming, isOn: Binding(
                get: { enableAirspaceStreaming },
                set: { newValue in
                    if newValue {
                        showAirspaceStreamingWarning = true
                    } else {
                        enableAirspaceStreaming = false
                    }
                }
            ))

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
                            .accessibilityLabel(L10n.Settings.airportUpdateAvailable)
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
                            .accessibilityLabel(L10n.Settings.airportUpdateAvailable)
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
        showTrackVector = appState.settings.showTrackVector
        showOpenAIPOverlay = appState.settings.showOpenAIPOverlay
        enableAirspaceStreaming = appState.settings.enableAirspaceStreaming
        DispatchQueue.main.async {
            self.isLoadingSettings = false
        }
    }

    private func saveSettings() {
        appState.settings.forceICAOChartLayer = forceICAOChartLayer
        appState.settings.offlineMode = offlineMode
        appState.settings.showAirportsOnMap = showAirportsOnMap
        appState.settings.showTrackVector = showTrackVector
        appState.settings.showOpenAIPOverlay = showOpenAIPOverlay
        appState.settings.enableAirspaceStreaming = enableAirspaceStreaming
        appState.saveSettings()
    }
}

// MARK: - OpenAIP Download Sheet

/// Sheet for selecting countries by continent and downloading OpenAIP data (tiles + airspace)
struct OpenAIPDownloadSheet: View {
    @EnvironmentObject var openAIPCacheManager: OpenAIPCacheManager
    @EnvironmentObject var openAIPDataService: OpenAIPDataService
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    @State private var selectedCountries: Set<String> = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    // Summary of current selection
                    if !selectedCountries.isEmpty {
                        Section {
                            let countries = Array(selectedCountries)
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L10n.Settings.openAIPCountriesSelected(selectedCountries.count))
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(.primaryText)
                                    Text(L10n.Settings.estimatedTileCache(openAIPCacheManager.estimatedDownloadSize(for: countries)))
                                        .font(.system(size: 13))
                                        .foregroundColor(.secondaryText)
                                }
                                Spacer()
                                Button(action: { selectedCountries.removeAll() }) {
                                    Text(L10n.Settings.openAIPClearSelection)
                                        .font(.system(size: 13))
                                        .foregroundColor(.aviationAmber)
                                }
                            }
                        }
                    }

                    // Continent rows with navigation
                    Section {
                        ForEach(OpenAIPConfig.continents) { continent in
                            NavigationLink {
                                ContinentCountryListView(
                                    continent: continent,
                                    selectedCountries: $selectedCountries
                                )
                            } label: {
                                continentRow(continent)
                            }
                        }
                    } header: {
                        Text(L10n.Settings.selectCountries)
                    }
                }
                .listStyle(.insetGrouped)

                // Download progress
                if openAIPCacheManager.isDownloading || openAIPDataService.isDownloading {
                    downloadProgressView
                }

                // Download buttons
                if !openAIPCacheManager.isDownloading && !openAIPDataService.isDownloading {
                    VStack(spacing: 8) {
                        Button(action: { startDownload(tilesAndData: true) }) {
                            HStack {
                                Image(systemName: "square.and.arrow.down.on.square")
                                    .font(.system(size: 14))
                                Text(L10n.Settings.downloadAll)
                            }
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

                        Button(action: { startDownload(tilesAndData: false) }) {
                            HStack {
                                Image(systemName: "shield.checkered")
                                    .font(.system(size: 14))
                                Text(L10n.Settings.downloadAirspaceOnly)
                            }
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.aviationGold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .disabled(selectedCountries.isEmpty)
                    }
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
            selectedCountries = Set(appState.settings.openAIPOfflineCountries)
            if selectedCountries.isEmpty {
                selectedCountries = ["CH"]
            }
        }
    }

    // MARK: - Continent Row

    private func continentRow(_ continent: OpenAIPConfig.Continent) -> some View {
        let selectedInContinent = continent.countries.filter { selectedCountries.contains($0) }.count
        return HStack {
            Image(systemName: continent.icon)
                .foregroundColor(.aviationGold)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(continent.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primaryText)
                Text(L10n.Settings.openAIPContinentCountryCount(continent.countries.count))
                    .font(.system(size: 12))
                    .foregroundColor(.secondaryText)
            }
            Spacer()
            if selectedInContinent > 0 {
                Text("\(selectedInContinent)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.aviationGold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.aviationGold.opacity(0.15))
                    )
            }
        }
    }

    // MARK: - Download Progress

    private var downloadProgressView: some View {
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

    // MARK: - Actions

    private func startDownload(tilesAndData: Bool) {
        let countries = Array(selectedCountries).sorted()
        appState.settings.openAIPOfflineCountries = countries
        appState.saveSettings()

        Task {
            if tilesAndData {
                // Download both tiles and airspace data in parallel
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await openAIPCacheManager.downloadTiles(for: countries)
                    }
                    group.addTask {
                        await openAIPDataService.downloadData(for: countries)
                    }
                    await group.waitForAll()
                }
            } else {
                // Download airspace data only (much faster, ~100 KB)
                await openAIPDataService.downloadData(for: countries)
            }
        }
    }
}

// MARK: - Continent Country List View

/// Sub-screen listing all countries within a continent, with select-all toggle
struct ContinentCountryListView: View {
    let continent: OpenAIPConfig.Continent
    @Binding var selectedCountries: Set<String>
    @EnvironmentObject var openAIPCacheManager: OpenAIPCacheManager

    /// Countries sorted by localized display name
    private var sortedCountries: [(code: String, name: String)] {
        continent.countries.map { code in
            (code: code, name: OpenAIPConfig.countryName(for: code))
        }.sorted { $0.name < $1.name }
    }

    /// Whether all countries in this continent are selected
    private var allSelected: Bool {
        continent.countries.allSatisfy { selectedCountries.contains($0) }
    }

    /// Whether some (but not all) countries in this continent are selected
    private var someSelected: Bool {
        continent.countries.contains { selectedCountries.contains($0) } && !allSelected
    }

    var body: some View {
        List {
            // Select All / Deselect All row
            Section {
                Button(action: toggleAll) {
                    HStack {
                        Image(systemName: allSelected ? "checkmark.circle.fill" : (someSelected ? "minus.circle.fill" : "circle"))
                            .foregroundColor(allSelected || someSelected ? .aviationGold : .secondaryText)
                            .font(.system(size: 20))
                        Text(allSelected ? L10n.Settings.openAIPDeselectAll : L10n.Settings.openAIPSelectAll(continent.name))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.primaryText)
                        Spacer()
                    }
                }
            } footer: {
                let continentCountries = continent.countries
                let selected = continentCountries.filter { selectedCountries.contains($0) }
                if !selected.isEmpty {
                    Text(L10n.Settings.estimatedTileCache(
                        openAIPCacheManager.estimatedDownloadSize(for: selected)
                    ))
                }
            }

            // Individual country rows
            Section {
                ForEach(sortedCountries, id: \.code) { country in
                    Button(action: { toggleCountry(country.code) }) {
                        HStack {
                            Text(flagEmoji(for: country.code))
                                .font(.system(size: 22))
                            Text(country.name)
                                .font(.system(size: 15))
                                .foregroundColor(.primaryText)
                            Spacer()
                            if selectedCountries.contains(country.code) {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.aviationGold)
                                    .font(.system(size: 14, weight: .semibold))
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .background(Color.cockpitBackground)
        .navigationTitle(continent.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggleCountry(_ code: String) {
        if selectedCountries.contains(code) {
            selectedCountries.remove(code)
        } else {
            selectedCountries.insert(code)
        }
    }

    private func toggleAll() {
        if allSelected {
            // Deselect all in this continent
            for code in continent.countries {
                selectedCountries.remove(code)
            }
        } else {
            // Select all in this continent
            for code in continent.countries {
                selectedCountries.insert(code)
            }
        }
    }

    /// Convert ISO country code to flag emoji
    private func flagEmoji(for countryCode: String) -> String {
        let base: UInt32 = 127397
        return countryCode.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(base + $0.value).map(String.init)
        }.joined()
    }
}
