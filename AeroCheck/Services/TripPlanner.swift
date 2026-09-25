import Foundation
import CoreLocation

// MARK: - Trip planning (v5.1)
//
// A trip is a journey of several flights: LSZS → LSZE → LSZQ is two legs, each an ordinary flight with
// its own logbook line, filed flight plan, nav log and close-out (see `Trip`). This file holds the
// PURE rules that turn a route into legs and keep the legs consistent with each other. No services,
// no managers: plans and coordinates in, plans and numbers out, like `ThreadTaskEngine`.

enum TripPlanner {

    // MARK: Splitting a route at a stop

    /// Split a route at the waypoint `index` into the leg that ends there and the leg that starts
    /// there.
    ///
    /// The first leg KEEPS the plan's identity, so a flight that is already followed keeps its plan and
    /// its thread when a stop is added; the second is a new plan. The stop is the end of one and the
    /// start of the other, at field elevation when it is known (the same rule as the endpoints of an
    /// imported SkyDemon route). The alternate belongs to the final destination, so it moves to the
    /// second leg. The second leg's departure is an estimate: the first leg's arrival plus the time on
    /// the ground.
    static func split(_ plan: FlightPlan, at index: Int, stopover: Stopover = Stopover(),
                      stopIdent: String? = nil, fieldElevationFeet: Double? = nil) -> (first: FlightPlan, second: FlightPlan)? {
        guard index > 0, index < plan.waypoints.count - 1 else { return nil }

        var stop = plan.waypoints[index]
        // The stop is named by its ident so the flight thread can find it: PPR, fees and customs are
        // all keyed on ICAO-looking waypoint names.
        if let stopIdent, !stopIdent.isEmpty { stop.name = stopIdent }
        if let fieldElevationFeet { stop.altitude = fieldElevationFeet }
        stop.actualTimeOver = nil

        var first = plan
        first.waypoints = Array(plan.waypoints[..<index]) + [stop]
        first.alternateAerodrome = nil
        first.diversion = nil
        first.calculateRouteData()

        var second = plan.copy()
        // A new identity for the stop's second appearance: waypoint ids are unique within a plan and
        // are what the map and the ATO record key on.
        let departure = FlightPlanWaypoint(
            name: stop.name, coordinate: stop.coordinate, altitude: stop.altitude,
            frequency: stop.frequency, callSign: stop.callSign, remarks: stop.remarks,
            plannedGroundSpeed: stop.plannedGroundSpeed
        )
        second.waypoints = [departure] + Array(plan.waypoints[(index + 1)...])
        for i in second.waypoints.indices { second.waypoints[i].actualTimeOver = nil }
        second.runwayInUse = nil
        second.stopover = stopover
        second.fuelOnBoard = fuelOnBoard(after: first, stopover: stopover, plannedFOB: plan.fuelOnBoard)
        second.plannedDepartureTime = estimatedDeparture(after: first, stopover: stopover)
        second.departureIsEstimate = true
        second.calculateRouteData()
        return (first, second)
    }

    /// Split at several stops at once, in route order. Returns the legs in flying order.
    static func legs(of route: FlightPlan, stops: [(index: Int, stopover: Stopover, ident: String?, elevation: Double?)]) -> [FlightPlan] {
        var remaining = route
        var legs: [FlightPlan] = []
        var consumed = 0
        for stop in stops.sorted(by: { $0.index < $1.index }) {
            let local = stop.index - consumed
            guard let (first, second) = split(remaining, at: local, stopover: stop.stopover,
                                              stopIdent: stop.ident, fieldElevationFeet: stop.elevation)
            else { continue }
            legs.append(first)
            remaining = second
            consumed += local
        }
        legs.append(remaining)
        return legs
    }

