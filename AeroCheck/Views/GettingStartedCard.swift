import SwiftUI

// MARK: - Getting started (6.8.0)

/// What onboarding leaves for later, on Today: up to six items that tick themselves off, the card gone once all are
/// done, once a real flight is in the logbook, or when the pilot hides it (the author's answers 7 A on the onboarding page,
/// 31 Oct 2026, and t05, 6 Nov 2026). A ticked row stays ticked, and a card that went doesn't come back. Only after the
/// new onboarding: a pilot who set the app up before 6.8.0 never sees it. Device-local.
enum GettingStarted {

    /// Set when onboarding ends; the card shows from then on.
    nonisolated static let offeredKey = "gettingStarted.offered"
    /// Hide pressed, or a real flight logged: gone for good on this device.
    nonisolated static let hiddenKey = "gettingStarted.hidden"
    /// The rows once done, comma-separated.
    nonisolated static let tickedKey = "gettingStarted.ticked"
    /// The Pro aircraft chosen in onboarding without Pro: its row offers the trial (the author's answer p1 B).
    nonisolated static let proAircraftKey = "gettingStarted.proAircraft"
    /// The first flight flown to its end page.
    nonisolated static let firstFlightFlownKey = "dryRun.firstFlightFlown"

    enum Item: String, CaseIterable, Identifiable {
        case base, offline, firstFlight, pro, route, dryRun
        var id: Self { self }
    }

    /// What the card reads, so its rule can be tested without the app.
    struct Status: Equatable {
        var hasHome = false
        var offlineDone = false
        var firstFlightFlown = false
        /// The Pro aircraft named in onboarding; nil: no Pro row.
        var proAircraft: String?
        var hasPro = false
        var hasRoute = false
        var dryRunFlown = false
    }

    /// The card's rows in order, each with whether it is done, or was. The Pro row only when onboarding named a Pro aircraft.
    static func items(_ status: Status, ticked: Set<Item> = []) -> [(item: Item, done: Bool)] {
        Item.allCases.compactMap { item in
            let done: Bool
            switch item {
            case .base: done = status.hasHome
            case .offline: done = status.offlineDone
            case .firstFlight: done = status.firstFlightFlown
            case .pro:
                guard status.proAircraft != nil else { return nil }
                done = status.hasPro
            case .route: done = status.hasRoute
            case .dryRun: done = status.dryRunFlown
            }
            return (item, done || ticked.contains(item))
        }
    }

    /// Shown: offered by onboarding, not hidden, something left to do.
    static func isShown(offered: Bool, hidden: Bool, status: Status, ticked: Set<Item> = []) -> Bool {
        offered && !hidden && items(status, ticked: ticked).contains { !$0.done }
    }

    /// The stored rows, as written by `ticks`.
    static func ticked(from stored: String) -> Set<Item> {
        Set(stored.split(separator: ",").compactMap { Item(rawValue: String($0)) })
    }

    static func ticks(_ items: [(item: Item, done: Bool)]) -> String {
        items.filter(\.done).map(\.item.rawValue).sorted().joined(separator: ",")
    }

    /// A real flight is in the logbook: the pilot has got started.
    static func retire(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: hiddenKey)
    }

    /// Onboarding's end: the card from now on, and the Pro aircraft its row names.
    static func begin(proAircraft: String?, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: offeredKey)
        defaults.set(proAircraft, forKey: proAircraftKey)
    }
}

/// Today's Getting started card. Each open row goes where its thing is done; a done row is ticked and does nothing.
struct GettingStartedCard: View {
    let isCompact: Bool
    @Environment(AppState.self) private var appState
    @EnvironmentObject private var flightPlanManager: FlightPlanManager
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @EnvironmentObject private var openAIPDataService: OpenAIPDataService
    @ObservedObject private var pilotMap = PilotMapDownloads.shared
    @AppStorage(GettingStarted.offeredKey) private var offered = false
    @AppStorage(GettingStarted.hiddenKey) private var hidden = false
    @AppStorage(GettingStarted.tickedKey) private var storedTicks = ""
    @AppStorage(GettingStarted.proAircraftKey) private var proAircraft: String?
    @AppStorage(GettingStarted.firstFlightFlownKey) private var firstFlightFlown = false
    @AppStorage(DryRunCenter.guidedFlownKey) private var dryRunFlown = false

    /// The home country, whole, as onboarding offered it.
    private var homeCountry: OfflineCountry? {
        guard let code = OfflineCountryCatalog.home(homeIdent: appState.settings.homeAerodromeIdent) else { return nil }
        return OfflineCountryCatalog.country(code, atlasRegions: pilotMap.regions,
                                             vfrCountries: Set(OFMDataService.shared.supportedCountries))
    }

