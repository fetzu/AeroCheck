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

    /// Minimum zoom level for this layer
    var minimumZoom: Int {
        switch self {
        case .standard, .satellite: return 0
        case .icao: return 7  // ICAO chart has limited zoom range
        case .landeskarten: return 7
        case .swissimage: return 7
        }
    }

    /// Maximum zoom level for this layer
    var maximumZoom: Int {
        switch self {
        case .standard, .satellite: return 20
        case .icao: return 14  // Extended to include Segelflugkarte range
        case .landeskarten: return 18
        case .swissimage: return 18
        }
    }
}

// MARK: - Shared Map State

/// Observable object to share map region state between different map views
class SharedMapState: ObservableObject {
    @Published var region: MKCoordinateRegion
    @Published var cameraDistance: Double = 10000
    @Published var cameraHeading: Double = 0

    init() {
        // Default to Switzerland center
        self.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 46.8, longitude: 8.2),
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        )
    }

    func updateFromRegion(_ newRegion: MKCoordinateRegion) {
        region = newRegion
        // Estimate camera distance from span (rough approximation)
        cameraDistance = newRegion.span.latitudeDelta * 111000.0 / 0.9
    }

    var mapCameraPosition: MapCameraPosition {
        .camera(MapCamera(
            centerCoordinate: region.center,
            distance: cameraDistance,
            heading: cameraHeading,
            pitch: 0
        ))
    }
}

// MARK: - Navigation Map View

/// Full-screen navigation map view with aircraft position tracking
struct NavigationMapView: View {
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var offlineMapManager: OfflineMapManager

    @Binding var isPresented: Bool
    @State private var selectedLayer: MapLayerType = .standard
    @State private var isFollowingAircraft: Bool = true
    @State private var showLayerPicker: Bool = false
    @State private var showCacheInfoModal: Bool = false

    /// Whether offline mode is active
    private var isOfflineMode: Bool {
        appState.settings.offlineMode && offlineMapManager.isCacheAvailable
    }

    /// Whether cache is available but not in offline mode (uses cache opportunistically)
    /// Only true when:
    /// - Not in offline mode
    /// - Cache is available
    /// - ICAO layer is selected
    /// - Either forceICAOChartLayer is ON, or current zoom is within cached range (7-11)
    private var isCachedMode: Bool {
        guard !appState.settings.offlineMode,
              offlineMapManager.isCacheAvailable,
              selectedLayer == .icao else {
            return false
        }
        // If forceICAOChartLayer is ON, we're always using ICAO (and cache)
        if appState.settings.forceICAOChartLayer {
            return true
        }
        // Otherwise, check if current zoom is within cached ICAO range (7-11)
        // At higher zoom levels, Segelflugkarte is used which is not cached
        let currentZoom = estimatedZoomLevel
        return currentZoom <= 11
    }

    /// Estimate current zoom level from map region span
    /// This is used to determine if we're in the cached ICAO range or Segelflugkarte range
    private var estimatedZoomLevel: Int {
        // Calculate zoom level from latitude span
        // At zoom 0, the world is 360° wide; each zoom level halves the span
        let latSpan = mapState.region.span.latitudeDelta
        if latSpan <= 0 { return 11 }
        // Formula: zoom ≈ log2(360 / span)
        let zoom = log2(360.0 / latSpan)
        return Int(zoom.rounded())
    }

    // Shared map state for preserving position between layers
    @StateObject private var mapState = SharedMapState()

    // Timer trigger for time display - use ID to force refresh
    @State private var timeDisplayId = UUID()

    // Create a dedicated timer that fires every second
    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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

