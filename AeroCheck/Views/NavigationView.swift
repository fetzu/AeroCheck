import SwiftUI
import MapKit
import CoreLocation

// MARK: - Map Layer Types

/// Available map layer types for navigation
enum MapLayerType: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case satellite = "Satellite"
    case icao = "ICAO Chart"
    case landeskarten = "Landeskarten"
    case swissimage = "SWISSIMAGE"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .standard: return "map"
        case .satellite: return "globe.americas"
        case .icao: return "airplane"
        case .landeskarten: return "map.fill"
        case .swissimage: return "photo"
        }
    }

    var description: String {
        switch self {
        case .standard: return "Standard map view"
        case .satellite: return "Satellite imagery"
        case .icao: return "Swiss ICAO aeronautical chart"
        case .landeskarten: return "Swiss national map"
        case .swissimage: return "Swiss aerial imagery"
        }
    }

    /// Whether this layer requires swisstopo tiles
    var isSwissLayer: Bool {
        switch self {
        case .standard, .satellite: return false
        case .icao, .landeskarten, .swissimage: return true
        }
    }

    /// WMTS layer identifier for swisstopo
    var swisstopoLayerIdentifier: String? {
        switch self {
        case .standard, .satellite: return nil
        case .icao: return "ch.bazl.luftfahrtkarten-icao"
        case .landeskarten: return "ch.swisstopo.pixelkarte-farbe"
        case .swissimage: return "ch.swisstopo.swissimage"
        }
    }
}

// MARK: - Navigation Map View

/// Full-screen navigation map view with aircraft position tracking
struct NavigationMapView: View {
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var appState: AppState

    @Binding var isPresented: Bool
    @State private var selectedLayer: MapLayerType = .standard
    @State private var mapCameraPosition: MapCameraPosition = .automatic
    @State private var isFollowingAircraft: Bool = true
    @State private var showLayerPicker: Bool = false

    // Map region for manual control
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 46.8, longitude: 8.2), // Switzerland center
        span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
    )

    var body: some View {
        ZStack {
            // Map content
            mapContent
                .ignoresSafeArea()

            // Overlay controls
            VStack {
                // Top bar with close button and layer picker
                topBar

                Spacer()

                // Bottom controls
                bottomControls
            }
            .padding()
        }
        .preferredColorScheme(.dark)
        .onAppear {
            centerOnAircraft()
        }
        .onChange(of: locationManager.currentLocation) { _, newLocation in
            if isFollowingAircraft, let location = newLocation {
                withAnimation(.easeInOut(duration: 0.3)) {
                    mapCameraPosition = .camera(MapCamera(
                        centerCoordinate: location.coordinate,
                        distance: 10000, // 10km view distance
                        heading: location.course >= 0 ? location.course : 0,
                        pitch: 0
                    ))
                }
            }
        }
    }

    // MARK: - Map Content

    @ViewBuilder
    private var mapContent: some View {
        if selectedLayer.isSwissLayer {
            // Use custom tile overlay for Swiss layers
            SwissMapView(
                layerType: selectedLayer,
                region: $region,
                currentLocation: locationManager.currentLocation,
                gpsTrack: appState.currentFlight?.gpsTrack ?? [],
                isFollowingAircraft: $isFollowingAircraft
            )
        } else {
            // Use native MapKit for standard/satellite
            Map(position: $mapCameraPosition, interactionModes: .all) {
                // Aircraft position marker
                if let location = locationManager.currentLocation {
                    Annotation("Aircraft", coordinate: location.coordinate) {
                        AircraftMarker(
                            heading: location.course >= 0 ? location.course : 0,
                            speed: locationManager.currentSpeedKnots
                        )
                    }
                }

                // GPS track polyline
                if let track = appState.currentFlight?.gpsTrack, track.count > 1 {
                    MapPolyline(coordinates: track.map { $0.coordinate })
                        .stroke(Color.aviationGold, lineWidth: 3)
                }
            }
            .mapStyle(selectedLayer == .satellite ? .imagery : .standard)
            .onMapCameraChange { context in
                // Disable follow mode when user manually pans
                if !isFollowingAircraft { return }
                // This is intentionally empty - we detect manual interaction elsewhere
            }
            .gesture(
                DragGesture()
                    .onChanged { _ in
                        isFollowingAircraft = false
                    }
            )
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            // Close button
            Button(action: { isPresented = false }) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.primaryText)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(Color.panelBackground.opacity(0.9))
                    )
            }

            Spacer()

            // Speed and altitude display
            HStack(spacing: 16) {
                // Speed
                HStack(spacing: 4) {
                    Text("\(Int(locationManager.currentSpeedKnots))")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                    Text("kt")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.aviationGreen)

                // Altitude
                HStack(spacing: 4) {
                    Text("\(Int(locationManager.currentAltitudeFeet))")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                    Text("ft")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.altimeterBlue)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.panelBackground.opacity(0.9))
            )

            Spacer()

            // Layer picker button
            Button(action: { showLayerPicker = true }) {
                HStack(spacing: 6) {
                    Image(systemName: selectedLayer.icon)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.primaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.panelBackground.opacity(0.9))
                )
            }
            .sheet(isPresented: $showLayerPicker) {
                LayerPickerSheet(selectedLayer: $selectedLayer)
            }
        }
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        HStack {
            Spacer()

            // Center on aircraft button
            Button(action: centerOnAircraft) {
                Image(systemName: isFollowingAircraft ? "location.fill" : "location")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(isFollowingAircraft ? .aviationGold : .primaryText)
                    .frame(width: 50, height: 50)
                    .background(
                        Circle()
                            .fill(Color.panelBackground.opacity(0.9))
                    )
            }
        }
    }

    // MARK: - Actions

    private func centerOnAircraft() {
        guard let location = locationManager.currentLocation else { return }

        isFollowingAircraft = true

        if selectedLayer.isSwissLayer {
            // Update region for Swiss map
            region = MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
            )
        } else {
            // Update camera position for MapKit
            withAnimation(.easeInOut(duration: 0.5)) {
                mapCameraPosition = .camera(MapCamera(
                    centerCoordinate: location.coordinate,
                    distance: 10000,
                    heading: location.course >= 0 ? location.course : 0,
                    pitch: 0
                ))
            }
        }
    }
}

