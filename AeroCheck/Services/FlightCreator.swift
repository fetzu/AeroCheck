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
        var plan = FlightPlan.from(intent: intent) { place($0, in: airports) }
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
        let plan = plan(fromRoute: route, intent: intent)
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

    /// The flight's own copy of a saved route: a fresh plan carrying the route's work (waypoints,
    /// fuel figures, remarks) with the flight's aircraft and date. Plan new flight previews a trip
    /// split from a route with the same copy it creates. (6.1)
    static func plan(fromRoute route: FlightPlan, intent: NewFlightIntent) -> FlightPlan {
        // `id` is a `let`, so this is a new value rather than a mutated copy — which is the point.
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
        return plan
    }

    /// A saved route flown as a trip, landing at the aerodromes switched on with "Land here": one leg
    /// per stretch between two landings, each keeping its part of the route (waypoints, altitudes),
    /// split as "Add a stop…" splits a flight. Nil when no landing splits the route. (6.1, M2)
    @discardableResult
    static func createTrip(fromRoute route: FlightPlan,
                           intent: NewFlightIntent,
                           landings: [TripPlanner.Landing],
                           plans: FlightPlanManager,
                           threads: FlightThreadManager,
                           notifications: NotificationService? = nil) async -> Trip? {
        let notifications = notifications ?? NotificationService.shared
        // Before any `createThread`, for the reason given in `create(from:)` above. (review F16)
        await notifications.requestAuthorization()
        return formTrip(fromRoute: route, intent: intent, landings: landings, plans: plans, threads: threads)
    }

    /// `createTrip(fromRoute:)` without the notification prompt, which a test can't answer.
    @discardableResult
    static func formTrip(fromRoute route: FlightPlan,
                         intent: NewFlightIntent,
                         landings: [TripPlanner.Landing],
                         plans: FlightPlanManager,
                         threads: FlightThreadManager) -> Trip? {
        let legs = TripPlanner.legs(of: plan(fromRoute: route, intent: intent), landingAt: landings)
        guard legs.count >= 2 else { return nil }
        var legIds: [UUID] = []
        for var leg in legs {
            leg.flightOwned = true
            plans.add(leg)
            legIds.append(threads.createThread(from: leg,
                                               profile: intent.kind.profile,
                                               routeLabel: FlightThreadManager.routeLabel(for: leg),
                                               aircraftRegistration: intent.aircraftRegistration).id)
        }
        guard let trip = threads.formTrip(from: legIds) else { return nil }
        // `createThread` made each leg the current flight in turn; the trip starts with leg 1.
        threads.setCurrentThread(legIds[0])
        // The legs came out of the split already estimated; one update of leg 1 runs the chain the
        // plan manager keeps from now on.
        if let first = plans.flightPlans.first(where: { $0.id == legs[0].id }) { plans.updateFlightPlan(first) }
        return trip
    }

    /// What Plan new flight asked for, created: a flight from a saved route, that route split into a
    /// trip at its landings, a trip from typed stops, or a flight from two aerodromes. Returns the flight
    /// to open (a trip's first leg). Home and the Flights tab both create through here, so the two can't
    /// drift apart. (6.1)
    static func create(_ planned: PlannedFlight,
                       plans: FlightPlanManager,
                       threads: FlightThreadManager,
                       airports: AirportDataService) async -> UUID? {
        // A saved route is copied whole — its waypoints, altitudes and fuel are the reason it was worth
        // saving, and rebuilding from two idents would discard all of it.
        if let route = planned.route {
            if !planned.landings.isEmpty,
               let trip = await createTrip(fromRoute: route, intent: planned.intent, landings: planned.landings,
                                           plans: plans, threads: threads) {
                return trip.legIds.first
            }
            return await create(fromRoute: route, intent: planned.intent, plans: plans, threads: threads).id
        }
        if planned.stops.idents.count > 2,
           let trip = await createTrip(idents: planned.stops.idents, stopovers: planned.stops.stopovers,
                                       template: planned.intent, plans: plans, threads: threads,
                                       airports: airports) {
            return trip.legIds.first
        }
        return await create(from: planned.intent, plans: plans, threads: threads, airports: airports).id
    }

    /// Where an ident is, for `FlightPlan.from(intent:)`: the aerodrome's position and field
    /// elevation, or nil when the airport data doesn't know it. Plan new flight's legs preview resolves
    /// with the same function, so it shows the legs this creates.
    static func place(_ ident: String, in airports: AirportDataService) -> FlightPlan.ResolvedPlace? {
        guard let airport = airports.findAirport(byIdent: ident) else { return nil }
        return FlightPlan.ResolvedPlace(coordinate: airport.coordinate,
                                        elevationFeet: airport.elevation.map(Double.init))
    }

    /// Create a multi-leg trip from consecutive aerodromes: LSZQ → LFSB → LSGY is two legs.
    ///
    /// Each leg is created by the SAME `create` above, so a leg is in every way an ordinary flight —
    /// which is the whole premise. The trip is then formed from them, which lifts the shared
    /// preparation off the first leg rather than asking for it again.
    ///
    /// `stopovers[i]` is the stop at `idents[i + 1]` (blank idents dropped): the time on the ground and
    /// the refuel Plan new flight asked for, on the leg that departs from there. A missing one is the
    /// default stop, 30 minutes without fuel. (6.1)
    @discardableResult
    static func createTrip(idents: [String],
                           stopovers: [Stopover] = [],
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
        if trip != nil { seedLaterLegs(legIds, stopovers: stopovers, plans: plans, threads: threads) }
        return trip
    }

    /// Give every leg after the first the stop in front of it (`stopovers[i]` for leg `i + 2`, else the
    /// default): an estimated departure (the previous leg's arrival plus the time on the ground) for
    /// its nav log's ETOs, and the fuel the previous leg leaves unless it refuels. The estimate is
    /// never a firm time, so it arms no reminder. (v5.1; the pilot's stops since 6.1)
    static func seedLaterLegs(_ legIds: [UUID], stopovers: [Stopover] = [],
                              plans: FlightPlanManager, threads: FlightThreadManager) {
        let planIds = legIds.compactMap { threads.thread(withId: $0)?.flightPlanId }
        for (leg, planId) in planIds.enumerated().dropFirst() {
            guard var plan = plans.flightPlans.first(where: { $0.id == planId }),
                  plan.stopover == nil, plan.firmDepartureTime == nil else { continue }
            plan.stopover = stopovers.indices.contains(leg - 1) ? stopovers[leg - 1] : Stopover()
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
    @discardableResult
    static func addStop(to threadId: UUID,
                        at candidate: TripPlanner.StopCandidate,
                        stopover: Stopover,
                        plans: FlightPlanManager,
                        threads: FlightThreadManager) -> FlightThread? {
        addStops(to: threadId, landingAt: [TripPlanner.Landing(candidate: candidate, stopover: stopover)],
                 plans: plans, threads: threads).first
    }

    /// Add several stops to a flight that has not flown yet, in one pass: it becomes one leg per
    /// stretch between them, in flying order (`TripPlanner.legs(of:landingAt:)`). Returns the new
    /// legs, in order.
    ///
    /// The flight keeps its identity (plan, thread, every tick) as the leg that ends at the first stop;
    /// the rest of the route becomes new legs after it, each with its own plan, nav log and leg-scoped
    /// tasks. A flight already in a trip gets the new legs inserted right after it, so stops can be
    /// added to any leg of a journey. A local flight (one aerodrome) flies out to the stops and back.
    /// (v5.1; several stops, and local flights, since 6.1)
    @discardableResult
    static func addStops(to threadId: UUID,
                         landingAt landings: [TripPlanner.Landing],
                         plans: FlightPlanManager,
                         threads: FlightThreadManager) -> [FlightThread] {
        guard !landings.isEmpty,
              let thread = threads.thread(withId: threadId), thread.flightId == nil,
              let planId = thread.flightPlanId,
              let plan = plans.flightPlans.first(where: { $0.id == planId })
        else { return [] }
        let legs = TripPlanner.legs(of: plan, landingAt: landings)
        guard legs.count >= 2, let first = legs.first else { return [] }

        // The new legs first, so the trip exists when the first leg's update carries its timing
        // forward (`updateFlightPlan` → the next leg's estimate).
        let followedBefore = threads.currentThreadId
        var anchor = threadId
        var added: [UUID] = []
        for leg in legs.dropFirst() {
            plans.add(leg)
            let created = threads.createThread(from: leg,
                                               profile: thread.profile,
                                               routeLabel: FlightThreadManager.routeLabel(for: leg),
                                               aircraftRegistration: thread.aircraftRegistration)
            threads.insertLeg(created.id, after: anchor)
            anchor = created.id
            added.append(created.id)
        }
        // `createThread` makes each new flight the current one; the pilot is still on this one.
        threads.setCurrentThread(followedBefore)

        plans.updateFlightPlan(first)
        // A leg that already followed this one now departs after the last new leg: pass the new legs
        // through the same update, which carries each arrival into the next leg's estimate.
        for leg in legs.dropFirst() {
            if let placed = plans.flightPlans.first(where: { $0.id == leg.id }) { plans.updateFlightPlan(placed) }
        }
        threads.updateRouteLabel(FlightThreadManager.routeLabel(for: first), threadId: threadId)
        // The destination changed: PPR, fees and customs are re-derived for it.
        threads.regenerateTasks(threadId: threadId, plan: first)
        return added.compactMap { threads.thread(withId: $0) }
    }

    /// A later leg's stop, changed on its page: the time on the ground and the refuel. Its estimated
    /// departure follows (`TripPlanner.settingStopover`), and so, through the plan manager's chain,
    /// does every leg after it. A leg that has flown, or the first leg, has no stop to change. (6.1)
    @discardableResult
    static func setStopover(_ stopover: Stopover,
                            onLeg threadId: UUID,
                            plans: FlightPlanManager,
                            threads: FlightThreadManager) -> Bool {
        guard let thread = threads.thread(withId: threadId), thread.flightId == nil,
              let trip = threads.trip(forThreadId: threadId),
              let position = trip.legIds.firstIndex(of: threadId), position > 0,
              let planId = thread.flightPlanId,
              let leg = plans.flightPlans.first(where: { $0.id == planId }),
              let previousPlanId = threads.thread(withId: trip.legIds[position - 1])?.flightPlanId,
              let previous = plans.flightPlans.first(where: { $0.id == previousPlanId })
        else { return false }
        // A refuel brings back the fuel the trip set off with.
        let firstPlanId = threads.thread(withId: trip.legIds[0])?.flightPlanId
        let plannedFOB = plans.flightPlans.first(where: { $0.id == firstPlanId })?.fuelOnBoard
        guard let updated = TripPlanner.settingStopover(stopover, on: leg, after: previous, plannedFOB: plannedFOB)
        else { return false }
        plans.updateFlightPlan(updated)
        // A departure that became an estimate again no longer arms a reminder or claims a day.
        if updated.firmDepartureTime != leg.firmDepartureTime {
            threads.regenerateTasks(threadId: threadId, plan: updated)
        }
        return true
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

    /// Whether a flight can take a stop: it has not flown, and has a route with somewhere to stop, or
    /// is a local flight (one aerodrome, out and back), which can fly out to stops and back. Circuits
    /// stay circuits. (a local flight since 6.1)
    static func canAddStop(to thread: FlightThread, plans: FlightPlanManager) -> Bool {
        guard thread.flightId == nil, let planId = thread.flightPlanId,
              let plan = plans.flightPlans.first(where: { $0.id == planId }) else { return false }
        return plan.waypoints.count >= 2 || (plan.waypoints.count == 1 && thread.profile == .full)
    }

    // MARK: - Cancelling (6.1)

    /// "Cancel flight": the page, its tasks and reminders, its place in a trip, and the copy of the
    /// route made for it (`FlightThreadManager.planToDelete`). Both cancels come through here, so a
    /// trip cancelled whole leaves exactly what cancelling its legs one by one would: the same
    /// deletion records, the same reminders gone.
    ///
    /// `logbookPlanIds`: the plans the logbook's flights point at, which stay.
    static func cancelLeg(_ threadId: UUID,
                          plans: FlightPlanManager,
                          threads: FlightThreadManager,
                          logbookPlanIds: Set<UUID>) {
        let ownPlan = FlightThreadManager.planToDelete(
            withThread: threadId, threads: threads.threads, plans: plans.flightPlans,
            logbookPlanIds: logbookPlanIds)
        // `removeLeg`, not `deleteThread`: this is the app's ONLY delete affordance and it
        // is shown on trip legs too. `deleteThread` knows nothing about trips, so cancelling
        // a leg left its id dangling in `Trip.legIds` — "Leg 3 of 3" on the second of two, a
        // degenerate trip never dissolved, and the survivor stuck with `tripId` set so its
        // trip-scoped rows never came back. `removeLeg` delegates to `deleteThread` for a
        // thread that is not in a trip, so it is a safe drop-in. (review F14)
        threads.removeLeg(threadId: threadId)
        if let ownPlan { plans.deleteFlightPlan(ownPlan) }
    }

    /// "Cancel trip": every leg neither flown nor flying (`FlightThreadManager.legsToCancel`), each
    /// cancelled by `cancelLeg`. Returns the legs removed.
    ///
    /// The legs that flew stay, with their flights in the logbook. Two or more of them left keep the
    /// trip, as the record of what was flown; one left is a flight of its own again, with the trip's
    /// preparation, as `removeLeg` decides for any leg. A leg in the air is never removed, whatever
    /// the caller offered (`flyingPlanId`: the plan of the flight under way).
    @discardableResult
    static func cancelTrip(_ tripId: UUID,
                           plans: FlightPlanManager,
                           threads: FlightThreadManager,
                           logbookPlanIds: Set<UUID>,
                           flyingPlanId: UUID? = nil) -> [UUID] {
        guard let trip = threads.trip(withId: tripId) else { return [] }
        let legs = FlightThreadManager.legsToCancel(in: trip, threads: threads.threads,
                                                    flyingPlanId: flyingPlanId)
        for leg in legs {
            cancelLeg(leg.id, plans: plans, threads: threads, logbookPlanIds: logbookPlanIds)
        }
        return legs.map(\.id)
    }
}
