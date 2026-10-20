import Foundation
import CoreLocation

// MARK: - The radio along the route (6.4.2)
//
// Who to talk to NOW and who to call NEXT, read off the route the way the printed nav log reads it. The nav log's
// walk (`RouteRadioPlanner.plan`) finds the zones the route enters at the planned altitude and the FIS along it; it
// also lays them out here, every call in the order the flight makes it, each with the stretch of the route where
// it is NOW. The Cockpit reads it at the aircraft's progress (`PhaseFrequencyPlanner`), so paper and screen agree.
//
// The rules are the author's answers of 18 Oct 2026, after the 6.4.1 device check dr-3 (LSGN to LSZQ), checked
// against the Swiss VFR Manual and the French eAIP:
//
// | Call                     | NOW                                                             | Answer |
// |--------------------------|-----------------------------------------------------------------|--------|
// | Departure                | from the start to the level-off, 10 NM at most                  | q3     |
// | FIS                      | its stretch, boundary to boundary                               | q4, q5 |
// | CTR, RMZ, FIZ, ATZ…      | from 5 min before the boundary to the exit; HX counts as active | q6     |
// | A TMA the FIS clears     | its Information station from 10 min before, the TMA beside it   | q6     |
// | Destination              | 5 min before it (its zone's boundary), or 2 min before its      | q8     |
// |                          | arrival point if that comes first; to the end and after         |        |
// | Its ATIS                 | in NEXT, LISTEN, from 10 min before that call point             | q9     |
// | An aerodrome on the way  | in NEXT, LISTEN, from 5 min before abeam to 2 NM past           | q7     |
//
// NEXT is NOW at the next change ahead on another frequency, unless a LISTEN item is in its window. Minutes are
// turned into miles at the aircraft's ground speed, so a slow aircraft gets its calls earlier on the map.

/// The flight's radio along its route. Distances are NM along the route from the departure.
struct RadioTimeline: Equatable {
    typealias Station = RouteRadioPlanner.Station

    enum Kind: Equatable {
        /// The departure field's contact.
        case departure
        /// The area's flight information service.
        case fis
        /// A zone to call before entering it: a CTR, an RMZ or FIZ, an ATZ, a TMA or CTA of class A to D.
        case unit
        /// A TMA whose clearance the FIS gives (TMA GENEVA, the Basel sectors, the Swiss class C TMAs): called on
        /// its Information station, the TMA named beside it.
        case tmaViaFIS
        /// The destination's contact.
        case destination
    }

    /// One station's stretch of the route.
    struct Call: Equatable {
        var station: Station
        var kind: Kind
        /// Where it takes over: the zone's boundary, the FIS's, the destination (or its zone's boundary).
        var fromNM: Double
        /// Where it hands over: the zone's exit, the next FIS's boundary. Infinite where the route ends inside it.
        var toNM: Double
        /// How long before `fromNM` it is NOW.
        var lead: TimeInterval = 0
        /// The airspace named beside the station ("TMA GENEVA").
        var note: String? = nil
        /// The destination's arrival point (the route's last point of that aerodrome): NOW 2 min before it at the
        /// latest.
        var arrivalPointNM: Double? = nil
    }

    /// Listen-only, shown in NEXT in its window.
    struct Listen: Equatable {
        enum Kind: Equatable {
            /// The destination's ATIS: from 10 min before the destination's call point until it.
            case atis
            /// An aerodrome the route passes within 2 NM, with no zone of its own: from 5 min before abeam to 2 NM
            /// past.
            case fieldOnTheWay
        }
        var station: Station
        var kind: Kind
        /// Abeam the field. Unused for the ATIS, whose window is counted back from the destination's call.
        var atNM: Double = 0
    }

    var calls: [Call] = []
    var listens: [Listen] = []
    /// Zones the route may enter, a limit in ft AGL or a flight level falling the wrong way: ROUTE lists them, they
    /// never take NOW (the nav log's "▸?").
    var possible: [Call] = []
    var totalNM: Double = 0
    /// Each waypoint's distance from the departure.
    var waypointNM: [Double] = []

    static let empty = RadioTimeline()
    var isEmpty: Bool { calls.isEmpty }

