import MapKit
import UIKit

// MARK: - The airspace's tags on the Cockpit's map (6.9.0)

/// What a tag says: a badge, the name, the limits as a pilot reads them. Every value at the in-flight size (a11 A). The
/// words here are the chart's: R, D, P, TMZ, GLD, a class letter, FL, ft, none of them translated.
struct AirspaceTagContent: Hashable {
    enum Shape: Hashable { case full, floor, ceiling }

    let id: String
    let shape: Shape
    let badge: String
    let name: String
    let upper: String
    let lower: String
    let kind: AirspaceMapKind

    init(_ tag: AirspaceRelevantTag) {
        id = tag.airspace.id
        switch tag.kind {
        case .atLevel: shape = .full
        case .floor: shape = .floor
        case .ceiling: shape = .ceiling
        }
        badge = Self.badge(tag.airspace)
        name = Self.name(tag.airspace)
        upper = Self.limit(tag.airspace.upperCeiling)
        lower = Self.limit(tag.airspace.lowerCeiling)
        kind = tag.airspace.mapKind
    }

    /// "GND", "FL 130", "4500 ft", "2000 AGL".
    static func limit(_ limit: AltitudeLimit) -> String {
        if limit.unit == 6 || limit.referenceDatum == 2 { return "FL \(Int((limit.asFeetMSL / 100).rounded()))" }
        if limit.value == 0, limit.referenceDatum == 0 { return "GND" }
        let feet = Int(limit.asFeetMSL.rounded())
        return limit.referenceDatum == 0 ? "\(feet) AGL" : "\(feet) ft"
    }

    static func badge(_ airspace: Airspace) -> String {
        switch airspace.airspaceType {
        case .restricted: return "R"
        case .danger: return "D"
        case .prohibited: return "P"
        case .gliderSector: return "GLD"
        case .aerial: return "AER"
        case .tmz: return "TMZ"
        case .rmz: return "RMZ"
        case .trp: return "TMZ"
        default: return airspace.airspaceClass?.letter ?? "?"
        }
    }

    static func name(_ airspace: Airspace) -> String {
        String(airspace.name.replacingOccurrences(of: "(HX)", with: "HX")
            .trimmingCharacters(in: .whitespaces).prefix(24))
    }

    /// The arrow tag's limit: the floor above, the ceiling below.
    var arrowText: String { shape == .ceiling ? "▼ \(upper)" : "▲ \(lower)" }

    /// The limits along an airspace's boundary, ground first, from one to the other (the author's q6, 5 Nov 2026): a
    /// slash is the chart's stack laid flat, and reads upside down this way round. Each keeps its unit, since the two can
    /// have different references: 2000 AGL – 4000 ft.
    static func boundaryText(_ airspace: Airspace) -> String {
        "\(badge(airspace)) \(limit(airspace.lowerCeiling)) – \(limit(airspace.upperCeiling))"
    }
}

/// Draws a tag to an image, as the map's markers are. `scale` is 1 on the iPad, the phone's in-flight label over 20.
enum AirspaceTagImage {
    private static let ink = UIColor(red: 0.067, green: 0.078, blue: 0.094, alpha: 1)

    private static func color(_ kind: AirspaceMapKind) -> UIColor {
        let c = kind.color
        return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
    }

    static func size(_ content: AirspaceTagContent, scale k: CGFloat) -> CGSize {
        let value = UIFont.aero(size: 20 * k, weight: .bold, monospaced: true)
        let width = { (text: String, font: UIFont) in ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        if content.shape == .full {
            let name = UIFont.aero(size: 13 * k, weight: .regular)
            let values = max(width(content.upper, value), width(content.lower, value)) + 58 * k
            return CGSize(width: max(values, width(content.name, name) + 20 * k), height: 78 * k)
        }
        let badge = UIFont.aero(size: 13 * k, weight: .bold)
        return CGSize(width: width(content.arrowText, value) + width(content.badge, badge) + 34 * k, height: 36 * k)
    }

    static func image(_ content: AirspaceTagContent, scale k: CGFloat) -> UIImage {
        let size = size(content, scale: k)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let plate = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 1.25 * k, dy: 1.25 * k),
                                     cornerRadius: 7 * k)
            UIColor.white.withAlphaComponent(0.94).setFill()
            plate.fill()
            color(content.kind).setStroke()
            plate.lineWidth = 2.5 * k
            plate.stroke()
            content.shape == .full ? drawFull(content, size: size, k: k) : drawArrow(content, size: size, k: k)
        }
    }

    private static func drawFull(_ content: AirspaceTagContent, size: CGSize, k: CGFloat) {
        (content.name as NSString).draw(at: CGPoint(x: 10 * k, y: 6 * k), withAttributes: [
            .font: UIFont.aero(size: 13 * k, weight: .regular), .foregroundColor: ink])
        let box = CGRect(x: 8 * k, y: 26 * k, width: 34 * k, height: 44 * k)
        color(content.kind).setFill()
        UIBezierPath(roundedRect: box, cornerRadius: 5 * k).fill()
        let font = UIFont.aero(size: (content.badge.count == 1 ? 22 : 12) * k, weight: .bold)
        let badge = NSAttributedString(string: content.badge, attributes: [.font: font, .foregroundColor: UIColor.white])
        let badgeSize = badge.size()
        badge.draw(at: CGPoint(x: box.midX - badgeSize.width / 2, y: box.midY - badgeSize.height / 2))
        let value: [NSAttributedString.Key: Any] = [.font: UIFont.aero(size: 20 * k, weight: .bold, monospaced: true),
                                                    .foregroundColor: ink]
        let x = box.maxX + 8 * k
        (content.upper as NSString).draw(at: CGPoint(x: x, y: 24 * k), withAttributes: value)
        (content.lower as NSString).draw(at: CGPoint(x: x, y: 50 * k), withAttributes: value)
        let line = UIBezierPath()
        line.move(to: CGPoint(x: x, y: 50 * k))
        line.addLine(to: CGPoint(x: size.width - 10 * k, y: 50 * k))
        ink.setStroke()
        line.lineWidth = 1.4 * k
        line.stroke()
    }

    private static func drawArrow(_ content: AirspaceTagContent, size: CGSize, k: CGFloat) {
        let badge = NSAttributedString(string: content.badge, attributes: [
            .font: UIFont.aero(size: 13 * k, weight: .bold), .foregroundColor: color(content.kind)])
        let badgeSize = badge.size()
        badge.draw(at: CGPoint(x: 10 * k, y: (size.height - badgeSize.height) / 2))
        let text = NSAttributedString(string: content.arrowText, attributes: [
            .font: UIFont.aero(size: 20 * k, weight: .bold, monospaced: true), .foregroundColor: ink])
        text.draw(at: CGPoint(x: 18 * k + badgeSize.width, y: (size.height - text.size().height) / 2))
    }
}

