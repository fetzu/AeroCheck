import SwiftUI

/// Settings hub view with navigation to sub-pages
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// When presented as a custom overlay (HomeView's leading-edge slide-in), the host supplies a
    /// close action; otherwise `nil` and the standard `@Environment(\.dismiss)` is used. (v4 UI/UX Revamp)
    var onClose: (() -> Void)? = nil

    /// When set, the hub opens directly to this section (e.g. the Home data-status dot → Data & Storage). (v4.1.0)
    var initialSection: Section? = nil

    /// iPad two-column selection (defaults to the first section so the detail pane is never empty).
    @State private var selection: Section? = .aircraft
    /// iPhone push-navigation path.
    @State private var path: [Section] = []
    /// Guards `initialSection` so it seeds the selection once, not on every re-appear.
    @State private var didApplyInitialSection = false

    /// The settings sections. On iPad regular width `NavigationSplitView` shows them as a sidebar
    /// with the chosen section in the detail pane; on iPhone/compact it automatically collapses to
    /// the previous single-column push navigation. (UX-22)
    enum Section: Hashable, CaseIterable, Identifiable {
        case aircraft, checklist, navigation, flightPlanning, sync, dataStorage, companion, about
        var id: Self { self }

        var icon: String {
            switch self {
            case .aircraft: return "airplane"
            case .checklist: return "checklist"
            case .navigation: return "map"
            case .flightPlanning: return "point.topleft.down.to.point.bottomright.curvepath"
            case .sync: return "icloud"
            case .dataStorage: return "internaldrive"
            case .companion: return "ipad.and.iphone"
            case .about: return "info.circle"
            }
        }
        var title: String {
            switch self {
            case .aircraft: return L10n.Settings.aircraftAndSubscription
            case .checklist: return L10n.Settings.checklistAndFlight
            case .navigation: return L10n.Settings.navigationAndMaps
            case .flightPlanning: return L10n.Settings.flightPlanning
            case .sync: return L10n.Settings.syncAndData
            case .dataStorage: return L10n.DataStorage.title
            case .companion: return L10n.Settings.companionMode
            case .about: return L10n.Settings.about
            }
        }
        var subtitle: String {
            switch self {
            case .aircraft: return L10n.Settings.aircraftAndSubscriptionSubtitle
            case .checklist: return L10n.Settings.checklistAndFlightSubtitle
            case .navigation: return L10n.Settings.navigationAndMapsSubtitle
            case .flightPlanning: return L10n.Settings.flightPlanningSubtitle
            case .sync: return L10n.Settings.syncAndDataSubtitle
            case .dataStorage: return L10n.DataStorage.subtitle
            case .companion: return L10n.Settings.companionModeSubtitle
            case .about: return L10n.Settings.aboutSubtitle
            }
        }
        /// Per-section accent for the cockpit icon circle. (v4 UI/UX Revamp)
        var tint: Color {
            switch self {
            case .aircraft: return .aviationGold
            case .checklist: return .altimeterBlue
            case .navigation: return .aviationGreen
            case .flightPlanning: return .orange
            case .sync: return .altimeterBlue
            case .dataStorage: return .aviationGreen
            case .companion: return .aviationGold
            case .about: return .secondaryText
            }
        }
        /// Optional row badge (Beta on flight planning + companion mode).
        var badge: String? {
            switch self {
            case .companion: return L10n.Tag.beta
            default: return nil
            }
        }
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                // iPad: a FIXED two-column layout (sidebar + detail). Replaces NavigationSplitView so
                // the sidebar can't be collapsed. (v4 UI/UX Revamp — user feedback)
                HStack(spacing: 0) {
                    NavigationStack { sidebar(twoColumn: true) }
                        .frame(width: 340)
                    Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1).ignoresSafeArea()
                    NavigationStack {
                        detailView(for: selection)
                            .navigationBarTitleDisplayMode(.inline)
                    }
                    // Fresh stack per category so tapping a sidebar item always shows that category's
                    // content — without this, a pushed sub-page (e.g. OpenAIP Data) stayed on top and the
                    // user had to tap back first. (settings nav fix)
                    .id(selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Color.cockpitBackground.ignoresSafeArea())
            } else {
                // iPhone: single column. When opened via a deep link from Home (the data-status chip
                // sets initialSection), present that section as the NavigationStack ROOT with a Close
                // button, so dismissing returns to Home rather than the settings sidebar. (data-status nav fix)
                NavigationStack(path: $path) {
                    Group {
                        if let deepLink = initialSection {
                            detailView(for: deepLink)
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbar {
                                    ToolbarItem(placement: .cancellationAction) {
                                        Button(L10n.Settings.done) { if let onClose { onClose() } else { dismiss() } }
                                    }
                                }
                        } else {
                            sidebar(twoColumn: false)
                        }
                    }
                    .navigationDestination(for: Section.self) { detailView(for: $0) }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard !didApplyInitialSection, let initialSection else { return }
            didApplyInitialSection = true
            // iPad two-column uses `selection`; compact renders the deep-link as the stack ROOT (above),
            // so it must NOT also be pushed onto `path`. (data-status nav fix)
            selection = initialSection
        }
        // A Plus/Max iPhone flips compact↔regular when rotated, which swaps push-nav (`path`) for the
        // two-column `selection`. Bridge the two so you stay on the same section instead of snapping
        // back to the top. (iPad is always regular, so this is a no-op there.) (orientation audit)
        .onChange(of: horizontalSizeClass) { _, newClass in
            // A deep-link renders as the compact stack root and manages itself — don't bridge it onto
            // `path`, or a rotation would stack a second copy of the same section. (data-status nav fix)
            guard initialSection == nil else { return }
            if newClass == .regular {
                if let last = path.last { selection = last }
            } else if let sel = selection {
                path = [sel]
            }
        }
    }

    /// The section list. In two-column mode rows set `selection`; in compact mode they push via `path`.
    /// SettingsRow carries its own chevron, so no NavigationLink (which would add a second one). (v4 UI/UX Revamp)
    private func sidebar(twoColumn: Bool) -> some View {
        List {
            ForEach(Section.allCases) { section in
                Button {
                    if twoColumn { selection = section } else { path.append(section) }
                } label: {
                    SettingsRow(
                        icon: section.icon,
                        title: section.title,
                        subtitle: section.subtitle,
                        tint: section.tint,
                        badge: section.badge,
                        isSelected: twoColumn && section == selection
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.cockpitBackground.ignoresSafeArea())
        .navigationTitle(L10n.Settings.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Top-left, matching the app convention (Flight Log, flight-plan list). (v4 UI/UX Revamp)
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.Settings.done) { if let onClose { onClose() } else { dismiss() } }
            }
        }
    }


    @ViewBuilder
    private func detailView(for section: Section?) -> some View {
        switch section {
        case .aircraft: AircraftSettingsView()
        case .checklist: ChecklistFlightSettingsView()
        case .navigation: NavigationMapsSettingsView()
        case .flightPlanning: FlightPlanningSettingsView()
        case .sync: SyncDataSettingsView()
        case .dataStorage: DataStorageSettingsView()
        case .companion: CompanionSettingsView()
        case .about: AboutSettingsView()
        case nil:
            ContentUnavailableView(L10n.Settings.title, systemImage: "gearshape")
        }
    }
}

