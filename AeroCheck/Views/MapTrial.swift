#if DEBUG
import MapKit
import MapLibre
import SwiftUI

// MARK: - The pilot's map trial (round 3, S2 A)

/// DEV-ONLY: the one-week trial of the pilot's map, drawn by MapLibre two ways, measured before choosing (the
/// author's S2 A, 25 Oct 2026). Not for a release; it lives on the `spike/maplibre-trial` branch.
///
/// - `SIMCTL_CHILD_AEROCHECK_MAP_TRIAL=B`: MapLibre draws the whole map (`PilotMapTrialView`), with a scripted
///   flight that records frame times and how long the map takes to fill after each zoom step.
/// - `SIMCTL_CHILD_AEROCHECK_MAP_TRIAL=D`: MapLibre draws tiles for MapKit: Apple's map layer becomes the pilot's map
///   inside `AeroMapView` (`PilotMapTileOverlay`), each tile rendered on the device and timed.
///
/// The data is not in the app: `Documents/MapTrial/` holds `switzerland.pmtiles` (Protomaps' daily build, cut to
/// Switzerland), `switzerland-relief.pmtiles` (Mapterhorn), `fonts/` and the styles `style.json` (labels) and
/// `style-tiles.json` (no labels), written by `CLAUDE/proposals/2026-10-25/map/trial/make-style.py`.
enum MapTrial {
    static var mode: String? { ProcessInfo.processInfo.environment["AEROCHECK_MAP_TRIAL"] }

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MapTrial", isDirectory: true)
    }

    /// The style with `{{DIR}}` replaced by the folder, written beside it; nil without the trial's files.
    static func styleURL(labels: Bool) -> URL? {
        let source = folder.appendingPathComponent(labels ? "style.json" : "style-tiles.json")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else { return nil }
        let out = folder.appendingPathComponent(labels ? "style.resolved.json" : "style-tiles.resolved.json")
        try? text.replacingOccurrences(of: "{{DIR}}", with: folder.path).write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// The app's memory footprint, as Xcode's gauge shows it.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// The trial route: Bressaucourt, Grenchen, Samedan.
    static let route: [CLLocationCoordinate2D] = [
        .init(latitude: 47.3920, longitude: 7.0280),
        .init(latitude: 47.1816, longitude: 7.4172),
        .init(latitude: 46.5341, longitude: 9.8841),
    ]

    static func write(_ object: [String: Any], to name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: folder.appendingPathComponent(name))
    }
}

/// Presents trial B or D over the app when the environment asks for it.
struct MapTrialPresenter: ViewModifier {
    @State private var showing = MapTrial.mode == "B" || MapTrial.mode == "D"

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $showing) {
            if MapTrial.mode == "D" { PilotTileTrialView() } else { PilotMapTrialView() }
        }
    }
}

/// The scripted flight both trials fly: zoom steps at LSZQ, the route in track-up, zoom steps at LSZS. Zooms are
/// MapKit's (the round 3 page's); MapLibre's are one lower.
enum MapTrialFlight {
    enum Step { case zoom(String, CLLocationCoordinate2D, Int), leg(String, CLLocationCoordinate2D, CLLocationDirection) }
    static var steps: [Step] {
        var out: [Step] = []
        let path = MapTrial.route
        for z in [10, 11, 12, 13, 14, 16] { out.append(.zoom("LSZQ z\(z)", path[0], z)) }
        for i in 0..<(path.count - 1) {
            let a = path[i], b = path[i + 1]
            let course = PilotMapView.bearing(a, b)
            for k in 0...4 {
                let f = Double(k) / 4
                out.append(.leg("leg \(i + 1).\(k)", .init(latitude: a.latitude + (b.latitude - a.latitude) * f,
                                                         longitude: a.longitude + (b.longitude - a.longitude) * f), course))
            }
        }
        for z in [13, 11, 9, 14] { out.append(.zoom("LSZS z\(z)", path[2], z)) }
        return out
    }

