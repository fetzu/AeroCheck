import MapKit
import UIKit

// MARK: - Arrival sectors and the approach view (6.2.0)
//
// The author's design (6 Oct, after four rounds of mockups at LSZQ and LSGE, "C with E"):
// - An arrival or departure sector is faint (ink blue at 10 %, a dashed edge, its corners rounded), and
//   its letter (N, E, SW…) sits in a round ink badge of a fixed screen size at the sector's deepest
//   point; without a sector, where the arrival starts. The arrival is drawn from the sector's edge to
//   where it meets the circuit, a filled arrowhead there: the part along the circuit is the circuit's.
// - The circuit's altitude is a pill turned along the downwind, upright, outside the circuit.
// - The approach view, only on approach in flight (the destination or the field diverted to, within
//   10 NM or from the Approach phase) or zoomed in on an aerodrome in Plan › Map (8 NM or less): the
//   chart faded round the field, the runway's extended centreline with its numbers (in flight the
//   runway in use filled), the circuit's direction for that runway, and a parachute where OpenAIP
//   says there is parachuting.
// Everything is drawn from data the app has (open flightmaps through the AeroCheck server, OpenAIP,
// the airport database); the official chart stays a tap away in the callout.

// MARK: - Geometry

/// Pure geometry for drawing the sectors and the arrivals: an arrival cut at its sector's edge, the
/// rounded ring, the circuit's downwind. On a local flat projection (longitude scaled by cos latitude),
/// which is exact enough for a few NM. The letter, the badge's point and the part of a route off the
/// circuit come with the data (`dir`, an area's `label`, `offCircuit`): the app works none of them out.
enum VFRSectorGeometry {
    /// The letters a sector can have, the intercardinals included: a `dir` outside them is ignored.
    static let directions: Set<String> = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

    /// Metres between two points.
    static func meters(_ a: VFRCoordinate, _ b: VFRCoordinate) -> Double {
        VFRLabelPlacement.flatDistance(a, b) * 111_320
    }

