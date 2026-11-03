import MapKit
import UIKit

// MARK: - The planned route on a map (6.7.0)

/// The route being planned, as the route builder hands it to `AeroMapView`: its waypoints, the leg selected in the
/// table or the profile, the legs with a conflict, and what an edit on the map does. A closure left nil turns that
/// edit off.
struct PlannedRoute {
    var waypoints: [FlightPlanWaypoint] = []
    /// The leg selected in the table or the profile (from waypoint n to n+1): haloed on the map.
    /// (planning proposal D3)
    var selectedLeg: Int?
    /// Waypoints whose leg has a conflict: their pins turn amber. (planning proposal D2)
    var conflictLegs: Set<Int> = []
    /// A tap on a waypoint's pin selects it, and its row in the table. (planning proposal D3)
    var onSelectWaypoint: ((Int) -> Void)?
    /// Live drag committed a waypoint move (index, new coordinate). (#3)
    var onMoveWaypoint: ((Int, CLLocationCoordinate2D) -> Void)?
    /// Live drag committed a mid-route insert (afterIndex, coordinate). (#3)
    var onInsertWaypoint: ((Int, CLLocationCoordinate2D) -> Void)?
    /// Deliberate press-and-hold on empty map appended a new waypoint (coordinate). (tap-add feedback)
    var onAddWaypoint: ((CLLocationCoordinate2D) -> Void)?
    /// "+" in an aerodrome's, navaid's or reporting point's callout. (6.0.1)
    var onPointAdd: ((RoutePoint) -> Void)?

    var isEditable: Bool { onMoveWaypoint != nil || onInsertWaypoint != nil || onAddWaypoint != nil }

    /// Only what draws: no edit.
    var drawnOnly: PlannedRoute {
        PlannedRoute(waypoints: waypoints, selectedLeg: selectedLeg, conflictLegs: conflictLegs)
    }
}

/// The route builder's route on `AeroMapView`: the route as the map's last update had it, what a tap on a pin or a
/// callout's "+" does with it, and the geometry its drawing and editing share. MapLibre draws it and edits it
/// (`PilotMapShapes`, `PilotMapMarkers`, `PilotRouteEditing`). Until 6.7.0 the builder had a map of its own
/// (`RouteBuilderMapView`). (flight-plan revamp #3, 6.7.0; 6.8.0)
@MainActor
final class PlannedRouteLayer: NSObject {
    /// The route as the map's last update had it; the callouts' "+" and the pins' selection read its closures.
    var route = PlannedRoute()

    /// The route's lines, bottom first: the selected leg's halo, the casing, the core. The MapLibre view draws these.
    /// (6.8.0)
    static func lines(for route: PlannedRoute) -> [MKPolyline] {
        let coords = route.waypoints.map(\.coordinate)
        guard coords.count >= 2 else { return [] }
        var lines: [MKPolyline] = []
        if let leg = route.selectedLeg, leg >= 0, leg + 1 < coords.count {
            lines.append(SelectedLegPolyline(coordinates: [coords[leg], coords[leg + 1]], count: 2))
        }
        lines.append(RouteCasingPolyline(coordinates: coords, count: coords.count))
        lines.append(RouteLinePolyline(coordinates: coords, count: coords.count))
        return lines
    }

