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

/// The route builder's route on `AeroMapView`: the numbered pins, the magenta line over its black casing, the
/// selected leg's halo, and the press-and-hold editing (move a waypoint, insert on a leg, add on empty map). Its
/// own object, as `VFRMapLayer` is, so the map draws it beside everything else and holds still while a finger drags
/// it. Until 6.7.0 the builder had a map of its own (`RouteBuilderMapView`). (flight-plan revamp #3, 6.7.0)
@MainActor
final class PlannedRouteLayer: NSObject, UIGestureRecognizerDelegate {
    /// The route as the map's last update had it; drag hit-testing reads its waypoints and closures.
    var route = PlannedRoute()
    private var lastRouteSignature = ""
    private var lastSelectedLegKey = ""
    private weak var longPress: UILongPressGestureRecognizer?

    // MARK: Live drag (flight-plan revamp #3)
    enum DragMode { case move(Int); case insert(Int); case append } // insert(afterIndex)
    private var dragMode: DragMode?
    private var dragCoords: [CLLocationCoordinate2D] = []       // working geometry during a drag
    private var dragIndex = 0                                   // index into dragCoords being moved
    private var dragAnnotation: RouteWaypointAnnotation?        // the marker following the finger
    private var dragCreatedTempAnnotation = false               // true for insert/append (remove on end)
    /// A finger has the route: the map leaves it alone until release.
    var isDragging: Bool { dragMode != nil }

    // Deferred add: a press on empty map only becomes a new waypoint after a longer, deliberate
    // hold (so a normal press/pan never adds one). (tap-add feedback)
    private var pendingAddWork: DispatchWorkItem?
    private var pendingAddAnchor: CGPoint?

    /// Draws `route` (`self.route`, set by the map's update) on `mapView`; nothing while it is the one drawn.
    func sync(on mapView: MKMapView) {
        installEditing(on: mapView)
        guard !isDragging else { return }   // never fight an in-progress live drag
        updateRoute(mapView)
        updateSelectedLeg(mapView)
    }

    // MARK: Drawing

    private func updateRoute(_ mapView: MKMapView) {
        let waypoints = route.waypoints
        let signature = Self.signature(of: waypoints) + "#" + route.conflictLegs.sorted().map(String.init).joined(separator: ",")
        guard signature != lastRouteSignature else { return }
        lastRouteSignature = signature
        lastSelectedLegKey = ""   // the leg halo is rebuilt below with the route

        // Replace numbered waypoint annotations.
        let oldWaypoints = mapView.annotations.compactMap { $0 as? RouteWaypointAnnotation }
        mapView.removeAnnotations(oldWaypoints)
        for (index, waypoint) in waypoints.enumerated() {
            let annotation = RouteWaypointAnnotation(coordinate: waypoint.coordinate, index: index, name: waypoint.name)
            annotation.hasConflict = route.conflictLegs.contains(index)
            mapView.addAnnotation(annotation)
        }

        // Replace the route polyline. Draw a black casing under a magenta core, matching the in-flight
        // navigation map so the plan previews exactly how the route reads in flight, and so it stays
        // visible on every tile layer (feedback #6 — gold washed out on some charts).
        Self.removeRouteOverlays(from: mapView)
        Self.addRouteLines(waypoints.map { $0.coordinate }, to: mapView)
    }

    private static func signature(of waypoints: [FlightPlanWaypoint]) -> String {
        waypoints.map { "\($0.id.uuidString)\($0.latitude),\($0.longitude)" }.joined(separator: "|")
    }

    private static func addRouteLines(_ coords: [CLLocationCoordinate2D], to mapView: MKMapView) {
        guard coords.count >= 2 else { return }
        mapView.addOverlay(RouteCasingPolyline(coordinates: coords, count: coords.count), level: .aboveLabels)
        mapView.addOverlay(RouteLinePolyline(coordinates: coords, count: coords.count), level: .aboveLabels)
    }