    /// Formatted current time - computed fresh each time
    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    /// Current heading from location
    private var currentHeading: Int {
        guard let location = locationManager.currentLocation, location.course >= 0 else {
            return 0
        }
        return Int(location.course)
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

                // Bottom controls with scale bar
                bottomControls
            }
            .padding()
        }
        .preferredColorScheme(.dark)
        .onAppear {
            centerOnAircraft()
            // Force ICAO layer in offline mode
            if isOfflineMode {
                selectedLayer = .icao
            }
        }
        .onReceive(clockTimer) { _ in
            // Force the time display to update by changing its ID
            timeDisplayId = UUID()
        }
        .onChange(of: locationManager.currentLocation) { _, newLocation in
            if isFollowingAircraft, let location = newLocation {
                updateMapStateForLocation(location)
            }
        }
        .onChange(of: selectedLayer) { oldLayer, newLayer in
            // When switching layers, force a tile refresh for Swiss layers
            if newLayer.isSwissLayer {
                // Trigger a small region update to force tile loading
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    let currentRegion = mapState.region
                    mapState.region = MKCoordinateRegion(
                        center: currentRegion.center,
                        span: MKCoordinateSpan(
                            latitudeDelta: currentRegion.span.latitudeDelta * 1.001,
                            longitudeDelta: currentRegion.span.longitudeDelta * 1.001
                        )
                    )
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        mapState.region = currentRegion
                    }
                }
            }
        }
    }

    private func updateMapStateForLocation(_ location: CLLocation) {
        let newRegion = MKCoordinateRegion(
            center: location.coordinate,
            span: mapState.region.span
        )
        mapState.updateFromRegion(newRegion)
        mapState.cameraHeading = location.course >= 0 ? location.course : 0
    }

    // MARK: - Map Content

    @ViewBuilder
    private var mapContent: some View {
        if isOfflineMode || selectedLayer.isSwissLayer {
            // Use custom tile overlay for Swiss layers (or offline mode)
            SwissMapView(
                layerType: isOfflineMode ? .icao : selectedLayer,
                mapState: mapState,
                currentLocation: locationManager.currentLocation,
                gpsTrack: appState.currentFlight?.gpsTrack ?? [],
                isFollowingAircraft: $isFollowingAircraft,
                forceICAOLayer: appState.settings.forceICAOChartLayer || isOfflineMode,
                offlineMapManager: isOfflineMode ? offlineMapManager : nil
            )
        } else {
            // Use UIKit-wrapped MKMapView for standard/satellite to avoid gesture issues
            NativeMapViewUIKit(
                selectedLayer: selectedLayer,
                mapState: mapState,
                currentLocation: locationManager.currentLocation,
                gpsTrack: appState.currentFlight?.gpsTrack ?? [],
                isFollowingAircraft: $isFollowingAircraft
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

            // Time, Speed, Altitude, and Heading display
            HStack(spacing: 16) {
                // Current time - use id to force refresh
                Text(formattedTime)
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundColor(.primaryText)
                    .id(timeDisplayId)

                // Divider
                Rectangle()
                    .fill(Color.dimText)
                    .frame(width: 1, height: 20)

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

                // Heading
                HStack(spacing: 4) {
                    Text(String(format: "%03d", currentHeading))
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                    Text("°")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.aviationGold)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.panelBackground.opacity(0.9))
            )

            Spacer()

            // Layer picker button (shows info modal in offline mode)
            Button(action: {
                if isOfflineMode {
                    showCacheInfoModal = true
                } else {
                    showLayerPicker = true
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: isOfflineMode ? MapLayerType.icao.icon : selectedLayer.icon)
                    if !isOfflineMode {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                    } else {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                    }
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(isOfflineMode ? .secondaryText : .primaryText)
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
            // Left side: Scale bar and cache/offline indicator
            VStack(alignment: .leading, spacing: 8) {
                // Offline/Cached mode indicator
                if isOfflineMode || isCachedMode {
                    Button(action: { showCacheInfoModal = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "internaldrive.fill")
                            Text(isOfflineMode ? "OFFLINE" : "CACHED")
                        }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isOfflineMode ? Color.aviationRed.opacity(0.9) : Color.aviationGold.opacity(0.9))
                        )
                    }
                    .sheet(isPresented: $showCacheInfoModal) {
                        CacheInfoSheet(isOfflineMode: isOfflineMode)
                            .environmentObject(appState)
                            .environmentObject(offlineMapManager)
                    }
                }

                // Scale bar
                SwissScaleBar(region: mapState.region)
            }

            Spacer()

            // Right side: GPS status and center button
            VStack(alignment: .trailing, spacing: 12) {
                // GPS Status
                HStack(spacing: 6) {
                    Text("GPS")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(gpsStatusColor)
                    StatusIndicator(gpsStatusIndicator, size: 8)
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

        // Update shared map state with current location
        let newRegion = MKCoordinateRegion(
            center: location.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        )
        mapState.updateFromRegion(newRegion)
        mapState.cameraHeading = location.course >= 0 ? location.course : 0
        mapState.cameraDistance = 10000
    }
}

// MARK: - Swiss Scale Bar (mimics SwissTopo style)

struct SwissScaleBar: View {
    let region: MKCoordinateRegion

    /// Calculate the appropriate scale distance based on current zoom
    /// Uses proper geodetic distance calculation for accuracy
    private var scaleInfo: (distance: Double, text: String, width: CGFloat) {
        // Get the center of the region
        let centerCoordinate = region.center

        // Use CLLocation's distance calculation for geodetic accuracy
        // Calculate the distance for the full longitude span at the center latitude
        let leftLocation = CLLocation(
            latitude: centerCoordinate.latitude,
            longitude: centerCoordinate.longitude - region.span.longitudeDelta / 2
        )
        let rightLocation = CLLocation(
            latitude: centerCoordinate.latitude,
            longitude: centerCoordinate.longitude + region.span.longitudeDelta / 2
        )

        // Get actual geodetic distance in meters
        let metersInSpan = leftLocation.distance(from: rightLocation)

        // iPad screen width varies, but a typical 11" iPad in landscape is ~1194 points wide
        // The map fills most of the screen, accounting for safe areas (~1100 points effective)
        // This is the key factor - we need to match what the map is actually showing
        let estimatedMapWidthPoints: CGFloat = 1100

        // Calculate meters per screen point
        let metersPerPoint = metersInSpan / Double(estimatedMapWidthPoints)

        // Target scale bar width in points (aim for ~80-100pt)
        let targetBarWidth: CGFloat = 80

        // Calculate how many meters that would represent
        let targetMeters = metersPerPoint * Double(targetBarWidth)

        // Choose appropriate scale - pick the largest round number that fits
        let scales: [(meters: Double, text: String)] = [
            (10, "10 m"),
            (20, "20 m"),
            (50, "50 m"),
            (100, "100 m"),
            (200, "200 m"),
            (500, "500 m"),
            (1000, "1 km"),
            (2000, "2 km"),
            (5000, "5 km"),
            (10000, "10 km"),
            (20000, "20 km"),
            (50000, "50 km"),
            (100000, "100 km"),
            (200000, "200 km")
        ]

        // Find the best scale that fits within our target width
        var selectedScale = scales[0]
        for scale in scales {
            if scale.meters <= targetMeters {
                selectedScale = scale
            } else {
                break
            }
        }

        // Calculate actual width for this scale
        let actualWidth = CGFloat(selectedScale.meters / metersPerPoint)

        return (selectedScale.meters, selectedScale.text, min(max(actualWidth, 40), 150))
    }

    var body: some View {
        let info = scaleInfo

        VStack(alignment: .leading, spacing: 2) {
            // Scale text
            Text(info.text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)

            // Scale bar (L-shaped like SwissTopo)
            HStack(spacing: 0) {
                // Vertical tick on left
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: 8)

                // Horizontal line
                Rectangle()
                    .fill(Color.white)
                    .frame(width: info.width, height: 2)

                // Vertical tick on right
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: 8)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.5))
        )
    }
}

