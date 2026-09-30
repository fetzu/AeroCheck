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

// MARK: - Stops in Plan new flight (6.1)
//
// The aerodromes the pilot types, in flying order. FROM is first and TO is last, always: they are the
// flight itself, so they can be cleared but not removed, and they never move. Every row between them
// is a STOP, an aerodrome the aircraft lands at, which makes the flight a trip with one leg per pair.
//
// "Add a stop on the way" puts the new stop just before TO. It used to append a row after the last
// one, so a pilot who typed LSZQ, LSZQ (the two empty rows read as From and To) and then added LSGE
// got LSZQ → LSZQ → LSGE: a local flight, then a leg away from home. Now it is LSZQ → LSGE → LSZQ,
// the round trip they meant. (trips proposal, M1)

struct PlannedStops: Equatable {

    struct Row: Identifiable, Equatable {
        let id: UUID
        var ident: String
        /// The time on the ground here and whether the aircraft refuels, before the next leg. Only a
        /// stop's is used: nothing waits at FROM, and the trip ends at TO.
        var stopover: Stopover

        init(id: UUID = UUID(), ident: String = "", stopover: Stopover = Stopover()) {
            self.id = id
            self.ident = ident
            self.stopover = stopover
        }

        /// Typed by hand, so trimmed and upper-cased once here rather than at every comparison.
        var normalisedIdent: String { ident.trimmingCharacters(in: .whitespaces).uppercased() }
    }

    enum Role: Equatable {
        case from
        /// The stop's number, from 1.
        case stop(Int)
        case to
    }

    /// FROM, the stops, TO. Never fewer than two rows.
    private(set) var rows: [Row]

    init(from: String = "", to: String = "") {
        rows = [Row(ident: from), Row(ident: to)]
    }

    /// The rows Plan new flight opens with: what the sheet was seeded with ("Plan this again" brings
    /// its flight's FROM and TO), else the home aerodrome as FROM and as TO, back home, when Settings
    /// has one. A pilot mostly flies from where they are based, and mostly back to it; adding a stop
    /// then makes the round trip, and typing over TO a flight elsewhere. (6.1)
    static func opening(for intent: NewFlightIntent, home: String?) -> PlannedStops {
        let seeded = !intent.departureIdent.trimmingCharacters(in: .whitespaces).isEmpty
            || !intent.arrivalIdent.trimmingCharacters(in: .whitespaces).isEmpty
        guard !seeded, let home = HomeAerodrome.normalized(home) else {
            return PlannedStops(from: intent.departureIdent, to: intent.arrivalIdent)
        }
        return PlannedStops(from: home, to: home)
    }

    /// The indices of the stops in `rows`: everything between FROM and TO.
    var stopIndices: Range<Int> { 1..<(rows.count - 1) }

    func role(at index: Int) -> Role {
        if index == 0 { return .from }
        if index == rows.count - 1 { return .to }
        return .stop(index)
    }

    func index(of id: UUID) -> Int? { rows.firstIndex { $0.id == id } }

    /// A new, empty stop just before TO; its id, so the sheet can focus it.
    @discardableResult
    mutating func addStop() -> UUID {
        let row = Row()
        rows.insert(row, at: rows.count - 1)
        return row.id
    }

    /// Take a stop away. FROM and TO are the flight itself: they can be cleared, not removed.
    mutating func removeStop(_ id: UUID) {
        guard let index = index(of: id), stopIndices.contains(index) else { return }
        rows.remove(at: index)
    }

    /// Move a stop to `destination` (an index in `rows`), kept among the stops: FROM and TO don't move.
    mutating func moveStop(_ id: UUID, to destination: Int) {
        guard let from = index(of: id), stopIndices.contains(from) else { return }
        let target = min(max(destination, stopIndices.lowerBound), stopIndices.upperBound - 1)
        guard target != from else { return }
        rows.insert(rows.remove(at: from), at: target)
    }

    mutating func setIdent(_ ident: String, for id: UUID) {
        guard let index = index(of: id) else { return }
        rows[index].ident = ident
    }

    mutating func setStopover(_ stopover: Stopover, for id: UUID) {
        guard let index = index(of: id) else { return }
        rows[index].stopover = stopover
    }

    /// The rows with an aerodrome typed in, in order. Blank rows are left out everywhere: a stop the
    /// pilot added and did not fill in must not become a leg to nowhere.
    var filledRows: [Row] { rows.filter { !$0.normalisedIdent.isEmpty } }

    /// The aerodromes in flying order, trimmed and upper-cased.
    var idents: [String] { filledRows.map(\.normalisedIdent) }

    /// The stop at each aerodrome between the first and the last of `idents`, in order: `stopovers[i]`
    /// is the stop in front of leg `i + 2`, as `FlightCreator.createTrip` takes them.
    var stopovers: [Stopover] {
        let filled = filledRows
        guard filled.count > 2 else { return [] }
        return filled.dropFirst().dropLast().map(\.stopover)
    }

    /// Two aerodromes make one leg, and each stop one more.
    var legCount: Int { max(0, idents.count - 1) }

    /// The aerodrome typed twice in a row, if one is: FROM = TO with no stop between is a local flight.
    var repeatedIdent: String? {
        let clean = idents
        return zip(clean, clean.dropFirst()).first { $0 == $1 }?.0
    }
}

