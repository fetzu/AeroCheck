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
    // cameraDistance is not @Published - only read when creating a new map view
    var cameraDistance: Double = 10000
    // cameraHeading IS @Published so the compass UI updates in real-time
    // The infinite loop is prevented by checking if the value actually changed
    @Published var cameraHeading: Double = 0
    // Flag to indicate a heading reset was requested (user tapped compass)
    var pendingHeadingReset: Bool = false

    init() {
        // Default to Switzerland center
        self.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 46.8, longitude: 8.2),
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        )
    }

    func updateFromRegion(_ newRegion: MKCoordinateRegion) {
        // Defer state updates to avoid "Publishing changes from within view updates" warning
        DispatchQueue.main.async { [weak self] in
            self?.region = newRegion
        }
    }

    /// Update camera state from an MKMapView's camera
    /// Call this from map delegate to sync distance and heading
    func updateFromCamera(_ camera: MKMapCamera) {
        cameraDistance = camera.centerCoordinateDistance
        // Only update heading if it changed significantly to avoid unnecessary redraws
        if abs(cameraHeading - camera.heading) > 0.1 {
            DispatchQueue.main.async { [weak self] in
                self?.cameraHeading = camera.heading
            }
        }
    }

    /// Request the map to reset heading to north
    func requestHeadingReset() {
        pendingHeadingReset = true
        cameraHeading = 0
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
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @ObservedObject private var marketingProvider = MarketingLocationProvider.shared

    @Binding var isPresented: Bool
    @State private var selectedLayer: MapLayerType = .icao
    @State private var isFollowingAircraft: Bool = true
    @State private var showLayerPicker: Bool = false
    @State private var showCacheInfoModal: Bool = false
    @State private var showFlightPlanning: Bool = false
    @State private var showRadioFrequencyWindow: Bool = false

    /// Whether offline mode is active (requires at least ICAO cache)
    private var isOfflineMode: Bool {
        appState.settings.offlineMode && offlineMapManager.isCacheAvailable
    }

    /// Whether both ICAO and Segelflug are cached for full offline support
    private var hasFullOfflineSupport: Bool {
        offlineMapManager.isCacheAvailable && offlineMapManager.isSegelflugCacheAvailable
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

    // Track actual map width for accurate scale bar
    @State private var mapWidth: CGFloat = 0

    /// GPS track to display - uses marketing path when in marketing mode, otherwise flight track
    private var displayGpsTrack: [GPSPoint] {
        // In marketing mode, convert the marketing path to GPSPoints
        if appState.settings.marketingMode && marketingProvider.isActive {
            return marketingProvider.previousPath.map { coord in
                GPSPoint(
                    latitude: coord.latitude,
                    longitude: coord.longitude,
                    altitude: 0,
                    timestamp: Date(),
                    speed: 0,
                    course: 0
                )
            }
        }
        // Otherwise use the current flight's GPS track
        return appState.currentFlight?.gpsTrack ?? []
    }

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
        guard locationManager.isTracking || locationManager.isLocationUpdatesActive else { return .dimText }
        switch locationManager.gpsSignalStatus {
        case .good: return .aviationGreen
        case .degraded: return .orange
        case .lost: return .aviationRed
        }
    }

    /// GPS status indicator
    private var gpsStatusIndicator: StatusIndicator.Status {
        guard locationManager.isTracking || locationManager.isLocationUpdatesActive else { return .inactive }
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
        if appState.settings.alwaysUseUTC {
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.string(from: Date()) + " (UTC)"
        }
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
        GeometryReader { geometry in
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

                // Flight Plan Overlay (when active)
                if appState.settings.enableFlightPlanning && flightPlanManager.activeFlightPlan != nil {
                    FlightPlanOverlayView(
                        containerSize: geometry.size,
                        radioFrequencyWindowOpen: showRadioFrequencyWindow
                    )
                        .environmentObject(flightPlanManager)
                        .environmentObject(locationManager)
                }

                // Radio Frequency Floating Window
                if showRadioFrequencyWindow {
                    RadioFrequencyOverlayView(
                        isPresented: $showRadioFrequencyWindow,
                        containerSize: geometry.size
                    )
                    .environmentObject(flightPlanManager)
                    .transition(.opacity.combined(with: .scale))
                }
            }
            .onAppear {
                mapWidth = geometry.size.width
            }
            .onChange(of: geometry.size) { _, newSize in
                mapWidth = newSize.width
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Start GPS updates when navigation view opens
            locationManager.startLocationUpdates()
            centerOnAircraft()
        }
        .onDisappear {
            // Stop GPS updates when navigation view closes (if not in a flight)
            locationManager.stopLocationUpdates()
        }
        .onReceive(clockTimer) { _ in
            // Force the time display to update by changing its ID
            timeDisplayId = UUID()
        }
        .onChange(of: locationManager.currentLocation) { _, newLocation in
            if isFollowingAircraft, let location = newLocation {
                updateMapStateForLocation(location)
            }
            // Auto-advance waypoint when within proximity threshold
            if appState.settings.enableFlightPlanning,
               let location = newLocation {
                let clLocation = CLLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                flightPlanManager.autoAdvanceWaypointIfNeeded(
                    currentLocation: clLocation,
                    threshold: appState.settings.waypointProximityThreshold
                )
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
        // Note: Do NOT update cameraHeading here - the map should always stay North-up
        // unless the user manually rotates it. Only user interaction should change heading.
    }

    // MARK: - Map Content

    @ViewBuilder
    private var mapContent: some View {
        // Track the current waypoint index to force map updates when it changes
        // This ensures waypoint checkmarks are refreshed immediately
        let currentWaypointIndex = flightPlanManager.activeFlightPlan?.currentWaypointIndex ?? 0

        if isOfflineMode || selectedLayer.isSwissLayer {
            // Use custom tile overlay for Swiss layers (or offline mode)
            // Always pass offlineMapManager so cache can be used opportunistically
            // In offline mode, only force ICAO if Segelflug cache is not available
            let effectiveForceICAO = appState.settings.forceICAOChartLayer || (isOfflineMode && !hasFullOfflineSupport)
            SwissMapView(
                layerType: isOfflineMode ? .icao : selectedLayer,
                mapState: mapState,
                currentLocation: locationManager.currentLocation,
                gpsTrack: displayGpsTrack,
                isFollowingAircraft: $isFollowingAircraft,
                forceICAOLayer: effectiveForceICAO,
                offlineMapManager: offlineMapManager,
                isStrictOfflineMode: isOfflineMode,
                hasSegelflugCache: offlineMapManager.isSegelflugCacheAvailable,
                activeFlightPlan: flightPlanManager.activeFlightPlan,
                currentWaypointIndex: currentWaypointIndex
            )
        } else {
            // Use UIKit-wrapped MKMapView for standard/satellite to avoid gesture issues
            NativeMapViewUIKit(
                selectedLayer: selectedLayer,
                mapState: mapState,
                currentLocation: locationManager.currentLocation,
                gpsTrack: displayGpsTrack,
                isFollowingAircraft: $isFollowingAircraft,
                activeFlightPlan: flightPlanManager.activeFlightPlan,
                currentWaypointIndex: currentWaypointIndex
            )
        }
    }

    // MARK: - Top Bar

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isCompactWidth: Bool {
        horizontalSizeClass == .compact
    }

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

            // Flight Plan button (when enabled)
            if appState.settings.enableFlightPlanning {
                Button(action: { showFlightPlanning = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "map.fill")
                        if flightPlanManager.activeFlightPlan != nil {
                            Circle()
                                .fill(Color.aviationGreen)
                                .frame(width: 8, height: 8)
                        }
                    }
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(flightPlanManager.activeFlightPlan != nil ? .aviationGreen : .primaryText)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(Color.panelBackground.opacity(0.9))
                    )
                }
                .sheet(isPresented: $showFlightPlanning) {
                    FlightPlanningView()
                        .environmentObject(appState)
                        .environmentObject(flightPlanManager)
                }
            }

            Spacer()

            // Time, Speed, Altitude, and Heading display
            // On iPhone (compact), use stacked layout; on iPad, use horizontal
            if isCompactWidth {
                // Stacked layout for iPhone
                VStack(spacing: 4) {
                    // Time on first row
                    Text(formattedTime)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(.primaryText)
                        .id(timeDisplayId)

                    // Speed, Altitude, Heading on second row
                    HStack(spacing: 10) {
                        // Speed (color-coded based on target)
                        HStack(spacing: 2) {
                            Text("\(Int(locationManager.currentSpeedKnots))")
                                .font(.system(size: 16, weight: .bold, design: .monospaced))
                            Text("kt")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(speedColor)

                        // Altitude
                        HStack(spacing: 2) {
                            Text("\(Int(locationManager.currentAltitudeFeet))")
                                .font(.system(size: 16, weight: .bold, design: .monospaced))
                            Text("ft")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.altimeterBlue)

                        // Heading
                        HStack(spacing: 2) {
                            Text(String(format: "%03d", currentHeading))
                                .font(.system(size: 16, weight: .bold, design: .monospaced))
                            Text("°")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.aviationGold)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.panelBackground.opacity(0.9))
                )
            } else {
                // Horizontal layout for iPad
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
            }

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
                SwissScaleBar(region: mapState.region, mapWidth: mapWidth)
            }

            Spacer()

            // Right side: GPS status, compass and center button
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

                // Radio Frequency button (always shown when flight planning is enabled)
                if appState.settings.enableFlightPlanning {
                    Button(action: { withAnimation { showRadioFrequencyWindow.toggle() } }) {
                        HStack(spacing: 4) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text("FREQ")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(showRadioFrequencyWindow ? .aviationGold : .primaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.panelBackground.opacity(0.9))
                        )
                    }
                }

                // Compass and center button row
                HStack(spacing: 12) {
                    // Compass button - only show when map is rotated
                    if abs(mapState.cameraHeading) > 0.5 {
                        Button(action: resetToNorth) {
                            CompassView(heading: mapState.cameraHeading)
                        }
                        .transition(.scale.combined(with: .opacity))
                    }

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
                .animation(.easeInOut(duration: 0.2), value: mapState.cameraHeading)
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

    private func resetToNorth() {
        // Request the map to reset heading to north
        mapState.requestHeadingReset()
    }
}

