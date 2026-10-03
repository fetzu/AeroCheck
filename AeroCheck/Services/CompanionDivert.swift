import Foundation
import CoreLocation

// MARK: - Divert from the Companion iPhone (6.2.0)
//
// The phone picks a field from its own airport data and sends it; the iPad diverts through its own
// Divert sheet's entry points (`FlightPlanManager.divert(to:)`, and `directTo(waypointAt:)` for the
// route's destination), so a diversion started on the phone is the iPad's in every way: the nav target,
// the nav log, the thread's TELL FIS, the Watch. The rules both ends share are here, pure; only the
// last function touches a manager.

enum CompanionDivert {

    // MARK: - The phone's list

    /// One field in the phone's list.
    struct Row: Equatable, Identifiable {
        let aerodrome: TripPlanner.Aerodrome
        /// True bearing from the aircraft, as the iPad's Divert sheet gives it. Nil without a position.
        let bearing: Double?
        let distanceNM: Double?
        /// The route's destination: going there is "direct to", not a diversion, as on the iPad.
        let isDestination: Bool

        var id: String { aerodrome.ident }
    }

    /// The iPad's sheet lists within this range; so does the phone.
    static let rangeNM = DivertPlanner.rangeNM
    /// Fields in the nearest list: a phone screen and a bit.
    static let maxNearest = 8
    /// How long this phone's own fix stands in for the aircraft's position.
    static let ownFixMaxAge: TimeInterval = 30

    /// The nearest fields first, within `rangeNM`, at most `limit`. Equal distances go by ident, so the
    /// order never flickers; an ident listed twice counts once.
    static func nearest(from position: CLLocationCoordinate2D, aerodromes: [TripPlanner.Aerodrome],
                        destinationIdent: String?, lastWaypointName: String?,
                        limit: Int = maxNearest) -> [Row] {
        var seen = Set<String>()
        let unique = aerodromes.filter { seen.insert($0.ident.uppercased()).inserted }
        let measured: [Row] = rows(unique, from: position, destinationIdent: destinationIdent,
                                   lastWaypointName: lastWaypointName)
        let inRange: [Row] = measured.filter { ($0.distanceNM ?? .infinity) <= rangeNM }
        let sorted: [Row] = inRange.sorted(by: isNearer)
        return Array(sorted.prefix(max(0, limit)))
    }

    /// Nearer first; at the same distance, by ident.
    private static func isNearer(_ a: Row, _ b: Row) -> Bool {
        let da = a.distanceNM ?? .infinity
        let db = b.distanceNM ?? .infinity
        if da != db { return da < db }
        return a.aerodrome.ident < b.aerodrome.ident
    }

    /// `aerodromes` in their own order (a search's relevance, or a list already shown, whose order must
    /// not move under the pilot's finger), measured from `position` when there is one.
    static func rows(_ aerodromes: [TripPlanner.Aerodrome], from position: CLLocationCoordinate2D?,
                     destinationIdent: String?, lastWaypointName: String?) -> [Row] {
        let origin: CLLocation? = position.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        return aerodromes.map { (aerodrome: TripPlanner.Aerodrome) -> Row in
            var bearing: Double?
            var distance: Double?
            if let position, let origin {
                let there = CLLocation(latitude: aerodrome.latitude, longitude: aerodrome.longitude)
                bearing = position.bearing(to: aerodrome.coordinate)
                distance = origin.distance(from: there) / 1852
            }
            let destination = isDestination(aerodrome.ident, destinationIdent: destinationIdent,
                                            lastWaypointName: lastWaypointName)
            return Row(aerodrome: aerodrome, bearing: bearing, distanceNM: distance, isDestination: destination)
        }
    }

