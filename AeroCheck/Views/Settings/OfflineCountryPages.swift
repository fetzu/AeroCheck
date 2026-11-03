import SwiftUI

// MARK: - Add a country

/// Offline data › Add a country: the home country and its neighbours first, then Europe, then elsewhere, with a
/// search. A country in one Atlas region downloads at one press; a larger one opens its page (the author's answers
/// 2 A and 3 A, 30 Oct 2026). A country added here stays listed until the page closes, saying how it is getting on.
/// (6.8.0)
struct AddCountryPage: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject private var offlineMapManager: OfflineMapManager
    @EnvironmentObject private var openAIPDataService: OpenAIPDataService
    @EnvironmentObject private var openAIPNavaidDataService: OpenAIPNavaidDataService
    @ObservedObject private var pilotMap = PilotMapDownloads.shared
    @ObservedObject private var vfr = OFMDataService.shared
    @ObservedObject private var countryDownloads = OfflineCountryDownloads.shared

    @State private var search = ""
    /// The countries not on the device when the page opened: those it lists.
    @State private var listed: Set<String>?

    private let tint: Color = .aviationGreen

    struct CountryGroup: Identifiable {
        let id: String
        let title: String
        let countries: [OfflineCountry]
    }

    /// The listed countries in their groups: the home country, its neighbours, Europe, elsewhere.
    static func groups(_ countries: [OfflineCountry], home: String?, search: String) -> [CountryGroup] {
        let shown = countries.filter { OfflineCountryCatalog.matches($0, search) }
        var rest = shown
        var groups: [CountryGroup] = []
        if let home {
            if let mine = rest.first(where: { $0.id == home }) {
                groups.append(CountryGroup(id: "home", title: L10n.OfflineData.yourCountry, countries: [mine]))
                rest.removeAll { $0.id == home }
            }
            let neighbours = CountryNeighbors.neighbors(of: home)
            let next = rest.filter { neighbours.contains($0.id) }
            if !next.isEmpty {
                groups.append(CountryGroup(id: "next", title: L10n.OfflineData.nextTo(OpenAIPConfig.countryName(for: home)),
                                    countries: next))
                rest.removeAll { neighbours.contains($0.id) }
            }
        }
        let europe = rest.filter { OfflineCountryCatalog.isInEurope($0.id) }
        if !europe.isEmpty { groups.append(CountryGroup(id: "europe", title: L10n.OfflineData.europe, countries: europe)) }
        let elsewhere = rest.filter { !OfflineCountryCatalog.isInEurope($0.id) }
        if !elsewhere.isEmpty { groups.append(CountryGroup(id: "elsewhere", title: L10n.OfflineData.elsewhere, countries: elsewhere)) }
        return groups
    }

    var body: some View {
        let snapshot = OfflineDataView.snapshot(appState: appState, airspace: openAIPDataService, vfr: vfr,
                                                pilotMap: pilotMap, charts: offlineMapManager,
                                                adding: countryDownloads.adding, sizes: OfflineCountrySizes())
        let onDevice = Set(snapshot.onDevice.map(\.country.id))
        let candidates = snapshot.countries.filter { listed?.contains($0.id) ?? !onDevice.contains($0.id) }
        let home = OfflineCountryCatalog.home(homeIdent: appState.settings.homeAerodromeIdent)
        let groups = Self.groups(candidates, home: home, search: search)
        SettingsPage {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                SettingsGroup(title: group.title, tint: tint,
                              footer: index == groups.count - 1 ? L10n.OfflineData.addFooter : nil) {
                    ForEach(group.countries) { country in
                        row(country, holding: snapshot.holding(country))
                    }
                }
            }
            if groups.isEmpty {
                Text(L10n.OfflineData.noMatch)
                    .font(.aero(.subheadline))
                    .foregroundColor(.secondaryText)
                    .padding(.horizontal, 6)
            }
        }
        .searchable(text: $search, prompt: L10n.OfflineData.searchPrompt)
        .navigationTitle(L10n.OfflineData.addCountry)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if listed == nil { listed = Set(candidates.map(\.id)) } }
    }

    @ViewBuilder
    private func row(_ country: OfflineCountry, holding: OfflineCountryHolding) -> some View {
        let downloading = countryDownloads.adding.contains(country.id)
            || holding.country.atlasRegions.contains { if case .downloading = pilotMap.state(of: $0.id) { return true }; return false }
        if country.isInRegions {
            NavigationLink {
                OfflineCountryPage(code: country.id)
            } label: {
                OfflineCountryRow(country: country,
                                  detail: holding.isOnDevice ? OfflineDataView.parts(holding, adding: countryDownloads.adding)
                                      : OfflineDataView.offer(country),
                                  bytes: fetchBytes(holding), trailing: .chevron)
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 0) {
                OfflineCountryRow(country: country,
                                  detail: downloading ? L10n.OfflineData.downloading
                                      : holding.isOnDevice ? L10n.OfflineData.onThisDevice : OfflineDataView.offer(country),
                                  bytes: holding.isOnDevice ? 0 : fetchBytes(holding), trailing: .none)
                Group {
                    if downloading {
                        ProgressView().frame(width: 44, height: 44)
                    } else if holding.isOnDevice {
                        Image(systemName: "checkmark.circle")
                            .scaledFont(size: 20, relativeTo: .title3)
                            .foregroundColor(.secondaryText)
                            .frame(width: 44, height: 44)
                            .accessibilityLabel(L10n.OfflineData.onThisDevice)
                    } else {
                        Button(L10n.PilotMap.download) {
                            OfflineDataView.downloadAll(holding, appState: appState, airspace: openAIPDataService,
                                                        navaids: openAIPNavaidDataService, pilotMap: pilotMap)
                        }
                        .font(.aero(.subheadline).weight(.semibold))
                        .foregroundColor(tint)
                        .frame(minHeight: 44)
                        .accessibilityLabel(L10n.OfflineData.downloadAllOf(country.name))
                    }
                }
                .padding(.trailing, 14)
            }
        }
    }

    private func fetchBytes(_ holding: OfflineCountryHolding) -> Int64 {
        OfflineCountryCatalog.bytesToFetch(holding.country, downloadedRegions: Set(holding.atlasDownloaded.map(\.id)),
                                           aeronauticalKept: holding.aeronautical)
    }
}