// MARK: - Compass View

/// Custom compass button that shows current heading with N indicator and arrow pointing north
struct CompassView: View {
    let heading: Double

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(Color.panelBackground.opacity(0.9))
                .frame(width: 50, height: 50)

            // Rotating compass content (N and arrow)
            // Negative rotation so N points to geographic north
            ZStack {
                // Arrow pointing up (to north)
                VStack(spacing: 0) {
                    // Arrow head
                    Image(systemName: "triangle.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.aviationRed)
                    Spacer()
                }
                .frame(height: 32)

                // N label
                Text("N")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.primaryText)
            }
            .rotationEffect(.degrees(-heading))
        }
    }
}

// MARK: - Radio Frequency Overlay View

/// Floating window showing radio frequencies from the active flight plan
/// Fixed position at bottom-right of the screen
struct RadioFrequencyOverlayView: View {
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var locationManager: LocationManager
    @Binding var isPresented: Bool
    let containerSize: CGSize

    /// Fixed position at middle-right (same area as the flight plan overlay)
    private var fixedPosition: CGPoint {
        let overlayWidth: CGFloat = 220
        let padding: CGFloat = 20
        return CGPoint(
            x: containerSize.width - overlayWidth / 2 - padding,
            y: containerSize.height / 2 // Center vertically (middle-right)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 12))
                Text("RADIO FREQUENCIES")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1)
                Spacer()
                Button(action: { withAnimation { isPresented = false } }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondaryText)
                }
            }
            .foregroundColor(.aviationGold)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.aviationDarkBlue)

            // Frequency list
            ScrollView {
                VStack(spacing: 0) {
                    if let plan = flightPlanManager.activeFlightPlan {
                        let frequenciesWithWaypoints = plan.waypoints.filter { $0.frequency != nil && !$0.frequency!.isEmpty }

                        if frequenciesWithWaypoints.isEmpty {
                            Text("No frequencies in flight plan")
                                .font(.system(size: 12))
                                .foregroundColor(.secondaryText)
                                .padding()
                        } else {
                            ForEach(Array(frequenciesWithWaypoints.enumerated()), id: \.element.id) { index, waypoint in
                                frequencyRow(waypoint: waypoint, isCurrent: plan.currentWaypointIndex == index)

                                if index < frequenciesWithWaypoints.count - 1 {
                                    Divider()
                                        .background(Color.dimText)
                                }
                            }
                        }

                        // Common Swiss frequencies section
                        Divider()
                            .background(Color.dimText)
                            .padding(.vertical, 4)

                        Text("COMMON SWISS FREQUENCIES")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.dimText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)

                        ForEach(SwissCommonFrequency.allCases, id: \.self) { freq in
                            commonFrequencyRow(freq, isHighlighted: shouldHighlightFrequency(freq))
                            if freq != SwissCommonFrequency.allCases.last {
                                Divider()
                                    .background(Color.dimText.opacity(0.5))
                            }
                        }

                        // Nearby Controlled Airspace section
                        if !nearbyCTRs.isEmpty {
                            Divider()
                                .background(Color.dimText)
                                .padding(.vertical, 4)

                            Text("NEARBY CONTROLLED AIRSPACE")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.dimText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)

                            ForEach(nearbyCTRs, id: \.ctr.id) { item in
                                ctrFrequencyRow(item.ctr, distanceNM: item.distanceNM)
                                if item.ctr.id != nearbyCTRs.last?.ctr.id {
                                    Divider()
                                        .background(Color.dimText.opacity(0.5))
                                }
                            }
                        }
                    } else {
                        Text("No active flight plan")
                            .font(.system(size: 12))
                            .foregroundColor(.secondaryText)
                            .padding()
                    }
                }
            }
            .frame(maxHeight: 400)
        }
        .frame(width: 220)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.panelBackground.opacity(0.95))
                .shadow(color: .black.opacity(0.5), radius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.aviationGold.opacity(0.3), lineWidth: 1)
        )
        .position(fixedPosition)
    }

    /// Determine if a common frequency should be highlighted based on aircraft position
    private func shouldHighlightFrequency(_ freq: SwissCommonFrequency) -> Bool {
        guard let location = locationManager.currentLocation else { return false }
        let coord = location.coordinate

        // Use SwissAirspaceSectors to determine which sector the aircraft is in
        let sector = SwissAirspaceSectors.getSector(for: coord)

        switch freq {
        case .zurichInfo:
            return sector == .zurich
        case .genevaInfo:
            return sector == .geneva
        case .fisEast:
            return sector == .zurich || sector == .east
        case .fisWest:
            return sector == .geneva || sector == .west
        case .emergency:
            return false // Emergency frequency is never auto-highlighted
        }
    }

    private func frequencyRow(waypoint: FlightPlanWaypoint, isCurrent: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(waypoint.name.isEmpty ? "Waypoint" : waypoint.name)
                    .font(.system(size: 12, weight: isCurrent ? .bold : .medium))
                    .foregroundColor(isCurrent ? .aviationGold : .primaryText)
                    .lineLimit(1)
                if let callSign = waypoint.callSign, !callSign.isEmpty {
                    Text(callSign)
                        .font(.system(size: 10))
                        .foregroundColor(.secondaryText)
                }
            }
            Spacer()
            Text(waypoint.frequency ?? "")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(isCurrent ? .aviationGreen : .aviationGold)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isCurrent ? Color.aviationGold.opacity(0.1) : Color.clear)
    }

    private func commonFrequencyRow(_ freq: SwissCommonFrequency, isHighlighted: Bool) -> some View {
        HStack {
            Text(freq.name)
                .font(.system(size: 11, weight: isHighlighted ? .semibold : .regular))
                .foregroundColor(isHighlighted ? .primaryText : .secondaryText)
            Spacer()
            Text(freq.frequency)
                .font(.system(size: 12, weight: isHighlighted ? .bold : .medium, design: .monospaced))
                .foregroundColor(isHighlighted ? .aviationGold : .secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHighlighted ? Color.aviationGold.opacity(0.1) : Color.clear)
    }

    /// Get nearby CTRs based on current location
    /// Major airports show up to 15nm, minor airports up to 10nm
    private var nearbyCTRs: [(ctr: SwissCTR, distanceNM: Double)] {
        guard let location = locationManager.currentLocation else { return [] }
        // Get CTRs within display radius, limited to closest 5
        return Array(SwissCTRProximity.getNearbyCTRs(from: location).prefix(5))
    }

    private func ctrFrequencyRow(_ ctr: SwissCTR, distanceNM: Double) -> some View {
        let isNearby = distanceNM <= ctr.radiusNM + 3.0 // Highlight if within CTR + 3nm buffer

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(ctr.name)
                        .font(.system(size: 11, weight: isNearby ? .semibold : .regular))
                        .foregroundColor(isNearby ? .primaryText : .secondaryText)
                    if ctr.isMilitary {
                        Text("MIL")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2))
                            .cornerRadius(3)
                    }
                }
                Text(ctr.callSign)
                    .font(.system(size: 9))
                    .foregroundColor(.dimText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(ctr.frequency)
                    .font(.system(size: 12, weight: isNearby ? .bold : .medium, design: .monospaced))
                    .foregroundColor(isNearby ? .aviationGold : .secondaryText)
                Text(String(format: "%.0fnm", distanceNM))
                    .font(.system(size: 9))
                    .foregroundColor(.dimText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isNearby ? Color.aviationGold.opacity(0.1) : Color.clear)
    }
}

/// Common Swiss aviation frequencies
enum SwissCommonFrequency: CaseIterable {
    case genevaInfo
    case fisWest
    case zurichInfo
    case fisEast
    case emergency

    var name: String {
        switch self {
        case .genevaInfo: return "Geneva Info"
        case .fisWest: return "FIS West"
        case .zurichInfo: return "Zurich Info"
        case .fisEast: return "FIS East"
        case .emergency: return "Emergency"
        }
    }

    var frequency: String {
        switch self {
        case .genevaInfo: return "126.350"
        case .fisWest: return "119.175"
        case .zurichInfo: return "124.700"
        case .fisEast: return "125.225"
        case .emergency: return "121.500"
        }
    }
}