    /// Join a leg with the one after it: the reverse of `split`, for two legs neither of which has
    /// flown. The first plan's identity is kept.
    static func join(_ first: FlightPlan, _ second: FlightPlan) -> FlightPlan {
        var joined = first
        joined.waypoints = first.waypoints + second.waypoints.dropFirst()
        joined.alternateAerodrome = second.alternateAerodrome ?? first.alternateAerodrome
        joined.diversion = nil
        joined.calculateRouteData()
        return joined
    }

    // MARK: Numbers that follow from the previous leg

    /// When a leg after a stop departs: the previous leg's arrival (its ETO at the destination, which
    /// already carries the arrival allowance) plus the time on the ground. Nil when the previous leg
    /// has no time at all.
    static func estimatedDeparture(after previous: FlightPlan, stopover: Stopover) -> Date? {
        guard let arrival = previous.waypoints.last?.estimatedTimeOver else { return nil }
        return arrival.addingTimeInterval(TimeInterval(max(0, stopover.groundMinutes)) * 60)
    }

    /// Fuel on board for a leg after a stop: the trip's planned fuel again when the pilot refuels,
    /// otherwise what the previous leg leaves in the tanks. Nil when that cannot be known, so the fuel
    /// task asks rather than showing a number nobody computed.
    static func fuelOnBoard(after previous: FlightPlan, stopover: Stopover, plannedFOB: Double?) -> Double? {
        if stopover.refuel { return plannedFOB }
        guard let onBoard = previous.fuelOnBoard, let burnt = previous.tripFuel else { return nil }
        return max(0, onBoard - burnt)
    }

    /// Re-derive a later leg's estimated departure (and so its ETOs) and, without a refuel, its fuel on
    /// board from the leg before it. Returns nil when nothing changed, so callers write only real
    /// changes. A departure the pilot chose (`departureIsEstimate != true`) is never touched.
    static func refreshed(_ leg: FlightPlan, after previous: FlightPlan) -> FlightPlan? {
        guard leg.departureIsEstimate == true, let stopover = leg.stopover else { return nil }
        var updated = leg
        updated.plannedDepartureTime = estimatedDeparture(after: previous, stopover: stopover)
        // Only when it can be computed: a leg whose previous leg has no fuel figures keeps whatever
        // the pilot entered on it.
        if !stopover.refuel, let carried = fuelOnBoard(after: previous, stopover: stopover, plannedFOB: nil) {
            updated.fuelOnBoard = carried
        }
        guard updated.plannedDepartureTime != leg.plannedDepartureTime
                || updated.fuelOnBoard != leg.fuelOnBoard else { return nil }
        updated.calculateRouteData()
        return updated
    }

    // MARK: Aerodromes along a route

    /// An aerodrome the "Add a stop" list can offer.
    struct Aerodrome: Equatable {
        let ident: String
        let name: String
        let latitude: Double
        let longitude: Double
        let elevationFeet: Double?
        let frequency: String?
        let isPPR: Bool
        /// ISO-2 country, for the border chip in the diversion list.
        var country: String? = nil
        /// The longest open runway, as a pilot reads it ("12/30 · 620 m asphalt").
        var runway: String? = nil

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    /// An aerodrome near the route, placed along it.
    struct StopCandidate: Equatable {
        let aerodrome: Aerodrome
        /// Distance from the departure, along the route, to the point abeam the aerodrome.
        let alongNM: Double
        /// How far off the route it is.
        let offsetNM: Double
        /// The route waypoint that IS this aerodrome, when there is one (within `onRouteNM`).
        let waypointIndex: Int?
    }

    /// Within this, a waypoint is taken to be the aerodrome itself.
    static let onRouteNM = 0.6