// MARK: - A country

/// A country's page: all of it at one press, or its parts one by one: the aeronautical data and VFR procedures
/// (small, for the whole country), the Atlas's regions, and in Switzerland the Swiss charts. Mockups 3 and 4 of the
/// proposal of 30 Oct 2026. The OpenAIP chart tiles are not offered here: question 17 is open. (6.8.0)
struct OfflineCountryPage: View {
    let code: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var offlineMapManager: OfflineMapManager
    @EnvironmentObject private var openAIPDataService: OpenAIPDataService
    @EnvironmentObject private var openAIPNavaidDataService: OpenAIPNavaidDataService
    @ObservedObject private var pilotMap = PilotMapDownloads.shared
    @ObservedObject private var vfr = OFMDataService.shared
    @ObservedObject private var countryDownloads = OfflineCountryDownloads.shared

    @State private var sizes = OfflineCountrySizes()
    @State private var pendingCountryDelete = false
    @State private var pendingRegionDelete: PilotMapRegion?
    @State private var pendingChartDelete: CacheableLayer?

    private let tint: Color = .aviationGreen

    var body: some View {
        let snapshot = OfflineDataView.snapshot(appState: appState, airspace: openAIPDataService, vfr: vfr,
                                                pilotMap: pilotMap, charts: offlineMapManager,
                                                adding: countryDownloads.adding, sizes: sizes)
        Group {
            if let country = snapshot.country(code) {
                content(snapshot.holding(country))
            } else {
                ContentUnavailableView(OpenAIPConfig.countryName(for: code), systemImage: "map")
            }
        }
        .navigationTitle(OpenAIPConfig.countryName(for: code))
        .navigationBarTitleDisplayMode(.inline)
        .task { sizes = await OfflineCountrySizes.read() }
        .onChange(of: countryDownloads.isSyncing) { _, syncing in if !syncing { Task { sizes = await OfflineCountrySizes.read() } } }
        .onChange(of: pilotMap.downloaded) { _, _ in Task { sizes = await OfflineCountrySizes.read() } }
        .alert(L10n.OfflineData.deleteCountryTitle(OpenAIPConfig.countryName(for: code)),
               isPresented: $pendingCountryDelete) {
            Button(L10n.DataStorage.delete, role: .destructive) { deleteCountry() }
            Button(L10n.Button.cancel, role: .cancel) {}
        } message: {
            Text(L10n.DataStorage.deleteConfirmMessage)
        }
        .alert(L10n.DataStorage.deleteConfirmTitle,
               isPresented: Binding(get: { pendingRegionDelete != nil }, set: { if !$0 { pendingRegionDelete = nil } }),
               presenting: pendingRegionDelete) { region in
            Button(L10n.DataStorage.delete, role: .destructive) { pilotMap.delete(region.id) }
            Button(L10n.Button.cancel, role: .cancel) {}
        } message: { _ in
            Text(L10n.DataStorage.deleteConfirmMessage)
        }
        .alert(L10n.DataStorage.deleteConfirmTitle,
               isPresented: Binding(get: { pendingChartDelete != nil }, set: { if !$0 { pendingChartDelete = nil } }),
               presenting: pendingChartDelete) { layer in
            Button(L10n.DataStorage.delete, role: .destructive) { offlineMapManager.deleteCache(for: layer) }
            Button(L10n.Button.cancel, role: .cancel) {}
        } message: { _ in
            Text(L10n.DataStorage.deleteConfirmMessage)
        }
    }