// MARK: - Flight Planning Warning Sheet

struct FlightPlanningWarningSheet: View {
    @Binding var isPresented: Bool
    @Binding var enableFlightPlanning: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "map.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.aviationAmber)
                    .padding(.top, 40)

                Text(L10n.Warning.betaFeature)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.primaryText)

                VStack(alignment: .leading, spacing: 16) {
                    WarningItem(icon: "exclamationmark.triangle.fill", text: L10n.Warning.flightPlanningBetaDesc)
                    WarningItem(icon: "map", text: L10n.Warning.flightPlanningPlanRoutes)
                    WarningItem(icon: "location.fill", text: L10n.Warning.flightPlanningAutoAdvance)
                    WarningItem(icon: "mountain.2.fill", text: L10n.Warning.flightPlanningTerrainViz)
                }
                .padding(.horizontal, 24)

                Spacer()

                VStack(spacing: 12) {
                    Button(action: {
                        enableFlightPlanning = true
                        isPresented = false
                    }) {
                        Text(L10n.Warning.iUnderstandEnable)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.aviationAmber)
                            )
                    }
                    .padding(.horizontal, 24)

                    Button(action: { isPresented = false }) {
                        Text(L10n.Warning.cancel)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.secondaryText)
                    }
                }
                .padding(.bottom, 40)
            }
            .background(Color.cockpitBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.cancel) { isPresented = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Estimated Airspeed Warning Sheet

struct EstimatedAirspeedWarningSheet: View {
    @Binding var isPresented: Bool
    @Binding var showEstimatedAirspeed: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.aviationAmber)
                    .padding(.top, 40)

                Text(L10n.Warning.experimentalFeature)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.primaryText)

                VStack(alignment: .leading, spacing: 16) {
                    WarningItem(icon: "airplane", text: L10n.Warning.estimatedAirspeedCalculated)
                    WarningItem(icon: "exclamationmark.circle.fill", text: L10n.Warning.estimatedAirspeedInaccurate)
                    WarningItem(icon: "gauge.with.needle", text: L10n.Warning.estimatedAirspeedAlwaysRelyOnboard)
                    WarningItem(icon: "network", text: L10n.Warning.estimatedAirspeedRequiresCellular)
                }
                .padding(.horizontal, 24)

                Spacer()

                VStack(spacing: 12) {
                    Button(action: {
                        showEstimatedAirspeed = true
                        isPresented = false
                    }) {
                        Text(L10n.Warning.iUnderstandEnable)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.aviationAmber)
                            )
                    }
                    .padding(.horizontal, 24)

                    Button(action: { isPresented = false }) {
                        Text(L10n.Warning.cancel)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.secondaryText)
                    }
                }
                .padding(.bottom, 40)
            }
            .background(Color.cockpitBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.cancel) { isPresented = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Airspace Streaming Warning Sheet

struct AirspaceStreamingWarningSheet: View {
    @Binding var isPresented: Bool
    @Binding var enableAirspaceStreaming: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 60))
                    .foregroundColor(.aviationAmber)
                    .padding(.top, 40)

                Text(L10n.Warning.onlineAirspaceTitle)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.primaryText)

                VStack(alignment: .leading, spacing: 16) {
                    WarningItem(icon: "wifi", text: L10n.Warning.onlineAirspaceRequiresInternet)
                    WarningItem(icon: "antenna.radiowaves.left.and.right", text: L10n.Warning.onlineAirspaceFetches)
                    WarningItem(icon: "arrow.down.circle", text: L10n.Warning.onlineAirspaceDownloadRecommended)
                }
                .padding(.horizontal, 24)

                Spacer()

                VStack(spacing: 12) {
                    Button(action: {
                        enableAirspaceStreaming = true
                        isPresented = false
                    }) {
                        Text(L10n.Warning.iUnderstandEnable)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.aviationAmber)
                            )
                    }
                    .padding(.horizontal, 24)

                    Button(action: { isPresented = false }) {
                        Text(L10n.Warning.cancel)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.secondaryText)
                    }
                }
                .padding(.bottom, 40)
            }
            .background(Color.cockpitBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.cancel) { isPresented = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct WarningItem: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.aviationAmber)
                .frame(width: 24)

            Text(text)
                .font(.system(size: 15))
                .foregroundColor(.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Offline Map Download Sheet

struct OfflineMapDownloadSheet: View {
    @EnvironmentObject var offlineMapManager: OfflineMapManager
    @Environment(\.dismiss) var dismiss
    @Binding var offlineMode: Bool
    /// When true, rendered as a pushed page (parent supplies the nav bar + back); else as a sheet.
    var asPage: Bool = false
    @State private var selectedCacheOption: CacheOption = .icaoOnly

    private func storageEstimate(for option: CacheOption) -> String {
        switch option {
        case .icaoOnly: return "~100 MB"
        case .icaoAndSegelflug: return "~250 MB"
        }
    }

    var body: some View {
        Group {
            if asPage {
                sheetContent
            } else {
                NavigationStack {
                    sheetContent
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                if !offlineMapManager.isDownloading {
                                    Button(L10n.Button.cancel) {
                                        if !offlineMapManager.isCacheAvailable { offlineMode = false }
                                        dismiss()
                                    }
                                }
                            }
                        }
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(offlineMapManager.isDownloading)
        .onAppear {
            if offlineMapManager.isCacheAvailable && !offlineMapManager.isSegelflugCacheAvailable {
                selectedCacheOption = .icaoAndSegelflug
            }
        }
        .onDisappear {
            // As a pushed page, backing out without a cache reverts Offline Mode (mirrors the sheet's Cancel).
            if asPage && !offlineMapManager.isDownloading && !offlineMapManager.isCacheAvailable {
                offlineMode = false
            }
        }
    }

    private var sheetContent: some View {
        VStack(spacing: 20) {
                Image(systemName: "map.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.aviationGold)
                    .padding(.top, 24)

                Text(L10n.Settings.downloadCharts)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.primaryText)

                Text(L10n.Download.description)
                    .font(.system(size: 14))
                    .foregroundColor(.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if !offlineMapManager.isDownloading {
                    VStack(spacing: 12) {
                        Text(L10n.Download.selectCharts)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondaryText)

                        ForEach(CacheOption.allCases) { option in
                            CacheOptionRow(
                                option: option,
                                storageEstimate: storageEstimate(for: option),
                                isSelected: selectedCacheOption == option,
                                isAlreadyCached: isCached(option)
                            ) {
                                selectedCacheOption = option
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }

                Spacer()

                if offlineMapManager.isDownloading {
                    VStack(spacing: 12) {
                        ProgressView(value: offlineMapManager.downloadProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .aviationGold))
                            .padding(.horizontal, 40)

                        if let layer = offlineMapManager.currentDownloadingLayer {
                            Text(L10n.Download.downloadingLayer(layer.displayName))
                                .font(.system(size: 14))
                                .foregroundColor(.secondaryText)
                        } else {
                            Text(L10n.Download.downloadingTiles)
                                .font(.system(size: 14))
                                .foregroundColor(.secondaryText)
                        }

                        Text("\(offlineMapManager.downloadedTileCount) / \(offlineMapManager.totalTileCount)")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.secondaryText)

                        if let eta = offlineMapManager.estimatedTimeRemaining, eta > 0 {
                            Text(L10n.Download.estimatedTimeRemaining(formattedTimeRemaining(eta)))
                                .font(.system(size: 13))
                                .foregroundColor(.dimText)
                        }

                        // PERF-23: surface server rate-limiting so a throttled (HTTP 429)
                        // download isn't mistaken for ordinary slowness or tile failures.
                        if offlineMapManager.downloadWasThrottled {
                            Label(L10n.Download.throttled, systemImage: "clock.badge.exclamationmark")
                                .font(.system(size: 12))
                                .foregroundColor(.aviationGold)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }
                    }
                } else if let error = offlineMapManager.downloadError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.aviationRed)

                        Text(error)
                            .font(.system(size: 13))
                            .foregroundColor(.aviationRed)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }

                if !offlineMapManager.isDownloading && (offlineMapManager.isCacheAvailable || offlineMapManager.isSegelflugCacheAvailable) {
                    VStack(spacing: 8) {
                        HStack(spacing: 16) {
                            if offlineMapManager.isCacheAvailable {
                                CacheStatusBadge(name: "ICAO", isAvailable: true)
                            }
                            if offlineMapManager.isSegelflugCacheAvailable {
                                CacheStatusBadge(name: "Segelflug", isAvailable: true)
                            }
                        }
                        Text(L10n.Download.total(offlineMapManager.formattedCacheSize))
                            .font(.system(size: 12))
                            .foregroundColor(.dimText)
                    }
                }

                Spacer()

                VStack(spacing: 12) {
                    if offlineMapManager.isDownloading {
                        // No action button while downloading
                    } else {
                        Button(action: startDownload) {
                            Text(downloadButtonText)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.aviationGold)
                                )
                        }
                        .padding(.horizontal, 24)

                        if offlineMapManager.isCacheAvailable || offlineMapManager.isSegelflugCacheAvailable {
                            Button(action: { dismiss() }) {
                                Text("Done")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.secondaryText)
                            }
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .background(Color.cockpitBackground)
            .navigationTitle(L10n.Settings.downloadCharts)
            .navigationBarTitleDisplayMode(.inline)
    }

    private var downloadButtonText: String {
        if offlineMapManager.isCacheAvailable && offlineMapManager.isSegelflugCacheAvailable {
            return "Re-download Charts"
        } else if offlineMapManager.isCacheAvailable && selectedCacheOption == .icaoAndSegelflug {
            return "Download Segelflugkarte"
        } else {
            return "Download \(selectedCacheOption.displayName)"
        }
    }

    private func isCached(_ option: CacheOption) -> Bool {
        switch option {
        case .icaoOnly:
            return offlineMapManager.isCacheAvailable
        case .icaoAndSegelflug:
            return offlineMapManager.isCacheAvailable && offlineMapManager.isSegelflugCacheAvailable
        }
    }

    private func startDownload() {
        Task { await offlineMapManager.downloadCharts(option: selectedCacheOption) }
    }

    private func formattedTimeRemaining(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
}

// MARK: - Cache Option Row

struct CacheOptionRow: View {
    let option: CacheOption
    let storageEstimate: String
    let isSelected: Bool
    let isAlreadyCached: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(option.displayName)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.primaryText)
                        if isAlreadyCached {
                            Text("CACHED")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.aviationGreen)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.aviationGreen.opacity(0.2))
                                )
                        }
                    }
                    Text(storageEstimate)
                        .font(.system(size: 12))
                        .foregroundColor(.dimText)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(isSelected ? .aviationGold : .dimText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.aviationGold.opacity(0.1) : Color.panelBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? Color.aviationGold : Color.clear, lineWidth: 1)
                    )
            )
        }
    }
}

