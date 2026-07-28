import SwiftUI

/// Settings sub-page consolidating external-data currency + offline storage in one place (v4.1.0 Data
/// Freshness). Reads `DataStatusManager` for per-source status and dispatches refresh/delete back to it.
/// The scattered download buttons in Navigation & Maps will be relocated here in a follow-up.
struct DataStorageSettingsView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject private var dataStatusManager: DataStatusManager
    @EnvironmentObject private var aircraftDataService: AircraftDataService
    @EnvironmentObject private var flightPlanManager: FlightPlanManager

    @State private var isPrefetchingTrip = false
    @State private var refreshingIDs: Set<String> = []
    @State private var isSyncingChecklists = false
    @State private var isUpdatingAll = false
    @State private var pendingDelete: DataSet?
    @State private var showRemoveAllConfirm = false
    /// On-disk sizes computed off the main thread on appear (the descriptors don't carry them yet).
    @State private var sizes: [String: Int64] = [:]

    private let tint: Color = .aviationGreen

    private var primaryDataSets: [DataSet] { dataStatusManager.dataSets.filter { $0.urgency == .primary } }
    private var imageryDataSets: [DataSet] { dataStatusManager.dataSets.filter { $0.urgency == .imagery } }
    private var hasUpdatable: Bool {
        dataStatusManager.dataSets.contains { $0.refreshPolicy == .smallSilentJSON && $0.isDownloaded }
    }

    var body: some View {
        SettingsPage {
            if !primaryDataSets.isEmpty {
                // Group + its OpenAIP credit wrapped together so the credit hugs the footer (no empty line).
                VStack(alignment: .leading, spacing: 7) {
                    SettingsGroup(title: L10n.DataStorage.aeronauticalSection, tint: tint, footer: L10n.DataStorage.caveat) {
                        ForEach(primaryDataSets) { dataRow($0) }

                        // This screen refreshes what's already downloaded; adding/removing coverage
                        // (countries, continents) happens in Navigation & Maps — link there instead of
                        // leaving users to hunt for it. (v4.2 UX fix)
                        NavigationLink {
                            NavigationMapsSettingsView()
                        } label: {
                            HStack(spacing: 8) {
                                SettingsRowLabel(icon: "map",
                                                 title: L10n.DataStorage.manageRegions,
                                                 subtitle: L10n.DataStorage.manageRegionsDetail,
                                                 tint: tint)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.dimText.opacity(0.7))
                                    .accessibilityHidden(true)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    openAIPCredit   // airspace is OpenAIP data
                }
            }
            if !imageryDataSets.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    SettingsGroup(title: L10n.DataStorage.chartsSection, tint: tint) {
                        ForEach(imageryDataSets) { dataRow($0) }
                    }
                    openAIPCredit   // OpenAIP map tiles
                }
            }
            tripPrefetchSection
            checklistsSection
            storageSection
        }
        .navigationTitle(L10n.DataStorage.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            dataStatusManager.recompute()
            recomputeSizes()
        }
        .alert(L10n.DataStorage.deleteConfirmTitle, isPresented: deleteAlertBinding, presenting: pendingDelete) { dataSet in
            Button(L10n.DataStorage.delete, role: .destructive) {
                dataStatusManager.delete(dataSet)
                recomputeSizes()
            }
            Button(L10n.Button.cancel, role: .cancel) {}
        } message: { _ in
            Text(L10n.DataStorage.deleteConfirmMessage)
        }
        .alert(L10n.DataStorage.removeAllConfirmTitle, isPresented: $showRemoveAllConfirm) {
            Button(L10n.DataStorage.removeAll, role: .destructive) {
                dataStatusManager.removeAll()
                recomputeSizes()
            }
            Button(L10n.Button.cancel, role: .cancel) {}
        } message: {
            Text(L10n.DataStorage.deleteConfirmMessage)
        }
    }

    // MARK: - Trip Prefetch (v4.1.0)

    /// Offers to download the per-country layers the active flight plan's route crosses but doesn't yet
    /// cover. Hidden when there's no active plan, the route is a single point, or coverage is complete.
    @ViewBuilder
    private var tripPrefetchSection: some View {
        if let plan = flightPlanManager.activeFlightPlan, plan.waypoints.count >= 2 {
            let routeCountries = RouteDataCalculator.countries(crossing: plan.waypoints.map { $0.coordinate })
            let needed = dataStatusManager.tripCountriesNeedingData(routeCountries: routeCountries)
            if !needed.isEmpty {
                let neededNames = needed.map { OpenAIPConfig.countryName(for: $0) }.joined(separator: ", ")
                SettingsGroup(title: L10n.DataStorage.tripSection, tint: tint,
                              footer: "\(L10n.DataStorage.tripFooter) \(neededNames)") {
                    SettingsButtonRow(icon: "arrow.down.circle",
                                      title: isPrefetchingTrip ? L10n.DataStorage.tripDownloading : L10n.DataStorage.tripDownload,
                                      tint: tint, showsChevron: false) {
                        guard !isPrefetchingTrip else { return }
                        Task {
                            isPrefetchingTrip = true
                            await dataStatusManager.prefetchTripData(countries: needed)
                            recomputeSizes()
                            isPrefetchingTrip = false
                        }
                    }
                }
            }
        }
    }

    // MARK: - Rows

    private func dataRow(_ dataSet: DataSet) -> some View {
        let (indicatorStatus, statusLabel) = statusInfo(dataSet.freshness)
        return HStack(spacing: 12) {
            StatusIndicator(indicatorStatus, size: 11, label: dataSet.displayName)
            VStack(alignment: .leading, spacing: 3) {
                Text(dataSet.displayName)
                    .font(.subheadline)
                    .foregroundColor(.primaryText)
                Text(dataSet.detail)
                    .font(.caption2)
                    .foregroundColor(.dimText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle(for: dataSet, statusLabel: statusLabel))
                    .font(.caption)
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let size = sizeString(for: dataSet) {
                Text(size)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.dimText)
            }
            rowMenu(dataSet)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func rowMenu(_ dataSet: DataSet) -> some View {
        Group {
            if refreshingIDs.contains(dataSet.id) {
                ProgressView().scaleEffect(0.7).frame(width: 28)
            } else {
                Menu {
                    Button {
                        Task { await refresh(dataSet) }
                    } label: {
                        Label(L10n.DataStorage.refresh, systemImage: "arrow.triangle.2.circlepath")
                    }
                    if dataSet.isDownloaded {
                        Button(role: .destructive) {
                            pendingDelete = dataSet
                        } label: {
                            Label(L10n.DataStorage.delete, systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .scaledFont(size: 18, relativeTo: .title3)
                        .foregroundColor(.secondaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.DataStorage.rowActions)
            }
        }
    }

    private var storageSection: some View {
        SettingsGroup(title: L10n.DataStorage.storageSection, tint: tint) {
            HStack(spacing: 13) {
                SettingsRowLabel(icon: "internaldrive", title: L10n.DataStorage.totalStorage(totalSizeString), tint: tint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            if hasUpdatable {
                if isUpdatingAll {
                    HStack(spacing: 13) {
                        SettingsRowLabel(icon: "arrow.triangle.2.circlepath", title: L10n.DataStorage.updateAll, tint: tint)
                        Spacer(minLength: 0)
                        ProgressView().scaleEffect(0.8)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                } else {
                    SettingsButtonRow(icon: "arrow.triangle.2.circlepath", title: L10n.DataStorage.updateAll,
                                      tint: tint, showsChevron: false) {
                        Task { await updateAll() }
                    }
                }
            }

            SettingsButtonRow(icon: "trash", title: L10n.DataStorage.removeAll,
                              tint: tint, showsChevron: false, destructive: true) {
                showRemoveAllConfirm = true
            }
        }
    }

    /// License-required OpenAIP attribution, shown after each section that surfaces OpenAIP data, with a
    /// tappable link (rendered from markdown). (v4.1.0)
    private var openAIPCredit: some View {
        Group {
            if let attributed = try? AttributedString(markdown: L10n.DataStorage.openAIPAttribution) {
                Text(attributed)
            } else {
                Text(L10n.DataStorage.openAIPAttribution)
            }
        }
        .font(.caption2)
        .foregroundColor(.dimText)
        .tint(.aviationGold)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 6)
    }

    // MARK: - Checklists (relocated from About → device-test feedback)

    private var checklistsSection: some View {
        SettingsGroup(title: L10n.DataStorage.checklistsSection, tint: tint, footer: L10n.DataStorage.checklistsDetail) {
            let cached = aircraftDataService.getAllCachedAircraft()
            if cached.isEmpty {
                Text(L10n.DataStorage.noChecklists)
                    .font(.caption)
                    .foregroundColor(.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            } else {
                ForEach(groupCachedByAeroclub(cached), id: \.aeroclub) { group in
                    checklistGroup(group)
                }
            }
            if isSyncingChecklists {
                HStack(spacing: 13) {
                    SettingsRowLabel(icon: "arrow.triangle.2.circlepath", title: L10n.DataStorage.syncChecklists, tint: tint)
                    Spacer(minLength: 0)
                    ProgressView().scaleEffect(0.8)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            } else {
                SettingsButtonRow(icon: "arrow.triangle.2.circlepath", title: L10n.DataStorage.syncChecklists,
                                  tint: tint, showsChevron: false) {
                    Task { await syncChecklists() }
                }
            }
        }
    }

    private func checklistGroup(_ group: (aeroclub: String?, aircraft: [CachedAircraftInfo])) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let aeroclub = group.aeroclub {
                HStack(spacing: 6) {
                    Image(systemName: "building.2").font(.caption)
                    Text(aeroclub).font(.caption.weight(.semibold))
                }
                .foregroundColor(.aviationGold)
            }
            ForEach(group.aircraft) { aircraft in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(aircraft.registration)
                            .scaledFont(size: 15, weight: .semibold, design: .monospaced, relativeTo: .subheadline)
                            .foregroundColor(.primaryText)
                        if aircraft.isPremium {
                            Image(systemName: "star.fill").scaledFont(size: 9, relativeTo: .caption2).foregroundColor(.aviationGold)
                        }
                        Text(aircraft.modelName).font(.caption).foregroundColor(.secondaryText).lineLimit(1)
                        Spacer(minLength: 6)
                        HStack(spacing: 5) {
                            ForEach(aircraft.checklistLanguages, id: \.self) { LanguageFlagView(languageCode: $0) }
                        }
                    }
                    Text("\(L10n.Settings.version(aircraft.version)) · \(aircraft.lastUpdated)")
                        .font(.caption2).foregroundColor(.dimText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func groupCachedByAeroclub(_ aircraft: [CachedAircraftInfo]) -> [(aeroclub: String?, aircraft: [CachedAircraftInfo])] {
        Dictionary(grouping: aircraft) { $0.aeroclub }
            .map { (aeroclub: $0.key, aircraft: $0.value.sorted { $0.registration < $1.registration }) }
            .sorted { lhs, rhs in
                switch (lhs.aeroclub, rhs.aeroclub) {
                case (nil, nil): return false
                case (nil, _): return true
                case (_, nil): return false
                case (let a?, let b?): return a < b
                }
            }
    }

    private func syncChecklists() async {
        isSyncingChecklists = true
        await aircraftDataService.fetchAvailableAircraft()
        await aircraftDataService.syncBundledAircraft()
        // Premium checklists were never synced here at all — this button only ever refreshed the
        // BUNDLED aircraft, so on a fleet where one aircraft is bundled and thirteen are not it
        // appeared to do nothing. The language must be passed: checklists cache per language and
        // the key omitting it is not the one any reader looks up. (device-test feedback)
        await aircraftDataService.syncAllChecklists(
            language: appState.settings.checklistLanguage.resolvedLanguage
        )
        isSyncingChecklists = false
    }

    // MARK: - Actions

    private func refresh(_ dataSet: DataSet) async {
        refreshingIDs.insert(dataSet.id)
        await dataStatusManager.refresh(dataSet)
        refreshingIDs.remove(dataSet.id)
        recomputeSizes()
    }

    private func updateAll() async {
        // The gate still blocks Low Data Mode / offline (cellularUpdatesEnabled defaults to true until
        // PR 7's user toggle). Drive it per-dataset so each row shows its own spinner while refreshing.
        guard DataRefreshGate.allowsSilentSmallRefresh(dataStatusManager.networkMonitor.conditions, cellularUpdatesEnabled: true) else { return }
        isUpdatingAll = true
        let updatable = dataStatusManager.dataSets.filter { $0.refreshPolicy == .smallSilentJSON && $0.isDownloaded }
        for dataSet in updatable {
            refreshingIDs.insert(dataSet.id)
            await dataStatusManager.refresh(dataSet)
            refreshingIDs.remove(dataSet.id)
            recomputeSizes()
        }
        isUpdatingAll = false
    }

    // MARK: - Presentation helpers

    private func statusInfo(_ freshness: DataFreshness) -> (StatusIndicator.Status, String) {
        switch freshness {
        case .fresh: return (.active, L10n.DataStorage.statusFresh)
        case .aging: return (.warning, L10n.DataStorage.statusAging)
        case .stale: return (.error, L10n.DataStorage.statusStale)
        case .missing: return (.inactive, L10n.DataStorage.statusMissing)
        }
    }

    private func subtitle(for dataSet: DataSet, statusLabel: String) -> String {
        var parts = [statusLabel]
        if dataSet.isDownloaded, let lastUpdated = dataSet.lastUpdated {
            parts.append(L10n.DataStorage.asOf(Self.dateFormatter.string(from: lastUpdated)))
        }
        if dataSet.isDownloaded {
            let regions = dataSet.coverage.isEmpty ? L10n.DataStorage.coverageGlobal : dataSet.coverage.joined(separator: ", ")
            parts.append(L10n.DataStorage.coverage(regions))
        }
        return parts.joined(separator: " · ")
    }

    private func sizeString(for dataSet: DataSet) -> String? {
        guard let bytes = dataSet.sizeOnDisk ?? sizes[dataSet.id], bytes > 0 else { return nil }
        return Self.byteFormatter.string(fromByteCount: bytes)
    }

    private var totalSizeString: String {
        let total = dataStatusManager.dataSets.reduce(Int64(0)) { sum, dataSet in
            sum + (dataSet.sizeOnDisk ?? sizes[dataSet.id] ?? 0)
        }
        return Self.byteFormatter.string(fromByteCount: total)
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    // MARK: - On-disk size computation

    /// Maps a dataset id to the Application Support subdirectory the owning service caches into. Swiss
    /// charts carry their size in the descriptor (`cacheSizeBytes`), so they're not listed here.
    private static let directoryByDataSetID: [String: String] = [
        "openaip.airspace": "OpenAIPData",
        "openaip.navaids": "OpenAIPNavaidData",
        "openaip.obstacles": "OpenAIPObstacleData",
        "openaip.reportingpoints": "OpenAIPReportingPointData",
        "ourairports.airports": "AirportData",
    ]

    private func recomputeSizes() {
        // Cheap: reads file-size metadata (stat) for a handful of cached files, not their contents.
        var result: [String: Int64] = [:]
        for (id, dir) in Self.directoryByDataSetID {
            result[id] = Self.applicationSupportDirectorySize(named: dir)
        }
        sizes = result
    }

    private static func applicationSupportDirectorySize(named name: String) -> Int64 {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return 0 }
        let dir = base.appendingPathComponent(name, isDirectory: true)
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
