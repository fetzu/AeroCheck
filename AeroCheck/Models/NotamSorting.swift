import CoreLocation
import Foundation

// MARK: - The NOTAMs against the flight (decided 6 Nov 2026, q2 A)

// A NOTAM is along the flight when it is at the departure, the destination, a stop or the alternate, or its circle or
// point lies within 10 NM of the route, and its time overlaps the flight, and its band overlaps the ground to the
// planned altitude, and its traffic isn't IFR only. Nothing disappears: every other one goes in a group with its count.
// Pure, so the page, See all and the tests read the same answer.

/// What a NOTAM is sorted against.
struct NotamFlight: Equatable, Hashable {
    /// In the order the list shows them.
    enum Role: Int, Hashable { case destination, stop, alternate, departure }

    struct Point: Equatable, Hashable {
        let latitude: Double
        let longitude: Double
        var altitudeFt: Double?

        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    }

    /// How far either side of the route a NOTAM counts.
    static let corridorNm = 10.0
    /// Over the planned altitude: a level can move on the day.
    static let altitudeMarginFt = 1000.0
    /// Either side of the flight: a departure moves, and a NOTAM that starts just after the landing can catch a late one.
    static let timeMargin: TimeInterval = 3600
    /// For a route with no times yet.
    static let plainDuration: TimeInterval = 3600

    var route: [Point]
    var aerodromes: [String: Role]
    var start: Date
    var end: Date
    /// Nil when no altitude is planned: the band can't be judged, and no NOTAM goes above.
    var ceilingFt: Double?
    /// "LSZQ → LFGA".
    var label: String

    /// The flight as planned. `departure`: when it leaves; nil (an undated flight) counts from now.
    static func make(plan: FlightPlan, departure: Date?, label: String? = nil, now: Date = Date()) -> NotamFlight {
        var roles: [String: Role] = [:]
        let waypoints = plan.waypoints
        for (index, waypoint) in waypoints.enumerated() {
            guard let ident = FlightPlan.aerodromeIdent(waypoint) else { continue }
            let role: Role = index == 0 ? .departure : index == waypoints.count - 1 ? .destination : .stop
            // A flight that comes back to where it left: its departure.
            if roles[ident] == nil { roles[ident] = role }
        }
        if let alternate = plan.alternateAerodrome?.trimmingCharacters(in: .whitespaces).uppercased(), !alternate.isEmpty,
           roles[alternate] == nil {
            roles[alternate] = .alternate
        }
        // To the minute: the same flight is the same flight for a whole minute, whatever redraws the page.
        let leaves = departure ?? Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
        let duration = plan.totalEET > 0 ? plan.totalEET : plainDuration
        let highest = waypoints.compactMap(\.altitude).filter(\.isFinite).max()
        return NotamFlight(route: waypoints.map { Point(latitude: $0.latitude, longitude: $0.longitude, altitudeFt: $0.altitude) },
                           aerodromes: roles, start: leaves.addingTimeInterval(-timeMargin),
                           end: leaves.addingTimeInterval(duration + timeMargin),
                           ceilingFt: highest.map { $0 + altitudeMarginFt },
                           label: label ?? [waypoints.first?.name, waypoints.count > 1 ? waypoints.last?.name : nil]
                            .compactMap { $0 }.joined(separator: " → "))
    }
}

/// Where a NOTAM stands against the flight.
enum NotamPlace: Equatable, Hashable {
    enum Side: Hashable { case left, right }

    case aerodrome(NotamFlight.Role)
    /// Its centre's distance from the route, the side (nil on the line), the leg's altitude, and how far along.
    case route(offsetNm: Double, side: Side?, altitudeFt: Double?, alongNm: Double)
}

/// A NOTAM and where it stands; no place for one away from the route.
struct NotamEntry: Equatable, Hashable, Identifiable {
    let notam: Notam
    let place: NotamPlace?
    /// One NOTAM's other regions: the source repeats it for each place on its line A (a real French one, five times).
    var alsoAt = 0
    var id: String { notam.id }
}

/// The answer: nothing is left out.
struct NotamSorted: Equatable {
    /// How many the flight page shows.
    static let shownOnBlock = 3

    var along: [NotamEntry] = []
    var notDuring: [NotamEntry] = []
    var above: [NotamEntry] = []
    var ifrOnly: [NotamEntry] = []
    /// In the route's countries, away from the route.
    var away: [NotamEntry] = []

    /// Those that touch the route: the page's "All 16".
    var total: Int { along.count + notDuring.count + above.count + ifrOnly.count }
    var isEmpty: Bool { total == 0 && away.isEmpty }
}

enum NotamSorter {
    static func sort(_ notams: [Notam], for flight: NotamFlight) -> NotamSorted {
        var sorted = NotamSorted()
        for entry in entries(notams, for: flight) {
            let notam = entry.notam
            guard entry.place != nil else {
                sorted.away.append(entry)
                continue
            }
            if !notam.overlaps(from: flight.start, to: flight.end) {
                sorted.notDuring.append(entry)
            } else if let ceiling = flight.ceilingFt, Double(notam.lowerFl) * 100 > ceiling {
                sorted.above.append(entry)
            } else if notam.isIFROnly {
                sorted.ifrOnly.append(entry)
            } else {
                sorted.along.append(entry)
            }
        }
        sorted.along.sort(by: inListOrder)
        sorted.notDuring.sort(by: inListOrder)
        sorted.above.sort(by: inListOrder)
        sorted.ifrOnly.sort(by: inListOrder)
        sorted.away.sort { ($0.notam.location, $0.notam.number) < ($1.notam.location, $1.notam.number) }
        return sorted
    }

