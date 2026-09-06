import Foundation
import CoreLocation

// MARK: - New flight intent (v5.0.0)
//
// What a pilot knows before they know a route: when, which aircraft, roughly where, and what kind of
// flying. This is the input to "Plan new flight", and it is deliberately the ONLY way a flight comes
// into existence — one sheet, one code path, however many doors lead into it.
//
// It is also what makes "Plan this again" safe. A duplicate is expressed as an intent, and an intent
// has no notion of task state, so preparation CANNOT be carried across a duplication even by
// accident. That rule is enforced by the type rather than by remembering it: a flight plan filed last
// Saturday is not filed this Saturday, and customs notified for last week's crossing is not notified
// for this one. A duplicated flight arriving with its preparation pre-ticked would be a checklist
// lying about work nobody did.

/// The two shapes of flying the app follows, which decide how much admin a flight carries.
enum FlightKind: String, CaseIterable, Sendable {
    /// Somewhere and back, or somewhere else entirely: the full admin bracket.
    case crossCountry
    /// Circuits at one field: weather, DABS, logbook, debrief, and nothing that only matters when
    /// you leave the pattern.
    case circuits

    var profile: ThreadProfile { self == .circuits ? .local : .full }
}

/// A flight the pilot intends to make. No task state, by construction — see the note above.
struct NewFlightIntent: Equatable, Sendable {
    var departureIdent: String = ""
    var arrivalIdent: String = ""
    var departureTime: Date?
    var aircraftTypeId: String
    var aircraftRegistration: String
    var aircraftModelName: String
    var kind: FlightKind = .crossCountry

    /// Circuits start and finish at the same field, so the pilot is asked for one aerodrome and the
    /// arrival follows it. Keeping them in step here means the rest of the app never has to special-
    /// case a circuit's "destination".
    var resolvedArrivalIdent: String {
        kind == .circuits ? departureIdent : arrivalIdent
    }

    /// Enough to be worth creating. A flight with no departure is not a flight yet; everything else,
    /// including the route, can arrive later.
    var isCreatable: Bool {
        !departureIdent.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The label the thread carries, captured now so it still reads correctly after the plan it came
    /// from is edited or deleted.
    var routeLabel: String {
        let from = departureIdent.uppercased()
        let to = resolvedArrivalIdent.uppercased()
        if kind == .circuits { return L10n.Flights.circuitsAt(from) }
        guard !to.isEmpty, to != from else { return from }
        return "\(from) → \(to)"
    }
}

// MARK: - Building a plan from an intent

extension FlightPlan {

    /// Turn an intent into a flight plan, resolving each end to a waypoint where the aerodrome is
    /// known.
    ///
    /// `resolve` is injected rather than reaching for `AirportDataService`, which keeps this pure and
    /// testable and lets the caller decide whether the airport layer is loaded.
    ///
    /// An ident that does not resolve produces NO waypoint rather than a guessed one. That matters
    /// more than it looks: the country detection behind customs, DABS and GAFOR runs on coordinates,
    /// so a fabricated position would put a flight in the wrong country — which is the defect this
    /// release already had to fix once.
    static func from(intent: NewFlightIntent,
                     resolve: (String) -> CLLocationCoordinate2D?) -> FlightPlan {
        var plan = FlightPlan(
            name: intent.routeLabel,
            aircraftTypeId: intent.aircraftTypeId,
            aircraftRegistration: intent.aircraftRegistration,
            aircraftModelName: intent.aircraftModelName,
            plannedDepartureTime: intent.departureTime,
            fuelFlow: FlightPlan.defaultFuelFlow(for: intent.aircraftTypeId)
        )

        // Circuits are one field, not a leg: two identical waypoints would draw a zero-length route
        // and invite a division by zero downstream.
        var idents = [intent.departureIdent]
        if intent.kind != .circuits, !intent.arrivalIdent.isEmpty,
           intent.arrivalIdent.uppercased() != intent.departureIdent.uppercased() {
            idents.append(intent.arrivalIdent)
        }

        plan.waypoints = idents.compactMap { ident -> FlightPlanWaypoint? in
            let trimmed = ident.trimmingCharacters(in: .whitespaces).uppercased()
            guard !trimmed.isEmpty, let coordinate = resolve(trimmed) else { return nil }
            return FlightPlanWaypoint(name: trimmed, coordinate: coordinate)
        }
        plan.calculateRouteData()
        return plan
    }
}

// MARK: - Duplicating

extension NewFlightIntent {

    /// "Plan this again" from a flight already flown. Carries the route, the aircraft and the shape
    /// of the flying; carries no preparation, because an intent cannot hold any.
    ///
    /// The departure time is deliberately dropped rather than shifted by a week — the app has no idea
    /// when you intend to fly it again, and a plausible wrong time in a flight plan is worse than an
    /// empty one the pilot fills in.
    init(duplicating flight: Flight) {
        self.init(
            departureIdent: flight.departureAirportIdent ?? "",
            arrivalIdent: flight.arrivalAirportIdent ?? "",
            departureTime: nil,
            aircraftTypeId: flight.flightPlan?.aircraftTypeId ?? flight.airplane,
            aircraftRegistration: flight.aircraftRegistration ?? "",
            aircraftModelName: flight.aircraftType ?? "",
            // A flight that returned to its departure field, with more than one landing, was circuits.
            // Getting this wrong only costs the pilot a segmented control they can flip.
            kind: Self.inferredKind(for: flight)
        )
    }

    /// "Plan this again" from a saved plan.
    init(duplicating plan: FlightPlan) {
        let idents = plan.waypoints.map(\.name)
        self.init(
            departureIdent: idents.first ?? "",
            arrivalIdent: idents.last ?? "",
            departureTime: nil,
            aircraftTypeId: plan.aircraftTypeId,
            aircraftRegistration: plan.aircraftRegistration,
            aircraftModelName: plan.aircraftModelName,
            kind: (idents.count > 1 && idents.first == idents.last) ? .circuits : .crossCountry
        )
    }

    static func inferredKind(for flight: Flight) -> FlightKind {
        guard let departure = flight.departureAirportIdent, !departure.isEmpty else {
            return .crossCountry
        }
        let sameField = (flight.arrivalAirportIdent ?? departure) == departure
        return (sameField && flight.totalLandings > 1) ? .circuits : .crossCountry
    }
}
