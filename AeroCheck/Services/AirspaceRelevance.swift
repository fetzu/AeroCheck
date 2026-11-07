import CoreLocation
import Foundation

// MARK: - Which airspace matters now (6.9.0)

/// Whether the aircraft is climbing, level or descending, from the GPS altitude smoothed over half a minute: one noisy
/// fix must not turn the tags over. More than 300 fpm either way counts (a11 A).
struct AirspaceVerticalTrend {
    static let window: TimeInterval = 30
    static let thresholdFpm = 300.0

    private var samples: [(time: TimeInterval, altitudeFt: Double)] = []

    mutating func add(altitudeFt: Double, at time: TimeInterval) {
        samples.append((time, altitudeFt))
        samples.removeAll { $0.time < time - Self.window }
    }

    /// Feet a minute, from the least-squares line through the window's fixes; zero below ten seconds of them.
    var verticalSpeedFpm: Double {
        guard let first = samples.first, let last = samples.last, last.time - first.time >= 10 else { return 0 }
        let count = Double(samples.count)
        let meanTime = samples.map(\.time).reduce(0, +) / count
        let meanAltitude = samples.map(\.altitudeFt).reduce(0, +) / count
        var slope = 0.0, spread = 0.0
        for sample in samples {
            slope += (sample.time - meanTime) * (sample.altitudeFt - meanAltitude)
            spread += (sample.time - meanTime) * (sample.time - meanTime)
        }
        return spread > 0 ? slope / spread * 60 : 0
    }
}

/// The part of the map the pilot is flying into: a path and how far either side of it counts (a11 A).
struct AirspaceAheadArea: Equatable {
    /// How far ahead the area looks, and the speed below which a track means nothing.
    static let minutesAhead = 10.0
    static let minimumTrackSpeedKt = 30.0
    static let halfWidthNM = 3.0
    static let stationaryRadiusNM = 5.0

    let path: [CLLocationCoordinate2D]
    let radiusNM: Double

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.radiusNM == rhs.radiusNM && lhs.path.map(\.latitude) == rhs.path.map(\.latitude)
            && lhs.path.map(\.longitude) == rhs.path.map(\.longitude)
    }

    /// The track for the next 10 minutes, 3 NM either side. The line's round end takes in the 2 NM around the aircraft.
    /// Below 30 kt the track means nothing: the route's next 10 minutes, or 5 NM around the aircraft without a route.
    static func make(at position: CLLocationCoordinate2D, trackDeg: Double?, groundSpeedKt: Double,
                     route: [CLLocationCoordinate2D] = [], plannedSpeedKt: Double = 100) -> AirspaceAheadArea {
        if groundSpeedKt >= minimumTrackSpeedKt, let trackDeg {
            let distance = groundSpeedKt * minutesAhead / 60
            return AirspaceAheadArea(path: [position, offset(position, trackDeg: trackDeg, nm: distance)],
                                     radiusNM: halfWidthNM)
        }
        if route.isEmpty { return AirspaceAheadArea(path: [position], radiusNM: stationaryRadiusNM) }
        return AirspaceAheadArea(path: cut([position] + route, nm: plannedSpeedKt * minutesAhead / 60),
                                 radiusNM: halfWidthNM)
    }

    /// The first `nm` of a path, the last leg cut to length.
    private static func cut(_ path: [CLLocationCoordinate2D], nm: Double) -> [CLLocationCoordinate2D] {
        var left = nm
        var out = [path[0]]
        for (a, b) in zip(path, path.dropFirst()) {
            let leg = PlaneNM(origin: a).distance(to: b)
            if leg >= left {
                let t = leg > 0 ? left / leg : 0
                out.append(CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                                  longitude: a.longitude + (b.longitude - a.longitude) * t))
                return out
            }
            left -= leg
            out.append(b)
        }
        return out
    }

    static func offset(_ origin: CLLocationCoordinate2D, trackDeg: Double, nm: Double) -> CLLocationCoordinate2D {
        let angle = trackDeg * .pi / 180
        let latitude = origin.latitude + nm * cos(angle) / 60
        let scale = max(cos(origin.latitude * .pi / 180), 0.01)
        return CLLocationCoordinate2D(latitude: latitude, longitude: origin.longitude + nm * sin(angle) / (60 * scale))
    }

    /// How far `airspace` is from the aircraft in NM, zero with the aircraft in it; nil when it is outside the area.
    func distanceNM(to airspace: Airspace) -> Double? {
        guard let start = path.first, airspace.polygonCoordinates.count >= 3 else { return nil }
        if airspace.containsPoint(start) { return 0 }
        let plane = PlaneNM(origin: start)
        let line = path.map(plane.point)
        var ring = airspace.polygonCoordinates.map(plane.point)
        ring.append(ring[0])
        let edges = Array(zip(ring, ring.dropFirst()))
        let fromAircraft = edges.map { PlaneNM.distance(line[0], $0.0, $0.1) }.min() ?? .infinity
        if path.contains(where: airspace.containsPoint) { return fromAircraft }
        var fromPath = fromAircraft
        for (p, q) in zip(line, line.dropFirst()) {
            for (a, b) in edges { fromPath = min(fromPath, PlaneNM.distance(p, q, a, b)) }
        }
        return fromPath <= radiusNM ? fromAircraft : nil
    }

    /// The box that holds the area, for the first query of the data.
    var bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)? {
        guard let start = path.first else { return nil }
        let scale = max(cos(start.latitude * .pi / 180), 0.01)
        let lat = radiusNM / 60, lon = radiusNM / (60 * scale)
        return (path.map(\.latitude).min()! - lat, path.map(\.latitude).max()! + lat,
                path.map(\.longitude).min()! - lon, path.map(\.longitude).max()! + lon)
    }
}