    /// A CTR, RMZ or FIZ: NOW 5 min before its boundary (q6).
    static let zoneLead: TimeInterval = 300
    /// A TMA the FIS clears: named from 10 min before (q6; "First RDO contact MNM 10min prior entry TMA",
    /// swisstopo's ICAO chart legend).
    static let tmaLead: TimeInterval = 600
    /// The destination: 5 min before it (q8; the blind call about 5 min before an aerodrome without ATS, VFR Manual
    /// COM-1 §1.2).
    static let destinationLead: TimeInterval = 300
    /// Or 2 min before its arrival point, if that comes first (q8).
    static let arrivalPointLead: TimeInterval = 120
    /// The destination's ATIS: from 10 min before its call (q9).
    static let atisLead: TimeInterval = 600
    /// An aerodrome on the way: 5 min before abeam (q7).
    static let fieldOnTheWayLead: TimeInterval = 300
    /// …until this far past it.
    static let fieldOnTheWayPastNM = 2.0
    /// Within this of the route, an aerodrome is on the way (q7).
    static let fieldOnTheWayNM = 2.0
    /// The departure is NOW to the level-off, and this far at most (a climb that never levels off).
    static let departureLimitNM = 10.0
    /// Further than this from the route, the flight is off it: the rules without a route (R7).
    static let offRouteNM = 5.0
    /// Under this, a speed is taken as this: a fix on the ground gives no time to miles.
    static let minimumSpeedKt = 30.0

    // MARK: - Reading it

    /// Where the flight is on it.
    struct Moment: Equatable {
        /// NM along the route.
        var progressNM: Double
        /// Ground speed, for the minutes before a boundary.
        var speedKt: Double
        /// The departure's stretch is over: the level-off came (`FlightCueState`).
        var departureOver = false
        /// Aerodromes on the way are shown (Settings › Checklist & Flight).
        var fieldsOnTheWay = true
    }

    /// What the timeline says at a moment.
    struct Reading: Equatable {
        var now: Call?
        var next: Station?
        /// NEXT is listen-only: the destination's ATIS, an aerodrome on the way.
        var nextIsListen = false
        /// The kind of NEXT's call, when it is one.
        var nextKind: Kind?
    }

    private static func milesPerSecond(_ speedKt: Double) -> Double { max(speedKt, minimumSpeedKt) / 3600 }

    /// Where a call becomes NOW at this ground speed.
    func start(of call: Call, speedKt: Double) -> Double {
        let v = Self.milesPerSecond(speedKt)
        switch call.kind {
        case .departure:
            return -.infinity
        case .fis:
            return call.fromNM
        case .unit, .tmaViaFIS:
            return call.fromNM - call.lead * v
        case .destination:
            var start = call.fromNM - call.lead * v
            if let arrival = call.arrivalPointNM { start = min(start, arrival - Self.arrivalPointLead * v) }
            return start
        }
    }

    /// Where a call stops being NOW.
    func end(of call: Call, departureOver: Bool) -> Double {
        switch call.kind {
        case .departure: return departureOver ? -.infinity : call.toNM
        case .destination: return .infinity
        case .fis, .unit, .tmaViaFIS: return call.toNM
        }
    }

    /// Which call wins where several hold a point: the destination, then the zone called last, then the departure,
    /// then the FIS.
    private static func rank(_ kind: Kind) -> Int {
        switch kind {
        case .fis: return 0
        case .departure: return 1
        case .unit, .tmaViaFIS: return 2
        case .destination: return 3
        }
    }

    /// NOW at a point of the route. The departure's or the destination's own zone (its CTR, its FIZ) is called
    /// under the aerodrome's name: "LSGC TWR", not "Les Eplatures TWR".
    func now(atNM progress: Double, speedKt: Double, departureOver: Bool) -> Call? {
        let held = calls.filter {
            start(of: $0, speedKt: speedKt) <= progress && progress < end(of: $0, departureOver: departureOver)
        }
        var best: (call: Call, start: Double)?
        for call in held {
            let start = start(of: call, speedKt: speedKt)
            if let chosen = best {
                let rank = Self.rank(call.kind), chosenRank = Self.rank(chosen.call.kind)
                if rank < chosenRank || (rank == chosenRank && start <= chosen.start) { continue }
            }
            best = (call, start)
        }
        guard let chosen = best?.call else { return nil }
        // The aerodrome and its own zone on one frequency: the aerodrome's name with the zone's frequency, as the
        // airspace data writes it (Grenchen's tower 120.105, the 8.33 kHz name the airport database writes 120.100).
        let isField = { (call: Call) in call.kind == .departure || call.kind == .destination }
        let isZone = { (call: Call) in call.kind == .unit || call.kind == .tmaViaFIS }
        if isZone(chosen), var field = held.first(where: { isField($0) && $0.station.hasSameFrequency(as: chosen.station) }) {
            field.station = Station(frequency: chosen.station.frequency, callSign: field.station.callSign,
                                    isHX: chosen.station.isHX)
            return field
        }
        if isField(chosen), let zone = held.first(where: { isZone($0) && $0.station.hasSameFrequency(as: chosen.station) }) {
            var field = chosen
            field.station = Station(frequency: zone.station.frequency, callSign: chosen.station.callSign, isHX: zone.station.isHX)
            return field
        }
        return chosen
    }

