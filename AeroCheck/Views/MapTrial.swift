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

/// Presents trial B over the app when the environment asks for it.
struct MapTrialPresenter: ViewModifier {
    @State private var showing = MapTrial.mode == "B"

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $showing) { PilotMapTrialView() }
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

    func frame(_ encoding: Double, _ rendering: Double) {
        guard recording else { return }
        frameMS.append(encoding + rendering)
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
            "frames_over_16ms": sorted.filter { $0 > 16.7 }.count,
            "frames_over_8ms": sorted.filter { $0 > 8.3 }.count,
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
    private let recorder = MapTrialRecorder()

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let style = MapTrial.styleURL(labels: labels) {
                PilotMapView(styleURL: style, recorder: recorder, flightToken: flight, overlays: overlays()) { status = $0 }
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
            if ProcessInfo.processInfo.environment["AEROCHECK_MAP_TRIAL_AUTOFLY"] != nil {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                flight += 1
            }
        }
    }

    /// What lies over the base map on the in-flight map: the route, the airspace and the aerodromes along it.
    private func overlays() -> PilotMapView.Overlays {
        let region = MKCoordinateRegion(center: .init(latitude: 46.95, longitude: 8.45),
                                        span: .init(latitudeDelta: 1.6, longitudeDelta: 3.6))
        let airspaces = openAIPDataService.airspacesInBounds(region).prefix(300).map {
            (coordinates: $0.polygonCoordinates, colour: $0.mapColor)
        }
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
        map.setCenter(MapTrial.route[0], zoomLevel: 9.5, animated: false)
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
            parent.recorder.frame(frameEncodingTime, frameRenderingTime)
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
            var steps: [(String, () -> Void, TimeInterval)] = []
            let lszq = MapTrial.route[0], lszs = MapTrial.route[2]
            for z in [9.0, 10.0, 11.0, 12.0, 13.0, 15.0] {
                steps.append(("LSZQ z\(Int(z) + 1)", { map.setCenter(lszq, zoomLevel: z, direction: 0, animated: false) }, 3))
            }
            let path = MapTrial.route
            for i in 0..<(path.count - 1) {
                let a = path[i], b = path[i + 1]
                let course = PilotMapView.bearing(a, b)
                for k in 0...4 {
                    let f = Double(k) / 4
                    let p = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * f,
                                                   longitude: a.longitude + (b.longitude - a.longitude) * f)
                    steps.append(("leg \(i + 1) \(k)", {
                        let cam = MLNMapCamera(lookingAtCenter: p, altitude: map.camera.altitude, pitch: 0, heading: course)
                        map.setZoomLevel(11.0, animated: false)
                        map.fly(to: cam, withDuration: 2.0, completionHandler: nil)
                    }, 2.2))
                }
            }
            for z in [12.0, 10.0, 8.0, 13.0] {
                steps.append(("LSZS z\(Int(z) + 1)", { map.setCenter(lszs, zoomLevel: z, direction: 0, animated: false) }, 3))
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
                parent.report(String(format: "Done: %d frames, p50 %.1f ms, p95 %.1f ms, >16 ms %d; fill median %.0f ms, max %.0f ms; %.0f MB",
                                     summary["frames"] as? Int ?? 0, summary["frame_ms_p50"] as? Double ?? 0,
                                     summary["frame_ms_p95"] as? Double ?? 0, summary["frames_over_16ms"] as? Int ?? 0,
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
#endif
