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
        case .icao: return 12  // Extended to include Segelflugkarte range (max zoom 12)
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

/// Map orientation mode
enum MapOrientationMode {
    case northUp    // Map always shows north at top
    case trackUp    // Map rotates so heading is always up
}

/// The navigation map's display state (selected chart layer + orientation), extracted from AppState
/// as one cohesive value rather than two loose @Published properties. AppState owns it via a single
/// `@Published var navigationMapState`, so mutating a field still drives SwiftUI updates. In-memory
/// session state (not persisted). (Phase 4 — AppState decomposition: state extraction)
struct NavigationMapState: Equatable {
    var selectedLayer: MapLayerType = .icao
    var orientationMode: MapOrientationMode = .northUp
}

extension MapOrientationMode: Equatable {}

/// Tab selection for compact navigation panel
enum CompactNavigationTab: String, CaseIterable {
    case plan = "PLAN"
    case freq = "FREQ"
}

/// Full-screen navigation map view with aircraft position tracking
struct NavigationMapView: View {
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var offlineMapManager: OfflineMapManager
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var aircraftDataService: AircraftDataService
    @EnvironmentObject var openAIPCacheManager: OpenAIPCacheManager
    @EnvironmentObject var openAIPDataService: OpenAIPDataService
    @EnvironmentObject var flightEventDetector: FlightEventDetector
    @ObservedObject private var marketingProvider = MarketingLocationProvider.shared

    @Binding var isPresented: Bool
    @State private var selectedLayer: MapLayerType = .icao
    @State private var isFollowingAircraft: Bool = true
    @State private var showLayerPicker: Bool = false
    @State private var showCacheInfoModal: Bool = false
    @State private var showFlightPlanning: Bool = false
    /// Whether the flight-plan sheet (bottom bar) is expanded to show the full plan detail. (3.5 — inc C)
    @State private var navSheetExpanded: Bool = false
    /// A waypoint being previewed from the expanded sheet (tap a row); nil = follow the active waypoint.
    @State private var previewWaypointIndex: Int? = nil
    /// Whether the frequency column shows the full list vs the capped essentials. (3.5 — feedback)
    @State private var showAllFreqs = false
    /// Phase-aware frequencies for the sheet's right column + the collapsed chip. Cached (recomputed
    /// on phase / significant-move) rather than per-render, since it does a nearest-airport query. (3.5 C2)
    @State private var phaseFreqItems: [PhaseFrequency] = []
    // Track-vector smoothing — EMA of ground speed + ground track (track averaged circularly via
    // sin/cos so it doesn't wrap). Favours recent samples (~10 s time constant). (3.5 C4)
    @State private var smoothedGroundSpeed: Double = 0
    @State private var smoothedTrackSin: Double = 0
    @State private var smoothedTrackCos: Double = 1
    @State private var hasTrackVectorEMA = false
    /// Last known aircraft coordinate — keeps the track vector anchored across brief GPS gaps. (3.5)
    @State private var lastKnownCoordinate: CLLocationCoordinate2D?
    /// Stable periodic timer (created once via @State) for the cruise-check evaluation — an inline
    /// Timer.publish recreated each render can stall, so the cruise check never fired. (3.5 fix)
    @State private var cruiseEvalTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @State private var mapOrientationMode: MapOrientationMode = .northUp
    @State private var locationUpdateCounter: Int = 0 // Forces map view updates on location change