    /// NOW and NEXT at a moment.
    func reading(_ moment: Moment) -> Reading {
        let progress = moment.progressNM, speed = moment.speedKt
        let now = now(atNM: progress, speedKt: speed, departureOver: moment.departureOver)
        var reading = Reading(now: now)

        // NEXT: NOW once the departure is over, then just after each change ahead, the first on another frequency.
        var ahead: [Call?] = []
        if now?.kind == .departure { ahead.append(self.now(atNM: progress, speedKt: speed, departureOver: true)) }
        let changes = calls.flatMap { [start(of: $0, speedKt: speed), end(of: $0, departureOver: true)] }
            .filter { $0.isFinite && $0 > progress }
            .sorted()
        for change in changes { ahead.append(self.now(atNM: change + 1e-6, speedKt: speed, departureOver: true)) }
        if let next = ahead.lazy.compactMap({ $0 }).first(where: { !$0.station.hasSameFrequency(as: now?.station) }) {
            reading.next = next.station
            reading.nextKind = next.kind
        }

        // LISTEN: the destination's ATIS from 10 min before its call point; else an aerodrome on the way.
        let v = Self.milesPerSecond(speed)
        if let destination = calls.last(where: { $0.kind == .destination }) {
            let call = start(of: destination, speedKt: speed)
            if let atis = listens.first(where: { $0.kind == .atis }),
               call - Self.atisLead * v <= progress, progress < call,
               !atis.station.hasSameFrequency(as: now?.station) {
                reading.next = atis.station
                reading.nextIsListen = true
                reading.nextKind = nil
            }
        }
        if !reading.nextIsListen, moment.fieldsOnTheWay,
           let field = listens.first(where: {
               $0.kind == .fieldOnTheWay
                   && $0.atNM - Self.fieldOnTheWayLead * v <= progress && progress < $0.atNM + Self.fieldOnTheWayPastNM
                   && !$0.station.hasSameFrequency(as: now?.station)
           }) {
            reading.next = field.station
            reading.nextIsListen = true
            reading.nextKind = nil
        }
        return reading
    }

    /// Every call from NOW on, in the order the flight makes them, each station once, the LISTEN items in their
    /// place: ROUTE's radio.
    func ahead(_ moment: Moment) -> [(station: Station, listen: Bool)] {
        let progress = moment.progressNM, speed = moment.speedKt
        var items: [(at: Double, station: Station, listen: Bool)] = []
        for call in calls where end(of: call, departureOver: moment.departureOver) > progress {
            items.append((max(start(of: call, speedKt: speed), progress), call.station, false))
        }
        let v = Self.milesPerSecond(speed)
        if let destination = calls.last(where: { $0.kind == .destination }),
           let atis = listens.first(where: { $0.kind == .atis }) {
            let call = start(of: destination, speedKt: speed)
            // Just before the contact, from 10 min out until the call point.
            if progress < call { items.append((max(call - 1e-3, progress), atis.station, true)) }
        }
        if moment.fieldsOnTheWay {
            for field in listens where field.kind == .fieldOnTheWay && field.atNM + Self.fieldOnTheWayPastNM > progress {
                items.append((max(field.atNM - Self.fieldOnTheWayLead * v, progress), field.station, true))
            }
        }
        var out: [(station: Station, listen: Bool)] = []
        for item in items.enumerated().sorted(by: { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }).map(\.element)
        where !out.contains(where: { $0.station.hasSameFrequency(as: item.station) }) {
            out.append((item.station, item.listen))
        }
        return out
    }

    // MARK: - Where the aircraft is on it

