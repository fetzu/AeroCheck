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
        var plan = FlightPlan.from(intent: intent) { ident in
            guard let airport = airports.findAirport(byIdent: ident) else { return nil }
            return FlightPlan.ResolvedPlace(coordinate: airport.coordinate,
                                            elevationFeet: airport.elevation.map(Double.init))
        }
        // The flight's own plan: it lives with the flight, not in the Routes list. (review #4, R1)
        plan.flightOwned = true
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
        // The flight's copy lives with the flight; the route stays in Routes, once. (review #4, R1)
        plan.flightOwned = true
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
        let trip = threads.formTrip(from: legIds)
        if trip != nil { seedLaterLegs(legIds, plans: plans, threads: threads) }
        return trip
    }

    /// Give every leg after the first the stop in front of it: an estimated departure (the previous
    /// leg's arrival plus the time on the ground) for its nav log's ETOs, and the fuel the previous
    /// leg leaves. The estimate is never a firm time, so it arms no reminder. (v5.1)
    private static func seedLaterLegs(_ legIds: [UUID], plans: FlightPlanManager, threads: FlightThreadManager) {
        let planIds = legIds.compactMap { threads.thread(withId: $0)?.flightPlanId }
        for planId in planIds.dropFirst() {
            guard var plan = plans.flightPlans.first(where: { $0.id == planId }),
                  plan.stopover == nil, plan.firmDepartureTime == nil else { continue }
            plan.stopover = Stopover()
            plan.departureIsEstimate = true
            plans.updateFlightPlan(plan)
        }
        // One update of the first leg carries its arrival down the whole chain.
        if let first = planIds.first, let plan = plans.flightPlans.first(where: { $0.id == first }) {
            plans.updateFlightPlan(plan)
        }
    }

    // MARK: - Stops (v5.1)

    /// Add a stop to a flight that has not flown yet: it becomes two legs of one trip.
    ///
    /// The flight keeps its identity (plan, thread, every tick) as the leg that ends at the stop; the
    /// rest of the route becomes a new leg after it, with its own plan, nav log and leg-scoped tasks.
    /// A flight already in a trip gets the new leg inserted right after it, so a stop can be added to
    /// any leg of a journey.
    @discardableResult
    static func addStop(to threadId: UUID,
                        at candidate: TripPlanner.StopCandidate,
                        stopover: Stopover,
                        plans: FlightPlanManager,
                        threads: FlightThreadManager) -> FlightThread? {
        guard let thread = threads.thread(withId: threadId), thread.flightId == nil,
              let planId = thread.flightPlanId,
              let plan = plans.flightPlans.first(where: { $0.id == planId })
        else { return nil }
        let (route, index) = TripPlanner.routeStopping(at: candidate, in: plan)
        guard let (first, second) = TripPlanner.split(route, at: index, stopover: stopover,
                                                      stopIdent: candidate.aerodrome.ident,
                                                      fieldElevationFeet: candidate.aerodrome.elevationFeet)
        else { return nil }

        // The new leg first, so the trip exists when the first leg's update carries its timing
        // forward (`updateFlightPlan` → the next leg's estimate).
        plans.add(second)
        let followedBefore = threads.currentThreadId
        let leg = threads.createThread(from: second,
                                       profile: thread.profile,
                                       routeLabel: FlightThreadManager.routeLabel(for: second),
                                       aircraftRegistration: thread.aircraftRegistration)
        // `createThread` makes the new flight the current one; the pilot is still on this one.
        threads.setCurrentThread(followedBefore)
        threads.insertLeg(leg.id, after: threadId)

        plans.updateFlightPlan(first)
        // A leg that already followed this one now departs after the new leg: pass the new leg
        // through the same update, which carries its arrival into that leg's estimate.
        if let placed = plans.flightPlans.first(where: { $0.id == second.id }) {
            plans.updateFlightPlan(placed)
        }
        threads.updateRouteLabel(FlightThreadManager.routeLabel(for: first), threadId: threadId)
        // The destination changed: PPR, fees and customs are re-derived for it.
        threads.regenerateTasks(threadId: threadId, plan: first)
        return threads.thread(withId: leg.id)
    }

    /// Undo a stop: join a leg with the one after it, while neither has flown. The first leg keeps its
    /// identity; the second is removed, and the trip dissolves when only one leg is left.
    @discardableResult
    static func joinWithNextLeg(_ threadId: UUID,
                                plans: FlightPlanManager,
                                threads: FlightThreadManager) -> Bool {
        guard let thread = threads.thread(withId: threadId), thread.flightId == nil,
              let next = threads.leg(after: threadId), next.flightId == nil,
              let planId = thread.flightPlanId, let nextPlanId = next.flightPlanId,
              let plan = plans.flightPlans.first(where: { $0.id == planId }),
              let nextPlan = plans.flightPlans.first(where: { $0.id == nextPlanId })
        else { return false }
        let joined = TripPlanner.join(plan, nextPlan)
        threads.removeLeg(threadId: next.id)
        plans.deleteFlightPlan(nextPlan)
        plans.updateFlightPlan(joined)
        threads.updateRouteLabel(FlightThreadManager.routeLabel(for: joined), threadId: threadId)
        threads.regenerateTasks(threadId: threadId, plan: joined)
        return true
    }

    /// After landing somewhere other than planned: the rest of the route as the next leg, from the
    /// aerodrome the flight is at, in the same trip. (v5.1)
    ///
    /// It rejoins the route past the diversion field (`TripPlanner.continuation`), carries the
    /// route's altitudes and frequency overrides, and brings the trip's weather and NOTAM ticks back
    /// unticked: a diversion is evidence that something changed. The new leg has no departure time —
    /// nobody knows it yet — and is today's flight because the one before it just landed.
    @discardableResult
    static func continueAfterDiversion(from threadId: UUID,
                                       plans: FlightPlanManager,
                                       threads: FlightThreadManager,
                                       airports: AirportDataService) -> FlightThread? {
        // Not "no next leg": a diversion on the first leg of a trip still needs a way to the stop the
        // later legs leave from, and the continuation goes in between them.
        guard let thread = threads.thread(withId: threadId), thread.landedElsewhere?.continued != true,
              let planId = thread.flightPlanId,
              let flown = plans.flightPlans.first(where: { $0.id == planId }),
              let diversion = flown.diversion
        else { return nil }
        let field = airports.findAirport(byIdent: diversion.ident).map(airports.planningAerodrome)
            ?? TripPlanner.Aerodrome(ident: diversion.ident, name: diversion.name,
                                     latitude: diversion.latitude, longitude: diversion.longitude,
                                     elevationFeet: diversion.elevationFeet, frequency: diversion.frequency,
                                     isPPR: false)
        let next = TripPlanner.continuation(of: flown, from: field)
        plans.add(next)
        let leg = threads.createThread(from: next,
                                       profile: thread.profile,
                                       routeLabel: FlightThreadManager.routeLabel(for: next),
                                       aircraftRegistration: thread.aircraftRegistration)
        threads.insertLeg(leg.id, after: threadId, rebrief: true)
        threads.markContinued(threadId: threadId)
        return threads.thread(withId: leg.id)
    }

    /// Whether a flight can take a stop: it has not flown and has a route with somewhere to stop.
    static func canAddStop(to thread: FlightThread, plans: FlightPlanManager) -> Bool {
        guard thread.flightId == nil, let planId = thread.flightPlanId,
              let plan = plans.flightPlans.first(where: { $0.id == planId }) else { return false }
        return plan.waypoints.count >= 2
    }
}
