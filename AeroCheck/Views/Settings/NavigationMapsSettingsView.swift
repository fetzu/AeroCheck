import SwiftUI

/// Settings sub-page for navigation, offline maps, and airport data
struct NavigationMapsSettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var offlineMapManager: OfflineMapManager
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var openAIPCacheManager: OpenAIPCacheManager
    @EnvironmentObject var openAIPDataService: OpenAIPDataService
    @EnvironmentObject var openAIPNavaidDataService: OpenAIPNavaidDataService

    @State private var forceICAOChartLayer: Bool = false
    @State private var offlineMode: Bool = false
    @State private var showAirportsOnMap: Bool = false
    @State private var showNavaidsOnMap: Bool = false
    @State private var showObstaclesOnMap: Bool = false
    @State private var showReportingPointsOnMap: Bool = false
    @State private var showTrackVector: Bool = false
    @State private var showOpenAIPOverlay: Bool = false
    @State private var enableAirspaceStreaming: Bool = false
    @State private var showAirspaceStreamingWarning: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var showOpenAIPDeleteConfirmation: Bool = false
    @State private var isLoadingSettings: Bool = false

    /// The two offline-data downloads are pushed into the settings detail column as pages (v4 UI/UX),
    /// not popped as sheets. One destination drives both the row taps and the Offline-Mode toggle.
    private enum DataDownloadRoute: Hashable { case offlineCharts, openAIP }
    @State private var dataRoute: DataDownloadRoute?

    private let tint: Color = .aviationGreen

    var body: some View {
        SettingsPage {
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
        .onChange(of: showNavaidsOnMap) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: showObstaclesOnMap) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: showReportingPointsOnMap) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: showTrackVector) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: showOpenAIPOverlay) { _, _ in if !isLoadingSettings { saveSettings() } }
        .onChange(of: enableAirspaceStreaming) { _, _ in if !isLoadingSettings { saveSettings() } }
        .sheet(isPresented: $showAirspaceStreamingWarning) {
            AirspaceStreamingWarningSheet(
                isPresented: $showAirspaceStreamingWarning,
                enableAirspaceStreaming: $enableAirspaceStreaming
            )
        }
        .navigationDestination(item: $dataRoute) { route in
            switch route {
            case .offlineCharts:
                OfflineMapDownloadSheet(offlineMode: $offlineMode, asPage: true)
                    .environmentObject(offlineMapManager)
            case .openAIP:
                OpenAIPDownloadSheet(asPage: true)
                    .environmentObject(openAIPCacheManager)
                    .environmentObject(openAIPDataService)
                    .environmentObject(openAIPNavaidDataService)
                    .environmentObject(appState)
            }
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
        SettingsGroup(title: L10n.Settings.navigation, tint: tint, footer: L10n.Settings.forceICAOFooter) {
            SettingsToggleRow(icon: "map", title: L10n.Settings.forceICAO, tint: tint, isOn: $forceICAOChartLayer)
                .disabled(offlineMode)
            SettingsToggleRow(icon: "location.north.line", title: L10n.Nav.trackVector,
                              subtitle: L10n.Nav.trackVectorDesc, tint: tint, isOn: $showTrackVector)
        }
    }

    // MARK: - Offline Maps Section

    @ViewBuilder
    private var offlineMapsSection: some View {
        SettingsGroup(title: L10n.Settings.offlineMaps, tint: tint, footer: offlineMapsFooter) {
            SettingsToggleRow(icon: "arrow.down.circle", title: L10n.Settings.offlineMode, tint: tint, isOn: $offlineMode)
                .onChange(of: offlineMode) { _, newValue in
                    if newValue && !offlineMapManager.isCacheAvailable {
                        dataRoute = .offlineCharts
                    }
                }

            if offlineMapManager.isCacheAvailable || offlineMapManager.isSegelflugCacheAvailable {
                if offlineMapManager.isCacheAvailable {
                    SettingsValueRow(title: L10n.Settings.icaoChart, tint: tint, value: offlineMapManager.cacheVersion)
                }

                if offlineMapManager.isSegelflugCacheAvailable {
                    SettingsValueRow(title: L10n.Settings.segelflugkarte, tint: tint, value: offlineMapManager.segelflugCacheVersion)
                }

                SettingsValueRow(title: L10n.Settings.totalCacheSize, tint: tint, value: offlineMapManager.formattedCacheSize)

                SettingsButtonRow(icon: "arrow.clockwise", title: L10n.Settings.updateCharts, tint: tint,
                                  showsChevron: false, action: { dataRoute = .offlineCharts })

                SettingsButtonRow(icon: "trash", title: L10n.Settings.deleteCache, tint: tint,
                                  showsChevron: false, destructive: true, action: { showDeleteConfirmation = true })
            } else {
                SettingsButtonRow(icon: "arrow.down.circle", title: L10n.Settings.downloadCharts, tint: tint,
                                  showsChevron: false, action: { dataRoute = .offlineCharts })
            }
        }
    }

    private var offlineMapsFooter: String {
        if offlineMode {
            if offlineMapManager.isSegelflugCacheAvailable {
                return L10n.Settings.offlineActive
            } else {
                return L10n.Settings.onlyICAO
            }
        } else if offlineMapManager.isCacheAvailable {
            return L10n.Settings.chartsCached
        } else {
            return L10n.Settings.downloadDesc
        }
    }

    // MARK: - OpenAIP Section

    @ViewBuilder
    private var openAIPSection: some View {
        SettingsGroup(title: L10n.Settings.openAIPAirspace, tint: tint, footer: L10n.Settings.openAIPFooter) {
            SettingsToggleRow(icon: "shield", title: L10n.Settings.airspaceOverlay, tint: tint, isOn: $showOpenAIPOverlay)

            SettingsToggleRow(icon: "dot.radiowaves.left.and.right", title: L10n.Settings.airspaceStreaming, tint: tint, isOn: Binding(
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
                // Download-in-progress row: spinner + progress bar, housed with the row container insets.
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
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            } else if openAIPDataService.isDataAvailable {
                // Multi-line status row: stacked text label + trailing update badge.
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
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }

            if openAIPCacheManager.isCacheAvailable {
                SettingsValueRow(title: L10n.Settings.tileCache, tint: tint, value: openAIPCacheManager.formattedCacheSize)
            }

            SettingsButtonRow(icon: openAIPDataService.isDataAvailable ? "arrow.triangle.2.circlepath" : "arrow.down.circle",
                              title: openAIPDataService.isDataAvailable ? L10n.Settings.updateData : L10n.Settings.downloadData,
                              tint: tint, showsChevron: false, action: { dataRoute = .openAIP })

            if openAIPDataService.isDataAvailable || openAIPCacheManager.isCacheAvailable {
                SettingsButtonRow(icon: "trash", title: L10n.Settings.deleteOpenAIPData, tint: tint,
                                  showsChevron: false, destructive: true, action: { showOpenAIPDeleteConfirmation = true })
            }

            if let error = openAIPDataService.downloadError ?? openAIPCacheManager.downloadError {
                // Error row: warning glyph + red caption, housed with the row container insets.
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.aviationRed)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.aviationRed)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
        }
    }

    // MARK: - Airport Data Section

    @ViewBuilder
    private var airportDataSection: some View {
        SettingsGroup(title: L10n.Settings.airportData, tint: tint, footer: L10n.Settings.airportDataFooter) {
            if airportDataService.isDownloading {
                // Download-in-progress row: spinner + progress bar, housed with the row container insets.
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
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            } else if airportDataService.isDataAvailable {
                // Multi-line status row: stacked text label + trailing update badge.
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
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                SettingsToggleRow(icon: "mappin.and.ellipse", title: L10n.Settings.showAirportsOnMap, tint: tint, isOn: $showAirportsOnMap)
                SettingsToggleRow(icon: "antenna.radiowaves.left.and.right", title: L10n.DataStorage.showNavaidsOnMap, tint: tint, isOn: $showNavaidsOnMap)
                SettingsToggleRow(icon: "exclamationmark.triangle", title: L10n.DataStorage.showObstaclesOnMap, tint: tint, isOn: $showObstaclesOnMap)
                SettingsToggleRow(icon: "triangle", title: L10n.DataStorage.showReportingPointsOnMap, tint: tint, isOn: $showReportingPointsOnMap)

                SettingsButtonRow(icon: "arrow.triangle.2.circlepath", title: L10n.Settings.updateAirportData, tint: tint,
                                  showsChevron: false, action: { Task { await airportDataService.downloadData() } })

                SettingsButtonRow(icon: "trash", title: L10n.Settings.deleteAirportData, tint: tint,
                                  showsChevron: false, destructive: true, action: { airportDataService.deleteData() })
            } else {
                SettingsButtonRow(icon: "arrow.down.circle", title: L10n.Settings.downloadAirportData, tint: tint,
                                  showsChevron: false, action: { Task { await airportDataService.downloadData() } })
            }

            if let error = airportDataService.downloadError {
                // Error row: warning glyph + red caption, housed with the row container insets.
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.aviationRed)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.aviationRed)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
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
        showNavaidsOnMap = appState.settings.showNavaidsOnMap
        showObstaclesOnMap = appState.settings.showObstaclesOnMap
        showReportingPointsOnMap = appState.settings.showReportingPointsOnMap
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
        appState.settings.showNavaidsOnMap = showNavaidsOnMap
        appState.settings.showObstaclesOnMap = showObstaclesOnMap
        appState.settings.showReportingPointsOnMap = showReportingPointsOnMap
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
    @EnvironmentObject var openAIPNavaidDataService: OpenAIPNavaidDataService
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    /// When true, rendered as a pushed page (parent supplies the nav bar + back); else as a sheet.
    var asPage: Bool = false

    @State private var selectedCountries: Set<String> = []
    @State private var showTilesConfirm = false

    var body: some View {
        Group {
            if asPage {
                downloadContent
            } else {
                NavigationStack {
                    downloadContent
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(L10n.Button.done) { dismiss() }
                            }
                        }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            selectedCountries = Set(appState.settings.openAIPOfflineCountries)
            if selectedCountries.isEmpty { selectedCountries = ["CH"] }
        }
        // Warn before adding the heavy raster tiles; recommend data-only. (v4.1.0 feedback)
        .alert(L10n.Settings.downloadTilesConfirmTitle, isPresented: $showTilesConfirm) {
            Button(L10n.Settings.downloadDataOnly) { startDownload(tilesAndData: false) }
            Button(L10n.Settings.downloadTilesAnyway, role: .destructive) { startDownload(tilesAndData: true) }
            Button(L10n.Button.cancel, role: .cancel) { }
        } message: {
            let selected = Array(selectedCountries)
            Text(L10n.Settings.downloadTilesConfirmMessage(
                OpenAIPDataService.estimatedDataSize(for: selected),
                openAIPCacheManager.estimatedDownloadSize(for: selected)))
        }
    }

    private var downloadContent: some View {
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
                                    // Data-first: show the JSON data estimate (the primary download), not tiles.
                                    Text(L10n.Settings.estimatedDataSize(OpenAIPDataService.estimatedDataSize(for: countries)))
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
                .listStyle(.plain)
                .scrollContentBackground(.hidden)

                // Download progress
                if openAIPCacheManager.isDownloading || openAIPDataService.isDownloading {
                    downloadProgressView
                }

                // Download buttons — DATA-FIRST: the structured data (small) is the primary action;
                // the heavy raster map tiles are an explicit opt-in. (v4.1.0 feedback)
                if !openAIPCacheManager.isDownloading && !openAIPDataService.isDownloading {
                    VStack(spacing: 8) {
                        Text(L10n.Settings.openAIPDownloadHint)
                            .font(.system(size: 12))
                            .foregroundColor(.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 2)

                        // Primary: structured data only (airspace + navaids + obstacles + RP + airports).
                        Button(action: { startDownload(tilesAndData: false) }) {
                            HStack {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 14))
                                Text(L10n.Settings.downloadData)
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

                        // Secondary: optionally add the large raster map tiles — confirm first.
                        Button(action: { showTilesConfirm = true }) {
                            HStack {
                                Image(systemName: "square.2.layers.3d")
                                    .font(.system(size: 14))
                                Text(L10n.Settings.downloadWithTiles)
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
        let obstacleService = OpenAIPObstacleDataService.shared
        let reportingPointService = OpenAIPReportingPointDataService.shared
        let openAIPAirportService = OpenAIPAirportDataService.shared

        Task {
            if tilesAndData {
                // Download tiles + airspace data + navaids + obstacles in parallel
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await openAIPCacheManager.downloadTiles(for: countries)
                    }
                    group.addTask {
                        await openAIPDataService.downloadData(for: countries)
                    }
                    group.addTask {
                        await openAIPNavaidDataService.downloadData(for: countries)
                    }
                    group.addTask {
                        await obstacleService.downloadData(for: countries)
                    }
                    group.addTask {
                        await reportingPointService.downloadData(for: countries)
                    }
                    group.addTask {
                        await openAIPAirportService.downloadData(for: countries)
                    }
                    await group.waitForAll()
                }
            } else {
                // Download structured data only (airspace + navaids + obstacles — small, ~100s KB)
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await openAIPDataService.downloadData(for: countries)
                    }
                    group.addTask {
                        await openAIPNavaidDataService.downloadData(for: countries)
                    }
                    group.addTask {
                        await obstacleService.downloadData(for: countries)
                    }
                    group.addTask {
                        await reportingPointService.downloadData(for: countries)
                    }
                    group.addTask {
                        await openAIPAirportService.downloadData(for: countries)
                    }
                    await group.waitForAll()
                }
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
                    Text(L10n.Settings.estimatedDataSize(
                        OpenAIPDataService.estimatedDataSize(for: selected)
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
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
