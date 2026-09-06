import Foundation

// MARK: - Creating a flight (v5.0.0)
//
// One function, because there is one creation path. Home's empty state, the Flights destination and
// "Plan this again" all arrive here with a `NewFlightIntent` and get the same plan, the same thread
// and the same reminders. A second creator that skipped a step is exactly how the thread ended up
// invisible, so the orchestration lives in one place rather than being retyped per screen.

@MainActor
enum FlightCreator {

    /// Turn an intent into a saved plan and the flight thread that follows it.
    ///
    /// The airport layer loads on demand rather than at launch, so this awaits it before resolving
    /// idents. Skipping that would leave a flight created on a cold start with no waypoints — and
    /// with no coordinates there is no country detection, so no customs, no DABS, no GAFOR. This
    /// release has already had to fix that failure once; it must not arrive by a second route.
    @discardableResult
    static func create(from intent: NewFlightIntent,
                       plans: FlightPlanManager,
                       threads: FlightThreadManager,
                       airports: AirportDataService,
                       notifications: NotificationService = .shared) async -> FlightThread {
        if !intent.departureIdent.isEmpty {
            await airports.ensureLoaded()
        }
        let plan = FlightPlan.from(intent: intent) { ident in
            airports.findAirport(byIdent: ident)?.coordinate
        }
        plans.add(plan)

        let thread = threads.createThread(
            from: plan,
            profile: intent.kind.profile,
            routeLabel: intent.routeLabel,
            aircraftRegistration: intent.aircraftRegistration
        )

        // The two reminders are the whole reason to follow a flight, so the permission prompt lands
        // here — with the pilot having just asked for it — rather than at cold launch.
        await notifications.requestAuthorization()
        return thread
    }
}