    /// The route's own lines: its core, its casing and the selected leg's halo. The three redraws take
    /// off only these; they used to take off every `MKPolyline`, which would have taken the traffic
    /// circuits and VFR routes with them. (6.2.0)
    static func isRouteOverlay(_ overlay: MKOverlay) -> Bool {
        overlay is RouteLinePolyline || overlay is RouteCasingPolyline || overlay is SelectedLegPolyline
    }

    static func removeRouteOverlays(from mapView: MKMapView) {
        let route = mapView.overlays.filter(isRouteOverlay)
        if !route.isEmpty { mapView.removeOverlays(route) }
    }

    /// A white halo under the selected leg, drawn below the route so the magenta line reads through
    /// it: the leg is highlighted where it is. (planning proposal D3)
    private func updateSelectedLeg(_ mapView: MKMapView) {
        let waypoints = route.waypoints
        let key = route.selectedLeg.map { "\($0)|\(waypoints.count)" } ?? "none"
        guard key != lastSelectedLegKey else { return }
        lastSelectedLegKey = key
        mapView.removeOverlays(mapView.overlays.filter { $0 is SelectedLegPolyline })
        guard let leg = route.selectedLeg, leg >= 0, leg + 1 < waypoints.count else { return }
        let coords = [waypoints[leg].coordinate, waypoints[leg + 1].coordinate]
        let halo = SelectedLegPolyline(coordinates: coords, count: 2)
        // Right under the route's casing: above the chart tiles (which share the level), under the line.
        if let casing = mapView.overlays.first(where: { $0 is RouteCasingPolyline }) {
            mapView.insertOverlay(halo, below: casing)
        } else {
            mapView.addOverlay(halo, level: .aboveLabels)
        }
    }

    /// The route's lines as this layer draws them, bottom first: the selected leg's halo, the casing, the core. The
    /// MapLibre view draws these. (6.8.0)
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

    /// A waypoint's numbered pin; nil for any other annotation.
    static func annotationView(for annotation: MKAnnotation, on mapView: MKMapView) -> MKAnnotationView? {
        guard let waypoint = annotation as? RouteWaypointAnnotation else { return nil }
        let id = "RouteWaypoint"
        let view: MKMarkerAnnotationView
        if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView {
            reused.annotation = annotation
            view = reused
        } else {
            view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
        }
        // Navigation magenta; amber where the leg from this waypoint has a conflict. (D2)
        view.markerTintColor = waypoint.hasConflict
            ? UIColor(red: 1.0, green: 0.75, blue: 0.0, alpha: 1)
            : UIColor(red: 1.0, green: 0.0, blue: 0.8, alpha: 1)
        view.glyphText = "\(waypoint.index + 1)"
        view.titleVisibility = .adaptive
        view.displayPriority = .required
        view.canShowCallout = true
        return view
    }

    /// A tap on a waypoint's pin selects it in the table too; true when it was one. (planning proposal D3)
    func didSelect(_ annotation: MKAnnotation) -> Bool {
        guard let waypoint = annotation as? RouteWaypointAnnotation else { return false }
        route.onSelectWaypoint?(waypoint.index)
        return true
    }

    // MARK: The callout's "+"

    /// The callout's "+": the route adds the point. Planning only: nil without `onPointAdd`.
    func addButton(for annotation: MKAnnotation) -> UIView? {
        guard route.onPointAdd != nil, Self.routePoint(for: annotation) != nil else { return nil }
        let button = AddToRouteButton(type: .contactAdd)
        button.accessibilityLabel = L10n.Nav.addToRoute
        return button
    }

    /// Whether the route being planned takes this marker's point: an aerodrome card's "+ Route". (6.7.0)
    func canAdd(_ annotation: MKAnnotation) -> Bool {
        route.onPointAdd != nil && Self.routePoint(for: annotation) != nil
    }

