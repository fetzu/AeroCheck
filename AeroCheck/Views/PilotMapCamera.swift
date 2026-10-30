import MapKit
import MapLibre
import UIKit

// MARK: - The camera on MapLibre (6.8.0)

/// The camera moves the MapKit view makes besides following the shared state (`PilotMapView.applyCamera`): the legs
/// panel's band and a search's aerodrome. (The plan's PR 8.)
///
/// MapLibre counts zoom as a scale, whatever the map's size: `zoomLevel` z is 2^(19 - z) map points per screen point
/// (`MKMapPoint`'s world is 2^28 points wide, MapLibre's 512 · 2^z). So the band keeps the pilot's zoom level and
/// frames at it, with none of `LegsBandDriver`'s measuring of a camera distance against the map's height.
enum PilotMapZoom {
    /// Map points per screen point at MapLibre zoom `z`.
    static func scale(atZoom z: Double) -> Double { pow(2, 19 - z) }

    /// MapLibre's zoom for `scale` map points per screen point.
    static func zoom(forScale scale: Double) -> Double { 19 - log2(max(scale, 1e-9)) }
}

/// The legs panel's band on MapLibre, as `LegsBandDriver` on MapKit: while the panel is open the band has the camera,
/// framing the aircraft and the next waypoint (`LegsPanelMap.place`) on every update; the map takes no gesture and
/// no marker tap; the shared state keeps the pilot's map, put back when the panel closes.
@MainActor
final class PilotLegsBand {
    private(set) var ownsCamera = false
    private var isOpen = false
    private var framing: LegsPanelMap.Framing?
    private var framedWaypoint: CLLocationCoordinate2D?
    /// The last camera set: centre, zoom, heading.
    private var last: (center: CLLocationCoordinate2D, zoom: Double, heading: Double)?
    /// The pilot's zoom with the panel closed, the one the band frames at.
    private var pilotZoom: Double?
    private var generation = 0

    nonisolated init() {}

    /// The map came to rest with the band not holding the camera: the pilot's zoom, in the shared state too (a map
    /// made with the panel open reads it there).
    func mapCameToRest(_ mapView: MLNMapView, mapState: SharedMapState) {
        guard !ownsCamera, mapView.bounds.height > 1 else { return }
        pilotZoom = mapView.zoomLevel
        let scale = PilotMapZoom.scale(atZoom: mapView.zoomLevel)
        mapState.bandPilotZoom = (scale, scale / max(mapView.camera.altitude, 1), mapView.bounds.height)
    }

    /// One update pass. True while the band has the camera.
    func update(_ mapView: MLNMapView, band: LegsPanelMap.Band?, mapState: SharedMapState) -> Bool {
        guard let band else {
            if isOpen { close(mapView, mapState: mapState) }
            return ownsCamera
        }
        if !isOpen { open(mapView, mapState: mapState) }
        frame(mapView, band: band)
        return true
    }

    private func open(_ mapView: MLNMapView, mapState: SharedMapState) {
        if pilotZoom == nil, let kept = mapState.bandPilotZoom { pilotZoom = PilotMapZoom.zoom(forScale: kept.scale) }
        if pilotZoom == nil { pilotZoom = mapView.zoomLevel }
        isOpen = true
        ownsCamera = true
        generation += 1
        framing = nil
        framedWaypoint = nil
        last = nil
        mapView.isScrollEnabled = false
        mapView.isZoomEnabled = false
        mapView.isRotateEnabled = false
        for annotation in mapView.selectedAnnotations { mapView.deselectAnnotation(annotation, animated: false) }
        mapView.accessibilityElementsHidden = true
    }

