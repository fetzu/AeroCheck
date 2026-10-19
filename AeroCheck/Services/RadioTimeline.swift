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
// | An aerodrome whose       | 5 min before the first of its points on the route, to 2 NM past | r3-2   |
// | reporting points it flies| the last, its zone entered or not                               |        |
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
        /// An aerodrome called at its reporting points, not a zone to enter: it waits for the departure's stretch to
        /// end, where a zone takes NOW from it in the climb (r3-2). (6.4.2)
        var yieldsToDeparture = false
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
    /// An aerodrome whose reporting points the route flies is called until this far past the last (r3-2).
    static let reportingPointPastNM = 2.0
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
    /// then an aerodrome at its reporting points, then the FIS.
    private static func rank(_ call: Call) -> Int {
        switch call.kind {
        case .fis: return 0
        case .departure: return 2
        case .unit, .tmaViaFIS: return call.yieldsToDeparture ? 1 : 3
        case .destination: return 4
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
                let rank = Self.rank(call), chosenRank = Self.rank(chosen.call)
                if rank < chosenRank || (rank == chosenRank && start <= chosen.start) { continue }
            }
            best = (call, start)
        }
        guard var chosen = best?.call else { return nil }
        // On the ground the departure is NOW, whatever call holds the field already: a zone or reporting point a few
        // miles out, whose 5 min start before the take-off at the leg's planned speed. LSGN read LSGC TWR on the
        // ground in the dr-3 replay, its V 6.7 NM out. (6.4.2)
        if progress <= 0, chosen.kind != .departure,
           let departure = held.first(where: { $0.kind == .departure }),
           !departure.station.hasSameFrequency(as: chosen.station) {
            chosen = departure
        }
        // The aerodrome and its own zone on one frequency: the aerodrome's name, on the 8.33 kHz channel's name of
        // the two (Grenchen's tower 120.105 where the airport database writes 120.100, Bern's 121.030 where its CTR
        // writes 121.025: `Station.preferredName`).
        let isField = { (call: Call) in call.kind == .departure || call.kind == .destination }
        let isZone = { (call: Call) in call.kind == .unit || call.kind == .tmaViaFIS }
        if isZone(chosen), var field = held.first(where: { isField($0) && $0.station.hasSameFrequency(as: chosen.station) }) {
            field.station = Station(frequency: Station.preferredName(chosen.station.frequency, field.station.frequency),
                                    callSign: field.station.callSign, isHX: chosen.station.isHX || field.station.isHX)
            return field
        }
        if isField(chosen), let zone = held.first(where: { isZone($0) && $0.station.hasSameFrequency(as: chosen.station) }) {
            var field = chosen
            field.station = Station(frequency: Station.preferredName(zone.station.frequency, chosen.station.frequency),
                                    callSign: chosen.station.callSign, isHX: zone.station.isHX || chosen.station.isHX)
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
        // While the departure is NOW, a call that starts before its stretch ends comes first, ahead of the FIS: the
        // level-off may come after it (LSGC at V, 6.7 NM out of LSGN, where NEXT read Geneva Info in the climb and
        // LSGC TWR took NOW at the level-off: the dr-3 replay of 19 Oct). (6.4.2)
        let changes = calls.flatMap { [start(of: $0, speedKt: speed), end(of: $0, departureOver: true)] }
            .filter { $0.isFinite && $0 > progress }
            .sorted()
        var ahead: [Call?] = []
        if let departure = now, departure.kind == .departure {
            let duringIt = [progress] + changes.filter { $0 + 1e-6 < departure.toNM }.map { $0 + 1e-6 }
            ahead.append(duringIt.lazy.compactMap { self.now(atNM: $0, speedKt: speed, departureOver: true) }
                .first { $0.kind != .fis && !$0.station.hasSameFrequency(as: departure.station) })
            ahead.append(self.now(atNM: progress, speedKt: speed, departureOver: true))
        }
        for change in changes { ahead.append(self.now(atNM: change + 1e-6, speedKt: speed, departureOver: true)) }
        if let next = ahead.lazy.compactMap({ $0 }).first(where: { !$0.station.hasSameFrequency(as: now?.station) }) {
            reading.next = next.station
            reading.nextKind = next.kind
        }

        // LISTEN: the destination's ATIS from 10 min before its call point, an aerodrome on the way from 5 min before
        // abeam to 2 NM past. Of two in their windows, the one whose window ends first, then the other: the field
        // passed, then the ATIS (the author's device check ls-1: LSPL abeam on the way back to Grenchen, where the
        // ATIS used to win and LSPL never showed).
        let v = Self.milesPerSecond(speed)
        var windows: [(station: Station, ends: Double)] = []
        if let destination = calls.last(where: { $0.kind == .destination }),
           let atis = listens.first(where: { $0.kind == .atis }) {
            let call = start(of: destination, speedKt: speed)
            if call - Self.atisLead * v <= progress, progress < call { windows.append((atis.station, call)) }
        }
        if moment.fieldsOnTheWay {
            for field in listens where field.kind == .fieldOnTheWay
                && field.atNM - Self.fieldOnTheWayLead * v <= progress && progress < field.atNM + Self.fieldOnTheWayPastNM {
                windows.append((field.station, field.atNM + Self.fieldOnTheWayPastNM))
            }
        }
        if let listen = windows.filter({ !$0.station.hasSameFrequency(as: now?.station) }).min(by: { $0.ends < $1.ends }) {
            reading.next = listen.station
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
        // where the Grenchen replay read "GRENCHEN TWR HX" once the level-off came. Since 6.4.2's device checks an
        // aerodrome on the way too: "GRENCHEN TWR HX" was too wide for NOW and showed no name at all (zn-3).
        var zoneCalls: [Call] = []
        // Any zone on an aerodrome's frequency where it holds the aerodrome, or where the aerodrome's own zone (its
        // CTR) is on that frequency: a TMA too, its frequency borrowed from the CTR. Bern's tower was "BERN TWR" from
        // TMA BERN, then "LSZB TWR", then "LSZB TWR HX" in its CTR, one frequency under three names (the route 3
        // replay, 19 Oct). HX where any zone on it over the aerodrome is. (6.4.2)
        var aerodromes: [(contact: Station, at: CLLocationCoordinate2D)] = fieldsNearby.map { ($0.contact, $0.coordinate) }
        if let contact = destination?.contact { aerodromes.insert((contact, waypoints[waypoints.count - 1].coordinate), at: 0) }
        if let contact = departure?.contact { aerodromes.insert((contact, waypoints[0].coordinate), at: 0) }
        func isHX(_ contact: Station, at point: CLLocationCoordinate2D) -> Bool {
            contact.isHX || (zones + possible).contains {
                $0.station.isHX && $0.station.hasSameFrequency(as: contact) && $0.airspace.containsPoint(point)
            }
        }
        func named(_ zone: Zone) -> Station {
            let ownZones = airspaces.filter {
                RouteRadioPlanner.isAerodromeZone($0)
                    && ($0.primaryFrequency.map { Station.isSameFrequency($0.value, zone.station.frequency) } ?? false)
            }
            guard let aerodrome = aerodromes.first(where: { aerodrome in
                      aerodrome.contact.hasSameFrequency(as: zone.station)
                          && (zone.airspace.containsPoint(aerodrome.at) || ownZones.contains { $0.containsPoint(aerodrome.at) })
                  }) else { return zone.station }
            return Station(frequency: Station.preferredName(zone.station.frequency, aerodrome.contact.frequency),
                           callSign: aerodrome.contact.callSign, isHX: isHX(aerodrome.contact, at: aerodrome.at))
        }
        for zone in zones {
            let viaFIS = RouteRadioPlanner.isClearedByFIS(zone.airspace, station: zone.station)
            let station = named(zone)
            for run in runs(zone.inside) {
                let from = run.lowerBound == 0 ? 0 : samples[run.lowerBound].d
                let to = run.upperBound + 1 < samples.count ? samples[run.upperBound + 1].d : .infinity
                zoneCalls.append(Call(station: station, kind: viaFIS ? .tmaViaFIS : .unit, fromNM: from, toNM: to,
                                      lead: viaFIS ? tmaLead : zoneLead,
                                      note: viaFIS ? "TMA " + RouteRadioPlanner.baseName(zone.airspace.name) : nil))
            }
        }
        // An aerodrome whose reporting points the route flies, not either end: its contact as a zone's, from 5 min
        // before the first point to 2 NM past the last, its zone entered or not. Calling Les Eplatures over its V and
        // E is customary though the route stays outside its CTR (the author's device check r3-2, 19 Oct 2026).
        let ends = Set([departure?.ident, destination?.ident].compactMap { $0?.uppercased() })
        var pointsOf: [String: [Int]] = [:]
        for i in waypoints.indices.dropFirst().dropLast() {
            guard let icao = waypoints[i].aerodromeICAO?.uppercased(), !icao.isEmpty, !ends.contains(icao) else { continue }
            pointsOf[icao, default: []].append(i)
        }
        var calledAtPoints = Set<String>()
        for (icao, points) in pointsOf {
            guard let field = fieldsNearby.first(where: { $0.ident.uppercased() == icao }),
                  let first = points.min(), let last = points.max() else { continue }
            calledAtPoints.insert(icao)
            zoneCalls.append(Call(station: field.contact, kind: .unit, fromNM: cum[first],
                                  toNM: min(cum[last] + reportingPointPastNM, total), lead: zoneLead,
                                  yieldsToDeparture: true))
        }
        timeline.calls += merged(zoneCalls)
        for zone in possible {
            guard let run = runs(zone.inside).first else { continue }
            timeline.possible.append(Call(station: named(zone), kind: .unit, fromNM: samples[run.lowerBound].d,
                                          toNM: run.upperBound + 1 < samples.count ? samples[run.upperBound + 1].d : .infinity,
                                          lead: zoneLead))
        }

        // The departure, from the start to the level-off.
        if var contact = departure?.contact {
            contact.isHX = isHX(contact, at: waypoints[0].coordinate)
            timeline.calls.append(Call(station: contact, kind: .departure, fromNM: 0, toNM: min(departureLimitNM, total)))
        }

        // The destination: from its zone's boundary where the route ends inside one that holds it, else the end.
        let end = waypoints[waypoints.count - 1].coordinate
        if let destination, var contact = destination.contact {
            contact.isHX = isHX(contact, at: end)
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

        // Aerodromes on the way: within 2 NM of the route, with no zone of their own, not either end, not called at
        // their reporting points.
        // Each pass its own, abeam where it comes closest: an out-and-back passes one twice, and had it on the way
        // out only (LSPL on the Grenchen loop, the author's device check ls-1, 19 Oct 2026).
        var listed = Set<String>()
        for field in fieldsNearby where !ends.contains(field.ident.uppercased()) && !calledAtPoints.contains(field.ident.uppercased()) {
            guard listed.insert(field.ident.uppercased()).inserted,
                  !airspaces.contains(where: { RouteRadioPlanner.isAerodromeZone($0) && $0.containsPoint(field.coordinate) })
            else { continue }
            var pass: [RouteRadioPlanner.Sample] = []
            for (i, sample) in samples.enumerated() {
                let near = distanceNM(sample.coordinate, field.coordinate) <= fieldOnTheWayNM
                if near { pass.append(sample) }
                guard !pass.isEmpty, !near || i == samples.count - 1 else { continue }
                if let abeam = pass.min(by: { distanceNM($0.coordinate, field.coordinate) < distanceNM($1.coordinate, field.coordinate) }) {
                    timeline.listens.append(Listen(station: field.contact, kind: .fieldOnTheWay, atNM: abeam.d))
                }
                pass = []
            }
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
                out[i].yieldsToDeparture = out[i].yieldsToDeparture && call.yieldsToDeparture
            } else {
                out.append(call)
            }
        }
        return out
    }
}
