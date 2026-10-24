import SwiftUI

// MARK: - Ground (v6.0 · P1)
//
// Everything a pilot does on the ground, as five sections behind one tab bar: Today, Plan, Logbook,
// Aircraft, Settings. Each tab is a place you stay in, and keeps its state while you look elsewhere.
// Before 6.0 the bottom bar looked like tabs but opened full-screen covers, each with its own Close
// button, stacked over one another (Apple HIG: a tab bar navigates, it doesn't act; one modal at a
// time). In the air the flight screen replaces all of it (see ContentView).

struct GroundView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject var threadManager: FlightThreadManager
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var aircraftDataService: AircraftDataService

    /// The iPad draws its own bar (`GroundTabBar`); the iPhone keeps the system's at the foot. (6.5.0)
    private var ownsTabBar: Bool { horizontalSizeClass == .regular }

    var body: some View {
        TabView(selection: Bindable(appState).groundTab) {
            // On the iPad, our own bar where the system's was (`GroundTabBar`): over Today, which has no navigation bar,
            // and over Settings' two columns (SettingsView); in the navigation bar of the others, beside their actions
            // (`groundTabBarInToolbar`). The tabs' screens don't take an inset set on the TabView. (6.5.0)
            HomeView()
                .safeAreaInset(edge: .top, spacing: 0) { if ownsTabBar { GroundTabBar() } }
                .tabItem { Label(L10n.Ground.today, systemImage: "sun.horizon.fill") }
                .tag(GroundTab.today)
                .badge(openFlightPlanBadge)
                .toolbar(ownsTabBar ? .hidden : .automatic, for: .tabBar)
            PlanTabView()
                .tabItem { Label(L10n.Ground.plan, systemImage: "map.fill") }
                .tag(GroundTab.plan)
                .toolbar(ownsTabBar ? .hidden : .automatic, for: .tabBar)
            FlightLogView(mode: .logbook)
                .tabItem { Label(L10n.Ground.logbook, systemImage: "book.closed.fill") }
                .tag(GroundTab.logbook)
                .toolbar(ownsTabBar ? .hidden : .automatic, for: .tabBar)
            NavigationStack { AircraftSettingsView(showsSpeeds: true).groundTabBarInToolbar() }
                .tabItem { Label(L10n.Ground.aircraft, systemImage: "airplane") }
                .tag(GroundTab.aircraft)
                .toolbar(ownsTabBar ? .hidden : .automatic, for: .tabBar)
            SettingsView(isEmbedded: true)
                .tabItem { Label(L10n.Ground.settings, systemImage: "gearshape.fill") }
                .tag(GroundTab.settings)
                .toolbar(ownsTabBar ? .hidden : .automatic, for: .tabBar)
        }
        .environment(\.ownsGroundTabBar, ownsTabBar)
        // The brand colour on the ground; the flight screens don't use it (v6.0 · P5).
        .tint(.aviationGold)
        .modifier(FlightStartAlerts())
    }

    /// A badge only for what can't wait: an ATC flight plan still open after landing. The Flights
    /// badge used to count every flight ever flown, which taught the eye to skip badges. (review A6)
    private var openFlightPlanBadge: Int {
        (threadManager.threadAwaitingCloseOut?.hasOpenFlightPlan ?? false) ? 1 : 0
    }
}

/// The ground's tabs on the iPad: at the top, as the system's floating bar, but as wide as its words. The system's
/// stops at about 470 pt on any iPad, so in German and French its words ran out of room and it scrolled, Settings out
/// of view (the author's device check, 23 Oct 2026). Ours is as wide as its words, its text sizes capped so it stays
/// within the screen. The dry run's ground keeps the system's: two tabs fit. (6.5.0)
struct GroundTabBar: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject var threadManager: FlightThreadManager

    private static let tabs: [(tab: GroundTab, title: String)] = [
        (.today, L10n.Ground.today), (.plan, L10n.Ground.plan), (.logbook, L10n.Ground.logbook),
        (.aircraft, L10n.Ground.aircraft), (.settings, L10n.Ground.settings),
    ]

    /// Today's badge: an ATC flight plan still open after landing, as the system's tab had it.
    private var badge: Int { (threadManager.threadAwaitingCloseOut?.hasOpenFlightPlan ?? false) ? 1 : 0 }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.tabs, id: \.tab) { item in
                tabButton(item.tab, title: item.title)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.panelBackground))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .fixedSize()
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func tabButton(_ tab: GroundTab, title: String) -> some View {
        let selected = appState.groundTab == tab
        return Button { appState.groundTab = tab } label: {
            HStack(spacing: 6) {
                Text(title)
                    .lineLimit(1)
                if tab == .today, badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.aviationRed))
                }
            }
            .font(.body)
            .foregroundColor(selected ? .aviationGold : .primaryText)
            .padding(.horizontal, 15)
            .frame(minHeight: 37)
            .background { if selected { Capsule().fill(Color.cockpitBackground) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(tab == .today && badge > 0 ? "\(badge)" : "")
        .accessibilityIdentifier("tab.\(tab)")
    }
}