// MARK: - Aircraft Marker

struct AircraftMarker: View {
    let heading: Double
    let speed: Double

    var body: some View {
        ZStack {
            // Outer glow
            Circle()
                .fill(Color.aviationGold.opacity(0.3))
                .frame(width: 40, height: 40)

            // Aircraft icon
            Image(systemName: "airplane")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.aviationGold)
                .rotationEffect(.degrees(heading))
                .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
        }
    }
}

// MARK: - Layer Picker Sheet

struct LayerPickerSheet: View {
    @Binding var selectedLayer: MapLayerType
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("Apple Maps") {
                    ForEach([MapLayerType.standard, .satellite]) { layer in
                        layerRow(layer)
                    }
                }

                Section("Swiss Topo") {
                    ForEach([MapLayerType.icao, .landeskarten, .swissimage]) { layer in
                        layerRow(layer)
                    }
                }
            }
            .navigationTitle("Map Layer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }

    private func layerRow(_ layer: MapLayerType) -> some View {
        Button(action: {
            selectedLayer = layer
            dismiss()
        }) {
            HStack {
                Image(systemName: layer.icon)
                    .font(.system(size: 18))
                    .foregroundColor(.aviationGold)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(layer.rawValue)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.primaryText)
                    Text(layer.description)
                        .font(.system(size: 12))
                        .foregroundColor(.secondaryText)
                }

                Spacer()

                if selectedLayer == layer {
                    Image(systemName: "checkmark")
                        .foregroundColor(.aviationGold)
                }
            }
        }
    }
}

// MARK: - Swiss Map View (UIKit Wrapper)

/// UIViewRepresentable wrapper for MKMapView with swisstopo tile overlays
struct SwissMapView: UIViewRepresentable {
    let layerType: MapLayerType
    @Binding var region: MKCoordinateRegion
    let currentLocation: CLLocation?
    let gpsTrack: [GPSPoint]
    @Binding var isFollowingAircraft: Bool

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = false

        // Add gesture recognizer to detect user interaction
        let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        panGesture.delegate = context.coordinator
        mapView.addGestureRecognizer(panGesture)

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Update tile overlay
        updateTileOverlay(mapView)

        // Update region
        if isFollowingAircraft {
            mapView.setRegion(region, animated: true)
        }

        // Update aircraft annotation
        updateAircraftAnnotation(mapView, context: context)

        // Update track overlay
        updateTrackOverlay(mapView, context: context)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Update Methods

