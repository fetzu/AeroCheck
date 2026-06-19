import SwiftUI

/// Settings sub-page consolidating external-data currency + offline storage in one place (v4.1.0 Data
/// Freshness). Reads `DataStatusManager` for per-source status and dispatches refresh/delete back to it.
/// The scattered download buttons in Navigation & Maps will be relocated here in a follow-up.
struct DataStorageSettingsView: View {
    @EnvironmentObject private var dataStatusManager: DataStatusManager

    @State private var refreshingIDs: Set<String> = []
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
                SettingsGroup(title: L10n.DataStorage.aeronauticalSection, tint: tint, footer: L10n.DataStorage.caveat) {
                    ForEach(primaryDataSets) { dataRow($0) }
                }
            }
            if !imageryDataSets.isEmpty {
                SettingsGroup(title: L10n.DataStorage.chartsSection, tint: tint) {
                    ForEach(imageryDataSets) { dataRow($0) }
                }
            }
            storageSection
            attributionFooter
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
                        .font(.system(size: 18))
                        .foregroundColor(.secondaryText)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
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

    /// License-required OpenAIP attribution, with a tappable link (rendered from markdown). (v4.1.0)
    private var attributionFooter: some View {
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
        .padding(.top, 2)
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
