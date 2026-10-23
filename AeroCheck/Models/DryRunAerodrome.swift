import Foundation
import CoreLocation

// MARK: - Dry run (6.4.0): an aerodrome as the generator flies it

/// An aerodrome as a dry run flies it: the runway in use from its threshold to its far end, the side of its
/// circuit, how far out the downwind runs and the circuit's altitude; the published circuit's line, and the
/// published arrivals and departures, which the generator flies as they are drawn. Made from open flightmaps'
/// thresholds and procedures where the app has them, else laid out on the reference point along a heading.
/// LSZQ is bundled (the author's pick, 12 Oct), so the guided flight flies on a fresh install, before any data
/// is downloaded. (6.4.0)
struct DryRunAerodrome {
    enum Side: Equatable {
        case left, right

        /// +1 right of the runway's direction, -1 left (the generator's offsets).
        var sign: Double { self == .right ? 1 : -1 }
    }

    /// A leg of the circuit, as its line goes.
    enum Leg: Equatable {
        case upwind, crosswind, downwind, base, final
    }

    /// A published arrival or departure: its line, and the part of it flown off the circuit (open flightmaps',
    /// the server's weekly job's `offCircuit`; nil when it gives none).
    struct Procedure {
        let name: String
        let line: [CLLocationCoordinate2D]
        let offCircuit: ClosedRange<Int>?
    }

    let ident: String
    let name: String
    /// Where the app's data places the aerodrome: the detector anchors take-offs and landings on it.
    let reference: CLLocationCoordinate2D
    let elevationFt: Double
    /// The runway in use: where it starts in the direction of take-off and landing, and where it ends.
    let threshold: CLLocationCoordinate2D
    let farEnd: CLLocationCoordinate2D
    let circuitSide: Side
    /// How far beside the runway the downwind runs, metres.
    let downwindOffsetM: Double
    /// The circuit's altitude, feet above sea level.
    let patternAltitudeFt: Double
    /// The published circuit's line, from the runway's far end round to its threshold; empty without one.
    var publishedCircuit: [CLLocationCoordinate2D] = []
    var arrivals: [Procedure] = []
    var departures: [Procedure] = []

    /// A circuit drawn with nothing to go by: 0.9 NM out, 1,000 ft above the field (the generator's).
    static let defaultDownwindOffsetM = 0.9 * DryRunGeo.metresPerNM
    static let defaultPatternHeightFt = 1000.0

    var runwayHeading: Double { DryRunGeo.bearing(from: threshold, to: farEnd) }
    var runwayLengthM: Double { DryRunGeo.distance(threshold, farEnd) }

    /// The runway's middle, from which the circuit's points are laid out.
    var runwayCentre: CLLocationCoordinate2D {
        DryRunGeo.destination(from: threshold, bearing: runwayHeading, distance: runwayLengthM / 2)
    }

    /// A point `along` metres along the runway's direction from its middle, `right` metres to its right.
    func point(along: Double, right: Double = 0) -> CLLocationCoordinate2D {
        let heading = runwayHeading
        let onAxis = DryRunGeo.destination(from: runwayCentre, bearing: heading, distance: along)
        return right == 0 ? onAxis : DryRunGeo.destination(from: onAxis, bearing: heading + 90, distance: right)
    }