/// Swiss airspace sectors for Info/FIS frequency selection
/// Based on the CTA zones from geocat.ch
enum SwissAirspaceSector {
    case zurich  // Eastern Switzerland - Zurich Info / FIS East
    case geneva  // Western Switzerland - Geneva Info / FIS West
    case east    // Far east - FIS East only (no Info)
    case west    // Far west - FIS West only (no Info)
}

/// Rough polygons for Swiss airspace sectors
/// Based on CTA zones from https://www.geocat.ch/geonetwork/srv/eng/catalog.search#/metadata/5fd1a95b-8f2c-4fff-8038-a7b2922488ad
struct SwissAirspaceSectors {
    /// Get the airspace sector for a given coordinate
    static func getSector(for coordinate: CLLocationCoordinate2D) -> SwissAirspaceSector {
        let lon = coordinate.longitude
        let lat = coordinate.latitude

        // Switzerland approximate bounds
        guard lat >= 45.8 && lat <= 47.9 && lon >= 5.9 && lon <= 10.6 else {
            // Outside Switzerland - default to nearest sector
            if lon < 7.5 {
                return .west
            } else {
                return .east
            }
        }

        // The dividing line between Zurich and Geneva sectors is approximately at 7.5°E longitude
        // This is a simplified approximation of the actual CTA boundaries
        // The actual boundary follows a more complex path through the Alps

        // Main dividing longitude (approximate - based on CTA boundary through Fribourg/Bern area)
        let divisionLongitude: Double = 7.45

        // Zurich Info covers:
        // - East of the dividing line
        // - Includes most of central and eastern Switzerland
        if lon >= divisionLongitude {
            return .zurich
        } else {
            // Geneva Info covers:
            // - West of the dividing line
            // - Includes western Switzerland and parts of the Alps
            return .geneva
        }
    }
}

// MARK: - Swiss CTR (Control Zones) Data

/// Swiss CTR zones with coordinates and frequencies
/// Data from swisstopo / Swiss AIP and IVAO Switzerland
/// FIS Zurich: LSZH, LSZA, LSZB, LSZC, LSZG, LSZR, LSZS, EDNY, LFSB
/// FIS Geneva: LSGG, LSGS, LSGC, LSMP
enum SwissCTR: CaseIterable, Identifiable {
    // FIS Zurich airports
    case zurich           // LSZH - Zurich Airport
    case basel            // LFSB - EuroAirport Basel-Mulhouse-Freiburg
    case lugano           // LSZA - Lugano-Agno
    case bern             // LSZB - Bern-Belp
    case buochs           // LSZC - Buochs (military)
    case grenchen         // LSZG - Grenchen
    case stGallen         // LSZR - St. Gallen-Altenrhein
    case samedan          // LSZS - Samedan/Engadin
    case friedrichshafen  // EDNY - Friedrichshafen (Germany)

    // FIS Geneva airports
    case geneva           // LSGG - Geneva-Cointrin
    case sion             // LSGS - Sion
    case lesEplatures     // LSGC - Les Eplatures (La Chaux-de-Fonds)
    case payerne          // LSMP - Payerne (military)

    var id: String { icaoCode }

    /// ICAO airport code
    var icaoCode: String {
        switch self {
        case .zurich: return "LSZH"
        case .basel: return "LFSB"
        case .lugano: return "LSZA"
        case .bern: return "LSZB"
        case .buochs: return "LSZC"
        case .grenchen: return "LSZG"
        case .stGallen: return "LSZR"
        case .samedan: return "LSZS"
        case .friedrichshafen: return "EDNY"
        case .geneva: return "LSGG"
        case .sion: return "LSGS"
        case .lesEplatures: return "LSGC"
        case .payerne: return "LSMP"
        }
    }

    var name: String {
        switch self {
        case .zurich: return "Zurich"
        case .basel: return "Basel"
        case .lugano: return "Lugano"
        case .bern: return "Bern"
        case .buochs: return "Buochs"
        case .grenchen: return "Grenchen"
        case .stGallen: return "St. Gallen"
        case .samedan: return "Samedan"
        case .friedrichshafen: return "Friedrichshafen"
        case .geneva: return "Geneva"
        case .sion: return "Sion"
        case .lesEplatures: return "Les Eplatures"
        case .payerne: return "Payerne"
        }
    }

    /// Primary frequency (Tower or Info)
    var frequency: String {
        switch self {
        case .zurich: return "118.100"          // Zurich Tower
        case .basel: return "118.300"           // Basel Tower
        case .lugano: return "118.550"          // Lugano Tower
        case .bern: return "126.075"            // Bern Tower
        case .buochs: return "120.425"          // Buochs Tower (military)
        case .grenchen: return "128.525"        // Grenchen Tower
        case .stGallen: return "119.900"        // Altenrhein Tower
        case .samedan: return "135.325"         // Samedan Info
        case .friedrichshafen: return "120.080" // Friedrichshafen Tower
        case .geneva: return "118.700"          // Geneva Tower
        case .sion: return "118.275"            // Sion Tower
        case .lesEplatures: return "118.125"    // Les Eplatures Tower
        case .payerne: return "131.225"         // Payerne Tower (military)
        }
    }

    /// Callsign for the frequency
    var callSign: String {
        switch self {
        case .zurich: return "ZURICH TOWER"
        case .basel: return "BASEL TOWER"
        case .lugano: return "LUGANO TOWER"
        case .bern: return "BERN TOWER"
        case .buochs: return "BUOCHS TOWER"
        case .grenchen: return "GRENCHEN TOWER"
        case .stGallen: return "ALTENRHEIN TOWER"
        case .samedan: return "SAMEDAN INFO"
        case .friedrichshafen: return "FRIEDRICHSHAFEN TWR"
        case .geneva: return "GENEVA TOWER"
        case .sion: return "SION TOWER"
        case .lesEplatures: return "LES EPLATURES TWR"
        case .payerne: return "PAYERNE TOWER"
        }
    }

    /// Center coordinate of the CTR
    var center: CLLocationCoordinate2D {
        switch self {
        case .zurich: return CLLocationCoordinate2D(latitude: 47.4647, longitude: 8.5492)
        case .basel: return CLLocationCoordinate2D(latitude: 47.5896, longitude: 7.5299)
        case .lugano: return CLLocationCoordinate2D(latitude: 46.0040, longitude: 8.9106)
        case .bern: return CLLocationCoordinate2D(latitude: 46.9141, longitude: 7.4975)
        case .buochs: return CLLocationCoordinate2D(latitude: 46.9744, longitude: 8.3969)
        case .grenchen: return CLLocationCoordinate2D(latitude: 47.1815, longitude: 7.4171)
        case .stGallen: return CLLocationCoordinate2D(latitude: 47.4850, longitude: 9.5608)
        case .samedan: return CLLocationCoordinate2D(latitude: 46.5340, longitude: 9.8841)
        case .friedrichshafen: return CLLocationCoordinate2D(latitude: 47.6713, longitude: 9.5115)
        case .geneva: return CLLocationCoordinate2D(latitude: 46.2381, longitude: 6.1089)
        case .sion: return CLLocationCoordinate2D(latitude: 46.2196, longitude: 7.3270)
        case .lesEplatures: return CLLocationCoordinate2D(latitude: 47.0839, longitude: 6.7936)
        case .payerne: return CLLocationCoordinate2D(latitude: 46.8430, longitude: 6.9156)
        }
    }

    /// Approximate radius of the CTR in nautical miles (for proximity detection)
    var radiusNM: Double {
        switch self {
        case .zurich: return 12.0
        case .basel: return 10.0
        case .lugano: return 5.0
        case .bern: return 5.0
        case .buochs: return 3.0
        case .grenchen: return 3.0
        case .stGallen: return 4.0
        case .samedan: return 5.0
        case .friedrichshafen: return 5.0
        case .geneva: return 10.0
        case .sion: return 4.0
        case .lesEplatures: return 3.0
        case .payerne: return 5.0
        }
    }

    /// Whether this is a major airport (for display radius filtering)
    /// Major airports show up to 15nm, minor airports up to 10nm
    var isMajor: Bool {
        switch self {
        case .zurich, .basel, .geneva: return true
        default: return false
        }
    }

    /// Whether this is a military CTR
    var isMilitary: Bool {
        switch self {
        case .buochs, .payerne: return true
        default: return false
        }
    }
}

/// Helper to find nearby CTRs
struct SwissCTRProximity {
    /// Get CTRs within display distance from a location
    /// Major airports (LSZH, LFSB, LSGG) show up to 15nm
    /// Minor airports show up to 10nm
    /// Returns list sorted by distance, closest first
    static func getNearbyCTRs(from location: CLLocation) -> [(ctr: SwissCTR, distanceNM: Double)] {
        var nearby: [(ctr: SwissCTR, distanceNM: Double)] = []

        for ctr in SwissCTR.allCases {
            let ctrLocation = CLLocation(latitude: ctr.center.latitude, longitude: ctr.center.longitude)
            let distanceMeters = location.distance(from: ctrLocation)
            let distanceNM = distanceMeters / 1852.0

            // Major airports show up to 15nm, minor airports up to 10nm
            let displayRadius = ctr.isMajor ? 15.0 : 10.0
            if distanceNM <= displayRadius {
                nearby.append((ctr: ctr, distanceNM: distanceNM))
            }
        }

        return nearby.sorted { $0.distanceNM < $1.distanceNM }
    }