/// Why a flight didn't start, and what couldn't be saved at its end, on whichever tab the pilot is
/// on. These lived on Today, so a START FLIGHT refused from a flight's page in Plan said nothing
/// until the pilot went back to Today. (on-device review #4, point 1)
private struct FlightStartAlerts: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var aircraftDataService: AircraftDataService
    // What a replayed start needs: the "Location is off" alert starts the flight itself.
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var flightEventDetector: FlightEventDetector
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var threadManager: FlightThreadManager

    func body(content: Content) -> some View {
        content
            .alert(L10n.Alert.cannotStartFlightTitle, isPresented: Binding(
                get: { appState.flightStartError != nil },
                set: { if !$0 { appState.flightStartError = nil } }
            )) {
                Button(L10n.Button.close, role: .cancel) { appState.flightStartError = nil }
            } message: {
                Text(appState.flightStartError ?? "")
            }
            // Location is off for the app: the flight can still run, the checklists and all, with
            // nothing recorded. The pilot decides, Settings one tap away. This was a dead end
            // ("Location access is required"), which kept the checklists from anyone who had said no
            // to the location; App Review asks for a way on (guideline 5.1.1(iv)). (6.3.2)
            .alert(L10n.Alert.locationOffTitle, isPresented: Binding(
                get: { appState.flightStartWithoutLocation != nil },
                set: { if !$0 { appState.flightStartWithoutLocation = nil } }
            ), presenting: appState.flightStartWithoutLocation) { request in
                Button(L10n.Alert.startWithoutGPS) {
                    appState.flightStartWithoutLocation = nil
                    startWithoutLocation(request)
                }
                Button(L10n.Button.openSettings) {
                    appState.flightStartWithoutLocation = nil
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button(L10n.Button.cancel, role: .cancel) { appState.flightStartWithoutLocation = nil }
            } message: { _ in
                Text(L10n.Alert.locationOffMessage)
            }
            // AéroCheck Pro isn't active for the aircraft the pilot tried to fly: say so, and offer
            // the two ways out. A lapsed subscription used to read "check your connection".
            .alert(L10n.Alert.proNotActiveTitle, isPresented: Binding(
                get: { appState.flightStartNeedsPro != nil },
                set: { if !$0 { appState.flightStartNeedsPro = nil } }
            )) {
                Button(L10n.Alert.seePlans) {
                    appState.flightStartNeedsPro = nil
                    appState.flightStartPaywallRequest = true
                }
                Button(L10n.Subscription.restorePurchases) {
                    appState.flightStartNeedsPro = nil
                    Task {
                        await subscriptionManager.restorePurchases()
                        await aircraftDataService.refetchUntilPremiumUnlocked()
                    }
                }
                Button(L10n.Button.cancel, role: .cancel) { appState.flightStartNeedsPro = nil }
            } message: {
                Text(L10n.Alert.proNotActive(appState.flightStartNeedsPro ?? ""))
            }
            // PR-14: a just-finished flight could not be persisted — its checkpoint was kept and will
            // be restored next launch. Surface it rather than letting the failure be silent.
            .alert(L10n.Alert.flightSaveFailedTitle, isPresented: Binding(
                get: { appState.flightSaveError != nil },
                set: { if !$0 { appState.flightSaveError = nil } }
            )) {
                Button(L10n.Button.close, role: .cancel) { appState.flightSaveError = nil }
            } message: {
                Text(appState.flightSaveError ?? "")
            }
            // The plans, personalised with the aircraft the pilot just tried to fly. (UX-07)
            .sheet(isPresented: Binding(
                get: { appState.flightStartPaywallRequest },
                set: { if !$0 { appState.flightStartPaywallRequest = false } }
            )) {
                SubscriptionView(contextAircraftName: selectedModelName)
                    .environmentObject(subscriptionManager)
            }
    }

    /// The held start, replayed through the one launch sequence with the pilot's go-ahead.
    private func startWithoutLocation(_ request: LocationOffFlightStart) {
        let launcher = FlightLauncher(
            appState: appState,
            locationManager: locationManager,
            aircraftDataService: aircraftDataService,
            airportDataService: airportDataService,
            flightEventDetector: flightEventDetector,
            flightPlanManager: flightPlanManager,
            threadManager: threadManager
        )
        Task {
            await launcher.begin(circuitMode: request.circuitMode, followedFlightId: request.followedFlightId,
                                 unplanned: request.unplanned, withoutLocation: true)
        }
    }

    private var selectedModelName: String? {
        guard let id = appState.settings.selectedRemoteAircraftId else { return appState.settings.selectedAircraft.modelName }
        return aircraftDataService.availableAircraft.first { $0.id == id }?.modelName
    }
}