    /// The aerodrome as the detector anchors to it, for a store that doesn't have it (a fresh install has no
    /// airport data yet). A stable id, the ground replays' (`GroundReplay.airport`): never saved, the same on
    /// every launch.
    var airport: Airport {
        let id = ident.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) % 100_000_000 }
        return Airport(id: id, ident: ident, type: .smallAirport, name: name,
                       latitude: reference.latitude, longitude: reference.longitude, elevation: Int(elevationFt),
                       continent: "EU", isoCountry: ident.hasPrefix("LS") ? "CH" : ident.hasPrefix("LF") ? "FR" : "",
                       isoRegion: "", municipality: nil, scheduledService: false, gpsCode: ident,
                       iataCode: nil, localCode: nil)
    }

    // The points the generator flies to and taxis by, as scripts/flightsim laid them out.
    var touchdownPoint: CLLocationCoordinate2D { point(along: -runwayLengthM / 2 + 60) }
    var lineUpPoint: CLLocationCoordinate2D { point(along: -runwayLengthM / 2 + 20) }
    var holdingPoint: CLLocationCoordinate2D { point(along: -runwayLengthM / 2 + 40, right: -circuitSide.sign * 70) }
    var apron: CLLocationCoordinate2D { point(along: -runwayLengthM / 4, right: -circuitSide.sign * 140) }
    var crosswindPoint: CLLocationCoordinate2D { point(along: runwayLengthM / 2 + 0.6 * DryRunGeo.metresPerNM) }
    var downwindStart: CLLocationCoordinate2D {
        point(along: runwayLengthM / 2 + 0.3 * DryRunGeo.metresPerNM, right: circuitSide.sign * downwindOffsetM)
    }
    var downwindEnd: CLLocationCoordinate2D {
        point(along: -runwayLengthM / 2 - 0.7 * DryRunGeo.metresPerNM, right: circuitSide.sign * downwindOffsetM)
    }
    var basePoint: CLLocationCoordinate2D {
        point(along: -runwayLengthM / 2 - 1.6 * DryRunGeo.metresPerNM, right: circuitSide.sign * downwindOffsetM * 0.55)
    }
    var finalPoint: CLLocationCoordinate2D { point(along: -runwayLengthM / 2 - 1.5 * DryRunGeo.metresPerNM) }

    /// From the runway's two thresholds, the one in use first, and the aerodrome's powered circuit if it
    /// has one (open flightmaps' line and altitude): the circuit on the side its points lie, its downwind as
    /// far out as they reach (between 0.6 and 1.6 NM). Without a circuit: a left-hand one, 0.9 NM out,
    /// 1,000 ft above the field.
    /// `circuitSide`: without a circuit line, the side the field publishes (a US field's, from NASR). (6.5.0)
    static func make(ident: String, name: String, reference: CLLocationCoordinate2D, elevationFt: Double,
                     threshold: CLLocationCoordinate2D, farEnd: CLLocationCoordinate2D,
                     circuitLine: [CLLocationCoordinate2D] = [], circuitAltitudeFt: Double? = nil,
                     circuitSide: Side? = nil,
                     arrivals: [Procedure] = [], departures: [Procedure] = []) -> DryRunAerodrome {
        let heading = DryRunGeo.bearing(from: threshold, to: farEnd)
        // Each point's distance off the runway's line, metres, positive to its right.
        let offsets = circuitLine.map { point -> Double in
            let d = DryRunGeo.distance(threshold, point)
            let off = DryRunGeo.angleDifference(from: heading, to: DryRunGeo.bearing(from: threshold, to: point))
            return d * sin(off * .pi / 180)
        }.filter { abs($0) > 0.2 * DryRunGeo.metresPerNM }
        var side = circuitSide ?? .left
        var offset = defaultDownwindOffsetM
        if !offsets.isEmpty {
            side = offsets.reduce(0, +) > 0 ? .right : .left
            let reach = offsets.map(abs).max() ?? offset
            offset = min(1.6 * DryRunGeo.metresPerNM, max(0.6 * DryRunGeo.metresPerNM, reach))
        }
        // The published line from the runway's far end round to the threshold, as the generator flies it; a line
        // the other way round (its last point the far end) is turned.
        var published = circuitLine
        if let first = published.first, let last = published.last,
           DryRunGeo.distance(first, threshold) < DryRunGeo.distance(last, threshold) {
            published.reverse()
        }
        return DryRunAerodrome(ident: ident, name: name, reference: reference, elevationFt: elevationFt,
                               threshold: threshold, farEnd: farEnd, circuitSide: side, downwindOffsetM: offset,
                               patternAltitudeFt: circuitAltitudeFt ?? elevationFt + defaultPatternHeightFt,
                               publishedCircuit: published.count >= 4 ? published : [],
                               arrivals: arrivals, departures: departures)
    }

    /// No thresholds in the data: the runway laid out on the reference point along `heading` (degrees
    /// true, the direction in use), `lengthM` long, as scripts/flightsim did; a left-hand circuit.
    static func make(ident: String, name: String, reference: CLLocationCoordinate2D, elevationFt: Double,
                     heading: Double, lengthM: Double, circuitSide: Side = .left,
                     patternAltitudeFt: Double? = nil) -> DryRunAerodrome {
        let threshold = DryRunGeo.destination(from: reference, bearing: heading + 180, distance: lengthM / 2)
        let farEnd = DryRunGeo.destination(from: reference, bearing: heading, distance: lengthM / 2)
        return DryRunAerodrome(ident: ident, name: name, reference: reference, elevationFt: elevationFt,
                               threshold: threshold, farEnd: farEnd, circuitSide: circuitSide,
                               downwindOffsetM: defaultDownwindOffsetM,
                               patternAltitudeFt: patternAltitudeFt ?? elevationFt + defaultPatternHeightFt)
    }

    /// LSZQ, Bressaucourt, bundled: runway 07 in use, its left-hand circuit at 2,900 ft and its two arrivals as
    /// open flightmaps draws them (AIRAC 2610), the thresholds and the lines from there, the reference point and
    /// the elevation from OurAirports. (OurAirports gives its runway, 07/25, without thresholds.)
    static let lszq = make(
        ident: "LSZQ", name: "Bressaucourt",
        reference: CLLocationCoordinate2D(latitude: 47.392408, longitude: 7.028956), elevationFt: 1866,
        threshold: CLLocationCoordinate2D(latitude: 47.39125, longitude: 7.02427),
        farEnd: CLLocationCoordinate2D(latitude: 47.39356, longitude: 7.03373),
        circuitLine: [(7.03373, 47.39356), (7.05466, 47.39851), (7.05579, 47.4001), (7.04636, 47.41809),
                      (7.044, 47.41884), (6.98485, 47.40447), (6.98375, 47.40284), (6.99369, 47.38507),
                      (6.99602, 47.38434), (7.02427, 47.39125)]
            .map { CLLocationCoordinate2D(latitude: $0.1, longitude: $0.0) },
        circuitAltitudeFt: 2900,
        arrivals: [
            Procedure(name: "ARR SECTOR EAST",
                      line: [(7.10158, 47.38718), (7.07828, 47.39336), (7.05721, 47.39871), (7.05612, 47.39946),
                             (7.04636, 47.41809), (7.044, 47.41884), (6.98485, 47.40447), (6.98374, 47.40285),
                             (6.99369, 47.38507), (6.99603, 47.38434), (7.02427, 47.39125)]
                        .map { CLLocationCoordinate2D(latitude: $0.1, longitude: $0.0) },
                      offCircuit: 0...2),
            Procedure(name: "ARR SEKTOR WEST",
                      line: [(6.94334, 47.37823), (6.97003, 47.38313), (6.98894, 47.38365), (6.99462, 47.384),
                             (7.02427, 47.39125)]
                        .map { CLLocationCoordinate2D(latitude: $0.1, longitude: $0.0) },
                      offCircuit: 0...3),
        ])
}