    /// Check if location is inside or very close to a CTR
    static func isNearCTR(_ ctr: SwissCTR, from location: CLLocation) -> Bool {
        let ctrLocation = CLLocation(latitude: ctr.center.latitude, longitude: ctr.center.longitude)
        let distanceMeters = location.distance(from: ctrLocation)
        let distanceNM = distanceMeters / 1852.0

        // Consider "near" if within CTR radius + 3nm buffer
        return distanceNM <= (ctr.radiusNM + 3.0)
    }
}

// MARK: - Swiss Scale Bar (mimics SwissTopo style)

struct SwissScaleBar: View {
    let region: MKCoordinateRegion
    var mapWidth: CGFloat = 0  // Actual map width in points, 0 means use fallback

    /// Calculate the appropriate scale distance based on current zoom
    /// Uses proper geodetic distance calculation for accuracy
    private func scaleInfo(mapWidthPoints: CGFloat) -> (distance: Double, text: String, width: CGFloat) {
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

        // Use actual map width if provided, otherwise estimate based on typical values
        // The map width should be passed from the parent view using GeometryReader
        let effectiveMapWidth: CGFloat = mapWidthPoints > 0 ? mapWidthPoints : 1100

        // Calculate meters per screen point
        let metersPerPoint = metersInSpan / Double(effectiveMapWidth)

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
        GeometryReader { geometry in
            // Get the actual screen width to estimate map width
            // The scale bar is in the bottom left, so we use the full container width
            let mapWidthEstimate = mapWidth > 0 ? mapWidth : geometry.size.width
            let info = scaleInfo(mapWidthPoints: mapWidthEstimate)

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
        .frame(height: 50)  // Fixed height for the scale bar container
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
    var activeFlightPlan: FlightPlan?
    var currentWaypointIndex: Int = 0  // Track separately to force updates

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = false  // Disabled - compass was appearing in wrong position
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = false
        mapView.showsScale = false // Use our custom scale bar instead

        // Set map type
        mapView.mapType = selectedLayer == .satellite ? .satellite : .standard

        // Set initial camera from shared state (preserves heading)
        let camera = MKMapCamera(
            lookingAtCenter: mapState.region.center,
            fromDistance: mapState.cameraDistance,
            pitch: 0,
            heading: mapState.cameraHeading
        )
        mapView.setCamera(camera, animated: false)

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Update map type if needed
        let expectedType: MKMapType = selectedLayer == .satellite ? .satellite : .standard
        if mapView.mapType != expectedType {
            mapView.mapType = expectedType
        }

        // Handle heading reset request (user tapped compass)
        if mapState.pendingHeadingReset {
            mapState.pendingHeadingReset = false
            let camera = MKMapCamera(
                lookingAtCenter: mapView.camera.centerCoordinate,
                fromDistance: mapView.camera.centerCoordinateDistance,
                pitch: 0,
                heading: 0
            )
            mapView.setCamera(camera, animated: true)
            return
        }

        // Update camera from shared state if significantly different (preserves heading)
        let regionChanged = !context.coordinator.regionsAreEqual(mapView.region, mapState.region)
        if regionChanged && !context.coordinator.isUserInteracting {
            let camera = MKMapCamera(
                lookingAtCenter: mapState.region.center,
                fromDistance: mapState.cameraDistance,
                pitch: 0,
                heading: mapState.cameraHeading
            )
            mapView.setCamera(camera, animated: true)
        }

        // Update aircraft annotation
        updateAircraftAnnotation(mapView, context: context)

        // Update track overlay
        updateTrackOverlay(mapView, context: context)

        // Update flight plan overlay
        updateFlightPlanOverlay(mapView, context: context)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func updateFlightPlanOverlay(_ mapView: MKMapView, context: Context) {
        // Remove existing flight plan overlays and annotations
        let existingFlightPlanPolylines = mapView.overlays.compactMap { $0 as? FlightPlanRoutePolyline }
        mapView.removeOverlays(existingFlightPlanPolylines)

        let existingWaypointAnnotations = mapView.annotations.compactMap { $0 as? FlightPlanWaypointAnnotation }
        mapView.removeAnnotations(existingWaypointAnnotations)

        guard let flightPlan = activeFlightPlan, flightPlan.waypoints.count >= 2 else { return }

        let currentWaypointIndex = flightPlan.currentWaypointIndex

        // Draw route segments
        let coordinates = flightPlan.waypoints.map { $0.coordinate }

        // Draw completed segments (dimmed) - use .aboveLabels to ensure visibility over tile overlays
        if currentWaypointIndex > 0 {
            let completedCoords = Array(coordinates.prefix(currentWaypointIndex + 1))
            let completedPolyline = FlightPlanRoutePolyline(coordinates: completedCoords, count: completedCoords.count)
            completedPolyline.isCompletedSegment = true
            mapView.addOverlay(completedPolyline, level: .aboveLabels)
        }

        // Draw remaining segments (bright) - use .aboveLabels to ensure visibility over tile overlays
        if currentWaypointIndex < flightPlan.waypoints.count {
            let remainingCoords = Array(coordinates.suffix(from: currentWaypointIndex))
            let remainingPolyline = FlightPlanRoutePolyline(coordinates: remainingCoords, count: remainingCoords.count)
            remainingPolyline.isCompletedSegment = false
            mapView.addOverlay(remainingPolyline, level: .aboveLabels)
        }

        // Add waypoint annotations
        for (index, waypoint) in flightPlan.waypoints.enumerated() {
            let annotation = FlightPlanWaypointAnnotation(
                coordinate: waypoint.coordinate,
                name: waypoint.name.isEmpty ? "WPT\(index + 1)" : waypoint.name,
                index: index,
                currentIndex: currentWaypointIndex
            )
            mapView.addAnnotation(annotation)
        }
    }

    private func updateAircraftAnnotation(_ mapView: MKMapView, context: Context) {
        let existingAnnotation = mapView.annotations.compactMap { $0 as? AircraftAnnotation }.first

        if let location = currentLocation {
            let newHeading = location.course >= 0 ? location.course : 0

            if let existing = existingAnnotation {
                // Update existing annotation in place to avoid blinking
                let coordChanged = abs(existing.coordinate.latitude - location.coordinate.latitude) > 0.00001 ||
                                   abs(existing.coordinate.longitude - location.coordinate.longitude) > 0.00001
                let headingChanged = abs(existing.heading - newHeading) > 0.5

                if coordChanged || headingChanged {
                    existing.coordinate = location.coordinate
                    existing.heading = newHeading

                    // Update the annotation view's transform for new heading
                    if let view = mapView.view(for: existing) {
                        let headingRadians = (newHeading - 90.0) * .pi / 180.0
                        UIView.animate(withDuration: 0.1) {
                            view.transform = CGAffineTransform(rotationAngle: CGFloat(headingRadians))
                        }
                    }
                }
            } else {
                // No existing annotation, add new one
                let annotation = AircraftAnnotation(
                    coordinate: location.coordinate,
                    heading: newHeading
                )
                mapView.addAnnotation(annotation)
            }
        } else if let existing = existingAnnotation {
            // No location, remove annotation
            mapView.removeAnnotation(existing)
        }
    }

    private func updateTrackOverlay(_ mapView: MKMapView, context: Context) {
        // Only update if track has changed
        let existingPolylines = mapView.overlays.compactMap { $0 as? MKPolyline }

        // Check if we need to update (different point count)
        let needsUpdate = existingPolylines.first?.pointCount != gpsTrack.count

        if needsUpdate {
            mapView.removeOverlays(existingPolylines)

            if gpsTrack.count > 1 {
                let coordinates = gpsTrack.map { $0.coordinate }
                let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
                // Use .aboveLabels for GPS track to ensure visibility over tile overlays
                mapView.addOverlay(polyline, level: .aboveLabels)
            }
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
            // Sync camera distance and heading so they're preserved when switching layers
            parent.mapState.updateFromCamera(mapView.camera)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            // Flight plan route (magenta - high visibility on aviation charts)
            if let flightPlanPolyline = overlay as? FlightPlanRoutePolyline {
                let renderer = MKPolylineRenderer(polyline: flightPlanPolyline)
                if flightPlanPolyline.isCompletedSegment {
                    // Completed segments - dimmed magenta
                    renderer.strokeColor = UIColor(red: 0.8, green: 0.2, blue: 0.6, alpha: 0.5)
                    renderer.lineWidth = 4
                } else {
                    // Active/remaining segments - bright magenta with black outline effect
                    renderer.strokeColor = UIColor(red: 1.0, green: 0.0, blue: 0.8, alpha: 1.0)
                    renderer.lineWidth = 5
                }
                renderer.lineDashPattern = nil // Solid line
                return renderer
            }

            // GPS track (gold)
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor(red: 0.85, green: 0.65, blue: 0.2, alpha: 1.0)
                renderer.lineWidth = 3
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            // Handle flight plan waypoint annotations
            if let waypointAnnotation = annotation as? FlightPlanWaypointAnnotation {
                return createWaypointAnnotationView(mapView, annotation: waypointAnnotation)
            }

            // Handle aircraft annotation
            guard let aircraftAnnotation = annotation as? AircraftAnnotation else {
                return nil
            }

            let identifier = "AircraftAnnotation"
            let annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            annotationView.canShowCallout = false

            // Create aircraft marker with outline for visibility on all map backgrounds
            // Following aviation UI/UX best practices: high contrast with dark outline
            let aviationGold = UIColor(red: 0.85, green: 0.65, blue: 0.2, alpha: 1.0)
            let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .bold)

            if let image = UIImage(systemName: "airplane", withConfiguration: config) {
                // Create image with stroke outline for better visibility
                let strokeColor = UIColor.black
                let strokeWidth: CGFloat = 2.0
                let imageSize = CGSize(width: image.size.width + strokeWidth * 2,
                                       height: image.size.height + strokeWidth * 2)

                UIGraphicsBeginImageContextWithOptions(imageSize, false, 0)
                defer { UIGraphicsEndImageContext() }

                // Draw stroke (multiple offset copies create outline effect)
                let offsets: [CGPoint] = [
                    CGPoint(x: -strokeWidth, y: 0),
                    CGPoint(x: strokeWidth, y: 0),
                    CGPoint(x: 0, y: -strokeWidth),
                    CGPoint(x: 0, y: strokeWidth),
                    CGPoint(x: -strokeWidth * 0.7, y: -strokeWidth * 0.7),
                    CGPoint(x: strokeWidth * 0.7, y: -strokeWidth * 0.7),
                    CGPoint(x: -strokeWidth * 0.7, y: strokeWidth * 0.7),
                    CGPoint(x: strokeWidth * 0.7, y: strokeWidth * 0.7)
                ]

                let tintedStroke = image.withTintColor(strokeColor, renderingMode: .alwaysOriginal)
                for offset in offsets {
                    tintedStroke.draw(at: CGPoint(x: strokeWidth + offset.x, y: strokeWidth + offset.y))
                }

                // Draw main icon on top
                let tintedImage = image.withTintColor(aviationGold, renderingMode: .alwaysOriginal)
                tintedImage.draw(at: CGPoint(x: strokeWidth, y: strokeWidth))

                if let finalImage = UIGraphicsGetImageFromCurrentImageContext() {
                    annotationView.image = finalImage
                }
            }

            // Apply rotation for heading
            // SF Symbol "airplane" points to the right (90°/East) by default
            // Subtract 90° so that heading 0° (North) shows plane pointing up
            let headingRadians = (aircraftAnnotation.heading - 90.0) * .pi / 180.0
            annotationView.transform = CGAffineTransform(rotationAngle: CGFloat(headingRadians))

            // Additional shadow for depth
            annotationView.layer.shadowColor = UIColor.black.cgColor
            annotationView.layer.shadowOffset = CGSize(width: 0, height: 2)
            annotationView.layer.shadowOpacity = 0.5
            annotationView.layer.shadowRadius = 3

            return annotationView
        }

        /// Create annotation view for flight plan waypoints
        private func createWaypointAnnotationView(_ mapView: MKMapView, annotation: FlightPlanWaypointAnnotation) -> MKAnnotationView {
            let identifier = "FlightPlanWaypoint"
            let annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            annotationView.canShowCallout = true

            // Waypoint appearance based on state
            let size: CGFloat = 24
            let markerColor: UIColor
            let iconName: String

            if annotation.isCurrentWaypoint {
                // Current/next waypoint - bright magenta with target icon
                markerColor = UIColor(red: 1.0, green: 0.0, blue: 0.8, alpha: 1.0)
                iconName = "target"
            } else if annotation.isCompletedWaypoint {
                // Completed waypoint - dimmed with checkmark
                markerColor = UIColor(red: 0.6, green: 0.3, blue: 0.5, alpha: 0.7)
                iconName = "checkmark.circle.fill"
            } else {
                // Future waypoint - medium brightness
                markerColor = UIColor(red: 0.9, green: 0.4, blue: 0.7, alpha: 0.9)
                iconName = "circle.fill"
            }

            // Create the waypoint marker image
            let config = UIImage.SymbolConfiguration(pointSize: size, weight: .bold)
            if let image = UIImage(systemName: iconName, withConfiguration: config) {
                // Create image with black outline for visibility
                let strokeWidth: CGFloat = 2.0
                let imageSize = CGSize(width: image.size.width + strokeWidth * 2,
                                       height: image.size.height + strokeWidth * 2)

                UIGraphicsBeginImageContextWithOptions(imageSize, false, 0)
                defer { UIGraphicsEndImageContext() }

                // Draw black outline
                let offsets: [CGPoint] = [
                    CGPoint(x: -strokeWidth, y: 0),
                    CGPoint(x: strokeWidth, y: 0),
                    CGPoint(x: 0, y: -strokeWidth),
                    CGPoint(x: 0, y: strokeWidth)
                ]

                let strokeImage = image.withTintColor(.black, renderingMode: .alwaysOriginal)
                for offset in offsets {
                    strokeImage.draw(at: CGPoint(x: strokeWidth + offset.x, y: strokeWidth + offset.y))
                }

                // Draw main colored icon
                let tintedImage = image.withTintColor(markerColor, renderingMode: .alwaysOriginal)
                tintedImage.draw(at: CGPoint(x: strokeWidth, y: strokeWidth))

                if let finalImage = UIGraphicsGetImageFromCurrentImageContext() {
                    annotationView.image = finalImage
                }
            }

            // Add shadow
            annotationView.layer.shadowColor = UIColor.black.cgColor
            annotationView.layer.shadowOffset = CGSize(width: 0, height: 2)
            annotationView.layer.shadowOpacity = 0.5
            annotationView.layer.shadowRadius = 2

            return annotationView
        }
    }
}

// MARK: - Aircraft Marker

struct AircraftMarker: View {
    let heading: Double
    let speed: Double