    private func updateTileOverlay(_ mapView: MKMapView) {
        // Remove existing tile overlays
        mapView.overlays.forEach { overlay in
            if overlay is MKTileOverlay {
                mapView.removeOverlay(overlay)
            }
        }

        // Add new tile overlay
        if let layerId = layerType.swisstopoLayerIdentifier {
            let overlay = SwisstopoTileOverlay(layerIdentifier: layerId)
            overlay.canReplaceMapContent = true
            mapView.addOverlay(overlay, level: .aboveLabels)
        }
    }

    private func updateAircraftAnnotation(_ mapView: MKMapView, context: Context) {
        // Remove existing aircraft annotations
        mapView.annotations.forEach { annotation in
            if annotation is AircraftAnnotation {
                mapView.removeAnnotation(annotation)
            }
        }

        // Add aircraft annotation
        if let location = currentLocation {
            let annotation = AircraftAnnotation(
                coordinate: location.coordinate,
                heading: location.course >= 0 ? location.course : 0
            )
            mapView.addAnnotation(annotation)
        }
    }

    private func updateTrackOverlay(_ mapView: MKMapView, context: Context) {
        // Remove existing track overlays
        mapView.overlays.forEach { overlay in
            if overlay is MKPolyline {
                mapView.removeOverlay(overlay)
            }
        }

        // Add track overlay
        if gpsTrack.count > 1 {
            let coordinates = gpsTrack.map { $0.coordinate }
            let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            mapView.addOverlay(polyline, level: .aboveRoads)
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: SwissMapView

        init(_ parent: SwissMapView) {
            self.parent = parent
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began {
                parent.isFollowingAircraft = false
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }

            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor(Color.aviationGold)
                renderer.lineWidth = 3
                return renderer
            }

            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let aircraftAnnotation = annotation as? AircraftAnnotation else {
                return nil
            }

            let identifier = "AircraftAnnotation"
            var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)

            if annotationView == nil {
                annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                annotationView?.canShowCallout = false
            }

            // Create aircraft image
            let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)
            let image = UIImage(systemName: "airplane", withConfiguration: config)?
                .withTintColor(UIColor(Color.aviationGold), renderingMode: .alwaysOriginal)

            annotationView?.image = image
            annotationView?.transform = CGAffineTransform(rotationAngle: CGFloat(aircraftAnnotation.heading * .pi / 180))

            // Add shadow
            annotationView?.layer.shadowColor = UIColor.black.cgColor
            annotationView?.layer.shadowOffset = CGSize(width: 0, height: 1)
            annotationView?.layer.shadowOpacity = 0.5
            annotationView?.layer.shadowRadius = 2

            return annotationView
        }
    }
}

// MARK: - Aircraft Annotation

class AircraftAnnotation: NSObject, MKAnnotation {
    var coordinate: CLLocationCoordinate2D
    var heading: Double

    init(coordinate: CLLocationCoordinate2D, heading: Double) {
        self.coordinate = coordinate
        self.heading = heading
        super.init()
    }
}

// MARK: - Swisstopo Tile Overlay

/// Custom tile overlay for swisstopo WMTS layers
class SwisstopoTileOverlay: MKTileOverlay {
    let layerIdentifier: String

    init(layerIdentifier: String) {
        self.layerIdentifier = layerIdentifier

        // Swisstopo WMTS URL template
        // Using the EPSG:3857 (Web Mercator) projection which is compatible with MapKit
        let urlTemplate = "https://wmts.geo.admin.ch/1.0.0/\(layerIdentifier)/default/current/3857/{z}/{x}/{y}.png"

        super.init(urlTemplate: urlTemplate)

        self.minimumZ = 7
        self.maximumZ = 18
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        // Construct the URL for swisstopo tiles
        let urlString = "https://wmts.geo.admin.ch/1.0.0/\(layerIdentifier)/default/current/3857/\(path.z)/\(path.x)/\(path.y).png"
        return URL(string: urlString) ?? URL(string: "about:blank")!
    }
}

// MARK: - Navigation Toggle Button

/// Button to toggle navigation mode from FlightView
struct NavigationModeButton: View {
    @Binding var showNavigation: Bool

    var body: some View {
        Button(action: { showNavigation = true }) {
            HStack(spacing: 6) {
                Image(systemName: "map")
                Text("NAV")
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.aviationBlue, lineWidth: 2)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.aviationBlue.opacity(0.2))
                    )
            )
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationMapView(isPresented: .constant(true))
        .environmentObject(AppState())
        .environmentObject(LocationManager())
}