    /// Each NOTAM once, at the place of its that matters most to the flight.
    private static func entries(_ notams: [Notam], for flight: NotamFlight) -> [NotamEntry] {
        var seen = Set<String>()
        var byNotam: [String: [Notam]] = [:]
        for notam in notams where seen.insert(notam.id).inserted { byNotam[notam.sameNotamKey, default: []].append(notam) }
        return byNotam.values.map { copies in
            let placed = copies.map { NotamEntry(notam: $0, place: place(of: $0, in: flight)) }
            let best = placed.min { rank($0.place) != rank($1.place) ? rank($0.place) < rank($1.place) : $0.notam.location < $1.notam.location }!
            return NotamEntry(notam: best.notam, place: best.place, alsoAt: copies.count - 1)
        }
    }

    /// The field first, then along the route, then by when it starts: the same order for the same list.
    private static func inListOrder(_ a: NotamEntry, _ b: NotamEntry) -> Bool {
        let (ra, rb) = (rank(a.place), rank(b.place))
        if ra.0 != rb.0 { return ra.0 < rb.0 }
        if ra.1 != rb.1 { return ra.1 < rb.1 }
        let (sa, sb) = (a.notam.start ?? .distantPast, b.notam.start ?? .distantPast)
        return sa != sb ? sa < sb : a.notam.number < b.notam.number
    }

    /// The destination, a stop, the route, the alternate, the departure: what can't be seen out of the window first.
    private static func rank(_ place: NotamPlace?) -> (Int, Double) {
        switch place {
        case .aerodrome(.destination): return (0, 0)
        case .aerodrome(.stop): return (1, 0)
        case .route(_, _, _, let along): return (2, along)
        case .aerodrome(.alternate): return (3, 0)
        case .aerodrome(.departure): return (4, 0)
        case nil: return (5, 0)
        }
    }

    /// At one of the flight's aerodromes, or within the corridor of its route; nil otherwise.
    static func place(of notam: Notam, in flight: NotamFlight) -> NotamPlace? {
        if let role = flight.aerodromes[notam.location] { return .aerodrome(role) }
        guard let circle = notam.circle, let nearest = nearest(to: circle.centre, on: flight.route),
              nearest.distanceNm - circle.radiusNm <= NotamFlight.corridorNm else { return nil }
        // Inside a wide circle the route is in the area: how far its centre lies says nothing ("328 NM RIGHT").
        if circle.radiusNm >= NotamFlight.corridorNm, nearest.distanceNm <= circle.radiusNm {
            return .route(offsetNm: 0, side: nil, altitudeFt: nearest.altitudeFt, alongNm: nearest.alongNm)
        }
        return .route(offsetNm: nearest.distanceNm, side: nearest.side, altitudeFt: nearest.altitudeFt, alongNm: nearest.alongNm)
    }

    /// The route's nearest point to `point`: how far, which side, the leg's level and how far along.
    static func nearest(to point: CLLocationCoordinate2D, on route: [NotamFlight.Point])
        -> (distanceNm: Double, side: NotamPlace.Side?, altitudeFt: Double?, alongNm: Double)? {
        guard let first = route.first else { return nil }
        if route.count == 1 {
            return (NotamGeometry.distanceNm(first.coordinate, point), nil, first.altitudeFt, 0)
        }
        var best: (distanceNm: Double, side: NotamPlace.Side?, altitudeFt: Double?, alongNm: Double)?
        var travelled = 0.0
        for (a, b) in zip(route, route.dropFirst()) {
            let leg = NotamGeometry.offsetNm(from: a.coordinate, to: b.coordinate)
            let to = NotamGeometry.offsetNm(from: a.coordinate, to: point)
            let square = leg.x * leg.x + leg.y * leg.y
            let t = square > 0 ? min(max((to.x * leg.x + to.y * leg.y) / square, 0), 1) : 0
            let distance = hypot(to.x - t * leg.x, to.y - t * leg.y)
            if distance < best?.distanceNm ?? .infinity {
                // East and north: positive to the left of the leg.
                let cross = leg.x * to.y - leg.y * to.x
                let side: NotamPlace.Side? = distance < 0.5 ? nil : cross > 0 ? .left : .right
                let level = [a.altitudeFt, b.altitudeFt].compactMap { $0 }.max()
                best = (distance, side, level, travelled + t * sqrt(square))
            }
            travelled += sqrt(square)
        }
        return best
    }

    /// How many of the NOTAMs along the flight this device first saw after the tick: "1 new since your tick". The tick
    /// stays the pilot's.
    static func newSince(_ tick: Date, along: [NotamEntry], firstSeen: [String: Date]) -> Int {
        along.filter { (firstSeen[$0.id] ?? .distantPast) > tick }.count
    }
}
