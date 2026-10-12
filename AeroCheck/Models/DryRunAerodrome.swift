import Foundation
import CoreLocation

// MARK: - Dry run (6.4.0): an aerodrome as the generator flies it

/// An aerodrome as a dry run flies it: the runway in use from its threshold to its far end, the side of its
/// circuit, how far out the downwind runs and the circuit's altitude. Made from open flightmaps' thresholds
/// and powered circuit where the app has them, else laid out on the reference point along a heading. LSZQ
/// is bundled (the author's pick, 12 Oct), so the guided flight flies on a fresh install, before any data
/// is downloaded. (6.4.0)
struct DryRunAerodrome {
    enum Side: Equatable {
        case left, right

        /// +1 right of the runway's direction, -1 left (the generator's offsets).
        var sign: Double { self == .right ? 1 : -1 }
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
    static func make(ident: String, name: String, reference: CLLocationCoordinate2D, elevationFt: Double,
                     threshold: CLLocationCoordinate2D, farEnd: CLLocationCoordinate2D,
                     circuitLine: [CLLocationCoordinate2D] = [], circuitAltitudeFt: Double? = nil) -> DryRunAerodrome {
        let heading = DryRunGeo.bearing(from: threshold, to: farEnd)
        // Each point's distance off the runway's line, metres, positive to its right.
        let offsets = circuitLine.map { point -> Double in
            let d = DryRunGeo.distance(threshold, point)
            let off = DryRunGeo.angleDifference(from: heading, to: DryRunGeo.bearing(from: threshold, to: point))
            return d * sin(off * .pi / 180)
        }.filter { abs($0) > 0.2 * DryRunGeo.metresPerNM }
        var side = Side.left
        var offset = defaultDownwindOffsetM
        if !offsets.isEmpty {
            side = offsets.reduce(0, +) > 0 ? .right : .left
            let reach = offsets.map(abs).max() ?? offset
            offset = min(1.6 * DryRunGeo.metresPerNM, max(0.6 * DryRunGeo.metresPerNM, reach))
        }
        return DryRunAerodrome(ident: ident, name: name, reference: reference, elevationFt: elevationFt,
                               threshold: threshold, farEnd: farEnd, circuitSide: side, downwindOffsetM: offset,
                               patternAltitudeFt: circuitAltitudeFt ?? elevationFt + defaultPatternHeightFt)
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

    /// LSZQ, Bressaucourt, bundled: runway 07 in use, its left-hand circuit at 2,900 ft as open flightmaps
    /// draws it (AIRAC 2610), the thresholds and the circuit's line from there, the reference point and the
    /// elevation from OurAirports. (OurAirports gives its runway, 07/25, without thresholds.)
    static let lszq = make(
        ident: "LSZQ", name: "Bressaucourt",
        reference: CLLocationCoordinate2D(latitude: 47.392408, longitude: 7.028956), elevationFt: 1866,
        threshold: CLLocationCoordinate2D(latitude: 47.39125, longitude: 7.02427),
        farEnd: CLLocationCoordinate2D(latitude: 47.39356, longitude: 7.03373),
        circuitLine: [(7.03373, 47.39356), (7.05466, 47.39851), (7.05579, 47.4001), (7.04636, 47.41809),
                      (7.044, 47.41884), (6.98485, 47.40447), (6.98375, 47.40284), (6.99369, 47.38507),
                      (6.99602, 47.38434), (7.02427, 47.39125)]
            .map { CLLocationCoordinate2D(latitude: $0.1, longitude: $0.0) },
        circuitAltitudeFt: 2900)
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
