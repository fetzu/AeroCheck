import SwiftUI

/// Settings hub view with navigation to sub-pages
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// When presented as a custom overlay (HomeView's leading-edge slide-in), the host supplies a
    /// close action; otherwise `nil` and the standard `@Environment(\.dismiss)` is used. (v4 UI/UX Revamp)
    var onClose: (() -> Void)? = nil

    /// When set, the hub opens directly to this section (e.g. the Home data-status dot → Data & Storage). (v4.1.0)
    var initialSection: Section? = nil
    /// The Settings tab: no Done button, and a page requested elsewhere (`pendingSettingsSection`, the
    /// Data chip on Today) opens when the tab shows. (v6.0 · P1)
    var isEmbedded: Bool = false
    /// The iPad's Settings tab: the ground's tab bar is drawn here, over the two columns. (6.5.0)
    @Environment(\.ownsGroundTabBar) private var ownsGroundTabBar

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
        // Navigation & Maps went into Offline data in 6.8.0: its downloads by country, its two connection switches,
        // and the map's layers left to the Map sheet (the author's answer 14 A, 30 Oct 2026).
        case aircraft, checklist, dataStorage, flightPlanning, sync, companion, about
        var id: Self { self }

        var icon: String {
            switch self {
            case .aircraft: return "airplane"
            case .checklist: return "checklist"
            case .flightPlanning: return "point.topleft.down.to.point.bottomright.curvepath"
            case .sync: return "icloud"
            case .dataStorage: return "arrow.down.circle"
            case .companion: return "ipad.and.iphone"
            case .about: return "info.circle"
            }
        }
        var title: String {
            switch self {
            case .aircraft: return L10n.Settings.aircraftAndSubscription
            case .checklist: return L10n.Settings.checklistAndFlight
            // The page's own name: it holds the pilot, the home aerodrome and the cost as well as the planning.
            // (6.4.0)
            case .flightPlanning: return L10n.Flights.title
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
                VStack(spacing: 0) {
                    // The ground's tab bar over both columns, where the system's sat. (6.5.0)
                    if isEmbedded && ownsGroundTabBar { GroundTabBar() }
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
                                        Button(L10n.Button.close) { if let onClose { onClose() } else { dismiss() } }
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
        // Only as its own cover. Embedded in a ground tab, a preferred scheme would darken the whole
        // window, and the root could no longer read the device's light/dark for Auto. (v6.0 · P1)
        .preferredColorScheme(isEmbedded ? nil : .dark)
        .onAppear { openPendingSection() }
        .onChange(of: appState.pendingSettingsSection) { _, _ in openPendingSection() }
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
            if !isEmbedded {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.close) { if let onClose { onClose() } else { dismiss() } }
                }
            }
        }
    }

    /// Open the page another screen asked for, then forget the request.
    private func openPendingSection() {
        guard isEmbedded, let section = appState.pendingSettingsSection else { return }
        appState.pendingSettingsSection = nil
        if horizontalSizeClass == .regular { selection = section } else { path = [section] }
    }


    @ViewBuilder
    private func detailView(for section: Section?) -> some View {
        switch section {
        case .aircraft: AircraftSettingsView()
        case .checklist: ChecklistFlightSettingsView()
        case .flightPlanning: FlightPlanningSettingsView()
        case .sync: SyncDataSettingsView()
        case .dataStorage: OfflineDataSettingsView()
        case .companion: CompanionSettingsView()
        case .about: AboutSettingsView()
        case nil:
            ContentUnavailableView(L10n.Settings.title, systemImage: "gearshape")
        }
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
                    .scaledFont(size: 60, relativeTo: .largeTitle)
                    .foregroundColor(.aviationAmber)
                    .padding(.top, 40)

                Text(L10n.Warning.onlineAirspaceTitle)
                    .scaledFont(size: 24, weight: .bold, relativeTo: .title2)
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
                            .scaledFont(size: 17, weight: .semibold, relativeTo: .body)
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.aviationAmber)
                            )
                    }
                    .padding(.horizontal, 24)
                    // One Cancel, the toolbar's, on the left: a second one here until 6.6.0
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
                .scaledFont(size: 20, relativeTo: .title3)
                .foregroundColor(.aviationAmber)
                .frame(width: 24)

            Text(text)
                .scaledFont(size: 15, relativeTo: .subheadline)
                .foregroundColor(.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                            .font(.aero(.caption))
                            .foregroundColor(.secondary)
                    }
                } else if transactions.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .scaledFont(size: 60, relativeTo: .largeTitle)
                            .foregroundColor(.secondary)
                        Text("No Transactions Found")
                            .font(.aero(.headline))
                        Text("This could mean:\n• You're not signed into an Apple ID\n• No subscriptions have been purchased\n• Testing with StoreKit Configuration file")
                            .font(.aero(.caption))
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
                    .font(.aero(.body, design: .monospaced))
                    .fontWeight(.semibold)
                Spacer()
                Text(transaction.statusText)
                    .font(.aero(.caption))
                    .fontWeight(.medium)
            }

            HStack {
                Text("Environment")
                    .font(.aero(.caption))
                    .foregroundColor(.secondary)
                Spacer()
                Text(transaction.environmentText)
                    .font(.aero(.caption))
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Purchased")
                    .font(.aero(.caption))
                    .foregroundColor(.secondary)
                Spacer()
                Text(transaction.purchaseDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.aero(.caption))
                    .foregroundColor(.secondary)
            }

            if let expirationDate = transaction.expirationDate {
                HStack {
                    Text("Expires")
                        .font(.aero(.caption))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(expirationDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.aero(.caption))
                        .foregroundColor(transaction.isActive ? .green : .red)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Transaction ID")
                        .font(.aero(.caption2))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(transaction.displayedID)
                        .scaledFont(size: 10, design: .monospaced, relativeTo: .caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // SEC-C3: the Original ID is the Apple originalTransactionId, which was until
                // recently the API's entire bearer credential — and this screen is reachable in a
                // RELEASE build (five taps on the version row). Printing it verbatim meant a
                // subscriber could read out a string that unlocked the whole premium catalogue for
                // anyone, on unlimited devices. It stays available for debugging, redacted to a
                // suffix that is still enough to correlate with a server log line. The row above
                // is redacted too: for a lifetime purchase it is the same value. (S9-39)
                HStack {
                    Text("Original ID")
                        .font(.aero(.caption2))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(transaction.displayedOriginalID)
                        .scaledFont(size: 10, design: .monospaced, relativeTo: .caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let error = transaction.verificationError {
                Text("Verification Error: \(error)")
                    .font(.aero(.caption2))
                    .foregroundColor(.red)
                    .padding(.top, 4)
            }

            if let revocationDate = transaction.revocationDate {
                Text("Revoked on \(revocationDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.aero(.caption2))
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
                            .scaledFont(size: 60, relativeTo: .largeTitle)
                            .foregroundColor(.secondary)
                        Text("No Logs Yet")
                            .font(.aero(.headline))
                        Text("Logs will appear here when you sync with the server or perform subscription operations.")
                            .font(.aero(.caption))
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
                    .font(.aero(.body))
                Text(log.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.aero(.caption))
                    .foregroundColor(.secondary)
                Spacer()
            }

            Text(log.message)
                .font(.aero(.caption, design: .monospaced))
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
        .environment(AppState())
        .environmentObject(LocationManager())
        .environmentObject(OfflineMapManager())
}

// MARK: - Premium Aircraft List

/// View displaying all premium aircraft available from the API
struct PremiumAircraftListView: View {
    @Environment(AppState.self) private var appState
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
                            .font(.aero(.caption))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if premiumAircraft.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "airplane.circle")
                        .scaledFont(size: 60, relativeTo: .largeTitle)
                        .foregroundColor(.secondary)
                    Text(L10n.Premium.noAircraftAvailable)
                        .font(.aero(.headline))
                    Text(L10n.Premium.checkBackLater)
                        .font(.aero(.caption))
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
                                canFly: aircraftDataService.canFly(aircraft),
                                isSelected: appState.settings.selectedRemoteAircraftId == aircraft.id,
                                onSelect: {
                                    // The same rule as the Aircraft tab and START FLIGHT: Pro active
                                    // on the server AND on this device. (on-device review #4, point 1)
                                    if aircraftDataService.canFly(aircraft) {
                                        // UX-14: route through the unified selection path (persists to
                                        // file + iCloud and reconciles the active checklist) instead of
                                        // a direct mutation + a dead UserDefaults write that was never
                                        // read — so a premium aircraft chosen here survives relaunch.
                                        appState.selectAircraft(id: aircraft.id, available: aircraftDataService.availableAircraft)
                                        Task {
                                            // Language matters: the cache key is
                                            // "<id>_<language>", and that is what the checklist
                                            // readers look up. Omitting it warmed an entry the
                                            // app never displays.
                                            _ = await aircraftDataService.fetchChecklist(
                                                for: aircraft.id,
                                                language: appState.settings.checklistLanguage.resolvedLanguage
                                            )
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
                                    .font(.aero(.caption))
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
        // Pushed, never presented: it inherits the app's dark environment. A preferred scheme here
        // would darken the whole window from inside the Aircraft tab. (v6.0 · P1)
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
    /// `AircraftDataService.canFly(aircraft)`: whether the row offers the aircraft or the plans.
    let canFly: Bool
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(canFly ? Color.aviationGold.opacity(0.2) : Color.secondary.opacity(0.2))
                        .frame(width: 50, height: 50)

                    Image(systemName: canFly ? "airplane.circle.fill" : "lock.fill")
                        .scaledFont(size: 24, relativeTo: .title2)
                        .foregroundColor(canFly ? .aviationGold : .secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(aircraft.registration)
                            .font(.aero(.body, design: .monospaced))
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)

                        Image(systemName: "star.fill")
                            .font(.aero(.caption))
                            .foregroundColor(.aviationGold)
                    }

                    Text(aircraft.shortModelName)
                        .font(.aero(.caption))
                        .foregroundColor(.secondary)

                    if !canFly {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .scaledFont(size: 10, relativeTo: .caption2)
                            Text(L10n.Premium.requiresAeroCheckPro)
                                .scaledFont(size: 11, relativeTo: .caption2)
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

                if isSelected && canFly {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.aero(.title3))
                        .foregroundColor(.aviationGold)
                }
            }
            .padding(.vertical, 8)
        }
        .opacity(canFly ? 1.0 : 0.7)
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
                .scaledFont(size: 16, relativeTo: .body)
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
            .environment(AppState())
            .environmentObject(AircraftDataService(subscriptionManager: subManager))
            .environmentObject(subManager)
    }
}