/// Coordinates flattened to NM around a point: good to a few metres over the tens of miles a look ahead covers.
private struct PlaneNM {
    let origin: CLLocationCoordinate2D
    let scale: Double

    init(origin: CLLocationCoordinate2D) {
        self.origin = origin
        scale = 60 * cos(origin.latitude * .pi / 180)
    }

    func point(_ c: CLLocationCoordinate2D) -> CGPoint {
        CGPoint(x: (c.longitude - origin.longitude) * scale, y: (c.latitude - origin.latitude) * 60)
    }

    func distance(to c: CLLocationCoordinate2D) -> Double {
        let p = point(c)
        return hypot(p.x, p.y)
    }

    /// From a point to a segment.
    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let square = dx * dx + dy * dy
        let t = square > 0 ? min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / square, 0), 1) : 0
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }

    /// Between two segments: zero when they cross.
    static func distance(_ p: CGPoint, _ q: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        func side(_ o: CGPoint, _ u: CGPoint, _ v: CGPoint) -> Double {
            (u.x - o.x) * (v.y - o.y) - (u.y - o.y) * (v.x - o.x)
        }
        if side(p, q, a) * side(p, q, b) < 0, side(a, b, p) * side(a, b, q) < 0 { return 0 }
        return min(distance(p, a, b), distance(q, a, b), distance(a, p, q), distance(b, p, q))
    }
}