    private var status: GettingStarted.Status {
        let home = appState.settings.homeAerodromeIdent?.trimmingCharacters(in: .whitespaces) ?? ""
        return GettingStarted.Status(
            hasHome: !home.isEmpty,
            offlineDone: homeCountry.map {
                OfflineCountryCatalog.isOnDevice($0, pilotMap: pilotMap, aeronauticalKept: openAIPDataService.downloadedCountries)
            } ?? true,
            firstFlightFlown: firstFlightFlown,
            proAircraft: proAircraft,
            hasPro: subscriptionManager.subscriptionStatus.isSubscribed,
            hasRoute: !flightPlanManager.flightPlans.isEmpty,
            dryRunFlown: dryRunFlown)
    }

    var body: some View {
        let status = status
        let ticked = GettingStarted.ticked(from: storedTicks)
        if GettingStarted.isShown(offered: offered, hidden: hidden, status: status, ticked: ticked), !appState.isFlightActive,
           appState.flights.isEmpty {
            let items = GettingStarted.items(status, ticked: ticked)
            let done = items.filter(\.done).count
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.GettingStarted.title)
                        .font(.aero(size: isCompact ? 17 : 19, weight: .bold))
                        .foregroundColor(.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text(L10n.GettingStarted.progress(done, items.count))
                        .font(.aero(size: 14, weight: .semibold))
                        .foregroundColor(.secondaryText)
                }
                ProgressView(value: Double(done), total: Double(items.count))
                    .tint(.aviationGold)
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    ForEach(items, id: \.item) { entry in
                        row(entry.item, done: entry.done)
                    }
                }
                HStack {
                    // Free practice, a flight of the pilot's own (the author's note on p2, 31 Oct 2026).
                    Button { DryRunCenter.shared.requestStart() } label: {
                        Text(L10n.DryRunCoach.FirstFlight.freePractice)
                            .font(.aero(size: 15, weight: .semibold))
                            .foregroundColor(.aviationGold)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button { hidden = true } label: {
                        Text(L10n.GettingStarted.hide)
                            .font(.aero(size: 15, weight: .semibold))
                            .foregroundColor(.secondaryText)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.aviationGold.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.aviationGold.opacity(0.4), lineWidth: 1))
            .task(id: GettingStarted.ticks(items)) { storedTicks = GettingStarted.ticks(items) }
        }
    }

    private func row(_ item: GettingStarted.Item, done: Bool) -> some View {
        Button { if !done { open(item) } } label: {
            HStack(spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.aero(size: 22, weight: .regular))
                    .foregroundColor(done ? .aviationGreen : .dimText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(item))
                        .font(.aero(size: isCompact ? 15 : 16, weight: .semibold))
                        .foregroundColor(done ? .secondaryText : .primaryText)
                        .strikethrough(done, color: .secondaryText)
                    if !done, let detail = detail(item) {
                        Text(detail)
                            .font(.aero(size: 13))
                            .foregroundColor(.secondaryText)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if !done {
                    Image(systemName: "chevron.right")
                        .font(.aero(size: 14, weight: .semibold))
                        .foregroundColor(.dimText)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(done)
        .accessibilityValue(done ? L10n.GettingStarted.done : "")
    }

    private func title(_ item: GettingStarted.Item) -> String {
        switch item {
        case .base: return L10n.GettingStarted.base
        case .offline: return L10n.GettingStarted.offline(homeCountry?.name ?? L10n.GettingStarted.yourCountry)
        case .firstFlight: return L10n.GettingStarted.firstFlight
        case .pro: return L10n.GettingStarted.pro(proAircraft ?? "")
        case .route: return L10n.GettingStarted.route
        case .dryRun: return L10n.DryRunCoach.FirstFlight.fullDryRun
        }
    }

    private func detail(_ item: GettingStarted.Item) -> String? {
        switch item {
        case .base: return nil
        case .offline:
            guard let country = homeCountry else { return nil }
            let fraction = OfflineCountryCatalog.progress([country], pilotMap: pilotMap,
                                                          aeronauticalKept: openAIPDataService.downloadedCountries)
            return fraction > 0 ? L10n.Onboarding.offlineProgress(fraction.formatted(.percent.precision(.fractionLength(0))))
                : nil
        case .firstFlight: return L10n.GettingStarted.firstFlightDetail
        case .pro: return L10n.GettingStarted.proDetail
        case .route: return nil
        case .dryRun: return L10n.GettingStarted.dryRunDetail
        }
    }

    private func open(_ item: GettingStarted.Item) {
        switch item {
        case .base:
            appState.pendingSettingsSection = .flightPlanning
            appState.groundTab = .settings
        case .offline:
            appState.pendingSettingsSection = .dataStorage
            appState.groundTab = .settings
        case .firstFlight:
            let pro = subscriptionManager.subscriptionStatus.isSubscribed ? nil : proAircraft
            DryRunCenter.shared.requestFirstFlight(pro: pro.map { registration in
                (registration, { [appState] in
                    appState.pendingSettingsSection = .aircraft
                    appState.groundTab = .settings
                })
            })
        case .pro:
            appState.pendingSettingsSection = .aircraft
            appState.groundTab = .settings
        case .route:
            appState.groundTab = .plan
        case .dryRun:
            DryRunCenter.shared.requestGuided()
        }
    }
}