// MARK: - Landing on the way, from a saved route (6.1)
//
// A saved route passes aerodromes: the ones it was drawn through, and others near it. Plan new flight
// lists them in flying order, each with a "Land here" switch, and the route is split at the ones
// switched on, each leg keeping its part of the route. With every switch off it stays one flight: a
// landing is a decision for one day's flight, so it is never stored on the route. (trips proposal, M2)

struct RouteLandings: Equatable {

    /// On the route or within its corridor, in flying order, and any aerodrome added with "Land
    /// somewhere else…", placed along the route like the others.
    private(set) var candidates: [TripPlanner.StopCandidate] = []
    /// The aerodromes switched on, by ident, with the stop there: the time on the ground and the refuel.
    private(set) var stopovers: [String: Stopover] = [:]

    init(candidates: [TripPlanner.StopCandidate] = []) {
        self.candidates = candidates.sorted { $0.alongNM < $1.alongNM }
    }

    func isLanding(at ident: String) -> Bool { stopovers[ident] != nil }

    /// "Land here" on or off. Switched off and on again, a stop starts over from the default.
    mutating func setLanding(_ landing: Bool, at ident: String) {
        guard candidates.contains(where: { $0.aerodrome.ident == ident }) else { return }
        stopovers[ident] = landing ? (stopovers[ident] ?? Stopover()) : nil
    }

    /// "Land somewhere else…": the aerodrome joins the list in its place along the route, switched on.
    mutating func add(_ candidate: TripPlanner.StopCandidate) {
        if !candidates.contains(where: { $0.aerodrome.ident == candidate.aerodrome.ident }) {
            candidates.append(candidate)
            candidates.sort { $0.alongNM < $1.alongNM }
        }
        setLanding(true, at: candidate.aerodrome.ident)
    }

    mutating func setStopover(_ stopover: Stopover, at ident: String) {
        guard isLanding(at: ident) else { return }
        stopovers[ident] = stopover
    }

    /// The landings, in flying order, for `TripPlanner.legs(of:landingAt:)`.
    var landings: [TripPlanner.Landing] {
        candidates.compactMap { candidate in
            stopovers[candidate.aerodrome.ident].map { TripPlanner.Landing(candidate: candidate, stopover: $0) }
        }
    }

    /// One flight with no landing; each landing adds a leg.
    var legCount: Int { landings.count + 1 }
}

// MARK: - What Plan new flight creates (6.1)

/// What the pilot asked for in Plan new flight, for `FlightCreator.create(_:)`: the typed aerodromes,
/// the intent (when, which aircraft), and, from a saved route, the route and where to land on it.
struct PlannedFlight {
    var stops: PlannedStops
    var intent: NewFlightIntent
    /// The saved route the flight is copied from; nil when the aerodromes were typed.
    var route: FlightPlan?
    /// Where the route is landed at on the way, in flying order: none keeps it one flight.
    var landings: [TripPlanner.Landing] = []
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
    /// What the route builder needs to know about an aerodrome: where it is, and how high.
    struct ResolvedPlace {
        let coordinate: CLLocationCoordinate2D
        /// Field elevation in feet AMSL, when the airport data knows it.
        let elevationFeet: Double?

        init(coordinate: CLLocationCoordinate2D, elevationFeet: Double? = nil) {
            self.coordinate = coordinate
            self.elevationFeet = elevationFeet
        }
    }

    /// Cruise height above an aerodrome overflown en route.
    ///
    /// A placeholder with a reason rather than a forecast: none of the data the app currently carries
    /// says how high a pilot intends to cross a field, and leaving the altitude empty means the route
    /// profile has nothing to draw and the ICAO level field stays blank. 4000 ft AGL clears a
    /// standard circuit by a wide margin and is an ordinary VFR transit height — and it is the
    /// pilot's to change on the waypoint, which is why it goes in as a value rather than a guess
    /// dressed up as a computation. (v5.x)
    static let overflightHeightAboveField: Double = 4000

    static func from(intent: NewFlightIntent,
                     resolve: (String) -> ResolvedPlace?) -> FlightPlan {
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

        let resolved = idents.compactMap { ident -> (String, ResolvedPlace)? in
            let trimmed = ident.trimmingCharacters(in: .whitespaces).uppercased()
            guard !trimmed.isEmpty, let place = resolve(trimmed) else { return nil }
            return (trimmed, place)
        }

        // Altitudes come from the field itself. The ends sit ON the ground — that is what departure
        // and arrival mean — and anything in between is overflown, so it gets the field elevation
        // plus a transit height. Without this every waypoint was nil, which left the route profile
        // with nothing to plot and the ICAO level field empty. Nil elevation stays nil: an invented
        // altitude in a flight plan is worse than a blank one the pilot fills in. (device pass)
        plan.waypoints = resolved.enumerated().map { index, entry in
            let (name, place) = entry
            let isEndpoint = index == 0 || index == resolved.count - 1
            let altitude = place.elevationFeet.map { elevation in
                isEndpoint ? elevation : elevation + Self.overflightHeightAboveField
            }
            return FlightPlanWaypoint(name: name, coordinate: place.coordinate, altitude: altitude)
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