    // Compact layout state (for small devices)
    @State private var showCompactPanel: Bool = false
    @State private var selectedCompactTab: CompactNavigationTab = .plan
    @State private var panelDragOffset: CGFloat = 0 // For drag-to-collapse gesture
    @State private var showGPSStatusModal: Bool = false
    @State private var streamingCTRCheckTask: Task<Void, Never>?
    /// Preview index for iPhone compact panel waypoint browsing (nil = showing real active waypoint)
    @State private var compactPreviewIndex: Int? = nil

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
        appState.activeChecklist.targetSpeed(for: appState.currentPhase)
    }

    /// Stall speed from current aircraft
    private var stallSpeed: Int {
        appState.activeChecklist.stallSpeed
    }

    /// Speed color based on current speed vs target
    private var speedColor: Color {
        let speedKnots = Int(locationManager.currentSpeedKnots)

        // Don't show stall color based on unreliable GPS data
        if locationManager.gpsSignalStatus != .good {
            return .dimText
        }

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

    /// Current heading from location (cached to prevent snapping to 0° during GPS gaps)
    private var currentHeading: Int {
        if let course = locationManager.currentCourseDegrees { return Int(course) }
        return 0
    }

    /// Determine if we should use compact layout for small devices
    /// Uses compact layout when flight planning is enabled and device width is compact (iPhone)
    /// Now also supports showing just frequency drawer when no flight plan is active
    private var shouldUseCompactLayout: Bool {
        isCompactWidth && appState.settings.enableFlightPlanning
    }

    /// Whether there is an active flight plan
    private var hasActiveFlightPlan: Bool {
        flightPlanManager.activeFlightPlan != nil
    }

    var body: some View {
        GeometryReader { geometry in
            if shouldUseCompactLayout {
                // Compact layout for small devices with flight plan active
                compactLayoutBody(geometry: geometry)
            } else {
                // Standard layout for large devices or when no flight plan
                standardLayoutBody(geometry: geometry)
            }
        }
        .preferredColorScheme(.dark)
        // Immersive full-screen map: hide the system status bar so the top chrome (airspace / layer)
        // never collides with the time / battery / network indicators. (3.5 fix)
        .statusBarHidden(true)
        // A detected go-around / touch-and-go / full-stop must be confirmable while the full-screen
        // map is up — FlightView's own overlay sits behind this .fullScreenCover. (PR-40)
        .flightEventConfirmationOverlay(detector: flightEventDetector, appState: appState)
        .onAppear {
            // Restore map settings from session state
            selectedLayer = appState.navigationMapState.selectedLayer
            mapOrientationMode = appState.navigationMapState.orientationMode
            // Start GPS updates when navigation view opens
            locationManager.startLocationUpdates()
            // Center on aircraft location immediately (synchronous, not via async dispatch)
            // so the map renders at the correct position from the first frame
            if let location = locationManager.currentLocation {
                mapState.region = MKCoordinateRegion(
                    center: location.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
                )
                mapState.cameraDistance = 10000
                if mapOrientationMode == .trackUp, let course = locationManager.currentCourseDegrees {
                    mapState.cameraHeading = course
                }
            }
            isFollowingAircraft = true
            // Ensure airport data is loaded — needed both for the map overlay AND for the phase-aware
            // frequencies (nearest-airport lookup), so load it regardless of the overlay setting, then
            // refresh the cached phase frequencies once it's available. (3.5 fix)
            Task {
                await airportDataService.ensureLoaded()
                // ensureLoaded() only loads an existing cache — it never downloads. The frequency
                // feature (nearest airfield + airfield auto-complete) needs the DB, so fetch it once
                // on demand if it was never downloaded. (3.5 fix)
                if !airportDataService.isDataAvailable && !airportDataService.isDownloading {
                    await airportDataService.downloadData()
                }
                recomputePhaseFrequencies()
            }
            // Ensure OpenAIP airspace data is loaded for FREQ panel CTR queries
            if openAIPDataService.isDataAvailable {
                Task { await openAIPDataService.ensureLoaded() }
            }
            // Trigger streaming CTR fetch if enabled and no downloaded data
            if appState.settings.enableAirspaceStreaming && !openAIPDataService.isDataAvailable,
               let coord = locationManager.currentLocation?.coordinate {
                Task { await openAIPDataService.fetchStreamingCTRsIfNeeded(from: coord) }
            }
            // Seed the cached spatial map content for the initial region. (PR-11)
            recomputeMapSpatialContent(force: true)
        }
        .onDisappear {
            // Stop GPS updates when navigation view closes (if not in a flight)
            locationManager.stopLocationUpdates()
            streamingCTRCheckTask?.cancel()
            streamingCTRCheckTask = nil
        }
        // PR-11: recompute the visible airports/airspace only when the region moves past the
        // quantization threshold (the function early-returns otherwise), instead of on every body
        // re-eval. A toggled overlay setting or newly-available data forces an immediate recompute.
        .onReceive(mapState.$region) { _ in
            recomputeMapSpatialContent()
        }
        .onChange(of: appState.settings.showAirportsOnMap) { _, _ in recomputeMapSpatialContent(force: true) }
        .onChange(of: appState.currentPhase) { _, _ in
            recomputePhaseFrequencies()
            appState.evaluateCruiseCheck()
        }
        .onChange(of: flightPlanManager.activeFlightPlan?.currentWaypointIndex) { _, _ in recomputePhaseFrequencies() }
        .onReceive(cruiseEvalTimer) { _ in
            appState.evaluateCruiseCheck()
        }
        .cruiseCheckReminder(appState: appState)
        .onChange(of: appState.settings.showOpenAIPOverlay) { _, _ in recomputeMapSpatialContent(force: true) }
        .onChange(of: airportDataService.isDataAvailable) { _, _ in recomputeMapSpatialContent(force: true) }
        .onChange(of: openAIPDataService.isDataAvailable) { _, _ in recomputeMapSpatialContent(force: true) }
        .onChange(of: locationManager.currentLocation) { _, newLocation in
            // Increment counter to force map view updates (ensures aircraft annotation moves)
            locationUpdateCounter += 1
            updateTrackVectorEMA()

            if isFollowingAircraft, let location = newLocation {
                updateMapStateForLocation(location)
            }

            // In track-up mode, update heading to match course (using cached heading)
            if mapOrientationMode == .trackUp, let course = locationManager.currentCourseDegrees {
                mapState.cameraHeading = course
            }

            // Auto-advance waypoint when within proximity threshold
            if appState.settings.enableFlightPlanning,
               let location = newLocation {
                let clLocation = CLLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                let prevIndex = flightPlanManager.activeFlightPlan?.currentWaypointIndex
                flightPlanManager.autoAdvanceWaypointIfNeeded(
                    currentLocation: clLocation,
                    threshold: appState.settings.waypointProximityThreshold
                )
                // Reset compact preview when GPS auto-advances
                if flightPlanManager.activeFlightPlan?.currentWaypointIndex != prevIndex {
                    compactPreviewIndex = nil
                }
            }

            // Debounced streaming CTR fetch (5s delay)
            if appState.settings.enableAirspaceStreaming && !openAIPDataService.isDataAvailable {
                streamingCTRCheckTask?.cancel()
                streamingCTRCheckTask = Task {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled, let coord = newLocation?.coordinate else { return }
                    await openAIPDataService.fetchStreamingCTRsIfNeeded(from: coord)
                }
            }
        }
        .onChange(of: selectedLayer) { oldLayer, newLayer in
            // Save to session state
            appState.navigationMapState.selectedLayer = newLayer
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

    // MARK: - Standard Layout (iPad and iPhone without active flight plan)

    private func standardLayoutBody(geometry: GeometryProxy) -> some View {
        ZStack {
            // Map content
            mapContent
                .ignoresSafeArea()

            // Overlay controls — top bar padded; the bottom bar runs full-width to the bottom edge.
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal)
                    .padding(.top)

                Spacer()

                bottomControls
            }

            // The floating FLIGHT INFO overlay and the separate radio-frequency panel are both retired
            // (inc C / C2) — flight-plan data + the phase-aware frequencies live in the expandable
            // bottom sheet (bottomControls / navSheetContent / freqColumn).
        }
        .onAppear {
            mapWidth = geometry.size.width
        }
        .onChange(of: geometry.size) { _, newSize in
            mapWidth = newSize.width
        }
    }

    // MARK: - Compact Layout (iPhone with active flight plan)

    @ViewBuilder
    private func compactLayoutBody(geometry: GeometryProxy) -> some View {
        // Calculate panel height - exactly half the screen plus bottom safe area
        let bottomSafeArea = geometry.safeAreaInsets.bottom
        let topSafeArea = geometry.safeAreaInsets.top
        let panelHeight = (geometry.size.height / 2) + bottomSafeArea

        ZStack(alignment: .top) {
            // Map content - full screen behind everything
            mapContent
                .ignoresSafeArea()

            // Fixed top bar overlay - stays in place regardless of panel state
            VStack {
                compactTopBar
                    .padding(.horizontal, 12)
                    .padding(.top, topSafeArea + (topSafeArea > 50 ? 8 : 4)) // Account for Dynamic Island/notch

                Spacer()
            }

            // Map controls positioned above the panel (or at bottom when panel hidden)
            VStack {
                Spacer()

                compactMapControls
                    .padding(.horizontal, 12)
                    .padding(.bottom, showCompactPanel ? (panelHeight + 8) : (bottomSafeArea + 8))
                    .animation(.easeInOut(duration: 0.3), value: showCompactPanel)
            }

            // Bottom panel - slides up from bottom edge of screen
            VStack {
                Spacer()

                if showCompactPanel {
                    compactBottomPanel(geometry: geometry, bottomSafeArea: bottomSafeArea)
                        .frame(height: panelHeight)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showCompactPanel)
        }
        .ignoresSafeArea()
        .onAppear {
            mapWidth = geometry.size.width
        }
        .onChange(of: geometry.size) { _, newSize in
            mapWidth = newSize.width
        }
    }

    // MARK: - Compact Top Bar

    private var compactTopBar: some View {
        HStack(spacing: 8) {
            // Close button
            Button(action: { isPresented = false }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.primaryText)
                    .frame(width: 44, height: 44) // HIG minimum tap target (UX-16)
                    .floatingChromeCircle()
            }

            // Flight Plan button (toggles bottom panel) - shown when flight plan is active and not completed
            // Opens the flight planning view when tapped, toggles panel with long press or when panel visible
            if hasActiveFlightPlan && !flightPlanManager.isFlightPlanCompleted {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showCompactPanel.toggle()
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "map.fill")
                            .font(.system(size: 12))
                        if showCompactPanel {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                        } else {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 8, weight: .bold))
                        }
                    }
                    .foregroundColor(showCompactPanel ? .aviationGreen : .primaryText)
                    .frame(width: 50, height: 44) // HIG minimum tap height (UX-16)
                    .floatingChromeBackground(cornerRadius: 8)
                }
            } else {
                // When no flight plan is active, show button to open flight planning view
                Button(action: { showFlightPlanning = true }) {
                    Image(systemName: "map.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.primaryText)
                        .frame(width: 44, height: 44) // HIG minimum tap target (UX-16)
                        .floatingChromeBackground(cornerRadius: 8)
                }
                .fullScreenCover(isPresented: $showFlightPlanning) {
                    FlightPlanningView()
                        .environmentObject(appState)
                        .environmentObject(flightPlanManager)
                        .environmentObject(airportDataService)
                        .environmentObject(aircraftDataService)
                        .environmentObject(openAIPDataService)
                }
            }

            Spacer()

            // Compact time/speed/altitude/heading display (two rows)
            VStack(spacing: 0) {
                VStack(spacing: 2) {
                    // Row 1: Time + Speed
                    HStack(spacing: 6) {
                        // Time
                        NavClockText(useUTC: appState.settings.alwaysUseUTC,
                                     font: .system(size: 11, weight: .medium, design: .monospaced),
                                     color: .primaryText)

                        Rectangle()
                            .fill(Color.dimText)
                            .frame(width: 1, height: 14)

                        // Speed
                        HStack(spacing: 1) {
                            Text("\(Int(locationManager.currentSpeedKnots))")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                            Text("kt")
                                .font(.system(size: 12)) // ≥12pt for glance legibility (UX-17)
                        }
                        .foregroundColor(speedColor)
                    }

                    // Row 2: Altitude + Heading
                    HStack(spacing: 6) {
                        // Altitude
                        HStack(spacing: 1) {
                            Text("\(Int(locationManager.currentAltitudeFeet))")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                            Text("ft")
                                .font(.system(size: 12)) // ≥12pt (UX-17)
                        }
                        .foregroundColor(.altimeterBlue)

                        Rectangle()
                            .fill(Color.dimText)
                            .frame(width: 1, height: 14)

                        // Heading
                        HStack(spacing: 1) {
                            Text(String(format: "%03d", currentHeading))
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                            Text("°")
                                .font(.system(size: 12)) // ≥12pt (UX-17)
                        }
                        .foregroundColor(.aviationGold)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)

                // "Next Check" line integrated in the info box
                if appState.isFlightActive {
                    Rectangle()
                        .fill(Color.dimText.opacity(0.3))
                        .frame(height: 0.5)

                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 9))
                        Text("Next: \(appState.currentPhase.title)")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.aviationGold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                }
            }
            .floatingChromeBackground(cornerRadius: 8)

            Spacer()

            // OpenAIP overlay toggle
            Button(action: {
                appState.settings.showOpenAIPOverlay.toggle()
                appState.saveSettings()
            }) {
                Image(systemName: "shield")
                    .font(.system(size: 14))
                    .foregroundColor(appState.settings.showOpenAIPOverlay ? .aviationGold : .secondaryText)
                    .frame(width: 44, height: 44) // HIG minimum tap target (UX-16)
                    .background(
                        Circle()
                            .fill(appState.settings.showOpenAIPOverlay
                                  ? Color.panelBackground.opacity(0.95)
                                  : Color.panelBackground.opacity(0.7))
                    )
            }

            // Layer picker button
            Button(action: {
                if isOfflineMode {
                    showCacheInfoModal = true
                } else {
                    showLayerPicker = true
                }
            }) {
                Image(systemName: isOfflineMode ? MapLayerType.icao.icon : selectedLayer.icon)
                    .font(.system(size: 14))
                    .foregroundColor(isOfflineMode ? .secondaryText : .primaryText)
                    .frame(width: 44, height: 44) // HIG minimum tap target (UX-16)
                    .floatingChromeCircle()
            }
            .sheet(isPresented: $showLayerPicker) {
                LayerPickerSheet(selectedLayer: $selectedLayer)
            }
        }
    }

    // MARK: - Compact Map Controls

    private var compactMapControls: some View {
        HStack(alignment: .bottom) {
            // Left side: Scale bar and cache/offline indicator
            VStack(alignment: .leading, spacing: 6) {
                // Offline/Cached mode indicator
                if isOfflineMode || isCachedMode {
                    Button(action: { showCacheInfoModal = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "internaldrive.fill")
                                .font(.system(size: 10))
                            Text(isOfflineMode ? L10n.Nav.offline : L10n.Nav.cached)
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
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
                SwissScaleBar(region: mapState.region, mapWidth: mapWidth, nauticalMiles: appState.settings.distanceInNauticalMiles)
            }

            Spacer()

            // Right side: GPS status, FREQ button (when no flight plan), and center button
            VStack(alignment: .trailing, spacing: 8) {
                // GPS Status (tappable for info modal)
                Button(action: { showGPSStatusModal = true }) {
                    HStack(spacing: 4) {
                        Text("GPS")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(gpsStatusColor)
                        StatusIndicator(gpsStatusIndicator, size: 6)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .floatingChromeBackground(cornerRadius: 6)
                }
                .fullScreenCover(isPresented: $showGPSStatusModal) {
                    GPSStatusInfoSheet(currentStatus: locationManager.gpsSignalStatus, isPresented: $showGPSStatusModal)
                }

                // FREQ button - only shown when no flight plan is active (to toggle frequency drawer)
                if !hasActiveFlightPlan {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showCompactPanel.toggle()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text("FREQ")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(showCompactPanel ? .aviationGold : .primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .floatingChromeBackground(cornerRadius: 8)
                    }
                }

                // Compass and center button row
                HStack(spacing: 8) {
                    // Compass / orientation toggle button
                    Button(action: toggleOrientation) {
                        if mapOrientationMode == .northUp {
                            CompassView(heading: mapState.cameraHeading)
                                .scaleEffect(0.8)
                                .frame(width: 40, height: 40)
                        } else {
                            Image(systemName: "location.north.line.fill")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.aviationGold)
                                .rotationEffect(.degrees(-mapState.cameraHeading))
                                .frame(width: 40, height: 40)
                                .floatingChromeCircle()
                        }
                    }

                    // Center on aircraft button
                    Button(action: centerOnAircraft) {
                        Image(systemName: isFollowingAircraft ? "location.fill" : "location")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(isFollowingAircraft ? .aviationGold : .primaryText)
                            .frame(width: 40, height: 40)
                            .floatingChromeCircle()
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: mapState.cameraHeading)
            }
        }
    }

    // MARK: - Compact Bottom Panel

    private func compactBottomPanel(geometry: GeometryProxy, bottomSafeArea: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Drag handle area
            draggablePanelHeader

            // Tab content
            ScrollView {
                if hasActiveFlightPlan {
                    switch selectedCompactTab {
                    case .plan:
                        compactFlightPlanContent
                    case .freq:
                        compactFrequencyContent
                    }
                } else {
                    // Only show frequencies when no flight plan active
                    compactFrequencyContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom safe area padding to extend panel to screen edge
            Color.panelBackground.opacity(0.95)
                .frame(height: bottomSafeArea)
        }
        .background(.regularMaterial)
    }

    /// Header for the compact panel with drag gesture support
    private var draggablePanelHeader: some View {
        VStack(spacing: 0) {
            // Drag indicator
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.secondaryText.opacity(0.5))
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 4)

            // Tab switcher or FREQ-only header
            if hasActiveFlightPlan {
                // Tab switcher when flight plan is active
                HStack(spacing: 0) {
                    ForEach(CompactNavigationTab.allCases, id: \.self) { tab in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedCompactTab = tab
                            }
                        }) {
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(selectedCompactTab == tab ? .aviationGold : .secondaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    selectedCompactTab == tab ?
                                        Color.aviationGold.opacity(0.15) : Color.clear
                                )
                        }
                    }
                }
            } else {
                // FREQ-only header when no flight plan
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 12))
                    Text("FREQ")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundColor(.aviationGold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.aviationGold.opacity(0.15))
            }
        }
        .background(Color.aviationDarkBlue)
        .gesture(
            DragGesture()
                .onChanged { value in
                    panelDragOffset = value.translation.height
                }
                .onEnded { value in
                    // If dragged down more than 50 points, collapse the panel
                    if value.translation.height > 50 {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showCompactPanel = false
                        }
                    }
                    // If dragged up more than 50 points while collapsed, expand
                    // (though this header is only shown when expanded)
                    panelDragOffset = 0
                }
        )
    }

    // MARK: - Compact Flight Plan Content

    private var compactFlightPlanContent: some View {
        VStack(spacing: 8) {
            if let plan = flightPlanManager.activeFlightPlan,
               !plan.waypoints.isEmpty {
                let displayIndex = compactPreviewIndex ?? plan.currentWaypointIndex
                let clampedIndex = Swift.max(0, Swift.min(displayIndex, plan.waypoints.count - 1))
                let displayWaypoint = plan.waypoints[clampedIndex]
                // Leg data (MC/DIST/EET) for the leg ARRIVING at the displayed waypoint lives
                // on its departure waypoint, not the arrival waypoint — read it through
                // legArriving(at:) (UX-01).
                let legWaypoint = plan.legArriving(at: clampedIndex)
                let isPreview = compactPreviewIndex != nil && compactPreviewIndex != plan.currentWaypointIndex

                // Waypoint header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isPreview ? "PREVIEW" : L10n.Nav.nextWaypoint)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(isPreview ? .aviationBlue : .dimText)
                        Text(displayWaypoint.name.isEmpty ? "\(L10n.Nav.wpt)\(clampedIndex + 1)" : displayWaypoint.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.primaryText)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text("\(clampedIndex + 1)/\(plan.waypoints.count)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondaryText)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                // PRIMARY: Planned waypoint-to-waypoint MC, DIST, EET
                HStack(spacing: 24) {
                    // Planned MC
                    VStack(spacing: 2) {
                        Text(L10n.Nav.mc)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.dimText)
                        if let mc = legWaypoint?.magneticCourse {
                            HStack(alignment: .firstTextBaseline, spacing: 1) {
                                Text(String(format: "%03d", Int(mc)))
                                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                                    .foregroundColor(.aviationGold)
                                Text("°")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.aviationGold)
                            }
                        } else {
                            Text("---°")
                                .font(.system(size: 24, weight: .bold, design: .monospaced))
                                .foregroundColor(.dimText)
                        }
                    }

                    // Planned DIST
                    VStack(spacing: 2) {
                        Text(L10n.Nav.dist)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.dimText)
                        if let dist = legWaypoint?.distance {
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(String(format: "%.1f", dist))
                                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                                    .foregroundColor(.aviationGold)
                                Text("NM")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondaryText)
                            }
                        } else {
                            Text("-- NM")
                                .font(.system(size: 24, weight: .bold, design: .monospaced))
                                .foregroundColor(.dimText)
                        }
                    }

                    // Planned EET
                    VStack(spacing: 2) {
                        Text("EET")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.dimText)
                        if let eet = legWaypoint?.estimatedElapsedTime {
                            let minutes = Int(eet / 60)
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text("\(minutes)")
                                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                                    .foregroundColor(.aviationGold)
                                Text("min")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondaryText)
                            }
                        } else {
                            Text("--")
                                .font(.system(size: 24, weight: .bold, design: .monospaced))
                                .foregroundColor(.dimText)
                        }
                    }
                }
                .padding(.horizontal, 16)

                // SECONDARY: Live GPS data to real next waypoint
                if let location = locationManager.currentLocation {
                    let clLocation = CLLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                    HStack(spacing: 12) {
                        if isPreview {
                            Text(L10n.Nav.hdgTo)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.dimText)
                        }
                        if let bearing = flightPlanManager.bearingToNextWaypoint(from: clLocation) {
                            Text(String(format: "%03d°", Int(bearing)))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondaryText)
                        }
                        if let distance = flightPlanManager.distanceToNextWaypoint(from: clLocation) {
                            Text(String(format: "%.1f NM", distance))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondaryText)
                        }
                    }
                    .padding(.horizontal, 16)
                }

                Divider()
                    .background(Color.dimText)
                    .padding(.horizontal, 16)

                // Progress bar
                VStack(spacing: 6) {
                    HStack {
                        Text(L10n.Nav.progress)
                            .font(.system(size: 10))
                            .foregroundColor(.secondaryText)
                        Spacer()
                        Text(String(format: "%.0f%%", plan.progress * 100))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondaryText)
                    }

                    ProgressView(value: plan.progress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .aviationGreen))

                    // Waypoint dots
                    HStack(spacing: 4) {
                        ForEach(0..<plan.waypoints.count, id: \.self) { index in
                            Circle()
                                .fill(index < plan.currentWaypointIndex ? Color.aviationGreen :
                                      index == plan.currentWaypointIndex ? Color.aviationGold : Color.dimText)
                                .frame(width: 6, height: 6)
                        }
                    }
                }
                .padding(.horizontal, 16)

                Divider()
                    .background(Color.dimText)
                    .padding(.horizontal, 16)

                // Chronometer
                VStack(spacing: 6) {
                    HStack {
                        Text(L10n.Nav.chronometer)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.dimText)

                        Spacer()

                        Button(action: {
                            flightPlanManager.resetChronometer()
                        }) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 12))
                                .foregroundColor(.secondaryText)
                        }
                    }

                    NavChronometerText(font: .system(size: 28, weight: .bold, design: .monospaced),
                                       color: .aviationGreen)

                    if flightPlanManager.activeFlightPlan?.chronometerStartTime == nil {
                        Button(action: {
                            flightPlanManager.startChronometer()
                        }) {
                            Text(L10n.Nav.start)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.aviationGreen)
                                )
                        }
                    }
                }
                .padding(.horizontal, 16)

                Divider()
                    .background(Color.dimText)
                    .padding(.horizontal, 16)

                // Waypoint preview navigation (does NOT affect flight state)
                HStack(spacing: 16) {
                    Button(action: {
                        let current = compactPreviewIndex ?? plan.currentWaypointIndex
                        compactPreviewIndex = max(0, current - 1)
                    }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.primaryText)
                            .frame(width: 44, height: 36)
                            .background(Color.aviationBlue)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(clampedIndex == 0)

                    if isPreview {
                        Button(action: { compactPreviewIndex = nil }) {
                            Image(systemName: "location.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.black)
                                .frame(width: 44, height: 36)
                                .background(Color.aviationGold)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    } else {
                        Text(L10n.Nav.wpt)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondaryText)
                    }

                    Button(action: {
                        let current = compactPreviewIndex ?? plan.currentWaypointIndex
                        compactPreviewIndex = Swift.min(plan.waypoints.count - 1, current + 1)
                    }) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.primaryText)
                            .frame(width: 44, height: 36)
                            .background(Color.aviationGreen)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(clampedIndex >= plan.waypoints.count - 1)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

            } else {
                Text(L10n.Nav.noActiveFlightPlan)
                    .font(.system(size: 14))
                    .foregroundColor(.secondaryText)
                    .padding()
            }
        }
    }

    // MARK: - Compact Frequency Content

    private var compactFrequencyContent: some View {
        VStack(spacing: 0) {
            if let plan = flightPlanManager.activeFlightPlan {
                let frequenciesWithWaypoints = plan.waypoints.filter { $0.frequency != nil && !$0.frequency!.isEmpty }

                // Waypoint frequencies
                if !frequenciesWithWaypoints.isEmpty {
                    ForEach(Array(frequenciesWithWaypoints.enumerated()), id: \.element.id) { index, waypoint in
                        compactFrequencyRow(
                            name: waypoint.name.isEmpty ? L10n.Nav.waypoint : waypoint.name,
                            callSign: waypoint.callSign,
                            frequency: waypoint.frequency ?? "",
                            isCurrent: waypoint.id == plan.currentWaypointId
                        )

                        if index < frequenciesWithWaypoints.count - 1 {
                            Divider()
                                .background(Color.dimText)
                        }
                    }
                } else {
                    Text(L10n.Nav.noFrequenciesInFlightPlan)
                        .font(.system(size: 12))
                        .foregroundColor(.secondaryText)
                        .padding()
                }

                // Nearby Controlled Airspace
                compactControlledAirspaceSection

                // Area frequencies section (Swiss only)
                if isInSwissAirspace {
                    Divider()
                        .background(Color.dimText)
                        .padding(.vertical, 4)

                    Text(L10n.Nav.areaFrequencies)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.dimText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)

                    ForEach(SwissCommonFrequency.allCases, id: \.self) { freq in
                        let isHighlighted = shouldHighlightCommonFrequency(freq)
                        compactCommonFrequencyRow(freq, isHighlighted: isHighlighted)
                        if freq != SwissCommonFrequency.allCases.last {
                            Divider()
                                .background(Color.dimText.opacity(0.5))
                        }
                    }
                }
            } else {
                // No active flight plan - show message and common frequencies
                Text(L10n.Nav.noActiveFlightPlan)
                    .font(.system(size: 12))
                    .foregroundColor(.secondaryText)
                    .padding()

                // Nearby Controlled Airspace
                compactControlledAirspaceSection

                // Area frequencies section (Swiss only)
                if isInSwissAirspace {
                    Divider()
                        .background(Color.dimText)
                        .padding(.vertical, 4)

                    Text(L10n.Nav.areaFrequencies)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.dimText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)

                    ForEach(SwissCommonFrequency.allCases, id: \.self) { freq in
                        let isHighlighted = shouldHighlightCommonFrequency(freq)
                        compactCommonFrequencyRow(freq, isHighlighted: isHighlighted)
                        if freq != SwissCommonFrequency.allCases.last {
                            Divider()
                                .background(Color.dimText.opacity(0.5))
                        }
                    }
                }
            }
        }
        .padding(.bottom, 16)
    }

    /// Whether the pilot is currently within Swiss airspace (for showing area frequencies)
    private var isInSwissAirspace: Bool {
        guard let location = locationManager.currentLocation else { return false }
        return SwissAirspaceSectors.isInSwitzerland(location.coordinate)
    }

    // Helper to check if common frequency should be highlighted
    private func shouldHighlightCommonFrequency(_ freq: SwissCommonFrequency) -> Bool {
        guard let location = locationManager.currentLocation else { return false }
        let coord = location.coordinate
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
            return false
        }
    }

    // Helper to get nearby CTRs from OpenAIP data (downloaded or streamed)
    private func getNearbyCTRsForCompact() -> [(airspace: Airspace, distanceNM: Double)] {
        guard let location = locationManager.currentLocation else { return [] }
        // Primary: full downloaded data
        if openAIPDataService.isDataAvailable {
            return Array(openAIPDataService.nearbyCTRs(from: location.coordinate).prefix(5))
        }
        // Streaming fallback (when enabled)
        if appState.settings.enableAirspaceStreaming {
            return Array(openAIPDataService.streamingCTRs.prefix(5))
        }
        return []
    }

    /// Get nearby airports with TWR frequencies as fallback when OpenAIP is unavailable
    private var compactFallbackTWRAirports: [(airport: Airport, twrFrequencies: [AirportFrequency], distanceNM: Double)] {
        guard let location = locationManager.currentLocation,
              airportDataService.isDataAvailable else { return [] }
        let nearbyAirports = airportDataService.findNearestAirports(
            to: location.coordinate,
            limit: 8,
            maxDistanceNm: 20.0
        )
        return nearbyAirports.compactMap { airport -> (airport: Airport, twrFrequencies: [AirportFrequency], distanceNM: Double)? in
            let frequencies = airportDataService.getFrequencies(for: airport.ident)
            let twrFreqs = frequencies.filter { $0.type == "TWR" }
            guard !twrFreqs.isEmpty else { return nil }
            let distanceNM = airport.distance(from: location.coordinate)
            return (airport: airport, twrFrequencies: twrFreqs, distanceNM: distanceNM)
        }
    }

    /// Compact "Nearby Controlled Airspace" section — OpenAIP primary (downloaded or streamed), OurAirports TWR fallback
    @ViewBuilder
    private var compactControlledAirspaceSection: some View {
        let ctrs = getNearbyCTRsForCompact()
        // OurAirports fallback only if no OpenAIP data (downloaded or streamed) available
        let fallback = (!ctrs.isEmpty || openAIPDataService.isDataAvailable) ? [] : compactFallbackTWRAirports

        if !ctrs.isEmpty || !fallback.isEmpty {
            Divider()
                .background(Color.dimText)
                .padding(.vertical, 4)

            Text(L10n.Nav.nearbyControlledAirspace)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.dimText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)

            if !ctrs.isEmpty {
                ForEach(ctrs, id: \.airspace.id) { item in
                    compactCTRRow(item.airspace, distanceNM: item.distanceNM)
                    if item.airspace.id != ctrs.last?.airspace.id {
                        Divider()
                            .background(Color.dimText.opacity(0.5))
                    }
                }
            } else {
                ForEach(fallback, id: \.airport.id) { item in
                    compactFallbackTWRRow(item.airport, twrFrequencies: item.twrFrequencies, distanceNM: item.distanceNM)
                    if item.airport.id != fallback.last?.airport.id {
                        Divider()
                            .background(Color.dimText.opacity(0.5))
                    }
                }
            }
        }
    }

    /// Compact fallback row showing OurAirports TWR frequency
    private func compactFallbackTWRRow(_ airport: Airport, twrFrequencies: [AirportFrequency], distanceNM: Double) -> some View {
        let isNearby = distanceNM <= 5.0

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(airport.ident)
                    .font(.system(size: 12, weight: isNearby ? .semibold : .regular))
                    .foregroundColor(isNearby ? .primaryText : .secondaryText)
                Text(airport.name)
                    .font(.system(size: 10))
                    .foregroundColor(.dimText)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(twrFrequencies.first?.formattedFrequency ?? "—")
                    .font(.system(size: 14, weight: isNearby ? .bold : .medium, design: .monospaced))
                    .foregroundColor(isNearby ? .aviationGold : .secondaryText)
                Text(String(format: "%.0fnm", distanceNM))
                    .font(.system(size: 10))
                    .foregroundColor(.dimText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isNearby ? Color.aviationGold.opacity(0.1) : Color.clear)
    }

    private func compactFrequencyRow(name: String, callSign: String?, frequency: String, isCurrent: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: isCurrent ? .bold : .medium))
                    .foregroundColor(isCurrent ? .aviationGold : .primaryText)
                    .lineLimit(1)
                if let callSign = callSign, !callSign.isEmpty {
                    Text(callSign)
                        .font(.system(size: 11))
                        .foregroundColor(.secondaryText)
                }
            }
            Spacer()
            Text(frequency)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(isCurrent ? .aviationGreen : .aviationGold)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isCurrent ? Color.aviationGold.opacity(0.1) : Color.clear)
    }

    private func compactCommonFrequencyRow(_ freq: SwissCommonFrequency, isHighlighted: Bool) -> some View {
        HStack {
            Text(freq.name)
                .font(.system(size: 12, weight: isHighlighted ? .semibold : .regular))
                .foregroundColor(isHighlighted ? .primaryText : .secondaryText)
            Spacer()
            Text(freq.frequency)
                .font(.system(size: 14, weight: isHighlighted ? .bold : .medium, design: .monospaced))
                .foregroundColor(isHighlighted ? .aviationGold : .secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isHighlighted ? Color.aviationGold.opacity(0.1) : Color.clear)
    }

    private func compactCTRRow(_ airspace: Airspace, distanceNM: Double) -> some View {
        let isActive = distanceNM <= 5.0 && airspace.containsAltitude(locationManager.currentAltitudeFeet)

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(airspace.shortName)
                        .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                        .foregroundColor(isActive ? .primaryText : .secondaryText)
                    if airspace.isMilitary {
                        Text("MIL")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2))
                            .cornerRadius(3)
                    }
                }
                if let freq = airspace.primaryFrequency {
                    Text(freq.name ?? freq.value)
                        .font(.system(size: 10))
                        .foregroundColor(.dimText)
                }
                Text(airspace.altitudeRangeString)
                    .font(.system(size: 8))
                    .foregroundColor(.dimText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(airspace.primaryFrequency?.value ?? "—")
                    .font(.system(size: 14, weight: isActive ? .bold : .medium, design: .monospaced))
                    .foregroundColor(isActive ? .aviationGold : .secondaryText)
                Text(String(format: "%.0fnm", distanceNM))
                    .font(.system(size: 10))
                    .foregroundColor(.dimText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isActive ? Color.aviationGold.opacity(0.1) : Color.clear)
    }

    // MARK: - State Update Helper

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

    /// Airports visible in the current map region (when airport overlay is enabled)
    /// Hidden automatically when OpenAIP overlay is active (OpenAIP provides its own airport symbols)
    // PR-11: the visible airports, their frequency lines, and the airspace polygons are cached in
    // @State and recomputed only when the visible region moves past a quantized threshold — not on
    // every body re-evaluation (e.g. every frame of a pan). `visibleAirports` is queried ONCE and
    // reused for the frequency lines, instead of being queried a second time.
    @State private var visibleAirports: [Airport] = []
    @State private var airportFrequencyLines: [String: String] = [:]
    @State private var visibleAirspacePolygons: [AirspacePolygon] = []
    @State private var lastSpatialRegion: MKCoordinateRegion?

    /// Region-quantization threshold (degrees) below which a region change skips re-querying. (PR-11)
    private static let spatialRequeryThresholdDegrees: Double = 0.01

    /// Whether the region moved or zoomed enough to warrant re-querying the visible map content.
    static func regionMovedSignificantly(
        from a: MKCoordinateRegion, to b: MKCoordinateRegion,
        threshold: Double = NavigationMapView.spatialRequeryThresholdDegrees
    ) -> Bool {
        abs(a.center.latitude - b.center.latitude) > threshold ||
        abs(a.center.longitude - b.center.longitude) > threshold ||
        abs(a.span.latitudeDelta - b.span.latitudeDelta) > threshold ||
        abs(a.span.longitudeDelta - b.span.longitudeDelta) > threshold
    }

    /// Recompute the cached spatial map content. Skips work when the region hasn't moved past the
    /// quantization threshold, unless `force` (a toggled setting / newly-available data). (PR-11)
    private func recomputeMapSpatialContent(force: Bool = false) {
        let region = mapState.region
        if !force, let last = lastSpatialRegion, !Self.regionMovedSignificantly(from: last, to: region) {
            return
        }
        lastSpatialRegion = region

        // Phase-aware frequencies depend on the nearest airport, so refresh them on a real move. (3.5 C2)
        recomputePhaseFrequencies()

        // Airports — queried once and reused below for the frequency lines.
        let airports: [Airport]
        if appState.settings.showAirportsOnMap, !appState.settings.showOpenAIPOverlay,
           airportDataService.isDataAvailable {
            let halfLat = region.span.latitudeDelta / 2
            let halfLon = region.span.longitudeDelta / 2
            airports = airportDataService.getAirportsInRegion(
                minLat: region.center.latitude - halfLat, maxLat: region.center.latitude + halfLat,
                minLon: region.center.longitude - halfLon, maxLon: region.center.longitude + halfLon,
                types: [.largeAirport, .mediumAirport, .smallAirport], limit: 100)
        } else {
            airports = []
        }
        visibleAirports = airports

        var freqLines: [String: String] = [:]
        if airportDataService.isDataAvailable {
            for airport in airports {
                let frequencies = airportDataService.getFrequencies(for: airport.ident)
                if !frequencies.isEmpty {
                    freqLines[airport.ident] = frequencies
                        .map { "\($0.type) \($0.formattedFrequency)" }
                        .joined(separator: "\n")
                }
            }
        }
        airportFrequencyLines = freqLines

        // Airspace polygons (prioritize restrictive airspaces, cap at 100).
        if appState.settings.showOpenAIPOverlay, openAIPDataService.isDataAvailable {
            let sorted = openAIPDataService.airspacesInBounds(region).sorted { a, b in
                if a.isRestrictive != b.isRestrictive { return a.isRestrictive }
                return a.airspaceType.rawValue < b.airspaceType.rawValue
            }
            visibleAirspacePolygons = Array(sorted.prefix(100)).compactMap { airspace in
                let coords = airspace.polygonCoordinates
                guard coords.count >= 3 else { return nil }
                var mutableCoords = coords
                return AirspacePolygon(airspace: airspace, coordinates: &mutableCoords, count: mutableCoords.count)
            }
        } else {
            visibleAirspacePolygons = []
        }
    }

    /// Pick the most relevant frequency from a list (TWR > ATIS > APP > first available)
    static func primaryFrequency(from frequencies: [AirportFrequency]) -> String? {
        let priorityTypes = ["TWR", "ATIS", "APP", "GND"]
        for type in priorityTypes {
            if let freq = frequencies.first(where: { $0.type.uppercased().contains(type) }) {
                return "\(type) \(freq.formattedFrequency)"
            }
        }
        if let first = frequencies.first {
            return "\(first.type) \(first.formattedFrequency)"
        }
        return nil
    }

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
                showOpenAIPOverlay: appState.settings.showOpenAIPOverlay,
                openAIPCacheManager: openAIPCacheManager,
                airspacePolygons: visibleAirspacePolygons,
                trackVectorOverlays: trackVectorOverlays,
                trackVectorEnabled: appState.settings.showTrackVector,
                currentWaypointIndex: currentWaypointIndex,
                locationUpdateCounter: locationUpdateCounter,
                visibleAirports: visibleAirports,
                airportFrequencyLines: airportFrequencyLines,
                cachedHeading: locationManager.currentCourseDegrees,
                onWaypointATOTap: { index in
                    flightPlanManager.recordATO(forWaypointAt: index)
                }
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
                currentWaypointIndex: currentWaypointIndex,
                locationUpdateCounter: locationUpdateCounter,
                visibleAirports: visibleAirports,
                airportFrequencyLines: airportFrequencyLines,
                cachedHeading: locationManager.currentCourseDegrees,
                showOpenAIPOverlay: appState.settings.showOpenAIPOverlay,
                openAIPCacheManager: openAIPCacheManager,
                airspacePolygons: visibleAirspacePolygons,
                trackVectorOverlays: trackVectorOverlays,
                trackVectorEnabled: appState.settings.showTrackVector,
                onWaypointATOTap: { index in
                    flightPlanManager.recordATO(forWaypointAt: index)
                }
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
                    .background(Color.panelBackground.opacity(0.92), in: Circle())
            }

            Spacer()

            // Time, Speed, Altitude, and Heading display
            // On iPhone (compact), use stacked layout; on iPad, use horizontal
            if isCompactWidth {
                // Stacked layout for iPhone
                VStack(spacing: 0) {
                    VStack(spacing: 4) {
                        // Time on first row
                        NavClockText(useUTC: appState.settings.alwaysUseUTC,
                                     font: .system(size: 14, weight: .medium, design: .monospaced),
                                     color: .primaryText)

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

                    // "Next Check" integrated in info box
                    if appState.isFlightActive {
                        Rectangle()
                            .fill(Color.dimText.opacity(0.3))
                            .frame(height: 0.5)

                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 10))
                            Text(appState.currentPhase.title)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.aviationGold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                }
                .background(Color.panelBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
            } else {
                // Horizontal layout for iPad
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        // Current time
                        NavClockText(useUTC: appState.settings.alwaysUseUTC,
                                     font: .system(size: 16, weight: .medium, design: .monospaced),
                                     color: .primaryText)

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

                        // Current phase, inline. When a cruise check is due it becomes a tappable amber
                        // ⟳ FREDA badge (tap to acknowledge); otherwise a plain gold phase label —
                        // a disabled Button was dimming the text. (3.5 — re-cruise)
                        if appState.isFlightActive {
                            Rectangle().fill(Color.dimText).frame(width: 1, height: 20)
                            if appState.cruiseCheckDue {
                                Button(action: { appState.acknowledgeCruiseCheck() }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .font(.system(size: 11, weight: .bold))
                                        Text(L10n.Nav.fredaCheck)
                                            .font(.system(size: 13, weight: .semibold))
                                            .lineLimit(1)
                                    }
                                    .foregroundColor(.aviationAmber)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Text(appState.currentPhase.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.aviationGold)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .fixedSize(horizontal: true, vertical: false)
                .background(Color.panelBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
            }

            Spacer()

            // Track-vector toggle — grouped with the airspace/layer map-display controls. (3.5 C4)
            Button(action: {
                appState.settings.showTrackVector.toggle()
                appState.saveSettings()
            }) {
                Image(systemName: "location.north.line")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(appState.settings.showTrackVector ? .aviationGold : .secondaryText)
                    .frame(width: 44, height: 44)
                    .background(Color.panelBackground.opacity(0.92), in: Circle())
            }
            .accessibilityLabel(L10n.Nav.trackVector)

            // OpenAIP overlay toggle
            Button(action: {
                appState.settings.showOpenAIPOverlay.toggle()
                appState.saveSettings()
            }) {
                Image(systemName: "shield")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(appState.settings.showOpenAIPOverlay ? .aviationGold : .secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(appState.settings.showOpenAIPOverlay
                                  ? Color.panelBackground.opacity(0.95)
                                  : Color.panelBackground.opacity(0.7))
                    )
            }

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
                .background(Color.panelBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
            }
            .sheet(isPresented: $showLayerPicker) {
                LayerPickerSheet(selectedLayer: $selectedLayer)
            }
        }
    }

    // MARK: - Bottom Controls

    /// The bottom assembly: a scale bar + offline/cache badge floating just above a full-width,
    /// two-row glass bar. Row 1 = NAV (next waypoint) + FREQ; row 2 = flight plan + GPS / tracking /
    /// zoom. (3.5 nav-chrome rebuild)
    private var bottomControls: some View {
        VStack(spacing: 0) {
            // Scale bar + offline/cache badge, left-aligned, above the bar.
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    if isOfflineMode || isCachedMode {
                        Button(action: { showCacheInfoModal = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "internaldrive.fill")
                                Text(isOfflineMode ? L10n.Nav.offline : L10n.Nav.cached)
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
                    SwissScaleBar(region: mapState.region, mapWidth: mapWidth, nauticalMiles: appState.settings.distanceInNauticalMiles)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            // Full-width bottom bar = the expandable flight-plan sheet, pinned to the bottom edge.
            VStack(spacing: 0) {
                if appState.settings.enableFlightPlanning {
                    navSheetHandle
                    if navSheetExpanded {
                        navSheetContent
                    } else {
                        navGlanceRow
                    }
                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
                }
                bottomControlRow
            }
            .background(
                Color.panelBackground.opacity(0.92)
                    .ignoresSafeArea(edges: .bottom)
            )
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.09)).frame(height: 0.5)
            }
        }
    }

    /// Grab handle — tap to toggle the flight-plan sheet, or drag up/down (snaps). (3.5 inc C)
    private var navSheetHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.22))
            .frame(width: 38, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.top, 7)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.28)) { navSheetExpanded.toggle() }
            }
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onEnded { value in
                        withAnimation(.easeInOut(duration: 0.28)) {
                            if value.translation.height < -24 { navSheetExpanded = true }
                            else if value.translation.height > 24 { navSheetExpanded = false }
                        }
                    }
            )
            .accessibilityLabel(L10n.Nav.flightPlan)
            .accessibilityAddTraits(.isButton)
    }

    /// Collapsed glance: nav data (LEFT) + frequency chip (RIGHT). Paradigm: left = nav, right = freq.
    private var navGlanceRow: some View {
        HStack(spacing: 10) {
            navGlanceData
            Spacer(minLength: 8)
            freqChip
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.28)) { navSheetExpanded = true } }
    }

    @ViewBuilder
    private var navGlanceData: some View {
        if let plan = flightPlanManager.activeFlightPlan, let next = plan.nextWaypoint {
            HStack(spacing: 6) {
                Text("WPT \(plan.currentWaypointIndex + 1)/\(plan.waypoints.count)")
                    .font(.system(size: 9, weight: .semibold)).tracking(0.3)
                    .foregroundColor(.dimText)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                Text(next.name.isEmpty ? "—" : next.name)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primaryText)
                if let distText = nextWaypointDistanceText {
                    Text("·").foregroundColor(.dimText)
                    Text(distText).font(.system(size: 13, design: .monospaced)).foregroundColor(.aviationGold)
                }
                if let brg = liveBearingText {
                    Text("·").foregroundColor(.dimText)
                    Text(brg).font(.system(size: 13, design: .monospaced)).foregroundColor(.secondaryText)
                }
                if let eto = next.estimatedTimeOver {
                    Text("·").foregroundColor(.dimText)
                    Text("ETO \(eto.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 13, design: .monospaced)).foregroundColor(.dimText)
                }
                if flightPlanManager.activeFlightPlan?.chronometerStartTime != nil {
                    Text("·").foregroundColor(.dimText)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(flightPlanManager.formattedChronometer)
                            .font(.system(size: 13, design: .monospaced)).foregroundColor(.aviationGreen)
                    }
                }
            }
            .lineLimit(1)
        } else {
            Text(L10n.Nav.flightPlan)
                .font(.system(size: 12)).foregroundColor(.dimText)
        }
    }

    /// Collapsed chip — the active (phase-relevant) frequency; tap expands the sheet to the full
    /// phase-aware list. (3.5 C2)
    private var freqChip: some View {
        let active = phaseFreqItems.first(where: { !$0.isEmergency }) ?? phaseFreqItems.first
        return Button(action: { withAnimation(.easeInOut(duration: 0.28)) { navSheetExpanded = true } }) {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 13))
                if let active {
                    Text(active.station).font(.system(size: 10, weight: .semibold)).tracking(0.3).lineLimit(1)
                    Text(active.freq).font(.system(size: 14, weight: .semibold, design: .monospaced))
                } else {
                    Text("FREQ").font(.system(size: 12, weight: .bold))
                }
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.dimText)
            }
            .foregroundColor(.aviationGold).lineLimit(1)
        }
        .accessibilityLabel(L10n.Nav.radioFrequencies)
    }

    private var liveBearingText: String? {
        guard let loc = locationManager.currentLocation,
              let brg = flightPlanManager.bearingToNextWaypoint(from: loc) else { return nil }
        return String(format: "%03d°", Int(brg))
    }

    // MARK: - Phase-aware frequencies (3.5 C2)

    private enum FreqPhaseGroup { case ground, enroute, arrival }

    /// Group the 16 phases into the freq-relevant contexts: departure field (ground/climb),
    /// enroute (area FIS/Info), or destination field (descent → shutdown).
    private func freqPhaseGroup(_ phase: ChecklistPhase) -> FreqPhaseGroup {
        switch phase {
        case .preflight, .beforeEngineStart, .engineStart, .afterEngineStart,
             .taxi, .runup, .beforeDeparture, .lineUp, .climb:
            return .ground
        case .cruise:
            return .enroute
        case .descent, .approach, .landing, .afterLanding, .shutdown, .hangar:
            return .arrival
        }
    }

    /// Priority order of airport frequency types to surface for the current phase.
    private func relevantFreqTypes(for phase: ChecklistPhase) -> [String] {
        switch phase {
        case .preflight, .beforeEngineStart: return ["ATIS", "GND", "TWR"]
        case .engineStart, .afterEngineStart: return ["GND", "ATIS", "TWR"]
        case .taxi: return ["GND", "TWR"]
        case .runup, .beforeDeparture, .lineUp, .climb: return ["TWR", "GND"]
        case .cruise: return ["ATIS"]
        case .descent, .approach: return ["ATIS", "APP", "TWR"]
        case .landing: return ["TWR", "APP"]
        case .afterLanding, .shutdown, .hangar: return ["GND", "ATIS"]
        }
    }

    private func areaFreqs(for sector: SwissAirspaceSector) -> [SwissCommonFrequency] {
        switch sector {
        case .zurich: return [.zurichInfo, .fisEast]
        case .geneva: return [.genevaInfo, .fisWest]
        case .east: return [.fisEast]
        case .west: return [.fisWest]
        }
    }

    /// Recompute the cached frequency list: the nearest field's VFR contact (regardless of plan, and
    /// highlighted as the active freq) + the route's departure / next / destination (auto-completed
    /// from the DB when a waypoint is an airfield) + area Info/FIS + emergency, deduped. Cached
    /// (recomputed on phase change + significant move). (3.5 — comprehensive route freqs)
    private func recomputePhaseFrequencies() {
        guard appState.settings.enableFlightPlanning else { phaseFreqItems = []; return }
        var items: [PhaseFrequency] = []
        var seen = Set<String>()
        func add(_ station: String, _ freq: String, highlighted: Bool = false, emergency: Bool = false) {
            let key = freq + "|" + station
            guard !seen.contains(key) else { return }
            seen.insert(key)
            items.append(PhaseFrequency(station: station, freq: freq, highlighted: highlighted, isEmergency: emergency))
        }

        // Nearest airfield — ATIS first (your first listen) then the contact frequency; regardless of
        // the flight plan. The first entry is highlighted as the active one.
        if let loc = locationManager.currentLocation, airportDataService.isDataAvailable,
           let apt = airportDataService.findNearestAirports(to: loc.coordinate, limit: 1, maxDistanceNm: 40).first {
            for (i, f) in airfieldFreqs(for: apt.ident).enumerated() {
                add("\(apt.ident) \(f.type)", f.freq, highlighted: i == 0)
            }
        }

        // Route: departure (first), the next target waypoint, and the destination (last) — manual
        // frequency if entered, else the airfield's ATIS + contact auto-completed from the DB.
        if let plan = flightPlanManager.activeFlightPlan, !plan.waypoints.isEmpty {
            var route: [FlightPlanWaypoint] = [plan.waypoints.first!]
            let idx = plan.currentWaypointIndex
            if plan.waypoints.indices.contains(idx) { route.append(plan.waypoints[idx]) }
            route.append(plan.waypoints.last!)
            for wp in route {
                for (label, freq) in waypointFreqs(wp) { add(label, freq) }
            }
        }

        // Area Info / FIS for the current Swiss sector.
        if let loc = locationManager.currentLocation, SwissAirspaceSectors.isInSwitzerland(loc.coordinate) {
            for sf in areaFreqs(for: SwissAirspaceSectors.getSector(for: loc.coordinate)) {
                add(sf.name, sf.frequency)
            }
        }

        // Emergency, always last.
        add(SwissCommonFrequency.emergency.name, SwissCommonFrequency.emergency.frequency, emergency: true)
        phaseFreqItems = items
    }

    /// An airfield's VFR frequencies: ATIS first when present (the first listen — it does NOT give you
    /// the next entity's frequency), then the contact frequency (TWR > AFIS > INFO > A/G > … — never
    /// the APP/GND that was being shown wrongly). (3.5)
    private static let contactPriority = ["TWR", "AFIS", "INFO", "A/G", "CTAF", "UNIC", "RDO"]
    private func airfieldFreqs(for ident: String) -> [(type: String, freq: String)] {
        let freqs = airportDataService.getFrequencies(for: ident)
        guard !freqs.isEmpty else { return [] }
        var out: [(String, String)] = []
        if let atis = freqs.first(where: { $0.type.uppercased().contains("ATIS") }) {
            out.append((atis.type, atis.formattedFrequency))
        }
        for type in Self.contactPriority {
            if let f = freqs.first(where: { $0.type.uppercased().contains(type) }) {
                out.append((f.type, f.formattedFrequency)); break
            }
        }
        if out.isEmpty, let f = freqs.first { out.append((f.type, f.formattedFrequency)) }
        return out
    }

    /// A waypoint's frequencies: the manually-entered one if set, else the airfield's ATIS + contact
    /// auto-completed from the DB when the waypoint name is an airfield ident. (3.5)
    private func waypointFreqs(_ wp: FlightPlanWaypoint) -> [(label: String, freq: String)] {
        let name = wp.name.isEmpty ? nil : wp.name
        if let f = wp.frequency, !f.isEmpty {
            return [(name ?? "WPT", f)]
        }
        if let ident = name, airportDataService.isDataAvailable {
            return airfieldFreqs(for: ident).map { ("\(ident) \($0.type)", $0.freq) }
        }
        return []
    }

    // MARK: - Track vector (3.5 C4)

    /// Update the EMA of ground speed + ground track on each GPS fix. Track is averaged via sin/cos so
    /// it never wraps; α≈0.15 favours recent fixes (~10 s time constant). (3.5 C4)
    private func updateTrackVectorEMA() {
        if let c = locationManager.currentLocation?.coordinate { lastKnownCoordinate = c }
        let gs = max(0, locationManager.currentSpeedKnots)
        let alpha = 0.15
        if !hasTrackVectorEMA {
            smoothedGroundSpeed = gs
            if let course = locationManager.currentCourseDegrees {
                smoothedTrackSin = sin(course * .pi / 180)
                smoothedTrackCos = cos(course * .pi / 180)
            }
            hasTrackVectorEMA = true
            return
        }
        smoothedGroundSpeed = alpha * gs + (1 - alpha) * smoothedGroundSpeed
        // Course is unreliable at very low speed — only fold it in while genuinely moving.
        if gs > 3, let course = locationManager.currentCourseDegrees {
            smoothedTrackSin = alpha * sin(course * .pi / 180) + (1 - alpha) * smoothedTrackSin
            smoothedTrackCos = alpha * cos(course * .pi / 180) + (1 - alpha) * smoothedTrackCos
        }
    }

    /// The trend-vector overlays (main line + 1/2/5-min perpendicular ticks) along the smoothed track.
    /// Empty when disabled, stationary (<5 kt), or no fix. (3.5 C4)
    private var trackVectorOverlays: [TrackVectorPolyline] {
        guard appState.settings.showTrackVector, hasTrackVectorEMA,
              let origin = locationManager.currentLocation?.coordinate ?? lastKnownCoordinate else { return [] }
        // TEMP DEBUG (bench testing): simulate 100 kt when actually stationary (<5 kt) so the vector
        // is visible without flying. Remove this fallback before merge — production hides below 5 kt.
        let gsKnots = smoothedGroundSpeed >= 5 ? smoothedGroundSpeed : 100.0
        let track = atan2(smoothedTrackSin, smoothedTrackCos) * 180 / .pi
        let gsMS = gsKnots * 0.514444 // knots → m/s
        var overlays: [TrackVectorPolyline] = []
        // Each segment is drawn twice: a dark casing first (below) + the bright core on top — so it
        // stays legible on the busy/light Segelflugkarte AND on dark satellite imagery. (3.5 fix)
        func addSegment(_ coords: [CLLocationCoordinate2D]) {
            var casing = coords
            overlays.append(TrackVectorCasingPolyline(coordinates: &casing, count: coords.count))
            var core = coords
            overlays.append(TrackVectorPolyline(coordinates: &core, count: coords.count))
        }
        let end = projectedCoordinate(from: origin, bearingDeg: track, distanceMeters: gsMS * 300) // 5 min
        addSegment([origin, end])
        let tickHalf = max(120.0, gsMS * 5)
        for minutes in [1.0, 2.0, 5.0] {
            let pt = projectedCoordinate(from: origin, bearingDeg: track, distanceMeters: gsMS * 60 * minutes)
            let a = projectedCoordinate(from: pt, bearingDeg: track + 90, distanceMeters: tickHalf)
            let b = projectedCoordinate(from: pt, bearingDeg: track - 90, distanceMeters: tickHalf)
            addSegment([a, b])
        }
        return overlays
    }

    /// Geodesic forward projection: a coordinate `distanceMeters` from `c` along `bearingDeg`. (3.5 C4)
    private func projectedCoordinate(from c: CLLocationCoordinate2D, bearingDeg: Double, distanceMeters: Double) -> CLLocationCoordinate2D {
        let R = 6_371_000.0
        let d = distanceMeters / R
        let t = bearingDeg * .pi / 180
        let lat1 = c.latitude * .pi / 180
        let lon1 = c.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(t))
        let lon2 = lon1 + atan2(sin(t) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }

    /// Expanded sheet — LEFT column = flight-plan/nav (chrono, waypoint list, live data, progress);
    /// RIGHT column = phase-aware frequencies. (3.5 inc C / C2 — paradigm: left = nav, right = freq)
    @ViewBuilder
    private var navSheetContent: some View {
        if let plan = flightPlanManager.activeFlightPlan {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    chronometerHeader(plan: plan)
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)
                    waypointList(plan: plan)
                    liveDataRow
                    progressRow(plan: plan)
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                // The column divider is drawn as a trailing overlay (bounded by this column's content
                // height) — a standalone `Rectangle().frame(width:)` has NO height and is greedy in Y,
                // which ballooned the whole sheet. (3.5 fix — 3rd attempt)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(width: 0.5)
                }

                freqColumn
                    .frame(width: 244)
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
                    .padding(.bottom, 10)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            // No flight plan — the frequency list (nearest + area + emergency) doesn't need a plan, so
            // expanding still shows it. (3.5 fix — the chevron did nothing without a plan)
            freqColumn
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 10)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The frequency column — the essentials (nearest + route, capped) with emergency always shown and
    /// a "show all / show less" toggle for the rest. (3.5 — feedback: cap to essentials)
    private var freqColumn: some View {
        let nonEmergency = phaseFreqItems.filter { !$0.isEmergency }
        let emergency = phaseFreqItems.filter { $0.isEmergency }
        let cap = 4
        let canCollapse = nonEmergency.count > cap
        let visible = (showAllFreqs || !canCollapse) ? nonEmergency : Array(nonEmergency.prefix(cap))
        return VStack(alignment: .leading, spacing: 0) {
            Text("\(L10n.Nav.radioFrequencies) · \(appState.currentPhase.title)")
                .font(.system(size: 9, weight: .semibold)).tracking(0.4)
                .foregroundColor(.altimeterBlue)
                .lineLimit(1)
                .padding(.bottom, 4)
            ForEach(visible) { freqRow($0) }
            if canCollapse {
                Button(action: { withAnimation { showAllFreqs.toggle() } }) {
                    HStack(spacing: 3) {
                        Text(showAllFreqs ? L10n.Nav.showLess : "\(L10n.Nav.allFrequencies) (\(nonEmergency.count))")
                        Image(systemName: showAllFreqs ? "chevron.up" : "chevron.down").font(.system(size: 9))
                    }
                    .font(.system(size: 10)).foregroundColor(.dimText)
                }
                .padding(.vertical, 3)
            }
            ForEach(emergency) { freqRow($0) }
        }
    }

    private func freqRow(_ item: PhaseFrequency) -> some View {
        HStack(spacing: 6) {
            Text(item.station)
                .font(.system(size: 11, weight: item.highlighted ? .semibold : .regular))
                .foregroundColor(item.isEmergency ? .aviationRed : .secondaryText)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(item.freq)
                .font(.system(size: 13, weight: item.highlighted ? .bold : .regular, design: .monospaced))
                .foregroundColor(item.highlighted ? .aviationGold : .primaryText)
        }
        .padding(.vertical, 3)
    }

    private func chronometerHeader(plan: FlightPlan) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.Nav.chronometer)
                    .font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundColor(.dimText)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(flightPlanManager.formattedChronometer)
                        .font(.system(size: 24, weight: .bold, design: .monospaced)).foregroundColor(.aviationGreen)
                }
            }
            Spacer()
            if plan.chronometerStartTime == nil {
                Button(action: { flightPlanManager.startChronometer() }) {
                    Text(L10n.Nav.start).font(.system(size: 12, weight: .bold)).foregroundColor(.black)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Color.aviationGreen, in: RoundedRectangle(cornerRadius: 7))
                }
            } else {
                Button(action: { flightPlanManager.stopChronometer() }) {
                    Text(L10n.Nav.stop).font(.system(size: 12, weight: .bold)).foregroundColor(.black)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Color.aviationAmber, in: RoundedRectangle(cornerRadius: 7))
                }
            }
            Button(action: { flightPlanManager.resetChronometer() }) {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 14)).foregroundColor(.secondaryText)
                    .frame(width: 38, height: 32)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
            .accessibilityLabel(L10n.Nav.chronometer)
        }
    }

    private func waypointList(plan: FlightPlan) -> some View {
        // Deterministic height (content for ≤5 waypoints, scroll beyond) — a greedy ScrollView made
        // the whole sheet balloon to fill the screen. Keep the sheet as short as the content. (3.5 fix)
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(plan.waypoints.enumerated()), id: \.element.id) { index, wpt in
                    waypointRow(plan: plan, index: index, wpt: wpt)
                    if index < plan.waypoints.count - 1 {
                        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
                    }
                }
            }
        }
        .frame(height: CGFloat(min(max(plan.waypoints.count, 1), 5)) * 36)
    }

    private func waypointRow(plan: FlightPlan, index: Int, wpt: FlightPlanWaypoint) -> some View {
        let isCurrent = index == plan.currentWaypointIndex
        let isPast = index < plan.currentWaypointIndex
        let isPreview = previewWaypointIndex == index
        let leg = plan.legArriving(at: index)
        return Button(action: { previewWaypoint(index: index, plan: plan) }) {
            HStack(spacing: 8) {
                Image(systemName: isPast ? "circle.fill" : (isCurrent ? "location.fill" : "circle"))
                    .font(.system(size: 9))
                    .foregroundColor(isPast ? .aviationGreen : (isCurrent ? .aviationGold : .dimText))
                Text(wpt.name.isEmpty ? "WPT \(index + 1)" : wpt.name)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular, design: .monospaced))
                    .foregroundColor(isCurrent ? .aviationGold : .primaryText)
                Spacer()
                HStack(spacing: 8) {
                    if let mc = leg?.magneticCourse {
                        Text(String(format: "%03d°", Int(mc))).foregroundColor(.secondaryText)
                    }
                    if let d = leg?.distance {
                        Text(String(format: "%.1f", d)).foregroundColor(.secondaryText)
                    }
                    if let ato = wpt.actualTimeOver {
                        Text("ATO \(ato.formatted(date: .omitted, time: .shortened))").foregroundColor(.aviationGreen)
                    } else if let eto = wpt.estimatedTimeOver {
                        Text("ETO \(eto.formatted(date: .omitted, time: .shortened))").foregroundColor(.dimText)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(isPreview ? Color.altimeterBlue.opacity(0.14)
                        : (isCurrent ? Color.aviationGold.opacity(0.10) : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Tap a waypoint to preview (centre the map on it); tap the active/previewed one to return.
    private func previewWaypoint(index: Int, plan: FlightPlan) {
        guard plan.waypoints.indices.contains(index) else { return }
        if previewWaypointIndex == index || index == plan.currentWaypointIndex {
            previewWaypointIndex = nil
            centerOnAircraft()
        } else {
            previewWaypointIndex = index
            isFollowingAircraft = false
            let wpt = plan.waypoints[index]
            mapState.updateFromRegion(MKCoordinateRegion(center: wpt.coordinate, span: mapState.region.span))
        }
    }

    private var liveDataRow: some View {
        HStack(spacing: 16) {
            if let loc = locationManager.currentLocation {
                if let brg = flightPlanManager.bearingToNextWaypoint(from: loc) {
                    liveStat(L10n.Nav.hdgTo, String(format: "%03d°", Int(brg)))
                }
                if let d = flightPlanManager.distanceToNextWaypoint(from: loc) {
                    liveStat(L10n.Nav.dist, String(format: "%.1f", d))
                }
                let gs = max(locationManager.currentSpeedKnots, 1)
                if let eta = flightPlanManager.etaToNextWaypoint(from: loc, groundSpeedKnots: gs) {
                    liveStat("ETA", Date().addingTimeInterval(eta).formatted(date: .omitted, time: .shortened))
                }
            }
            if appState.lineUpTime != nil {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    liveStat(L10n.FlightPlan.fltTime, flightTimeText)
                }
            }
            Spacer()
        }
    }

    private func liveStat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundColor(.dimText)
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondaryText)
        }
    }

    private var flightTimeText: String {
        guard let t = appState.lineUpTime else { return "--:--:--" }
        let e = max(0, Int(Date().timeIntervalSince(t)))
        return String(format: "%02d:%02d:%02d", e / 3600, (e % 3600) / 60, e % 60)
    }

    private func progressRow(plan: FlightPlan) -> some View {
        HStack(spacing: 10) {
            ProgressView(value: plan.progress)
                .progressViewStyle(.linear)
                .tint(.aviationGreen)
            HStack(spacing: 3) {
                ForEach(0..<plan.waypoints.count, id: \.self) { i in
                    Circle()
                        .fill(i < plan.currentWaypointIndex ? Color.aviationGreen
                              : (i == plan.currentWaypointIndex ? Color.aviationGold : Color.dimText.opacity(0.5)))
                        .frame(width: 5, height: 5)
                }
            }
        }
    }

    /// Row 2 — flight plan (left, when relevant) and GPS / tracking / zoom (right). (3.5)
    /// Destination endpoint, total remaining distance (live to next + remaining planned legs), and the
    /// planned ETA at the destination. (3.5 — row 2)
    private var destinationSummary: (dest: String, remainingNM: Double, eta: Date?)? {
        guard let plan = flightPlanManager.activeFlightPlan,
              plan.waypoints.count >= 2,
              let dest = plan.waypoints.last else { return nil }
        var remaining = 0.0
        if let loc = locationManager.currentLocation,
           let d = flightPlanManager.distanceToNextWaypoint(from: loc) {
            remaining += d
        }
        if plan.currentWaypointIndex + 1 < plan.waypoints.count {
            for i in (plan.currentWaypointIndex + 1)..<plan.waypoints.count {
                remaining += plan.legArriving(at: i)?.distance ?? 0
            }
        }
        let name = dest.name.isEmpty ? "WPT \(plan.waypoints.count)" : dest.name
        return (name, remaining, dest.estimatedTimeOver)
    }

    @ViewBuilder
    private var destinationSummaryView: some View {
        if let s = destinationSummary {
            HStack(spacing: 6) {
                Text("DEST")
                    .font(.system(size: 9, weight: .semibold)).tracking(0.4)
                    .foregroundColor(.dimText)
                Text(s.dest)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primaryText)
                Text("·").foregroundColor(.dimText)
                Text(String(format: "%.0f NM", s.remainingNM))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondaryText)
                if let eta = s.eta {
                    Text("·").foregroundColor(.dimText)
                    Text("ETA \(eta.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.dimText)
                }
            }
            .lineLimit(1)
        }
    }

    private var bottomControlRow: some View {
        HStack(spacing: 12) {
            if appState.settings.enableFlightPlanning {
                Button(action: { showFlightPlanning = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.system(size: 17, weight: .medium))
                        if flightPlanManager.activeFlightPlan != nil {
                            Circle().fill(Color.aviationGreen).frame(width: 7, height: 7)
                        }
                    }
                    .foregroundColor(flightPlanManager.activeFlightPlan != nil ? .aviationGreen : .primaryText)
                    .frame(width: 50, height: 40)
                    .contentShape(Rectangle())
                }
                .fullScreenCover(isPresented: $showFlightPlanning) {
                    FlightPlanningView()
                        .environmentObject(appState)
                        .environmentObject(flightPlanManager)
                        .environmentObject(airportDataService)
                        .environmentObject(aircraftDataService)
                        .environmentObject(openAIPDataService)
                }
            }

            // Destination summary — endpoint + total remaining + ETA, so the drawer is only needed for
            // the mid-route outlook. (3.5 — device feedback)
            destinationSummaryView

            Spacer()

            // GPS status (tap for the info sheet)
            Button(action: { showGPSStatusModal = true }) {
                HStack(spacing: 6) {
                    StatusIndicator(gpsStatusIndicator, size: 8)
                    Text("GPS")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primaryText)
                }
                .padding(.horizontal, 6)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .fullScreenCover(isPresented: $showGPSStatusModal) {
                GPSStatusInfoSheet(currentStatus: locationManager.gpsSignalStatus, isPresented: $showGPSStatusModal)
            }

            // Single tracking button: free → center & follow → track-up → free.
            Button(action: cycleTracking) {
                Image(systemName: trackingIcon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(trackingTint)
                    .frame(width: 46, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.Nav.navigation)
            .animation(.easeInOut(duration: 0.2), value: mapState.cameraHeading)

            // Zoom out / in (kept for gloved / turbulence use, docked far-right).
            HStack(spacing: 0) {
                Button(action: { zoom(by: 2.0) }) {
                    Image(systemName: "minus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primaryText)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.Nav.zoomOut)
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 0.5, height: 22)
                Button(action: { zoom(by: 0.5) }) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primaryText)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.Nav.zoomIn)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.14), lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Live distance to the next waypoint (NM), if a fix + plan are available. (3.5)
    private var nextWaypointDistanceText: String? {
        guard let loc = locationManager.currentLocation,
              let dist = flightPlanManager.distanceToNextWaypoint(from: loc) else { return nil }
        return String(format: "%.1f NM", dist)
    }

    // MARK: - Actions

    private func centerOnAircraft() {
        guard let location = locationManager.currentLocation else { return }

        isFollowingAircraft = true

        // Re-center WITHOUT changing the zoom. Forcing a fixed span here previously cropped the
        // visible airports out of the freshly re-queried region whenever follow was engaged. (3.5 fix)
        let newRegion = MKCoordinateRegion(
            center: location.coordinate,
            span: mapState.region.span
        )
        mapState.updateFromRegion(newRegion)
        // Respect orientation mode: only set heading for track-up (use cached heading)
        if mapOrientationMode == .trackUp, let course = locationManager.currentCourseDegrees {
            mapState.cameraHeading = course
        }
    }

    private func toggleOrientation() {
        switch mapOrientationMode {
        case .northUp:
            mapOrientationMode = .trackUp
            // Set heading to current course (use cached heading for stability)
            if let course = locationManager.currentCourseDegrees {
                mapState.cameraHeading = course
            }
        case .trackUp:
            mapOrientationMode = .northUp
            mapState.requestHeadingReset()
        }
        // Save to session state
        appState.navigationMapState.orientationMode = mapOrientationMode
    }

    /// Single tracking button: each tap advances an Apple-Maps-style cycle —
    /// free → center & follow (north-up) → track-up (rotate with heading) → free. (3.5 nav-chrome rebuild)
    private func cycleTracking() {
        if !isFollowingAircraft {
            // free → center & follow, north-up
            if mapOrientationMode == .trackUp {
                mapOrientationMode = .northUp
                mapState.requestHeadingReset()
            }
            isFollowingAircraft = true
            centerOnAircraft()
        } else if mapOrientationMode == .northUp {
            // center & follow → track-up
            mapOrientationMode = .trackUp
            centerOnAircraft()
        } else {
            // track-up → free
            isFollowingAircraft = false
            mapOrientationMode = .northUp
            mapState.requestHeadingReset()
        }
        appState.navigationMapState.orientationMode = mapOrientationMode
    }

    /// SF Symbol reflecting the current tracking state.
    private var trackingIcon: String {
        if !isFollowingAircraft { return "location" }
        return mapOrientationMode == .trackUp ? "location.north.line.fill" : "location.fill"
    }

    /// Tint for the tracking button — gold once engaged.
    private var trackingTint: Color {
        isFollowingAircraft ? .aviationGold : .primaryText
    }

    /// Zoom the live map by scaling the current region span (factor < 1 zooms in). `mapState.region`
    /// is kept current by the map's `regionDidChangeAnimated`, so this reads the true zoom. (3.5)
    private func zoom(by factor: Double) {
        // The map camera is distance-driven (setCamera fromDistance: mapState.cameraDistance), so a
        // span-only change never zoomed the tile layers — it just got reverted by regionDidChange.
        // Scale the camera distance AND nudge the region so updateUIView re-applies the camera. (3.5 fix)
        mapState.cameraDistance = min(max(mapState.cameraDistance * factor, 800), 4_000_000)
        let r = mapState.region
        let lat = min(max(r.span.latitudeDelta * factor, 0.0015), 80)
        let lon = min(max(r.span.longitudeDelta * factor, 0.0015), 80)
        mapState.updateFromRegion(
            MKCoordinateRegion(center: r.center, span: MKCoordinateSpan(latitudeDelta: lat, longitudeDelta: lon))
        )
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
                .fill(.regularMaterial)
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
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var openAIPDataService: OpenAIPDataService
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool
    let containerSize: CGSize

    @State private var streamingCTRCheckTask: Task<Void, Never>?

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
                Text(L10n.Nav.radioFrequencies)
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
                            Text(L10n.Nav.noFrequenciesInFlightPlan)
                                .font(.system(size: 12))
                                .foregroundColor(.secondaryText)
                                .padding()
                        } else {
                            ForEach(Array(frequenciesWithWaypoints.enumerated()), id: \.element.id) { index, waypoint in
                                frequencyRow(waypoint: waypoint, isCurrent: waypoint.id == plan.currentWaypointId)

                                if index < frequenciesWithWaypoints.count - 1 {
                                    Divider()
                                        .background(Color.dimText)
                                }
                            }
                        }

                        // Nearby airport frequencies section
                        nearbyAirportFrequenciesSection

                        // Nearby Controlled Airspace section
                        controlledAirspaceSection

                        // Area frequencies section (Swiss only)
                        if isInSwissAirspace {
                            Divider()
                                .background(Color.dimText)
                                .padding(.vertical, 4)

                            Text(L10n.Nav.areaFrequencies)
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
                        }
                    } else {
                        // No active flight plan - show message and common frequencies
                        Text(L10n.Nav.noActiveFlightPlan)
                            .font(.system(size: 12))
                            .foregroundColor(.secondaryText)
                            .padding()

                        // Nearby airport frequencies section
                        nearbyAirportFrequenciesSection

                        // Nearby Controlled Airspace section
                        controlledAirspaceSection

                        // Area frequencies section (Swiss only)
                        if isInSwissAirspace {
                            Divider()
                                .background(Color.dimText)
                                .padding(.vertical, 4)

                            Text(L10n.Nav.areaFrequencies)
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
                        }
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
        .onAppear {
            // Trigger streaming CTR fetch if enabled and no downloaded data
            if appState.settings.enableAirspaceStreaming && !openAIPDataService.isDataAvailable,
               let coord = locationManager.currentLocation?.coordinate {
                Task { await openAIPDataService.fetchStreamingCTRsIfNeeded(from: coord) }
            }
        }
        .onDisappear {
            streamingCTRCheckTask?.cancel()
            streamingCTRCheckTask = nil
        }
        .onChange(of: locationManager.currentLocation) { _, newLocation in
            // Debounced streaming CTR fetch (5s delay)
            if appState.settings.enableAirspaceStreaming && !openAIPDataService.isDataAvailable {
                streamingCTRCheckTask?.cancel()
                streamingCTRCheckTask = Task {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled, let coord = newLocation?.coordinate else { return }
                    await openAIPDataService.fetchStreamingCTRsIfNeeded(from: coord)
                }
            }
        }
    }

    /// Whether the pilot is currently within Swiss airspace (for showing area frequencies)
    private var isInSwissAirspace: Bool {
        guard let location = locationManager.currentLocation else { return false }
        return SwissAirspaceSectors.isInSwitzerland(location.coordinate)
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
                Text(waypoint.name.isEmpty ? L10n.Nav.waypoint : waypoint.name)
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

    /// Section displaying nearby airport frequencies from OurAirports data
    @ViewBuilder
    private var nearbyAirportFrequenciesSection: some View {
        let airports = nearbyAirportFrequencies
        if !airports.isEmpty {
            Divider()
                .background(Color.dimText)
                .padding(.vertical, 4)

            Text(L10n.Nav.nearbyAirportFrequencies)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.dimText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

            ForEach(airports, id: \.airport.id) { item in
                let isNearby = item.distanceNM <= 5.0
                VStack(alignment: .leading, spacing: 0) {
                    // Airport header
                    HStack {
                        Text(item.airport.ident)
                            .font(.system(size: 11, weight: isNearby ? .bold : .semibold))
                            .foregroundColor(isNearby ? .aviationGold : .primaryText)
                        Text(item.airport.name)
                            .font(.system(size: 10))
                            .foregroundColor(.secondaryText)
                            .lineLimit(1)
                        Spacer()
                        Text(String(format: "%.0fnm", item.distanceNM))
                            .font(.system(size: 9))
                            .foregroundColor(.dimText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)

                    // Individual frequencies
                    ForEach(item.frequencies) { freq in
                        HStack {
                            Text(freq.type)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondaryText)
                                .frame(width: 35, alignment: .leading)
                            if let desc = freq.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.system(size: 9))
                                    .foregroundColor(.dimText)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(freq.formattedFrequency)
                                .font(.system(size: 12, weight: isNearby ? .bold : .medium, design: .monospaced))
                                .foregroundColor(isNearby ? .aviationGold : .secondaryText)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                    }
                }
                .background(isNearby ? Color.aviationGold.opacity(0.1) : Color.clear)

                if item.airport.id != airports.last?.airport.id {
                    Divider()
                        .background(Color.dimText.opacity(0.5))
                }
            }
        }
    }

    /// Get nearby airports with their frequencies from OurAirports data
    private var nearbyAirportFrequencies: [(airport: Airport, frequencies: [AirportFrequency], distanceNM: Double)] {
        guard let location = locationManager.currentLocation,
              airportDataService.isDataAvailable else { return [] }
        let nearbyAirports = airportDataService.findNearestAirports(
            to: location.coordinate,
            limit: 5,
            maxDistanceNm: 15.0
        )
        return nearbyAirports.compactMap { (airport: Airport) -> (airport: Airport, frequencies: [AirportFrequency], distanceNM: Double)? in
            let frequencies = airportDataService.getFrequencies(for: airport.ident)
            guard !frequencies.isEmpty else { return nil }
            let distanceNM = airport.distance(from: location.coordinate)
            return (airport: airport, frequencies: frequencies, distanceNM: distanceNM)
        }
    }

    /// Whether OpenAIP CTR data is available for the controlled airspace section (downloaded or streamed)
    private var hasOpenAIPCTRData: Bool {
        openAIPDataService.isDataAvailable || (appState.settings.enableAirspaceStreaming && !openAIPDataService.streamingCTRs.isEmpty)
    }

    /// Get nearby CTRs from OpenAIP airspace data (downloaded or streamed)
    private var nearbyCTRs: [(airspace: Airspace, distanceNM: Double)] {
        guard let location = locationManager.currentLocation else { return [] }
        // Primary: full downloaded data
        if openAIPDataService.isDataAvailable {
            return Array(openAIPDataService.nearbyCTRs(from: location.coordinate).prefix(5))
        }
        // Streaming fallback (when enabled)
        if appState.settings.enableAirspaceStreaming {
            return Array(openAIPDataService.streamingCTRs.prefix(5))
        }
        return []
    }

    /// Get nearby airports with TWR frequencies as fallback when OpenAIP is unavailable
    private var fallbackTWRAirports: [(airport: Airport, twrFrequencies: [AirportFrequency], distanceNM: Double)] {
        guard let location = locationManager.currentLocation,
              airportDataService.isDataAvailable else { return [] }
        let nearbyAirports = airportDataService.findNearestAirports(
            to: location.coordinate,
            limit: 8,
            maxDistanceNm: 20.0
        )
        return nearbyAirports.compactMap { airport -> (airport: Airport, twrFrequencies: [AirportFrequency], distanceNM: Double)? in
            let frequencies = airportDataService.getFrequencies(for: airport.ident)
            let twrFreqs = frequencies.filter { $0.type == "TWR" }
            guard !twrFreqs.isEmpty else { return nil }
            let distanceNM = airport.distance(from: location.coordinate)
            return (airport: airport, twrFrequencies: twrFreqs, distanceNM: distanceNM)
        }
    }

    /// The "Nearby Controlled Airspace" section — uses OpenAIP if available (downloaded or streamed), OurAirports TWR as fallback
    @ViewBuilder
    private var controlledAirspaceSection: some View {
        let ctrs = nearbyCTRs
        // OurAirports fallback only if no OpenAIP data (downloaded or streamed) available
        let fallback = (!ctrs.isEmpty || openAIPDataService.isDataAvailable) ? [] : fallbackTWRAirports

        if !ctrs.isEmpty || !fallback.isEmpty {
            Divider()
                .background(Color.dimText)
                .padding(.vertical, 4)

            Text(L10n.Nav.nearbyControlledAirspace)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.dimText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

            if !ctrs.isEmpty {
                // OpenAIP CTR data (primary)
                ForEach(ctrs, id: \.airspace.id) { item in
                    ctrFrequencyRow(item.airspace, distanceNM: item.distanceNM)
                    if item.airspace.id != ctrs.last?.airspace.id {
                        Divider()
                            .background(Color.dimText.opacity(0.5))
                    }
                }
            } else {
                // OurAirports TWR fallback
                ForEach(fallback, id: \.airport.id) { item in
                    fallbackTWRRow(item.airport, twrFrequencies: item.twrFrequencies, distanceNM: item.distanceNM)
                    if item.airport.id != fallback.last?.airport.id {
                        Divider()
                            .background(Color.dimText.opacity(0.5))
                    }
                }
            }
        }
    }

    private func ctrFrequencyRow(_ airspace: Airspace, distanceNM: Double) -> some View {
        let isActive = distanceNM <= 5.0 && airspace.containsAltitude(locationManager.currentAltitudeFeet)

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(airspace.shortName)
                        .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                        .foregroundColor(isActive ? .primaryText : .secondaryText)
                    if airspace.isMilitary {
                        Text("MIL")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2))
                            .cornerRadius(3)
                    }
                }
                if let freq = airspace.primaryFrequency {
                    Text(freq.name ?? freq.value)
                        .font(.system(size: 9))
                        .foregroundColor(.dimText)
                }
                Text(airspace.altitudeRangeString)
                    .font(.system(size: 8))
                    .foregroundColor(.dimText)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(airspace.primaryFrequency?.value ?? "—")
                    .font(.system(size: 12, weight: isActive ? .bold : .medium, design: .monospaced))
                    .foregroundColor(isActive ? .aviationGold : .secondaryText)
                Text(String(format: "%.0fnm", distanceNM))
                    .font(.system(size: 9))
                    .foregroundColor(.dimText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isActive ? Color.aviationGold.opacity(0.1) : Color.clear)
    }

    /// Fallback row showing OurAirports TWR frequency when OpenAIP data isn't available
    private func fallbackTWRRow(_ airport: Airport, twrFrequencies: [AirportFrequency], distanceNM: Double) -> some View {
        let isNearby = distanceNM <= 5.0

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(airport.ident)
                    .font(.system(size: 11, weight: isNearby ? .semibold : .regular))
                    .foregroundColor(isNearby ? .primaryText : .secondaryText)
                Text(airport.name)
                    .font(.system(size: 9))
                    .foregroundColor(.dimText)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(twrFrequencies.first?.formattedFrequency ?? "—")
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
/// A transient FREDA cruise-check reminder banner. Appears when `appState.cruiseCheckDue` flips true
/// and auto-dismisses after 30 s (the amber phase indicator persists until acknowledged). Reusable
/// across the nav map and the flight HUD. (3.5 — re-cruise)
struct CruiseCheckReminderModifier: ViewModifier {
    @ObservedObject var appState: AppState
    @State private var show = false
    @State private var dismissWork: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if show {
                    banner
                        .padding(.top, 64)
                        .padding(.horizontal, 40)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onChange(of: appState.cruiseCheckDue) { _, due in
                dismissWork?.cancel()
                if due {
                    withAnimation(.spring(response: 0.4)) { show = true }
                    let work = DispatchWorkItem { withAnimation { show = false } }
                    dismissWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
                } else {
                    withAnimation { show = false }
                }
            }
    }

    private var banner: some View {
        Button(action: {
            appState.acknowledgeCruiseCheck()
            withAnimation { show = false }
        }) {
            HStack(spacing: 11) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 17, weight: .bold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.Nav.cruiseCheckDue).font(.system(size: 13, weight: .bold))
                    Text(L10n.Nav.cruiseCheckHint).font(.system(size: 11)).opacity(0.85)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark.circle.fill").font(.system(size: 20))
            }
            .foregroundColor(.black)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .frame(maxWidth: 460)
            .background(Color.aviationAmber, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}

extension View {
    func cruiseCheckReminder(appState: AppState) -> some View {
        modifier(CruiseCheckReminderModifier(appState: appState))
    }
}

/// One phase-aware frequency row for the flight-plan sheet (station label + frequency). (3.5 C2)
struct PhaseFrequency: Identifiable {
    let id = UUID()
    let station: String
    let freq: String
    let highlighted: Bool
    let isEmergency: Bool
}

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
    /// Check if a coordinate is within Swiss airspace bounds (approximate)
    static func isInSwitzerland(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude >= 45.8 && coordinate.latitude <= 47.9 &&
        coordinate.longitude >= 5.9 && coordinate.longitude <= 10.6
    }

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

// MARK: - Swiss Scale Bar (mimics SwissTopo style)

struct SwissScaleBar: View {
    let region: MKCoordinateRegion
    var mapWidth: CGFloat = 0  // Actual map width in points, 0 means use fallback
    /// Aviation distance unit: NM (default for the nav map) vs metric. (3.5 — configurable in settings)
    var nauticalMiles: Bool = false

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

        // Choose appropriate scale - pick the largest round number that fits. Aviation uses NM. (3.5)
        let nmScales: [(meters: Double, text: String)] = [
            (185.2, "0.1 NM"), (370.4, "0.2 NM"), (926, "0.5 NM"),
            (1852, "1 NM"), (3704, "2 NM"), (9260, "5 NM"),
            (18520, "10 NM"), (37040, "20 NM"), (92600, "50 NM"),
            (185200, "100 NM"), (370400, "200 NM")
        ]
        let metricScales: [(meters: Double, text: String)] = [
            (10, "10 m"), (20, "20 m"), (50, "50 m"), (100, "100 m"),
            (200, "200 m"), (500, "500 m"), (1000, "1 km"), (2000, "2 km"),
            (5000, "5 km"), (10000, "10 km"), (20000, "20 km"), (50000, "50 km"),
            (100000, "100 km"), (200000, "200 km")
        ]
        let scales: [(meters: Double, text: String)] = nauticalMiles ? nmScales : metricScales

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

/// Cache of rendered waypoint marker images keyed by waypoint state ("current"/"completed"/
/// "future"). The stroke-outlined marker is identical for every waypoint in a given state but was
/// re-rendered via UIGraphics for each annotation; there are only three distinct images. Accessed
/// only from main-thread MapKit delegate callbacks. Shared by both map representables. (PR-10)
private var waypointMarkerImageCache: [String: UIImage] = [:]

private func cachedWaypointMarker(state: String, iconName: String, color: UIColor, size: CGFloat = 24) -> UIImage? {
    if let cached = waypointMarkerImageCache[state] { return cached }

    let config = UIImage.SymbolConfiguration(pointSize: size, weight: .bold)
    guard let image = UIImage(systemName: iconName, withConfiguration: config) else { return nil }

    let strokeWidth: CGFloat = 2.0
    let imageSize = CGSize(width: image.size.width + strokeWidth * 2,
                           height: image.size.height + strokeWidth * 2)
    UIGraphicsBeginImageContextWithOptions(imageSize, false, 0)
    defer { UIGraphicsEndImageContext() }

    let offsets: [CGPoint] = [
        CGPoint(x: -strokeWidth, y: 0), CGPoint(x: strokeWidth, y: 0),
        CGPoint(x: 0, y: -strokeWidth), CGPoint(x: 0, y: strokeWidth),
    ]
    let strokeImage = image.withTintColor(.black, renderingMode: .alwaysOriginal)
    for offset in offsets {
        strokeImage.draw(at: CGPoint(x: strokeWidth + offset.x, y: strokeWidth + offset.y))
    }
    let tintedImage = image.withTintColor(color, renderingMode: .alwaysOriginal)
    tintedImage.draw(at: CGPoint(x: strokeWidth, y: strokeWidth))

    let finalImage = UIGraphicsGetImageFromCurrentImageContext()
    if let finalImage { waypointMarkerImageCache[state] = finalImage }
    return finalImage
}

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
    var locationUpdateCounter: Int = 0  // Forces updateUIView on every location change
    var visibleAirports: [Airport] = []  // Airports to display on map
    var airportFrequencyLines: [String: String] = [:]  // ICAO -> all frequencies (newline-separated)
    var cachedHeading: Double?  // Cached course from LocationManager (survives GPS gaps)
    var showOpenAIPOverlay: Bool = false
    var openAIPCacheManager: OpenAIPCacheManager?
    var airspacePolygons: [AirspacePolygon] = []  // Airspace overlays to display
    var trackVectorOverlays: [MKPolyline] = []  // Ground-track trend vector (line + ticks)
    var trackVectorEnabled: Bool = false  // Keep a valid vector across transient empties; remove only when off
    var onWaypointATOTap: ((Int) -> Void)?  // Callback when user taps/long-presses a waypoint to set ATO

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = false  // Disabled - compass was appearing in wrong position
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = false
        mapView.showsScale = false // Use our custom scale bar instead

        // Set map type
        mapView.mapType = selectedLayer == .satellite ? .satellite : .standard

        // Add OpenAIP tile overlay if enabled
        if showOpenAIPOverlay {
            let overlay = OpenAIPTileOverlay(cacheManager: openAIPCacheManager)
            mapView.addOverlay(overlay, level: .aboveLabels)
        }

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

        // Update OpenAIP tile overlay
        updateOpenAIPOverlay(mapView, context: context)

        // Update airspace polygon overlays
        updateAirspaceOverlays(mapView, context: context)

        // Track vector — rebuilt each update. Only wipe when the feature is OFF; on a transient empty
        // (brief GPS gap / <5 kt) keep the existing vector instead of blanking it. (3.5 fix)
        let existingTrackVector = mapView.overlays.compactMap { $0 as? TrackVectorPolyline }
        if !trackVectorEnabled {
            mapView.removeOverlays(existingTrackVector)
        } else if !trackVectorOverlays.isEmpty {
            mapView.removeOverlays(existingTrackVector)
            for tv in trackVectorOverlays { mapView.addOverlay(tv, level: .aboveLabels) }
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

        // Apply heading changes independently of region (for track-up mode).
        // When only heading changed but not region, the above block won't fire.
        if !regionChanged && !context.coordinator.isUserInteracting {
            let headingDelta = abs(mapView.camera.heading - mapState.cameraHeading)
            let normalizedDelta = min(headingDelta, 360.0 - headingDelta)
            if normalizedDelta > 0.5 {
                let camera = MKMapCamera(
                    lookingAtCenter: mapView.camera.centerCoordinate,
                    fromDistance: mapView.camera.centerCoordinateDistance,
                    pitch: 0,
                    heading: mapState.cameraHeading
                )
                mapView.setCamera(camera, animated: true)
            }
        }

        // Update aircraft annotation
        updateAircraftAnnotation(mapView, context: context)

        // Update track overlay
        updateTrackOverlay(mapView, context: context)

        // Update flight plan overlay
        updateFlightPlanOverlay(mapView, context: context)

        // Update airport annotations
        updateAirportAnnotations(mapView, context: context)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func updateAirportAnnotations(_ mapView: MKMapView, context: Context) {
        // Get existing airport annotations
        let existingAirportAnnotations = mapView.annotations.compactMap { $0 as? AirportAnnotation }
        let existingIds = Set(existingAirportAnnotations.map { $0.airport.id })
        let newIds = Set(visibleAirports.map { $0.id })

        // Remove annotations that are no longer visible
        let toRemove = existingAirportAnnotations.filter { !newIds.contains($0.airport.id) }
        mapView.removeAnnotations(toRemove)

        // Add new annotations
        let toAdd = visibleAirports.filter { !existingIds.contains($0.id) }
        for airport in toAdd {
            let annotation = AirportAnnotation(airport: airport, frequencyLines: airportFrequencyLines[airport.ident])
            mapView.addAnnotation(annotation)
        }
    }

    private func updateFlightPlanOverlay(_ mapView: MKMapView, context: Context) {
        let existingFlightPlanPolylines = mapView.overlays.compactMap { $0 as? FlightPlanRoutePolyline }
        let existingWaypointAnnotations = mapView.annotations.compactMap { $0 as? FlightPlanWaypointAnnotation }

        guard let flightPlan = activeFlightPlan, flightPlan.waypoints.count >= 2 else {
            // No (valid) plan: clear any existing flight-plan overlays/annotations. (PR-10)
            mapView.removeOverlays(existingFlightPlanPolylines)
            mapView.removeAnnotations(existingWaypointAnnotations)
            context.coordinator.lastFlightPlanSignature = nil
            return
        }

        let currentWaypointIndex = flightPlan.currentWaypointIndex

        // Diff guard: rebuild only when the waypoints or the current-leg index actually changed.
        // This previously tore down and re-added every route polyline + waypoint annotation on every
        // updateUIView (each map pan / GPS tick). (PR-10)
        let signature = flightPlan.waypoints
            .map { "\($0.coordinate.latitude),\($0.coordinate.longitude),\($0.name)" }
            .joined(separator: "|") + "@\(currentWaypointIndex)"
        if context.coordinator.lastFlightPlanSignature == signature, !existingWaypointAnnotations.isEmpty {
            return
        }
        context.coordinator.lastFlightPlanSignature = signature

        // Changed — tear down the old flight-plan layer and redraw it.
        mapView.removeOverlays(existingFlightPlanPolylines)
        mapView.removeAnnotations(existingWaypointAnnotations)

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
            // Use cached heading (survives GPS gaps) instead of raw location.course
            let newHeading = cachedHeading ?? (location.course >= 0 ? location.course : 0)

            if let existing = existingAnnotation {
                // Update existing annotation in place to avoid blinking
                let coordChanged = abs(existing.coordinate.latitude - location.coordinate.latitude) > 0.00001 ||
                                   abs(existing.coordinate.longitude - location.coordinate.longitude) > 0.00001
                let headingChanged = abs(existing.heading - newHeading) > 0.5

                // Always reapply transform: camera heading may have changed (track-up mode)
                existing.coordinate = location.coordinate
                existing.heading = newHeading

                // Update the annotation view's transform for new heading
                // MKAnnotationView is screen-relative, so subtract camera heading
                // to compensate for map rotation in track-up mode.
                // In north-up mode, camera heading is 0 so this is a no-op.
                if let view = mapView.view(for: existing) {
                    let effectiveHeading = newHeading - mapView.camera.heading
                    let headingRadians = (effectiveHeading - 90.0) * .pi / 180.0
                    if coordChanged || headingChanged {
                        UIView.animate(withDuration: 0.1) {
                            view.transform = CGAffineTransform(rotationAngle: CGFloat(headingRadians))
                        }
                    } else {
                        // Camera rotation changed but position/heading didn't — update without animation
                        view.transform = CGAffineTransform(rotationAngle: CGFloat(headingRadians))
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

    private func updateOpenAIPOverlay(_ mapView: MKMapView, context: Context) {
        let hasOverlay = mapView.overlays.contains(where: { $0 is OpenAIPTileOverlay })

        if showOpenAIPOverlay && !hasOverlay {
            let overlay = OpenAIPTileOverlay(cacheManager: openAIPCacheManager)
            mapView.addOverlay(overlay, level: .aboveLabels)
        } else if !showOpenAIPOverlay && hasOverlay {
            let overlaysToRemove = mapView.overlays.filter { $0 is OpenAIPTileOverlay }
            mapView.removeOverlays(overlaysToRemove)
        }
    }

    private func updateAirspaceOverlays(_ mapView: MKMapView, context: Context) {
        let existingAirspaceOverlays = mapView.overlays.compactMap { $0 as? AirspacePolygon }
        let existingIds = Set(existingAirspaceOverlays.map { $0.airspaceId })
        let newIds = Set(airspacePolygons.map { $0.airspaceId })

        guard existingIds != newIds else { return }

        // Remove only the overlays that are no longer visible and add only the newly-visible ones,
        // instead of tearing down and re-adding the entire set whenever it changes at all — so a pan
        // that shifts a few airspaces in/out doesn't rebuild the rest. (PR-11)
        let toRemove = existingAirspaceOverlays.filter { !newIds.contains($0.airspaceId) }
        if !toRemove.isEmpty { mapView.removeOverlays(toRemove) }

        let toAdd = airspacePolygons.filter { !existingIds.contains($0.airspaceId) }
        for polygon in toAdd {
            mapView.addOverlay(polygon, level: .aboveLabels)
        }
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: NativeMapViewUIKit
        var isUserInteracting = false
        /// Signature of the last-rendered flight plan, so the overlay is rebuilt only on change. (PR-10)
        var lastFlightPlanSignature: String?

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
            // OpenAIP tile overlay
            if let tileOverlay = overlay as? OpenAIPTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }

            // Airspace polygon overlay
            if let airspacePolygon = overlay as? AirspacePolygon {
                let renderer = MKPolygonRenderer(polygon: airspacePolygon)
                let color = airspacePolygon.overlayColor
                renderer.fillColor = UIColor(red: color.red, green: color.green, blue: color.blue, alpha: 0.15)
                renderer.strokeColor = UIColor(red: color.red, green: color.green, blue: color.blue, alpha: 0.8)
                renderer.lineWidth = 1.5
                if airspacePolygon.isDashed {
                    renderer.lineDashPattern = [8, 4]
                }
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
            if let casing = overlay as? TrackVectorCasingPolyline {
                let renderer = MKPolylineRenderer(polyline: casing)
                renderer.strokeColor = UIColor.black.withAlphaComponent(0.5)
                renderer.lineWidth = 6
                return renderer
            }

            if let trackVector = overlay as? TrackVectorPolyline {
                let renderer = MKPolylineRenderer(polyline: trackVector)
                renderer.strokeColor = UIColor(red: 0.20, green: 0.95, blue: 1.0, alpha: 1.0)
                renderer.lineWidth = 3
                return renderer
            }

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

            // Handle airport annotation
            if let airportAnnotation = annotation as? AirportAnnotation {
                return createAirportAnnotationView(mapView, annotation: airportAnnotation)
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
            // Also subtract camera heading: MKAnnotationView is screen-relative, so in
            // track-up mode we must compensate for the map's rotation.
            let effectiveHeading = aircraftAnnotation.heading - mapView.camera.heading
            let headingRadians = (effectiveHeading - 90.0) * .pi / 180.0
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
            // Dequeue a reusable annotation view instead of allocating a new one each time. (PR-10)
            let annotationView: MKAnnotationView
            if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) {
                reused.annotation = annotation
                annotationView = reused
            } else {
                annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            }
            annotationView.canShowCallout = true

            // Waypoint appearance based on state — image is cached per state. (PR-10)
            let stateKey: String
            let markerColor: UIColor
            let iconName: String

            if annotation.isCurrentWaypoint {
                // Current/next waypoint - bright magenta with target icon
                stateKey = "current"
                markerColor = UIColor(red: 1.0, green: 0.0, blue: 0.8, alpha: 1.0)
                iconName = "target"
            } else if annotation.isCompletedWaypoint {
                // Completed waypoint - dimmed with checkmark
                stateKey = "completed"
                markerColor = UIColor(red: 0.6, green: 0.3, blue: 0.5, alpha: 0.7)
                iconName = "checkmark.circle.fill"
            } else {
                // Future waypoint - medium brightness
                stateKey = "future"
                markerColor = UIColor(red: 0.9, green: 0.4, blue: 0.7, alpha: 0.9)
                iconName = "circle.fill"
            }

            annotationView.image = cachedWaypointMarker(state: stateKey, iconName: iconName, color: markerColor)

            // Add shadow
            annotationView.layer.shadowColor = UIColor.black.cgColor
            annotationView.layer.shadowOffset = CGSize(width: 0, height: 2)
            annotationView.layer.shadowOpacity = 0.5
            annotationView.layer.shadowRadius = 2

            // Add long-press gesture for ATO recording
            addLongPressToWaypointView(annotationView)

            return annotationView
        }

        /// Create annotation view for airports
        private func createAirportAnnotationView(_ mapView: MKMapView, annotation: AirportAnnotation) -> MKAnnotationView {
            let identifier = "AirportAnnotation"
            let annotationView: MKAnnotationView

            if let reusedView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) {
                reusedView.annotation = annotation
                annotationView = reusedView
            } else {
                annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            }

            annotationView.canShowCallout = true

            // Size and color based on airport type
            let size: CGFloat
            let iconName: String
            let color: UIColor

            switch annotation.airport.type {
            case .largeAirport:
                size = 20
                iconName = "airplane.circle.fill"
                color = UIColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 1.0) // Blue
            case .mediumAirport:
                size = 16
                iconName = "airplane.circle"
                color = UIColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 0.9) // Blue
            case .smallAirport:
                size = 14
                iconName = "airplane"
                color = UIColor(red: 0.4, green: 0.7, blue: 0.4, alpha: 0.9) // Green
            default:
                size = 12
                iconName = "circle.fill"
                color = UIColor.gray
            }

            let config = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
            if let image = UIImage(systemName: iconName, withConfiguration: config) {
                annotationView.image = image.withTintColor(color, renderingMode: .alwaysOriginal)
            }

            // Configure callout with multi-line frequency detail
            annotationView.rightCalloutAccessoryView = nil
            annotationView.leftCalloutAccessoryView = nil

            if let freqLines = annotation.frequencyLines {
                let detailLabel = UILabel()
                detailLabel.numberOfLines = 0

                let attributed = NSMutableAttributedString()
                // Airport name line
                let nameAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: UIColor.label
                ]
                attributed.append(NSAttributedString(string: annotation.airport.name + "\n", attributes: nameAttrs))
                // Frequency lines
                let freqAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: UIColor.secondaryLabel
                ]
                attributed.append(NSAttributedString(string: freqLines, attributes: freqAttrs))

                detailLabel.attributedText = attributed
                annotationView.detailCalloutAccessoryView = detailLabel
            } else {
                annotationView.detailCalloutAccessoryView = nil
            }

            return annotationView
        }

        // MARK: - Waypoint ATO Tap/Long-Press

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            guard let waypointAnnotation = annotation as? FlightPlanWaypointAnnotation else { return }
            mapView.deselectAnnotation(annotation, animated: false)
            parent.onWaypointATOTap?(waypointAnnotation.waypointIndex)
        }

        func addLongPressToWaypointView(_ annotationView: MKAnnotationView) {
            annotationView.gestureRecognizers?.removeAll { $0 is UILongPressGestureRecognizer }
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleWaypointLongPress(_:)))
            longPress.minimumPressDuration = 1.0
            annotationView.addGestureRecognizer(longPress)
        }

        @objc private func handleWaypointLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let annotationView = gesture.view as? MKAnnotationView,
                  let waypointAnnotation = annotationView.annotation as? FlightPlanWaypointAnnotation else { return }
            parent.onWaypointATOTap?(waypointAnnotation.waypointIndex)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
        NavigationStack {
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

                    // Data-source attribution required by the providers' terms (swisstopo/BAZL,
                    // MeteoSwiss, Open-Meteo, OpenAIP). (SEC-16)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Data sources")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondaryText)
                            .padding(.horizontal, 20)
                        Text("Charts © swisstopo / BAZL · Wind © MeteoSwiss · Elevation: Open-Meteo & © swisstopo · \(OpenAIPConfig.attributionText)")
                            .font(.system(size: 11))
                            .foregroundColor(.dimText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 20)
                    }
                }
                .padding(.vertical, 16)
            }
            .background(Color.cockpitBackground)
            .navigationTitle(L10n.MapLayer.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.done) { dismiss() }
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
    var showOpenAIPOverlay: Bool = false
    var openAIPCacheManager: OpenAIPCacheManager?
    var airspacePolygons: [AirspacePolygon] = []
    var trackVectorOverlays: [MKPolyline] = []  // Ground-track trend vector (line + ticks)
    var trackVectorEnabled: Bool = false  // Keep a valid vector across transient empties; remove only when off
    var currentWaypointIndex: Int = 0  // Track separately to force updates
    var locationUpdateCounter: Int = 0  // Forces updateUIView on every location change
    var visibleAirports: [Airport] = []  // Airports to display on map
    var airportFrequencyLines: [String: String] = [:]  // ICAO -> all frequencies (newline-separated)
    var cachedHeading: Double?  // Cached course from LocationManager (survives GPS gaps)
    var onWaypointATOTap: ((Int) -> Void)?  // Callback when user taps/long-presses a waypoint to set ATO

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
        // Zoom 12 ≈ 15,000m (Segelflugkarte max zoom)
        // Zoom 13 ≈ 7,500m
        // Zoom 14 ≈ 4,000m
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
                // ICAO + Segelflugkarte: zoom 7-12
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

                // Re-add OpenAIP tile overlay if it was enabled (removed above with all MKTileOverlays)
                if self.showOpenAIPOverlay {
                    let openAIPOverlay = OpenAIPTileOverlay(
                        cacheManager: self.openAIPCacheManager,
                        isStrictOfflineMode: self.isStrictOfflineMode
                    )
                    mapView.addOverlay(openAIPOverlay, level: .aboveLabels)
                }

                // The base tile was just re-added on TOP (same .aboveLabels level), which buries the
                // flight-plan route line. Invalidate the route diff-guard so the next updateUIView
                // redraws the route above the tile. (3.5 fix — route line was invisible on Swiss layers)
                context.coordinator.lastFlightPlanSignature = nil

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

        // Update OpenAIP tile overlay
        let hasOpenAIPOverlay = mapView.overlays.contains(where: { $0 is OpenAIPTileOverlay })
        if showOpenAIPOverlay && !hasOpenAIPOverlay {
            let openAIPOverlay = OpenAIPTileOverlay(
                cacheManager: openAIPCacheManager,
                isStrictOfflineMode: isStrictOfflineMode
            )
            mapView.addOverlay(openAIPOverlay, level: .aboveLabels)
        } else if !showOpenAIPOverlay && hasOpenAIPOverlay {
            let overlaysToRemove = mapView.overlays.filter { $0 is OpenAIPTileOverlay }
            mapView.removeOverlays(overlaysToRemove)
        }

        // Update airspace polygon overlays
        let existingAirspaceOverlays = mapView.overlays.compactMap { $0 as? AirspacePolygon }
        let existingIds = Set(existingAirspaceOverlays.map { $0.airspaceId })
        let newIds = Set(airspacePolygons.map { $0.airspaceId })
        if existingIds != newIds {
            mapView.removeOverlays(existingAirspaceOverlays)
            for polygon in airspacePolygons {
                mapView.addOverlay(polygon, level: .aboveLabels)
            }
        }

        // Track vector — rebuilt each update. Only wipe when the feature is OFF; on a transient empty
        // (brief GPS gap / <5 kt) keep the existing vector instead of blanking it. (3.5 fix)
        let existingTrackVector = mapView.overlays.compactMap { $0 as? TrackVectorPolyline }
        if !trackVectorEnabled {
            mapView.removeOverlays(existingTrackVector)
        } else if !trackVectorOverlays.isEmpty {
            mapView.removeOverlays(existingTrackVector)
            for tv in trackVectorOverlays { mapView.addOverlay(tv, level: .aboveLabels) }
        }

        // Update camera from shared state (preserves heading)
        let regionChanged = !context.coordinator.regionsAreEqual(mapView.region, mapState.region)
        if overlayChanged {
            // Always reposition camera on overlay change (layer switch)
            let camera = MKMapCamera(
                lookingAtCenter: mapState.region.center,
                fromDistance: mapState.cameraDistance,
                pitch: 0,
                heading: mapState.cameraHeading
            )
            mapView.setCamera(camera, animated: false)

            // Force tile reload after overlay change for Swiss layers
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
        } else if regionChanged && !context.coordinator.isUserInteracting {
            // Only reposition camera when NOT user-driven (matches NativeMapViewUIKit pattern)
            let camera = MKMapCamera(
                lookingAtCenter: mapState.region.center,
                fromDistance: mapState.cameraDistance,
                pitch: 0,
                heading: mapState.cameraHeading
            )
            mapView.setCamera(camera, animated: true)
        }

        // Apply heading changes independently of region (for track-up mode).
        // When only heading changed but not region/overlay, the above block won't fire.
        if !regionChanged && !overlayChanged && !context.coordinator.isUserInteracting {
            let headingDelta = abs(mapView.camera.heading - mapState.cameraHeading)
            let normalizedDelta = min(headingDelta, 360.0 - headingDelta)
            if normalizedDelta > 0.5 {
                let camera = MKMapCamera(
                    lookingAtCenter: mapView.camera.centerCoordinate,
                    fromDistance: mapView.camera.centerCoordinateDistance,
                    pitch: 0,
                    heading: mapState.cameraHeading
                )
                mapView.setCamera(camera, animated: true)
            }
        }

        // Update aircraft annotation
        updateAircraftAnnotation(mapView, context: context)

        // When layer changes, force-refresh track overlay so the renderer uses the correct color
        if overlayChanged {
            let existingTrackPolylines = mapView.overlays.compactMap { overlay -> MKPolyline? in
                if overlay is FlightPlanRoutePolyline || overlay is MKTileOverlay { return nil }
                return overlay as? MKPolyline
            }
            mapView.removeOverlays(existingTrackPolylines)
        }

        // Update track overlay
        updateTrackOverlay(mapView, context: context)

        // Update flight plan overlay
        updateFlightPlanOverlay(mapView, context: context)

        // Update airport annotations
        updateAirportAnnotations(mapView, context: context)
    }

    private func updateAirportAnnotations(_ mapView: MKMapView, context: Context) {
        // Get existing airport annotations
        let existingAirportAnnotations = mapView.annotations.compactMap { $0 as? AirportAnnotation }
        let existingIds = Set(existingAirportAnnotations.map { $0.airport.id })
        let newIds = Set(visibleAirports.map { $0.id })

        // Remove annotations that are no longer visible
        let toRemove = existingAirportAnnotations.filter { !newIds.contains($0.airport.id) }
        mapView.removeAnnotations(toRemove)

        // Add new annotations
        let toAdd = visibleAirports.filter { !existingIds.contains($0.id) }
        for airport in toAdd {
            let annotation = AirportAnnotation(airport: airport, frequencyLines: airportFrequencyLines[airport.ident])
            mapView.addAnnotation(annotation)
        }
    }

    private func updateFlightPlanOverlay(_ mapView: MKMapView, context: Context) {
        let existingFlightPlanPolylines = mapView.overlays.compactMap { $0 as? FlightPlanRoutePolyline }
        let existingWaypointAnnotations = mapView.annotations.compactMap { $0 as? FlightPlanWaypointAnnotation }

        guard let flightPlan = activeFlightPlan, flightPlan.waypoints.count >= 2 else {
            // No (valid) plan: clear any existing flight-plan overlays/annotations. (PR-10)
            mapView.removeOverlays(existingFlightPlanPolylines)
            mapView.removeAnnotations(existingWaypointAnnotations)
            context.coordinator.lastFlightPlanSignature = nil
            return
        }

        let currentWaypointIndex = flightPlan.currentWaypointIndex

        // Diff guard: rebuild only when the waypoints or the current-leg index actually changed.
        // This previously tore down and re-added every route polyline + waypoint annotation on every
        // updateUIView (each map pan / GPS tick). (PR-10)
        let signature = flightPlan.waypoints
            .map { "\($0.coordinate.latitude),\($0.coordinate.longitude),\($0.name)" }
            .joined(separator: "|") + "@\(currentWaypointIndex)"
        if context.coordinator.lastFlightPlanSignature == signature, !existingWaypointAnnotations.isEmpty {
            return
        }
        context.coordinator.lastFlightPlanSignature = signature

        // Changed — tear down the old flight-plan layer and redraw it.
        mapView.removeOverlays(existingFlightPlanPolylines)
        mapView.removeAnnotations(existingWaypointAnnotations)

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
            // Use cached heading (survives GPS gaps) instead of raw location.course
            let newHeading = cachedHeading ?? (location.course >= 0 ? location.course : 0)

            if let existing = existingAnnotation {
                // Update existing annotation in place to avoid blinking
                let coordChanged = abs(existing.coordinate.latitude - location.coordinate.latitude) > 0.00001 ||
                                   abs(existing.coordinate.longitude - location.coordinate.longitude) > 0.00001
                let headingChanged = abs(existing.heading - newHeading) > 0.5

                // Always reapply transform: camera heading may have changed (track-up mode)
                existing.coordinate = location.coordinate
                existing.heading = newHeading

                // Update the annotation view's transform for new heading
                // MKAnnotationView is screen-relative, so subtract camera heading
                // to compensate for map rotation in track-up mode.
                // In north-up mode, camera heading is 0 so this is a no-op.
                if let view = mapView.view(for: existing) {
                    let effectiveHeading = newHeading - mapView.camera.heading
                    let headingRadians = (effectiveHeading - 90.0) * .pi / 180.0
                    if coordChanged || headingChanged {
                        UIView.animate(withDuration: 0.1) {
                            view.transform = CGAffineTransform(rotationAngle: CGFloat(headingRadians))
                        }
                    } else {
                        // Camera rotation changed but position/heading didn't — update without animation
                        view.transform = CGAffineTransform(rotationAngle: CGFloat(headingRadians))
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
        /// Signature of the last-rendered flight plan, so the overlay is rebuilt only on change. (PR-10)
        var lastFlightPlanSignature: String?
        var currentLayerType: MapLayerType?
        var currentForceICAO: Bool = false
        var offlineMapManager: OfflineMapManager?
        var isStrictOfflineMode: Bool = false
        var hasSegelflugCache: Bool = false
        private var isUpdatingRegion = false
        var isUserInteracting = false

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
                        isUserInteracting = true
                        parent.isFollowingAircraft = false
                        return
                    }
                }
            }
        }

        // Sync region changes back to shared state
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            isUserInteracting = false
            guard !isUpdatingRegion else { return }
            isUpdatingRegion = true
            parent.mapState.updateFromRegion(mapView.region)
            // Sync camera distance and heading so they're preserved when switching layers
            parent.mapState.updateFromCamera(mapView.camera)
            isUpdatingRegion = false
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            // Airspace polygon overlay (check before generic MKTileOverlay)
            if let airspacePolygon = overlay as? AirspacePolygon {
                let renderer = MKPolygonRenderer(polygon: airspacePolygon)
                let color = airspacePolygon.overlayColor
                renderer.fillColor = UIColor(red: color.red, green: color.green, blue: color.blue, alpha: 0.15)
                renderer.strokeColor = UIColor(red: color.red, green: color.green, blue: color.blue, alpha: 0.8)
                renderer.lineWidth = 1.5
                if airspacePolygon.isDashed {
                    renderer.lineDashPattern = [8, 4]
                }
                return renderer
            }

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

            // GPS track - use magenta on ICAO/Segelflugkarte layers for visibility,
            // gold on other layers
            if let casing = overlay as? TrackVectorCasingPolyline {
                let renderer = MKPolylineRenderer(polyline: casing)
                renderer.strokeColor = UIColor.black.withAlphaComponent(0.5)
                renderer.lineWidth = 6
                return renderer
            }

            if let trackVector = overlay as? TrackVectorPolyline {
                let renderer = MKPolylineRenderer(polyline: trackVector)
                renderer.strokeColor = UIColor(red: 0.20, green: 0.95, blue: 1.0, alpha: 1.0)
                renderer.lineWidth = 3
                return renderer
            }

            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                let isICAOLayer = (currentLayerType ?? parent.layerType) == .icao
                if isICAOLayer {
                    // Bright magenta for visibility on aeronautical charts
                    renderer.strokeColor = UIColor(red: 1.0, green: 0.0, blue: 0.8, alpha: 1.0)
                } else {
                    renderer.strokeColor = UIColor(red: 0.85, green: 0.65, blue: 0.2, alpha: 1.0)
                }
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

            // Handle airport annotation
            if let airportAnnotation = annotation as? AirportAnnotation {
                return createAirportAnnotationView(mapView, annotation: airportAnnotation)
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
            // Also subtract camera heading: MKAnnotationView is screen-relative, so in
            // track-up mode we must compensate for the map's rotation.
            let effectiveHeading = aircraftAnnotation.heading - mapView.camera.heading
            let headingRadians = (effectiveHeading - 90.0) * .pi / 180.0
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
            // Dequeue a reusable annotation view instead of allocating a new one each time. (PR-10)
            let annotationView: MKAnnotationView
            if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) {
                reused.annotation = annotation
                annotationView = reused
            } else {
                annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            }
            annotationView.canShowCallout = true

            // Waypoint appearance based on state — image is cached per state. (PR-10)
            let stateKey: String
            let markerColor: UIColor
            let iconName: String

            if annotation.isCurrentWaypoint {
                // Current/next waypoint - bright magenta with target icon
                stateKey = "current"
                markerColor = UIColor(red: 1.0, green: 0.0, blue: 0.8, alpha: 1.0)
                iconName = "target"
            } else if annotation.isCompletedWaypoint {
                // Completed waypoint - dimmed with checkmark
                stateKey = "completed"
                markerColor = UIColor(red: 0.6, green: 0.3, blue: 0.5, alpha: 0.7)
                iconName = "checkmark.circle.fill"
            } else {
                // Future waypoint - medium brightness
                stateKey = "future"
                markerColor = UIColor(red: 0.9, green: 0.4, blue: 0.7, alpha: 0.9)
                iconName = "circle.fill"
            }

            annotationView.image = cachedWaypointMarker(state: stateKey, iconName: iconName, color: markerColor)

            // Add shadow
            annotationView.layer.shadowColor = UIColor.black.cgColor
            annotationView.layer.shadowOffset = CGSize(width: 0, height: 2)
            annotationView.layer.shadowOpacity = 0.5
            annotationView.layer.shadowRadius = 2

            // Add long-press gesture for ATO recording
            addLongPressToWaypointView(annotationView)

            return annotationView
        }

        /// Create annotation view for airports
        private func createAirportAnnotationView(_ mapView: MKMapView, annotation: AirportAnnotation) -> MKAnnotationView {
            let identifier = "AirportAnnotation"
            let annotationView: MKAnnotationView

            if let reusedView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) {
                reusedView.annotation = annotation
                annotationView = reusedView
            } else {
                annotationView = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            }

            annotationView.canShowCallout = true

            // Size and color based on airport type
            let size: CGFloat
            let iconName: String
            let color: UIColor

            switch annotation.airport.type {
            case .largeAirport:
                size = 20
                iconName = "airplane.circle.fill"
                color = UIColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 1.0) // Blue
            case .mediumAirport:
                size = 16
                iconName = "airplane.circle"
                color = UIColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 0.9) // Blue
            case .smallAirport:
                size = 14
                iconName = "airplane"
                color = UIColor(red: 0.4, green: 0.7, blue: 0.4, alpha: 0.9) // Green
            default:
                size = 12
                iconName = "circle.fill"
                color = UIColor.gray
            }

            let config = UIImage.SymbolConfiguration(pointSize: size, weight: .medium)
            if let image = UIImage(systemName: iconName, withConfiguration: config) {
                annotationView.image = image.withTintColor(color, renderingMode: .alwaysOriginal)
            }

            // Configure callout with multi-line frequency detail
            annotationView.rightCalloutAccessoryView = nil
            annotationView.leftCalloutAccessoryView = nil

            if let freqLines = annotation.frequencyLines {
                let detailLabel = UILabel()
                detailLabel.numberOfLines = 0

                let attributed = NSMutableAttributedString()
                // Airport name line
                let nameAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: UIColor.label
                ]
                attributed.append(NSAttributedString(string: annotation.airport.name + "\n", attributes: nameAttrs))
                // Frequency lines
                let freqAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: UIColor.secondaryLabel
                ]
                attributed.append(NSAttributedString(string: freqLines, attributes: freqAttrs))

                detailLabel.attributedText = attributed
                annotationView.detailCalloutAccessoryView = detailLabel
            } else {
                annotationView.detailCalloutAccessoryView = nil
            }

            return annotationView
        }

        // MARK: - Waypoint ATO Tap/Long-Press

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            guard let waypointAnnotation = annotation as? FlightPlanWaypointAnnotation else { return }
            // Deselect so user can tap again later
            mapView.deselectAnnotation(annotation, animated: false)
            // Record ATO on tap
            parent.onWaypointATOTap?(waypointAnnotation.waypointIndex)
        }

        /// Add long-press gesture recognizer to waypoint annotation views
        func addLongPressToWaypointView(_ annotationView: MKAnnotationView) {
            // Remove any existing long-press recognizers to avoid duplicates
            annotationView.gestureRecognizers?.removeAll { $0 is UILongPressGestureRecognizer }

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleWaypointLongPress(_:)))
            longPress.minimumPressDuration = 1.0
            annotationView.addGestureRecognizer(longPress)
        }

        @objc private func handleWaypointLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began,
                  let annotationView = gesture.view as? MKAnnotationView,
                  let waypointAnnotation = annotationView.annotation as? FlightPlanWaypointAnnotation else { return }
            parent.onWaypointATOTap?(waypointAnnotation.waypointIndex)
            // Haptic feedback
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
        }
    }
}