// MARK: - The circuit as flown

extension DryRunAerodrome {
    /// The circuit the generator flies: the published line, or one laid out on the points above (the runway's far
    /// end, the upwind's end, the downwind, the base, the final, the threshold).
    var circuitLine: [CLLocationCoordinate2D] {
        guard publishedCircuit.isEmpty else { return publishedCircuit }
        return [farEnd, crosswindPoint, downwindStart, downwindEnd, basePoint, finalPoint, threshold]
    }

    /// Each segment's leg, `line[i]` to `line[i + 1]`: along the runway's direction before the downwind is the
    /// upwind, after it the final; against it the downwind; across it the crosswind before the downwind, the base
    /// after. (The legs are worked out as the generator flies them, for its speeds, its heights and what the
    /// guided flight's folded card says; nothing of it is shown as data.)
    static func legs(of line: [CLLocationCoordinate2D], runwayHeading: Double) -> [Leg] {
        var sawDownwind = false
        return zip(line, line.dropFirst()).map { a, b in
            let off = abs(DryRunGeo.angleDifference(from: runwayHeading, to: DryRunGeo.bearing(from: a, to: b)))
            if off > 130 {
                sawDownwind = true
                return .downwind
            }
            if off < 50 { return sawDownwind ? .final : .upwind }
            return sawDownwind ? .base : .crosswind
        }
    }