// MARK: - Native Map View (UIKit Wrapper for Standard/Satellite)

/// UIViewRepresentable wrapper for MKMapView - used for Apple Maps layers
/// This avoids the gesture conflict issues that occur with SwiftUI Map
struct NativeMapViewUIKit: UIViewRepresentable {
    let selectedLayer: MapLayerType
    @ObservedObject var mapState: SharedMapState
    let currentLocation: CLLocation?
    let gpsTrack: [GPSPoint]
    @Binding var isFollowingAircraft: Bool

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = false
        mapView.showsScale = false // Use our custom scale bar instead

        // Set map type
        mapView.mapType = selectedLayer == .satellite ? .satellite : .standard

        // Set initial region from shared state
        mapView.setRegion(mapState.region, animated: false)

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Update map type if needed
        let expectedType: MKMapType = selectedLayer == .satellite ? .satellite : .standard
        if mapView.mapType != expectedType {
            mapView.mapType = expectedType
        }

        // Update region from shared state if significantly different
        let regionChanged = !context.coordinator.regionsAreEqual(mapView.region, mapState.region)
        if regionChanged && !context.coordinator.isUserInteracting {
            mapView.setRegion(mapState.region, animated: true)
        }

        // Update aircraft annotation
        updateAircraftAnnotation(mapView, context: context)

        // Update track overlay
        updateTrackOverlay(mapView, context: context)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

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
        // Remove existing polylines
        let existingPolylines = mapView.overlays.compactMap { $0 as? MKPolyline }
        mapView.removeOverlays(existingPolylines)

        // Add track overlay
        if gpsTrack.count > 1 {
            let coordinates = gpsTrack.map { $0.coordinate }
            let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            mapView.addOverlay(polyline, level: .aboveRoads)
        }
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: NativeMapViewUIKit
        var isUserInteracting = false

        init(_ parent: NativeMapViewUIKit) {
            self.parent = parent
        }

