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
    }

    /// A badge only for what can't wait: an ATC flight plan still open after landing. The Flights
    /// badge used to count every flight ever flown, which taught the eye to skip badges. (review A6)
    private var openFlightPlanBadge: Int {
        (threadManager.threadAwaitingCloseOut?.hasOpenFlightPlan ?? false) ? 1 : 0
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
        .background(Color.cockpitBackground.ignoresSafeArea())
    }
}
