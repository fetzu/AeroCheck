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
    @EnvironmentObject var threadManager: FlightThreadManager
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var aircraftDataService: AircraftDataService

    var body: some View {
        TabView(selection: Bindable(appState).groundTab) {
            HomeView()
                .tabItem { Label(L10n.Ground.today, systemImage: "sun.horizon.fill") }
                .tag(GroundTab.today)
                .badge(openFlightPlanBadge)
            PlanTabView()
                .tabItem { Label(L10n.Ground.plan, systemImage: "map.fill") }
                .tag(GroundTab.plan)
            FlightLogView(mode: .logbook)
                .tabItem { Label(L10n.Ground.logbook, systemImage: "book.closed.fill") }
                .tag(GroundTab.logbook)
            NavigationStack { AircraftSettingsView(showsSpeeds: true) }
                .tabItem { Label(L10n.Ground.aircraft, systemImage: "airplane") }
                .tag(GroundTab.aircraft)
            SettingsView(isEmbedded: true)
                .tabItem { Label(L10n.Ground.settings, systemImage: "gearshape.fill") }
                .tag(GroundTab.settings)
        }
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

/// Why a flight didn't start, and what couldn't be saved at its end, on whichever tab the pilot is
/// on. These lived on Today, so a START FLIGHT refused from a flight's page in Plan said nothing
/// until the pilot went back to Today. (on-device review #4, point 1)
private struct FlightStartAlerts: ViewModifier {
    @Environment(AppState.self) private var appState
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var aircraftDataService: AircraftDataService

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

    @State private var section: Section = .flights
    /// The embedded map has no close button; this only satisfies its binding.
    @State private var mapPresented = true

    var body: some View {
        // One navigation stack, at the tab's root, as the other tabs have. The sections bring none of
        // their own: on iPadOS a nested stack's bar shares the tab bar's row and pulled this picker up
        // under the tabs. A section's actions (Routes' filter and +) join that row. (on-device review
        // #1, G-07)
        NavigationStack {
            VStack(spacing: 0) {
                Picker(L10n.Ground.plan, selection: $section) {
                    ForEach(Section.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                switch section {
                case .flights:
                    FlightLogView(mode: .plan)
                case .routes:
                    FlightPlanningView(isEmbedded: true)
                case .map:
                    NavigationMapView(isPresented: $mapPresented, showsCloseButton: false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.cockpitBackground.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