    var body: some View {
        // Aircraft marker with outline for visibility on all map backgrounds
        // SF Symbol "airplane" points to the right (90°/East) by default
        // Subtract 90° so that heading 0° (North) shows plane pointing up
        ZStack {
            // Black outline (drawn multiple times offset to create stroke effect)
            ForEach(0..<8, id: \.self) { i in
                let angle = Double(i) * .pi / 4
                let offset: CGFloat = 1.5
                Image(systemName: "airplane")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.black)
                    .offset(x: cos(angle) * offset, y: sin(angle) * offset)
            }
            // Main gold icon
            Image(systemName: "airplane")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.aviationGold)
        }
        .rotationEffect(.degrees(heading - 90.0))
        .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 2)
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

                    // swisstopo section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("swisstopo")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondaryText)
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
    var isStrictOfflineMode: Bool = false
    var hasSegelflugCache: Bool = false
    var activeFlightPlan: FlightPlan?
    var currentWaypointIndex: Int = 0  // Track separately to force updates

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
                // minCenterCoordinateDistance empirically tuned to prevent zooming past available tiles
                return MKMapView.CameraZoomRange(minCenterCoordinateDistance: 135_000, maxCenterCoordinateDistance: 600_000)!
            } else {
                // ICAO + Segelflugkarte: zoom 7-14
                // minCenterCoordinateDistance empirically tuned to prevent zooming past available tiles
                return MKMapView.CameraZoomRange(minCenterCoordinateDistance: 65_000, maxCenterCoordinateDistance: 600_000)!
            }

        case .landeskarten:
            // Landeskarten: zoom 7-18
            // minCenterCoordinateDistance empirically tuned to prevent zooming past available tiles
            return MKMapView.CameraZoomRange(minCenterCoordinateDistance: 1_500, maxCenterCoordinateDistance: 600_000)!

        case .swissimage:
            // SWISSIMAGE: zoom 7-18
            // minCenterCoordinateDistance empirically tuned to prevent zooming past available tiles
            return MKMapView.CameraZoomRange(minCenterCoordinateDistance: 1_500, maxCenterCoordinateDistance: 600_000)!
        }
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = false  // Disabled - compass was appearing in wrong position
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = false

        // Set zoom range based on layer type
        let zoomRange = cameraZoomRange(for: layerType, forceICAO: forceICAOLayer)
        mapView.cameraZoomRange = zoomRange

        // Add tile overlay
        addTileOverlay(to: mapView, layerType: layerType, context: context)

        // Set initial camera from shared state (preserves heading)
        let camera = MKMapCamera(
            lookingAtCenter: mapState.region.center,
            fromDistance: mapState.cameraDistance,
            pitch: 0,
            heading: mapState.cameraHeading
        )
        mapView.setCamera(camera, animated: false)

        // WORKAROUND for iPad-specific bug: Force a complete layer cycle after initial setup.
        // On iPad, the initial tile overlay doesn't properly respect zoom constraints until
        // a layer switch occurs. We simulate this by briefly switching to a different layer
        // configuration and back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Remove existing overlay
            let existingTileOverlays = mapView.overlays.compactMap { $0 as? MKTileOverlay }
            mapView.removeOverlays(existingTileOverlays)

            // Briefly set a different zoom range (like switching to Landeskarten)
            mapView.cameraZoomRange = MKMapView.CameraZoomRange(
                minCenterCoordinateDistance: 1_500,
                maxCenterCoordinateDistance: 600_000
            )

            // Now switch back to ICAO configuration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                // Set correct zoom range
                mapView.cameraZoomRange = zoomRange

                // Re-add the overlay
                if self.layerType == .icao {
                    let overlay = ICAOSegelflugkarteTileOverlay(
                        forceICAO: self.forceICAOLayer,
                        offlineMapManager: self.offlineMapManager,
                        isStrictOfflineMode: self.isStrictOfflineMode,
                        hasSegelflugCache: self.hasSegelflugCache
                    )
                    overlay.canReplaceMapContent = true
                    mapView.addOverlay(overlay, level: .aboveLabels)
                } else if let layerId = self.layerType.swisstopoLayerIdentifier {
                    let overlay = SwisstopoTileOverlay(
                        layerIdentifier: layerId,
                        tileExtension: self.layerType.tileExtension,
                        minimumZ: self.layerType.minimumZoom,
                        maximumZ: self.layerType.maximumZoom
                    )
                    overlay.canReplaceMapContent = true
                    mapView.addOverlay(overlay, level: .aboveLabels)
                }

                // Force camera update like updateUIView does after overlay change (preserves heading)
                let adjustedCamera = MKMapCamera(
                    lookingAtCenter: self.mapState.region.center,
                    fromDistance: self.mapState.cameraDistance * 1.0001,
                    pitch: 0,
                    heading: self.mapState.cameraHeading
                )
                mapView.setCamera(adjustedCamera, animated: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    let camera = MKMapCamera(
                        lookingAtCenter: self.mapState.region.center,
                        fromDistance: self.mapState.cameraDistance,
                        pitch: 0,
                        heading: self.mapState.cameraHeading
                    )
                    mapView.setCamera(camera, animated: false)
                }
            }
        }

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Handle heading reset request (user tapped compass)
        if mapState.pendingHeadingReset {
            mapState.pendingHeadingReset = false
            let camera = MKMapCamera(
                lookingAtCenter: mapView.camera.centerCoordinate,
                fromDistance: mapView.camera.centerCoordinateDistance,
                pitch: 0,
                heading: 0
            )
            mapView.setCamera(camera, animated: true)
            return
        }

        // Update tile overlay if layer changed or force setting changed
        let overlayChanged = context.coordinator.updateTileOverlayIfNeeded(
            mapView,
            layerType: layerType,
            forceICAO: forceICAOLayer,
            strictOffline: isStrictOfflineMode,
            segelflugCache: hasSegelflugCache
        )

        // Always update zoom range to ensure it matches current settings
        // This is important when forceICAOLayer changes from Settings
        let newZoomRange = cameraZoomRange(for: layerType, forceICAO: forceICAOLayer)
        if mapView.cameraZoomRange != newZoomRange {
            mapView.cameraZoomRange = newZoomRange
        }

        // Update camera from shared state (preserves heading)
        let regionChanged = !context.coordinator.regionsAreEqual(mapView.region, mapState.region)
        if regionChanged || overlayChanged {
            let camera = MKMapCamera(
                lookingAtCenter: mapState.region.center,
                fromDistance: mapState.cameraDistance,
                pitch: 0,
                heading: mapState.cameraHeading
            )
            mapView.setCamera(camera, animated: !overlayChanged)

            // Force tile reload after overlay change for Swiss layers
            if overlayChanged {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    // Trigger a redraw by slightly adjusting the camera distance
                    let adjustedCamera = MKMapCamera(
                        lookingAtCenter: mapState.region.center,
                        fromDistance: mapState.cameraDistance * 1.0001,
                        pitch: 0,
                        heading: mapState.cameraHeading
                    )
                    mapView.setCamera(adjustedCamera, animated: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        mapView.setCamera(camera, animated: false)
                    }
                }
            }
        }

        // Update aircraft annotation
        updateAircraftAnnotation(mapView, context: context)

        // Update track overlay
        updateTrackOverlay(mapView, context: context)

        // Update flight plan overlay
        updateFlightPlanOverlay(mapView, context: context)
    }

    private func updateFlightPlanOverlay(_ mapView: MKMapView, context: Context) {
        // Remove existing flight plan overlays and annotations
        let existingFlightPlanPolylines = mapView.overlays.compactMap { $0 as? FlightPlanRoutePolyline }
        mapView.removeOverlays(existingFlightPlanPolylines)

        let existingWaypointAnnotations = mapView.annotations.compactMap { $0 as? FlightPlanWaypointAnnotation }
        mapView.removeAnnotations(existingWaypointAnnotations)

        guard let flightPlan = activeFlightPlan, flightPlan.waypoints.count >= 2 else { return }

        let currentWaypointIndex = flightPlan.currentWaypointIndex

        // Draw route segments
        let coordinates = flightPlan.waypoints.map { $0.coordinate }

        // Draw completed segments (dimmed) - use .aboveLabels to ensure visibility over tile overlays
        if currentWaypointIndex > 0 {
            let completedCoords = Array(coordinates.prefix(currentWaypointIndex + 1))
            let completedPolyline = FlightPlanRoutePolyline(coordinates: completedCoords, count: completedCoords.count)
            completedPolyline.isCompletedSegment = true
            mapView.addOverlay(completedPolyline, level: .aboveLabels)
        }

        // Draw remaining segments (bright) - use .aboveLabels to ensure visibility over tile overlays
        if currentWaypointIndex < flightPlan.waypoints.count {
            let remainingCoords = Array(coordinates.suffix(from: currentWaypointIndex))
            let remainingPolyline = FlightPlanRoutePolyline(coordinates: remainingCoords, count: remainingCoords.count)
            remainingPolyline.isCompletedSegment = false
            mapView.addOverlay(remainingPolyline, level: .aboveLabels)
        }

        // Add waypoint annotations
        for (index, waypoint) in flightPlan.waypoints.enumerated() {
            let annotation = FlightPlanWaypointAnnotation(
                coordinate: waypoint.coordinate,
                name: waypoint.name.isEmpty ? "WPT\(index + 1)" : waypoint.name,
                index: index,
                currentIndex: currentWaypointIndex
            )
            mapView.addAnnotation(annotation)
        }
    }

    private func addTileOverlay(to mapView: MKMapView, layerType: MapLayerType, context: Context) {
        if layerType == .icao {
            // ICAO layer with seamless Segelflugkarte switching (or offline mode)
            let overlay = ICAOSegelflugkarteTileOverlay(
                forceICAO: forceICAOLayer,
                offlineMapManager: offlineMapManager,
                isStrictOfflineMode: isStrictOfflineMode,
                hasSegelflugCache: hasSegelflugCache
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
        context.coordinator.isStrictOfflineMode = isStrictOfflineMode
        context.coordinator.hasSegelflugCache = hasSegelflugCache
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Update Methods

    private func updateAircraftAnnotation(_ mapView: MKMapView, context: Context) {
        let existingAnnotation = mapView.annotations.compactMap { $0 as? AircraftAnnotation }.first

        if let location = currentLocation {
            let newHeading = location.course >= 0 ? location.course : 0

            if let existing = existingAnnotation {
                // Update existing annotation in place to avoid blinking
                let coordChanged = abs(existing.coordinate.latitude - location.coordinate.latitude) > 0.00001 ||
                                   abs(existing.coordinate.longitude - location.coordinate.longitude) > 0.00001
                let headingChanged = abs(existing.heading - newHeading) > 0.5

                if coordChanged || headingChanged {
                    existing.coordinate = location.coordinate
                    existing.heading = newHeading

                    // Update the annotation view's transform for new heading
                    if let view = mapView.view(for: existing) {
                        let headingRadians = (newHeading - 90.0) * .pi / 180.0
                        UIView.animate(withDuration: 0.1) {
                            view.transform = CGAffineTransform(rotationAngle: CGFloat(headingRadians))
                        }
                    }
                }
            } else {
                // No existing annotation, add new one
                let annotation = AircraftAnnotation(
                    coordinate: location.coordinate,
                    heading: newHeading
                )
                mapView.addAnnotation(annotation)
            }
        } else if let existing = existingAnnotation {
            // No location, remove annotation
            mapView.removeAnnotation(existing)
        }
    }

    private func updateTrackOverlay(_ mapView: MKMapView, context: Context) {
        // Only update if track has changed
        let existingPolylines = mapView.overlays.compactMap { $0 as? MKPolyline }

        // Check if we need to update (different point count)
        let needsUpdate = existingPolylines.first?.pointCount != gpsTrack.count

        if needsUpdate {
            mapView.removeOverlays(existingPolylines)

            if gpsTrack.count > 1 {
                let coordinates = gpsTrack.map { $0.coordinate }
                let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
                // Use .aboveLabels for GPS track to ensure visibility over tile overlays
                mapView.addOverlay(polyline, level: .aboveLabels)
            }
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: SwissMapView
        var currentLayerType: MapLayerType?
        var currentForceICAO: Bool = false
        var offlineMapManager: OfflineMapManager?
        var isStrictOfflineMode: Bool = false
        var hasSegelflugCache: Bool = false
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

        func updateTileOverlayIfNeeded(_ mapView: MKMapView, layerType: MapLayerType, forceICAO: Bool, strictOffline: Bool, segelflugCache: Bool) -> Bool {
            // Check if we need to update
            let layerChanged = layerType != currentLayerType
            let forceChanged = forceICAO != currentForceICAO
            let offlineChanged = strictOffline != isStrictOfflineMode
            let segelflugCacheChanged = segelflugCache != hasSegelflugCache

            guard layerChanged || forceChanged || offlineChanged || segelflugCacheChanged else { return false }

            currentLayerType = layerType
            currentForceICAO = forceICAO
            isStrictOfflineMode = strictOffline
            hasSegelflugCache = segelflugCache

            // Remove existing tile overlays
            let existingTileOverlays = mapView.overlays.compactMap { $0 as? MKTileOverlay }
            mapView.removeOverlays(existingTileOverlays)

            // Add new tile overlay
            if layerType == .icao {
                let overlay = ICAOSegelflugkarteTileOverlay(
                    forceICAO: forceICAO,
                    offlineMapManager: offlineMapManager,
                    isStrictOfflineMode: strictOffline,
                    hasSegelflugCache: segelflugCache
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
            // Sync camera distance and heading so they're preserved when switching layers
            parent.mapState.updateFromCamera(mapView.camera)
            isUpdatingRegion = false
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tileOverlay)
                return renderer
            }

            // Flight plan route (magenta - high visibility on aviation charts)
            if let flightPlanPolyline = overlay as? FlightPlanRoutePolyline {
                let renderer = MKPolylineRenderer(polyline: flightPlanPolyline)
                if flightPlanPolyline.isCompletedSegment {
                    // Completed segments - dimmed magenta
                    renderer.strokeColor = UIColor(red: 0.8, green: 0.2, blue: 0.6, alpha: 0.5)
                    renderer.lineWidth = 4
                } else {
                    // Active/remaining segments - bright magenta with black outline effect
                    renderer.strokeColor = UIColor(red: 1.0, green: 0.0, blue: 0.8, alpha: 1.0)
                    renderer.lineWidth = 5
                }
                renderer.lineDashPattern = nil // Solid line
                return renderer
            }

            // GPS track (gold)
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
            // Handle flight plan waypoint annotations
            if let waypointAnnotation = annotation as? FlightPlanWaypointAnnotation {
                return createWaypointAnnotationView(mapView, annotation: waypointAnnotation)
            }

            // Handle aircraft annotation
            guard let aircraftAnnotation = annotation as? AircraftAnnotation else {
                return nil
            }

            let identifier = "AircraftAnnotation"

            // Always create fresh annotation view to ensure correct coloring
            let annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            annotationView.canShowCallout = false

            // Create aircraft marker with outline for visibility on all map backgrounds
            // Following aviation UI/UX best practices: high contrast with dark outline
            let aviationGold = UIColor(red: 0.85, green: 0.65, blue: 0.2, alpha: 1.0)
            let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .bold)

            if let image = UIImage(systemName: "airplane", withConfiguration: config) {
                // Create image with stroke outline for better visibility
                let strokeColor = UIColor.black
                let strokeWidth: CGFloat = 2.0
                let imageSize = CGSize(width: image.size.width + strokeWidth * 2,
                                       height: image.size.height + strokeWidth * 2)

                UIGraphicsBeginImageContextWithOptions(imageSize, false, 0)
                defer { UIGraphicsEndImageContext() }

                // Draw stroke (multiple offset copies create outline effect)
                let offsets: [CGPoint] = [
                    CGPoint(x: -strokeWidth, y: 0),
                    CGPoint(x: strokeWidth, y: 0),
                    CGPoint(x: 0, y: -strokeWidth),
                    CGPoint(x: 0, y: strokeWidth),
                    CGPoint(x: -strokeWidth * 0.7, y: -strokeWidth * 0.7),
                    CGPoint(x: strokeWidth * 0.7, y: -strokeWidth * 0.7),
                    CGPoint(x: -strokeWidth * 0.7, y: strokeWidth * 0.7),
                    CGPoint(x: strokeWidth * 0.7, y: strokeWidth * 0.7)
                ]

                let tintedStroke = image.withTintColor(strokeColor, renderingMode: .alwaysOriginal)
                for offset in offsets {
                    tintedStroke.draw(at: CGPoint(x: strokeWidth + offset.x, y: strokeWidth + offset.y))
                }

                // Draw main icon on top
                let tintedImage = image.withTintColor(aviationGold, renderingMode: .alwaysOriginal)
                tintedImage.draw(at: CGPoint(x: strokeWidth, y: strokeWidth))

                if let finalImage = UIGraphicsGetImageFromCurrentImageContext() {
                    annotationView.image = finalImage
                }
            }

            // Apply rotation for heading
            // SF Symbol "airplane" points to the right (90°/East) by default
            // Subtract 90° so that heading 0° (North) shows plane pointing up
            let headingRadians = (aircraftAnnotation.heading - 90.0) * .pi / 180.0
            annotationView.transform = CGAffineTransform(rotationAngle: CGFloat(headingRadians))

            // Additional shadow for depth
            annotationView.layer.shadowColor = UIColor.black.cgColor
            annotationView.layer.shadowOffset = CGSize(width: 0, height: 2)
            annotationView.layer.shadowOpacity = 0.5
            annotationView.layer.shadowRadius = 3

            return annotationView
        }

        /// Create annotation view for flight plan waypoints
        private func createWaypointAnnotationView(_ mapView: MKMapView, annotation: FlightPlanWaypointAnnotation) -> MKAnnotationView {
            let identifier = "FlightPlanWaypoint"
            let annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            annotationView.canShowCallout = true

            // Waypoint appearance based on state
            let size: CGFloat = 24
            let markerColor: UIColor
            let iconName: String

            if annotation.isCurrentWaypoint {
                // Current/next waypoint - bright magenta with target icon
                markerColor = UIColor(red: 1.0, green: 0.0, blue: 0.8, alpha: 1.0)
                iconName = "target"
            } else if annotation.isCompletedWaypoint {
                // Completed waypoint - dimmed with checkmark
                markerColor = UIColor(red: 0.6, green: 0.3, blue: 0.5, alpha: 0.7)
                iconName = "checkmark.circle.fill"
            } else {
                // Future waypoint - medium brightness
                markerColor = UIColor(red: 0.9, green: 0.4, blue: 0.7, alpha: 0.9)
                iconName = "circle.fill"
            }

            // Create the waypoint marker image
            let config = UIImage.SymbolConfiguration(pointSize: size, weight: .bold)
            if let image = UIImage(systemName: iconName, withConfiguration: config) {
                // Create image with black outline for visibility
                let strokeWidth: CGFloat = 2.0
                let imageSize = CGSize(width: image.size.width + strokeWidth * 2,
                                       height: image.size.height + strokeWidth * 2)

                UIGraphicsBeginImageContextWithOptions(imageSize, false, 0)
                defer { UIGraphicsEndImageContext() }

                // Draw black outline
                let offsets: [CGPoint] = [
                    CGPoint(x: -strokeWidth, y: 0),
                    CGPoint(x: strokeWidth, y: 0),
                    CGPoint(x: 0, y: -strokeWidth),
                    CGPoint(x: 0, y: strokeWidth)
                ]

                let strokeImage = image.withTintColor(.black, renderingMode: .alwaysOriginal)
                for offset in offsets {
                    strokeImage.draw(at: CGPoint(x: strokeWidth + offset.x, y: strokeWidth + offset.y))
                }

                // Draw main colored icon
                let tintedImage = image.withTintColor(markerColor, renderingMode: .alwaysOriginal)
                tintedImage.draw(at: CGPoint(x: strokeWidth, y: strokeWidth))

                if let finalImage = UIGraphicsGetImageFromCurrentImageContext() {
                    annotationView.image = finalImage
                }
            }

            // Add shadow
            annotationView.layer.shadowColor = UIColor.black.cgColor
            annotationView.layer.shadowOffset = CGSize(width: 0, height: 2)
            annotationView.layer.shadowOpacity = 0.5
            annotationView.layer.shadowRadius = 2

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

// MARK: - Flight Plan Waypoint Annotation

class FlightPlanWaypointAnnotation: NSObject, MKAnnotation {
    var coordinate: CLLocationCoordinate2D
    var title: String?
    var subtitle: String?
    var waypointIndex: Int
    var isCurrentWaypoint: Bool
    var isCompletedWaypoint: Bool

    init(coordinate: CLLocationCoordinate2D, name: String, index: Int, currentIndex: Int) {
        self.coordinate = coordinate
        self.title = name
        self.waypointIndex = index
        self.isCurrentWaypoint = index == currentIndex
        self.isCompletedWaypoint = index < currentIndex
        super.init()
    }
}

// MARK: - Flight Plan Route Polyline

/// Custom polyline class to distinguish flight plan route from GPS track
class FlightPlanRoutePolyline: MKPolyline {
    var isCompletedSegment: Bool = false
}

// MARK: - ICAO + Segelflugkarte Tile Overlay (with seamless switching)

/// Custom tile overlay for Swiss ICAO aeronautical chart with seamless Segelflugkarte switching
/// - ICAO Chart (ch.bazl.luftfahrtkarten-icao): zoom 7-11, scale 1:500,000
/// - Segelflugkarte (ch.bazl.segelflugkarte): zoom 11-14, scale 1:300,000
/// When forceICAO is true, always use ICAO layer even at higher zoom levels
/// When offlineMapManager is provided, use cached tiles from disk (cache-first in online mode)
/// When isStrictOfflineMode is true, only use cached tiles (no network requests)
class ICAOSegelflugkarteTileOverlay: MKTileOverlay {
    private let icaoLayerIdentifier = "ch.bazl.luftfahrtkarten-icao"
    private let segelflugkarteLayerIdentifier = "ch.bazl.segelflugkarte"
    let forceICAO: Bool
    weak var offlineMapManager: OfflineMapManager?
    let isStrictOfflineMode: Bool
    let hasSegelflugCache: Bool

    // Zoom level where we switch from ICAO to Segelflugkarte
    // ICAO: zoom 7-11 (1:500,000)
    // Segelflugkarte: zoom 11-14 (1:300,000) - swisstopo only provides up to zoom 14
    private let icaoMinZoom = 7
    private let icaoMaxZoom = 11
    private let segelflugkarteMinZoom = 11
    private let segelflugkarteMaxZoom = 14

    init(forceICAO: Bool = false, offlineMapManager: OfflineMapManager? = nil, isStrictOfflineMode: Bool = false, hasSegelflugCache: Bool = false) {
        self.forceICAO = forceICAO
        self.offlineMapManager = offlineMapManager
        self.isStrictOfflineMode = isStrictOfflineMode
        self.hasSegelflugCache = hasSegelflugCache
        // Use a placeholder URL template - we override loadTile(at:result:) for cache-first loading
        let urlTemplate = "https://wmts.geo.admin.ch/1.0.0/ch.bazl.luftfahrtkarten-icao/default/current/3857/{z}/{x}/{y}.png"
        super.init(urlTemplate: urlTemplate)

        // Set tile overlay zoom constraints to match the camera zoom range
        // This helps MapKit understand the valid tile range
        self.minimumZ = icaoMinZoom

        // In strict offline mode with only ICAO cache, limit to ICAO range
        // In strict offline mode with both caches (or forceICAO off), allow Segelflug range
        if forceICAO {
            self.maximumZ = icaoMaxZoom
        } else if isStrictOfflineMode {
            self.maximumZ = hasSegelflugCache ? segelflugkarteMaxZoom : icaoMaxZoom
        } else {
            self.maximumZ = segelflugkarteMaxZoom
        }
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        // This is called as fallback - loadTile handles cache-first logic
        let (layerIdentifier, finalZ) = layerInfo(for: path)
        let urlString = "https://wmts.geo.admin.ch/1.0.0/\(layerIdentifier)/default/current/3857/\(finalZ)/\(path.x)/\(path.y).png"
        return URL(string: urlString) ?? URL(string: "about:blank")!
    }

    /// Override loadTile to implement cache-first loading strategy
    /// This provides instant loading from cache while falling back to network when needed
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        // Determine which layer to use based on zoom and settings
        let (layerIdentifier, finalZ) = layerInfo(for: path)

        // Determine if this tile should come from ICAO or Segelflug based on the layer
        let isICAOTile = layerIdentifier == icaoLayerIdentifier

        // Try cache first when we have a cache manager
        if let manager = offlineMapManager {
            if isICAOTile {
                // Check for cached ICAO tile
                if let cachedURL = manager.cachedTileURL(z: finalZ, x: path.x, y: path.y, layer: .icao),
                   let data = try? Data(contentsOf: cachedURL) {
                    // Cache hit - return immediately (this is why offline mode is fast!)
                    result(data, nil)
                    return
                }
            } else {
                // Check for cached Segelflug tile
                if let cachedURL = manager.cachedTileURL(z: finalZ, x: path.x, y: path.y, layer: .segelflug),
                   let data = try? Data(contentsOf: cachedURL) {
                    result(data, nil)
                    return
                }
            }
        }

        // In strict offline mode, don't make network requests
        if isStrictOfflineMode {
            // Return empty data for tiles not in cache
            result(nil, nil)
            return
        }

        // Cache miss - fetch from network
        let urlString = "https://wmts.geo.admin.ch/1.0.0/\(layerIdentifier)/default/current/3857/\(finalZ)/\(path.x)/\(path.y).png"

        guard let url = URL(string: urlString) else {
            result(nil, nil)
            return
        }

        // Use URLSession for network requests
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                result(nil, error)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data = data else {
                result(nil, nil)
                return
            }

            result(data, nil)
        }
        task.resume()
    }

    /// Determine which layer and zoom to use for a given tile path
    private func layerInfo(for path: MKTileOverlayPath) -> (layerIdentifier: String, finalZ: Int) {
        let z = path.z

        if forceICAO {
            // Force ICAO at all zoom levels - clamp to ICAO's valid range
            let finalZ = min(max(z, icaoMinZoom), icaoMaxZoom)
            return (icaoLayerIdentifier, finalZ)
        } else if isStrictOfflineMode && !hasSegelflugCache {
            // Offline mode with only ICAO cache - force ICAO
            let finalZ = min(max(z, icaoMinZoom), icaoMaxZoom)
            return (icaoLayerIdentifier, finalZ)
        } else {
            // Seamless switching between ICAO and Segelflugkarte
            // Works in both online mode and offline mode with both caches
            if z <= icaoMaxZoom {
                // Use ICAO chart for lower zoom levels
                let finalZ = min(max(z, icaoMinZoom), icaoMaxZoom)
                return (icaoLayerIdentifier, finalZ)
            } else {
                // Use Segelflugkarte for higher zoom levels
                let finalZ = min(max(z, segelflugkarteMinZoom), segelflugkarteMaxZoom)
                return (segelflugkarteLayerIdentifier, finalZ)
            }
        }
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

    private var hasFullOfflineSupport: Bool {
        offlineMapManager.isCacheAvailable && offlineMapManager.isSegelflugCacheAvailable
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 14) {
                // Header icon
                Image(systemName: isOfflineMode ? "wifi.slash" : "internaldrive.fill")
                    .font(.system(size: 40))
                    .foregroundColor(isOfflineMode ? .aviationRed : .aviationGold)
                    .padding(.top, 20)

                // Title
                Text(isOfflineMode ? "Offline Mode Active" : "Using Cached Charts")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.primaryText)

                // Description
                VStack(spacing: 8) {
                    if isOfflineMode {
                        if hasFullOfflineSupport {
                            Text("The app is in offline mode. Both ICAO Chart and Segelflugkarte are available from cache with seamless zoom switching.")
                                .font(.system(size: 13))
                                .foregroundColor(.secondaryText)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("The app is in offline mode. Only the ICAO Chart is cached.")
                                .font(.system(size: 13))
                                .foregroundColor(.secondaryText)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)

                            Text("Download Segelflugkarte for seamless zoom transitions in offline mode.")
                                .font(.system(size: 11))
                                .foregroundColor(.aviationAmber)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("Charts are being served from your local cache for faster loading.")
                            .font(.system(size: 13))
                            .foregroundColor(.secondaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Tiles load instantly from cache; uncached tiles fetch from the network.")
                            .font(.system(size: 11))
                            .foregroundColor(.dimText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16)

                // Cache info
                VStack(spacing: 6) {
                    // ICAO Cache
                    if offlineMapManager.isCacheAvailable {
                        HStack {
                            Text("ICAO Chart:")
                                .foregroundColor(.secondaryText)
                            Spacer()
                            Text(offlineMapManager.cacheVersion)
                                .foregroundColor(.aviationGreen)
                        }
                    }

                    // Segelflug Cache
                    HStack {
                        Text("Segelflugkarte:")
                            .foregroundColor(.secondaryText)
                        Spacer()
                        if offlineMapManager.isSegelflugCacheAvailable {
                            Text(offlineMapManager.segelflugCacheVersion)
                                .foregroundColor(.aviationGreen)
                        } else {
                            Text("Not cached")
                                .foregroundColor(.dimText)
                        }
                    }

                    HStack {
                        Text("Total Size:")
                            .foregroundColor(.secondaryText)
                        Spacer()
                        Text(offlineMapManager.formattedCacheSize)
                            .foregroundColor(.primaryText)
                    }
                }
                .font(.system(size: 11))
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.panelBackground)
                )
                .padding(.horizontal, 16)

                Spacer(minLength: 8)

                // Action buttons (only for offline mode)
                if isOfflineMode {
                    VStack(spacing: 6) {
                        // Go Online button (switches to online mode with cache still active)
                        Button(action: goOnline) {
                            HStack(spacing: 6) {
                                Image(systemName: "wifi")
                                Text("Go Online")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.aviationGreen)
                            )
                        }
                        .padding(.horizontal, 16)

                        // Stay Offline button (secondary)
                        Button(action: { dismiss() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "wifi.slash")
                                Text("Stay Offline")
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Color.aviationRed.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.aviationRed.opacity(0.15))
                            )
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 16)
                }
            }
            .background(Color.cockpitBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isOfflineMode {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .presentationDetents(isOfflineMode ? [.height(420)] : [.height(320)])
        .interactiveDismissDisabled(false)
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
