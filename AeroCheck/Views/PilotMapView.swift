import MapKit
import MapLibre
import SwiftUI

// MARK: - The engine

/// Which engine draws the maps while 6.8.0 moves them to MapLibre: MapKit until the stack's last PR takes it out.
/// Settings › About › Developer options switches it; a DEBUG launch can force it (`AEROCHECK_MAP_ENGINE=maplibre`).
// MARK: - The style

/// The pilot's map's style (AeroCheck-maps `build/style.py`; the app ships a copy), its tile and glyph addresses
/// filled in with the ones `PilotTileURLProtocol` answers, and the outline's names in the app's language. (6.8.0)
enum PilotMapStyle {
    /// Written once per launch beside the app's caches, for MapLibre to load as a file.
    static let url: URL? = {
        guard let bundled = Bundle.main.url(forResource: "pilot-day", withExtension: "json", subdirectory: "PilotMapStyle"),
              let text = try? String(contentsOf: bundled, encoding: .utf8) else { return nil }
        let filled = text
            .replacingOccurrences(of: "{{MAP_TILES}}", with: PilotMapConfig.mapTileTemplate)
            .replacingOccurrences(of: "{{RELIEF_TILES}}", with: PilotMapConfig.reliefTileTemplate)
            .replacingOccurrences(of: "{{GLYPHS}}", with: PilotMapConfig.glyphsTemplate)
            .replacingOccurrences(of: "{{OUTLINE_TILES}}", with: PilotMapConfig.outlineTileTemplate)
            .replacingOccurrences(of: "{{LANG}}", with: outlineLanguage)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-day.style.json")
        do {
            try filled.write(to: out, atomically: true, encoding: .utf8)
            return out
        } catch {
            return nil
        }
    }()

    /// The outline names countries, capitals, rivers and lakes in English, French and German: the app's language
    /// when it is one of them, else English.
    static var outlineLanguage: String {
        ["en", "fr", "de"].contains(AppLanguage.current) ? AppLanguage.current : "en"
    }

    private static var registered = false

    /// Before the first map view or snapshot: MapLibre's session answered by `PilotTileURLProtocol`.
    static func prepare() {
        guard !registered else { return }
        PilotTileURLProtocol.registerWithMapLibre(source: PilotMap.shared)
        registered = true
    }

    /// The peaks' mark: a small brown triangle, as the style's `peak` image.
    /// The hatch of an R, D or P area: charcoal diagonals that tile across the pattern's edges (a1 A).
    static let hatchImageName = "airspace.hatch"
    static let hatchImage: UIImage = {
        let side: CGFloat = 12
        let c = AirspaceMapKind.restrictive.color
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let cg = context.cgContext
            cg.setStrokeColor(UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1).cgColor)
            cg.setLineWidth(1.5)
            cg.setLineCap(.square)
            for offset in [-side, 0, side] {
                cg.move(to: CGPoint(x: offset, y: side))
                cg.addLine(to: CGPoint(x: offset + side, y: 0))
            }
            cg.strokePath()
        }
    }()

    static let peakImage: UIImage = {
        let size = CGSize(width: 11, height: 9)
        return UIGraphicsImageRenderer(size: size).image { context in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: size.width / 2, y: 0))
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.close()
            UIColor(red: 0.416, green: 0.263, blue: 0.129, alpha: 1).setFill()
            path.fill()
        }
    }()
}

// MARK: - The view

/// `AeroMapView` drawn by MapLibre (6.8.0, the plan's PR 4): the pilot's map, the swisstopo charts and OpenAIP's tiles
/// over it, the layer choice, the camera kept in `SharedMapState` as the MapKit view keeps it; the airspace, the
/// procedures, the track, the routes, the track vector and the aircraft over everything (`PilotMapShapes`, PR 6); the
/// markers and their cards and callouts (`PilotMapMarkers`, PR 7). The legs band and the builder's gestures follow in
/// the next PRs of the stack.
struct PilotMapView: UIViewRepresentable {
    let map: AeroMapView

    func makeUIView(context: Context) -> MLNMapView {
        PilotMapStyle.prepare()
        // A frame of its own from the start: a camera set on a view of no size lands near 0° N 0° E.
        let view = MLNMapView(frame: CGRect(x: 0, y: 0, width: 320, height: 320), styleURL: PilotMapStyle.url)
        view.delegate = context.coordinator
        view.logoView.isHidden = true
        view.attributionButtonPosition = .bottomLeft
        view.isPitchEnabled = false
        view.isRotateEnabled = true
        // The follow's slide at 30 frames a second; the pilot's finger gets the screen's full rate (6.10.0).
        view.preferredFramesPerSecond = .lowPower
        let platformControls = map.features.contains(.mapKitControls)
        view.compassView.isHidden = !platformControls
        view.showsScale = platformControls
        view.showsUserLocation = platformControls
        context.coordinator.placeCamera(on: view)
        // A tap on the map, not on a marker or a callout, closes the callout open: MapLibre's own tap recognizer never
        // fired under SwiftUI's chrome (7.0.0-pre2), neither to select nor to deselect.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.mapTapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        #if DEBUG
        // The screenshot run's "map settled": still, and nothing left for MapLibre to draw.
        MapSettle.watch(map: view) { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator, view.window != nil else { return nil }
            let bounds = view.visibleCoordinateBounds
            let nw = MKMapPoint(CLLocationCoordinate2D(latitude: bounds.ne.latitude, longitude: bounds.sw.longitude))
            let se = MKMapPoint(CLLocationCoordinate2D(latitude: bounds.sw.latitude, longitude: bounds.ne.longitude))
            let rect = MKMapRect(x: nw.x, y: nw.y, width: se.x - nw.x, height: se.y - nw.y)
            return (MapSettle.View(rect: rect, heading: view.direction), !coordinator.isIdle)
        }
        #endif
        return view
    }

