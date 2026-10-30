import SwiftUI

/// Settings › Data & Storage › Pilot's map (and Navigation & Maps): the regions on this device, each with its size,
/// build date and state, to update or delete; every other region by country on a page of its own, with a search; the
/// month's online allowance underneath. (6.8.0)
struct PilotMapSettingsSection: View {
    @ObservedObject var downloads: PilotMapDownloads
    var tint: Color = .aviationGreen

    @State private var pendingDelete: PilotMapRegion?

    var body: some View {
        SettingsGroup(title: L10n.PilotMap.section, tint: tint, footer: L10n.PilotMap.footer) {
            if downloads.regions.isEmpty && downloads.downloaded.isEmpty {
                Text(L10n.PilotMap.noRegions)
                    .font(.aero(.caption))
                    .foregroundColor(.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            }
            ForEach(onDevice) { region in
                PilotMapRegionRow(region: region, state: downloads.state(of: region.id),
                                  bytesToFetch: downloads.bytesToFetch(region), tint: tint,
                                  download: { downloads.download(region) },
                                  stop: { downloads.cancel(region.id) },
                                  delete: { pendingDelete = region })
            }
            // Every country zoomed out, offline: a row of its own (question 10). (6.8.0)
            if let overview = downloads.overview {
                PilotMapRegionRow(region: overview, state: downloads.state(of: overview.id),
                                  bytesToFetch: downloads.bytesToFetch(overview), tint: tint,
                                  download: { downloads.download(overview) },
                                  stop: { downloads.cancel(overview.id) },
                                  delete: { pendingDelete = overview })
            }
            if !downloads.regions.isEmpty {
                NavigationLink {
                    PilotMapRegionsPage(downloads: downloads, tint: tint)
                } label: {
                    HStack(spacing: 8) {
                        SettingsRowLabel(icon: "map", title: L10n.PilotMap.allRegions,
                                         subtitle: L10n.PilotMap.allRegionsDetail(downloads.regions.count), tint: tint)
                        Image(systemName: "chevron.right")
                            .font(.aero(size: 14, weight: .semibold))
                            .foregroundColor(.dimText)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pilotMap.allRegions")
            }
            allowanceRow
        }
        .task { await downloads.refreshIndex() }
        .alert(L10n.DataStorage.deleteConfirmTitle, isPresented: deleteBinding, presenting: pendingDelete) { region in
            Button(L10n.DataStorage.delete, role: .destructive) { downloads.delete(region.id) }
            Button(L10n.Button.cancel, role: .cancel) {}
        } message: { _ in
            Text(L10n.DataStorage.deleteConfirmMessage)
        }
    }

    /// The regions downloaded or downloading, the index's first, then any the index no longer lists (they still draw).
    private var onDevice: [PilotMapRegion] {
        let ids = Set(downloads.regions.map(\.id))
        let here = Set(downloads.downloaded.map(\.id))
        let listed = downloads.regions.filter { region in
            if here.contains(region.id) { return true }
            if case .downloading = downloads.state(of: region.id) { return true }
            return downloads.state(of: region.id) == .failed
        }
        return listed + downloads.downloaded.filter { !ids.contains($0.id) && $0.id != PilotMapRegion.overviewID }
    }

    private var allowanceRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.PilotMap.allowance(used: downloads.allowanceUsed, limit: downloads.allowanceLimit))
                .font(.aero(.caption))
                .foregroundColor(.secondaryText)
            switch downloads.allowanceLevel {
            case .open:
                EmptyView()
            case .nearLimit:
                Text(L10n.PilotMap.allowanceNear)
                    .font(.aero(.caption))
                    .foregroundColor(.aviationAmber)
            case .exhausted:
                Text(L10n.PilotMap.allowanceExhausted)
                    .font(.aero(.caption))
                    .foregroundColor(.aviationAmber)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}

/// Every region of the index by country, alphabetically in the app's language, with a search on the country's and the
/// region's names. A country of one region is that region's row; a larger one is its regions under its name. (6.8.0)
struct PilotMapRegionsPage: View {
    @ObservedObject var downloads: PilotMapDownloads
    var tint: Color = .aviationGreen
    @State private var search = ""
    @State private var pendingDelete: PilotMapRegion?

    struct Country: Identifiable {
        let id: String
        let name: String
        let regions: [PilotMapRegion]
    }

    static func countries(_ regions: [PilotMapRegion], search: String, locale: Locale = .current) -> [Country] {
        let grouped = Dictionary(grouping: regions) { $0.country ?? $0.id.uppercased() }
        let query = search.trimmingCharacters(in: .whitespaces)
        return grouped.map { code, regions in
            let name = regions.count == 1 ? regions[0].displayName
                : locale.localizedString(forRegionCode: code) ?? code
            let sorted = regions.sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
            guard !query.isEmpty, !Self.matches(name, query) else { return Country(id: code, name: name, regions: sorted) }
            return Country(id: code, name: name, regions: sorted.filter { Self.matches($0.displayName, query) })
        }
        .filter { !$0.regions.isEmpty }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    static func matches(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    var body: some View {
        SettingsPage {
            ForEach(Self.countries(downloads.regions, search: search)) { country in
                SettingsGroup(title: country.regions.count == 1 && country.name == country.regions[0].displayName
                              ? nil : country.name, tint: tint) {
                    ForEach(country.regions) { region in
                        PilotMapRegionRow(region: region, state: downloads.state(of: region.id),
                                          bytesToFetch: downloads.bytesToFetch(region), tint: tint,
                                          download: { downloads.download(region) },
                                          stop: { downloads.cancel(region.id) },
                                          delete: { pendingDelete = region })
                    }
                }
            }
        }
        .searchable(text: $search, prompt: L10n.PilotMap.searchRegions)
        .navigationTitle(L10n.PilotMap.allRegions)
        .navigationBarTitleDisplayMode(.inline)
        .alert(L10n.DataStorage.deleteConfirmTitle, isPresented: Binding(get: { pendingDelete != nil },
                                                                         set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { region in
            Button(L10n.DataStorage.delete, role: .destructive) { downloads.delete(region.id) }
            Button(L10n.Button.cancel, role: .cancel) {}
        } message: { _ in
            Text(L10n.DataStorage.deleteConfirmMessage)
        }
    }
}

/// One region: name, then its state, build date and size; the action at the end.
private struct PilotMapRegionRow: View {
    let region: PilotMapRegion
    let state: PilotMapDownloads.State
    let bytesToFetch: Int
    let tint: Color
    let download: () -> Void
    let stop: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(region.displayName)
                    .font(.aero(.subheadline))
                    .foregroundColor(.primaryText)
                Text(detail)
                    .font(.aero(.caption))
                    .foregroundColor(state == .failed ? .aviationRed : .secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if case let .downloading(fraction) = state {
                    ProgressView(value: fraction)
                        .tint(tint)
                        .accessibilityLabel(L10n.PilotMap.downloading(fraction))
                }
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var detail: String {
        var parts: [String] = []
        switch state {
        case .notDownloaded: parts.append(L10n.DataStorage.statusMissing)
        case let .downloading(fraction): parts.append(L10n.PilotMap.downloading(fraction))
        case .downloaded: parts.append(L10n.PilotMap.downloaded)
        case .updateAvailable: parts.append(L10n.PilotMap.updateAvailable)
        case .failed: parts.append(L10n.PilotMap.failed)
        }
        if let built = Self.date(region.built) { parts.append(L10n.DataStorage.asOf(built)) }
        // What is on the device, or what the tap would fetch (an update: only the archives rebuilt).
        let bytes: Int
        switch state {
        case .downloading: bytes = 0
        case .updateAvailable: bytes = bytesToFetch
        default: bytes = region.downloadBytes
        }
        if bytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .downloading:
            Button(action: stop) {
                Image(systemName: "stop.circle")
                    .scaledFont(size: 20, relativeTo: .title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .foregroundColor(.secondaryText)
            .accessibilityLabel(L10n.PilotMap.stop)
        case .notDownloaded, .failed:
            Button(L10n.PilotMap.download, action: download)
                .font(.aero(.subheadline).weight(.semibold))
                .foregroundColor(tint)
                .frame(minHeight: 44)
        case .downloaded, .updateAvailable:
            Menu {
                if state == .updateAvailable {
                    Button(action: download) { Label(L10n.PilotMap.update, systemImage: "arrow.triangle.2.circlepath") }
                }
                Button(role: .destructive, action: delete) { Label(L10n.DataStorage.delete, systemImage: "trash") }
            } label: {
                Image(systemName: state == .updateAvailable ? "arrow.down.circle" : "checkmark.circle")
                    .scaledFont(size: 20, relativeTo: .title3)
                    .foregroundColor(state == .updateAvailable ? tint : .secondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.DataStorage.rowActions)
        }
    }

    /// `yyyyMMdd` as the device writes a date.
    static func date(_ built: String) -> String? {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyyMMdd"
        guard let date = parser.date(from: built) else { return nil }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: TimeZone(identifier: "UTC")!))
    }
}