    private func content(_ holding: OfflineCountryHolding) -> some View {
        let country = holding.country
        let toFetch = OfflineCountryCatalog.bytesToFetch(country, downloadedRegions: Set(holding.atlasDownloaded.map(\.id)),
                                                         aeronauticalKept: holding.aeronautical
                                                             || countryDownloads.adding.contains(code))
        return SettingsPage {
            SettingsGroup(tint: tint) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(holding.isOnDevice ? OfflineDataView.parts(holding, adding: countryDownloads.adding)
                         : L10n.OfflineData.notOnDevice)
                        .font(.aero(.headline))
                        .foregroundColor(.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if holding.bytes > 0 {
                        Text(L10n.OfflineData.bytesOnDevice(OfflineDataView.bytes(holding.bytes)))
                            .font(.aero(.caption))
                            .foregroundColor(.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
                if toFetch > 0 {
                    SettingsButtonRow(icon: "arrow.down.circle",
                                      title: L10n.OfflineData.downloadAllOf(country.name),
                                      tint: tint, value: OfflineDataView.bytes(toFetch), showsChevron: false) {
                        OfflineDataView.downloadAll(holding, appState: appState, airspace: openAIPDataService,
                                                    navaids: openAIPNavaidDataService, pilotMap: pilotMap)
                    }
                    .accessibilityIdentifier("offlineData.downloadAll")
                }
            }

            if country.hasAeronauticalData || country.hasVFRProcedures {
                SettingsGroup(tint: tint, footer: country.isInRegions ? L10n.OfflineData.wholeCountryFooter(country.name) : nil) {
                    if country.hasAeronauticalData { aeronauticalRow(holding) }
                    if country.hasVFRProcedures { vfrRow(holding) }
                }
            }

            if !country.atlasRegions.isEmpty {
                SettingsGroup(title: country.isInRegions ? L10n.OfflineData.atlasRegions(country.atlasRegions.count)
                              : L10n.PilotMap.section, tint: tint) {
                    ForEach(country.atlasRegions) { region in
                        PilotMapRegionRow(region: region, state: pilotMap.state(of: region.id),
                                          bytesToFetch: pilotMap.bytesToFetch(region), tint: tint,
                                          download: { downloadRegion(region, holding: holding) },
                                          stop: { pilotMap.cancel(region.id) },
                                          delete: { pendingRegionDelete = region }, failure: pilotMap.ceilingMessage)
                    }
                }
            }

            if country.hasSwissCharts { swissChartsGroup }

            if holding.isOnDevice {
                SettingsGroup(tint: tint) {
                    SettingsButtonRow(icon: "trash", title: L10n.OfflineData.deleteCountry(country.name), tint: tint,
                                      showsChevron: false, destructive: true) {
                        pendingCountryDelete = true
                    }
                }
            }
        }
    }

    // MARK: Aeronautical data

    private func aeronauticalRow(_ holding: OfflineCountryHolding) -> some View {
        let adding = countryDownloads.adding.contains(code)
        let failed = openAIPDataService.failedCountries.contains(code)
        var line = L10n.DataStorage.statusMissing
        if adding {
            line = L10n.OfflineData.downloading
        } else if holding.aeronautical {
            line = "OpenAIP"
            if let date = openAIPDataService.lastUpdated {
                line += " · " + L10n.DataStorage.asOf(date.formatted(date: .abbreviated, time: .omitted))
            }
            if let bytes = sizes.aeronautical[code], bytes > 0 { line += " · " + OfflineDataView.bytes(bytes) }
        }
        return partRow(title: L10n.OfflineData.aeronauticalTitle, subtitle: L10n.OfflineData.aeronauticalDetail,
                       line: line, failed: failed, busy: adding, onDevice: holding.aeronautical) {
            countryDownloads.add(code, appState: appState, airspace: openAIPDataService, navaids: openAIPNavaidDataService)
        }
    }

    /// Open flightmaps' circuits and routes come with the aeronautical data: no button of their own.
    private func vfrRow(_ holding: OfflineCountryHolding) -> some View {
        var line = countryDownloads.adding.contains(code) ? L10n.OfflineData.downloading : L10n.OfflineData.withAeronautical
        if holding.vfr {
            line = "open flightmaps"
            if let cycle = vfr.cycles[code] { line += " · AIRAC \(cycle.airac)" }
            if let bytes = sizes.vfr[code], bytes > 0 { line += " · " + OfflineDataView.bytes(bytes) }
        }
        return partRow(title: L10n.OfflineData.vfrTitle, subtitle: L10n.OfflineData.vfrDetail, line: line,
                       failed: vfr.failedCountries.contains(code), busy: false, onDevice: holding.vfr, action: nil)
    }

    private func partRow(title: String, subtitle: String, line: String, failed: Bool, busy: Bool, onDevice: Bool,
                         action: (() -> Void)?) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.aero(.subheadline)).foregroundColor(.primaryText)
                Text(subtitle)
                    .font(.aero(.caption2))
                    .foregroundColor(.dimText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(line)
                    .font(.aero(.caption))
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if failed {
                    Text(L10n.DataStorage.updateFailed([code]))
                        .font(.aero(.caption))
                        .foregroundColor(.aviationRed)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if busy {
                ProgressView().frame(width: 44, height: 44)
            } else if onDevice {
                Image(systemName: "checkmark.circle")
                    .scaledFont(size: 20, relativeTo: .title3)
                    .foregroundColor(.secondaryText)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(L10n.PilotMap.downloaded)
            } else if let action {
                Button(L10n.PilotMap.download, action: action)
                    .font(.aero(.subheadline).weight(.semibold))
                    .foregroundColor(tint)
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: Swiss charts

    private var swissChartsGroup: some View {
        SettingsGroup(title: L10n.OfflineData.swissCharts, tint: tint) {
            chartRow(.icao, title: L10n.OfflineData.icaoChart, subtitle: nil,
                     available: offlineMapManager.isCacheAvailable, edition: offlineMapManager.cacheVersion,
                     approximate: "≈ 100 MB", option: .icaoOnly)
            chartRow(.segelflug, title: L10n.OfflineData.gliderChart, subtitle: L10n.OfflineData.gliderChartDetail,
                     available: offlineMapManager.isSegelflugCacheAvailable, edition: offlineMapManager.segelflugCacheVersion,
                     approximate: "≈ 150 MB", option: .icaoAndSegelflug)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.OfflineData.onlineCharts).font(.aero(.subheadline)).foregroundColor(.primaryText)
                    Text(L10n.OfflineData.onlineChartsDetail)
                        .font(.aero(.caption))
                        .foregroundColor(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            if let error = offlineMapManager.downloadError {
                Text(error)
                    .font(.aero(.caption))
                    .foregroundColor(.aviationRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            }
        }
    }

    private func chartRow(_ layer: CacheableLayer, title: String, subtitle: String?, available: Bool, edition: String,
                          approximate: String, option: CacheOption) -> some View {
        let downloading = offlineMapManager.isDownloading && offlineMapManager.currentDownloadingLayer == layer
        var line = available ? L10n.OfflineData.edition(edition) : "\(L10n.DataStorage.statusMissing) · \(approximate)"
        if downloading { line = L10n.PilotMap.downloading(offlineMapManager.downloadProgress) }
        if available && offlineMapManager.needsYearlyUpdate { line += " · " + L10n.PilotMap.updateAvailable }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.aero(.subheadline)).foregroundColor(.primaryText)
                if let subtitle {
                    Text(subtitle)
                        .font(.aero(.caption2))
                        .foregroundColor(.dimText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(line)
                    .font(.aero(.caption))
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if downloading {
                    ProgressView(value: offlineMapManager.downloadProgress).tint(tint)
                }
            }
            Spacer(minLength: 8)
            if downloading {
                ProgressView().frame(width: 44, height: 44)
            } else if available {
                Menu {
                    Button { Task { await offlineMapManager.downloadCharts(option: option) } } label: {
                        Label(L10n.PilotMap.update, systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button(role: .destructive) { pendingChartDelete = layer } label: {
                        Label(L10n.DataStorage.delete, systemImage: "trash")
                    }
                } label: {
                    Image(systemName: offlineMapManager.needsYearlyUpdate ? "arrow.down.circle" : "checkmark.circle")
                        .scaledFont(size: 20, relativeTo: .title3)
                        .foregroundColor(offlineMapManager.needsYearlyUpdate ? tint : .secondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.DataStorage.rowActions)
            } else {
                Button(L10n.PilotMap.download) { Task { await offlineMapManager.downloadCharts(option: option) } }
                    .font(.aero(.subheadline).weight(.semibold))
                    .foregroundColor(tint)
                    .frame(minHeight: 44)
                    .disabled(offlineMapManager.isDownloading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: Actions

    /// A region, and the country's aeronautical data with it when it isn't kept: it is small and for the whole
    /// country.
    private func downloadRegion(_ region: PilotMapRegion, holding: OfflineCountryHolding) {
        pilotMap.download(region)
        if holding.country.hasAeronauticalData || holding.country.hasVFRProcedures, !holding.aeronautical, !holding.vfr {
            countryDownloads.add(code, appState: appState, airspace: openAIPDataService, navaids: openAIPNavaidDataService)
        }
    }

    private func deleteCountry() {
        let snapshot = OfflineDataView.snapshot(appState: appState, airspace: openAIPDataService, vfr: vfr,
                                                pilotMap: pilotMap, charts: offlineMapManager,
                                                adding: countryDownloads.adding, sizes: sizes)
        guard let country = snapshot.country(code) else { return }
        let holding = snapshot.holding(country)
        for region in holding.atlasDownloaded { pilotMap.delete(region.id) }
        for region in country.atlasRegions { pilotMap.cancel(region.id) }
        if holding.aeronautical || holding.vfr || appState.settings.openAIPOfflineCountries.contains(code)
            || countryDownloads.adding.contains(code) {
            countryDownloads.remove(code, appState: appState, airspace: openAIPDataService, navaids: openAIPNavaidDataService)
        }
        if country.hasSwissCharts { offlineMapManager.deleteCache() }
        dismiss()
    }
}

extension OfflineDataView {
    /// One press: the country's aeronautical data and VFR procedures when not kept, and every Atlas region not on the
    /// device.
    static func downloadAll(_ holding: OfflineCountryHolding, appState: AppState, airspace: OpenAIPDataService,
                            navaids: OpenAIPNavaidDataService, pilotMap: PilotMapDownloads) {
        let country = holding.country
        if country.hasAeronauticalData || country.hasVFRProcedures, !holding.aeronautical {
            OfflineCountryDownloads.shared.add(country.id, appState: appState, airspace: airspace, navaids: navaids)
        }
        for region in holding.atlasMissing { pilotMap.download(region) }
    }
}

// MARK: - From the map

/// Where the map's download hints lead: Offline data, or one country's page there. (6.8.0)
enum OfflineDataRoute: Identifiable, Hashable {
    case offlineData
    case country(String)

    var id: String {
        switch self {
        case .offlineData: return "offlineData"
        case let .country(code): return code
        }
    }
}

/// Offline data, or a country's page, in a sheet over the map, with a Close button.
struct OfflineDataRouteView: View {
    let route: OfflineDataRoute
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch route {
        case .offlineData:
            SettingsView(initialSection: .dataStorage)
        case let .country(code):
            NavigationStack {
                OfflineCountryPage(code: code)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.Button.close) { dismiss() }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
    }
}