    /// The aircraft's progress along the route, NM from the departure, and how far it is from the route: the fix
    /// projected on the leg to the waypoint flown to (`index`), within that leg. Before the first leg, 0; past the
    /// last waypoint (landed at the end, `followLanding`), the route's length.
    func progress(of position: CLLocationCoordinate2D, flyingTo index: Int,
                  waypoints: [CLLocationCoordinate2D]) -> (nm: Double, offRouteNM: Double)? {
        guard waypoints.count >= 2, waypointNM.count == waypoints.count else { return nil }
        if index <= 0 { return (0, Self.distanceNM(position, waypoints[0])) }
        if index >= waypoints.count { return (totalNM, Self.distanceNM(position, waypoints[waypoints.count - 1])) }
        let a = waypoints[index - 1], b = waypoints[index]
        let (along, across) = Self.project(position, from: a, to: b)
        let leg = waypointNM[index] - waypointNM[index - 1]
        return (waypointNM[index - 1] + min(max(along, 0), leg), across)
    }

    /// A point's distance along the line from `a` to `b` and from it, NM, on a flat local plane (a leg is short).
    static func project(_ p: CLLocationCoordinate2D, from a: CLLocationCoordinate2D,
                        to b: CLLocationCoordinate2D) -> (along: Double, across: Double) {
        let cosLat = cos(a.latitude * .pi / 180)
        func xy(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            ((c.longitude - a.longitude) * 60 * cosLat, (c.latitude - a.latitude) * 60)
        }
        let pb = xy(b), pp = xy(p)
        let length = (pb.x * pb.x + pb.y * pb.y).squareRoot()
        guard length > 1e-9 else { return (0, (pp.x * pp.x + pp.y * pp.y).squareRoot()) }
        let ux = pb.x / length, uy = pb.y / length
        let along = pp.x * ux + pp.y * uy
        let t = min(max(along, 0), length)
        let dx = pp.x - ux * t, dy = pp.y - uy * t
        return (along, (dx * dx + dy * dy).squareRoot())
    }

    static func distanceNM(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1852.0
    }
}

// MARK: - Building it (the nav log's walk)

extension RadioTimeline {
    /// A zone the walk found the route inside of at the planned altitude, with the station the nav log prints for it.
    struct Zone {
        let airspace: Airspace
        let station: Station
        /// Per walk sample: inside at the planned altitude.
        let inside: [Bool]
    }