    var circuitLegs: [Leg] { Self.legs(of: circuitLine, runwayHeading: runwayHeading) }

    /// The way in from `position`: the published arrival whose start is nearest, else a 45° join to the start of
    /// the downwind from 1 NM outside the circuit. Its points from where it begins (flown to first) to the
    /// threshold, and each segment's leg of the circuit (nil: still joining). `beforeDownwind`: only an arrival
    /// that joins the circuit before its downwind (the guided flight's, so the downwind is flown).
    func wayIn(from position: CLLocationCoordinate2D, beforeDownwind: Bool = false) -> (points: [CLLocationCoordinate2D], legs: [Leg?]) {
        let circuit = circuitLine
        let legs = circuitLegs
        let candidates = arrivals.compactMap { arrival -> (points: [CLLocationCoordinate2D], legs: [Leg?])? in
            guard let join = joinIndex(of: arrival) else { return nil }
            if beforeDownwind, !legs[join...].contains(.downwind) { return nil }
            let off = Array(arrival.line[...(arrival.offCircuit?.upperBound ?? max(0, arrival.line.count - 2))])
            let points = off + circuit[join...]
            return (points, Array(repeating: nil, count: off.count) + legs[join...].map(Optional.some))
        }
        if let nearest = candidates.min(by: {
            DryRunGeo.distance(position, $0.points[0]) < DryRunGeo.distance(position, $1.points[0])
        }) {
            return nearest
        }
        guard let join = joinFromOutside else {
            return (circuit, legs.map(Optional.some))
        }
        return ([join.entry] + circuit[join.index...], [nil] + legs[join.index...].map(Optional.some))
    }

    /// The way in the guided flight comes back by (the same as `wayIn` from the side it is placed on): its first
    /// point, and the bearing straight out from it, away from the circuit.
    var guidedEntry: (point: CLLocationCoordinate2D, outward: Double) {
        let way = wayIn(from: reference, beforeDownwind: true)
        let first = way.points[0], second = way.points[min(1, way.points.count - 1)]
        return (first, DryRunGeo.bearing(from: second, to: first))
    }

    /// The circuit's point nearest where `arrival` comes onto it (its first point past the part off it).
    func joinIndex(of arrival: Procedure) -> Int? {
        let circuit = circuitLine
        let onCircuit = arrival.offCircuit.map { $0.upperBound + 1 } ?? (arrival.line.count - 1)
        guard arrival.line.indices.contains(onCircuit), !circuit.isEmpty else { return nil }
        let point = arrival.line[onCircuit]
        return circuit.indices.min { DryRunGeo.distance(circuit[$0], point) < DryRunGeo.distance(circuit[$1], point) }
    }

    /// The downwind's first point on the circuit line, and a point 1 NM outside the circuit from which the
    /// downwind is joined at 45°.
    var joinFromOutside: (entry: CLLocationCoordinate2D, index: Int)? {
        let circuit = circuitLine
        guard let index = circuitLegs.firstIndex(of: .downwind) else { return nil }
        let start = circuit[index]
        let downwind = DryRunGeo.bearing(from: start, to: circuit[index + 1])
        // Outside a left-hand circuit is to the right of its downwind, outside a right-hand one to the left.
        let outward: Double = circuitSide == .left ? 1 : -1
        let inbound = downwind - 45 * outward
        return (DryRunGeo.destination(from: start, bearing: inbound + 180, distance: DryRunGeo.metresPerNM), index)
    }

    /// The published departure that leaves toward `bearing` (degrees true from the aerodrome), nil without one
    /// within 90° of it.
    func departure(toward bearing: Double) -> Procedure? {
        departures.filter { !$0.line.isEmpty }
            .map { ($0, abs(DryRunGeo.angleDifference(from: bearing, to: DryRunGeo.bearing(from: reference, to: $0.line.last!)))) }
            .filter { $0.1 < 90 }
            .min { $0.1 < $1.1 }?.0
    }
}