    /// Aerodromes within `corridorNM` of the route, in the order they are reached, excluding the
    /// departure and destination themselves.
    static func stopCandidates(along route: [FlightPlanWaypoint], aerodromes: [Aerodrome],
                               corridorNM: Double = 5) -> [StopCandidate] {
        guard route.count >= 2 else { return [] }
        let coordinates = route.map(\.coordinate)
        let geometry = RouteGeometry(route: coordinates)
        let total = geometry.cumulative.last ?? 0
        var result: [StopCandidate] = []
        for aerodrome in aerodromes {
            guard let (along, offset) = geometry.locate(aerodrome.coordinate), offset <= corridorNM else { continue }
            // The two ends are where the flight starts and stops already.
            if along < 1 || along > total - 1 { continue }
            let onRoute = route.indices.dropFirst().dropLast().first { i in
                geometry.distanceNM(route[i].coordinate, aerodrome.coordinate) <= onRouteNM
            }
            result.append(StopCandidate(aerodrome: aerodrome, alongNM: along, offsetNM: offset,
                                        waypointIndex: onRoute))
        }
        return result.sorted { $0.alongNM < $1.alongNM }
    }

    /// The route with `aerodrome` as a waypoint, and that waypoint's index: the waypoint that already
    /// is the aerodrome, or a new one inserted where it lengthens the route least.
    static func routeStopping(at candidate: StopCandidate, in plan: FlightPlan) -> (plan: FlightPlan, index: Int) {
        if let index = candidate.waypointIndex { return (plan, index) }
        var updated = plan
        let index = max(1, min(plan.waypoints.count - 1,
                               FlightPlanManager.bestInsertionIndex(for: candidate.aerodrome.coordinate,
                                                                    in: plan.waypoints)))
        let neighbour = plan.waypoints[index - 1]
        updated.waypoints.insert(FlightPlanWaypoint(name: candidate.aerodrome.ident,
                                                    coordinate: candidate.aerodrome.coordinate,
                                                    altitude: candidate.aerodrome.elevationFeet,
                                                    plannedGroundSpeed: neighbour.plannedGroundSpeed),
                                 at: index)
        updated.calculateRouteData()
        return (updated, index)
    }

    // MARK: Continuing after landing somewhere else

    /// Within this of the planned destination, a landing is AT the destination.
    static let destinationToleranceNM = 2.0

    /// The plan as flown, once the flight has landed at `field`: a diversion is recorded when the
    /// flight ended anywhere but its destination, whether or not the pilot pressed Divert. END FLIGHT
    /// knows where the aircraft stopped, and that is a fact — no guessing about intentions in the air.
    ///
    /// A diversion made in the air keeps its start time and where it left the route; one found only
    /// now left the route after the last waypoint the track actually passed.
    static func settlingDiversion(_ plan: FlightPlan, landedAt field: Aerodrome?, landing: Date?) -> FlightPlan {
        guard let field, let destination = plan.waypoints.last, plan.waypoints.count >= 2 else { return plan }
        var settled = plan
        let geometry = RouteGeometry(route: [destination.coordinate])
        let atDestination = field.ident.uppercased() == destination.name.uppercased()
            || geometry.distanceNM(field.coordinate, destination.coordinate) <= destinationToleranceNM
        if var diversion = plan.diversion {
            if diversion.ident != field.ident {
                // Went somewhere else again: where it landed is what counts.
                diversion = Diversion(ident: field.ident, name: field.name, latitude: field.latitude,
                                      longitude: field.longitude, elevationFeet: field.elevationFeet,
                                      frequency: field.frequency, startedAt: diversion.startedAt,
                                      leftRouteAt: diversion.leftRouteAt)
            }
            // Diverted, then went to the destination after all: no diversion.
            settled.diversion = atDestination ? nil : diversion
            settled.diversion?.landedAt = landing
            return settled
        }
        guard !atDestination else { return plan }
        let lastPassed = plan.waypoints.lastIndex { $0.actualTimeOver != nil } ?? 0
        settled.diversion = Diversion(ident: field.ident, name: field.name, latitude: field.latitude,
                                      longitude: field.longitude, elevationFeet: field.elevationFeet,
                                      frequency: field.frequency, startedAt: nil,
                                      leftRouteAt: min(lastPassed + 1, plan.waypoints.count - 1),
                                      landedAt: landing)
        return settled
    }