/// Planning, in one place: the flights you are preparing, the routes you keep, and the map to look at
/// airspace before either. It used to hide under Flight Log › Upcoming. (review A3)
struct PlanTabView: View {
    enum Section: CaseIterable, Hashable {
        case flights, routes, map

        var title: String {
            switch self {
            case .flights: return L10n.Ground.planFlights
            case .routes: return L10n.Ground.planRoutes
            case .map: return L10n.Ground.planMap
            }
        }
    }

    @Environment(AppState.self) private var appState
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var section: Section = .flights
    /// The embedded map has no close button; this only satisfies its binding.
    @State private var mapPresented = true

    private var picker: some View {
        Picker(L10n.Ground.plan, selection: $section) {
            ForEach(Section.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    var body: some View {
        // One navigation stack, at the tab's root, as the other tabs have. The sections bring none of
        // their own: on iPadOS a nested stack's bar shares the tab bar's row and pulled this picker up
        // under the tabs. A section's actions (Routes' filter and +) join that row. (on-device review
        // #1, G-07)
        NavigationStack {
            VStack(spacing: 0) {
                // On the iPhone the bar has a row of its own, shown only when a section has actions:
                // the picker dropped by a bar's height on Routes and came back up on Flights. There it
                // sits in the bar, which every section then shows. (iPhone pass)
                if horizontalSizeClass != .compact {
                    picker
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }

                switch section {
                case .flights:
                    FlightLogView(mode: .plan)
                case .routes:
                    FlightPlanningView(isEmbedded: true)
                case .map:
                    // The in-flight map's chrome, exactly: no clock/speed/altitude bar or GPS chip over
                    // the map controls (they sat on top of them), the same controls in the same places.
                    // (on-device review #4)
                    VStack(spacing: 0) {
                        // The route on the map without its countries' data: the route builder's offer to download
                        // it, here too, above the chart rather than over its chrome (the author's v65-14,
                        // 23 Oct 2026). (6.5.0)
                        TripDataBanner(route: flightPlanManager.activeFlightPlan?.waypoints.map(\.coordinate) ?? [])
                        NavigationMapView(isPresented: $mapPresented, showsCloseButton: false, chrome: .plan,
                                          onShowRoutes: { section = .routes })
                            // The chart starts under the picker, as the other sections do. Drawn on under
                            // the iPhone's bar, it was blurred there by the bar's scroll edge effect.
                            // (round 6, I-10)
                            .clipped()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.cockpitBackground.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if horizontalSizeClass == .compact {
                    ToolbarItem(placement: .principal) {
                        picker.frame(maxWidth: 250)
                    }
                }
            }
            .groundTabBarInToolbar()
        }
        // A section asked for from elsewhere: Today's route strip opens Routes. (iPhone pass)
        .onAppear { openPendingSection() }
        .onChange(of: appState.pendingPlanSection) { _, _ in openPendingSection() }
    }

    private func openPendingSection() {
        guard let pending = appState.pendingPlanSection else { return }
        appState.pendingPlanSection = nil
        section = pending
    }
}

/// The iPad draws the ground's tab bar itself (`GroundView`), in the tabs' navigation bars or over them. (6.5.0)
private struct OwnsGroundTabBarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var ownsGroundTabBar: Bool {
        get { self[OwnsGroundTabBarKey.self] }
        set { self[OwnsGroundTabBarKey.self] = newValue }
    }
}

extension View {
    /// The iPad's tab bar in this tab's navigation bar, where the system's sat: the tab's own actions keep their place
    /// beside it (Routes' filter and +, the Logbook's import). On the root of a tab's navigation stack. (6.5.0)
    func groundTabBarInToolbar(_ enabled: Bool = true) -> some View {
        modifier(GroundTabBarToolbar(enabled: enabled))
    }
}

private struct GroundTabBarToolbar: ViewModifier {
    @Environment(\.ownsGroundTabBar) private var shown
    let enabled: Bool

    func body(content: Content) -> some View {
        content.toolbar {
            if shown && enabled {
                ToolbarItem(placement: .principal) { GroundTabBar() }
            }
        }
    }
}