    /// Where the list is measured from: the aircraft's position as the iPad streams it (the one the NAV
    /// screen's arrow uses, and this phone's own GPS when the iPad borrows it), else this phone's own
    /// recent fix. Nil when there is neither: the list is then a search only.
    static func reference(streamedLatitude: Double?, streamedLongitude: Double?, ownFix: CLLocation?,
                          now: Date) -> CLLocationCoordinate2D? {
        if let latitude = streamedLatitude, let longitude = streamedLongitude,
           CompanionWireLimits.isValidCoordinate(latitude: latitude, longitude: longitude) {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        guard let ownFix, ownFix.horizontalAccuracy >= 0,
              CompanionWireLimits.isValidCoordinate(latitude: ownFix.coordinate.latitude,
                                                    longitude: ownFix.coordinate.longitude),
              abs(now.timeIntervalSince(ownFix.timestamp)) <= ownFixMaxAge else { return nil }
        return ownFix.coordinate
    }

    // MARK: - The route's destination (both ends)

    /// Whether `ident` is the route's destination. `destinationIdent` is the aerodrome the iPad's Divert
    /// sheet takes for it (`AirportDataService.routeDestinationIdent`); without one, the last
    /// waypoint's own name, when it is the ident.
    static func isDestination(_ ident: String, destinationIdent: String?, lastWaypointName: String?) -> Bool {
        guard let candidate = destinationIdent ?? lastWaypointName, !candidate.isEmpty, !ident.isEmpty else {
            return false
        }
        return candidate.caseInsensitiveCompare(ident) == .orderedSame
    }

    // MARK: - A request, until the iPad shows it taken (the phone)

    /// What the phone sent, sent again until the iPad's plan snapshot shows it taken.
    ///
    /// A command goes once over UDP and is not resent, and the first one of a connection only raises the
    /// iPad's "Allow companion control?" and is dropped (S9-08): sent once, a Divert tapped before the
    /// pilot allowed the phone, or lost on the way, did nothing and said nothing. Sent again every few
    /// seconds, it goes through as soon as the pilot allows it. The iPad takes the same request twice as
    /// once (`action(for:plan:own:destinationIdent:)` does nothing for where the aircraft already goes),
    /// and the phone stops at the first snapshot that shows it, or after `giveUpAfter`.
    struct Request {
        enum Goal: Equatable {
            /// Diverting to that field.
            case divert(ident: String)
            /// Back on the route, to its last waypoint: a field that is the route's destination.
            case destination
            /// Back on the route.
            case resume
        }

        enum Step: Equatable {
            /// The snapshot shows it: done.
            case taken
            /// Send it again now.
            case resend
            /// Nothing to do this time.
            case wait
            /// Not taken in `giveUpAfter`: the phone says so and sends no more.
            case gaveUp
        }

        static let resendInterval: TimeInterval = 2
        static let giveUpAfter: TimeInterval = 30

        let goal: Goal
        let command: CompanionCommand
        let firstSent: Date
        private(set) var lastSent: Date
        private(set) var gaveUp = false

        init(goal: Goal, command: CompanionCommand, sentAt: Date) {
            self.goal = goal
            self.command = command
            self.firstSent = sentAt
            self.lastSent = sentAt
        }

        /// The ident of the field it goes to, for the row that shows it.
        var ident: String? {
            if case .divert(let ident) = goal { return ident }
            return nil
        }

        func isTaken(by plan: CompanionFlightPlanSnapshot?) -> Bool {
            guard let plan else { return false }
            switch goal {
            case .divert(let ident):
                return plan.diversion?.name.caseInsensitiveCompare(ident) == .orderedSame
            case .destination:
                return plan.diversion == nil && plan.currentWaypointIndex == plan.waypoints.count - 1
            case .resume:
                return plan.diversion == nil
            }
        }

        /// What to do at `now`, the latest plan snapshot in hand. A request taken late, after the phone
        /// gave up, still counts as taken.
        mutating func step(now: Date, plan: CompanionFlightPlanSnapshot?) -> Step {
            if isTaken(by: plan) { return .taken }
            if gaveUp { return .wait }
            if now.timeIntervalSince(firstSent) >= Self.giveUpAfter {
                gaveUp = true
                return .gaveUp
            }
            guard now.timeIntervalSince(lastSent) >= Self.resendInterval else { return .wait }
            lastSent = now
            return .resend
        }
    }

    // MARK: - The wire

    /// A field as the phone sends it.
    static func field(_ aerodrome: TripPlanner.Aerodrome) -> CompanionDivertField {
        CompanionDivertField(ident: aerodrome.ident, name: aerodrome.name, latitude: aerodrome.latitude,
                             longitude: aerodrome.longitude, elevationFeet: aerodrome.elevationFeet,
                             frequency: aerodrome.frequency)
    }

    /// The field the iPad diverts to: its own record of the ident when it has one (`own`), what it
    /// lacks taken from the phone's; else the phone's field as sent.
    static func aerodrome(_ field: CompanionDivertField, own: TripPlanner.Aerodrome?) -> TripPlanner.Aerodrome {
        guard let own else {
            return TripPlanner.Aerodrome(ident: field.ident, name: field.name.isEmpty ? field.ident : field.name,
                                         latitude: field.latitude, longitude: field.longitude,
                                         elevationFeet: field.elevationFeet, frequency: field.frequency,
                                         isPPR: false)
        }
        return TripPlanner.Aerodrome(ident: own.ident, name: own.name, latitude: own.latitude,
                                     longitude: own.longitude, elevationFeet: own.elevationFeet ?? field.elevationFeet,
                                     frequency: own.frequency ?? field.frequency, isPPR: own.isPPR,
                                     country: own.country, runway: own.runway, type: own.type)
    }

    // MARK: - The iPad

    /// What the iPad does with a field from the phone.
    enum Action: Equatable {
        /// Already where the aircraft goes, or nothing to divert: nothing changes.
        case none
        /// The route's destination: direct to its last waypoint, as the iPad's sheet does it.
        case directTo(index: Int)
        case divert(TripPlanner.Aerodrome)
    }

    static func action(for field: CompanionDivertField, plan: FlightPlan, own: TripPlanner.Aerodrome?,
                       destinationIdent: String?) -> Action {
        guard field.isNavigable, let last = plan.waypoints.indices.last else { return .none }
        let target = aerodrome(field, own: own)
        if isDestination(target.ident, destinationIdent: destinationIdent, lastWaypointName: plan.waypoints[last].name) {
            if plan.diversion == nil && plan.currentWaypointIndex == last { return .none }
            return .directTo(index: last)
        }
        if plan.diversion?.ident.caseInsensitiveCompare(target.ident) == .orderedSame { return .none }
        return .divert(target)
    }

    /// The iPad applies a field from the phone: its own record of it, then the same call its Divert
    /// sheet makes.
    @MainActor
    static func apply(_ field: CompanionDivertField, flightPlanManager: FlightPlanManager,
                      airports: AirportDataService?) {
        guard let plan = flightPlanManager.activeFlightPlan else { return }
        let own = airports.flatMap { store in store.findAirport(byIdent: field.ident).map(store.planningAerodrome) }
        let destination = plan.waypoints.last.flatMap { last in
            airports?.routeDestinationIdent(name: last.name, coordinate: last.coordinate)
        }
        switch action(for: field, plan: plan, own: own, destinationIdent: destination) {
        case .none:
            break
        case .directTo(let index):
            flightPlanManager.directTo(waypointAt: index)
        case .divert(let aerodrome):
            flightPlanManager.divert(to: aerodrome)
        }
    }
}

extension AirportDataService {
    /// The aerodrome the iPad's Divert sheet takes for the route's destination: the one the last
    /// waypoint is named after, else the nearest within 1 NM of it. Nil when neither is in the data.
    func routeDestinationIdent(name: String, coordinate: CLLocationCoordinate2D) -> String? {
        if !name.isEmpty, let named = findAirport(byIdent: name) { return named.ident }
        return nearestAirport(to: coordinate, maxDistanceNm: 1)?.ident
    }
}