    /// An aerodrome near the route, with its contact (q7).
    struct NearbyField: Equatable {
        let ident: String
        let coordinate: CLLocationCoordinate2D
        let contact: Station

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.ident == rhs.ident && lhs.contact == rhs.contact
                && lhs.coordinate.latitude == rhs.coordinate.latitude && lhs.coordinate.longitude == rhs.coordinate.longitude
        }
    }

    /// The timeline from the walk's products: the samples, the zones and the possible ones, the FIS where it changes.
    static func build(waypoints: [FlightPlanWaypoint], cum: [Double], samples: [RouteRadioPlanner.Sample],
                      zones: [Zone], possible: [Zone], fisChanges: [(nm: Double, station: Station)],
                      airspaces: [Airspace], departure: RouteRadioPlanner.Aerodrome?,
                      destination: RouteRadioPlanner.Aerodrome?, fieldsNearby: [NearbyField] = []) -> RadioTimeline {
        guard waypoints.count >= 2, let total = cum.last else { return .empty }
        var timeline = RadioTimeline(totalNM: total, waypointNM: cum)

        // The FIS, boundary to boundary; the last to the end and after.
        for (i, change) in fisChanges.enumerated() {
            let to = i + 1 < fisChanges.count ? fisChanges[i + 1].nm : .infinity
            timeline.calls.append(Call(station: change.station, kind: .fis, fromNM: i == 0 ? 0 : change.nm, toNM: to))
        }

        // Each stretch of each zone at the planned altitude. An aerodrome's own zone on its frequency is called by
        // the aerodrome's name, on the zone's channel: "LSZG TWR HX 120.105" from the ground to the CTR's exit,
        // where the Grenchen replay read "GRENCHEN TWR HX" once the level-off came.
        var zoneCalls: [Call] = []
        let aerodromes = [(departure, waypoints[0].coordinate), (destination, waypoints[waypoints.count - 1].coordinate)]
        for zone in zones {
            let viaFIS = RouteRadioPlanner.isClearedByFIS(zone.airspace, station: zone.station)
            var station = zone.station
            if RouteRadioPlanner.isAerodromeZone(zone.airspace),
               let contact = aerodromes.first(where: { end in
                   end.0?.contact?.hasSameFrequency(as: zone.station) == true && zone.airspace.containsPoint(end.1)
               })?.0?.contact {
                station = Station(frequency: zone.station.frequency, callSign: contact.callSign, isHX: zone.station.isHX)
            }
            for run in runs(zone.inside) {
                let from = run.lowerBound == 0 ? 0 : samples[run.lowerBound].d
                let to = run.upperBound + 1 < samples.count ? samples[run.upperBound + 1].d : .infinity
                zoneCalls.append(Call(station: station, kind: viaFIS ? .tmaViaFIS : .unit, fromNM: from, toNM: to,
                                      lead: viaFIS ? tmaLead : zoneLead,
                                      note: viaFIS ? "TMA " + RouteRadioPlanner.baseName(zone.airspace.name) : nil))
            }
        }
        timeline.calls += merged(zoneCalls)
        for zone in possible {
            guard let run = runs(zone.inside).first else { continue }
            timeline.possible.append(Call(station: zone.station, kind: .unit, fromNM: samples[run.lowerBound].d,
                                          toNM: run.upperBound + 1 < samples.count ? samples[run.upperBound + 1].d : .infinity,
                                          lead: zoneLead))
        }

        // The departure, from the start to the level-off.
        if let contact = departure?.contact {
            timeline.calls.append(Call(station: contact, kind: .departure, fromNM: 0, toNM: min(departureLimitNM, total)))
        }

        // The destination: from its zone's boundary where the route ends inside one that holds it, else the end.
        let end = waypoints[waypoints.count - 1].coordinate
        if let destination, let contact = destination.contact {
            // The stretch of the aerodrome's own zone the route ends in (a CTR, a FIZ), not a TMA above it.
            let zoneEntry = zones
                .filter { RouteRadioPlanner.isAerodromeZone($0.airspace) && $0.airspace.containsPoint(end) }
                .compactMap { zone in runs(zone.inside).last.flatMap { $0.upperBound == samples.count - 1 ? $0.lowerBound : nil } }
                .map { $0 == 0 ? 0 : samples[$0].d }
                .min()
            let arrival = (1..<(waypoints.count - 1)).last {
                waypoints[$0].aerodromeICAO?.uppercased() == destination.ident.uppercased()
            }.map { cum[$0] }
            timeline.calls.append(Call(station: contact, kind: .destination, fromNM: zoneEntry ?? total, toNM: .infinity,
                                       lead: destinationLead, arrivalPointNM: arrival))
            if let atis = destination.atis {
                timeline.listens.append(Listen(station: Station(frequency: atis, callSign: "\(destination.ident) ATIS"),
                                               kind: .atis))
            }
        }

        // Aerodromes on the way: within 2 NM of the route, with no zone of their own, not either end.
        let ends = Set([departure?.ident, destination?.ident].compactMap { $0?.uppercased() })
        for field in fieldsNearby where !ends.contains(field.ident.uppercased()) {
            guard !airspaces.contains(where: { RouteRadioPlanner.isAerodromeZone($0) && $0.containsPoint(field.coordinate) }),
                  let nearest = samples.min(by: { distanceNM($0.coordinate, field.coordinate) < distanceNM($1.coordinate, field.coordinate) }),
                  distanceNM(nearest.coordinate, field.coordinate) <= fieldOnTheWayNM else { continue }
            timeline.listens.append(Listen(station: field.contact, kind: .fieldOnTheWay, atNM: nearest.d))
        }
        timeline.listens.sort { ($0.kind == .atis ? -1 : $0.atNM) < ($1.kind == .atis ? -1 : $1.atNM) }
        return timeline
    }

    /// The runs of `true`, as index ranges.
    static func runs(_ flags: [Bool]) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        var start: Int?
        for (i, flag) in flags.enumerated() {
            if flag, start == nil { start = i }
            if !flag, let s = start { out.append(s...(i - 1)); start = nil }
        }
        if let s = start { out.append(s...(flags.count - 1)) }
        return out
    }

    /// Zone calls on one frequency that touch or overlap (TMA ZUERICH 2A then 3A, a CTR's two sectors) as one, so
    /// NOW doesn't change between them.
    static func merged(_ calls: [Call]) -> [Call] {
        var out: [Call] = []
        for call in calls.sorted(by: { $0.fromNM < $1.fromNM }) {
            if let i = out.lastIndex(where: {
                $0.kind == call.kind && $0.station.hasSameFrequency(as: call.station) && call.fromNM <= $0.toNM + 0.5
            }) {
                out[i].toNM = max(out[i].toNM, call.toNM)
            } else {
                out.append(call)
            }
        }
        return out
    }
}