// MARK: - Aircraft Annotation

class AircraftAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    @objc dynamic var heading: Double

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

/// Marker subclass for the ground-track trend vector (line + 1/2/5-min ticks), rendered cyan. (3.5 C4)
class TrackVectorPolyline: MKPolyline {}

/// The dark casing drawn under each track-vector segment for legibility on any map. (3.5 fix)
class TrackVectorCasingPolyline: TrackVectorPolyline {}

// MARK: - Swisstopo tile overlays
// `ICAOSegelflugkarteTileOverlay` and `SwisstopoTileOverlay` moved to the shared
// `Services/SwisstopoTileOverlays.swift` (Phase 3.5 design-system consolidation — they were
// duplicated as `WaypointPicker*` in FlightPlanEditorView). All map consumers use them from there.

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

// MARK: - GPS Status Info Sheet

/// Modal sheet explaining GPS status indicators
/// GPS Status modal — presented via .fullScreenCover as a centered card over dimmed background
struct GPSStatusInfoSheet: View {
    let currentStatus: GPSSignalStatus
    @Binding var isPresented: Bool

    private var currentStatusText: String {
        switch currentStatus {
        case .good: return L10n.GPS.signalGood
        case .degraded: return L10n.GPS.signalDegraded
        case .lost: return L10n.GPS.signalLost
        }
    }