    /// Whether `point` is inside `ring` (open or closed).
    static func contains(_ point: VFRCoordinate, _ ring: [VFRCoordinate]) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.latitude > point.latitude) != (b.latitude > point.latitude),
               point.longitude < (b.longitude - a.longitude) * (point.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// An arrival from where it leaves its sector (it crosses it on the way in, so its line would run
    /// through the badge); a departure up to where it enters its sector. Every 25 m. The line itself
    /// when it never enters the sector.
    static func outsideSector(_ line: [VFRCoordinate], ring: [VFRCoordinate],
                              kind: VFRProcedure.Kind) -> [VFRCoordinate] {
        guard line.count >= 2, ring.count >= 3 else { return line }
        var dense: [VFRCoordinate] = []
        for (a, b) in zip(line, line.dropFirst()) {
            let steps = max(1, Int(meters(a, b) / 25))
            for t in 0..<steps {
                let f = Double(t) / Double(steps)
                dense.append(VFRCoordinate(latitude: a.latitude + (b.latitude - a.latitude) * f,
                                           longitude: a.longitude + (b.longitude - a.longitude) * f))
            }
        }
        dense.append(line[line.count - 1])
        let inside = dense.indices.filter { contains(dense[$0], ring) }
        switch kind {
        case .arrival:
            guard let cut = inside.last, cut < dense.count - 2 else { return line }
            return Array(dense[cut...])
        case .departure:
            guard let cut = inside.first, cut > 1 else { return line }
            return Array(dense[...cut])
        case .circuit:
            return line
        }
    }

    /// `ring` with its corners rounded (Chaikin's corner cutting, closed): open flightmaps draws its
    /// sectors as a few straight sides, the VACs as soft shapes.
    static func rounded(_ ring: [VFRCoordinate], iterations: Int = 3) -> [VFRCoordinate] {
        guard ring.count >= 3 else { return ring }
        var points = ring
        for _ in 0..<iterations {
            var next: [VFRCoordinate] = []
            for (index, a) in points.enumerated() {
                let b = points[(index + 1) % points.count]
                next.append(VFRCoordinate(latitude: 0.75 * a.latitude + 0.25 * b.latitude,
                                          longitude: 0.75 * a.longitude + 0.25 * b.longitude))
                next.append(VFRCoordinate(latitude: 0.25 * a.latitude + 0.75 * b.latitude,
                                          longitude: 0.25 * a.longitude + 0.75 * b.longitude))
            }
            points = next
        }
        return points
    }

    /// A circuit's downwind: its longest leg, as drawn (from, to).
    static func downwind(of line: [VFRCoordinate]) -> (VFRCoordinate, VFRCoordinate)? {
        zip(line, line.dropFirst()).max { meters($0.0, $0.1) < meters($1.0, $1.1) }
    }

    /// Whether the outside of the circuit is on the left of its leg `from` → `to`, looking along it.
    static func outsideIsLeft(of leg: (VFRCoordinate, VFRCoordinate), circuit line: [VFRCoordinate]) -> Bool {
        let k = cos(leg.0.latitude * .pi / 180)
        let cx = line.map(\.longitude).reduce(0, +) / Double(line.count) * k
        let cy = line.map(\.latitude).reduce(0, +) / Double(line.count)
        let ax = leg.0.longitude * k, ay = leg.0.latitude, bx = leg.1.longitude * k, by = leg.1.latitude
        // North up: a positive cross product puts the centre on the left, so the outside is on the right.
        return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax) < 0
    }

    /// The true bearing from `a` to `b`, degrees.
    static func bearing(_ a: VFRCoordinate, _ b: VFRCoordinate) -> Double {
        let k = cos((a.latitude + b.latitude) / 2 * .pi / 180)
        let degrees = atan2((b.longitude - a.longitude) * k, b.latitude - a.latitude) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The smaller angle between two bearings, 0 to 180.
    static func angle(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    /// The point `meters` from `point` towards `bearing`.
    static func offset(_ point: VFRCoordinate, bearing: Double, meters: Double) -> VFRCoordinate {
        let r = bearing * .pi / 180
        let dLat = meters * cos(r) / 111_320
        let dLon = meters * sin(r) / (111_320 * cos(point.latitude * .pi / 180))
        return VFRCoordinate(latitude: point.latitude + dLat, longitude: point.longitude + dLon)
    }
}

// MARK: - The approach view

/// One runway as the approach view draws it: its two ends (threshold, designator, true bearing of the
/// direction that lands on it).
struct VFRRunwayEnds: Equatable, Sendable {
    struct End: Equatable, Sendable {
        let ident: String
        let threshold: VFRCoordinate
        let trueBearing: Double
    }

    let first: End
    let second: End

    /// The runways of an aerodrome: open flightmaps' thresholds when it has them (paired by
    /// designator), else the airport database's ends, else the reference point with the runway's
    /// heading and length (OurAirports gives LSZQ's runway no thresholds).
    static func runways(thresholds: [VFRThreshold], airportRunways: [Runway],
                        reference: VFRCoordinate?) -> [VFRRunwayEnds] {
        var result: [VFRRunwayEnds] = []
        var used = Set<Int>()
        for (i, a) in thresholds.enumerated() where !used.contains(i) {
            guard let j = thresholds.indices.first(where: { j in
                j != i && !used.contains(j) && isReciprocal(a.runway, thresholds[j].runway)
            }) else { continue }
            let b = thresholds[j]
            used.formUnion([i, j])
            let bearingA = a.trueBearing ?? VFRSectorGeometry.bearing(a.position, b.position)
            let bearingB = b.trueBearing ?? VFRSectorGeometry.bearing(b.position, a.position)
            result.append(VFRRunwayEnds(
                first: End(ident: ident(for: bearingA, among: airportRunways) ?? a.runway, threshold: a.position, trueBearing: bearingA),
                second: End(ident: ident(for: bearingB, among: airportRunways) ?? b.runway, threshold: b.position, trueBearing: bearingB)))
        }
        if !result.isEmpty { return result }
        for runway in airportRunways where !runway.closed {
            guard let le = runway.leIdent, let he = runway.heIdent else { continue }
            if let la = runway.leLatitude, let lo = runway.leLongitude, let ha = runway.heLatitude, let ho = runway.heLongitude {
                let a = VFRCoordinate(latitude: la, longitude: lo), b = VFRCoordinate(latitude: ha, longitude: ho)
                result.append(VFRRunwayEnds(first: End(ident: le, threshold: a, trueBearing: VFRSectorGeometry.bearing(a, b)),
                                            second: End(ident: he, threshold: b, trueBearing: VFRSectorGeometry.bearing(b, a))))
            } else if let reference, let heading = runway.leHeadingDegT ?? designatorBearing(le),
                      let length = runway.lengthFt, length > 0 {
                let half = Double(length) * 0.3048 / 2
                let a = VFRSectorGeometry.offset(reference, bearing: heading + 180, meters: half)
                let b = VFRSectorGeometry.offset(reference, bearing: heading, meters: half)
                result.append(VFRRunwayEnds(first: End(ident: le, threshold: a, trueBearing: heading),
                                            second: End(ident: he, threshold: b, trueBearing: (heading + 180).truncatingRemainder(dividingBy: 360))))
            }
        }
        return result
    }

    /// The airport database's designator for the end landing on `bearing` (within 20°): the app votes on
    /// designators across its sources, and open flightmaps' can lag (LSGE's 10/28 where OurAirports,
    /// OpenAIP and the VAC have 09/27). Nil when it has no such end.
    static func ident(for bearing: Double, among runways: [Runway]) -> String? {
        var best: (ident: String, off: Double)?
        for runway in runways where !runway.closed {
            for (ident, heading) in [(runway.leIdent, runway.leHeadingDegT), (runway.heIdent, runway.heHeadingDegT)] {
                guard let ident, let endBearing = heading ?? designatorBearing(ident) else { continue }
                let off = VFRSectorGeometry.angle(endBearing, bearing)
                if off <= 20, off < (best?.off ?? .infinity) { best = (ident, off) }
            }
        }
        return best?.ident
    }

    /// The runway's length, threshold to threshold, in metres.
    var lengthMeters: Double { VFRSectorGeometry.meters(first.threshold, second.threshold) }

    /// "07" and "25", "09L" and "27R": the same strip landed on either way.
    static func isReciprocal(_ a: String, _ b: String) -> Bool {
        guard let x = Int(a.prefix(2)), let y = Int(b.prefix(2)) else { return false }
        return abs(x - y) == 18
    }

    /// A designator's rough bearing ("07" → 70°).
    static func designatorBearing(_ ident: String) -> Double? {
        Int(ident.prefix(2)).map { Double($0 % 36) * 10 }
    }

    /// The end that lands into `windFrom` (degrees true); nil without a wind direction.
    static func endInUse(of runways: [VFRRunwayEnds], windFrom: Double?) -> End? {
        guard let windFrom else { return nil }
        return runways.flatMap { [$0.first, $0.second] }
            .min { VFRSectorGeometry.angle($0.trueBearing, windFrom) < VFRSectorGeometry.angle($1.trueBearing, windFrom) }
    }
}

/// A direction arrowhead on a circuit's downwind: where, and which way (degrees true).
struct VFRDirectionArrow: Equatable, Sendable {
    let at: VFRCoordinate
    let bearing: Double
}

/// What the approach view draws for one aerodrome.
struct VFRApproachField: Equatable, Sendable {
    let ident: String
    let reference: VFRCoordinate
    let runways: [VFRRunwayEnds]
    /// The runway landed on, in flight (from the briefing's wind); nil on the ground, or without a wind.
    let runwayInUse: String?
    let arrows: [VFRDirectionArrow]
    let parachuting: Bool
    /// Where the parachute goes: beside the field, away from its circuits.
    let parachutePosition: VFRCoordinate?

    /// How far the fade reaches, and the centreline past each threshold.
    static let fadeRadiusNM = 4.2
    static let centrelineNM = 2.0

    var drawKey: String {
        "approach|\(ident)|\(runwayInUse ?? "-")|\(parachuting)|\(arrows.count)|\(runways.count)"
    }

    /// - Parameters:
    ///   - circuits: the aerodrome's circuits as drawn, for the direction arrows.
    ///   - windFrom: the wind's direction (degrees true), in flight; nil on the ground.
    static func make(ident: String, reference: VFRCoordinate, runways: [VFRRunwayEnds], circuits: [VFRProcedure],
                     windFrom: Double?, parachuting: Bool) -> VFRApproachField {
        let inUse = VFRRunwayEnds.endInUse(of: runways, windFrom: windFrom)
        // The longest runway, and the one in use if it is another: Bern's parallel strips put four
        // numbers on top of each other at the end of their centrelines.
        let longest = runways.max { $0.lengthMeters < $1.lengthMeters }
        let runways = runways.filter { runway in
            runway == longest || (inUse.map { [runway.first.ident, runway.second.ident].contains($0.ident) } ?? false)
        }
        var arrows: [VFRDirectionArrow] = []
        if let inUse {
            for circuit in circuits where circuit.kind == .circuit && circuit.line.count >= 3 {
                arrows += directionArrows(on: circuit.line, landing: inUse.trueBearing)
            }
        }
        return VFRApproachField(ident: ident, reference: reference, runways: runways, runwayInUse: inUse?.ident,
                                arrows: arrows, parachuting: parachuting,
                                parachutePosition: parachuting ? parachuteSpot(reference: reference, runways: runways, circuits: circuits) : nil)
    }

    /// The circuit's direction for the runway landed on: two arrowheads on the downwind. Open
    /// flightmaps draws a circuit for one runway, its line ending on that runway's final: flown the
    /// same way when the runway in use lands the way that final does, the other way round for the
    /// opposite runway; none when it's neither (a circuit for a crossing runway).
    static func directionArrows(on line: [VFRCoordinate], landing bearing: Double) -> [VFRDirectionArrow] {
        guard line.count >= 3, let leg = VFRSectorGeometry.downwind(of: line) else { return [] }
        let final = VFRSectorGeometry.bearing(line[line.count - 2], line[line.count - 1])
        let difference = VFRSectorGeometry.angle(final, bearing)
        let forward: Bool
        if difference <= 60 { forward = true } else if difference >= 120 { forward = false } else { return [] }
        let legBearing = VFRSectorGeometry.bearing(leg.0, leg.1)
        let way = forward ? legBearing : (legBearing + 180).truncatingRemainder(dividingBy: 360)
        return [0.16, 0.84].map { t in
            VFRDirectionArrow(at: VFRCoordinate(latitude: leg.0.latitude + (leg.1.latitude - leg.0.latitude) * t,
                                                longitude: leg.0.longitude + (leg.1.longitude - leg.0.longitude) * t),
                              bearing: way)
        }
    }

    /// 0.35 NM from the reference point, square to the runway, on the side away from the circuits.
    static func parachuteSpot(reference: VFRCoordinate, runways: [VFRRunwayEnds], circuits: [VFRProcedure]) -> VFRCoordinate {
        let runwayBearing = runways.first?.first.trueBearing ?? 0
        let points = circuits.flatMap(\.line)
        var side = runwayBearing + 90
        if !points.isEmpty {
            let centre = VFRCoordinate(latitude: points.map(\.latitude).reduce(0, +) / Double(points.count),
                                       longitude: points.map(\.longitude).reduce(0, +) / Double(points.count))
            let towardsCircuits = VFRSectorGeometry.bearing(reference, centre)
            if VFRSectorGeometry.angle(side, towardsCircuits) < 90 { side += 180 }
        }
        return VFRSectorGeometry.offset(reference, bearing: side.truncatingRemainder(dividingBy: 360), meters: 0.35 * 1852)
    }
}

// MARK: - Overlays and annotations of the approach view

/// The chart faded round the field: a soft disc, white by day, a dimming at night.
final class VFRFadeOverlay: NSObject, MKOverlay, VFRProcedureShape {
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect
    let radiusMeters: Double
    var procedureId = ""
    var drawKey = ""
    var isScaled: Bool { false }

    init(center: CLLocationCoordinate2D, radiusMeters: Double) {
        coordinate = center
        self.radiusMeters = radiusMeters
        let points = radiusMeters * MKMapPointsPerMeterAtLatitude(center.latitude)
        let c = MKMapPoint(center)
        boundingMapRect = MKMapRect(x: c.x - points, y: c.y - points, width: 2 * points, height: 2 * points)
        super.init()
    }
}

/// Draws `VFRFadeOverlay`: a radial gradient, 42 % in the middle, 30 % three quarters out, none at the edge.
final class VFRFadeRenderer: MKOverlayRenderer {
    let color: UIColor

    init(overlay: VFRFadeOverlay, color: UIColor) {
        self.color = color
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let fade = overlay as? VFRFadeOverlay else { return }
        let rect = self.rect(for: fade.boundingMapRect)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2
        let colors = [color.withAlphaComponent(0.42).cgColor, color.withAlphaComponent(0.30).cgColor,
                      color.withAlphaComponent(0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                        locations: [0, 0.75, 1]) else { return }
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                   endRadius: radius, options: [])
    }
}

/// A runway number at the end of its extended centreline, or the parachute beside the field.
final class VFRApproachAnnotation: NSObject, MKAnnotation {
    enum Kind: Equatable {
        /// The number, and whether it is the runway in use (filled).
        case runway(String, inUse: Bool)
        case parachute
    }

    let kind: Kind
    let field: String
    let coordinate: CLLocationCoordinate2D

    init(kind: Kind, field: String, coordinate: CLLocationCoordinate2D) {
        self.kind = kind
        self.field = field
        self.coordinate = coordinate
        super.init()
    }

    var labelKey: String {
        switch kind {
        case .runway(let ident, let inUse): return "approach|\(field)|rwy|\(ident)|\(inUse)|\(coordinate.latitude),\(coordinate.longitude)"
        case .parachute: return "approach|\(field)|para|\(coordinate.latitude),\(coordinate.longitude)"
        }
    }

    /// The approach view's annotations for `field`: a number past each end of each centreline, the
    /// parachute.
    static func annotations(for field: VFRApproachField) -> [VFRApproachAnnotation] {
        var out: [VFRApproachAnnotation] = []
        let reach = (VFRApproachField.centrelineNM + 0.25) * 1852
        for runway in field.runways {
            for (end, other) in [(runway.first, runway.second), (runway.second, runway.first)] {
                // An end's number where the pilot lands on it: on the approach side, past the centreline.
                let outward = VFRSectorGeometry.bearing(other.threshold, end.threshold)
                let at = VFRSectorGeometry.offset(end.threshold, bearing: outward, meters: reach)
                out.append(VFRApproachAnnotation(kind: .runway(end.ident, inUse: end.ident == field.runwayInUse),
                                                 field: field.ident, coordinate: at.coordinate))
            }
        }
        if let spot = field.parachutePosition {
            out.append(VFRApproachAnnotation(kind: .parachute, field: field.ident, coordinate: spot.coordinate))
        }
        return out
    }
}

/// The bitmaps of the approach view and of the sector badges. Bitmaps, never symbol images
/// (`aeroMarkerSymbol`).
enum VFRApproachImages {
    private static var cache: [String: UIImage] = [:]

    /// A sector's letter in a 34 pt ink disc with a white ring, in a 44 pt square (the touch target).
    static func badge(_ letter: String, palette: VFRMapPalette) -> UIImage {
        let key = "badge|\(letter)|\(palette.rawValue)"
        if let cached = cache[key] { return cached }
        let canvas = CGSize(width: 44, height: 44)
        let image = UIGraphicsImageRenderer(size: canvas).image { _ in
            let ring = CGRect(x: 22 - 19.5, y: 22 - 19.5, width: 39, height: 39)
            palette.labelFill.setFill()
            UIBezierPath(ovalIn: ring).fill()
            palette.procedure.setFill()
            UIBezierPath(ovalIn: ring.insetBy(dx: 2.5, dy: 2.5)).fill()
            let font = UIFont.aero(size: letter.count > 1 ? 16 : 21, weight: .bold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: palette.badgeLetter]
            let size = (letter as NSString).size(withAttributes: attributes)
            (letter as NSString).draw(at: CGPoint(x: 22 - size.width / 2, y: 22 - size.height / 2), withAttributes: attributes)
        }
        cache[key] = image
        return image
    }

    /// A runway number: ink with a halo, or filled for the runway in use.
    static func runway(_ ident: String, inUse: Bool, palette: VFRMapPalette) -> UIImage {
        let key = "rwy|\(ident)|\(inUse)|\(palette.rawValue)"
        if let cached = cache[key] { return cached }
        let font = UIFont.aero(size: 19, weight: .bold)
        let textSize = (ident as NSString).size(withAttributes: [.font: font])
        let box = CGSize(width: ceil(textSize.width) + 16, height: ceil(textSize.height) + 6)
        let canvas = CGSize(width: max(44, box.width + 4), height: max(44, box.height + 4))
        let image = UIGraphicsImageRenderer(size: canvas).image { _ in
            let rect = CGRect(x: (canvas.width - box.width) / 2, y: (canvas.height - box.height) / 2,
                              width: box.width, height: box.height)
            let origin = CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2)
            if inUse {
                let shape = UIBezierPath(roundedRect: rect, cornerRadius: 6)
                palette.procedure.setFill()
                shape.fill()
                palette.labelFill.setStroke()
                shape.lineWidth = 2
                shape.stroke()
                (ident as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: palette.badgeLetter])
            } else {
                (ident as NSString).draw(at: origin, withAttributes: [.font: font, .strokeColor: palette.labelFill,
                                                                      .strokeWidth: 8, .foregroundColor: palette.labelFill])
                (ident as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: palette.procedure])
            }
        }
        cache[key] = image
        return image
    }

    /// A parachute in a 30 pt ink disc with a white ring.
    static func parachute(palette: VFRMapPalette) -> UIImage {
        let key = "para|\(palette.rawValue)"
        if let cached = cache[key] { return cached }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 44, height: 44)).image { _ in
            let ring = CGRect(x: 22 - 16, y: 22 - 16, width: 32, height: 32)
            palette.labelFill.setFill()
            UIBezierPath(ovalIn: ring).fill()
            palette.procedure.setFill()
            UIBezierPath(ovalIn: ring.insetBy(dx: 2, dy: 2)).fill()
            let ink = palette.badgeLetter
            ink.setFill()
            ink.setStroke()
            // The canopy, its lines, the jumper.
            let canopy = UIBezierPath()
            canopy.addArc(withCenter: CGPoint(x: 22, y: 20), radius: 9, startAngle: .pi, endAngle: 0, clockwise: true)
            canopy.addQuadCurve(to: CGPoint(x: 13, y: 20), controlPoint: CGPoint(x: 22, y: 16))
            canopy.fill()
            let lines = UIBezierPath()
            lines.lineWidth = 1.2
            for x in [13.5, 22, 30.5] {
                lines.move(to: CGPoint(x: x, y: 19.5))
                lines.addLine(to: CGPoint(x: 22, y: 27))
            }
            lines.stroke()
            UIBezierPath(ovalIn: CGRect(x: 20, y: 26.5, width: 4, height: 4)).fill()
        }
        cache[key] = image
        return image
    }
}