    /// Overlays drawn on both trials, once the services have their data.
    @MainActor
    static func airspaces(_ service: OpenAIPDataService) -> [Airspace] {
        let region = MKCoordinateRegion(center: .init(latitude: 46.95, longitude: 8.45), span: .init(latitudeDelta: 1.6, longitudeDelta: 3.6))
        return Array(service.airspacesInBounds(region).prefix(300))
    }
}

// MARK: - Trial B: MapLibre draws the whole map

/// Frame times and fill times, kept while the scripted flight runs.
final class MapTrialRecorder {
    var frameMS: [Double] = []
    var fills: [(label: String, ms: Double)] = []
    var footprints: [Double] = []
    var recording = false
    var fillStarted: (label: String, at: CFTimeInterval)?
    private var lastFrame: CFTimeInterval?

    /// The time since the previous frame while the map moves (gaps over 250 ms are the map at rest). The frame's own
    /// encoding and rendering times read 0 on the simulator.
    func frame() {
        guard recording else { lastFrame = nil; return }
        let now = CACurrentMediaTime()
        if let last = lastFrame, now - last < 0.25 { frameMS.append((now - last) * 1000) }
        lastFrame = now
    }

    func startFill(_ label: String) { fillStarted = (label, CACurrentMediaTime()) }

    func idle() {
        guard let started = fillStarted else { return }
        fills.append((started.label, (CACurrentMediaTime() - started.at) * 1000))
        fillStarted = nil
    }

    func summary() -> [String: Any] {
        let sorted = frameMS.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(Int(Double(sorted.count) * p), sorted.count - 1)] }
        return [
            "frames": sorted.count,
            "frame_ms_p50": pct(0.5), "frame_ms_p95": pct(0.95), "frame_ms_p99": pct(0.99), "frame_ms_max": sorted.last ?? 0,
            "frames_over_17ms": sorted.filter { $0 > 17.5 }.count,
            "frames_over_34ms": sorted.filter { $0 > 34 }.count,
            "fills_ms": fills.map { ["step": $0.label, "ms": ($0.ms * 10).rounded() / 10] },
            "footprint_mb_max": footprints.max() ?? 0,
            "footprint_mb_end": footprints.last ?? 0,
        ]
    }
}

struct PilotMapTrialView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var airportDataService: AirportDataService
    @EnvironmentObject private var openAIPDataService: OpenAIPDataService
    @State private var status = "Ready"
    @State private var flight = 0
    @State private var labels = true
    @State private var overlays: PilotMapView.Overlays?
    private let recorder = MapTrialRecorder()

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let style = MapTrial.styleURL(labels: labels), let overlays {
                PilotMapView(styleURL: style, recorder: recorder, flightToken: flight, overlays: overlays) { status = $0 }
                    .ignoresSafeArea()
            } else {
                Text("No trial data in Documents/MapTrial").padding()
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Close") { dismiss() }
                    Button("Fly") { flight += 1 }
                    Toggle("Labels", isOn: $labels).fixedSize()
                }
                .buttonStyle(.borderedProminent)
                Text(status).font(.system(size: 13, design: .monospaced))
                    .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(.top, 60).padding(.leading, 16)
        }
        .task {
            await airportDataService.ensureLoaded()
            await openAIPDataService.ensureLoaded()
            overlays = makeOverlays()
            if ProcessInfo.processInfo.environment["AEROCHECK_MAP_TRIAL_AUTOFLY"] != nil {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                flight += 1
            }
        }
    }

    /// What lies over the base map on the in-flight map: the route, the airspace and the aerodromes along it.
    private func makeOverlays() -> PilotMapView.Overlays {
        let airspaces = MapTrialFlight.airspaces(openAIPDataService).map { (coordinates: $0.polygonCoordinates, colour: $0.mapColor) }
        let airports = airportDataService.getAirportsInRegion(
            minLat: 46.2, maxLat: 47.8, minLon: 6.5, maxLon: 10.5, types: [.largeAirport, .mediumAirport, .smallAirport], limit: 400)
            .map { (coordinate: $0.coordinate, ident: $0.ident) }
        return .init(route: MapTrial.route, airspaces: Array(airspaces), airports: airports)
    }
}