// MARK: - From the app's data

extension DryRunAerodrome {
    /// An aerodrome as the app's data has it, nil without a runway to fly:
    /// - the runway's ends from open flightmaps' thresholds, else from the airport data's runway ends, else
    ///   laid out on the reference point along the runway's heading and length;
    /// - the runway in use: the one open flightmaps' powered circuit lands on (its line ends at the
    ///   threshold), with that circuit's side, reach and altitude; else the longest open runway from its low
    ///   end, with a left-hand circuit 1,000 ft above the field. (6.4.0)
    /// - a US field's pattern from NASR (`pattern`): the side of that runway's pattern and the field's TPA, where
    ///   until 6.5.0 every dry run without a circuit flew left-hand. (the author's v65-17, 23 Oct 2026)
    static func make(airport: Airport, runways: [Runway], thresholds: [VFRThreshold] = [],
                     circuits: [VFRProcedure] = [], pattern: NASRPatterns.Aerodrome? = nil) -> DryRunAerodrome? {
        let reference = CLLocationCoordinate2D(latitude: airport.latitude, longitude: airport.longitude)
        let elevation = Double(airport.elevation ?? 0)
        let open = runways.filter { !$0.closed }.sorted { ($0.lengthFt ?? 0) > ($1.lengthFt ?? 0) }

        // The runways as pairs of ends, the longest first, with the low end's designator where the data has it.
        var ends: [(CLLocationCoordinate2D, CLLocationCoordinate2D)] = []
        var lowEnds: [String?] = []
        for runway in open {
            let le = runway.leIdent.flatMap { id in thresholds.first { sameRunwayEnd($0.runway, id) } }?.position.coordinate
                ?? coordinate(runway.leLatitude, runway.leLongitude)
            let he = runway.heIdent.flatMap { id in thresholds.first { sameRunwayEnd($0.runway, id) } }?.position.coordinate
                ?? coordinate(runway.heLatitude, runway.heLongitude)
            if let le, let he, DryRunGeo.distance(le, he) > 150 {
                ends.append((le, he))
                lowEnds.append(runway.leIdent)
            }
        }
        if ends.isEmpty { ends = pairs(of: thresholds) }

        // The powered circuit, and the runway it lands on: the end nearest its line's last point.
        let circuit = circuits.first { $0.kind == .circuit && $0.categories.contains(.powered) && $0.usage != .helicopter }
        if let circuit, let last = circuit.line.last?.coordinate {
            var best: (threshold: CLLocationCoordinate2D, farEnd: CLLocationCoordinate2D, distance: Double)?
            for (a, b) in ends {
                for (threshold, farEnd) in [(a, b), (b, a)] {
                    let distance = DryRunGeo.distance(threshold, last)
                    if distance < (best?.distance ?? 800) { best = (threshold, farEnd, distance) }
                }
            }
            if let best {
                // Its arrivals and departures, for the same aircraft as the circuit.
                func procedures(_ kind: VFRProcedure.Kind) -> [Procedure] {
                    circuits.filter { $0.kind == kind && $0.isFor(any: [.powered]) && $0.usage != .helicopter && $0.line.count >= 2 }
                        .map { Procedure(name: $0.name, line: $0.line.map(\.coordinate), offCircuit: $0.offCircuit) }
                }
                return make(ident: airport.ident, name: airport.name, reference: reference, elevationFt: elevation,
                            threshold: best.threshold, farEnd: best.farEnd,
                            circuitLine: circuit.line.map(\.coordinate), circuitAltitudeFt: circuit.altitudeFt.map(Double.init),
                            arrivals: procedures(.arrival), departures: procedures(.departure))
            }
        }
        if let longest = ends.first {
            let side = lowEnds.first.flatMap { $0 }.flatMap { pattern?.side(of: $0) }
            return make(ident: airport.ident, name: airport.name, reference: reference, elevationFt: elevation,
                        threshold: longest.0, farEnd: longest.1,
                        circuitAltitudeFt: pattern?.tpa.map { elevation + Double($0.agl) },
                        circuitSide: side.map { $0 == .right ? .right : .left })
        }
        // Only a heading and a length; else only its designator (Bellechasse, Montricher: 08 lies about 080°,
        // magnetic, a few degrees off true in Europe, near enough for the dry run's runway).
        if let runway = open.first,
           let heading = runway.leHeadingDegT ?? runway.heHeadingDegT.map({ ($0 + 180).truncatingRemainder(dividingBy: 360) })
               ?? designatorHeading(runway.leIdent)
               ?? designatorHeading(runway.heIdent).map({ ($0 + 180).truncatingRemainder(dividingBy: 360) }),
           let length = runway.lengthMeters, length > 150 {
            return make(ident: airport.ident, name: airport.name, reference: reference, elevationFt: elevation,
                        heading: heading, lengthM: Double(length))
        }
        return nil
    }