    private func frame(_ mapView: MLNMapView, band: LegsPanelMap.Band) {
        guard let rect = band.rect, band.viewSize.height > 0, let pilotZoom else { return }
        if band.waypoint?.latitude != framedWaypoint?.latitude || band.waypoint?.longitude != framedWaypoint?.longitude {
            framing = nil
            framedWaypoint = band.waypoint
        }
        let scale = PilotMapZoom.scale(atZoom: pilotZoom)
        // MapLibre centres the camera in the view less its content inset.
        let inset = mapView.contentInset
        let cameraPoint = CGPoint(x: inset.left + (band.viewSize.width - inset.left - inset.right) / 2,
                                  y: inset.top + (band.viewSize.height - inset.top - inset.bottom) / 2)
        let placement: LegsPanelMap.Placement
        if let start = band.legStart, let end = band.waypoint {
            placement = LegsPanelMap.placeLeg(from: MKMapPoint(start), to: MKMapPoint(end), heading: band.heading,
                                              band: rect, viewSize: band.viewSize, cameraPoint: cameraPoint, scale: scale)
        } else {
            guard let aircraft = band.aircraft, CLLocationCoordinate2DIsValid(aircraft) else { return }
            placement = LegsPanelMap.place(aircraft: MKMapPoint(aircraft), waypoint: band.waypoint.map(MKMapPoint.init),
                                           heading: band.heading, band: rect, viewSize: band.viewSize,
                                           cameraPoint: cameraPoint, scale: scale, previous: framing)
        }
        framing = placement.framing
        let zoom = PilotMapZoom.zoom(forScale: scale * placement.zoomOut)
        let center = placement.center.coordinate
        if let last, Self.isSame(last, (center, zoom, band.heading), scale: scale * placement.zoomOut) { return }
        last = (center, zoom, band.heading)
        mapView.setCenter(center, zoomLevel: zoom, direction: band.heading, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func close(_ mapView: MLNMapView, mapState: SharedMapState) {
        isOpen = false
        generation += 1
        let closing = generation
        mapView.isScrollEnabled = true
        mapView.isZoomEnabled = true
        mapView.isRotateEnabled = true
        mapView.accessibilityElementsHidden = false
        // Back to the pilot's map once the view has its size back (the panel closing grows it in portrait): the
        // centre the shared state holds (NavigationMapView writes where the map returns to), at the pilot's zoom,
        // which is a scale and so the same whatever the height.
        DispatchQueue.main.async { [weak self, weak mapView] in
            guard let self, let mapView, self.generation == closing else { return }
            let zoom = self.pilotZoom ?? mapView.zoomLevel
            mapView.setCenter(mapState.region.center, zoomLevel: zoom, direction: mapState.cameraHeading, animated: false)
            self.ownsCamera = false
            self.last = nil
            mapState.cameraDistance = mapView.camera.altitude
            mapState.updateFromRegion(PilotMapView.Coordinator.region(of: mapView))
            mapState.endBand()
        }
    }

    /// Within half a point, half a percent of zoom and half a degree.
    static func isSame(_ a: (center: CLLocationCoordinate2D, zoom: Double, heading: Double),
                       _ b: (center: CLLocationCoordinate2D, zoom: Double, heading: Double), scale: Double) -> Bool {
        let moved = hypot(MKMapPoint(a.center).x - MKMapPoint(b.center).x, MKMapPoint(a.center).y - MKMapPoint(b.center).y) / scale
        let turned = abs(a.heading - b.heading).truncatingRemainder(dividingBy: 360)
        return moved < 0.5 && abs(a.zoom - b.zoom) < log2(1.005) && min(turned, 360 - turned) < 0.5
    }
}

extension PendingCameraMove {
    /// The search's aerodrome on MapLibre: `spanNM` across the map's narrower side, held within the chart's zoom
    /// range, keeping the heading, at once. False while the map has no size yet: left pending.
    @MainActor
    func apply(to mapView: MLNMapView) -> Bool {
        let size = mapView.bounds.size
        guard size.width > 0, size.height > 0 else { return false }
        let narrower = Double(min(size.width, size.height))
        // Metres per point for the span, as map points per point at the aerodrome's latitude.
        let metresPerPoint = spanNM * 1852 / narrower
        let scale = metresPerPoint * MKMapPointsPerMeterAtLatitude(center.latitude)
        let zoom = min(max(PilotMapZoom.zoom(forScale: scale), mapView.minimumZoomLevel), mapView.maximumZoomLevel)
        mapView.setCenter(center, zoomLevel: zoom, direction: mapView.direction, animated: false)
        return true
    }
}

// MARK: - The route builder's editing on MapLibre

/// The route builder's press-and-hold editing on MapLibre: grab a waypoint to move it, grab a leg to insert a waypoint
/// on it, hold longer on empty map to add one where it links in best. The
/// line follows the finger (`preview`); the change is committed on release through the route's closures. The map
/// holds still meanwhile.
@MainActor
final class PilotRouteEditing: NSObject, UIGestureRecognizerDelegate {
    enum Mode: Equatable { case move(Int), insert(Int), append }

    /// The route as the map's last update had it.
    var route = PlannedRoute()
    /// The working geometry while a finger has the route; nil otherwise. The shapes draw it in place of the route.
    private(set) var preview: [CLLocationCoordinate2D]?
    /// Called when the preview changes: the map redraws the route and the dragged pin.
    var onPreview: (() -> Void)?
    private(set) var mode: Mode?
    private var index = 0
    private weak var press: UILongPressGestureRecognizer?
    private var pendingAdd: DispatchWorkItem?
    private var pendingAnchor: CGPoint?
    /// The dragged pin, a marker of its own moved in place.
    let draggedPin = PilotAircraftMarker()

    nonisolated override init() { super.init() }

    var isDragging: Bool { mode != nil }

    /// The dragged pin's label: the number the waypoint has, or will have once inserted; "+" while a point added on
    /// empty map is still finding its place in the route.
    var draggedLabel: String {
        switch mode {
        case .move, .insert: return "\(index + 1)"
        case .append, nil: return "+"
        }
    }

    func install(on mapView: MLNMapView) {
        guard press == nil, route.isEditable else { return }
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
        recognizer.minimumPressDuration = 0.2
        recognizer.delegate = self
        mapView.addGestureRecognizer(recognizer)
        press = recognizer
    }

    @objc private func handle(_ gesture: UILongPressGestureRecognizer) {
        guard let mapView = gesture.view as? MLNMapView else { return }
        let point = gesture.location(in: mapView)
        switch gesture.state {
        case .began:
            begin(mapView, at: point)
            if mode == nil { scheduleAdd(mapView, at: point) }
        case .changed:
            guard mode != nil else {
                if let anchor = pendingAnchor, hypot(point.x - anchor.x, point.y - anchor.y) > 16 { cancelAdd() }
                return
            }
            move(mapView, to: mapView.convert(point, toCoordinateFrom: mapView))
        case .ended:
            guard let mode else { cancelAdd(); return }
            let final = mapView.convert(point, toCoordinateFrom: mapView)
            finish(mapView)
            switch mode {
            case .move(let i): route.onMoveWaypoint?(i, final)
            case .insert(let after): route.onInsertWaypoint?(after, final)
            case .append: route.onAddWaypoint?(final)
            }
        case .cancelled, .failed:
            cancelAdd()
            finish(mapView)
        default:
            break
        }
    }

    private func points(on mapView: MLNMapView) -> [CGPoint] {
        route.waypoints.map { mapView.convert($0.coordinate, toPointTo: mapView) }
    }

    private func begin(_ mapView: MLNMapView, at point: CGPoint) {
        let coords = route.waypoints.map(\.coordinate)
        guard !coords.isEmpty else { return }
        if route.onMoveWaypoint != nil,
           let i = PlannedRouteLayer.waypointIndex(near: point, points: points(on: mapView), maxPointDistance: 34) {
            mode = .move(i)
            index = i
            preview = coords
            grabbed(mapView, at: coords[i])
            return
        }
        if route.onInsertWaypoint != nil, coords.count >= 2,
           let leg = PlannedRouteLayer.closestSegment(to: point, points: points(on: mapView), maxPointDistance: 22) {
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            mode = .insert(leg)
            index = leg + 1
            var working = coords
            working.insert(coord, at: index)
            preview = working
            grabbed(mapView, at: coord)
        }
    }

    private func scheduleAdd(_ mapView: MLNMapView, at point: CGPoint) {
        guard route.onAddWaypoint != nil else { return }
        cancelAdd()
        pendingAnchor = point
        let work = DispatchWorkItem { [weak self, weak mapView] in
            guard let self, let mapView, self.pendingAnchor != nil, self.mode == nil else { return }
            self.pendingAdd = nil
            self.pendingAnchor = nil
            self.mode = .append
            let coord = mapView.convert(point, toCoordinateFrom: mapView)
            self.grabbed(mapView, at: coord)
            self.move(mapView, to: coord)
        }
        pendingAdd = work
        // The recognizer's 0.2 s and 0.45 s more: a deliberate two-thirds-second hold before it adds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func cancelAdd() {
        pendingAdd?.cancel()
        pendingAdd = nil
        pendingAnchor = nil
    }

    private func move(_ mapView: MLNMapView, to coord: CLLocationCoordinate2D) {
        if mode == .append {
            // Where it will land: the cheapest insertion for its position, recomputed as the finger moves.
            var coords = route.waypoints.map(\.coordinate)
            index = min(FlightPlanManager.bestInsertionIndex(for: coord, in: route.waypoints), coords.count)
            coords.insert(coord, at: index)
            preview = coords
        } else if var working = preview, index < working.count {
            working[index] = coord
            preview = working
        }
        draggedPin.coordinate = coord
        onPreview?()
    }

    private func grabbed(_ mapView: MLNMapView, at coord: CLLocationCoordinate2D) {
        mapView.isScrollEnabled = false
        for annotation in mapView.selectedAnnotations { mapView.deselectAnnotation(annotation, animated: false) }
        draggedPin.coordinate = coord
        mapView.addAnnotation(draggedPin)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onPreview?()
    }

    private func finish(_ mapView: MLNMapView) {
        mode = nil
        preview = nil
        mapView.removeAnnotation(draggedPin)
        mapView.isScrollEnabled = true
        onPreview?()
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