/// MLNMapView with the trial style and the overlays as GeoJSON sources.
struct PilotMapView: UIViewRepresentable {
    struct Overlays {
        var route: [CLLocationCoordinate2D]
        var airspaces: [(coordinates: [CLLocationCoordinate2D], colour: (red: Double, green: Double, blue: Double))]
        var airports: [(coordinate: CLLocationCoordinate2D, ident: String)]
    }

    let styleURL: URL
    let recorder: MapTrialRecorder
    let flightToken: Int
    let overlays: Overlays
    let report: (String) -> Void

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: styleURL)
        map.delegate = context.coordinator
        map.setCenter(MapTrial.route[0], zoomLevel: 10, animated: false)
        map.logoView.isHidden = true
        map.compassView.isHidden = false
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.parent = self
        if map.styleURL != styleURL { map.styleURL = styleURL }
        if context.coordinator.flown != flightToken, flightToken > 0 {
            context.coordinator.flown = flightToken
            context.coordinator.fly(map)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: PilotMapView
        var flown = 0
        init(_ parent: PilotMapView) { self.parent = parent }

        func mapView(_ map: MLNMapView, didFinishLoading style: MLNStyle) {
            addOverlays(to: style)
        }

        func mapViewDidFinishRenderingFrame(_ map: MLNMapView, fullyRendered: Bool, frameEncodingTime: Double, frameRenderingTime: Double) {
            parent.recorder.frame()
        }

        func mapViewDidBecomeIdle(_ map: MLNMapView) {
            parent.recorder.idle()
        }

        private func addOverlays(to style: MLNStyle) {
            let o = parent.overlays
            // Airspace: translucent fill, coloured edge, as the navigation map draws it.
            var features: [MLNPolygonFeature] = []
            for a in o.airspaces where a.coordinates.count >= 3 {
                var c = a.coordinates
                let f = MLNPolygonFeature(coordinates: &c, count: UInt(c.count))
                f.attributes = ["color": String(format: "#%02x%02x%02x", Int(a.colour.red * 255), Int(a.colour.green * 255), Int(a.colour.blue * 255))]
                features.append(f)
            }
            let airspace = MLNShapeSource(identifier: "airspace", features: features, options: nil)
            style.addSource(airspace)
            let fill = MLNFillStyleLayer(identifier: "airspace-fill", source: airspace)
            fill.fillColor = NSExpression(mglJSONObject: ["to-color", ["get", "color"]])
            fill.fillOpacity = NSExpression(forConstantValue: 0.12)
            style.addLayer(fill)
            let edge = MLNLineStyleLayer(identifier: "airspace-line", source: airspace)
            edge.lineColor = NSExpression(mglJSONObject: ["to-color", ["get", "color"]])
            edge.lineWidth = NSExpression(forConstantValue: 1.5)
            edge.lineOpacity = NSExpression(forConstantValue: 0.85)
            style.addLayer(edge)
            // The route: white casing, magenta core (round 2, R4 A).
            var r = o.route
            let route = MLNShapeSource(identifier: "route", shape: MLNPolylineFeature(coordinates: &r, count: UInt(r.count)), options: nil)
            style.addSource(route)
            let casing = MLNLineStyleLayer(identifier: "route-casing", source: route)
            casing.lineColor = NSExpression(forConstantValue: UIColor.white)
            casing.lineWidth = NSExpression(forConstantValue: 8)
            casing.lineCap = NSExpression(forConstantValue: "round")
            style.addLayer(casing)
            let core = MLNLineStyleLayer(identifier: "route-core", source: route)
            core.lineColor = NSExpression(forConstantValue: UIColor(red: 0.83, green: 0.14, blue: 0.61, alpha: 1))
            core.lineWidth = NSExpression(forConstantValue: 4)
            core.lineCap = NSExpression(forConstantValue: "round")
            style.addLayer(core)
            // Aerodromes: a blue ring and the identifier, upright in track-up.
            let points = o.airports.map { a -> MLNPointFeature in
                let p = MLNPointFeature(); p.coordinate = a.coordinate; p.attributes = ["ident": a.ident]; return p
            }
            let aero = MLNShapeSource(identifier: "aerodromes", features: points, options: nil)
            style.addSource(aero)
            let ring = MLNCircleStyleLayer(identifier: "aerodrome-ring", source: aero)
            ring.circleRadius = NSExpression(forConstantValue: 7)
            ring.circleColor = NSExpression(forConstantValue: UIColor.clear)
            ring.circleStrokeColor = NSExpression(forConstantValue: UIColor(red: 0.17, green: 0.35, blue: 0.66, alpha: 1))
            ring.circleStrokeWidth = NSExpression(forConstantValue: 3)
            style.addLayer(ring)
            let ident = MLNSymbolStyleLayer(identifier: "aerodrome-ident", source: aero)
            ident.text = NSExpression(forKeyPath: "ident")
            ident.textFontNames = NSExpression(forConstantValue: ["Noto Sans Medium"])
            ident.textFontSize = NSExpression(forConstantValue: 13)
            ident.textColor = NSExpression(forConstantValue: UIColor(red: 0.17, green: 0.35, blue: 0.66, alpha: 1))
            ident.textHaloColor = NSExpression(forConstantValue: UIColor.white)
            ident.textHaloWidth = NSExpression(forConstantValue: 1.6)
            ident.textAnchor = NSExpression(forConstantValue: "left")
            ident.textOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0.9, dy: 0)))
            style.addLayer(ident)
        }

        /// The scripted flight: zoom steps at LSZQ (each timed to idle), then the route in track-up at about 11 km
        /// across (MapLibre 12), legs of 8 s, then zoom steps at Samedan. About a minute in all.
        func fly(_ map: MLNMapView) {
            let rec = parent.recorder
            rec.frameMS = []; rec.fills = []; rec.footprints = []; rec.recording = true
            let steps: [(String, () -> Void, TimeInterval)] = MapTrialFlight.steps.map { step in
                switch step {
                case let .zoom(label, at, z):
                    return (label, { map.setCenter(at, zoomLevel: Double(z - 1), direction: 0, animated: false) }, 3)
                case let .leg(label, at, course):
                    return (label, {
                        let cam = MLNMapCamera(lookingAtCenter: at, altitude: map.camera.altitude, pitch: 0, heading: course)
                        if abs(map.zoomLevel - 11) > 0.01 { map.setZoomLevel(11, animated: false) }
                        map.fly(to: cam, withDuration: 2.0, completionHandler: nil)
                    }, 2.2)
                }
            }
            run(steps, map: map, index: 0)
        }

        private func run(_ steps: [(String, () -> Void, TimeInterval)], map: MLNMapView, index: Int) {
            let rec = parent.recorder
            guard index < steps.count else {
                rec.recording = false
                var summary = rec.summary()
                summary["style"] = parent.styleURL.lastPathComponent
                summary["device"] = UIDevice.current.model
                MapTrial.write(summary, to: "results-B.json")
                let fills = rec.fills.map { $0.ms }
                parent.report(String(format: "Done: %d frames, interval p50 %.1f ms, p95 %.1f ms, >34 ms %d; fill median %.0f ms, max %.0f ms; %.0f MB",
                                     summary["frames"] as? Int ?? 0, summary["frame_ms_p50"] as? Double ?? 0,
                                     summary["frame_ms_p95"] as? Double ?? 0, summary["frames_over_34ms"] as? Int ?? 0,
                                     fills.sorted()[fills.count / 2], fills.max() ?? 0, rec.footprints.max() ?? 0))
                return
            }
            let (label, action, wait) = steps[index]
            parent.report("Flying: \(label)")
            rec.startFill(label)
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak map] in
                guard let self, let map else { return }
                rec.footprints.append(MapTrial.footprintMB())
                if rec.fillStarted != nil { rec.fills.append((label + " (not idle)", wait * 1000)); rec.fillStarted = nil }
                self.run(steps, map: map, index: index + 1)
            }
        }
    }

    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDirection {
        let la1 = a.latitude * .pi / 180, la2 = b.latitude * .pi / 180, dl = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dl) * cos(la2), x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dl)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
}