// MARK: - Cache Status Badge

struct CacheStatusBadge: View {
    let name: String
    let isAvailable: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                .font(.system(size: 12))
            Text(name)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(isAvailable ? .aviationGreen : .dimText)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isAvailable ? Color.aviationGreen.opacity(0.15) : Color.panelBackground)
        )
    }
}

// MARK: - Transaction Debug View

struct TransactionDebugView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) var dismiss
    @State private var transactions: [TransactionDebugInfo] = []
    @State private var isLoading = true
    @State private var currentAccountType: String = "Unknown"

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Loading transactions...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if transactions.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        Text("No Transactions Found")
                            .font(.headline)
                        Text("This could mean:\n• You're not signed into an Apple ID\n• No subscriptions have been purchased\n• Testing with StoreKit Configuration file")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                } else {
                    List {
                        Section {
                            HStack {
                                Text("Total Transactions")
                                Spacer()
                                Text("\(transactions.count)")
                                    .foregroundColor(.secondary)
                            }
                            HStack {
                                Text("Active Subscriptions")
                                Spacer()
                                Text("\(transactions.filter { $0.isActive }.count)")
                                    .foregroundColor(transactions.filter { $0.isActive }.count > 0 ? .green : .secondary)
                            }
                            HStack {
                                Text("Account Type")
                                Spacer()
                                Text(currentAccountType)
                                    .foregroundColor(.secondary)
                            }
                        } header: {
                            Text("Summary")
                        }

                        Section {
                            ForEach(transactions) { transaction in
                                TransactionDebugRow(transaction: transaction)
                            }
                        } header: {
                            Text("All Transactions")
                        }
                    }
                }
            }
            .navigationTitle("Transaction Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.close) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        Task { await loadTransactions() }
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .task { await loadTransactions() }
        }
        .preferredColorScheme(.dark)
    }

    private func loadTransactions() async {
        isLoading = true
        transactions = await subscriptionManager.getAllTransactions()
        if let firstTransaction = transactions.first {
            currentAccountType = firstTransaction.environmentText
        } else {
            currentAccountType = "No Transactions"
        }
        isLoading = false
    }
}

