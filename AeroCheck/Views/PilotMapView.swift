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

        private var policy: ChartPolicy {
            ChartPolicy(forceICAO: map.forceICAOLayer, strictOffline: map.isStrictOfflineMode,
                        segelflugCache: map.hasSegelflugCache)
        }

        // MARK: Layers

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            self.style = style
            style.setImage(PilotMapStyle.peakImage, forName: "peak")
            drawnRasters = []
            MainActor.assumeIsolated { shapes.reset() }
            applyLayers(on: mapView)
            applyShapes(on: mapView)
        }

        // MARK: Markers

        @objc func mapTapped(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let mapView = gesture.view as? MLNMapView else { return }
            let point = gesture.location(in: mapView)
            var hit = mapView.hitTest(point, with: nil)
            while let view = hit {
                if view is PilotMarkerView || view is PilotMarkerCallout { return }
                hit = view.superview
            }
            for annotation in mapView.selectedAnnotations { mapView.deselectAnnotation(annotation, animated: true) }
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

        /// The chart's rasters, then OpenAIP's, above the pilot's map (a chart covers the map where it has tiles) and
        /// under the lines and areas (`PilotMapShapes`).
        func applyLayers(on mapView: MLNMapView) {
            guard let style else { return }
            var wanted = PilotMapCharts.rasters(for: map.layerType, policy: policy)
            if map.features.contains(.openAIPTiles) && map.showOpenAIPTiles {
                wanted.append(PilotMapCharts.openAIPRaster(offline: map.isStrictOfflineMode))
            }
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
            // Above the scale bar and MapLibre's attribution button, and above Plan › Map's allowance line.
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
        }

        /// The shared state's camera, when it moved without the pilot's finger: a north reset, a fit, the aircraft
        /// followed, the heading in track-up.
        func applyCamera(on mapView: MLNMapView) {
            let state = map.mapState
            let map = self.map
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
            let center = mapView.centerCoordinate
            let moved = abs(center.latitude - region.center.latitude) > 0.0001
                || abs(center.longitude - region.center.longitude) > 0.0001
            let turned = Self.angle(mapView.direction, state.cameraHeading) > 0.5
            // The zoom buttons and a search change the distance alone.
            let zoomed = abs(mapView.camera.altitude / max(state.cameraDistance, 1) - 1) > 0.02
            guard moved || turned || zoomed else { return }
            let camera = MLNMapCamera(lookingAtCenter: moved ? region.center : center,
                                      altitude: state.cameraDistance, pitch: 0, heading: state.cameraHeading)
            mapView.setCamera(camera, animated: DryRunCameraPace.animates)
        }

        func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            let gestures: MLNCameraChangeReason = [.gesturePan, .gesturePinch, .gestureRotate, .gestureZoomIn,
                                                   .gestureZoomOut, .gestureOneFingerZoom, .gestureTilt]
            if !reason.intersection(gestures).isEmpty {
                isUserInteracting = true
                map.isFollowingAircraft = false
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

        func mapViewWillStartRenderingFrame(_ mapView: MLNMapView) { isIdle = false }

        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            MainActor.assumeIsolated { markers.layout(on: mapView, atRest: false) }
            guard mapView.window != nil, placedAt != CGSize(width: 320, height: 320) else { return }
            map.liveRegion?.region = Self.region(of: mapView)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            isUserInteracting = false
            // An animation cut short by the next one (two zoom taps): its halfway camera is nobody's.
            if reason.contains(.transitionCancelled) { return }
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
            state.updateFromRegion(region)
            state.cameraDistance = mapView.camera.altitude
            let heading = mapView.direction
            if Self.angle(state.cameraHeading, heading) > 0.1 {
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
