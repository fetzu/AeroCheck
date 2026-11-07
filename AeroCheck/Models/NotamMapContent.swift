import CoreLocation
import Foundation

// MARK: - The map

/// What the NOTAM areas layer draws. Pure: the NOTAMs on the device and a moment in, what goes on the map out.
enum NotamMapContent {
    /// Beyond this a NOTAM means a region, and a circle on the chart would say more than it knows.
    static let maxRadiusNm = 50.0
    /// A chart stays a chart: the nearest to the map's middle.
    static let maxShown = 40

    struct Item: Equatable, Hashable, Identifiable {
        enum Shape: Equatable, Hashable { case area(radiusNm: Double), obstacle }

        let notam: Notam
        let shape: Shape
        let latitude: Double
        let longitude: Double

        var id: String { notam.id }
        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    }

    /// The item a NOTAM makes when it applies between the two dates: a circle for an airspace NOTAM of at most 50 NM, a
    /// marker for an obstacle, nothing for the rest, which stay in the list.
    static func item(_ notam: Notam, from: Date, to: Date) -> Item? {
        guard notam.overlaps(from: from, to: to), let centre = notam.coordinate else { return nil }
        switch notam.kind {
        case .airspace:
            guard let radius = notam.radiusNm, radius > 0, radius <= maxRadiusNm else { return nil }
            return Item(notam: notam, shape: .area(radiusNm: radius), latitude: centre.latitude, longitude: centre.longitude)
        case .obstacle:
            return Item(notam: notam, shape: .obstacle, latitude: centre.latitude, longitude: centre.longitude)
        default:
            return nil
        }
    }

    /// What to draw of `notams` in a box around `centre`, the nearest first.
    static func items(_ notams: [Notam], from: Date, to: Date, centre: CLLocationCoordinate2D, latSpan: Double, lonSpan: Double) -> [Item] {
        let halfLat = latSpan / 2 + 1, halfLon = lonSpan / 2 + 1.5
        var seen = Set<String>()
        // A repeated NOTAM is one circle, not five on top of each other.
        let found = notams.filter { seen.insert($0.sameNotamKey).inserted }.compactMap { notam -> Item? in
            guard let item = item(notam, from: from, to: to), abs(item.latitude - centre.latitude) <= halfLat,
                  abs(item.longitude - centre.longitude) <= halfLon else { return nil }
            return item
        }
        return Array(found.sorted { NotamGeometry.distanceNm($0.coordinate, centre) < NotamGeometry.distanceNm($1.coordinate, centre) }
            .prefix(maxShown))
    }

    /// The circle as a closed ring, for the line and the tag's place.
    static func ring(centre: CLLocationCoordinate2D, radiusNm: Double, points: Int = 72) -> [CLLocationCoordinate2D] {
        let cosLat = max(cos(centre.latitude * .pi / 180), 0.01)
        return (0...points).map { step in
            let angle = Double(step) / Double(points) * 2 * .pi
            return CLLocationCoordinate2D(latitude: centre.latitude + radiusNm / 60 * cos(angle),
                                          longitude: centre.longitude + radiusNm / (60 * cosLat) * sin(angle))
        }
    }

    /// What a tap at `point` falls on: an edge within `toleranceNm`, and with `insideToo` the areas it is inside.
    static func hits(_ items: [Item], at point: CLLocationCoordinate2D, toleranceNm: Double, insideToo: Bool) -> [Notam] {
        items.filter { item in
            let distance = NotamGeometry.distanceNm(item.coordinate, point)
            switch item.shape {
            case .area(let radius):
                return insideToo ? distance <= radius + toleranceNm : abs(distance - radius) <= toleranceNm
            case .obstacle:
                return distance <= toleranceNm
            }
        }.map(\.notam)
    }
}