    func updateUIView(_ view: MLNMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.map = map
        // In the background MapLibre draws nothing, so a follow never arrives and was asked again at each pass. The
        // map catches up once the app is active again. (6.10.0)
        if UIApplication.shared.applicationState == .background {
            coordinator.deferUpdate(of: view)
            return
        }
        Self.update(view, coordinator: coordinator)
    }

    /// Everything the shared state asks of the map: the layers, shapes, markers, credits, zoom limits and camera.
    static func update(_ view: MLNMapView, coordinator: Coordinator) {
        let map = coordinator.map
        // A finger dragging the planned route has the map until release. (6.7.0)
        if coordinator.routeDragging(on: view) { return }
        PilotMap.onlineAllowed = !map.isStrictOfflineMode
        coordinator.applyLayers(on: view)
        coordinator.applyShapes(on: view)
        coordinator.applyMarkers(on: view)
        coordinator.updateCredits(on: view)
        coordinator.applyZoomLimits(on: view)
        guard coordinator.hasSize(view) else { return }
        coordinator.applyCamera(on: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(map: map) }

    final class Coordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {
        var map: AeroMapView
        private var style: MLNStyle?
        /// The rasters on the map, to replace them only when the layer or the policy changes.
        private var drawnRasters: [PilotMapCharts.Raster] = []
        /// The lines, areas and aircraft over the map.
        private let shapes = PilotMapShapes()
        /// The markers, their cards and callouts.
        private let markers = PilotMapMarkers()
        /// The legs panel's band, which has the camera while the panel is open.
        private let legsBand = PilotLegsBand()
        /// The route builder's editing.
        private let editing = PilotRouteEditing()

        /// The planned route given to the editing; true while a finger drags it.
        func routeDragging(on mapView: MLNMapView) -> Bool {
            let map = self.map
            return MainActor.assumeIsolated {
                editing.route = map.shownPlannedRoute
                editing.install(on: mapView)
                editing.onPreview = { [weak self, weak mapView] in
                    guard let self, let mapView else { return }
                    self.applyShapes(on: mapView)
                    PilotMapMarkers.hideWaypointMarker(index: self.editing.movingIndex, on: mapView)
                }
                return editing.isDragging
            }
        }
        private var isUserInteracting = false
        /// The view's size when the camera was last placed from the shared state: placed again once SwiftUI has laid
        /// the view out, so the first report back describes the pilot's map, not the placeholder frame.
        private var placedAt: CGSize = .zero

        func placeCamera(on mapView: MLNMapView) {
            let state = map.mapState
            mapView.setCamera(MLNMapCamera(lookingAtCenter: state.region.center, altitude: state.cameraDistance, pitch: 0,
                                           heading: state.cameraHeading), animated: false)
            placedAt = mapView.bounds.size
        }

        /// Laid out at its real size: the first time, the camera goes where the shared state says.
        func hasSize(_ mapView: MLNMapView) -> Bool {
            guard mapView.window != nil, mapView.bounds.width > 1, mapView.bounds.height > 1 else { return false }
            if placedAt == CGSize(width: 320, height: 320) && mapView.bounds.size != placedAt { placeCamera(on: mapView) }
            return true
        }

        init(map: AeroMapView) { self.map = map }

        deinit {
            if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        }

        // MARK: Background

        /// The map a pass in the background left alone, brought up to date when the app is active again.
        private weak var deferredView: MLNMapView?
        private var activeObserver: NSObjectProtocol?

        func deferUpdate(of mapView: MLNMapView) {
            stopGlide()
            deferredView = mapView
            guard activeObserver == nil else { return }
            activeObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let view = self.deferredView else { return }
                    self.deferredView = nil
                    PilotMapView.update(view, coordinator: self)
                }
            }
        }

        // MARK: Frame rate

        /// Back to the follow's 30 frames a second a second after the pilot's finger left the map (6.10.0).
        private var frameRateRestore: DispatchWorkItem?

        func fingerFrameRate(on mapView: MLNMapView) {
            frameRateRestore?.cancel()
            frameRateRestore = nil
            if mapView.preferredFramesPerSecond != .maximum { mapView.preferredFramesPerSecond = .maximum }
            glideFrameRate = nil
        }

