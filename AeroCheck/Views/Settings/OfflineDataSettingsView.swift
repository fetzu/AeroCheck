import SwiftUI

/// Settings › Offline data: what is on the device, by country, with one update status at the top, where the map's
/// data comes from, the worldwide airports and the Atlas's overview, the month's online allowance and the storage.
/// It replaces Data & Storage and Navigation & Maps: a country is the unit (the author's answers 1 A to 10 C, 30 Oct
/// 2026), the layer switches are the Map sheet's, and the two connection switches came here (14 A). (6.8.0)
struct OfflineDataSettingsView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject private var dataStatusManager: DataStatusManager
    @EnvironmentObject private var airportDataService: AirportDataService
    @EnvironmentObject private var offlineMapManager: OfflineMapManager
    @EnvironmentObject private var openAIPDataService: OpenAIPDataService
    @ObservedObject private var pilotMap = PilotMapDownloads.shared
    @ObservedObject private var vfr = OFMDataService.shared
    @ObservedObject private var countryDownloads = OfflineCountryDownloads.shared

    @State private var sizes = OfflineCountrySizes()
    @State private var airportBytes: Int64 = 0
    @State private var isUpdating = false
    @State private var showAirspaceStreamingWarning = false
    @State private var showRemoveAllConfirm = false
    @State private var showAirportsDeleteConfirm = false
    @State private var pendingOverviewDelete = false

    private let tint: Color = .aviationGreen

    var body: some View {
        let snapshot = OfflineDataView.snapshot(appState: appState, airspace: openAIPDataService, vfr: vfr,
                                                pilotMap: pilotMap, charts: offlineMapManager,
                                                adding: countryDownloads.adding, sizes: sizes)
        let holdings = snapshot.onDevice
        SettingsPage {
            statusGroup(holdings)
            connectionGroup
            countriesGroup(holdings)
            worldwideGroup
            SettingsGroup(title: L10n.OfflineData.atlasOnline, tint: tint, footer: L10n.OfflineData.atlasOnlineFooter) {
                PilotMapAllowanceRow(downloads: pilotMap)
            }
            storageGroup(holdings)
            credits
        }
        .navigationTitle(L10n.OfflineData.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { dataStatusManager.recompute() }
        .task {
            await readSizes()
            await pilotMap.refreshIndex()
        }
        .onChange(of: countryDownloads.isSyncing) { _, syncing in if !syncing { Task { await readSizes() } } }
        .onChange(of: pilotMap.downloaded) { _, _ in Task { await readSizes() } }
        .onChange(of: airportDataService.isDownloading) { _, _ in Task { await readSizes() } }
        .sheet(isPresented: $showAirspaceStreamingWarning) {
            AirspaceStreamingWarningSheet(isPresented: $showAirspaceStreamingWarning,
                                          enableAirspaceStreaming: settingBinding(\.enableAirspaceStreaming))
        }
        .alert(L10n.DataStorage.removeAllConfirmTitle, isPresented: $showRemoveAllConfirm) {
            Button(L10n.DataStorage.removeAll, role: .destructive) { removeAll() }
            Button(L10n.Button.cancel, role: .cancel) {}
        } message: {
            Text(L10n.DataStorage.deleteConfirmMessage)
        }
        .alert(L10n.DataStorage.deleteConfirmTitle, isPresented: $showAirportsDeleteConfirm) {
            Button(L10n.DataStorage.delete, role: .destructive) {
                airportDataService.deleteData()
                Task { await readSizes() }
            }
            Button(L10n.Button.cancel, role: .cancel) {}
        } message: {
            Text(L10n.DataStorage.deleteConfirmMessage)
        }
        .alert(L10n.DataStorage.deleteConfirmTitle, isPresented: $pendingOverviewDelete) {
            Button(L10n.DataStorage.delete, role: .destructive) { pilotMap.delete(PilotMapRegion.overviewID) }
            Button(L10n.Button.cancel, role: .cancel) {}
        } message: {
            Text(L10n.DataStorage.deleteConfirmMessage)
        }
    }

    // MARK: - Status

    /// One status for everything: what is ready offline, then up to date or the updates waiting, and the switch that
    /// keeps it so (the author's answer 6 A).
    private func statusGroup(_ holdings: [OfflineCountryHolding]) -> some View {
        let updates = OfflineDataView.updateCount(dataSets: dataStatusManager.dataSets, pilotMap: pilotMap,
                                                  charts: offlineMapManager)
        return SettingsGroup(tint: tint) {
            VStack(alignment: .leading, spacing: 4) {
                Text(holdings.isEmpty ? L10n.OfflineData.nothingYet : L10n.OfflineData.readyIn(holdings.count))
                    .font(.aero(.headline))
                    .foregroundColor(.primaryText)
                if !holdings.isEmpty {
                    Text(OfflineDataView.readyDetail(holdings, totalBytes: totalBytes(holdings)))
                        .font(.aero(.caption))
                        .foregroundColor(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .accessibilityElement(children: .combine)

            if updates == 0 || isUpdating {
                HStack(spacing: 12) {
                    StatusIndicator(isUpdating ? .warning : .active, size: 11)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isUpdating ? L10n.OfflineData.updating : L10n.OfflineData.upToDate)
                            .font(.aero(.subheadline))
                            .foregroundColor(.primaryText)
                        if let checked = dataStatusManager.lastCheck, !isUpdating {
                            Text(L10n.OfflineData.checked(checked.formatted(.relative(presentation: .named))))
                                .font(.aero(.caption))
                                .foregroundColor(.secondaryText)
                        }
                    }
                    Spacer(minLength: 8)
                    if isUpdating { ProgressView().scaleEffect(0.8) }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .accessibilityElement(children: .combine)
            } else {
                HStack(spacing: 12) {
                    StatusIndicator(.warning, size: 11)
                    Text(L10n.OfflineData.updates(updates))
                        .font(.aero(.subheadline))
                        .foregroundColor(.primaryText)
                    Spacer(minLength: 8)
                    Button(L10n.OfflineData.updateNow) { Task { await updateNow() } }
                        .font(.aero(.subheadline).weight(.semibold))
                        .foregroundColor(tint)
                        .frame(minHeight: 44)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }

            SettingsToggleRow(icon: "arrow.triangle.2.circlepath", title: L10n.OfflineData.autoUpdate,
                              subtitle: L10n.OfflineData.autoUpdateDetail, tint: tint,
                              isOn: settingBinding(\.autoUpdateOfflineData))
        }
    }

    // MARK: - Connection

    /// Where the map's data comes from: the two switches of the old Navigation & Maps (the author's answer 14 A).
    private var connectionGroup: some View {
        SettingsGroup(title: L10n.OfflineData.connection, tint: tint) {
            SettingsToggleRow(icon: "airplane", title: L10n.OfflineData.offlineMode,
                              subtitle: L10n.OfflineData.offlineModeDetail, tint: tint,
                              isOn: settingBinding(\.offlineMode))
            SettingsToggleRow(icon: "dot.radiowaves.left.and.right", title: L10n.OfflineData.onlineAirspace,
                              subtitle: L10n.OfflineData.onlineAirspaceDetail, tint: tint,
                              isOn: Binding(get: { appState.settings.enableAirspaceStreaming },
                                            set: { on in
                                                if on {
                                                    showAirspaceStreamingWarning = true
                                                } else {
                                                    appState.settings.enableAirspaceStreaming = false
                                                    appState.saveSettings()
                                                }
                                            }))
        }
    }

    // MARK: - Countries

    private func countriesGroup(_ holdings: [OfflineCountryHolding]) -> some View {
        SettingsGroup(title: L10n.OfflineData.yourCountries, tint: tint, footer: L10n.OfflineData.yourCountriesFooter) {
            if holdings.isEmpty {
                Text(L10n.OfflineData.noCountries)
                    .font(.aero(.caption))
                    .foregroundColor(.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            }
            ForEach(holdings, id: \.country.id) { holding in
                NavigationLink {
                    OfflineCountryPage(code: holding.country.id)
                } label: {
                    OfflineCountryRow(country: holding.country,
                                      detail: OfflineDataView.parts(holding, adding: countryDownloads.adding),
                                      bytes: holding.bytes, trailing: .chevron)
                }
                .buttonStyle(.plain)
            }
            NavigationLink {
                AddCountryPage()
            } label: {
                HStack(spacing: 8) {
                    SettingsRowLabel(icon: "plus", title: L10n.OfflineData.addCountry, tint: tint)
                    Image(systemName: "chevron.right")
                        .font(.aero(size: 13, weight: .semibold))
                        .foregroundColor(.dimText)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("offlineData.addCountry")
        }
    }

    // MARK: - Worldwide

    /// The airports of every country (OurAirports), and the Atlas's overview, its map only (the author's answer 10 C).
    private var worldwideGroup: some View {
        SettingsGroup(title: L10n.OfflineData.worldwide, tint: tint) {
            airportsRow
            if let overview = pilotMap.overview {
                PilotMapRegionRow(region: overview, state: pilotMap.state(of: overview.id),
                                  bytesToFetch: pilotMap.bytesToFetch(overview), tint: tint,
                                  download: { pilotMap.download(overview) },
                                  stop: { pilotMap.cancel(overview.id) },
                                  delete: { pendingOverviewDelete = true })
            }
        }
    }

    private var airportsRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.OfflineData.airports)
                    .font(.aero(.subheadline))
                    .foregroundColor(.primaryText)
                Text(airportsDetail)
                    .font(.aero(.caption))
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if airportDataService.isDownloading {
                    ProgressView(value: airportDataService.downloadProgress).tint(tint)
                }
                if let error = airportDataService.downloadError {
                    Text(error)
                        .font(.aero(.caption))
                        .foregroundColor(.aviationRed)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if airportDataService.isDownloading {
                ProgressView().scaleEffect(0.8).frame(width: 44, height: 44)
            } else if airportDataService.isOurAirportsDownloaded {
                Menu {
                    Button { Task { await airportDataService.downloadData() } } label: {
                        Label(L10n.PilotMap.update, systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button(role: .destructive) { showAirportsDeleteConfirm = true } label: {
                        Label(L10n.DataStorage.delete, systemImage: "trash")
                    }
                } label: {
                    Image(systemName: airportDataService.needsUpdate ? "arrow.down.circle" : "checkmark.circle")
                        .scaledFont(size: 20, relativeTo: .title3)
                        .foregroundColor(airportDataService.needsUpdate ? tint : .secondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.DataStorage.rowActions)
            } else {
                Button(L10n.PilotMap.download) { Task { await airportDataService.downloadData() } }
                    .font(.aero(.subheadline).weight(.semibold))
                    .foregroundColor(tint)
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var airportsDetail: String {
        // OurAirports' own file, not `isDataAvailable`, which a country's OpenAIP aerodromes make true on their own: the
        // row said Downloaded after Switzerland alone (the author's device check fix2-10, 31 Oct 2026).
        guard airportDataService.isOurAirportsDownloaded else {
            return "\(L10n.OfflineData.airportsSource) · \(L10n.DataStorage.statusMissing)"
        }
        var parts = [L10n.OfflineData.airportsCount(airportDataService.airportCount)]
        if let date = airportDataService.lastUpdated {
            parts.append(L10n.DataStorage.asOf(date.formatted(date: .abbreviated, time: .omitted)))
        }
        if airportBytes > 0 { parts.append(OfflineDataView.bytes(airportBytes)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Storage

    private func storageGroup(_ holdings: [OfflineCountryHolding]) -> some View {
        SettingsGroup(title: L10n.DataStorage.storageSection, tint: tint) {
            SettingsValueRow(icon: "internaldrive", title: L10n.OfflineData.onThisDevice, tint: tint,
                             value: OfflineDataView.bytes(totalBytes(holdings)))
            SettingsButtonRow(icon: "trash", title: L10n.DataStorage.removeAll, tint: tint,
                              showsChevron: false, destructive: true) {
                showRemoveAllConfirm = true
            }
        }
    }

    private func totalBytes(_ holdings: [OfflineCountryHolding]) -> Int64 {
        let overview = pilotMap.downloaded.first { $0.id == PilotMapRegion.overviewID }?.downloadBytes ?? 0
        return holdings.reduce(Int64(0)) { $0 + $1.bytes } + airportBytes + Int64(overview)
    }

    /// The sources' credits the licences ask for, linked.
    private var credits: some View {
        Group {
            if let attributed = try? AttributedString(markdown: L10n.OfflineData.credits) {
                Text(attributed)
            } else {
                Text(L10n.OfflineData.credits)
            }
        }
        .font(.aero(.caption2))
        .foregroundColor(.dimText)
        .tint(.aviationGold)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 6)
    }

    // MARK: - Actions

    /// Every update waiting, at once: the small data, the Atlas's new builds and the Swiss charts' new edition.
    private func updateNow() async {
        isUpdating = true
        for region in pilotMap.downloaded where pilotMap.state(of: region.id) == .updateAvailable {
            if let listed = pilotMap.listedRegion(region.id) { pilotMap.download(listed) }
        }
        if offlineMapManager.needsYearlyUpdate && !offlineMapManager.isDownloading {
            let option: CacheOption = offlineMapManager.isSegelflugCacheAvailable ? .icaoAndSegelflug : .icaoOnly
            Task { await offlineMapManager.downloadCharts(option: option) }
        }
        await dataStatusManager.updateAllDownloaded()
        await readSizes()
        isUpdating = false
    }

    private func removeAll() {
        dataStatusManager.removeAll()
        pilotMap.deleteAll()
        offlineMapManager.deleteCache()
        appState.settings.openAIPOfflineCountries = []
        appState.saveSettings()
        Task { await readSizes() }
    }

    private func readSizes() async {
        sizes = await OfflineCountrySizes.read()
        airportBytes = await Task.detached(priority: .utility) {
            OfflineDataView.directoryBytes("AirportData")
        }.value
    }

    private func settingBinding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { appState.settings[keyPath: keyPath] },
                set: { appState.settings[keyPath: keyPath] = $0; appState.saveSettings() })
    }
}

/// What Offline data and its pages share: the snapshot of the services, the counts and the lines. (6.8.0)
@MainActor
enum OfflineDataView {

    static func snapshot(appState: AppState, airspace: OpenAIPDataService, vfr: OFMDataService,
                         pilotMap: PilotMapDownloads, charts: OfflineMapManager, adding: Set<String>,
                         sizes: OfflineCountrySizes) -> OfflineDataSnapshot {
        OfflineDataSnapshot(
            countries: OfflineCountryCatalog.countries(atlasRegions: pilotMap.regions,
                                                       vfrCountries: Set(vfr.supportedCountries)),
            kept: Set(airspace.downloadedCountries),
            vfrKept: Set(vfr.downloadedCountries),
            adding: adding,
            downloadedRegions: pilotMap.downloaded,
            swissCharts: charts.isCacheAvailable || charts.isSegelflugCacheAvailable,
            swissChartBytes: charts.cacheSizeBytes,
            sizes: sizes)
    }

    /// The updates waiting: each small dataset aging or out of date, each Atlas region with a new build, the Swiss
    /// charts' new edition.
    static func updateCount(dataSets: [DataSet], pilotMap: PilotMapDownloads, charts: OfflineMapManager) -> Int {
        let data = dataSets.filter {
            $0.refreshPolicy == .smallSilentJSON && $0.isDownloaded && ($0.freshness == .aging || $0.freshness == .stale)
        }.count
        let atlas = pilotMap.downloaded.filter { pilotMap.state(of: $0.id) == .updateAvailable }.count
        return data + atlas + (charts.needsYearlyUpdate ? 1 : 0)
    }

    /// "Switzerland, France in 3 of its 13 regions · 412 MB".
    static func readyDetail(_ holdings: [OfflineCountryHolding], totalBytes: Int64) -> String {
        let names = holdings.map { holding -> String in
            let total = holding.country.atlasRegions.count
            let here = holding.atlasDownloaded.count
            return total > 1 && here > 0 && here < total
                ? L10n.OfflineData.inRegions(holding.country.name, here, total) : holding.country.name
        }
        return "\(ListFormatter.localizedString(byJoining: names)) · \(bytes(totalBytes))"
    }

    /// A country's row: what is on the device, "Atlas · aeronautical data · VFR procedures · Swiss charts".
    static func parts(_ holding: OfflineCountryHolding, adding: Set<String>) -> String {
        if adding.contains(holding.country.id) { return L10n.OfflineData.downloading }
        var parts: [String] = []
        let total = holding.country.atlasRegions.count
        let here = holding.atlasDownloaded.count
        if here > 0 {
            parts.append(total > 1 && here < total ? L10n.OfflineData.partAtlasSome(here, total) : L10n.OfflineData.partAtlas)
        }
        if holding.aeronautical { parts.append(L10n.OfflineData.partAeronautical) }
        if holding.vfr { parts.append(L10n.OfflineData.partVFR) }
        if holding.swissCharts { parts.append(L10n.OfflineData.partSwissCharts) }
        return capitalisedFirst(parts.joined(separator: " · "))
    }

    /// What a country offers, for Add a country: "Atlas in 13 regions · aeronautical data · VFR procedures".
    static func offer(_ country: OfflineCountry) -> String {
        if country.atlasRegions.isEmpty { return L10n.OfflineData.aeronauticalOnly }
        var parts = [country.isInRegions ? L10n.OfflineData.partAtlasIn(country.atlasRegions.count) : L10n.OfflineData.partAtlas]
        if country.hasAeronauticalData { parts.append(L10n.OfflineData.partAeronautical) }
        if country.hasVFRProcedures { parts.append(L10n.OfflineData.partVFR) }
        return parts.joined(separator: " · ")
    }

    static func capitalisedFirst(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    nonisolated static func directoryBytes(_ name: String) -> Int64 {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let enumerator = fm.enumerator(at: base.appendingPathComponent(name, isDirectory: true),
                                             includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

/// One country: its flag and name, a line under it, its size, and a chevron or a button at the end.
struct OfflineCountryRow: View {
    enum Trailing { case chevron, none }

    let country: OfflineCountry
    let detail: String
    let bytes: Int64
    var trailing: Trailing = .chevron

    var body: some View {
        HStack(spacing: 12) {
            Text(OfflineCountryCatalog.flag(country.id))
                .font(.system(size: 24))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(country.name)
                    .font(.aero(.subheadline))
                    .foregroundColor(.primaryText)
                Text(detail)
                    .font(.aero(.caption))
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if bytes > 0 {
                Text(OfflineDataView.bytes(bytes))
                    .font(.aero(.caption).monospacedDigit())
                    .foregroundColor(.dimText)
            }
            if trailing == .chevron {
                Image(systemName: "chevron.right")
                    .font(.aero(size: 13, weight: .semibold))
                    .foregroundColor(.dimText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
