import Foundation

// MARK: - A trip on Today and in Plan › Flights (6.1)
//
// Once a trip existed, both screens showed its first leg and nothing else: Today as a plain flight,
// with no word of a trip, and Plan › Flights as leg 1's map under "TRIP · LEG 1 OF 3" in small print.
// Legs 2 and 3 appeared nowhere on either screen. A pilot who had planned three flights in a row saw
// one, and had to open it to find the others.
//
// This is what both screens say about a trip instead: every leg in flying order, the one the card is
// about, which have flown, when each leaves, and what is next. It is pure, so the four states that
// matter (a single flight, leg 1, mid-trip, after the last leg) are pinned by tests rather than by
// looking at a screen.

/// A trip as Today and Plan › Flights show it.
struct TripOverview: Equatable {

    /// One leg, as a chip on Today and a row in Plan › Flights.
    struct Leg: Identifiable, Equatable {
        /// The leg's thread.
        let id: UUID
        /// One-based, as on the leg page.
        let number: Int
        /// "LSZQ → LSGE": the aerodromes, not the leg's name, so the chips read as a chain.
        let route: String
        /// What the leg is called elsewhere: its name, else its route.
        let displayName: String
        /// When it leaves: the firm departure, else the estimate a later leg carries (the leg before
        /// lands, plus the time on the ground), else nil.
        let departure: Date?
        let departureIsEstimate: Bool
        let state: FlightThreadState
        /// Landed: it has a recorded flight and is closing out or done. The leg page's rule.
        let isFlown: Bool
        /// Nautical miles and seconds, 0 when the leg has no route yet.
        let distance: Double
        let eet: TimeInterval
        /// The leg's own pre-flight checks (the trip's shared ones are counted once, on the trip).
        let checksDone: Int
        let checksTotal: Int
    }

    let tripId: UUID
    /// The pilot's name for the trip, if any.
    let name: String?
    let legs: [Leg]
    /// The leg the card is about: the next to fly, the one flying, or the one closing out.
    let focusId: UUID

    var legCount: Int { legs.count }
    var focus: Leg? { legs.first { $0.id == focusId } }

    /// "LSZQ → LSGE → LSGN → LSZQ": the first leg's departure, then where each leg lands. Built from
    /// the legs rather than stored, so it stays right when one is added or removed.
    ///
    /// A leg that doesn't leave from where the one before landed (a flight that landed elsewhere, the next leg still
    /// from the planned field) starts again with its own departure, after a dot: "LSZQ → EDSB · EDTF → LSZQ", never
    /// "LSZQ → EDSB → LSZQ". (6.6.0)
    var chain: String {
        guard let first = legs.first else { return "" }
        var segments: [[String]] = [[Self.ends(of: first.route).from]]
        for leg in legs {
            let (from, to) = Self.ends(of: leg.route)
            if let last = segments[segments.count - 1].last, !from.isEmpty, from != last {
                segments.append([from])
            }
            segments[segments.count - 1].append(to)
        }
        return segments.map { $0.filter { !$0.isEmpty }.joined(separator: " → ") }.joined(separator: " · ")
    }

    var totalDistance: Double { legs.reduce(0) { $0 + $1.distance } }
    /// The legs' flight times added up; the time on the ground at the stops is not in it.
    var totalEET: TimeInterval { legs.reduce(0) { $0 + $1.eet } }

    /// Nil when there is no trip to show: fewer than two legs found, or `focus` isn't one of them.
    /// The card then falls back to the single flight it has always shown.
    ///
    /// - Parameters:
    ///   - legs: the trip's legs, in flying order (`FlightThreadManager.legs(of:)`), flown ones included.
    ///   - focus: the leg the card is about.
    ///   - plan: a leg's own plan, for its times and figures.
    init?(trip: Trip, legs: [FlightThread], focus: UUID, plan: (FlightThread) -> FlightPlan?) {
        guard legs.count >= 2, legs.contains(where: { $0.id == focus }) else { return nil }
        tripId = trip.id
        name = trip.name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        focusId = focus
        self.legs = legs.enumerated().map { index, leg in
            let legPlan = plan(leg)
            let estimate = leg.scheduledDeparture == nil && legPlan?.departureIsEstimate == true
                ? legPlan?.plannedDepartureTime : nil
            let progress = leg.preFlightProgress
            return Leg(id: leg.id,
                       number: index + 1,
                       route: leg.routeLabel,
                       displayName: leg.displayName,
                       departure: leg.scheduledDeparture ?? estimate,
                       departureIsEstimate: leg.scheduledDeparture == nil && estimate != nil,
                       state: leg.state,
                       isFlown: leg.flightId != nil && (leg.state == .closeOut || leg.state == .done),
                       distance: legPlan.map { $0.waypoints.count >= 2 ? $0.totalDistance : 0 } ?? 0,
                       eet: legPlan.map { $0.waypoints.count >= 2 ? $0.totalEET : 0 } ?? 0,
                       checksDone: progress.done,
                       checksTotal: progress.total)
        }
    }

    /// "LSZQ → LSGE" into its two ends. A label with no arrow is its own both ends.
    static func ends(of route: String) -> (from: String, to: String) {
        let parts = route.components(separatedBy: " → ")
        return (parts.first ?? route, parts.last ?? route)
    }

    // MARK: - Words

    /// "Leg 1 · LSZQ → LSGE": the line under START FLIGHT, naming the leg it starts.
    var startLine: String? {
        focus.map { L10n.TripCard.startLeg($0.number, $0.route) }
    }
}

// MARK: - START FLIGHT on Today

/// What START FLIGHT on Today says: the action, and for a trip the leg it starts.
struct StartFlightLabel: Equatable {
    let title: String
    let leg: String?

    /// - Parameters:
    ///   - hero: today's flight (`FlightThreadManager.startableFlightToday`), nil when START would
    ///     start a flight of its own.
    ///   - trip: the hero's trip, when it is a leg of one.
    static func make(hero: FlightThread?, trip: TripOverview?) -> StartFlightLabel {
        guard let hero else { return .init(title: L10n.Button.startFlight, leg: nil) }
        let leg = trip?.focusId == hero.id ? trip?.startLine : nil
        if hero.state == .flying { return .init(title: L10n.Home.resumeThisFlight, leg: leg) }
        // A trip's leg: START FLIGHT, and the leg under it. "Start this flight" would leave the pilot
        // to work out which of the three it is.
        if let leg { return .init(title: L10n.Button.startFlight, leg: leg) }
        return .init(title: L10n.Home.startThisFlight, leg: nil)
    }
}
