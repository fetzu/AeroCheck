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
                       notifications: NotificationService? = nil) async -> FlightThread {
        // Resolved INSIDE the body rather than as a default argument. Default arguments are
        // evaluated in a nonisolated context, so `= .shared` reaches a main-actor property from
        // outside the actor — a warning today and an error under Swift 6.
        let notifications = notifications ?? NotificationService.shared
        if !intent.departureIdent.isEmpty {
            await airports.ensureLoaded()
        }
        let plan = FlightPlan.from(intent: intent) { ident in
            guard let airport = airports.findAirport(byIdent: ident) else { return nil }
            return FlightPlan.ResolvedPlace(coordinate: airport.coordinate,
                                            elevationFeet: airport.elevation.map(Double.init))
        }
        plans.add(plan)

        // BEFORE `createThread`, which schedules the T-24h reminder behind a `hasPermission()`
        // guard. Asking afterwards meant that on a fresh install the status was still
        // `.notDetermined` when the guard ran, the reminder was dropped, and nothing ever rescans —
        // so the first flight a pilot ever plans silently got no preparation reminder. The prompt
        // still lands here, with the pilot having just asked for it, rather than at cold launch.
        // (review F16)
        await notifications.requestAuthorization()

        let thread = threads.createThread(
            from: plan,
            profile: intent.kind.profile,
            routeLabel: intent.routeLabel,
            aircraftRegistration: intent.aircraftRegistration
        )
        return thread
    }

    /// Create a flight from a route the pilot has already built, rather than from typed idents.
    ///
    /// The route is COPIED, never referenced. Flying LSZQ → LSGY three times must not mean that
    /// entering October's fuel rewrites August's — and `thread(forPlanId:)` answers with ONE thread
    /// per plan, so two flights sharing a plan would make close-out ambiguous at exactly the moment
    /// it matters.
    ///
    /// Copying is also what makes a saved route worth having: the waypoints the pilot placed by
    /// hand, the altitudes, the fuel figures. Rebuilding from the two end idents would throw all of
    /// that away and hand back something that only looks like the route. (v5.x)
    @discardableResult
    static func create(fromRoute route: FlightPlan,
                       intent: NewFlightIntent,
                       plans: FlightPlanManager,
                       threads: FlightThreadManager,
                       notifications: NotificationService? = nil) async -> FlightThread {
        let notifications = notifications ?? NotificationService.shared

        // A fresh plan carrying the route's own work: waypoints, fuel figures, remarks. `id` is a
        // `let`, so this is a new value rather than a mutated copy — which is the point.
        var plan = FlightPlan(
            name: route.name,
            waypoints: route.waypoints,
            aircraftTypeId: intent.aircraftTypeId,
            // The aircraft is the FLIGHT's, not the route's: the same route next month may be a
            // different tail, and the checklist and the fuel flow follow the aircraft.
            aircraftRegistration: intent.aircraftRegistration,
            aircraftModelName: intent.aircraftModelName,
            pilot: route.pilot,
            instructor: route.instructor,
            flightType: route.flightType,
            runwayInUse: route.runwayInUse,
            fuelFlow: route.fuelFlow,
            reserveFuel: route.reserveFuel,
            additionalFuel: route.additionalFuel,
            extraFuel: route.extraFuel,
            fuelOnBoard: route.fuelOnBoard,
            remarks: route.remarks
        )
        plan.tripFuel = route.tripFuel
        plan.plannedDepartureTime = intent.departureTime
        // Times over recorded on a previous flight of this route belong to that flight.
        for index in plan.waypoints.indices {
            plan.waypoints[index].actualTimeOver = nil
        }
        plan.calculateRouteData()
        plans.add(plan)

        // Before `createThread`, for the reason given in `create(from:)` above. (review F16)
        await notifications.requestAuthorization()

        let thread = threads.createThread(
            from: plan,
            profile: intent.kind.profile,
            routeLabel: FlightThreadManager.routeLabel(for: plan),
            aircraftRegistration: intent.aircraftRegistration
        )
        return thread
    }

    /// Create a multi-leg trip from consecutive aerodromes: LSZQ → LFSB → LSGY is two legs.
    ///
    /// Each leg is created by the SAME `create` above, so a leg is in every way an ordinary flight —
    /// which is the whole premise. The trip is then formed from them, which lifts the shared
    /// preparation off the first leg rather than asking for it again.
    @discardableResult
    static func createTrip(idents: [String],
                           template: NewFlightIntent,
                           plans: FlightPlanManager,
                           threads: FlightThreadManager,
                           airports: AirportDataService,
                           notifications: NotificationService? = nil) async -> Trip? {
        let notifications = notifications ?? NotificationService.shared
        let stops = idents.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
        guard stops.count >= 3 else { return nil }   // fewer than two legs is just a flight

        var legIds: [UUID] = []
        for (from, to) in zip(stops, stops.dropFirst()) {
            var intent = template
            intent.departureIdent = from
            intent.arrivalIdent = to
            // Only the FIRST leg carries the departure time. The later ones depart when the earlier
            // ones land, which the app cannot know, and a guessed time would drive both the T−24 h
            // reminder and the staleness rule off a number nobody chose.
            intent.departureTime = legIds.isEmpty ? template.departureTime : nil
            let thread = await create(from: intent,
                                      plans: plans,
                                      threads: threads,
                                      airports: airports,
                                      notifications: notifications)
            legIds.append(thread.id)
        }
        return threads.formTrip(from: legIds)
    }
}