/// What the status slot says of the air ahead: the first airspace the track enters at the aircraft's altitude within five
/// minutes, amber only for R, D, P or class C and D within two (a6 A). Nothing about class E, which asks nothing, about
/// glider areas, or about an airspace the aircraft is already in.
struct AirspaceAheadFinding: Equatable {
    let airspaceId: String
    let name: String
    let minutes: Int
    let isCaution: Bool
    let entry: CLLocationCoordinate2D

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.airspaceId == rhs.airspaceId && lhs.minutes == rhs.minutes && lhs.isCaution == rhs.isCaution
    }

    static let lookAheadMinutes = 5.0
    static let cautionMinutes = 2.0
    /// Fifteen seconds of track at a time: about a quarter of a mile at 100 kt.
    static let stepSeconds = 15.0

    private static func asks(_ airspace: Airspace) -> Bool {
        guard !airspace.isInformationArea else { return false }
        switch airspace.mapKind {
        case .restrictive, .controlled, .zone: return true
        // On the tags and the map, not here: the DABS doesn't cover them, so they'd count as active every day, and in
        // the Jura they lit the slot for 11 minutes of a 15-minute flight (the author, 4 Nov).
        case .glider, .classE, .neutral: return false
        }
    }

    /// Whether this airspace turns amber: a clearance or a keep-out, not a transponder zone.
    private static func isSerious(_ airspace: Airspace) -> Bool {
        if airspace.mapKind == .restrictive { return true }
        return airspace.airspaceClass == .classC || airspace.airspaceClass == .classD
    }

    static func first(in airspaces: [Airspace], from position: CLLocationCoordinate2D, trackDeg: Double?,
                      groundSpeedKt: Double, altitudeFt: Double, terrainFt: ClosedRange<Double>? = nil) -> AirspaceAheadFinding? {
        guard groundSpeedKt >= AirspaceAheadArea.minimumTrackSpeedKt, let trackDeg else { return nil }
        let margin = AirspaceRelevance.levelMarginFt
        let atLevel = airspaces.filter { airspace in
            guard asks(airspace), !airspace.containsPoint(position) else { return false }
            let (lower, upper) = AirspaceRelevance.band(airspace, terrainFt: terrainFt)
            return lower <= altitudeFt + margin && upper >= altitudeFt - margin
        }
        guard !atLevel.isEmpty else { return nil }
        var seconds = stepSeconds
        while seconds <= lookAheadMinutes * 60 {
            let nm = groundSpeedKt * seconds / 3600
            let point = AirspaceAheadArea.offset(position, trackDeg: trackDeg, nm: nm)
            let entered = atLevel.filter { $0.containsPoint(point) }
            // Serious first, then the name: two entered at once give the same answer every time
            if let airspace = entered.min(by: { a, b in
                isSerious(a) != isSerious(b) ? isSerious(a) : a.name < b.name
            }) {
                let minutes = seconds / 60
                return AirspaceAheadFinding(airspaceId: airspace.id, name: AirspaceTagContent.name(airspace),
                                            minutes: max(1, Int(minutes.rounded(.up))),
                                            isCaution: isSerious(airspace) && minutes <= cautionMinutes, entry: point)
            }
            seconds += stepSeconds
        }
        return nil
    }
}

/// Keeps the slot from flickering on a boundary (human-factors principle 15): a state stays 15 seconds after the air
/// clears, and amber doesn't step back to information until then. A value: the Cockpit keeps one.
struct AirspaceAheadWatch {
    static let holdSeconds: TimeInterval = 15

    private(set) var shown: AirspaceAheadFinding?
    private var heldSince: Date?

    mutating func update(_ finding: AirspaceAheadFinding?, at now: Date) -> AirspaceAheadFinding? {
        let steppedDown = shown?.isCaution == true && shown?.airspaceId == finding?.airspaceId && finding?.isCaution == false
        if let finding, !steppedDown {
            shown = finding
            heldSince = nil
            return shown
        }
        guard shown != nil else { return nil }
        let since = heldSince ?? now
        heldSince = since
        if now.timeIntervalSince(since) >= Self.holdSeconds {
            shown = finding
            heldSince = nil
        }
        return shown
    }
}

/// A tag the map should show: the airspace, what kind, and where it ranks.
struct AirspaceRelevantTag {
    /// At the aircraft's level the full tag; a floor or ceiling the arrow tag (▲, ▼).
    enum Kind: Equatable { case atLevel, floor, ceiling }

    let airspace: Airspace
    let kind: Kind
    let weight: Double
    let distanceNM: Double
}

/// Which airspace gets a tag (a11 A, a8 A). All three must be true: it asks something of the pilot, it is ahead, and
/// its band is at the aircraft's height or about to be. Pure: `OpenAIPDataService` gives the airspace, the rest is here,
/// so the map's cap of 100 polygons never hides a tag. Ported from the study's `mock.py`.
enum AirspaceRelevance {
    static let levelMarginFt = 500.0
    static let maxTags = 5