        func restoreFollowFrameRate(on mapView: MLNMapView) {
            // Only after a finger: a glide's own rate is the glide's.
            guard mapView.preferredFramesPerSecond == .maximum else { return }
            frameRateRestore?.cancel()
            let restore = DispatchWorkItem { [weak self, weak mapView] in
                mapView?.preferredFramesPerSecond = .lowPower
                self?.frameRateRestore = nil
                self?.glideFrameRate = nil
            }
            frameRateRestore = restore
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: restore)
        }

        private var policy: ChartPolicy {
            ChartPolicy(forceICAO: map.forceICAOLayer, strictOffline: map.isStrictOfflineMode,
                        segelflugCache: map.hasSegelflugCache)
        }

        // MARK: Layers

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            self.style = style
            style.setImage(PilotMapStyle.peakImage, forName: "peak")
            style.setImage(PilotMapStyle.hatchImage, forName: PilotMapStyle.hatchImageName)
            drawnRasters = []
            MainActor.assumeIsolated { shapes.reset() }
            applyLayers(on: mapView)
            applyShapes(on: mapView)
        }

        // MARK: Markers

        @objc func mapTapped(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let mapView = gesture.view as? MLNMapView else { return }
            let point = gesture.location(in: mapView)
            // The edge arrow, panned away from the aircraft: back to it, as centre. Before the markers: it sits over them.
            if !map.isFollowingAircraft, let geometry = map.edgeArrowGeometry, let aircraft = map.shownAircraft,
               let onTap = map.onEdgeArrowTap,
               geometry.edgeArrowHit(point, aircraft: aircraft.coordinate, region: map.mapState.region,
                                     heading: mapView.direction, target: CockpitTarget.control) {
                onTap()
                return
            }
            var hit = mapView.hitTest(point, with: nil)
            while let view = hit {
                if view is PilotMarkerView || view is PilotMarkerCallout { return }
                hit = view.superview
            }
            // The first tap beside an open callout closes it, as it always did. Only a tap with nothing to close asks
            // what is over the point (6.9.0).
            let closedCallout = !mapView.selectedAnnotations.isEmpty
            for annotation in mapView.selectedAnnotations { mapView.deselectAnnotation(annotation, animated: true) }
            if !closedCallout, let tap = map.airspaceTapHandler { tap(mapView.convert(point, toCoordinateFrom: mapView)) }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// The markers as the MapKit view shows them, and a search's aerodrome's card once the map is there.
        func applyMarkers(on mapView: MLNMapView) {
            guard style != nil else { return }
            let map = self.map
            MainActor.assumeIsolated {
                markers.onWaypointLongPress = { map.atoTap?($0) }
                markers.sync(map, on: mapView)
                markers.openPendingCallout(on: mapView, mapState: map.mapState)
            }
        }

        func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            if let aircraft = annotation as? PilotAircraftMarker {
                // The route builder's dragged pin, or the aircraft.
                return MainActor.assumeIsolated {
                    if aircraft === editing.draggedPin {
                        let view = PilotMarkerView(reuseIdentifier: nil)
                        view.annotation = aircraft
                        let lifted = PilotMapMarkers.liftedPinImage(label: editing.draggedLabel)
                        view.show(lifted.image, offset: lifted.dotOffset)
                        view.isEnabled = false
                        return view
                    }
                    return markers.view(for: aircraft, on: mapView)
                }
            }
            guard let marker = annotation as? PilotMarker else { return nil }
            return MainActor.assumeIsolated { markers.view(for: marker, on: mapView, inFlight: map.isInFlight) }
        }

        func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            guard let marker = annotation as? PilotMarker else { return false }
            return MainActor.assumeIsolated { PilotMapMarkers.hasCallout(marker.base) }
        }

        func mapView(_ mapView: MLNMapView, calloutViewFor annotation: MLNAnnotation) -> MLNCalloutView? {
            guard let marker = annotation as? PilotMarker else { return nil }
            let map = self.map
            return MainActor.assumeIsolated {
                markers.callout(for: marker, map: map, on: mapView) { [weak mapView] in
                    mapView?.deselectAnnotation(marker, animated: true)
                }
            }
        }

        func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            guard let marker = annotation as? PilotMarker else { return }
            MainActor.assumeIsolated {
                switch marker.base {
                case let waypoint as FlightPlanWaypointAnnotation:
                    // A tap records the time over the waypoint, in flight only: on Plan › Map a tap stamped one. (6.5.0)
                    mapView.deselectAnnotation(annotation, animated: false)
                    if map.isInFlight { map.atoTap?(waypoint.waypointIndex) }
                case is VFRApproachAnnotation:
                    mapView.deselectAnnotation(annotation, animated: false)
                case let tag as AirspaceTagAnnotation:
                    mapView.deselectAnnotation(annotation, animated: false)
                    if let id = tag.content.notamId, let item = map.shownNotams.first(where: { $0.id == id }) {
                        map.notamReader?([item.notam], item.notam.number)
                    }
                case let notam as NotamMarkerAnnotation:
                    mapView.deselectAnnotation(annotation, animated: false)
                    map.notamReader?([notam.item.notam], notam.item.notam.number)
                default:
                    // A route pin selects its row in the route builder too. (planning proposal D3)
                    _ = markers.plannedRoute.didSelect(marker.base)
                    map.mapState.noteCalloutOpen(true)   // the chrome steps aside (6.2.0)
                }
            }
        }

        func mapView(_ mapView: MLNMapView, didDeselect annotation: MLNAnnotation) {
            let state = map.mapState
            let closed = ((annotation as? PilotMarker)?.base as? AirportAnnotation)?.airport.ident
            MainActor.assumeIsolated {
                state.noteCalloutOpen(false)
                // The searched aerodrome's own marker goes with its card. (6.8.0, device check pm-10)
                if let searched = state.searchedAerodrome, searched.ident == closed {
                    state.searchedAerodrome = nil
                    state.objectWillChange.send()
                }
            }
        }

        /// The airspace, procedures, track, routes, track vector and aircraft, as the MapKit view draws them.
        func applyShapes(on mapView: MLNMapView) {
            guard let style else { return }
            // The map's delegate and SwiftUI's updates come on the main thread.
            MainActor.assumeIsolated { shapes.apply(map, on: mapView, style: style, routePreview: editing.preview) }
        }

        /// The chart's rasters, above the pilot's map (a chart covers the map where it has tiles) and
        /// under the lines and areas (`PilotMapShapes`).
        func applyLayers(on mapView: MLNMapView) {
            guard let style else { return }
            let wanted = PilotMapCharts.rasters(for: map.layerType, policy: policy)
            guard wanted != drawnRasters else { return }
            for raster in drawnRasters {
                if let layer = style.layer(withIdentifier: raster.id) { style.removeLayer(layer) }
                if let source = style.source(withIdentifier: raster.id) { style.removeSource(source) }
            }
            for raster in wanted {
                let source = MLNRasterTileSource(identifier: raster.id, tileURLTemplates: [raster.template], options: [
                    .minimumZoomLevel: raster.minTileZoom, .maximumZoomLevel: raster.maxTileZoom, .tileSize: 256,
                ])
                style.addSource(source)
                let layer = MLNRasterStyleLayer(identifier: raster.id, source: source)
                if let minZoom = raster.minZoom { layer.minimumZoomLevel = Float(minZoom) }
                if let maxZoom = raster.maxZoom { layer.maximumZoomLevel = Float(maxZoom) }
                if let lines = MainActor.assumeIsolated({ shapes.lowestLayer(in: style) }) {
                    style.insertLayer(layer, below: lines)
                } else {
                    style.addLayer(layer)
                }
            }
            drawnRasters = wanted
        }

        // MARK: Imagery credits

        /// Each imagery source on screen, credited in its own words with its link, while the imagery shows (the licence
        /// register's first rule): at a border, every source in view.
        private lazy var credits: UITextView = {
            let view = UITextView()
            view.isEditable = false
            view.isScrollEnabled = false
            view.backgroundColor = UIColor.white.withAlphaComponent(0.85)
            view.layer.cornerRadius = 6
            view.textContainerInset = UIEdgeInsets(top: 3, left: 5, bottom: 3, right: 5)
            view.textContainer.lineFragmentPadding = 0
            view.font = UIFont.systemFont(ofSize: 11)
            view.linkTextAttributes = [.foregroundColor: UIColor(red: 0.13, green: 0.37, blue: 0.59, alpha: 1)]
            view.accessibilityIdentifier = "map.imageryCredits"
            view.translatesAutoresizingMaskIntoConstraints = false
            return view
        }()
        private var shownCredits: [String] = []
        private var creditsBottom: NSLayoutConstraint?

        func updateCredits(on mapView: MLNMapView) {
            let showing = policy.layer(for: map.layerType) == .satellite && !map.isStrictOfflineMode
            let sources = showing ? ImageryTiles.credited(in: Self.mercatorRect(of: mapView), zoom: mapView.zoomLevel,
                                                          store: PilotMap.imagery) : []
            let ids = sources.map(\.id)
            // Above the scale bar and MapLibre's attribution button, and above Plan › Map's allowance line or the Cockpit's
            // foot chips.
            creditsBottom?.constant = -(64 + map.mapState.footerLift)
            guard ids != shownCredits else { return }
            shownCredits = ids
            guard !sources.isEmpty else { credits.removeFromSuperview(); return }
            let text = NSMutableAttributedString()
            for (i, source) in sources.enumerated() {
                if i > 0 { text.append(NSAttributedString(string: " · ")) }
                var attributes: [NSAttributedString.Key: Any] = [:]
                if let link = source.creditLink.flatMap(URL.init(string:)) { attributes[.link] = link }
                text.append(NSAttributedString(string: source.creditLine(), attributes: attributes))
            }
            text.addAttributes([.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor(white: 0.1, alpha: 1)],
                               range: NSRange(location: 0, length: text.length))
            credits.attributedText = text
            if credits.superview == nil {
                mapView.addSubview(credits)
                let guide = mapView.safeAreaLayoutGuide
                let bottom = credits.bottomAnchor.constraint(equalTo: guide.bottomAnchor,
                                                             constant: -(64 + map.mapState.footerLift))
                creditsBottom = bottom
                NSLayoutConstraint.activate([
                    credits.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
                    credits.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -8),
                    bottom,
                ])
            }
        }

        /// The view in web mercator [0, 1].
        static func mercatorRect(of mapView: MLNMapView) -> CGRect {
            let b = mapView.visibleCoordinateBounds
            let nw = ImageryGeometry.mercator(lon: b.sw.longitude, lat: b.ne.latitude)
            let se = ImageryGeometry.mercator(lon: b.ne.longitude, lat: b.sw.latitude)
            return CGRect(x: nw.x, y: nw.y, width: max(se.x - nw.x, 1e-9), height: max(se.y - nw.y, 1e-9))
        }

        // MARK: Camera

        /// The layer's camera range (`ChartPolicy`, in camera distances, as on MapKit) in MapLibre's zooms for this
        /// view's size.
        func applyZoomLimits(on mapView: MLNMapView) {
            guard mapView.bounds.width > 0 else { return }
            let range = policy.cameraZoomRange(for: map.layerType)
            let latitude = mapView.centerCoordinate.latitude
            let size = mapView.bounds.size
            let minZoom = MLNZoomLevelForAltitude(range.maxCenterCoordinateDistance, 0, latitude, size)
            let maxZoom = MLNZoomLevelForAltitude(range.minCenterCoordinateDistance, 0, latitude, size)
            if abs(mapView.minimumZoomLevel - minZoom) > 0.01 { mapView.minimumZoomLevel = max(0, minZoom) }
            if abs(mapView.maximumZoomLevel - maxZoom) > 0.01 { mapView.maximumZoomLevel = min(22, maxZoom) }
            // The zoom buttons stop where the chart does, and grey out there (device check h-4, round 7: the scale
            // changed but the map didn't, at its limit). The distances the map can reach at these zoom levels, not the
            // range's: a level converted back gives another distance (5,952 m for a range's 3,341 m, 11 Nov).
            let closest = MLNAltitudeForZoomLevel(mapView.maximumZoomLevel, 0, latitude, size)
            let farthest = MLNAltitudeForZoomLevel(mapView.minimumZoomLevel, 0, latitude, size)
            if closest > 0, farthest > closest { map.mapState.zoomLimits = closest...farthest }
        }

        /// The shared state's camera, when it moved without the pilot's finger: a north reset, a fit, the aircraft
        /// followed, the heading in track-up.
        func applyCamera(on mapView: MLNMapView) {
            let state = map.mapState
            let map = self.map
            // The marker rides the centre only while a glide or a rest on the aircraft has the camera.
            var ridesOn = false
            defer {
                if !ridesOn {
                    glideTarget = nil
                    glideFixTime = nil
                    glideInterval = nil
                    stopGlide()
                    setGlideFrameRate(nil, on: mapView)
                    let fix = map.shownAircraft?.coordinate
                        MainActor.assumeIsolated { markers.leaveCentre(at: fix) }
                }
            }
            // The open legs panel's band has the camera until it has closed and put the pilot's back.
            if MainActor.assumeIsolated({ legsBand.update(mapView, band: map.legsBand, mapState: state) }) { return }
            if state.pendingHeadingReset {
                state.pendingHeadingReset = false
                let camera = mapView.camera
                camera.heading = 0
                mapView.setCamera(camera, animated: true)
                return
            }
            if let fit = state.pendingFitCoordinates, !fit.isEmpty, mapView.bounds.width > 0 {
                state.pendingFitCoordinates = nil
                let padding = state.pendingFitPadding ?? UIEdgeInsets(top: 130, left: 50, bottom: 130, right: 50)
                state.pendingFitPadding = nil
                var coordinates = fit
                mapView.setVisibleCoordinates(&coordinates, count: UInt(coordinates.count), edgePadding: padding, animated: false)
                state.cameraDistance = mapView.camera.altitude
                state.updateFromFit(Self.region(of: mapView))
                return
            }
            // A search's aerodrome, within the chart's zoom range. (6.2.0)
            if let move = state.pendingCameraMove, MainActor.assumeIsolated({ move.apply(to: mapView) }) {
                state.pendingCameraMove = nil
                state.cameraDistance = mapView.camera.altitude
                state.updateFromFit(Self.region(of: mapView))
                return
            }
            guard !isUserInteracting else { return }
            let region = state.region
            // Following: the pilot's follow is on. A fix moves the aircraft at once and reaches the shared state's
            // region a turn later (`updateFromRegion`): in between, the marker stays on the centre, unless the fix is
            // far from it (the camera isn't following it: the nav sheet open).
            let following = map.isFollowingAircraft && fixNearCentre(on: mapView)
            // A glide on its way to this fix: nothing to ask again. A pass in between (any other change) would start
            // it over, slower.
            if following, let glideTarget, Self.same(glideTarget, region.center) {
                ridesOn = true
                // A zoom tap meanwhile: the drive eases to it, even with the aircraft held (parked, between fixes).
                if glideActive { wakeGlide() }
                return
            }
            let center = mapView.centerCoordinate
            // Following, every fix moves the map, a taxi's few metres too (11 m before, so every other fix); otherwise a
            // move of the shared state's centre (about 11 m).
            let threshold = following ? 0.000002 : 0.0001
            let moved = abs(center.latitude - region.center.latitude) > threshold
                || abs(center.longitude - region.center.longitude) > threshold
            let turned = Self.angle(mapView.direction, state.cameraHeading) > 0.5
            // The zoom buttons and a search change the distance alone.
            let zoomed = abs(mapView.camera.altitude / max(state.cameraDistance, 1) - 1) > 0.02
            guard moved || turned || zoomed else {
                // At rest on the aircraft: it stays on the centre for the next glide.
                ridesOn = following && MainActor.assumeIsolated({ markers.ridesCentre })
                return
            }
            let camera = MLNMapCamera(lookingAtCenter: moved ? region.center : center,
                                      altitude: state.cameraDistance, pitch: 0, heading: state.cameraHeading)
            if following, moved, let glide = glidePace(to: region.center, on: mapView) {
                ridesOn = true
                glideTarget = region.center
                MainActor.assumeIsolated { markers.rideCentre(on: mapView) }
                setGlideFrameRate(glide.frames, on: mapView)
                feedGlide(GlideFix(time: map.shownAircraft?.timestamp ?? FlightClock.now, coordinate: region.center,
                                   heading: state.cameraHeading), on: mapView)
                return
            }
            // A turn or a zoom alone keeps the centre: the aircraft stays on it. Gliding, the drive eases to it: a
            // MapLibre animation would be cut by the drive's next frame (device check h-4, round 7: it stuttered).
            ridesOn = following && !moved && MainActor.assumeIsolated({ markers.ridesCentre })
            if ridesOn, glideActive {
                wakeGlide()
                return
            }
            setGlideFrameRate(nil, on: mapView)
            mapView.setCamera(camera, animated: DryRunCameraPace.animates)
        }

        // MARK: Glide

        /// The fix the camera is gliding to, and when the follow last moved it.
        private var glideTarget: CLLocationCoordinate2D?
        private var lastFollowMove: CFTimeInterval = 0
        /// Longer than this between two fixes (a gap, a pause, the first fix) and the camera goes as before.
        static let glideGap: CFTimeInterval = 2.5

        /// How long the glide to `target` takes: as long as since the last fix, so the map arrives as the next one
        /// is due and never stops between (1 s in flight, 50 ms in a dry run at 30×). Nil when the camera should go
        /// as before: Reduce Motion, a gap, a jump longer than a third of the map, or the aircraft not on the centre
        /// to start from (the pilot just asked to follow again).
        private func glidePace(to target: CLLocationCoordinate2D, on mapView: MLNMapView) -> (pace: TimeInterval, frames: Int)? {
            let now = CACurrentMediaTime()
            let since = now - lastFollowMove
            lastFollowMove = now
            let point = mapView.convert(target, toPointTo: mapView)
            let jump = hypot(point.x - mapView.bounds.midX, point.y - mapView.bounds.midY)
            let onCentre = MainActor.assumeIsolated {
                markers.ridesCentre || (markers.aircraftOffset(on: mapView).map { $0 < 3 } ?? false)
            }
            // The fixes' own times, not when they arrived: the dry run hands out one fix, then two, in the same 50 ms
            // (30 a second on a 20 Hz timer), and a GPS fix comes a little early or late. Timed by their arrival, the
            // map ran at one speed then twice it and paused between: smooth a few frames, then a hitch (the author's
            // g-2, round 6). Each fix is shown a fixed delay after its own time, the camera there just then.
            let rate = (FlightClock.virtual?.rate).map { $0 > 0 ? $0 : 1 } ?? 1
            let fixTime = map.shownAircraft?.timestamp
            if let fixTime, let glideFixTime, fixTime > glideFixTime {
                let interval = fixTime.timeIntervalSince(glideFixTime) / rate
                glideInterval = glideInterval.map { 0.7 * $0 + 0.3 * interval } ?? interval
            }
            let age = fixTime.map { FlightClock.now.timeIntervalSince($0) / rate }
            guard let pace = Self.glidePace(since: since, jump: jump, mapSize: mapView.bounds.size, onCentre: onCentre,
                                            reduceMotion: UIAccessibility.isReduceMotionEnabled, age: age,
                                            delay: Self.glideDelay(interval: glideInterval ?? since))
            else {
                glideFixTime = nil
                glideInterval = nil
                return nil
            }
            glideFixTime = fixTime
            return (pace, Self.glideFrames(pointsPerSecond: Double(jump) / pace))
        }

        // MARK: The drive

        /// A fix the camera passes through: its own time, where, and the camera's heading for it (track-up).
        struct GlideFix: Equatable {
            let time: Date
            let coordinate: CLLocationCoordinate2D
            let heading: Double

            static func == (a: GlideFix, b: GlideFix) -> Bool {
                a.time == b.time && Coordinator.same(a.coordinate, b.coordinate) && a.heading == b.heading
            }
        }

        /// The glide is driven frame by frame: as MapLibre starts each frame, the camera goes where the aircraft was
        /// `glideDelay` ago, between the two fixes around that moment, with no MapLibre animation. A camera move
        /// started while one runs made MapLibre jump the rest of the old one: every fix a frame three times as long as
        /// its neighbours (the author's g-2, round 6, "smooth for a few frames, but then lags"). On MapLibre's own
        /// frames, not a display link of ours: two clocks drew frames 17 ms, then 48 ms apart. Each camera change asks
        /// for the next frame, at the glide's rate; with no fix to follow the frames stop.
        private var glideFixes: [GlideFix] = []
        private var glideActive = false
        private weak var glideMap: MLNMapView?
        /// True while the drive moves the camera: its own region changes are the drive's, not the pilot's.
        private var glideMoving = false
        /// A finger moved the map since it last came to rest: a flick's coast, stopped by a touch, ends "cancelled".
        private var fingerMoved = false
        /// The full work of a map at rest (credits, shapes for the zoom, names that collide): every 2 s while gliding.
        private var glideRestPass: CFTimeInterval = 0
        static let glideRestEvery: CFTimeInterval = 2

        private func feedGlide(_ fix: GlideFix, on mapView: MLNMapView) {
            if let last = glideFixes.last, fix.time <= last.time {
                glideFixes[glideFixes.count - 1] = fix
            } else {
                glideFixes.append(fix)
                if glideFixes.count > 6 { glideFixes.removeFirst(glideFixes.count - 6) }
            }
            glideMap = mapView
            wakeGlide()
        }

        /// The first frame, or one after the drive stalled (nothing changed, so MapLibre drew nothing): from there
        /// each frame asks for the next.
        private func wakeGlide() {
            if !glideActive || CACurrentMediaTime() - glideLastTick > 0.2 {
                glideActive = true
                glideTick()
            }
        }

        /// When the drive last placed the camera, and the zoom it is on its way through: from, to, since when.
        private var glideLastTick: CFTimeInterval = 0
        private var glideZoom: (from: Double, to: Double, start: CFTimeInterval)?
        /// A zoom tap's move while the drive has the camera: as long as MapLibre's own was.
        static let glideZoomDuration: CFTimeInterval = 0.2

        /// The camera's distance `progress` (0 to 1) of the way through a zoom from `from` to `to`: in the scale's
        /// terms (logarithmic, as each tap halves or doubles), quick first and settling at the end.
        static func zoomedAltitude(from: Double, to: Double, progress: Double) -> Double {
            guard from > 0, to > 0 else { return to }
            let p = min(1, max(0, progress))
            guard p < 1 else { return to }
            let eased = 1 - (1 - p) * (1 - p)
            return exp(log(from) + (log(to) - log(from)) * eased)
        }

        func stopGlide() {
            glideActive = false
            glideFixes = []
            glideZoom = nil
        }

        private func glideTick() {
            guard let mapView = glideMap, mapView.window != nil, !isUserInteracting,
                  UIApplication.shared.applicationState != .background else {
                stopGlide()
                return
            }
            let rate = (FlightClock.virtual?.rate).map { $0 > 0 ? $0 : 1 } ?? 1
            let interval = glideInterval ?? 1
            let shown = FlightClock.now.addingTimeInterval(-Self.glideDelay(interval: interval) * rate)
            guard let last = glideFixes.last,
                  let place = Self.glidePosition(glideFixes, at: shown, reach: interval * rate) else {
                stopGlide()
                return
            }
            let now = CACurrentMediaTime()
            let target = map.mapState.cameraDistance
            if glideZoom?.to != target {
                // A new zoom: from where the camera is now, even halfway through the last one.
                let current = mapView.camera.altitude
                glideZoom = abs(current / target - 1) < 0.002 ? nil : (current, target, now)
            }
            let altitude = glideZoom.map {
                Self.zoomedAltitude(from: $0.from, to: $0.to, progress: (now - $0.start) / Self.glideZoomDuration)
            } ?? target
            glideLastTick = now
            let camera = MLNMapCamera(lookingAtCenter: place.coordinate, altitude: altitude, pitch: 0, heading: place.heading)
            glideMoving = true
            mapView.setCamera(camera, animated: false)
            glideMoving = false
            // A zoom under way asks for its next frame itself: its first is where the camera already is, and with the
            // aircraft held nothing else changed, so MapLibre drew nothing more (a tap waited 4.6 s, 11 Nov).
            if let zoom = glideZoom, now - zoom.start < Self.glideZoomDuration { mapView.triggerRepaint() }
            MainActor.assumeIsolated { markers.layout(on: mapView, atRest: false) }
            // Caught up with a fix that no other follows (parked, paused): the drive rests, the map with it.
            if shown.timeIntervalSince(last.time) > Self.glideGap * rate {
                stopGlide()
                self.mapView(mapView, regionDidChangeWith: [], animated: false)
            }
        }

        /// Where the camera is at `time`: between the two fixes around it; past the last, on along its last leg for
        /// `reach` (a fix a little late never stops the map), then held there.
        static func glidePosition(_ fixes: [GlideFix], at time: Date,
                                  reach: TimeInterval) -> (coordinate: CLLocationCoordinate2D, heading: Double)? {
            guard let first = fixes.first, let last = fixes.last else { return nil }
            if time <= first.time || fixes.count == 1 { return (first.coordinate, first.heading) }
            var a = fixes[fixes.count - 2], b = last
            for (p, q) in zip(fixes, fixes.dropFirst()) where time <= q.time {
                a = p
                b = q
                break
            }
            let span = max(b.time.timeIntervalSince(a.time), 0.001)
            let along = min(time.timeIntervalSince(a.time), span + max(reach, 0)) / span
            let coordinate = CLLocationCoordinate2D(
                latitude: a.coordinate.latitude + (b.coordinate.latitude - a.coordinate.latitude) * along,
                longitude: a.coordinate.longitude + (b.coordinate.longitude - a.coordinate.longitude) * along)
            var turn = (b.heading - a.heading).truncatingRemainder(dividingBy: 360)
            if turn > 180 { turn -= 360 } else if turn < -180 { turn += 360 }
            let heading = (a.heading + turn * min(along, 1)).truncatingRemainder(dividingBy: 360)
            return (coordinate, heading < 0 ? heading + 360 : heading)
        }

        /// The time of the fix the camera glides to, and the fixes' interval on the clock, smoothed.
        private var glideFixTime: Date?
        private var glideInterval: TimeInterval?

        /// How long after its own time a fix is shown: one interval between fixes and a margin for a fix that comes
        /// late, so the camera reaches each fix as the next is on its way and never waits (1.1 s in flight, 0.13 s
        /// in a dry run at 30×; the glide before showed each fix about one interval late too).
        static func glideDelay(interval: TimeInterval) -> TimeInterval { min(interval, glideGap) + 0.1 }

        /// Frames a second for a glide: about a point a frame, so the map draws no more than the move shows, and
        /// only a rate that divides 60 (every 6th, 5th, 4th, 3rd or 2nd refresh), so the frames come evenly. In
        /// cruise at 1× the map moves a few points a second (10 frames), at 30× a hundred and more (30). The finger
        /// still gets the screen's full rate. Measured on 10 Nov: 30 frames all the glide long doubled the CPU.
        static func glideFrames(pointsPerSecond: Double) -> Int {
            [10, 12, 15, 20].first { Double($0) >= pointsPerSecond } ?? 30
        }

        /// The glide's rate on the map, or the follow's 30 back (nil): never over a finger's full rate. A new rate
        /// waits a second: changed at every fix, the frames came every second refresh, then every third.
        private var glideFrameRate: Int?
        private var glideRateAsked: (frames: Int, since: CFTimeInterval)?
        static let glideRateHold: CFTimeInterval = 1

        private func setGlideFrameRate(_ frames: Int?, on mapView: MLNMapView) {
            guard frames != glideFrameRate, frameRateRestore == nil, !isUserInteracting else {
                glideRateAsked = nil
                return
            }
            if let frames, glideFrameRate != nil {
                let now = CACurrentMediaTime()
                // Faster at once (a frame too few shows), slower after a second of asking for it.
                if frames < glideFrameRate ?? 30 {
                    if glideRateAsked?.frames != frames { glideRateAsked = (frames, now) }
                    guard now - (glideRateAsked?.since ?? now) >= Self.glideRateHold else { return }
                }
            }
            glideRateAsked = nil
            glideFrameRate = frames
            mapView.preferredFramesPerSecond = frames.map { MLNMapViewPreferredFramesPerSecond(rawValue: $0) } ?? .lowPower
        }

        /// The rule of `glidePace(to:on:)`, without the map: `since` the last fix arrived, `jump` the move on screen in
        /// points, `age` how long ago the fix was taken (its own time, at the clock's rate), `delay` how long after its
        /// time a fix is shown. The glide ends at that moment, so the camera reaches every fix the same time after it
        /// was taken, at the aircraft's own pace, however the fixes arrive: two at once, one late. With no time, as
        /// long as since the last fix.
        static func glidePace(since: TimeInterval, jump: CGFloat, mapSize: CGSize, onCentre: Bool, reduceMotion: Bool,
                              age: TimeInterval? = nil, delay: TimeInterval = 0) -> TimeInterval? {
            guard !reduceMotion, since < glideGap, onCentre, jump < min(mapSize.width, mapSize.height) / 3 else { return nil }
            let pace = age.map { delay - $0 } ?? since
            return min(max(pace, 0.02), glideGap)
        }

        /// Within this of the centre, a fix is one the camera is on its way to: a second's flight is a few points.
        static let fixReach: CGFloat = 40

        private func fixNearCentre(on mapView: MLNMapView) -> Bool {
            guard let fix = map.shownAircraft?.coordinate else { return false }
            let point = mapView.convert(fix, toPointTo: mapView)
            return hypot(point.x - mapView.bounds.midX, point.y - mapView.bounds.midY) < Self.fixReach
        }

        static func same(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
            abs(a.latitude - b.latitude) < 0.000001 && abs(a.longitude - b.longitude) < 0.000001
        }

        static let gestures: MLNCameraChangeReason = [.gesturePan, .gesturePinch, .gestureRotate, .gestureZoomIn,
                                                      .gestureZoomOut, .gestureOneFingerZoom, .gestureTilt]

        func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            if !reason.intersection(Self.gestures).isEmpty {
                fingerMoved = true
                isUserInteracting = true
                map.isFollowingAircraft = false
                fingerFrameRate(on: mapView)
                glideTarget = nil
                stopGlide()
                let fix = map.shownAircraft?.coordinate
                MainActor.assumeIsolated { markers.leaveCentre(at: fix) }
            }
        }

        /// MapLibre has drawn all it was asked, tiles included; a new frame (a tile arriving, a camera change) ends it.
        private(set) var isIdle = false

        func mapViewDidBecomeIdle(_ mapView: MLNMapView) {
            isIdle = true
            // The credits as the map came to rest: the last camera change of a quick series of zoom taps can end
            // cancelled, and its regionDidChange returns early.
            updateCredits(on: mapView)
        }

        func mapViewWillStartRenderingFrame(_ mapView: MLNMapView) {
            isIdle = false
            if glideActive, mapView === glideMap { glideTick() }
        }

        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            MainActor.assumeIsolated { markers.layout(on: mapView, atRest: false) }
            guard mapView.window != nil, placedAt != CGSize(width: 320, height: 320) else { return }
            map.liveRegion?.region = Self.region(of: mapView)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            if glideMoving {
                let now = CACurrentMediaTime()
                guard now - glideRestPass >= Self.glideRestEvery else { return }
                glideRestPass = now
            }
            isUserInteracting = false
            restoreFollowFrameRate(on: mapView)
            // An animation cut short by the next one (two zoom taps): its halfway camera is nobody's. But a flick
            // stopped by a finger ends cancelled too, and there the camera is the pilot's: kept, or the next pass put
            // the map back where it was before the flick (the author, round 7, as on MapKit once).
            if reason.contains(.transitionCancelled), !fingerMoved, reason.intersection(Self.gestures).isEmpty { return }
            fingerMoved = false
            // Not before the view is on screen at its size: the placeholder's camera is nobody's.
            guard mapView.window != nil, placedAt != CGSize(width: 320, height: 320) else { return }
            // The band's camera isn't the pilot's: the shared state keeps theirs, to go back to.
            if MainActor.assumeIsolated({ legsBand.ownsCamera }) {
                map.mapState.updateBandRegion(Self.region(of: mapView))
                applyShapes(on: mapView)
                MainActor.assumeIsolated { markers.layout(on: mapView, atRest: true) }
                return
            }
            MainActor.assumeIsolated { legsBand.mapCameToRest(mapView, mapState: map.mapState) }
            applyZoomLimits(on: mapView)
            updateCredits(on: mapView)
            // The procedures' dashes and arrowheads are cut for the zoom.
            applyShapes(on: mapView)
            MainActor.assumeIsolated {
                markers.layout(on: mapView, atRest: true)
                markers.openPendingCallout(on: mapView, mapState: map.mapState)
            }
            let state = map.mapState
            let region = Self.region(of: mapView)
            map.liveRegion?.region = region
            // A glide's end is the fix it went to, already in the shared state, or an older one when the next fix
            // came first: written back, it would take the newer fix's place and stop the follow.
            if glideTarget == nil || !reason.intersection(Self.gestures).isEmpty { state.updateFromRegion(region) }
            // Gliding, the camera's distance is on its way to the state's (a zoom tap's): written back halfway, it
            // took the tap's place and the zoom stopped short (11 Nov).
            if glideTarget == nil || !reason.intersection(Self.gestures).isEmpty { state.cameraDistance = mapView.camera.altitude }
            let heading = mapView.direction
            // Gliding, the camera's heading is on its way to the state's: not the pilot's to keep.
            if glideTarget == nil, Self.angle(state.cameraHeading, heading) > 0.1 {
                DispatchQueue.main.async { state.cameraHeading = heading }
            }
        }

        static func region(of mapView: MLNMapView) -> MKCoordinateRegion {
            let bounds = mapView.visibleCoordinateBounds
            return MKCoordinateRegion(center: mapView.centerCoordinate,
                                      span: MKCoordinateSpan(latitudeDelta: abs(bounds.ne.latitude - bounds.sw.latitude),
                                                             longitudeDelta: abs(bounds.ne.longitude - bounds.sw.longitude)))
        }

        static func angle(_ a: Double, _ b: Double) -> Double {
            let d = abs(a - b).truncatingRemainder(dividingBy: 360)
            return min(d, 360 - d)
        }
    }
}