    /// The next leg after a diversion: from the aerodrome the flight landed at, back onto the route,
    /// and along the rest of it to the original destination.
    ///
    /// The rejoin point is the first remaining waypoint PAST the diversion field along the route, so
    /// the pilot never flies back over ground already covered, and the rest of the route (built around
    /// airspace and terrain) is kept. "Shortest way to the destination" would be the wrong rule: by
    /// the triangle inequality it always means straight there, throwing the route away.
    static func continuation(of original: FlightPlan, from field: Aerodrome) -> FlightPlan {
        let first = min(max(0, original.diversion?.leftRouteAt ?? 1), original.waypoints.count - 1)
        let tail = Array(original.waypoints[first...])
        var rejoin = tail.count - 1
        if tail.count >= 2 {
            let geometry = RouteGeometry(route: tail.map(\.coordinate))
            if let (along, _) = geometry.locate(field.coordinate),
               let past = geometry.cumulative.firstIndex(where: { $0 > along + onRouteNM }) {
                rejoin = past
            }
        }

        var plan = original.copy()
        let departure = FlightPlanWaypoint(name: field.ident, coordinate: field.coordinate,
                                           altitude: field.elevationFeet,
                                           frequency: nil,
                                           plannedGroundSpeed: tail[rejoin].plannedGroundSpeed)
        // Joining at the destination itself means flying straight there.
        plan.waypoints = [departure] + Array(tail[rejoin...])
        for i in plan.waypoints.indices { plan.waypoints[i].actualTimeOver = nil }
        plan.diversion = nil
        plan.runwayInUse = nil
        plan.plannedDepartureTime = nil
        plan.departureIsEstimate = nil
        plan.stopover = nil
        plan.fuelOnBoard = nil
        plan.calculateRouteData()
        return plan
    }
}

// MARK: - Route geometry

/// Flat geometry along a route, in nautical miles. Routes are tens of miles long, so a local
/// equirectangular projection is well inside the precision any of this needs.
struct RouteGeometry {
    let points: [(x: Double, y: Double)]
    let cumulative: [Double]
    private let cosLat: Double

    init(route: [CLLocationCoordinate2D]) {
        let lat = route.map(\.latitude).reduce(0, +) / Double(max(1, route.count))
        cosLat = cos(lat * .pi / 180)
        let cosLat = self.cosLat
        points = route.map { ($0.longitude * 60 * cosLat, $0.latitude * 60) }
        var cumulative: [Double] = [0]
        for i in points.indices.dropFirst() {
            cumulative.append(cumulative[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
        }
        self.cumulative = cumulative
    }

    func xy(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        (c.longitude * 60 * cosLat, c.latitude * 60)
    }

    func distanceNM(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let p = xy(a), q = xy(b)
        return hypot(p.x - q.x, p.y - q.y)
    }

    /// Along-route distance of `p` projected onto leg `k` (clamped to the leg) and its offset from it.
    func project(_ p: (x: Double, y: Double), onto k: Int) -> (along: Double, offset: Double) {
        let a = points[k], b = points[k + 1]
        let vx = b.x - a.x, vy = b.y - a.y
        let length2 = vx * vx + vy * vy
        guard length2 > 0 else { return (cumulative[k], hypot(p.x - a.x, p.y - a.y)) }
        let t = min(1, max(0, ((p.x - a.x) * vx + (p.y - a.y) * vy) / length2))
        return (cumulative[k] + t * sqrt(length2), hypot(p.x - (a.x + t * vx), p.y - (a.y + t * vy)))
    }

    /// Where a point sits along the whole route: the nearest leg's along-route distance and offset.
    func locate(_ c: CLLocationCoordinate2D) -> (along: Double, offset: Double)? {
        guard points.count >= 2 else { return nil }
        let p = xy(c)
        return (0..<(points.count - 1)).map { project(p, onto: $0) }.min { $0.offset < $1.offset }
    }
}