    /// How the band reads for this rule: the lowest the floor and the highest the ceiling can be. A limit that can't be
    /// pinned down (above the ground, a flight level) so counts as inside (a8 A).
    static func band(_ airspace: Airspace, terrainFt: ClosedRange<Double>?) -> (lowerFt: Double, upperFt: Double) {
        let band = AirspaceVerticalBand(airspace, terrainFt: terrainFt)
        return (band.floor.low, band.ceiling.high)
    }

    /// Whether it asks something, and how much: R, D and P first, a clearance, a glider, transponder or radio zone,
    /// class E last. Nil when it asks nothing: class G never gets a tag.
    private static func weight(of airspace: Airspace) -> Double? {
        if airspace.isInformationArea { return nil }
        switch airspace.mapKind {
        case .restrictive: return 0
        case .controlled: return 1
        case .glider, .zone: return 2
        case .classE: return 3
        case .neutral: return nil
        }
    }

    /// The kind of tag this airspace earns at this height and rank, or nil.
    static func tag(_ airspace: Airspace, altitudeFt: Double, verticalSpeedFpm: Double,
                    terrainFt: ClosedRange<Double>? = nil) -> (kind: AirspaceRelevantTag.Kind, weight: Double)? {
        guard let weight = weight(of: airspace) else { return nil }
        let (lower, upper) = band(airspace, terrainFt: terrainFt)
        if lower <= altitudeFt + levelMarginFt, upper >= altitudeFt - levelMarginFt {
            // Class E asks no clearance: no full tag, only its floor or ceiling when you are about to cross it.
            return airspace.mapKind == .classE ? nil : (.atLevel, weight)
        }
        let threshold = AirspaceVerticalTrend.thresholdFpm
        let (above, below): (Double, Double) = verticalSpeedFpm > threshold ? (2000, 0)
            : verticalSpeedFpm < -threshold ? (0, 2000) : (1000, 1000)
        if lower > altitudeFt + levelMarginFt, lower <= altitudeFt + levelMarginFt + above { return (.floor, weight + 0.5) }
        if upper < altitudeFt - levelMarginFt, upper >= altitudeFt - levelMarginFt - below { return (.ceiling, weight + 0.5) }
        return nil
    }

    /// The tags, five at most, ranked: by what it asks, at-level before arrows within a kind, nearest first; the name
    /// settles a tie, so the same air gives the same tags.
    static func tags(in airspaces: [Airspace], area: AirspaceAheadArea, altitudeFt: Double, verticalSpeedFpm: Double,
                     terrainFt: ClosedRange<Double>? = nil) -> [AirspaceRelevantTag] {
        var found: [AirspaceRelevantTag] = []
        for airspace in airspaces {
            guard let (kind, weight) = tag(airspace, altitudeFt: altitudeFt, verticalSpeedFpm: verticalSpeedFpm,
                                           terrainFt: terrainFt),
                  let distance = area.distanceNM(to: airspace) else { continue }
            found.append(AirspaceRelevantTag(airspace: airspace, kind: kind, weight: weight, distanceNM: distance))
        }
        found.sort { a, b in
            if a.weight != b.weight { return a.weight < b.weight }
            if a.distanceNM != b.distanceNM { return a.distanceNM < b.distanceNM }
            return a.airspace.name < b.airspace.name
        }
        return Array(found.prefix(maxTags))
    }

    /// How the map draws an airspace: at the aircraft's level in full, near it lighter, the rest faint (a3 A).
    static func tier(_ airspace: Airspace, altitudeFt: Double, terrainFt: ClosedRange<Double>? = nil) -> AirspaceMapTier {
        let (lower, upper) = band(airspace, terrainFt: terrainFt)
        if lower <= altitudeFt + levelMarginFt, upper >= altitudeFt - levelMarginFt { return .atLevel }
        let floorAbove = lower > altitudeFt + levelMarginFt && lower <= altitudeFt + 2000
        let ceilingBelow = upper < altitudeFt - levelMarginFt && upper >= altitudeFt - 1000
        return floorAbove || ceilingBelow ? .near : .far
    }
}