/// Where the tags go on the map: ranked, each inside its own airspace, never over the aircraft, the route's ends, the
/// controls or the status slot, and where it was while that still holds, so tags don't jump as the aircraft moves
/// (human-factors principle 15). Pure: points on the map's view in, points out.
enum AirspaceTagPlacer {
    struct Request {
        let id: String
        /// The airspace's edge in the map's points.
        let ring: [CGPoint]
        let size: CGSize
        /// Where the tag's centre was, if it is on the map.
        var previous: CGPoint?
    }

    static let margin: CGFloat = 6
    static let grid = 16

    static func place(_ requests: [Request], in bounds: CGRect, keepOut: [CGRect]) -> [String: CGPoint] {
        let area = bounds.insetBy(dx: 8, dy: 8)
        var taken = keepOut
        var placed: [String: CGPoint] = [:]
        // A kept tag holds its place against a new one of lower rank, never against a higher one: rank decides first.
        for request in requests {
            let fits = { (point: CGPoint) -> CGRect? in
                let rect = CGRect(x: point.x - request.size.width / 2, y: point.y - request.size.height / 2,
                                  width: request.size.width, height: request.size.height)
                guard area.contains(rect), !taken.contains(where: { $0.insetBy(dx: -margin, dy: -margin).intersects(rect) })
                else { return nil }
                return rect
            }
            let candidates = (request.previous.map { [$0] } ?? []) + spots(in: request.ring, within: area)
            for point in candidates where inside(point, request.ring) {
                if let rect = fits(point) {
                    taken.append(rect)
                    placed[request.id] = point
                    break
                }
            }
        }
        return placed
    }

    /// Grid points inside the ring and on the map, the one deepest inside first, then outward from it.
    static func spots(in ring: [CGPoint], within area: CGRect) -> [CGPoint] {
        guard ring.count >= 3 else { return [] }
        let box = ring.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }.intersection(area)
        guard !box.isNull, box.width > 0, box.height > 0 else { return [] }
        var points: [CGPoint] = []
        for i in 1..<grid {
            for j in 1..<grid {
                let point = CGPoint(x: box.minX + box.width * CGFloat(i) / CGFloat(grid),
                                    y: box.minY + box.height * CGFloat(j) / CGFloat(grid))
                if inside(point, ring) { points.append(point) }
            }
        }
        guard let deepest = points.max(by: { clearance($0, ring) < clearance($1, ring) }) else { return [] }
        return points.sorted { hypot($0.x - deepest.x, $0.y - deepest.y) < hypot($1.x - deepest.x, $1.y - deepest.y) }
    }

    private static func clearance(_ point: CGPoint, _ ring: [CGPoint]) -> CGFloat {
        var nearest = CGFloat.infinity
        for (a, b) in zip(ring, ring.dropFirst() + ring.prefix(1)) {
            let dx = b.x - a.x, dy = b.y - a.y
            let square = dx * dx + dy * dy
            let t = square > 0 ? min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / square, 0), 1) : 0
            nearest = min(nearest, hypot(point.x - a.x - t * dx, point.y - a.y - t * dy))
        }
        return nearest
    }

    static func inside(_ point: CGPoint, _ ring: [CGPoint]) -> Bool {
        var isInside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                isInside.toggle()
            }
            j = i
        }
        return isInside
    }
}

/// A tag on the map.
final class AirspaceTagAnnotation: NSObject, MKAnnotation {
    let content: AirspaceTagContent
    let coordinate: CLLocationCoordinate2D
    var title: String? { content.name }
    var subtitle: String? {
        content.shape == .full ? "\(content.upper), \(content.lower)" : content.arrowText
    }

    init(content: AirspaceTagContent, coordinate: CLLocationCoordinate2D) {
        self.content = content
        self.coordinate = coordinate
    }
}