struct TransactionDebugRow: View {
    let transaction: TransactionDebugInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(transaction.productID)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                Spacer()
                Text(transaction.statusText)
                    .font(.caption)
                    .fontWeight(.medium)
            }

            HStack {
                Text("Environment")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(transaction.environmentText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Purchased")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(transaction.purchaseDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let expirationDate = transaction.expirationDate {
                HStack {
                    Text("Expires")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(expirationDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundColor(transaction.isActive ? .green : .red)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Transaction ID")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(transaction.id)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Text("Original ID")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(transaction.originalID)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let error = transaction.verificationError {
                Text("Verification Error: \(error)")
                    .font(.caption2)
                    .foregroundColor(.red)
                    .padding(.top, 4)
            }

            if let revocationDate = transaction.revocationDate {
                Text("Revoked on \(revocationDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundColor(.red)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Subscription Debug Log View

struct SubscriptionDebugLogView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) var dismiss
    @ObservedObject var debugLogger: SubscriptionDebugLogger

    var body: some View {
        NavigationStack {
            Group {
                if debugLogger.logs.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        Text("No Logs Yet")
                            .font(.headline)
                        Text("Logs will appear here when you sync with the server or perform subscription operations.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                } else {
                    List {
                        ForEach(debugLogger.logs) { log in
                            DebugLogRow(log: log)
                        }
                    }
                }
            }
            .navigationTitle("Subscription Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.close) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { debugLogger.clear() }) {
                        Image(systemName: "trash")
                    }
                    .disabled(debugLogger.logs.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct DebugLogRow: View {
    let log: DebugLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(log.level.emoji)
                    .font(.body)
                Text(log.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }

            Text(log.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(colorForLevel(log.level))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private func colorForLevel(_ level: LogLevel) -> Color {
        switch level {
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environmentObject(AppState())
        .environmentObject(LocationManager())
        .environmentObject(OfflineMapManager())
}

// MARK: - Premium Aircraft List

/// View displaying all premium aircraft available from the API
struct PremiumAircraftListView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var aircraftDataService: AircraftDataService
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) var dismiss
    @State private var showLocalSubscriptionView = false

    var premiumAircraft: [RemoteAircraftMetadata] {
        aircraftDataService.availableAircraft.filter { !$0.isFree }
    }

    var aircraftByAeroclub: [(aeroclub: String, aircraft: [RemoteAircraftMetadata])] {
        let grouped = Dictionary(grouping: premiumAircraft) { $0.aeroclub ?? "" }
        return grouped
            .map { (aeroclub: $0.key, aircraft: $0.value.sorted { $0.registration < $1.registration }) }
            .sorted { $0.aeroclub < $1.aeroclub }
    }

    var body: some View {
        List {
            if aircraftDataService.isLoading {
                HStack {
                    Spacer()
                    VStack(spacing: 16) {
                        ProgressView()
                        Text(L10n.Premium.loadingAircraft)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if premiumAircraft.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "airplane.circle")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    Text(L10n.Premium.noAircraftAvailable)
                        .font(.headline)
                    Text(L10n.Premium.checkBackLater)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
            } else {
                ForEach(aircraftByAeroclub, id: \.aeroclub) { group in
                    Section {
                        ForEach(group.aircraft) { aircraft in
                            PremiumAircraftRow(
                                aircraft: aircraft,
                                isSelected: appState.settings.selectedRemoteAircraftId == aircraft.id,
                                onSelect: {
                                    if aircraft.hasAccess {
                                        // UX-14: route through the unified selection path (persists to
                                        // file + iCloud and reconciles the active checklist) instead of
                                        // a direct mutation + a dead UserDefaults write that was never
                                        // read — so a premium aircraft chosen here survives relaunch.
                                        appState.selectAircraft(id: aircraft.id, available: aircraftDataService.availableAircraft)
                                        Task {
                                            _ = await aircraftDataService.fetchChecklist(for: aircraft.id)
                                        }
                                        dismiss()
                                    } else {
                                        // Show subscription view directly from this view
                                        // instead of dismiss + delay + parent binding (which was fragile)
                                        showLocalSubscriptionView = true
                                    }
                                }
                            )
                        }
                    } header: {
                        if !group.aeroclub.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "building.2")
                                    .font(.caption)
                                Text(group.aeroclub)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.cockpitBackground.ignoresSafeArea())
        .navigationTitle(L10n.Settings.premiumAircrafts)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .onAppear {
            Task { await aircraftDataService.fetchAvailableAircraft() }
        }
        .sheet(isPresented: $showLocalSubscriptionView) {
            SubscriptionView()
                .environmentObject(subscriptionManager)
        }
        .onChange(of: subscriptionManager.subscriptionStatus) { _, newValue in
            // When subscription becomes active, refresh the aircraft list to update hasAccess
            if newValue.isSubscribed {
                Task { await aircraftDataService.fetchAvailableAircraft() }
            }
        }
    }
}

struct PremiumAircraftRow: View {
    let aircraft: RemoteAircraftMetadata
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(aircraft.hasAccess ? Color.aviationGold.opacity(0.2) : Color.secondary.opacity(0.2))
                        .frame(width: 50, height: 50)

                    Image(systemName: aircraft.hasAccess ? "airplane.circle.fill" : "lock.fill")
                        .font(.system(size: 24))
                        .foregroundColor(aircraft.hasAccess ? .aviationGold : .secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(aircraft.registration)
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)

                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundColor(.aviationGold)
                    }

                    Text(aircraft.shortModelName)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if !aircraft.hasAccess {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10))
                            Text(L10n.Premium.requiresAeroCheckPro)
                                .font(.system(size: 11))
                        }
                        .foregroundColor(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    ForEach(aircraft.checklistLanguages, id: \.self) { languageCode in
                        LanguageFlagView(languageCode: languageCode)
                    }
                }

                if isSelected && aircraft.hasAccess {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.aviationGold)
                }
            }
            .padding(.vertical, 8)
        }
        .opacity(aircraft.hasAccess ? 1.0 : 0.7)
    }
}

/// A view that displays a language flag indicator
struct LanguageFlagView: View {
    let languageCode: String

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 28, height: 28)

            Text(flagEmoji)
                .font(.system(size: 16))
        }
    }

    private var flagEmoji: String {
        switch languageCode {
        case "en": return "\u{1F1EC}\u{1F1E7}"
        case "fr": return "\u{1F1EB}\u{1F1F7}"
        case "de": return "\u{1F1E9}\u{1F1EA}"
        case "it": return "\u{1F1EE}\u{1F1F9}"
        default: return "\u{1F3F3}\u{FE0F}"
        }
    }
}

#Preview("Premium Aircraft List") {
    let subManager = SubscriptionManager()
    NavigationStack {
        PremiumAircraftListView()
            .environmentObject(AppState())
            .environmentObject(AircraftDataService(subscriptionManager: subManager))
            .environmentObject(subManager)
    }
}
