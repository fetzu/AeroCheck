#if DEBUG
import CoreLocation
import Foundation

// MARK: - The device-check scene (DEV-ONLY, compiled out of Release)
//
// `AEROCHECK_SCENE=devcheck`: the routes and flights a simulator check starts from, dated from today, so a session
// on a fresh throwaway doesn't type them in by hand. Made as a pilot's taps make them: the routes through the
// route builder's own waypoints (`RoutePoint`) and `FlightPlanManager`, the flights through `FlightCreator`, so
// the pages, their tasks and the trip are what Plan new flight gives. Only the system's notification prompt is
// skipped (an inert service): on a fresh install it waits on an alert nobody answers.
//
// Each launch deletes what the last one made, by the ids it kept, and makes it again; nothing else is touched.
//
//   Route   LSZQ → LSZP → LSZG, LSZP its usual stop (45 min, refuel)
//   Route   LSZQ → EDTF, into Germany
//   Trip A  LSZQ → LFGA → LSZQ, tomorrow at 10:00, F-HVXA (a 30-minute stop at LFGA)
//   Flight  LSZQ → LFSB, today, two hours from now, F-HVXA
//
// The aerodromes come from the airport data (`CLAUDE/tools/sim-seed.sh` copies it onto a throwaway): without it
// nothing resolves and the scene makes nothing.

@MainActor
enum DevCheckScene {

    /// What the scene made, by id: the next launch deletes these and nothing else.
    struct Made: Codable {
        var routeIds: [UUID] = []
        var threadIds: [UUID] = []
    }

    static let madeKey = "AeroCheck.devCheckScene.made"

    static func inject(appState: AppState, plans: FlightPlanManager, threads: FlightThreadManager,
                       airports: AirportDataService, defaults: UserDefaults = .standard) async {
        await airports.ensureLoaded()
        removeWhatWasMade(appState: appState, plans: plans, threads: threads, defaults: defaults)

        guard ["LSZQ", "LSZP", "LSZG", "EDTF", "LFGA", "LFSB"].allSatisfy({ airports.findAirport(byIdent: $0) != nil })
        else {
            AppLog.marketing.debugLine("Dev check scene: aerodromes missing, nothing made (no airport data?)")
            return
        }
        var made = Made()
        let notifications = NotificationService.inert()
        let aircraft = AircraftType.wt9Dynamic

        // The saved routes, as the builder saves them.
        let usualStop = Stopover(groundMinutes: 45, refuel: true)
        if let route = makeRoute(["LSZQ", "LSZP", "LSZG"], stops: ["LSZP": usualStop], plans: plans, airports: airports) {
            made.routeIds.append(route.id)
        }
        if let route = makeRoute(["LSZQ", "EDTF"], plans: plans, airports: airports) {
            made.routeIds.append(route.id)
        }

        // Trip A, as Plan new flight makes it from typed stops.
        let calendar = Calendar.current
        let now = FlightClock.now
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let tripDeparture = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow)
        let tripIntent = NewFlightIntent(departureIdent: "LSZQ", arrivalIdent: "LSZQ", departureTime: tripDeparture,
                                         aircraftTypeId: aircraft.rawValue, aircraftRegistration: aircraft.registration,
                                         aircraftModelName: aircraft.modelName)
        if let trip = await FlightCreator.createTrip(idents: ["LSZQ", "LFGA", "LSZQ"], stopovers: [Stopover()],
                                                     template: tripIntent, plans: plans, threads: threads,
                                                     airports: airports, notifications: notifications) {
            made.threadIds += trip.legIds
        }

        // Today's flight, two hours from now on the next five minutes.
        let fiveMinutes: TimeInterval = 300
        let inTwoHours = now.addingTimeInterval(2 * 3600).timeIntervalSinceReferenceDate
        let departure = Date(timeIntervalSinceReferenceDate: (inTwoHours / fiveMinutes).rounded(.up) * fiveMinutes)
        let intent = NewFlightIntent(departureIdent: "LSZQ", arrivalIdent: "LFSB", departureTime: departure,
                                     aircraftTypeId: aircraft.rawValue, aircraftRegistration: aircraft.registration,
                                     aircraftModelName: aircraft.modelName)
        let flight = await FlightCreator.create(from: intent, plans: plans, threads: threads, airports: airports,
                                                notifications: notifications)
        made.threadIds.append(flight.id)

        if let data = try? JSONEncoder().encode(made) { defaults.set(data, forKey: madeKey) }
        AppLog.marketing.debugLine("Dev check scene: \(made.routeIds.count) routes, \(made.threadIds.count) flights")
    }

    /// The last launch's routes and flights, each flight cancelled as "Cancel flight" cancels it (its page, its
    /// place in the trip, its own copy of the route). A flight flown since keeps its logbook entry.
    private static func removeWhatWasMade(appState: AppState, plans: FlightPlanManager, threads: FlightThreadManager,
                                          defaults: UserDefaults) {
        guard let data = defaults.data(forKey: madeKey),
              let made = try? JSONDecoder().decode(Made.self, from: data) else { return }
        let logbookPlanIds = Set(appState.flights.compactMap(\.flightPlanId))
        for id in made.threadIds where threads.thread(withId: id) != nil {
            FlightCreator.cancelLeg(id, plans: plans, threads: threads, logbookPlanIds: logbookPlanIds)
        }
        for id in made.routeIds {
            if let route = plans.flightPlans.first(where: { $0.id == id }) { plans.deleteFlightPlan(route) }
        }
        defaults.removeObject(forKey: madeKey)
    }

    /// A saved route through these aerodromes, each the waypoint the builder's From, To and "+" make, its
    /// contact frequency included; `stops` marks the usual stops, as the waypoint sheet's Land here does.
    private static func makeRoute(_ idents: [String], stops: [String: Stopover] = [:], plans: FlightPlanManager,
                                  airports: AirportDataService) -> FlightPlan? {
        let fields = idents.compactMap { airports.findAirport(byIdent: $0) }
        guard fields.count == idents.count else { return nil }
        let aircraft = AircraftType.wt9Dynamic
        var route = plans.createFlightPlan(name: idents.joined(separator: " → "), aircraftTypeId: aircraft.rawValue,
                                           aircraftRegistration: aircraft.registration,
                                           aircraftModelName: aircraft.modelName)
        route.waypoints = fields.enumerated().map { index, field in
            let frequency = airports.bestFieldFrequency(for: field.ident)?.formattedFrequency
            var waypoint = RoutePoint.aerodrome(field).waypoint(asEndpoint: index == 0 || index == fields.count - 1,
                                                                contactFrequency: frequency)
            waypoint.stopover = stops[field.ident]
            return waypoint
        }
        route.calculateRouteData()
        plans.updateFlightPlan(route)
        return route
    }
}
#endif