    /// A runway end's designator as a heading: "08" 80°, "26L" 260°, "36" 0°; nil for a helipad's "H1".
    static func designatorHeading(_ ident: String?) -> Double? {
        guard let ident, let number = Int(ident.prefix { $0.isNumber }), (1...36).contains(number) else { return nil }
        return Double(number % 36) * 10
    }

    private static func coordinate(_ latitude: Double?, _ longitude: Double?) -> CLLocationCoordinate2D? {
        guard let latitude, let longitude, latitude != 0 || longitude != 0 else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// "07" and "7", "25L" and "25 L": the same end.
    static func sameRunwayEnd(_ a: String, _ b: String) -> Bool {
        func normal(_ s: String) -> String {
            let t = s.uppercased().replacingOccurrences(of: " ", with: "")
            let digits = t.prefix { $0.isNumber }
            return String(Int(digits).map(String.init) ?? String(digits)) + t.dropFirst(digits.count)
        }
        return normal(a) == normal(b)
    }

    /// Open flightmaps' thresholds paired end to end (their designators 18 apart), when the airport data has
    /// no runway.
    private static func pairs(of thresholds: [VFRThreshold]) -> [(CLLocationCoordinate2D, CLLocationCoordinate2D)] {
        var result: [(CLLocationCoordinate2D, CLLocationCoordinate2D)] = []
        for (i, a) in thresholds.enumerated() {
            guard let na = Int(a.runway.prefix { $0.isNumber }) else { continue }
            for b in thresholds[(i + 1)...] {
                guard let nb = Int(b.runway.prefix { $0.isNumber }), abs(na - nb) == 18 else { continue }
                result.append((a.position.coordinate, b.position.coordinate))
            }
        }
        return result.sorted { DryRunGeo.distance($0.0, $0.1) > DryRunGeo.distance($1.0, $1.1) }
    }
}

// MARK: - The geometry (a sphere: plenty for a few tens of NM)

enum DryRunGeo {
    static let earthRadiusM = 6_371_000.0
    static let metresPerNM = 1852.0
    static let metresPerFoot = 0.3048
    static let metresPerSecondPerKnot = 0.514444

    static func destination(from start: CLLocationCoordinate2D, bearing: Double, distance: Double) -> CLLocationCoordinate2D {
        let p1 = start.latitude * .pi / 180, l1 = start.longitude * .pi / 180, b = bearing * .pi / 180
        let d = distance / earthRadiusM
        let p2 = asin(sin(p1) * cos(d) + cos(p1) * sin(d) * cos(b))
        let l2 = l1 + atan2(sin(b) * sin(d) * cos(p1), cos(d) - sin(p1) * sin(p2))
        let longitude = (l2 * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180
        return CLLocationCoordinate2D(latitude: p2 * 180 / .pi, longitude: longitude)
    }

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        Flight.haversineMeters(a.latitude, a.longitude, b.latitude, b.longitude)
    }

    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dl = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// `to` − `from`, between -180 and 180.
    static func angleDifference(from: Double, to: Double) -> Double {
        (to - from + 540).truncatingRemainder(dividingBy: 360) - 180
    }
}
