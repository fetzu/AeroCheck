import SwiftUI
import MapKit
import CoreLocation

/// Reliable coloured SF-Symbol image for map annotations: bakes the colour into the symbol via a palette
/// configuration. `UIImage(systemName:).withTintColor(_:renderingMode:.alwaysOriginal)` on an
/// `MKAnnotationView.image` renders BLACK on iOS 26 — so every airport/navaid/obstacle/RP marker came out
/// black. The palette config colours the glyph at creation time and is unaffected. (v4.1.0 fix)
func aeroMarkerSymbol(_ name: String, color: UIColor, pointSize: CGFloat,
                      weight: UIImage.SymbolWeight = .semibold) -> UIImage? {
    let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(UIImage.SymbolConfiguration(paletteColors: [color]))
    return UIImage(systemName: name, withConfiguration: config)
}


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
    @EnvironmentObject var dataStatusManager: DataStatusManager

    /// True when the downloaded OpenAIP airspace data is aging/stale, or the developer "simulate stale
    /// data" toggle is on — drives the on-map staleness cue (v4.1.0 Data Freshness), so stale airspace
    /// drawn on the map is visible in flight, not just in Settings.
    private var airspaceDataNeedsAttention: Bool {
        if dataStatusManager.debugForceStale { return true }
        guard openAIPDataService.isDataAvailable, let lastUpdated = openAIPDataService.lastUpdated else { return false }
        let freshness = FreshnessThresholds.aeronautical.freshness(lastUpdated: lastUpdated, now: Date())
        return freshness == .aging || freshness == .stale
    }
    @EnvironmentObject var flightEventDetector: FlightEventDetector
    @ObservedObject private var marketingProvider = MarketingLocationProvider.shared

    @Binding var isPresented: Bool
    @State private var selectedLayer: MapLayerType = .icao
    @State private var isFollowingAircraft: Bool = true
    @State private var showLayerPicker: Bool = false
    @State private var showOverlaysSheet: Bool = false   // v4.1.0 ② — the Layers sheet
    @State private var showCacheInfoModal: Bool = false
    @State private var showFlightPlanning: Bool = false
    /// Whether the flight-plan sheet (bottom bar) is expanded to show the full plan detail. (v4 UI/UX Revamp — inc C)
    @State private var navSheetExpanded: Bool = false
    /// True once the map has snapped to the aircraft after opening, so the first GPS fix centers
    /// tightly even when no position was available at open. (v4 UI/UX Revamp — center on position by default)
    @State private var hasInitiallyCentered: Bool = false
    /// A waypoint being previewed from the expanded sheet (tap a row); nil = follow the active waypoint.
    @State private var previewWaypointIndex: Int? = nil
    /// A crossed waypoint the user tapped to resume its leg (drives the confirm dialog). (v4 UI/UX Revamp)
    @State private var legResumeTarget: Int? = nil
    /// Whether the frequency column shows the full list vs the capped essentials. (v4 UI/UX Revamp — feedback)
    @State private var showAllFreqs = false
    /// Phase-aware frequencies for the sheet's right column + the collapsed chip. Cached (recomputed
    /// on phase / significant-move) rather than per-render, since it does a nearest-airport query. (v4 UI/UX Revamp C2)
    @State private var phaseFreqItems: [PhaseFrequency] = []
    // Track-vector smoothing — EMA of ground speed + ground track (track averaged circularly via
    // sin/cos so it doesn't wrap). Favours recent samples (~10 s time constant). (v4 UI/UX Revamp C4)
    @State private var smoothedGroundSpeed: Double = 0
    @State private var smoothedTrackSin: Double = 0
    @State private var smoothedTrackCos: Double = 1
    @State private var hasTrackVectorEMA = false
    /// Last known aircraft coordinate — keeps the track vector anchored across brief GPS gaps. (v4 UI/UX Revamp)
    @State private var lastKnownCoordinate: CLLocationCoordinate2D?
    /// Stable periodic timer (created once via @State) for the cruise-check evaluation — an inline
    /// Timer.publish recreated each render can stall, so the cruise check never fired. (v4 UI/UX Revamp fix)
    @State private var cruiseEvalTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @State private var mapOrientationMode: MapOrientationMode = .northUp
    @State private var locationUpdateCounter: Int = 0 // Forces map view updates on location change

    // Compact layout state (for small devices)
    @State private var showCompactPanel: Bool = false
    /// Measured height of the compact bottom sheet — the floating controls sit just above it and the
    /// sheet grows only to its content (not a fixed half-screen). (v4 UI/UX Revamp — iPhone)
    @State private var compactSheetHeight: CGFloat = 96
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
        isCompactWidth  // iPhone always uses the compact layout; plan/freq UI is gated inside. (v4 UI/UX Revamp)
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
        // never collides with the time / battery / network indicators. (v4 UI/UX Revamp fix)
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
                hasInitiallyCentered = true
            }
            // Default to centered & following the aircraft. (v4 UI/UX Revamp — center on position by default)
            isFollowingAircraft = true
            // Ensure airport data is loaded — needed both for the map overlay AND for the phase-aware
            // frequencies (nearest-airport lookup), so load it regardless of the overlay setting, then
            // refresh the cached phase frequencies once it's available. (v4 UI/UX Revamp fix)
            Task {
                await airportDataService.ensureLoaded()
                // ensureLoaded() only loads an existing cache — it never downloads. The frequency
                // feature (nearest airfield + airfield auto-complete) needs the DB, so fetch it once
                // on demand if it was never downloaded. (v4 UI/UX Revamp fix)
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
            // Prime the track-vector EMA from the last known fix so the vector appears immediately on
            // (re)open — even on a stationary device with no fresh location *change* to trigger it. (v4 UI/UX Revamp fix)
            updateTrackVectorEMA()
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
        .onChange(of: appState.settings.showNavaidsOnMap) { _, _ in recomputeMapSpatialContent(force: true) }
        .onChange(of: appState.settings.showObstaclesOnMap) { _, _ in recomputeMapSpatialContent(force: true) }
        .onChange(of: appState.settings.showReportingPointsOnMap) { _, _ in recomputeMapSpatialContent(force: true) }
        .onChange(of: appState.currentPhase) { _, _ in
            recomputePhaseFrequencies()
            appState.evaluateCruiseCheck()
        }
        .onChange(of: flightPlanManager.activeFlightPlan?.currentWaypointIndex) { _, _ in recomputePhaseFrequencies() }
        .onReceive(cruiseEvalTimer) { _ in
            appState.evaluateCruiseCheck()
            // Re-prime the track-vector EMA each tick so a stationary device (no GPS *change*) keeps a
            // valid vector after a Nav→Checklist→Nav round trip. (v4 UI/UX Revamp fix)
            updateTrackVectorEMA()
        }
        .onChange(of: appState.settings.showOpenAIPOverlay) { _, _ in recomputeMapSpatialContent(force: true) }
        .onChange(of: airportDataService.isDataAvailable) { _, available in
            recomputeMapSpatialContent(force: true)
            // Nearest-airfield + waypoint auto-complete frequencies are gated on the airport DB, which
            // loads asynchronously AFTER the first recompute. Re-run the freq build the moment it lands
            // so those entries actually appear. (v4 UI/UX Revamp fix — the recurring "only destination shows" bug.)
            if available { recomputePhaseFrequencies() }
        }
        .onChange(of: openAIPDataService.isDataAvailable) { _, _ in recomputeMapSpatialContent(force: true) }
        .onChange(of: locationManager.currentLocation) { _, newLocation in
            // Increment counter to force map view updates (ensures aircraft annotation moves)
            locationUpdateCounter += 1
            updateTrackVectorEMA()

            if isFollowingAircraft, let location = newLocation {
                if !hasInitiallyCentered {
                    // First fix after opening (no position was available at open) — snap to a tight,
                    // centered view rather than re-centering at whatever stale zoom was left. (v4 UI/UX Revamp)
                    mapState.region = MKCoordinateRegion(
                        center: location.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
                    )
                    mapState.cameraDistance = 10000
                    hasInitiallyCentered = true
                } else {
                    updateMapStateForLocation(location)
                }
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
        // Single expression (no top-level `let` + `return`) so the body is unambiguously a view, not a
        // result-builder with a disabling `return`. Heights are inlined / measured. (v4 UI/UX Revamp fix)
        ZStack(alignment: .top) {
            // Map content - full screen behind everything
            mapContent
                .ignoresSafeArea()

            // Fixed top bar overlay.
            VStack {
                compactTopBar
                    .padding(.horizontal, 12)
                    .padding(.top, geometry.safeAreaInsets.top + (geometry.safeAreaInsets.top > 50 ? 8 : 4))
                Spacer()
            }

            // Floating map controls, pinned just above the sheet (or the bottom edge when no sheet).
            VStack {
                Spacer()
                compactMapControls
                    .padding(.horizontal, 12)
                    .padding(.bottom, (appState.settings.enableFlightPlanning ? compactSheetHeight : geometry.safeAreaInsets.bottom) + 8)
                    .animation(.easeInOut(duration: 0.3), value: compactSheetHeight)
            }

            // Bottom nav sheet — only with flight planning on (it carries the plan + frequencies). The
            // sheet sizes to its content; the map view stays clean when planning is off. (v4 UI/UX Revamp)
            if appState.settings.enableFlightPlanning {
                VStack {
                    Spacer()
                    compactNavSheet(geometry: geometry)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear { mapWidth = geometry.size.width }
        .onChange(of: geometry.size) { _, newSize in mapWidth = newSize.width }
        .onPreferenceChange(CompactSheetHeightPreferenceKey.self) { compactSheetHeight = $0 }
    }

    // MARK: - Compact nav sheet (iPhone) — always-visible peek that expands to fit its content. (v4 UI/UX Revamp)

    private func compactNavSheet(geometry: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            compactSheetHandle
            if showCompactPanel {
                compactExpandedContent(bottomSafeArea: geometry.safeAreaInsets.bottom)
            } else {
                compactPeekContent(bottomSafeArea: geometry.safeAreaInsets.bottom)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(
            Color.panelBackground.opacity(0.97)
                .overlay(GeometryReader { p in
                    Color.clear.preference(key: CompactSheetHeightPreferenceKey.self, value: p.size.height)
                })
        )
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        }
        .animation(.easeInOut(duration: 0.3), value: showCompactPanel)
    }

    /// Expanded sheet body — sizes to its content (waypointList caps + scrolls internally, freqColumn
    /// is short) so the sheet only grows as much as needed. (v4 UI/UX Revamp — iPhone)
    @ViewBuilder
    private func compactExpandedContent(bottomSafeArea: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let plan = flightPlanManager.activeFlightPlan {
                legTimerCluster(.minimal)
                waypointList(plan: plan, compact: true)
                liveDataRow
                progressRow(plan: plan)
            }
            freqColumn
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, bottomSafeArea + 12)
    }

    /// Peek sheet body — leg timer (when a plan is active) + a one-line glance. No trailing Spacer, so
    /// it sizes to content. (v4 UI/UX Revamp — iPhone)
    @ViewBuilder
    private func compactPeekContent(bottomSafeArea: CGFloat) -> some View {
        VStack(spacing: 0) {
            if hasActiveFlightPlan {
                legTimerCluster(.minimal)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            compactGlanceRow
                .padding(.horizontal, 12)
                .padding(.bottom, bottomSafeArea + 10)
        }
    }

    /// "— ⌃ —" handle (pills + state chevron); tap or drag to expand/collapse the sheet. (v4 UI/UX Revamp — iPhone)
    private var compactSheetHandle: some View {
        HStack(spacing: 6) {
            Capsule().fill(Color.white.opacity(0.22)).frame(width: 16, height: 4)
            Image(systemName: showCompactPanel ? "chevron.down" : "chevron.up")
                .font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.5))
            Capsule().fill(Color.white.opacity(0.22)).frame(width: 16, height: 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8).padding(.bottom, 7)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.3)) { showCompactPanel.toggle() } }
        .gesture(
            DragGesture(minimumDistance: 10).onEnded { value in
                withAnimation(.easeInOut(duration: 0.3)) {
                    if value.translation.height < -24 { showCompactPanel = true }
                    else if value.translation.height > 24 { showCompactPanel = false }
                }
            }
        )
    }

    /// Peek glance — next-waypoint summary + the current frequency chip; tap to expand. (v4 UI/UX Revamp — iPhone)
    private var compactGlanceRow: some View {
        HStack(spacing: 8) {
            navGlanceData
            Spacer(minLength: 6)
            compactFreqChip
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.3)) { showCompactPanel = true } }
    }

    private var compactFreqChip: some View {
        let active = phaseFreqItems.first(where: { $0.role == .current })
            ?? phaseFreqItems.first(where: { !$0.isEmergency }) ?? phaseFreqItems.first
        return HStack(spacing: 5) {
            Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 12))
            if let active {
                Text(active.station).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                Text(active.freq).font(.system(size: 13, weight: .semibold, design: .monospaced))
            } else {
                Text("FREQ").font(.system(size: 11, weight: .bold))
            }
        }
        .foregroundColor(.aviationGold).lineLimit(1)
    }

    // MARK: - Compact Top Bar

    private var compactTopBar: some View {
        HStack(spacing: 8) {
            // Close button
            Button(action: { isPresented = false }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.primaryText)
                    .frame(width: 44, height: 44) // HIG minimum tap target (UX-16)
                    .floatingChromeCircle()
            }

            // Flight Plan button — only when flight planning (Beta) is on; the map view stays clean
            // (no plan button or sheet) when it's off. (v4 UI/UX Revamp — iPhone)
            if appState.settings.enableFlightPlanning {
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
                        .environmentObject(locationManager)
                }
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

            // Layers button → grouped overlays sheet (airspace/tiles · markers + show-all · track vector).
            // (v4.1.0 ② — iPhone reaches every layer toggle here; the map-type picker is its own button.)
            Button(action: { showOverlaysSheet = true }) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 14))
                    .foregroundColor(.primaryText)
                    .frame(width: 44, height: 44)
                    .floatingChromeCircle()
            }
            .accessibilityLabel(L10n.Nav.layers)
            .sheet(isPresented: $showOverlaysSheet) {
                OverlaysSheet().environmentObject(appState)
            }

            // Map-type picker button (shows the cache info modal in offline mode).
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
                    .environmentObject(appState)
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

                // (FREQ button removed — frequencies now live in the always-visible bottom sheet peek.)

                // 3-state tracking button: free → center & follow → track-up → free. (v4 UI/UX Revamp — iPhone)
                Button(action: cycleTracking) {
                    Image(systemName: trackingIcon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(trackingTint)
                        .frame(width: 40, height: 40)
                        .floatingChromeCircle()
                }
                .accessibilityLabel(L10n.Nav.navigation)
                .animation(.easeInOut(duration: 0.2), value: mapState.cameraHeading)

                // Zoom out / in (pinch also works). (v4 UI/UX Revamp — iPhone)
                VStack(spacing: 0) {
                    Button(action: { zoom(by: 0.5) }) {
                        Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primaryText).frame(width: 40, height: 36).contentShape(Rectangle())
                    }
                    .accessibilityLabel(L10n.Nav.zoomIn)
                    Rectangle().fill(Color.white.opacity(0.12)).frame(width: 22, height: 0.5)
                    Button(action: { zoom(by: 2.0) }) {
                        Image(systemName: "minus").font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primaryText).frame(width: 40, height: 36).contentShape(Rectangle())
                    }
                    .accessibilityLabel(L10n.Nav.zoomOut)
                }
                .floatingChromeBackground(cornerRadius: 10)
            }
        }
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
    @State private var visibleNavaids: [Navaid] = []
    @State private var visibleObstacles: [Obstacle] = []
    @State private var visibleReportingPoints: [ReportingPoint] = []
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

        // Phase-aware frequencies depend on the nearest airport, so refresh them on a real move. (v4 UI/UX Revamp C2)
        recomputePhaseFrequencies()

        // Airports — queried once and reused below for the frequency lines. Independent layer,
        // controlled solely by `showAirportsOnMap` (decoupled from the airspace overlay — v4.1.0 fix).
        let airports: [Airport]
        if appState.settings.showAirportsOnMap,
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

        // Navaids — independent layer, controlled solely by its toggle (v4.1.0; decoupled from the
        // airspace overlay, which draws vector CTRs from data, never the navaid symbols).
        if appState.settings.showNavaidsOnMap,
           OpenAIPNavaidDataService.shared.isDataAvailable {
            let navHalfLat = region.span.latitudeDelta / 2
            let navHalfLon = region.span.longitudeDelta / 2
            visibleNavaids = OpenAIPNavaidDataService.shared.navaidsInRegion(
                latRange: (region.center.latitude - navHalfLat)...(region.center.latitude + navHalfLat),
                lonRange: (region.center.longitude - navHalfLon)...(region.center.longitude + navHalfLon))
        } else {
            visibleNavaids = []
        }

        // Obstacles — independent layer, controlled solely by its toggle (v4.1.0; decoupled from overlay).
        if appState.settings.showObstaclesOnMap,
           OpenAIPObstacleDataService.shared.isDataAvailable {
            let obsHalfLat = region.span.latitudeDelta / 2
            let obsHalfLon = region.span.longitudeDelta / 2
            visibleObstacles = OpenAIPObstacleDataService.shared.obstaclesInRegion(
                latRange: (region.center.latitude - obsHalfLat)...(region.center.latitude + obsHalfLat),
                lonRange: (region.center.longitude - obsHalfLon)...(region.center.longitude + obsHalfLon))
        } else {
            visibleObstacles = []
        }

        // VFR reporting points — independent layer, controlled solely by its toggle (v4.1.0; decoupled).
        if appState.settings.showReportingPointsOnMap,
           OpenAIPReportingPointDataService.shared.isDataAvailable {
            let rpHalfLat = region.span.latitudeDelta / 2
            let rpHalfLon = region.span.longitudeDelta / 2
            visibleReportingPoints = OpenAIPReportingPointDataService.shared.reportingPointsInRegion(
                latRange: (region.center.latitude - rpHalfLat)...(region.center.latitude + rpHalfLat),
                lonRange: (region.center.longitude - rpHalfLon)...(region.center.longitude + rpHalfLon))
        } else {
            visibleReportingPoints = []
        }

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
                showOpenAIPTiles: appState.settings.showOpenAIPTiles,
                openAIPCacheManager: openAIPCacheManager,
                airspacePolygons: visibleAirspacePolygons,
                trackVectorOverlays: trackVectorOverlays,
                trackVectorEnabled: appState.settings.showTrackVector,
                currentWaypointIndex: currentWaypointIndex,
                locationUpdateCounter: locationUpdateCounter,
                visibleAirports: visibleAirports,
                visibleNavaids: visibleNavaids,
                visibleObstacles: visibleObstacles,
                visibleReportingPoints: visibleReportingPoints,
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
                visibleNavaids: visibleNavaids,
                visibleObstacles: visibleObstacles,
                visibleReportingPoints: visibleReportingPoints,
                airportFrequencyLines: airportFrequencyLines,
                cachedHeading: locationManager.currentCourseDegrees,
                showOpenAIPOverlay: appState.settings.showOpenAIPOverlay,
                showOpenAIPTiles: appState.settings.showOpenAIPTiles,
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
                Image(systemName: "chevron.down")
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
                        // a disabled Button was dimming the text. (v4 UI/UX Revamp — re-cruise)
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

            // Layers button — opens the grouped overlays sheet (airspace/tiles · markers + show-all ·
            // track vector). Replaces the standalone track-vector button so the on-map button count
            // stays at two even as layers grow. (v4.1.0 ②)
            Button(action: { showOverlaysSheet = true }) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondaryText)
                    .frame(width: 44, height: 44)
                    .background(Color.panelBackground.opacity(0.92), in: Circle())
            }
            .accessibilityLabel(L10n.Nav.layers)
            .sheet(isPresented: $showOverlaysSheet) {
                OverlaysSheet().environmentObject(appState)
            }

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
            .overlay(alignment: .topTrailing) {
                // On-map staleness cue (v4.1.0): an amber badge when the downloaded airspace data is
                // aging/stale, so stale airspace drawn on the map is visible in flight.
                if airspaceDataNeedsAttention {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.aviationAmber)
                        .padding(2)
                        .background(Color.panelBackground, in: Circle())
                        .offset(x: 5, y: -5)
                        .accessibilityHidden(true)
                }
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
                    .environmentObject(appState)
            }
        }
    }

    // MARK: - Bottom Controls

    /// The bottom assembly: a scale bar + offline/cache badge floating just above a full-width,
    /// two-row glass bar. Row 1 = NAV (next waypoint) + FREQ; row 2 = flight plan + GPS / tracking /
    /// zoom. (v4 UI/UX Revamp nav-chrome rebuild)
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
                // Degrade the row when horizontal space runs out: MARK/START labels → icons (compact),
                // then drop the +/− zoom buttons (minimal). ViewThatFits picks the first that fits. (v4 UI/UX Revamp)
                ViewThatFits(in: .horizontal) {
                    bottomControlRow(.full)
                    bottomControlRow(.compact)
                    bottomControlRow(.minimal)
                }
            }
            .background(
                Color.panelBackground.opacity(0.92)
                    .ignoresSafeArea(edges: .bottom)
            )
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.09)).frame(height: 0.5)
            }
            // Tap a crossed waypoint in the leg table → confirm resuming that leg. (v4 UI/UX Revamp)
            .confirmationDialog(
                L10n.Nav.resumeLegTitle,
                isPresented: Binding(get: { legResumeTarget != nil }, set: { if !$0 { legResumeTarget = nil } }),
                titleVisibility: .visible,
                presenting: legResumeTarget
            ) { idx in
                Button(L10n.Nav.resumeLeg, role: .destructive) {
                    flightPlanManager.resumeLeg(at: idx)
                    legResumeTarget = nil
                }
                Button(L10n.Button.cancel, role: .cancel) { legResumeTarget = nil }
            } message: { _ in
                Text(L10n.Nav.resumeLegMessage)
            }
            // Covers for the row-2 buttons — declared once on the bar (the buttons live inside the
            // ViewThatFits candidates). (v4 UI/UX Revamp)
            .fullScreenCover(isPresented: $showFlightPlanning) {
                FlightPlanningView()
                    .environmentObject(appState)
                    .environmentObject(flightPlanManager)
                    .environmentObject(airportDataService)
                    .environmentObject(aircraftDataService)
                    .environmentObject(openAIPDataService)
                    .environmentObject(locationManager)
            }
            .fullScreenCover(isPresented: $showGPSStatusModal) {
                GPSStatusInfoSheet(currentStatus: locationManager.gpsSignalStatus, isPresented: $showGPSStatusModal)
            }
        }
    }

    /// Grab handle — two grabber pills flanking a state-aware chevron ("— ⌃ —" collapsed / "— ⌄ —"
    /// expanded): keeps the iOS drag-grabber convention but adds an explicit expand cue. Tap to toggle,
    /// or drag up/down (snaps). (v4 UI/UX Revamp inc C)
    private var navSheetHandle: some View {
        HStack(spacing: 6) {
            Capsule().fill(Color.white.opacity(0.22)).frame(width: 16, height: 4)
            Image(systemName: navSheetExpanded ? "chevron.down" : "chevron.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
            Capsule().fill(Color.white.opacity(0.22)).frame(width: 16, height: 4)
        }
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
                // Chronometer moved to bottom-bar row 2 (always visible). (v4 UI/UX Revamp)
            }
            .lineLimit(1)
        } else {
            Text(L10n.Nav.flightPlan)
                .font(.system(size: 12)).foregroundColor(.dimText)
        }
    }

    /// Collapsed chip — the active (phase-relevant) frequency; tap expands the sheet to the full
    /// phase-aware list. (v4 UI/UX Revamp C2)
    private var freqChip: some View {
        let active = phaseFreqItems.first(where: { $0.role == .current })
            ?? phaseFreqItems.first(where: { !$0.isEmergency }) ?? phaseFreqItems.first
        return Button(action: { withAnimation(.easeInOut(duration: 0.28)) { navSheetExpanded = true } }) {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 13))
                if let active {
                    Text(active.station).font(.system(size: 10, weight: .semibold)).tracking(0.3).lineLimit(1)
                    Text(active.freq).font(.system(size: 14, weight: .semibold, design: .monospaced))
                } else {
                    Text("FREQ").font(.system(size: 12, weight: .bold))
                }
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

    // MARK: - Phase-aware frequencies (v4 UI/UX Revamp C2)

    private func areaFreqs(for sector: SwissAirspaceSector) -> [SwissCommonFrequency] {
        switch sector {
        case .zurich: return [.zurichInfo, .fisEast]
        case .geneva: return [.genevaInfo, .fisWest]
        case .east: return [.fisEast]
        case .west: return [.fisWest]
        }
    }

    private struct FreqEntry { let station: String; let freq: String }

    /// The nearest airfield that actually has usable VFR frequencies — walks up to 6 nearest and skips
    /// frequency-less fields (grass strips / heliports), mirroring the HUD's nearest-strip logic. The
    /// old `limit: 1` made a single freq-less closest field silently drop the whole nearest entry, so
    /// the area FIS ("Zurich Info") wrongly became the current frequency. (v4 UI/UX Revamp fix)
    private func nearestAirfieldWithFreqs(to coord: CLLocationCoordinate2D) -> Airport? {
        guard airportDataService.isDataAvailable else { return nil }
        return airportDataService.findNearestAirports(to: coord, limit: 6, maxDistanceNm: 40)
            .first { !airfieldFreqs(for: $0.ident).isEmpty }
    }

    private func airportDistanceNm(from coord: CLLocationCoordinate2D, to apt: Airport) -> Double {
        CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            .distance(from: CLLocation(latitude: apt.latitude, longitude: apt.longitude)) / 1852.0
    }

    /// Select the CURRENT and NEXT frequencies a VFR pilot needs, proximity-aware: within ~10 NM of a
    /// field CURRENT is that field's contact, else the area FIS/Info; NEXT is the next route airfield,
    /// else the nearest CTR ahead, else the FIS↔field hand-off. Prefers the CONTACT freq (ATIS is
    /// listen-only and stays under "All Frequencies"). Degrades to plan order with no GPS. (v4 UI/UX Revamp)
    private func computeCurrentNextFreqs() -> (current: FreqEntry?, next: FreqEntry?) {
        func contact(_ list: [(label: String, freq: String)]) -> FreqEntry? {
            (list.first { !$0.label.uppercased().contains("ATIS") } ?? list.first)
                .map { FreqEntry(station: $0.label, freq: $0.freq) }
        }
        // No usable position: fall back to plan order (departure = current, next waypoint = next).
        guard let loc = locationManager.currentLocation, airportDataService.isDataAvailable else {
            guard let plan = flightPlanManager.activeFlightPlan, !plan.waypoints.isEmpty else { return (nil, nil) }
            let cur = contact(waypointFreqs(plan.waypoints[0]))
            let nxt = plan.waypoints.dropFirst().lazy.compactMap { contact(self.waypointFreqs($0)) }.first
            return (cur, nxt)
        }
        let coord = loc.coordinate
        let nearField = nearestAirfieldWithFreqs(to: coord)
        let nearDist = nearField.map { airportDistanceNm(from: coord, to: $0) }
        let nearEntry = nearField.flatMap { apt in
            contact(airfieldFreqs(for: apt.ident).map { (label: "\(apt.ident) \($0.type)", freq: $0.freq) })
        }
        let fisCommon = SwissAirspaceSectors.isInSwitzerland(coord)
            ? areaFreqs(for: SwissAirspaceSectors.getSector(for: coord)).first : nil
        let fisEntry = fisCommon.map { FreqEntry(station: $0.name, freq: $0.frequency) }

        let nearActive = (nearDist ?? .infinity) <= 10.0  // ~10 NM ≈ inside a typical CTR/RMZ

        // CURRENT: near a field → that field; else the area FIS you're working enroute.
        let current = nearActive ? (nearEntry ?? fisEntry) : (fisEntry ?? nearEntry)

        // NEXT: the next station you'll need — next route airfield, else nearest CTR ahead, else the
        // FIS↔field hand-off (at a field you'll call Info next; enroute the next field).
        var next: FreqEntry?
        if let plan = flightPlanManager.activeFlightPlan {
            let idx = plan.currentWaypointIndex
            if let aheadIdx = plan.waypoints.indices.first(where: { $0 > idx && !waypointFreqs(plan.waypoints[$0]).isEmpty }) {
                next = contact(waypointFreqs(plan.waypoints[aheadIdx]))
            }
        }
        if next == nil,
           let ctr = openAIPDataService.nearbyCTRs(from: coord, withinNM: 25, requireFrequencies: true).first,
           let f = ctr.airspace.primaryFrequency {
            next = FreqEntry(station: ctr.airspace.shortName, freq: f.value)
        }
        if next == nil { next = nearActive ? fisEntry : nearEntry }
        if let c = current, let n = next, c.station == n.station, c.freq == n.freq { next = nil }
        return (current, next)
    }

    /// Recompute the cached frequency list. CURRENT + NEXT (proximity/time-aware) show by default along
    /// with EMERGENCY; everything else along the journey (nearest field's full set, route waypoints,
    /// area FIS, nearby CTRs) is `.other`, revealed by "All Frequencies". Deduped; cached (recomputed
    /// on phase change + significant move). (v4 UI/UX Revamp — current/next)
    private func recomputePhaseFrequencies() {
        guard appState.settings.enableFlightPlanning else {
            phaseFreqItems = []
            WatchConnectivityManager.shared.updatePanelFrequencies([])
            return
        }
        var items: [PhaseFrequency] = []
        var seen = Set<String>()
        func add(_ station: String, _ freq: String, role: FreqRole = .other, emergency: Bool = false) {
            let key = freq + "|" + station
            guard !seen.contains(key) else { return }
            seen.insert(key)
            items.append(PhaseFrequency(station: station, freq: freq,
                                        highlighted: role == .current, isEmergency: emergency,
                                        role: emergency ? .emergency : role))
        }

        // CURRENT + NEXT — the two a VFR pilot needs at a glance.
        let (current, next) = computeCurrentNextFreqs()
        if let c = current { add(c.station, c.freq, role: .current) }
        if let n = next { add(n.station, n.freq, role: .next) }

        // Everything else, in journey order, for "All Frequencies" (deduped vs current/next).
        if let loc = locationManager.currentLocation, let near = nearestAirfieldWithFreqs(to: loc.coordinate) {
            for f in airfieldFreqs(for: near.ident) { add("\(near.ident) \(f.type)", f.freq) }
        }
        if let plan = flightPlanManager.activeFlightPlan, !plan.waypoints.isEmpty {
            for wp in plan.waypoints { for (label, freq) in waypointFreqs(wp) { add(label, freq) } }
        }
        if let loc = locationManager.currentLocation, SwissAirspaceSectors.isInSwitzerland(loc.coordinate) {
            for sf in areaFreqs(for: SwissAirspaceSectors.getSector(for: loc.coordinate)) { add(sf.name, sf.frequency) }
        }
        if let loc = locationManager.currentLocation {
            for ctr in openAIPDataService.nearbyCTRs(from: loc.coordinate, withinNM: 25, requireFrequencies: true) {
                if let f = ctr.airspace.primaryFrequency { add(ctr.airspace.shortName, f.value) }
            }
        }

        // Emergency, always last.
        add(SwissCommonFrequency.emergency.name, SwissCommonFrequency.emergency.frequency, emergency: true)
        phaseFreqItems = items

        // Mirror this exact list (content + NOW/NEXT + order) to the Apple Watch. (Watch freq sync)
        WatchConnectivityManager.shared.updatePanelFrequencies(items.map { item in
            let role: FrequencyRole = item.isEmergency ? .emergency
                : item.role == .current ? .now
                : item.role == .next ? .next : .other
            return FrequencyInfo(name: item.station, frequency: item.freq, type: .common, role: role)
        })
    }

    /// An airfield's VFR frequencies: ATIS first when present (the first listen — it does NOT give you
    /// the next entity's frequency), then the contact frequency (TWR > AFIS > INFO > A/G > … — never
    /// the APP/GND that was being shown wrongly). (v4 UI/UX Revamp)
    // Single source of truth shared with the HUD NEAREST strip (AirportDataService).
    private static let contactPriority = AirportDataService.fieldContactPriority
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
    /// auto-completed from the DB when the waypoint name is an airfield ident. (v4 UI/UX Revamp)
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

    // MARK: - Track vector (v4 UI/UX Revamp C4)

    /// Update the EMA of ground speed + ground track on each GPS fix. Track is averaged via sin/cos so
    /// it never wraps; α≈0.15 favours recent fixes (~10 s time constant). (v4 UI/UX Revamp C4)
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
    /// Empty when disabled, stationary (<5 kt), or no fix. (v4 UI/UX Revamp C4)
    private var trackVectorOverlays: [TrackVectorPolyline] {
        guard appState.settings.showTrackVector, hasTrackVectorEMA,
              let origin = locationManager.currentLocation?.coordinate ?? lastKnownCoordinate else { return [] }
        // Hide the vector when essentially stationary (<5 kt) — ground track is meaningless there. (v4 UI/UX Revamp)
        guard smoothedGroundSpeed >= 5 else { return [] }
        let gsKnots = smoothedGroundSpeed
        let track = atan2(smoothedTrackSin, smoothedTrackCos) * 180 / .pi
        let gsMS = gsKnots * 0.514444 // knots → m/s
        var overlays: [TrackVectorPolyline] = []
        // Each segment is drawn twice: a dark casing first (below) + the bright core on top — so it
        // stays legible on the busy/light Segelflugkarte AND on dark satellite imagery. (v4 UI/UX Revamp fix)
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

    /// Geodesic forward projection: a coordinate `distanceMeters` from `c` along `bearingDeg`. (v4 UI/UX Revamp C4)
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
    /// RIGHT column = phase-aware frequencies. (v4 UI/UX Revamp inc C / C2 — paradigm: left = nav, right = freq)
    @ViewBuilder
    private var navSheetContent: some View {
        if let plan = flightPlanManager.activeFlightPlan {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
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
                // which ballooned the whole sheet. (v4 UI/UX Revamp fix — 3rd attempt)
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
            // expanding still shows it. (v4 UI/UX Revamp fix — the chevron did nothing without a plan)
            freqColumn
                // Mirror the with-plan layout: same 244-pt column, pushed to the trailing edge (where
                // it sits as the right column when a plan is active) rather than centered. (v4 UI/UX Revamp fix)
                .frame(width: 244)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 14)
                .padding(.top, 2)
                .padding(.bottom, 10)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The frequency column — by default just CURRENT + NEXT (what a VFR pilot needs to hand) plus
    /// EMERGENCY; "All Frequencies" reveals every station along the journey in order. (v4 UI/UX Revamp — current/next)
    private var freqColumn: some View {
        let nonEmergency = phaseFreqItems.filter { !$0.isEmergency }
        let emergency = phaseFreqItems.filter { $0.isEmergency }
        let essentials = nonEmergency.filter { $0.role == .current || $0.role == .next }
        let hasMore = nonEmergency.count > essentials.count
        let visible = showAllFreqs ? nonEmergency : essentials
        return VStack(alignment: .leading, spacing: 0) {
            Text(L10n.Nav.radioFrequencies)
                .font(.system(size: 9, weight: .semibold)).tracking(0.4)
                .foregroundColor(.altimeterBlue)
                .lineLimit(1)
                .padding(.bottom, 4)
            ForEach(visible) { freqRow($0) }
            if hasMore {
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

    /// A short CURRENT/NEXT tag + its colour, or nil for other rows. (v4 UI/UX Revamp)
    private func roleTag(_ role: FreqRole) -> (String, Color)? {
        switch role {
        case .current: return (L10n.Nav.freqCurrent, .aviationGold)
        case .next: return (L10n.Nav.freqNext, .altimeterBlue)
        default: return nil
        }
    }

    private func freqRow(_ item: PhaseFrequency) -> some View {
        HStack(spacing: 6) {
            if let tag = roleTag(item.role) {
                Text(tag.0)
                    .font(.system(size: 8, weight: .bold)).tracking(0.3)
                    .foregroundColor(tag.1)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(tag.1.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
            }
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

    private func waypointList(plan: FlightPlan, compact: Bool = false) -> some View {
        // Deterministic height (content for ≤5 waypoints, scroll beyond) — a greedy ScrollView made
        // the whole sheet balloon to fill the screen. Keep the sheet as short as the content. (v4 UI/UX Revamp fix)
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(plan.waypoints.enumerated()), id: \.element.id) { index, wpt in
                    waypointRow(plan: plan, index: index, wpt: wpt, compact: compact)
                    if index < plan.waypoints.count - 1 {
                        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
                    }
                }
            }
        }
        .frame(height: CGFloat(min(max(plan.waypoints.count, 1), 5)) * 36)
    }

    private func waypointRow(plan: FlightPlan, index: Int, wpt: FlightPlanWaypoint, compact: Bool = false) -> some View {
        let isCurrent = index == plan.currentWaypointIndex
        let isPast = index < plan.currentWaypointIndex
        let isPreview = previewWaypointIndex == index
        let leg = plan.legArriving(at: index)
        let actual = actualLegTime(plan: plan, index: index, isCurrent: isCurrent, isPast: isPast, wpt: wpt)
        return Button(action: { handleWaypointTap(index: index, plan: plan, isPast: isPast) }) {
            HStack(spacing: 8) {
                // Sequence number — matches the numbered disc on the map. (v4 UI/UX Revamp)
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(isCurrent ? .aviationGold : .secondaryText)
                    .frame(width: 16, alignment: .center)
                Image(systemName: isPast ? "circle.fill" : (isCurrent ? "location.fill" : "circle"))
                    .font(.system(size: 9))
                    .foregroundColor(isPast ? .aviationGreen : (isCurrent ? .aviationGold : .dimText))
                Text(wpt.name.isEmpty ? "WPT \(index + 1)" : wpt.name)
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular, design: .monospaced))
                    .foregroundColor(isCurrent ? .aviationGold : .primaryText)
                    .lineLimit(1)
                Spacer(minLength: 6)
                // Fixed-width columns so every row's heading / distance / PLAN / ACT / Δ line up,
                // whether or not a leg has been flown yet. (v4 UI/UX Revamp — column alignment)
                HStack(spacing: 6) {
                    // Heading + distance kept on iPad; dropped on the narrow iPhone table. (v4 UI/UX Revamp)
                    if !compact {
                        Text(leg?.magneticCourse.map { String(format: "%03d°", Int($0)) } ?? "")
                            .foregroundColor(.secondaryText).frame(width: 38, alignment: .trailing)
                        Text(leg?.distance.map { String(format: "%.1f", $0) } ?? "")
                            .foregroundColor(.secondaryText).frame(width: 40, alignment: .trailing)
                    }
                    Text((leg?.totalLegEET).map { formatClock($0) } ?? "")  // PLAN (EET)
                        .foregroundColor(.dimText).frame(width: 44, alignment: .trailing)
                    Text(actual.map { formatClock($0) } ?? "")            // ACT / live
                        .foregroundColor(isCurrent ? .aviationGold : .aviationGreen)
                        .frame(width: 44, alignment: .trailing)
                    legDeltaText(planned: leg?.totalLegEET, actual: actual)  // Δ ahead/over
                        .frame(width: 52, alignment: .trailing)
                }
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(isPreview ? Color.altimeterBlue.opacity(0.14)
                        : (isCurrent ? Color.aviationGold.opacity(0.10) : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Actual time flown on the leg arriving at `index`: the live timer for the current leg, ATO-to-ATO
    /// for a crossed leg, nil for a future leg. (v4 UI/UX Revamp)
    private func actualLegTime(plan: FlightPlan, index: Int, isCurrent: Bool, isPast: Bool, wpt: FlightPlanWaypoint) -> TimeInterval? {
        if isCurrent {
            let e = flightPlanManager.chronometerElapsed
            return e > 0.5 ? e : nil
        }
        if isPast, index >= 1, let ato = wpt.actualTimeOver,
           let prev = plan.waypoints[index - 1].actualTimeOver {
            return ato.timeIntervalSince(prev)
        }
        return nil
    }

    /// The ▲ ahead / ▼ over delta of actual vs planned leg time, or blank when not yet comparable. (v4 UI/UX Revamp)
    @ViewBuilder
    private func legDeltaText(planned: TimeInterval?, actual: TimeInterval?) -> some View {
        if let planned, let actual {
            let d = planned - actual
            Text((d >= 0 ? "▲" : "▼") + formatClock(abs(d)))
                .foregroundColor(d >= 0 ? .aviationGreen : .aviationAmber)
        } else {
            Text("")
        }
    }

    /// Tap a crossed waypoint → confirm resuming that leg; tap a current/future one → map preview. (v4 UI/UX Revamp)
    private func handleWaypointTap(index: Int, plan: FlightPlan, isPast: Bool) {
        if isPast {
            legResumeTarget = index
        } else {
            previewWaypoint(index: index, plan: plan)
        }
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
                    liveStat("ETE", formatClock(eta))  // live time to the next waypoint
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

    /// Row 2 — flight plan (left, when relevant) and GPS / tracking / zoom (right). (v4 UI/UX Revamp)
    /// Destination endpoint, total remaining distance (live to next + remaining planned legs), and the
    /// planned ETA at the destination. (v4 UI/UX Revamp — row 2)
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

    /// How dense the bottom control row renders — ViewThatFits picks the first that fits, degrading the
    /// MARK/START labels to icon-only (compact), then dropping the +/− zoom buttons (minimal, pinch
    /// still zooms). (v4 UI/UX Revamp — responsive row 2)
    enum BarDensity { case full, compact, minimal }

    /// VFR leg timer on row 2 — times the current leg, compares it to the planned leg time (▲ ahead /
    /// ▼ over), and MARK records the crossing + restarts the leg. Pause/resume + reset. Idle shows just
    /// a START button. Plan-scoped, always visible without opening the drawer. (v4 UI/UX Revamp — leg timer)
    @ViewBuilder
    private func legTimerCluster(_ density: BarDensity) -> some View {
        if let plan = flightPlanManager.activeFlightPlan {
            let plannedLeg = plan.legArriving(at: plan.currentWaypointIndex)?.totalLegEET
            let canMark = plan.currentWaypointIndex < plan.waypoints.count
            let legLabel = currentLegLabel(plan)
            let iconOnly = density != .full  // MARK/START shrink to their icon when space is tight
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let running = flightPlanManager.isChronometerRunning
                let elapsed = flightPlanManager.chronometerElapsed
                let started = running || elapsed > 0.5
                HStack(spacing: 6) {
                    if !started {
                        legPillButton(icon: "stopwatch", label: L10n.Nav.startLeg, tint: .aviationGreen, filled: false, iconOnly: iconOnly) {
                            flightPlanManager.startChronometer()
                        }
                    } else {
                        legReadout(legLabel: density == .minimal ? nil : legLabel, elapsed: elapsed, planned: plannedLeg, running: running)
                        if canMark {
                            let markName = plan.waypoints[plan.currentWaypointIndex].name
                            let markLabel = markName.isEmpty ? L10n.Nav.mark : "\(L10n.Nav.mark) \(markName)"
                            legPillButton(icon: "mappin.and.ellipse", label: markLabel, tint: .aviationGold, filled: true, iconOnly: iconOnly) {
                                flightPlanManager.markWaypoint()
                            }
                        }
                        legIconButton(running ? "pause.fill" : "play.fill",
                                      accessibilityLabel: running ? L10n.Nav.pauseChronometer : L10n.Nav.startChronometer) {
                            running ? flightPlanManager.pauseChronometer() : flightPlanManager.startChronometer()
                        }
                        legIconButton("arrow.counterclockwise",
                                      accessibilityLabel: L10n.Nav.resetChronometer) { flightPlanManager.resetChronometer() }
                    }
                }
            }
        }
    }

    /// "FROM → TO" idents for the leg currently being flown, or nil before the first leg / once done. (v4 UI/UX Revamp)
    private func currentLegLabel(_ plan: FlightPlan) -> String? {
        let i = plan.currentWaypointIndex
        guard i >= 1, i < plan.waypoints.count else { return nil }
        let from = plan.waypoints[i - 1].name
        let to = plan.waypoints[i].name
        return "\(from.isEmpty ? "WPT \(i)" : from) → \(to.isEmpty ? "WPT \(i + 1)" : to)"
    }

    /// The current leg (FROM → TO) + leg elapsed vs the planned leg time, with an ahead/over delta. (v4 UI/UX Revamp)
    private func legReadout(legLabel: String?, elapsed: TimeInterval, planned: TimeInterval?, running: Bool) -> some View {
        HStack(spacing: 6) {
            if let legLabel {
                Text(legLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primaryText).lineLimit(1)
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 16)
            }
            Image(systemName: "stopwatch").font(.system(size: 12)).foregroundColor(running ? .aviationGreen : .secondaryText)
            Text(formatClock(elapsed))
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(running ? .aviationGreen : .secondaryText)
            if let planned {
                Text("/ \(formatClock(planned))").font(.system(size: 11, design: .monospaced)).foregroundColor(.dimText)
                let delta = planned - elapsed
                Text((delta >= 0 ? "▲" : "▼") + formatClock(abs(delta)))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(delta >= 0 ? .aviationGreen : .aviationAmber)
            }
        }
        .padding(.horizontal, 9).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.10), lineWidth: 1)))
        .fixedSize(horizontal: true, vertical: false)  // one line — never wrap the timer text
    }

    private func legPillButton(icon: String, label: String, tint: Color, filled: Bool, iconOnly: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                if !iconOnly { Text(label).font(.system(size: 12, weight: .semibold)).fixedSize() }
            }
            .foregroundColor(filled ? .black : tint)
            .padding(.horizontal, iconOnly ? 8 : 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(filled ? tint : tint.opacity(0.16)))
            .frame(minHeight: 44)   // 44pt touch target around the 32pt visual
            .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    private func legIconButton(_ icon: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondaryText)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
                .frame(minWidth: 44, minHeight: 44)   // 44pt touch target around the 32pt visual
                .contentShape(Rectangle())
        }
        .accessibilityLabel(accessibilityLabel)
    }

    /// A duration as "M:SS" (or "H:MM:SS" past an hour). (v4 UI/UX Revamp)
    private func formatClock(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func bottomControlRow(_ density: BarDensity) -> some View {
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
            }

            // Destination summary — endpoint + total remaining + ETA, so the drawer is only needed for
            // the mid-route outlook. (v4 UI/UX Revamp — device feedback)
            destinationSummaryView

            Spacer()

            // Leg timer — centered on row 2, always visible without opening the drawer. (v4 UI/UX Revamp)
            legTimerCluster(density)

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

            // Zoom out / in (kept for gloved / turbulence use, docked far-right). First thing dropped
            // when horizontal space runs out — pinch still zooms. (v4 UI/UX Revamp)
            if density != .minimal {
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Live distance to the next waypoint (NM), if a fix + plan are available. (v4 UI/UX Revamp)
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
        // visible airports out of the freshly re-queried region whenever follow was engaged. (v4 UI/UX Revamp fix)
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
    /// free → center & follow (north-up) → track-up (rotate with heading) → free. (v4 UI/UX Revamp nav-chrome rebuild)
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
    /// is kept current by the map's `regionDidChangeAnimated`, so this reads the true zoom. (v4 UI/UX Revamp)
    private func zoom(by factor: Double) {
        // The map camera is distance-driven (setCamera fromDistance: mapState.cameraDistance), so a
        // span-only change never zoomed the tile layers — it just got reverted by regionDidChange.
        // Scale the camera distance AND nudge the region so updateUIView re-applies the camera. (v4 UI/UX Revamp fix)
        mapState.cameraDistance = min(max(mapState.cameraDistance * factor, 800), 4_000_000)
        let r = mapState.region
        let lat = min(max(r.span.latitudeDelta * factor, 0.0015), 80)
        let lon = min(max(r.span.longitudeDelta * factor, 0.0015), 80)
        mapState.updateFromRegion(
            MKCoordinateRegion(center: r.center, span: MKCoordinateSpan(latitudeDelta: lat, longitudeDelta: lon))
        )
    }
}

/// One phase-aware frequency row for the flight-plan sheet (station label + frequency). (v4 UI/UX Revamp C2)
/// Role of a frequency in the current/next/emergency model: only CURRENT + NEXT (+ EMERGENCY) show by
/// default; everything else is `.other`, revealed by "All Frequencies". (v4 UI/UX Revamp)
enum FreqRole { case current, next, other, emergency }

/// Preference key reporting the compact bottom sheet's measured height, so the floating map controls
/// sit just above it. (v4 UI/UX Revamp — iPhone)
struct CompactSheetHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct PhaseFrequency: Identifiable {
    let id = UUID()
    let station: String
    let freq: String
    let highlighted: Bool
    let isEmergency: Bool
    var role: FreqRole = .other
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
    /// Aviation distance unit: NM (default for the nav map) vs metric. (v4 UI/UX Revamp — configurable in settings)
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

        // Choose appropriate scale - pick the largest round number that fits. Aviation uses NM. (v4 UI/UX Revamp)
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

/// A numbered waypoint marker — a state-coloured disc with the waypoint's 1-based sequence number,
/// matching the numbered rows in the flight-plan drawer. White number on a black-outlined disc reads
/// on any map layer. Cached per state+number. (`iconName` kept for call-site compatibility — the
/// number is drawn instead of an SF Symbol.) (v4 UI/UX Revamp)
private func cachedWaypointMarker(number: Int, state: String, iconName: String, color: UIColor, size: CGFloat = 26) -> UIImage? {
    let key = "\(state)-\(number)"
    if let cached = waypointMarkerImageCache[key] { return cached }

    let diameter = size
    let strokeWidth: CGFloat = 2.0
    let imageSize = CGSize(width: diameter + strokeWidth * 2, height: diameter + strokeWidth * 2)
    UIGraphicsBeginImageContextWithOptions(imageSize, false, 0)
    defer { UIGraphicsEndImageContext() }
    guard let ctx = UIGraphicsGetCurrentContext() else { return nil }

    let circleRect = CGRect(x: strokeWidth, y: strokeWidth, width: diameter, height: diameter)
    ctx.setFillColor(color.cgColor)
    ctx.fillEllipse(in: circleRect)
    ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.85).cgColor)
    ctx.setLineWidth(strokeWidth)
    ctx.strokeEllipse(in: circleRect)

    let text = "\(number)" as NSString
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: diameter * 0.56, weight: .heavy),
        .foregroundColor: UIColor.white,
        .paragraphStyle: para,
    ]
    let textSize = text.size(withAttributes: attrs)
    text.draw(at: CGPoint(x: circleRect.midX - textSize.width / 2, y: circleRect.midY - textSize.height / 2), withAttributes: attrs)

    let finalImage = UIGraphicsGetImageFromCurrentImageContext()
    if let finalImage { waypointMarkerImageCache[key] = finalImage }
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
    var visibleNavaids: [Navaid] = []  // Navaids to display on map (v4.1.0)
    var visibleObstacles: [Obstacle] = []  // Obstacles to display on map (v4.1.0)
    var visibleReportingPoints: [ReportingPoint] = []  // VFR reporting points to display on map (v4.1.0)
    var airportFrequencyLines: [String: String] = [:]  // ICAO -> all frequencies (newline-separated)
    var cachedHeading: Double?  // Cached course from LocationManager (survives GPS gaps)
    var showOpenAIPOverlay: Bool = false
    var showOpenAIPTiles: Bool = false
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

        // Add OpenAIP raster tile overlay if enabled (separate from the airspace vector — v4.1.0)
        if showOpenAIPTiles {
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
        // (brief GPS gap / <5 kt) keep the existing vector instead of blanking it. (v4 UI/UX Revamp fix)
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
        updateNavaidAnnotations(mapView, context: context)
        updateObstacleAnnotations(mapView, context: context)
        updateReportingPointAnnotations(mapView, context: context)
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

    private func updateNavaidAnnotations(_ mapView: MKMapView, context: Context) {
        let existing = mapView.annotations.compactMap { $0 as? NavaidAnnotation }
        let existingIds = Set(existing.map { $0.navaid.id })
        let newIds = Set(visibleNavaids.map { $0.id })
        mapView.removeAnnotations(existing.filter { !newIds.contains($0.navaid.id) })
        for navaid in visibleNavaids where !existingIds.contains(navaid.id) {
            mapView.addAnnotation(NavaidAnnotation(navaid: navaid))
        }
    }

    private func updateObstacleAnnotations(_ mapView: MKMapView, context: Context) {
        let existing = mapView.annotations.compactMap { $0 as? ObstacleAnnotation }
        let existingIds = Set(existing.map { $0.obstacle.id })
        let newIds = Set(visibleObstacles.map { $0.id })
        mapView.removeAnnotations(existing.filter { !newIds.contains($0.obstacle.id) })
        for obstacle in visibleObstacles where !existingIds.contains(obstacle.id) {
            mapView.addAnnotation(ObstacleAnnotation(obstacle: obstacle))
        }
    }

    private func updateReportingPointAnnotations(_ mapView: MKMapView, context: Context) {
        let existing = mapView.annotations.compactMap { $0 as? ReportingPointAnnotation }
        let existingIds = Set(existing.map { $0.point.id })
        let newIds = Set(visibleReportingPoints.map { $0.id })
        mapView.removeAnnotations(existing.filter { !newIds.contains($0.point.id) })
        for point in visibleReportingPoints where !existingIds.contains(point.id) {
            mapView.addAnnotation(ReportingPointAnnotation(point: point))
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
        // Scope strictly to the GPS-track polyline. This used to cast to `MKPolyline`, which ALSO
        // matched the flight-plan route and the track-vector subclasses — so a point-count mismatch
        // removed ALL of them and only re-added the GPS track (route/vector "flashed then vanished").
        // `GPSTrackPolyline` isolates the breadcrumb trail. (v4 UI/UX Revamp fix)
        let existingPolylines = mapView.overlays.compactMap { $0 as? GPSTrackPolyline }
        // Rebuild only when new source points arrived (compare source count, not the possibly
        // subsampled vertex count), and cap the drawn vertices for very long tracks. (v4.0.0 review P2)
        let needsUpdate = existingPolylines.first?.sourceCount != gpsTrack.count
        if needsUpdate {
            mapView.removeOverlays(existingPolylines)
            if gpsTrack.count > 1 {
                let coordinates = subsampledTrackCoordinates(gpsTrack)
                let polyline = GPSTrackPolyline(coordinates: coordinates, count: coordinates.count)
                polyline.sourceCount = gpsTrack.count
                // Use .aboveLabels for GPS track to ensure visibility over tile overlays
                mapView.addOverlay(polyline, level: .aboveLabels)
            }
        }
    }

    private func updateOpenAIPOverlay(_ mapView: MKMapView, context: Context) {
        let hasOverlay = mapView.overlays.contains(where: { $0 is OpenAIPTileOverlay })

        if showOpenAIPTiles && !hasOverlay {
            let overlay = OpenAIPTileOverlay(cacheManager: openAIPCacheManager)
            mapView.addOverlay(overlay, level: .aboveLabels)
        } else if !showOpenAIPTiles && hasOverlay {
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

            // Handle navaid annotation (v4.1.0)
            if let navaidAnnotation = annotation as? NavaidAnnotation {
                let id = "NavaidAnnotation"
                let navaidView: MKAnnotationView
                if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: id) {
                    reused.annotation = navaidAnnotation
                    navaidView = reused
                } else {
                    navaidView = MKAnnotationView(annotation: navaidAnnotation, reuseIdentifier: id)
                }
                navaidView.canShowCallout = true
                navaidView.image = aeroMarkerSymbol("hexagon", color: UIColor(red: 1.0, green: 0.72, blue: 0.0, alpha: 1.0), pointSize: 13)
                return navaidView
            }

            // Handle obstacle annotation (v4.1.0)
            if let obstacleAnnotation = annotation as? ObstacleAnnotation {
                let id = "ObstacleAnnotation"
                let obstacleView: MKAnnotationView
                if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: id) {
                    reused.annotation = obstacleAnnotation
                    obstacleView = reused
                } else {
                    obstacleView = MKAnnotationView(annotation: obstacleAnnotation, reuseIdentifier: id)
                }
                obstacleView.canShowCallout = true
                obstacleView.image = aeroMarkerSymbol("exclamationmark.triangle.fill", color: UIColor(red: 0.95, green: 0.5, blue: 0.1, alpha: 1.0), pointSize: 13)
                return obstacleView
            }

            // Handle reporting-point annotation (v4.1.0)
            if let reportingPointAnnotation = annotation as? ReportingPointAnnotation {
                let id = "ReportingPointAnnotation"
                let rpView: MKAnnotationView
                if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: id) {
                    reused.annotation = reportingPointAnnotation
                    rpView = reused
                } else {
                    rpView = MKAnnotationView(annotation: reportingPointAnnotation, reuseIdentifier: id)
                }
                rpView.canShowCallout = true
                let symbol = reportingPointAnnotation.point.compulsory ? "triangle.fill" : "triangle"
                rpView.image = aeroMarkerSymbol(symbol, color: UIColor(red: 0.85, green: 0.2, blue: 0.6, alpha: 1.0), pointSize: 12)
                return rpView
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

            annotationView.image = cachedWaypointMarker(number: annotation.waypointIndex + 1, state: stateKey, iconName: iconName, color: markerColor)

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

            annotationView.image = aeroMarkerSymbol(iconName, color: color, pointSize: size, weight: .medium)

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
    @EnvironmentObject var appState: AppState
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
        .presentationDetents([.height(620)])
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
/// The grouped map-layers sheet opened by the "Layers" button: Airspace & charts (airspace vector +
/// optional raster tiles), Map markers (airports/navaids/reporting points/obstacles with a show-all
/// master), and Flight (track vector). (v4.1.0 ② — entry-point consolidation + tiles/airspace split)
struct OverlaysSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    private var anyMarkerOn: Bool {
        appState.settings.showAirportsOnMap || appState.settings.showNavaidsOnMap ||
        appState.settings.showReportingPointsOnMap || appState.settings.showObstaclesOnMap
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    groupCard(L10n.Nav.airspaceCharts) {
                        toggleRow(icon: "shield", title: L10n.Nav.airspace, isOn: appState.settings.showOpenAIPOverlay) {
                            appState.settings.showOpenAIPOverlay.toggle(); appState.saveSettings()
                        }
                        Divider().padding(.leading, 56)
                        toggleRow(icon: "square.grid.3x3", title: L10n.Nav.mapTiles, isOn: appState.settings.showOpenAIPTiles) {
                            appState.settings.showOpenAIPTiles.toggle(); appState.saveSettings()
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L10n.Nav.mapMarkers)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondaryText)
                            Spacer()
                            Button(anyMarkerOn ? L10n.Nav.hideAll : L10n.Nav.showAll) {
                                setAllMarkers(!anyMarkerOn)
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.aviationGold)
                        }
                        .padding(.horizontal, 20)
                        VStack(spacing: 0) {
                            toggleRow(icon: "mappin.and.ellipse", title: L10n.DataStorage.airportsName, isOn: appState.settings.showAirportsOnMap) {
                                appState.settings.showAirportsOnMap.toggle(); appState.saveSettings()
                            }
                            Divider().padding(.leading, 56)
                            toggleRow(icon: "antenna.radiowaves.left.and.right", title: L10n.DataStorage.navaidsName, isOn: appState.settings.showNavaidsOnMap) {
                                appState.settings.showNavaidsOnMap.toggle(); appState.saveSettings()
                            }
                            Divider().padding(.leading, 56)
                            toggleRow(icon: "triangle", title: L10n.DataStorage.reportingPointsName, isOn: appState.settings.showReportingPointsOnMap) {
                                appState.settings.showReportingPointsOnMap.toggle(); appState.saveSettings()
                            }
                            Divider().padding(.leading, 56)
                            toggleRow(icon: "exclamationmark.triangle", title: L10n.DataStorage.obstaclesName, isOn: appState.settings.showObstaclesOnMap) {
                                appState.settings.showObstaclesOnMap.toggle(); appState.saveSettings()
                            }
                        }
                        .background(Color.panelBackground)
                        .cornerRadius(12)
                        .padding(.horizontal, 16)
                    }

                    groupCard(L10n.Nav.flightSection) {
                        toggleRow(icon: "location.north.line", title: L10n.Nav.trackVector, isOn: appState.settings.showTrackVector) {
                            appState.settings.showTrackVector.toggle(); appState.saveSettings()
                        }
                    }
                }
                .padding(.vertical, 16)
            }
            .background(Color.cockpitBackground)
            .navigationTitle(L10n.Nav.layers)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.done) { dismiss() }
                }
            }
        }
        .presentationDetents([.height(520)])
        .preferredColorScheme(.dark)
    }

    private func setAllMarkers(_ on: Bool) {
        appState.settings.showAirportsOnMap = on
        appState.settings.showNavaidsOnMap = on
        appState.settings.showReportingPointsOnMap = on
        appState.settings.showObstaclesOnMap = on
        appState.saveSettings()
    }

    @ViewBuilder
    private func groupCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondaryText)
                .padding(.horizontal, 20)
            VStack(spacing: 0) { content() }
                .background(Color.panelBackground)
                .cornerRadius(12)
                .padding(.horizontal, 16)
        }
    }

    private func toggleRow(icon: String, title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).font(.system(size: 18))
                    .foregroundColor(isOn ? .aviationGold : .secondaryText).frame(width: 30)
                Text(title).font(.system(size: 16, weight: .medium)).foregroundColor(.primaryText)
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isOn ? .aviationGold : .dimText)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

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
    var showOpenAIPTiles: Bool = false
    var openAIPCacheManager: OpenAIPCacheManager?
    var airspacePolygons: [AirspacePolygon] = []
    var trackVectorOverlays: [MKPolyline] = []  // Ground-track trend vector (line + ticks)
    var trackVectorEnabled: Bool = false  // Keep a valid vector across transient empties; remove only when off
    var currentWaypointIndex: Int = 0  // Track separately to force updates
    var locationUpdateCounter: Int = 0  // Forces updateUIView on every location change
    var visibleAirports: [Airport] = []  // Airports to display on map
    var visibleNavaids: [Navaid] = []  // Navaids to display on map (v4.1.0)
    var visibleObstacles: [Obstacle] = []  // Obstacles to display on map (v4.1.0)
    var visibleReportingPoints: [ReportingPoint] = []  // VFR reporting points to display on map (v4.1.0)
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
                if self.showOpenAIPTiles {
                    let openAIPOverlay = OpenAIPTileOverlay(
                        cacheManager: self.openAIPCacheManager,
                        isStrictOfflineMode: self.isStrictOfflineMode
                    )
                    mapView.addOverlay(openAIPOverlay, level: .aboveLabels)
                }

                // The base tile was just re-added on TOP (same .aboveLabels level), which buries the
                // flight-plan route line. Invalidate the route diff-guard so the next updateUIView
                // redraws the route above the tile. (v4 UI/UX Revamp fix — route line was invisible on Swiss layers)
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
        if showOpenAIPTiles && !hasOpenAIPOverlay {
            let openAIPOverlay = OpenAIPTileOverlay(
                cacheManager: openAIPCacheManager,
                isStrictOfflineMode: isStrictOfflineMode
            )
            mapView.addOverlay(openAIPOverlay, level: .aboveLabels)
        } else if !showOpenAIPTiles && hasOpenAIPOverlay {
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
        // (brief GPS gap / <5 kt) keep the existing vector instead of blanking it. (v4 UI/UX Revamp fix)
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
                // Exclude the track vector too — a Swiss layer switch must not strip it. (v4 UI/UX Revamp fix)
                if overlay is FlightPlanRoutePolyline || overlay is MKTileOverlay || overlay is TrackVectorPolyline { return nil }
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
        updateNavaidAnnotations(mapView, context: context)
        updateObstacleAnnotations(mapView, context: context)
        updateReportingPointAnnotations(mapView, context: context)
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

    private func updateNavaidAnnotations(_ mapView: MKMapView, context: Context) {
        let existing = mapView.annotations.compactMap { $0 as? NavaidAnnotation }
        let existingIds = Set(existing.map { $0.navaid.id })
        let newIds = Set(visibleNavaids.map { $0.id })
        mapView.removeAnnotations(existing.filter { !newIds.contains($0.navaid.id) })
        for navaid in visibleNavaids where !existingIds.contains(navaid.id) {
            mapView.addAnnotation(NavaidAnnotation(navaid: navaid))
        }
    }

    private func updateObstacleAnnotations(_ mapView: MKMapView, context: Context) {
        let existing = mapView.annotations.compactMap { $0 as? ObstacleAnnotation }
        let existingIds = Set(existing.map { $0.obstacle.id })
        let newIds = Set(visibleObstacles.map { $0.id })
        mapView.removeAnnotations(existing.filter { !newIds.contains($0.obstacle.id) })
        for obstacle in visibleObstacles where !existingIds.contains(obstacle.id) {
            mapView.addAnnotation(ObstacleAnnotation(obstacle: obstacle))
        }
    }

    private func updateReportingPointAnnotations(_ mapView: MKMapView, context: Context) {
        let existing = mapView.annotations.compactMap { $0 as? ReportingPointAnnotation }
        let existingIds = Set(existing.map { $0.point.id })
        let newIds = Set(visibleReportingPoints.map { $0.id })
        mapView.removeAnnotations(existing.filter { !newIds.contains($0.point.id) })
        for point in visibleReportingPoints where !existingIds.contains(point.id) {
            mapView.addAnnotation(ReportingPointAnnotation(point: point))
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
        // Scope strictly to the GPS-track polyline. This used to cast to `MKPolyline`, which ALSO
        // matched the flight-plan route and the track-vector subclasses — so a point-count mismatch
        // removed ALL of them and only re-added the GPS track (route/vector "flashed then vanished").
        // `GPSTrackPolyline` isolates the breadcrumb trail. (v4 UI/UX Revamp fix)
        let existingPolylines = mapView.overlays.compactMap { $0 as? GPSTrackPolyline }
        // Rebuild only when new source points arrived (compare source count, not the possibly
        // subsampled vertex count), and cap the drawn vertices for very long tracks. (v4.0.0 review P2)
        let needsUpdate = existingPolylines.first?.sourceCount != gpsTrack.count
        if needsUpdate {
            mapView.removeOverlays(existingPolylines)
            if gpsTrack.count > 1 {
                let coordinates = subsampledTrackCoordinates(gpsTrack)
                let polyline = GPSTrackPolyline(coordinates: coordinates, count: coordinates.count)
                polyline.sourceCount = gpsTrack.count
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

            // Handle navaid annotation (v4.1.0)
            if let navaidAnnotation = annotation as? NavaidAnnotation {
                let id = "NavaidAnnotation"
                let navaidView: MKAnnotationView
                if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: id) {
                    reused.annotation = navaidAnnotation
                    navaidView = reused
                } else {
                    navaidView = MKAnnotationView(annotation: navaidAnnotation, reuseIdentifier: id)
                }
                navaidView.canShowCallout = true
                navaidView.image = aeroMarkerSymbol("hexagon", color: UIColor(red: 1.0, green: 0.72, blue: 0.0, alpha: 1.0), pointSize: 13)
                return navaidView
            }

            // Handle obstacle annotation (v4.1.0)
            if let obstacleAnnotation = annotation as? ObstacleAnnotation {
                let id = "ObstacleAnnotation"
                let obstacleView: MKAnnotationView
                if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: id) {
                    reused.annotation = obstacleAnnotation
                    obstacleView = reused
                } else {
                    obstacleView = MKAnnotationView(annotation: obstacleAnnotation, reuseIdentifier: id)
                }
                obstacleView.canShowCallout = true
                obstacleView.image = aeroMarkerSymbol("exclamationmark.triangle.fill", color: UIColor(red: 0.95, green: 0.5, blue: 0.1, alpha: 1.0), pointSize: 13)
                return obstacleView
            }

            // Handle reporting-point annotation (v4.1.0)
            if let reportingPointAnnotation = annotation as? ReportingPointAnnotation {
                let id = "ReportingPointAnnotation"
                let rpView: MKAnnotationView
                if let reused = mapView.dequeueReusableAnnotationView(withIdentifier: id) {
                    reused.annotation = reportingPointAnnotation
                    rpView = reused
                } else {
                    rpView = MKAnnotationView(annotation: reportingPointAnnotation, reuseIdentifier: id)
                }
                rpView.canShowCallout = true
                let symbol = reportingPointAnnotation.point.compulsory ? "triangle.fill" : "triangle"
                rpView.image = aeroMarkerSymbol(symbol, color: UIColor(red: 0.85, green: 0.2, blue: 0.6, alpha: 1.0), pointSize: 12)
                return rpView
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

            annotationView.image = cachedWaypointMarker(number: annotation.waypointIndex + 1, state: stateKey, iconName: iconName, color: markerColor)

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

            annotationView.image = aeroMarkerSymbol(iconName, color: color, pointSize: size, weight: .medium)

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

/// The recorded GPS breadcrumb trail. A distinct subclass so overlay bookkeeping targets ONLY the
/// trail and never the route or track vector (all three are MKPolylines). (v4 UI/UX Revamp fix)
class GPSTrackPolyline: MKPolyline {
    /// Number of source GPS points this polyline was built from (it may carry fewer, subsampled,
    /// vertices). Used to decide whether a rebuild is needed without re-rendering on every redraw.
    var sourceCount: Int = 0
}

/// Max vertices drawn for the GPS breadcrumb. Long flights are subsampled to this so MapKit doesn't
/// re-tessellate thousands of points on every fix; short tracks pass through unchanged. (v4.0.0 review P2)
private let maxTrackVertices = 3000
private func subsampledTrackCoordinates(_ track: [GPSPoint]) -> [CLLocationCoordinate2D] {
    guard track.count > maxTrackVertices else { return track.map { $0.coordinate } }
    let step = Double(track.count - 1) / Double(maxTrackVertices - 1)
    var result: [CLLocationCoordinate2D] = []
    result.reserveCapacity(maxTrackVertices)
    for i in 0..<maxTrackVertices {
        let idx = min(Int((Double(i) * step).rounded()), track.count - 1)
        result.append(track[idx].coordinate)
    }
    return result
}

/// Marker subclass for the ground-track trend vector (line + 1/2/5-min ticks), rendered cyan. (v4 UI/UX Revamp C4)
class TrackVectorPolyline: MKPolyline {}

/// The dark casing drawn under each track-vector segment for legibility on any map. (v4 UI/UX Revamp fix)
class TrackVectorCasingPolyline: TrackVectorPolyline {}

// MARK: - Swisstopo tile overlays
// `ICAOSegelflugkarteTileOverlay` and `SwisstopoTileOverlay` moved to the shared
// `Services/SwisstopoTileOverlays.swift` (v4 UI/UX Revamp design-system consolidation — they were
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

// MARK: - Preview

#Preview {
    NavigationMapView(isPresented: .constant(true))
        .environmentObject(AppState())
        .environmentObject(LocationManager())
        .environmentObject(OfflineMapManager())
        .environmentObject(OpenAIPCacheManager())
        .environmentObject(OpenAIPDataService())
        .environmentObject(FlightEventDetector())
        .environmentObject(DataStatusManager(providers: [], networkMonitor: NetworkMonitor(stub: .disconnected)))
}