    /// Adds the marker's point to the route being planned.
    func add(_ annotation: MKAnnotation) {
        guard let point = Self.routePoint(for: annotation) else { return }
        route.onPointAdd?(point)
    }

    /// Adds the callout's point when `control` is its "+" (a navaid's, a reporting point's); true when it was.
    func addPoint(for control: UIControl, of view: MKAnnotationView, on mapView: MKMapView) -> Bool {
        guard control is AddToRouteButton, let point = Self.routePoint(for: view.annotation) else { return false }
        route.onPointAdd?(point)
        mapView.deselectAnnotation(view.annotation, animated: true)
        return true
    }

    static func routePoint(for annotation: MKAnnotation?) -> RoutePoint? {
        switch annotation {
        case let airport as AirportAnnotation: return .aerodrome(airport.airport)
        case let navaid as NavaidAnnotation: return .navaid(navaid.navaid)
        case let point as ReportingPointAnnotation: return .reportingPoint(point.point, point.label)
        default: return nil
        }
    }

    // MARK: Live drag handling (flight-plan revamp #3 + deliberate add)

    /// One press-and-hold gesture drives ALL route editing: grab a waypoint to move it, grab the
    /// route line to insert mid-route (both at the short grab threshold for a responsive feel), or
    /// hold longer on empty map to drop a new waypoint. A plain tap adds nothing, so you can
    /// pan/zoom/inspect without accidentally creating waypoints. Only on a route that can be edited.
    private func installEditing(on mapView: MKMapView) {
        guard longPress == nil, route.isEditable else { return }
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        recognizer.minimumPressDuration = 0.2
        recognizer.delegate = self
        mapView.addGestureRecognizer(recognizer)
        longPress = recognizer
    }