        func regionsAreEqual(_ r1: MKCoordinateRegion, _ r2: MKCoordinateRegion) -> Bool {
            let epsilon = 0.0001
            return abs(r1.center.latitude - r2.center.latitude) < epsilon &&
                   abs(r1.center.longitude - r2.center.longitude) < epsilon &&
                   abs(r1.span.latitudeDelta - r2.span.latitudeDelta) < epsilon &&
                   abs(r1.span.longitudeDelta - r2.span.longitudeDelta) < epsilon
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // Check if user is interacting
            if let gestureRecognizers = mapView.subviews.first?.gestureRecognizers {
                for recognizer in gestureRecognizers {
                    if recognizer.state == .began || recognizer.state == .changed {
                        isUserInteracting = true
                        parent.isFollowingAircraft = false
                        return
                    }
                }
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            isUserInteracting = false
            parent.mapState.updateFromRegion(mapView.region)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor(red: 0.85, green: 0.65, blue: 0.2, alpha: 1.0)
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
            let annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            annotationView.canShowCallout = false

            // Bright yellow color for visibility
            let yellowColor = UIColor(red: 1.0, green: 0.85, blue: 0.0, alpha: 1.0)
            let config = UIImage.SymbolConfiguration(pointSize: 30, weight: .bold)

            if let image = UIImage(systemName: "airplane", withConfiguration: config) {
                annotationView.image = image.withTintColor(yellowColor, renderingMode: .alwaysOriginal)
            }

            annotationView.transform = CGAffineTransform(rotationAngle: CGFloat(aircraftAnnotation.heading * .pi / 180))

            // Shadow for visibility
            annotationView.layer.shadowColor = UIColor.black.cgColor
            annotationView.layer.shadowOffset = CGSize(width: 0, height: 2)
            annotationView.layer.shadowOpacity = 0.8
            annotationView.layer.shadowRadius = 4

            // Glow effect
            let glowView = UIView(frame: CGRect(x: -10, y: -10, width: 50, height: 50))
            glowView.backgroundColor = yellowColor.withAlphaComponent(0.4)
            glowView.layer.cornerRadius = 25
            annotationView.insertSubview(glowView, at: 0)
            glowView.center = CGPoint(x: annotationView.bounds.midX, y: annotationView.bounds.midY)

            return annotationView
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
            ScrollView {
                VStack(spacing: 16) {
                    // Apple Maps section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Apple Maps")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondaryText)
                            .textCase(.uppercase)
                            .padding(.horizontal, 20)

                        VStack(spacing: 0) {
                            ForEach([MapLayerType.standard, .satellite]) { layer in
                                layerRow(layer)
                                if layer != .satellite {
                                    Divider()
                                        .padding(.leading, 56)
                                }
                            }
                        }
                        .background(Color.panelBackground)
                        .cornerRadius(12)
                        .padding(.horizontal, 16)
                    }

                    // Swiss Topo section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Swiss Topo")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondaryText)
                            .textCase(.uppercase)
                            .padding(.horizontal, 20)

                        VStack(spacing: 0) {
                            ForEach([MapLayerType.icao, .landeskarten, .swissimage]) { layer in
                                layerRow(layer)
                                if layer != .swissimage {
                                    Divider()
                                        .padding(.leading, 56)
                                }
                            }
                        }
                        .background(Color.panelBackground)
                        .cornerRadius(12)
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 16)
            }
            .background(Color.cockpitBackground)
            .navigationTitle("Map Layer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(480)])
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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Swiss Map View (UIKit Wrapper)

/// UIViewRepresentable wrapper for MKMapView with swisstopo tile overlays
struct SwissMapView: UIViewRepresentable {
    let layerType: MapLayerType
    @ObservedObject var mapState: SharedMapState
    let currentLocation: CLLocation?
    let gpsTrack: [GPSPoint]
    @Binding var isFollowingAircraft: Bool
    let forceICAOLayer: Bool
    var offlineMapManager: OfflineMapManager?

    /// Get the camera zoom range for the current layer
    /// This locks the map view to only allow zooming within the valid tile range
    ///
    /// **IMPORTANT: This is where zoom limits are defined for each layer type.**
    /// Adjust minCenterCoordinateDistance to change max zoom-in level.
    /// Adjust maxCenterCoordinateDistance to change max zoom-out level.
    ///
    private func cameraZoomRange(for layer: MapLayerType, forceICAO: Bool) -> MKMapView.CameraZoomRange {
        // Camera zoom range uses centerCoordinateDistance (meters from camera to ground center)
        // Lower distance = more zoomed in, higher distance = more zoomed out
        //
        // Empirical mapping from tile zoom levels to camera distance:
        // Zoom 7  ≈ 500,000m (country level, very zoomed out)
        // Zoom 8  ≈ 250,000m
        // Zoom 9  ≈ 120,000m
        // Zoom 10 ≈ 60,000m
        // Zoom 11 ≈ 30,000m (ICAO max zoom / Segelflugkarte switch point)
        // Zoom 12 ≈ 15,000m
        // Zoom 13 ≈ 7,500m
        // Zoom 14 ≈ 4,000m (Segelflugkarte max zoom)
        // Zoom 15 ≈ 2,000m
        // Zoom 16 ≈ 1,000m
        // Zoom 17 ≈ 500m
        // Zoom 18 ≈ 300m (Landeskarten/SWISSIMAGE max zoom)

        switch layer {
        case .standard, .satellite:
            // No restrictions for Apple Maps
            return MKMapView.CameraZoomRange(minCenterCoordinateDistance: 100, maxCenterCoordinateDistance: 10_000_000)!

        case .icao:
            if forceICAO {
                // ICAO only: zoom 7-11
                // Lock max zoom at zoom level 11 (~30,000m) - changed/corrected to 135'000m
                return MKMapView.CameraZoomRange(minCenterCoordinateDistance: 135_000, maxCenterCoordinateDistance: 600_000)!
            } else {
                // ICAO + Segelflugkarte: zoom 7-14
                // Lock max zoom at zoom level 14 (~4,000m) - using 5,000m for safety margin - changed/corrected to 65'000m
                return MKMapView.CameraZoomRange(minCenterCoordinateDistance: 65_000, maxCenterCoordinateDistance: 600_000)!
            }

        case .landeskarten:
            // Landeskarten: zoom 7-18
            // Lock max zoom at zoom level 18 (~300m) - using 350m for safety margin - changed/corrected to 1500m
            return MKMapView.CameraZoomRange(minCenterCoordinateDistance: 1_500, maxCenterCoordinateDistance: 600_000)!

        case .swissimage:
            // SWISSIMAGE: zoom 7-18
            // Lock max zoom at zoom level 18 (~300m) - using 350m for safety margin - changed/corrected to 1500m
            return MKMapView.CameraZoomRange(minCenterCoordinateDistance: 1_500, maxCenterCoordinateDistance: 600_000)!
        }
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = false

        // Set zoom range based on layer type
        mapView.cameraZoomRange = cameraZoomRange(for: layerType, forceICAO: forceICAOLayer)

        // Set initial region from shared state
        mapView.setRegion(mapState.region, animated: false)

        // Add initial tile overlay
        addTileOverlay(to: mapView, layerType: layerType, context: context)

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Update tile overlay if layer changed or force setting changed
        let overlayChanged = context.coordinator.updateTileOverlayIfNeeded(
            mapView,
            layerType: layerType,
            forceICAO: forceICAOLayer
        )

        // Always update zoom range to ensure it matches current settings
        // This is important when forceICAOLayer changes from Settings
        let newZoomRange = cameraZoomRange(for: layerType, forceICAO: forceICAOLayer)
        if mapView.cameraZoomRange != newZoomRange {
            mapView.cameraZoomRange = newZoomRange
        }

        // Update region from shared state
        let regionChanged = !context.coordinator.regionsAreEqual(mapView.region, mapState.region)
        if regionChanged || overlayChanged {
            mapView.setRegion(mapState.region, animated: !overlayChanged)

            // Force tile reload after region change for Swiss layers
            if overlayChanged {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    // Trigger a redraw by slightly adjusting the region
                    var adjustedRegion = mapState.region
                    adjustedRegion.span.latitudeDelta *= 1.0001
                    mapView.setRegion(adjustedRegion, animated: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        mapView.setRegion(mapState.region, animated: false)
                    }
                }
            }
        }

        // Update aircraft annotation
        updateAircraftAnnotation(mapView, context: context)

        // Update track overlay
        updateTrackOverlay(mapView, context: context)
    }

    private func addTileOverlay(to mapView: MKMapView, layerType: MapLayerType, context: Context) {
        if layerType == .icao {
            // ICAO layer with seamless Segelflugkarte switching (or offline mode)
            let overlay = ICAOSegelflugkarteTileOverlay(
                forceICAO: forceICAOLayer,
                offlineMapManager: offlineMapManager
            )
            overlay.canReplaceMapContent = true
            mapView.addOverlay(overlay, level: .aboveLabels)
        } else if let layerId = layerType.swisstopoLayerIdentifier {
            let overlay = SwisstopoTileOverlay(
                layerIdentifier: layerId,
                tileExtension: layerType.tileExtension,
                minimumZ: layerType.minimumZoom,
                maximumZ: layerType.maximumZoom
            )
            overlay.canReplaceMapContent = true
            mapView.addOverlay(overlay, level: .aboveLabels)
        }
        context.coordinator.currentLayerType = layerType
        context.coordinator.currentForceICAO = forceICAOLayer
        context.coordinator.offlineMapManager = offlineMapManager
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
        var currentLayerType: MapLayerType?
        var currentForceICAO: Bool = false
        var offlineMapManager: OfflineMapManager?
        private var isUpdatingRegion = false

        init(_ parent: SwissMapView) {
            self.parent = parent
        }

        func regionsAreEqual(_ r1: MKCoordinateRegion, _ r2: MKCoordinateRegion) -> Bool {
            let epsilon = 0.0001
            return abs(r1.center.latitude - r2.center.latitude) < epsilon &&
                   abs(r1.center.longitude - r2.center.longitude) < epsilon &&
                   abs(r1.span.latitudeDelta - r2.span.latitudeDelta) < epsilon &&
                   abs(r1.span.longitudeDelta - r2.span.longitudeDelta) < epsilon
        }

        func updateTileOverlayIfNeeded(_ mapView: MKMapView, layerType: MapLayerType, forceICAO: Bool) -> Bool {
            // Check if we need to update
            let layerChanged = layerType != currentLayerType
            let forceChanged = forceICAO != currentForceICAO

            guard layerChanged || forceChanged else { return false }

            currentLayerType = layerType
            currentForceICAO = forceICAO

            // Remove existing tile overlays
            let existingTileOverlays = mapView.overlays.compactMap { $0 as? MKTileOverlay }
            mapView.removeOverlays(existingTileOverlays)

            // Add new tile overlay
            if layerType == .icao {
                let overlay = ICAOSegelflugkarteTileOverlay(
                    forceICAO: forceICAO,
                    offlineMapManager: offlineMapManager
                )
                overlay.canReplaceMapContent = true
                mapView.addOverlay(overlay, level: .aboveLabels)
            } else if let layerId = layerType.swisstopoLayerIdentifier {
                let overlay = SwisstopoTileOverlay(
                    layerIdentifier: layerId,
                    tileExtension: layerType.tileExtension,
                    minimumZ: layerType.minimumZoom,
                    maximumZ: layerType.maximumZoom
                )
                overlay.canReplaceMapContent = true
                mapView.addOverlay(overlay, level: .aboveLabels)
            }

            return true
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // Check if user is interacting via gesture recognizers
            if let gestureRecognizers = mapView.subviews.first?.gestureRecognizers {
                for recognizer in gestureRecognizers {
                    if recognizer.state == .began || recognizer.state == .changed {
                        parent.isFollowingAircraft = false
                        return
                    }
                }
            }
        }

        // Sync region changes back to shared state
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !isUpdatingRegion else { return }
            isUpdatingRegion = true
            parent.mapState.updateFromRegion(mapView.region)
            isUpdatingRegion = false
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tileOverlay)
                return renderer
            }

            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                // Use explicit UIColor for gold
                renderer.strokeColor = UIColor(red: 0.85, green: 0.65, blue: 0.2, alpha: 1.0)
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

            // Always create fresh annotation view to ensure correct coloring
            let annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            annotationView.canShowCallout = false

            // Create aircraft image with explicit yellow/gold color
            // Using a brighter yellow that's clearly visible on all backgrounds
            let yellowColor = UIColor(red: 1.0, green: 0.85, blue: 0.0, alpha: 1.0)
            let config = UIImage.SymbolConfiguration(pointSize: 30, weight: .bold)

            if let image = UIImage(systemName: "airplane", withConfiguration: config) {
                // Create a new image with the tint color applied
                let coloredImage = image.withTintColor(yellowColor, renderingMode: .alwaysOriginal)
                annotationView.image = coloredImage
            }

            // Apply rotation for heading
            annotationView.transform = CGAffineTransform(rotationAngle: CGFloat(aircraftAnnotation.heading * .pi / 180))

            // Add strong shadow for visibility on all backgrounds
            annotationView.layer.shadowColor = UIColor.black.cgColor
            annotationView.layer.shadowOffset = CGSize(width: 0, height: 2)
            annotationView.layer.shadowOpacity = 0.8
            annotationView.layer.shadowRadius = 4

            // Add background glow circle with bright yellow
            let glowView = UIView(frame: CGRect(x: -10, y: -10, width: 50, height: 50))
            glowView.backgroundColor = yellowColor.withAlphaComponent(0.4)
            glowView.layer.cornerRadius = 25
            annotationView.insertSubview(glowView, at: 0)

            // Center the glow view
            glowView.center = CGPoint(x: annotationView.bounds.midX, y: annotationView.bounds.midY)

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

// MARK: - ICAO + Segelflugkarte Tile Overlay (with seamless switching)

/// Custom tile overlay for Swiss ICAO aeronautical chart with seamless Segelflugkarte switching
/// - ICAO Chart (ch.bazl.luftfahrtkarten-icao): zoom 7-11, scale 1:500,000
/// - Segelflugkarte (ch.bazl.segelflugkarte): zoom 11-14, scale 1:300,000
/// When forceICAO is true, always use ICAO layer even at higher zoom levels
/// When offlineMapManager is provided, use cached tiles from disk
class ICAOSegelflugkarteTileOverlay: MKTileOverlay {
    private let icaoLayerIdentifier = "ch.bazl.luftfahrtkarten-icao"
    private let segelflugkarteLayerIdentifier = "ch.bazl.segelflugkarte"
    let forceICAO: Bool
    weak var offlineMapManager: OfflineMapManager?

    // Zoom level where we switch from ICAO to Segelflugkarte
    // ICAO: zoom 7-11 (1:500,000)
    // Segelflugkarte: zoom 11-14 (1:300,000)
    private let icaoMinZoom = 7
    private let icaoMaxZoom = 11
    private let segelflugkarteMinZoom = 11
    private let segelflugkarteMaxZoom = 14

    init(forceICAO: Bool = false, offlineMapManager: OfflineMapManager? = nil) {
        self.forceICAO = forceICAO
        self.offlineMapManager = offlineMapManager
        // Use a placeholder URL template - we override url(forTilePath:) anyway
        let urlTemplate = "https://wmts.geo.admin.ch/1.0.0/ch.bazl.luftfahrtkarten-icao/default/current/3857/{z}/{x}/{y}.png"
        super.init(urlTemplate: urlTemplate)

        // Set tile overlay zoom constraints to match the camera zoom range
        // This helps MapKit understand the valid tile range
        self.minimumZ = icaoMinZoom
        // In offline mode, only ICAO tiles are available (no Segelflugkarte)
        self.maximumZ = (offlineMapManager != nil || forceICAO) ? icaoMaxZoom : segelflugkarteMaxZoom
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let z = path.z
        let clampedZ = min(max(z, icaoMinZoom), icaoMaxZoom)

        // Check for offline cached tile first
        if let manager = offlineMapManager,
           let cachedURL = manager.cachedTileURL(z: clampedZ, x: path.x, y: path.y) {
            return cachedURL
        }

        // Online mode - determine which layer to use based on zoom level and force setting
        let layerIdentifier: String
        let finalZ: Int
        let tileExtension = "png"

        if forceICAO || offlineMapManager != nil {
            // Force ICAO at all zoom levels - clamp to ICAO's valid range
            layerIdentifier = icaoLayerIdentifier
            finalZ = clampedZ
        } else {
            // Seamless switching between ICAO and Segelflugkarte
            if z <= icaoMaxZoom {
                // Use ICAO chart for lower zoom levels
                layerIdentifier = icaoLayerIdentifier
                finalZ = min(max(z, icaoMinZoom), icaoMaxZoom)
            } else {
                // Use Segelflugkarte for higher zoom levels
                layerIdentifier = segelflugkarteLayerIdentifier
                finalZ = min(max(z, segelflugkarteMinZoom), segelflugkarteMaxZoom)
            }
        }

        let urlString = "https://wmts.geo.admin.ch/1.0.0/\(layerIdentifier)/default/current/3857/\(finalZ)/\(path.x)/\(path.y).\(tileExtension)"
        return URL(string: urlString) ?? URL(string: "about:blank")!
    }
}

// MARK: - Swisstopo Tile Overlay

/// Custom tile overlay for swisstopo WMTS layers
class SwisstopoTileOverlay: MKTileOverlay {
    let layerIdentifier: String
    let tileExtension: String
    let validMinZoom: Int
    let validMaxZoom: Int

    init(layerIdentifier: String, tileExtension: String = "png", minimumZ: Int = 7, maximumZ: Int = 18) {
        self.layerIdentifier = layerIdentifier
        self.tileExtension = tileExtension
        self.validMinZoom = minimumZ
        self.validMaxZoom = maximumZ

        // Swisstopo WMTS URL template
        // Using the EPSG:3857 (Web Mercator) projection which is compatible with MapKit
        let urlTemplate = "https://wmts.geo.admin.ch/1.0.0/\(layerIdentifier)/default/current/3857/{z}/{x}/{y}.\(tileExtension)"

        super.init(urlTemplate: urlTemplate)

        // Set proper zoom constraints to match the camera zoom range
        self.minimumZ = minimumZ
        self.maximumZ = maximumZ
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        // Clamp zoom level to valid range for this layer
        let clampedZ = min(max(path.z, validMinZoom), validMaxZoom)

        // Construct the URL for swisstopo tiles
        let urlString = "https://wmts.geo.admin.ch/1.0.0/\(layerIdentifier)/default/current/3857/\(clampedZ)/\(path.x)/\(path.y).\(tileExtension)"
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

// MARK: - Cache Info Sheet

/// Modal sheet explaining cache status and usage
struct CacheInfoSheet: View {
    let isOfflineMode: Bool
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var offlineMapManager: OfflineMapManager
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Header icon
                    Image(systemName: isOfflineMode ? "wifi.slash" : "internaldrive.fill")
                        .font(.system(size: 50))
                        .foregroundColor(isOfflineMode ? .aviationRed : .aviationGold)
                        .padding(.top, 32)

                    // Title
                    Text(isOfflineMode ? "Offline Mode Active" : "Using Cached Map")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.primaryText)

                    // Description
                    VStack(spacing: 12) {
                        if isOfflineMode {
                            Text("The app is currently in offline mode. Map data is being served from the locally cached ICAO Chart.")
                                .font(.system(size: 15))
                                .foregroundColor(.secondaryText)
                                .multilineTextAlignment(.center)

                            Text("Layer switching is disabled in offline mode. Only the ICAO Chart is available.")
                                .font(.system(size: 13))
                                .foregroundColor(.dimText)
                                .multilineTextAlignment(.center)
                        } else {
                            Text("The ICAO Chart is currently being served from your local cache for faster loading.")
                                .font(.system(size: 15))
                                .foregroundColor(.secondaryText)
                                .multilineTextAlignment(.center)

                            Text("The app will use cached tiles when available, and fetch from the network for tiles not in cache.")
                                .font(.system(size: 13))
                                .foregroundColor(.dimText)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal, 24)

                    // Cache info
                    VStack(spacing: 6) {
                        HStack {
                            Text("Cache Version:")
                                .foregroundColor(.secondaryText)
                            Spacer()
                            Text(offlineMapManager.cacheVersion)
                                .foregroundColor(.primaryText)
                        }

                        HStack {
                            Text("Downloaded:")
                                .foregroundColor(.secondaryText)
                            Spacer()
                            Text(offlineMapManager.formattedCacheDate)
                                .foregroundColor(.primaryText)
                        }

                        HStack {
                            Text("Size:")
                                .foregroundColor(.secondaryText)
                            Spacer()
                            Text(offlineMapManager.formattedCacheSize)
                                .foregroundColor(.primaryText)
                        }
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.panelBackground)
                    )
                    .padding(.horizontal, 20)

                    Spacer(minLength: 20)

                    // Action buttons
                    VStack(spacing: 10) {
                        if isOfflineMode {
                            // Go Online button (switches to online mode with cache still active)
                            Button(action: goOnline) {
                                HStack(spacing: 8) {
                                    Image(systemName: "wifi")
                                    Text("Go Online")
                                }
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.aviationGreen)
                                )
                            }
                            .padding(.horizontal, 20)

                            // Done button (secondary)
                            Button(action: { dismiss() }) {
                                Text("Stay Offline")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.secondaryText)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .padding(.horizontal, 20)
                        } else {
                            // Done button
                            Button(action: { dismiss() }) {
                                Text("Done")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color.aviationGold)
                                    )
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
            .background(Color.cockpitBackground)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private func goOnline() {
        // Disable offline mode - cache will still be used opportunistically
        appState.settings.offlineMode = false
        appState.saveSettings()
        dismiss()
    }
}

// MARK: - Preview

#Preview {
    NavigationMapView(isPresented: .constant(true))
        .environmentObject(AppState())
        .environmentObject(LocationManager())
        .environmentObject(OfflineMapManager())
}
