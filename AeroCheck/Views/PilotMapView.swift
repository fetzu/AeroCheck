import MapKit
import MapLibre
import SwiftUI

// MARK: - The engine

/// Which engine draws the maps while 6.8.0 moves them to MapLibre: MapKit until the stack's last PR takes it out.
/// Settings › About › Developer options switches it; a DEBUG launch can force it (`AEROCHECK_MAP_ENGINE=maplibre`).
enum MapEngine {
    static let defaultsKey = "mapEngineMapLibre"

    static func drawsWithMapLibre(stored: Bool) -> Bool {
        #if DEBUG
        if let forced = ProcessInfo.processInfo.environment["AEROCHECK_MAP_ENGINE"] { return forced == "maplibre" }
        #endif
        return stored
    }

    /// The engine in use now, for code outside a view (the layer names).
    static var current: Bool { drawsWithMapLibre(stored: UserDefaults.standard.bool(forKey: defaultsKey)) }
}

/// A map surface on the engine chosen: `AeroMapView` (MapKit) or `PilotMapView` (MapLibre), from the same inputs.
struct MapEngineView: View {
    let map: AeroMapView
    @AppStorage(MapEngine.defaultsKey) private var mapLibre = false

    var body: some View {
        if MapEngine.drawsWithMapLibre(stored: mapLibre) {
            PilotMapView(map: map)
        } else {
            map
        }
    }
}

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
/// procedures, the track, the routes, the track vector and the aircraft over everything (`PilotMapShapes`, PR 6). The
/// markers and their callouts, the legs band and the builder's gestures follow in the next PRs of the stack.
struct PilotMapView: UIViewRepresentable {
    let map: AeroMapView

    private static var registered = false

    func makeUIView(context: Context) -> MLNMapView {
        if !Self.registered {
            PilotTileURLProtocol.registerWithMapLibre(source: PilotMap.shared)
            Self.registered = true
        }
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
        return view
    }

    func updateUIView(_ view: MLNMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.map = map
        PilotMap.onlineAllowed = !map.isStrictOfflineMode
        coordinator.applyLayers(on: view)
        coordinator.applyShapes(on: view)
        coordinator.updateCredits(on: view)
        coordinator.applyZoomLimits(on: view)
        guard coordinator.hasSize(view) else { return }
        coordinator.applyCamera(on: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(map: map) }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var map: AeroMapView
        private var style: MLNStyle?
        /// The rasters on the map, to replace them only when the layer or the policy changes.
        private var drawnRasters: [PilotMapCharts.Raster] = []
        /// The lines, areas and aircraft over the map.
        private let shapes = PilotMapShapes()
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

        /// The airspace, procedures, track, routes, track vector and aircraft, as the MapKit view draws them.
        func applyShapes(on mapView: MLNMapView) {
            guard let style else { return }
            // The map's delegate and SwiftUI's updates come on the main thread.
            MainActor.assumeIsolated { shapes.apply(map, on: mapView, style: style) }
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

        func updateCredits(on mapView: MLNMapView) {
            let showing = policy.layer(for: map.layerType) == .satellite && !map.isStrictOfflineMode
            let sources = showing ? ImageryTiles.credited(in: Self.mercatorRect(of: mapView), zoom: mapView.zoomLevel,
                                                          store: PilotMap.imagery) : []
            let ids = sources.map(\.id)
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
                NSLayoutConstraint.activate([
                    credits.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
                    credits.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -8),
                    // Above the app's scale bar and MapLibre's attribution button, both at the bottom left.
                    credits.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -64),
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

        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            guard mapView.window != nil, placedAt != CGSize(width: 320, height: 320) else { return }
            map.liveRegion?.region = Self.region(of: mapView)
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            isUserInteracting = false
            // Not before the view is on screen at its size: the placeholder's camera is nobody's.
            guard mapView.window != nil, placedAt != CGSize(width: 320, height: 320) else { return }
            applyZoomLimits(on: mapView)
            updateCredits(on: mapView)
            // The procedures' dashes and arrowheads are cut for the zoom.
            applyShapes(on: mapView)
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