    @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let mapView = gesture.view as? MKMapView else { return }
        let point = gesture.location(in: mapView)
        switch gesture.state {
        case .began:
            beginDrag(mapView, at: point)                 // move / insert on a waypoint or the line
            if dragMode == nil { schedulePendingAdd(mapView, at: point) } // empty → deferred add
        case .changed:
            if dragMode == nil {
                // Still before the deliberate-add threshold; movement here means the user is panning.
                if let anchor = pendingAddAnchor, hypot(point.x - anchor.x, point.y - anchor.y) > 16 {
                    cancelPendingAdd()
                }
                return
            }
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            if case .append = dragMode {
                // A dropped point previews where it will actually land (cheapest insertion),
                // recomputed as the finger moves — not stuck appended to the end. (smart-insert feedback)
                rebuildAppendPreview(mapView, coord: coord)
                return
            }
            guard dragIndex < dragCoords.count else { return }
            dragCoords[dragIndex] = coord
            dragAnnotation?.coordinate = coord
            redrawDragRoute(mapView)
        case .ended:
            if dragMode == nil { cancelPendingAdd(); return } // released before the add threshold
            endDrag(mapView, at: point)
        case .cancelled, .failed:
            cancelPendingAdd()
            cancelDrag(mapView)
        default:
            break
        }
    }

    /// Arm a deferred add: after a longer hold on empty map (without panning), drop a new waypoint
    /// under the finger and let the user drag it before release. (tap-add feedback)
    private func schedulePendingAdd(_ mapView: MKMapView, at point: CGPoint) {
        guard route.onAddWaypoint != nil else { return }
        cancelPendingAdd()
        pendingAddAnchor = point
        let work = DispatchWorkItem { [weak self, weak mapView] in
            guard let self, let mapView, self.pendingAddAnchor != nil, self.dragMode == nil else { return }
            self.startAppendDrag(mapView, at: point)
        }
        pendingAddWork = work
        // ~0.2 s recognizer threshold + 0.45 s ≈ a deliberate two-thirds-second hold before it adds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func cancelPendingAdd() {
        pendingAddWork?.cancel()
        pendingAddWork = nil
        pendingAddAnchor = nil
    }

    private func startAppendDrag(_ mapView: MKMapView, at point: CGPoint) {
        pendingAddWork = nil
        pendingAddAnchor = nil
        let coord = mapView.convert(point, toCoordinateFrom: mapView)
        dragMode = .append
        let temp = RouteWaypointAnnotation(coordinate: coord, index: 0, name: "")
        mapView.addAnnotation(temp)
        dragAnnotation = temp
        dragCreatedTempAnnotation = true
        grabbed(mapView, deselect: nil)
        rebuildAppendPreview(mapView, coord: coord) // place it at the cheapest-insertion position
    }

    /// Rebuild the live preview for a dropped point: splice it into the route at the cheapest
    /// insertion index for its current position, so the line shows how it will actually link in.
    private func rebuildAppendPreview(_ mapView: MKMapView, coord: CLLocationCoordinate2D) {
        let idx = FlightPlanManager.bestInsertionIndex(for: coord, in: route.waypoints)
        var coords = route.waypoints.map { $0.coordinate }
        let at = min(idx, coords.count)
        coords.insert(coord, at: at)
        dragCoords = coords
        dragIndex = at
        dragAnnotation?.coordinate = coord
        redrawDragRoute(mapView)
    }

    /// Grab a waypoint (move) if the press is on one, else the nearest route segment (insert).
    private func beginDrag(_ mapView: MKMapView, at point: CGPoint) {
        let wpts = route.waypoints
        guard !wpts.isEmpty else { return }
        if route.onMoveWaypoint != nil,
           let idx = waypointIndex(near: point, mapView: mapView, maxPointDistance: 34),
           let anno = routeAnnotation(at: idx, in: mapView) {
            dragMode = .move(idx)
            dragCoords = wpts.map { $0.coordinate }
            dragIndex = idx
            dragAnnotation = anno
            dragCreatedTempAnnotation = false
            grabbed(mapView, deselect: anno)
            return
        }
        if route.onInsertWaypoint != nil, wpts.count >= 2,
           let seg = closestSegment(to: point, mapView: mapView, maxPointDistance: 22) {
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            let insertAt = seg + 1
            dragMode = .insert(seg)
            dragCoords = wpts.map { $0.coordinate }
            dragCoords.insert(coord, at: insertAt)
            dragIndex = insertAt
            let temp = RouteWaypointAnnotation(coordinate: coord, index: insertAt, name: "")
            mapView.addAnnotation(temp)
            dragAnnotation = temp
            dragCreatedTempAnnotation = true
            grabbed(mapView, deselect: nil)
            redrawDragRoute(mapView)
        }
    }

    private func grabbed(_ mapView: MKMapView, deselect: MKAnnotation?) {
        mapView.isScrollEnabled = false
        if let deselect = deselect { mapView.deselectAnnotation(deselect, animated: false) }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func endDrag(_ mapView: MKMapView, at point: CGPoint) {
        guard let mode = dragMode else { return }
        let finalCoord = mapView.convert(point, toCoordinateFrom: mapView)
        if dragCreatedTempAnnotation, let temp = dragAnnotation { mapView.removeAnnotation(temp) }
        finishDrag(mapView)
        switch mode {
        case .move(let index): route.onMoveWaypoint?(index, finalCoord)
        case .insert(let afterIndex): route.onInsertWaypoint?(afterIndex, finalCoord)
        case .append: route.onAddWaypoint?(finalCoord)
        }
    }

    private func cancelDrag(_ mapView: MKMapView) {
        finishDrag(mapView)
        // Rebuilds markers + line from the model, dropping any temp insert/append marker and
        // resetting a moved marker to its committed position.
        redrawCommittedRoute(mapView)
    }

    private func finishDrag(_ mapView: MKMapView) {
        dragMode = nil
        dragAnnotation = nil
        dragCoords = []
        dragCreatedTempAnnotation = false
        mapView.isScrollEnabled = true
    }

    /// Redraw the magenta route from the live working geometry (move/insert preview).
    private func redrawDragRoute(_ mapView: MKMapView) {
        Self.removeRouteOverlays(from: mapView)
        Self.addRouteLines(dragCoords, to: mapView)
    }

    /// Rebuild markers + route from the committed model (used after a cancelled drag).
    private func redrawCommittedRoute(_ mapView: MKMapView) {
        lastRouteSignature = ""
        lastSelectedLegKey = ""
        let old = mapView.annotations.compactMap { $0 as? RouteWaypointAnnotation }
        mapView.removeAnnotations(old)
        updateRoute(mapView)
        updateSelectedLeg(mapView)
    }

    // MARK: Drag hit-testing

    /// Index of the waypoint whose marker is closest to `point` (within `maxPointDistance` px), or nil.
    private func waypointIndex(near point: CGPoint, mapView: MKMapView, maxPointDistance: CGFloat) -> Int? {
        var best: (index: Int, dist: CGFloat)?
        for (i, w) in route.waypoints.enumerated() {
            let p = mapView.convert(w.coordinate, toPointTo: mapView)
            // The marker balloon sits above its coordinate tip — bias the hit centre up.
            let centre = CGPoint(x: p.x, y: p.y - 14)
            let d = hypot(point.x - centre.x, point.y - centre.y)
            if best == nil || d < best!.dist { best = (i, d) }
        }
        if let best = best, best.dist <= maxPointDistance { return best.index }
        return nil
    }

    private func routeAnnotation(at index: Int, in mapView: MKMapView) -> RouteWaypointAnnotation? {
        mapView.annotations.compactMap { $0 as? RouteWaypointAnnotation }.first { $0.index == index }
    }

    /// Start index of the route segment closest to `point` (within `maxPointDistance` px), or nil.
    private func closestSegment(to point: CGPoint, mapView: MKMapView, maxPointDistance: CGFloat) -> Int? {
        let wpts = route.waypoints
        guard wpts.count >= 2 else { return nil }
        var best: (index: Int, dist: CGFloat)?
        for i in 0..<(wpts.count - 1) {
            let a = mapView.convert(wpts[i].coordinate, toPointTo: mapView)
            let b = mapView.convert(wpts[i + 1].coordinate, toPointTo: mapView)
            let d = distance(from: point, toSegment: a, b)
            if best == nil || d < best!.dist { best = (i, d) }
        }
        if let best = best, best.dist <= maxPointDistance { return best.index }
        return nil
    }

    private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let ap = CGPoint(x: p.x - a.x, y: p.y - a.y)
        let len2 = ab.x * ab.x + ab.y * ab.y
        let t = len2 == 0 ? 0 : max(0, min(1, (ap.x * ab.x + ap.y * ab.y) / len2))
        let proj = CGPoint(x: a.x + t * ab.x, y: a.y + t * ab.y)
        return hypot(p.x - proj.x, p.y - proj.y)
    }

    // Let the press coexist with the map's own pan/zoom recognizers.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// A callout's "+", told apart from the official chart and Divert. (6.7.0)
final class AddToRouteButton: UIButton {}

// MARK: - Route overlays

/// Black casing drawn underneath the magenta route core (a distinct subclass so the renderer can tell
/// the two `MKPolyline`s apart). Mirrors the in-flight navigation map's route styling.
final class RouteCasingPolyline: MKPolyline {}
/// The route's magenta core. Its own class, so the redraws take off the route and nothing else on the
/// map that is a polyline (the traffic circuits and VFR routes). (6.2.0)
final class RouteLinePolyline: MKPolyline {}
/// The halo under the leg selected in the route editor. (planning proposal D3)
final class SelectedLegPolyline: MKPolyline {}

// MARK: - Route waypoint annotation

/// A numbered route waypoint marker. `coordinate` is KVO-observable so MapKit can move it in place.
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