    /// The halo, the casing and the core; nil for any other overlay.
    static func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        // The selected leg's halo, under the route. (planning proposal D3)
        if let halo = overlay as? SelectedLegPolyline {
            let renderer = MKPolylineRenderer(polyline: halo)
            renderer.strokeColor = UIColor.white.withAlphaComponent(0.85)
            renderer.lineWidth = 16
            renderer.lineCap = .round
            return renderer
        }
        if let casing = overlay as? RouteCasingPolyline {
            let renderer = MKPolylineRenderer(polyline: casing)
            renderer.strokeColor = UIColor.black.withAlphaComponent(0.5)
            renderer.lineWidth = 7
            renderer.lineJoin = .round
            renderer.lineCap = .round
            return renderer
        }
        if let core = overlay as? RouteLinePolyline {
            let renderer = MKPolylineRenderer(polyline: core)
            renderer.strokeColor = UIColor(red: 1.0, green: 0.0, blue: 0.8, alpha: 1.0) // navigation magenta
            renderer.lineWidth = 4
            renderer.lineJoin = .round
            renderer.lineCap = .round
            return renderer
        }
        return nil
    }

    /// A tap on a waypoint's pin selects it in the table too; true when it was one. (planning proposal D3)
    func didSelect(_ annotation: MKAnnotation) -> Bool {
        guard let waypoint = annotation as? RouteWaypointAnnotation else { return false }
        route.onSelectWaypoint?(waypoint.index)
        return true
    }

    // MARK: The callout's "+"

    /// Whether the route being planned takes this marker's point: an aerodrome card's "+ Route". (6.7.0)
    func canAdd(_ annotation: MKAnnotation) -> Bool {
        route.onPointAdd != nil && Self.routePoint(for: annotation) != nil
    }

    /// Adds the marker's point to the route being planned.
    func add(_ annotation: MKAnnotation) {
        guard let point = Self.routePoint(for: annotation) else { return }
        route.onPointAdd?(point)
    }

    static func routePoint(for annotation: MKAnnotation?) -> RoutePoint? {
        switch annotation {
        case let airport as AirportAnnotation: return .aerodrome(airport.airport)
        case let navaid as NavaidAnnotation: return .navaid(navaid.navaid)
        case let point as ReportingPointAnnotation: return .reportingPoint(point.point, point.label)
        default: return nil
        }
    }

    // MARK: Hit-testing

    /// Of `points` (the waypoints on screen), the one whose balloon is closest to `point`, within `maxPointDistance`.
    /// The builder's press-and-hold editing hit-tests with this (`PilotRouteEditing`). (6.8.0)
    static func waypointIndex(near point: CGPoint, points: [CGPoint], maxPointDistance: CGFloat) -> Int? {
        var best: (index: Int, dist: CGFloat)?
        for (i, p) in points.enumerated() {
            // The marker balloon sits above its coordinate tip — bias the hit centre up.
            let centre = CGPoint(x: p.x, y: p.y - 14)
            let d = hypot(point.x - centre.x, point.y - centre.y)
            if best == nil || d < best!.dist { best = (i, d) }
        }
        if let best = best, best.dist <= maxPointDistance { return best.index }
        return nil
    }

    /// Of the route through `points`, the start of the leg closest to `point`, within `maxPointDistance`. (6.8.0)
    static func closestSegment(to point: CGPoint, points: [CGPoint], maxPointDistance: CGFloat) -> Int? {
        guard points.count >= 2 else { return nil }
        var best: (index: Int, dist: CGFloat)?
        for i in 0..<(points.count - 1) {
            let d = distance(from: point, toSegment: points[i], points[i + 1])
            if best == nil || d < best!.dist { best = (i, d) }
        }
        if let best = best, best.dist <= maxPointDistance { return best.index }
        return nil
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let ap = CGPoint(x: p.x - a.x, y: p.y - a.y)
        let len2 = ab.x * ab.x + ab.y * ab.y
        let t = len2 == 0 ? 0 : max(0, min(1, (ap.x * ab.x + ap.y * ab.y) / len2))
        let proj = CGPoint(x: a.x + t * ab.x, y: a.y + t * ab.y)
        return hypot(p.x - proj.x, p.y - proj.y)
    }
}

/// A callout's "+", told apart from the official chart and Divert. (6.7.0)
final class AddToRouteButton: UIButton {}

// MARK: - Route overlays

/// Black casing drawn underneath the magenta route core (a distinct subclass so the renderer can tell
/// the two `MKPolyline`s apart). Mirrors the in-flight navigation map's route styling.
final class RouteCasingPolyline: MKPolyline {}
/// The route's magenta core. Its own class, so the renderer tells it from the other polylines on the map (the
/// traffic circuits and VFR routes). (6.2.0)
final class RouteLinePolyline: MKPolyline {}
/// The halo under the leg selected in the route editor. (planning proposal D3)
final class SelectedLegPolyline: MKPolyline {}

// MARK: - Route waypoint annotation

/// A numbered route waypoint marker. `coordinate` is KVO-observable so the map can move it in place.
final class RouteWaypointAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    let index: Int
    let title: String?
    /// The leg from this waypoint has a conflict: the pin is amber. (planning proposal D2)
    var hasConflict = false

    init(coordinate: CLLocationCoordinate2D, index: Int, name: String) {
        self.coordinate = coordinate
        self.index = index
        self.title = name.isEmpty ? "WPT\(index + 1)" : name
    }
}

// MARK: - A crossed airspace's look

extension AirspacePolygon {
    /// Translucent fill and coloured stroke, brighter and thicker when selected (a conflict tapped in the route
    /// builder's list). One look on every map since 6.7.0. (#4)
    func style(_ renderer: MKPolygonRenderer, selected: Bool) {
        let c = overlayColor
        renderer.fillColor = UIColor(red: c.red, green: c.green, blue: c.blue, alpha: selected ? 0.36 : 0.15)
        renderer.strokeColor = UIColor(red: c.red, green: c.green, blue: c.blue, alpha: selected ? 1.0 : 0.8)
        renderer.lineWidth = selected ? 3 : 1.5
        renderer.lineDashPattern = isDashed ? [8, 4] : nil
    }
}