    private var currentStatusColor: Color {
        switch currentStatus {
        case .good: return .aviationGreen
        case .degraded: return .orange
        case .lost: return .aviationRed
        }
    }

    var body: some View {
        ZStack {
            // Dimmed background — tap to dismiss
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            // Floating modal card
            VStack(spacing: 16) {
                // Header icon
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 40))
                    .foregroundColor(.aviationGold)
                    .padding(.top, 24)

                // Title
                Text(L10n.GPS.statusTitle)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.primaryText)

                // Current status
                HStack {
                    Text(L10n.GPS.currentStatus)
                        .font(.system(size: 14))
                        .foregroundColor(.secondaryText)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(currentStatusColor)
                            .frame(width: 10, height: 10)
                        Text(currentStatusText)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(currentStatusColor)
                    }
                }
                .padding(.horizontal, 20)

                Divider()
                    .padding(.horizontal, 16)

                // Status explanations
                VStack(spacing: 14) {
                    statusRow(
                        color: .aviationGreen,
                        title: L10n.GPS.signalGood,
                        description: L10n.GPS.statusGoodDesc
                    )
                    statusRow(
                        color: .orange,
                        title: L10n.GPS.signalDegraded,
                        description: L10n.GPS.statusDegradedDesc
                    )
                    statusRow(
                        color: .aviationRed,
                        title: L10n.GPS.signalLost,
                        description: L10n.GPS.statusLostDesc
                    )
                }
                .padding(.horizontal, 20)

                // Done button
                Button(action: { isPresented = false }) {
                    Text(L10n.Button.done)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.aviationGold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .background(Color.cockpitBackground)
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
            .frame(maxWidth: 420)
            .padding(.horizontal, 32)
        }
        .preferredColorScheme(.dark)
        .presentationBackground(.clear)
    }

    private func statusRow(color: Color, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .shadow(color: color.opacity(0.5), radius: 4)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primaryText)
                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        NavigationStack {
            VStack(spacing: 14) {
                // Header icon
                Image(systemName: isOfflineMode ? "wifi.slash" : "internaldrive.fill")
                    .font(.system(size: 40))
                    .foregroundColor(isOfflineMode ? .aviationRed : .aviationGold)
                    .padding(.top, 20)

                // Title
                Text(isOfflineMode ? L10n.Nav.offlineModeActive : L10n.Nav.usingCachedCharts)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.primaryText)

                // Description
                VStack(spacing: 8) {
                    if isOfflineMode {
                        if hasFullOfflineSupport {
                            Text(L10n.Nav.offlineDesc)
                                .font(.system(size: 13))
                                .foregroundColor(.secondaryText)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(L10n.Nav.offlineICAOOnly)
                                .font(.system(size: 13))
                                .foregroundColor(.secondaryText)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(L10n.Nav.downloadSegelflugkarteDesc)
                                .font(.system(size: 11))
                                .foregroundColor(.aviationAmber)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(L10n.Nav.cachedChartsDesc)
                            .font(.system(size: 13))
                            .foregroundColor(.secondaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(L10n.Nav.cachedTilesDesc)
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
                            Text(L10n.Nav.icaoChart)
                                .foregroundColor(.secondaryText)
                            Spacer()
                            Text(offlineMapManager.cacheVersion)
                                .foregroundColor(.aviationGreen)
                        }
                    }

                    // Segelflug Cache
                    HStack {
                        Text(L10n.Nav.segelflugkarte)
                            .foregroundColor(.secondaryText)
                        Spacer()
                        if offlineMapManager.isSegelflugCacheAvailable {
                            Text(offlineMapManager.segelflugCacheVersion)
                                .foregroundColor(.aviationGreen)
                        } else {
                            Text(L10n.Nav.notCached)
                                .foregroundColor(.dimText)
                        }
                    }

                    HStack {
                        Text(L10n.Nav.totalSize)
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
                                Text(L10n.Nav.goOnline)
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
                                Text(L10n.Nav.stayOffline)
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
                        Button(L10n.Button.done) { dismiss() }
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

// MARK: - Airspace Polygon Overlay

/// MKPolygon subclass that carries airspace metadata for rendering
class AirspacePolygon: MKPolygon {
    var airspaceId: String = ""
    var airspaceName: String = ""
    var airspaceTypeCategory: AirspaceTypeCategory = .other
    var airspaceClassCategory: AirspaceClassCategory?
    var upperCeilingDisplay: String = ""
    var lowerCeilingDisplay: String = ""
    var overlayColor: (red: Double, green: Double, blue: Double) = (0.5, 0.5, 0.5)
    var isDashed: Bool = false

    convenience init(airspace: Airspace, coordinates: inout [CLLocationCoordinate2D], count: Int) {
        self.init(coordinates: &coordinates, count: count)
        self.airspaceId = airspace.id
        self.airspaceName = airspace.name
        self.airspaceTypeCategory = airspace.airspaceType
        self.airspaceClassCategory = airspace.airspaceClass
        self.upperCeilingDisplay = airspace.upperCeiling.displayString
        self.lowerCeilingDisplay = airspace.lowerCeiling.displayString
        self.overlayColor = airspace.mapColor

        // Dashed border for certain types
        switch airspace.airspaceType {
        case .tmz, .rmz, .fir, .uir:
            self.isDashed = true
        default:
            if airspace.airspaceClass == .classE || airspace.airspaceClass == .classG {
                self.isDashed = true
            }
        }
    }
}

// MARK: - Self-timing clock / chronometer (PR-10)

/// A wall-clock HH:mm:ss display that ticks itself once per second via `TimelineView` instead of the
/// old `.id(UUID())` hack driven by a top-level 1 Hz timer. The hack changed top-level `@State`
/// every second, re-evaluating the entire ~2000-line map body; this scopes the per-second redraw to
/// just this small subview. The `DateFormatter` is cached (was rebuilt per render). (PR-10)
private struct NavClockText: View {
    let useUTC: Bool
    let font: Font
    let color: Color

    private static let localFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    private static let utcFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; f.timeZone = TimeZone(identifier: "UTC"); return f
    }()

    static func string(for date: Date, useUTC: Bool) -> String {
        useUTC ? utcFormatter.string(from: date) + " (UTC)" : localFormatter.string(from: date)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.string(for: context.date, useUTC: useUTC))
                .font(font)
                .foregroundColor(color)
        }
    }
}

/// The flight-plan chronometer, ticking itself once per second via `TimelineView` rather than the
/// old top-level `refreshTrigger` `.id()` hack that re-rendered the whole map body. (PR-10)
private struct NavChronometerText: View {
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    let font: Font
    let color: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(flightPlanManager.formattedChronometer)
                .font(font)
                .foregroundColor(color)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationMapView(isPresented: .constant(true))
        .environmentObject(AppState())
        .environmentObject(LocationManager())
        .environmentObject(OfflineMapManager())
        .environmentObject(OpenAIPCacheManager())
        .environmentObject(OpenAIPDataService())
        .environmentObject(FlightEventDetector())
}