// MARK: - Trial D: MapLibre draws tiles for MapKit, flown the same way

struct PilotTileTrialView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var openAIPDataService: OpenAIPDataService
    @StateObject private var mapState: SharedMapState = {
        let s = SharedMapState()
        s.region = MKCoordinateRegion(center: MapTrial.route[0], span: .init(latitudeDelta: 0.5, longitudeDelta: 0.5))
        s.cameraDistance = 60_000
        return s
    }()
    @State private var polygons: [AirspacePolygon] = []
    @State private var status = "Loading"

    var body: some View {
        ZStack(alignment: .topLeading) {
            AeroMapView(layerType: .standard, mapState: mapState, currentLocation: nil, gpsTrack: [],
                        isFollowingAircraft: .constant(false), forceICAOLayer: false, airspacePolygons: polygons,
                        features: [.airspace])
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 8) {
                Button("Close") { dismiss() }.buttonStyle(.borderedProminent)
                Text(status).font(.system(size: 13, design: .monospaced))
                    .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(.top, 60).padding(.leading, 16)
        }
        .task {
            await openAIPDataService.ensureLoaded()
            polygons = MapTrialFlight.airspaces(openAIPDataService).compactMap { a in
                var c = a.polygonCoordinates
                return c.count >= 3 ? AirspacePolygon(airspace: a, coordinates: &c, count: c.count) : nil
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await fly()
        }
    }

    /// The same steps as B. A zoom step frames the area the iPad shows at that zoom; a leg moves the camera with the
    /// heading set (track-up). After each step: how many tiles MapLibre rendered and when the last one was done.
    private func fly() async {
        let renderer = PilotTileRenderer.shared
        var rows: [[String: Any]] = []
        var footprints: [Double] = []
        for step in MapTrialFlight.steps {
            let started = CACurrentMediaTime()
            renderer.completions = []
            let label: String, wait: Double
            switch step {
            case let .zoom(l, at, z):
                label = l; wait = 3
                let mpp = 156_543.03 * cos(at.latitude * .pi / 180) / pow(2, Double(z))
                let halfLat = 590 * mpp / 111_320, halfLon = 410 * mpp / (111_320 * cos(at.latitude * .pi / 180))
                mapState.cameraHeading = 0
                mapState.pendingFitCoordinates = [.init(latitude: at.latitude + halfLat, longitude: at.longitude - halfLon),
                                                  .init(latitude: at.latitude - halfLat, longitude: at.longitude + halfLon)]
                mapState.pendingFitPadding = .zero
                mapState.objectWillChange.send()
            case let .leg(l, at, course):
                label = l; wait = 2.2
                if mapState.cameraDistance > 30_000 || mapState.cameraDistance < 15_000 { mapState.cameraDistance = 22_000 }
                mapState.cameraHeading = course
                mapState.region = MKCoordinateRegion(center: at, span: mapState.region.span)
            }
            status = "Flying: \(label)"
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            let done = renderer.completions
            let last = done.map(\.at).max().map { ($0 - started) * 1000 } ?? 0
            let ms = done.map(\.ms).sorted()
            rows.append(["step": label, "tiles": done.count, "fill_ms": (last * 10).rounded() / 10,
                         "tile_ms_p50": ms.isEmpty ? 0 : ms[ms.count / 2]])
            footprints.append(MapTrial.footprintMB())
        }
        let all = rows.compactMap { $0["tile_ms_p50"] as? Double }.filter { $0 > 0 }.sorted()
        let zoomFills = rows.filter { ($0["step"] as? String ?? "").contains(" z") }.compactMap { $0["fill_ms"] as? Double }.sorted()
        MapTrial.write(["steps": rows, "footprint_mb_max": footprints.max() ?? 0, "device": UIDevice.current.model,
                        "pool": 3], to: "results-D-flight.json")
        status = String(format: "Done: zoom fills median %.0f ms, max %.0f ms; tile p50 of steps %.0f ms; %.0f MB",
                        zoomFills.isEmpty ? 0 : zoomFills[zoomFills.count / 2], zoomFills.last ?? 0,
                        all.isEmpty ? 0 : all[all.count / 2], footprints.max() ?? 0)
    }
}
#endif
