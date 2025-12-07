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

    /// File extension for tiles (some layers only support jpeg)
    var tileExtension: String {
        switch self {
        case .standard, .satellite: return "png"
        case .icao: return "png"
        case .landeskarten, .swissimage: return "jpeg"
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
    @State private var currentTime = Date()

    // Timer for updating time display
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // Map region for manual control
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 46.8, longitude: 8.2), // Switzerland center
        span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
    )

    /// Current target speed from flight phase (if applicable)
    private var targetSpeed: Int? {
        appState.currentPhase.targetSpeed
    }

    /// Stall speed from current aircraft
    private var stallSpeed: Int {
        ChecklistData.currentAircraft.stallSpeed
    }

    /// Speed color based on current speed vs target
    private var speedColor: Color {
        let speedKnots = Int(locationManager.currentSpeedKnots)

        // If below stall speed, always red
        if speedKnots < stallSpeed {
            return .aviationRed
        }

        // If we have a target speed, color based on that
        if let target = targetSpeed {
            if abs(speedKnots - target) <= 5 {
                return .aviationGreen // On target
            } else {
                return .orange // Off target
            }
        }

        // No target speed, use green
        return .aviationGreen
    }

    /// GPS status color
    private var gpsStatusColor: Color {
        guard locationManager.isTracking else { return .dimText }
        switch locationManager.gpsSignalStatus {
        case .good: return .aviationGreen
        case .degraded: return .orange
        case .lost: return .aviationRed
        }
    }

    /// GPS status indicator
    private var gpsStatusIndicator: StatusIndicator.Status {
        guard locationManager.isTracking else { return .inactive }
        switch locationManager.gpsSignalStatus {
        case .good: return .active
        case .degraded: return .warning
        case .lost: return .error
        }
    }

    /// Formatted current time
    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: currentTime)
    }

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
        .onReceive(timer) { time in
            currentTime = time
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
            .mapControls {
                MapScaleView()
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
                // Speed (color-coded based on target)
                HStack(spacing: 4) {
                    Text("\(Int(locationManager.currentSpeedKnots))")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                    Text("kt")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(speedColor)

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
        HStack(alignment: .bottom) {
            // Scale indicator placeholder for Swiss maps (scale is built into SwissMapView)
            if selectedLayer.isSwissLayer {
                Spacer()
                    .frame(width: 100)
            }

            Spacer()

            // Right side: Time, GPS status, and center button
            VStack(alignment: .trailing, spacing: 12) {
                // Time and GPS status
                HStack(spacing: 12) {
                    // GPS Status
                    HStack(spacing: 6) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 12))
                            .foregroundColor(gpsStatusColor)
                        StatusIndicator(gpsStatusIndicator, size: 8)
                    }

                    // Current time
                    Text(formattedTime)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(.primaryText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.panelBackground.opacity(0.9))
                )

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
    @Environment(\.horizontalSizeClass) var horizontalSizeClass

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
            .listStyle(.insetGrouped)
            .navigationTitle("Map Layer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents(horizontalSizeClass == .regular ? [.medium, .large] : [.height(400)])
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
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = false

        // Configure scale view to always show in bottom left
        mapView.showsScale = true

        // Add gesture recognizer to detect user interaction
        let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        panGesture.delegate = context.coordinator
        mapView.addGestureRecognizer(panGesture)

        let pinchGesture = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinchGesture.delegate = context.coordinator
        mapView.addGestureRecognizer(pinchGesture)

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Update tile overlay if layer changed
        context.coordinator.updateTileOverlayIfNeeded(mapView, layerType: layerType)

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

    private func updateAircraftAnnotation(_ mapView: MKMapView, context: Context) {
        // Remove existing aircraft annotations
        let existingAircraftAnnotations = mapView.annotations.compactMap { $0 as? AircraftAnnotation }
        mapView.removeAnnotations(existingAircraftAnnotations)

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
        // Remove existing track overlays (polylines only, not tile overlays)
        let existingPolylines = mapView.overlays.compactMap { $0 as? MKPolyline }
        mapView.removeOverlays(existingPolylines)

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
        private var currentLayerType: MapLayerType?

        init(_ parent: SwissMapView) {
            self.parent = parent
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began {
                parent.isFollowingAircraft = false
            }
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began {
                parent.isFollowingAircraft = false
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }

        func updateTileOverlayIfNeeded(_ mapView: MKMapView, layerType: MapLayerType) {
            // Only update if layer changed
            guard layerType != currentLayerType else { return }
            currentLayerType = layerType

            // Remove existing tile overlays
            let existingTileOverlays = mapView.overlays.compactMap { $0 as? MKTileOverlay }
            mapView.removeOverlays(existingTileOverlays)

            // Add new tile overlay
            if let layerId = layerType.swisstopoLayerIdentifier {
                let overlay = SwisstopoTileOverlay(
                    layerIdentifier: layerId,
                    tileExtension: layerType.tileExtension
                )
                overlay.canReplaceMapContent = true
                mapView.addOverlay(overlay, level: .aboveLabels)
            }
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
            } else {
                annotationView?.annotation = annotation
            }

            // Create aircraft image with aviation gold color
            let config = UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)
            let goldColor = UIColor(red: 0.85, green: 0.65, blue: 0.2, alpha: 1.0) // aviationGold
            let image = UIImage(systemName: "airplane", withConfiguration: config)?
                .withTintColor(goldColor, renderingMode: .alwaysOriginal)

            annotationView?.image = image
            annotationView?.transform = CGAffineTransform(rotationAngle: CGFloat(aircraftAnnotation.heading * .pi / 180))

            // Add shadow
            annotationView?.layer.shadowColor = UIColor.black.cgColor
            annotationView?.layer.shadowOffset = CGSize(width: 0, height: 1)
            annotationView?.layer.shadowOpacity = 0.5
            annotationView?.layer.shadowRadius = 2

            // Add background glow
            if annotationView?.subviews.first(where: { $0.tag == 999 }) == nil {
                let glowView = UIView(frame: CGRect(x: -8, y: -8, width: 40, height: 40))
                glowView.backgroundColor = goldColor.withAlphaComponent(0.3)
                glowView.layer.cornerRadius = 20
                glowView.tag = 999
                annotationView?.insertSubview(glowView, at: 0)
            }

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
    let tileExtension: String

    init(layerIdentifier: String, tileExtension: String = "png") {
        self.layerIdentifier = layerIdentifier
        self.tileExtension = tileExtension

        // Swisstopo WMTS URL template
        // Using the EPSG:3857 (Web Mercator) projection which is compatible with MapKit
        let urlTemplate = "https://wmts.geo.admin.ch/1.0.0/\(layerIdentifier)/default/current/3857/{z}/{x}/{y}.\(tileExtension)"

        super.init(urlTemplate: urlTemplate)

        self.minimumZ = 7
        self.maximumZ = 18
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        // Construct the URL for swisstopo tiles
        let urlString = "https://wmts.geo.admin.ch/1.0.0/\(layerIdentifier)/default/current/3857/\(path.z)/\(path.x)/\(path.y).\(tileExtension)"
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
