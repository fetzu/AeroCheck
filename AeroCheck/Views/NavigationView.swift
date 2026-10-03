import Combine
import SwiftUI
import MapKit
import CoreLocation

/// Reliable coloured marker image for `MKAnnotationView`. On iOS 26 a *symbol* image assigned to
/// `MKAnnotationView.image` renders BLACK no matter how it's tinted (`.withTintColor(…, .alwaysOriginal)`
/// AND a palette `SymbolConfiguration` both fail) — the annotation view re-templates the glyph. The fix
/// is to flatten the tinted symbol into a plain bitmap via `UIGraphicsImageRenderer` (a non-template
/// image is shown as-is) — the same technique the aircraft marker uses. (v4.1.0 fix)
func aeroMarkerSymbol(_ name: String, color: UIColor, pointSize: CGFloat,
                      weight: UIImage.SymbolWeight = .semibold) -> UIImage? {
    let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let symbol = UIImage(systemName: name, withConfiguration: config) else { return nil }
    let tinted = symbol.withTintColor(color, renderingMode: .alwaysOriginal)
    let renderer = UIGraphicsImageRenderer(size: tinted.size)
    return renderer.image { _ in
        tinted.draw(in: CGRect(origin: .zero, size: tinted.size))
    }
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
    /// Coordinates the map should frame on its next update (user tapped "Show" on the off-screen
    /// route pill). Consumed by the representables, same idiom as `pendingHeadingReset`.
    ///
    /// It has to be done map-side rather than by computing a region here: fitting a bounding box into
    /// a viewport depends on the viewport's aspect ratio, and only `setVisibleMapRect(edgePadding:)`
    /// knows it. Deriving a camera distance from the route's extent framed a 200 NM east–west route
    /// as if it were 20 NM tall and zoomed into the middle of it. (v4.4.0)
    var pendingFitCoordinates: [CLLocationCoordinate2D]?
    /// What the map shows while the legs panel's band has the camera, for the airports and airspace
    /// drawn on it. The band never writes `region`, `cameraDistance` or `cameraHeading`: they keep the
    /// map the pilot left, which closing the panel puts back. nil with the panel closed. (6.1, option C)
    @Published var bandRegion: MKCoordinateRegion?

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

    /// The band's map moved. Deferred, as `updateFromRegion` is.
    func updateBandRegion(_ region: MKCoordinateRegion) {
        DispatchQueue.main.async { [weak self] in
            self?.bandRegion = region
        }
    }

    /// The panel closed and the map is back where it was.
    func endBand() {
        DispatchQueue.main.async { [weak self] in
            self?.bandRegion = nil
        }
    }

    /// Request the map to reset heading to north
    func requestHeadingReset() {
        pendingHeadingReset = true
        cameraHeading = 0
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
    /// The zoom the map was left at, so reopening it (or switching the Cockpit back to MAP) doesn't
    /// throw away the scale the pilot chose. nil until the map has been shown once. (v6.0 · P2)
    var cameraDistance: Double?
    var latitudeDelta: Double?
}

extension MapOrientationMode: Equatable {}

/// Full-screen navigation map view with aircraft position tracking
struct NavigationMapView: View {
    @Environment(\.cockpitTheme) private var theme
    @EnvironmentObject var locationManager: LocationManager
    @Environment(AppState.self) private var appState
    @EnvironmentObject var offlineMapManager: OfflineMapManager
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var airportDataService: AirportDataService
    @EnvironmentObject var aircraftDataService: AircraftDataService
    @EnvironmentObject var openAIPCacheManager: OpenAIPCacheManager
    @EnvironmentObject var openAIPDataService: OpenAIPDataService
    @EnvironmentObject var dataStatusManager: DataStatusManager
    // Observed so the count-based recompute triggers actually fire when each layer's async
    // first-load lands (these services are singletons, not environment objects). (v4.2 fix)
    @ObservedObject private var openAIPNavaidDataService = OpenAIPNavaidDataService.shared
    @ObservedObject private var openAIPObstacleDataService = OpenAIPObstacleDataService.shared
    @ObservedObject private var openAIPReportingPointDataService = OpenAIPReportingPointDataService.shared
    /// The aerodrome procedures (6.2.0): its `revision` redraws them when a download or the first load lands.
    @ObservedObject private var vfrProcedureService = OFMDataService.shared

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
    @EnvironmentObject var aviationWeatherService: AviationWeatherService
    /// For the one line a diversion shows when a flight plan was filed. (v5.1)
    @EnvironmentObject var threadManager: FlightThreadManager
    @ObservedObject private var marketingProvider = MarketingLocationProvider.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var isPresented: Bool
    /// False in the Plan tab, where the map is a section of the screen rather than a cover to close.
    /// (v6.0 · P1)
    var showsCloseButton: Bool = true
    /// The MAP pane of the Cockpit (iPad): no top bar — the Cockpit's header and instrument strip are
    /// right above — and no second flight-event overlay, the Cockpit has one. (v6.0 · P2)
    /// Plan › Map uses the same chrome, so the map a pilot plans on is the map they fly with.
    /// (on-device review #4)
    var isInCockpit: Bool = false
    /// Where "Routes" goes instead of opening the routes as a cover: Plan › Map switches to its own
    /// Routes section, rather than stacking a second copy of it over the tab. (on-device review #4)
    var onShowRoutes: (() -> Void)? = nil
    /// The Cockpit on a phone on its side (I7): its header and strip, for the top of a column on the
    /// left that also takes the thumb bar, with the map at full height beside it. (iPhone pass)
    var leadingColumn: AnyView? = nil
    var leadingColumnWidth: CGFloat = 340
    /// Over the chart, under the next waypoint: the Cockpit's chips that come and go (BRIEFING, the
    /// cautions), on the phone. Over it, they pushed the next waypoint down as they came. (6.1)
    var mapTopAccessory: AnyView? = nil
    /// The Cockpit's CHECKLIST pane, for the check slot's "N items". Given by the Cockpit only: with it,
    /// in flight, the check slot leads the bottom row. (6.1)
    var onShowChecklist: (() -> Void)? = nil
    @State private var selectedLayer: MapLayerType = .icao
    @State private var isFollowingAircraft: Bool = true
    /// iPad: base chart and overlays in one labelled sheet. (v6.0 · C1)
    @State private var showMapSheet: Bool = false
    /// Measured height of the open legs-and-frequencies panel, so it hugs its content up to its limit.
    @State private var legsPanelContentHeight: CGFloat = 0
    /// Emergency, pinned to the open panel's foot: its height. (6.1, option C)
    @State private var emergencyFooterHeight: CGFloat = 0
    /// The panel just opened: its scroll is to bring the leg being flown into view, once measured.
    @State private var legsRevealPending = false
    /// The chart's measures, for the band the open panel leaves between the card and itself.
    @State private var chartGeometry = ChartGeometry()
    /// The map as the panel found it, put back when it closes. (6.1, option C)
    @State private var cameraBeforeLegs: LegsPanelMap.SavedCamera?
    @State private var showCacheInfoModal: Bool = false
    @State private var showSigmets: Bool = false
    /// The Cockpit's chips over the chart, as last measured: the room kept for them. (6.1)
    @State private var mapAccessoryHeight: CGFloat?
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
    /// Stable periodic timer (created once via @State) for FREDA's evaluation — an inline
    /// Timer.publish recreated each render can stall, so the reminder never fired. (v4 UI/UX Revamp fix)
    @State private var fredaEvalTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @State private var mapOrientationMode: MapOrientationMode = .northUp
    /// The last MARK or leg-timer reset, offered back for a few seconds. (v6.0 · C2)
    @State private var undoOffer: NavUndoOffer?
    @State private var locationUpdateCounter: Int = 0 // Forces map view updates on location change

    @State private var showGPSStatusModal: Bool = false
    @State private var streamingCTRCheckTask: Task<Void, Never>?
    /// The Divert sheet, and the field it opens on when reached from an airport callout. (v5.1)
    @State private var showDivert = false
    @State private var divertPreselect: String?

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
            return theme.textDim
        }

        // If below stall speed, always red
        if speedKnots < stallSpeed {
            return theme.danger
        }

        // If we have a target speed, color based on that
        if let target = targetSpeed {
            if abs(speedKnots - target) <= 5 {
                return theme.onTarget // On target
            } else {
                return .orange // Off target
            }
        }

        // No target speed, use green
        return theme.onTarget
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
        // SEC-C15: never convert a sensor/peer-derived Double with a trapping initializer.
        // An implausible or unrepresentable course falls back to the same 0 the nil case uses,
        // rather than trapping the process.
        if let course = locationManager.currentCourseDegrees { return course.safeInt(or: 0) }
        return 0
    }

    var body: some View {
        // The handlers in two expressions of their own (`mapLifecycle`, `mapDataRefresh`), and the longer
        // ones in methods. Chained here, all of it was one expression, and from #278 on the compiler of
        // Xcode 26, which the CodeQL job builds with, gave up type-checking it: "unable to type-check this
        // expression in reasonable time". (6.1.0)
        mapDataRefresh(mapLifecycle(mapWithPresentations))
    }

    /// The map and what it presents.
    private var mapWithPresentations: some View {
        // One layout on both devices: the phone's own map chrome went with the iPhone pass (I4).
        GeometryReader { geometry in
            standardLayoutBody(geometry: geometry)
        }
        // Only as its own cover. Embedded in a ground tab, a preferred scheme would darken the whole
        // window, and the root could no longer read the device's light/dark for Auto. (v6.0 · P1)
        .preferredColorScheme(showsCloseButton ? .dark : nil)
        // Immersive full-screen map: hide the system status bar so the top chrome (airspace / layer)
        // never collides with the time / battery / network indicators. (v4 UI/UX Revamp fix)
        // Not in the Plan tab, where the tab bar sits above the map. (v6.0 · P1)
        .statusBarHidden(showsCloseButton)
        // A detected go-around / touch-and-go / full-stop must be confirmable while the full-screen
        // map is up — FlightView's own overlay sits behind this .fullScreenCover. (PR-40)
        // In the Cockpit the map is inside FlightView, whose overlay already covers it.
        .modifier(FlightEventOverlayUnlessEmbedded(isEmbedded: isInCockpit,
                                                   detector: flightEventDetector, appState: appState))
        .sheet(isPresented: $showDivert) {
            DivertSheet(onClose: { showDivert = false }, preselectedIdent: divertPreselect)
                .environment(\.cockpitTheme, theme)
                .environmentObject(flightPlanManager)
                .environmentObject(airportDataService)
                .environmentObject(locationManager)
                .presentationDetents([.large])
        }
    }

    /// Opening and closing the map, its region, the panel, the overlay settings, the phase, the leg and
    /// the FREDA tick.
    private func mapLifecycle(_ content: some View) -> some View {
        content
        .onAppear { handleAppear() }
        .onDisappear { handleDisappear() }
        // PR-11: recompute the visible airports/airspace only when the region moves past the
        // quantization threshold (the function early-returns otherwise), instead of on every body
        // re-eval. A toggled overlay setting or newly-available data forces an immediate recompute.
        .onReceive(mapState.$region) { _ in
            recomputeMapSpatialContent()
        }
        // The band's chart, while the legs panel is open. (6.1, option C)
        .onReceive(mapState.$bandRegion) { _ in
            recomputeMapSpatialContent()
        }
        .onChange(of: navSheetExpanded) { _, open in
            if open { legsPanelOpened() } else { legsPanelClosed() }
        }
        .onChange(of: appState.settings.showAirportsOnMap) { _, _ in recomputeMapSpatialContent(force: true) }
        .onChange(of: appState.settings.showNavaidsOnMap) { _, _ in recomputeMapSpatialContent(force: true) }
        .onChange(of: appState.settings.showObstaclesOnMap) { _, _ in recomputeMapSpatialContent(force: true) }
        .onChange(of: appState.settings.showReportingPointsOnMap) { _, _ in recomputeMapSpatialContent(force: true) }
        // The aerodrome procedures: their switches, their data, the palette and the plan's ends. (6.2.0)
        .modifier(VFRLayerFollower(key: vfrLayerKey) { recomputeMapSpatialContent(force: true) })
        .onChange(of: appState.currentPhase) { _, _ in
            recomputePhaseFrequencies()
            appState.evaluateFreda(lastPassage: FredaWaypointPassage.latest(in: flightPlanManager.activeFlightPlan))
        }
        .onChange(of: flightPlanManager.activeFlightPlan?.currentWaypointIndex) { _, _ in recomputePhaseFrequencies() }
        .onReceive(fredaEvalTimer) { _ in
            appState.evaluateFreda(lastPassage: FredaWaypointPassage.latest(in: flightPlanManager.activeFlightPlan))
            // Re-prime the track-vector EMA each tick so a stationary device (no GPS *change*) keeps a
            // valid vector after a Nav→Checklist→Nav round trip. (v4 UI/UX Revamp fix)
            updateTrackVectorEMA()
        }
    }

    /// The map's content as its data and settings change, the aircraft as it moves, the layer as chosen.
    private func mapDataRefresh(_ content: some View) -> some View {
        content
        .onChange(of: appState.settings.showOpenAIPOverlay) { _, _ in recomputeMapSpatialContent(force: true) }
        .onChange(of: airportDataService.isDataAvailable) { _, available in
            recomputeMapSpatialContent(force: true)
            // Nearest-airfield + waypoint auto-complete frequencies are gated on the airport DB, which
            // loads asynchronously AFTER the first recompute. Re-run the freq build the moment it lands
            // so those entries actually appear. (v4 UI/UX Revamp fix — the recurring "only destination shows" bug.)
            if available { recomputePhaseFrequencies() }
        }
        .onChange(of: openAIPDataService.isDataAvailable) { _, _ in recomputeMapSpatialContent(force: true) }
        // First-open race (v4.2 fix): `isDataAvailable` is restored from cache METADATA at app
        // launch — it is already true before this view first appears, so the onChange above never
        // fires for the initial async feature decode. The forced onAppear recompute runs against a
        // still-empty array, and the unforced region recompute early-returns (region unchanged) —
        // leaving the enabled overlay blank until a real pan/zoom. Recomputing when the loaded
        // COUNTS land closes the race for all four layers.
        .onChange(of: openAIPDataService.airspaceCount) { _, _ in recomputeMapSpatialContent(force: true) }
        .onChange(of: openAIPNavaidDataService.navaidCount) { _, _ in recomputeMapSpatialContent(force: true) }
        .onChange(of: openAIPObstacleDataService.obstacleCount) { _, _ in recomputeMapSpatialContent(force: true) }
        .onChange(of: openAIPReportingPointDataService.reportingPointCount) { _, _ in recomputeMapSpatialContent(force: true) }
        .onChange(of: locationManager.currentLocation) { _, newLocation in handleLocationChange(newLocation) }
        .onChange(of: selectedLayer) { _, newLayer in handleLayerChange(to: newLayer) }
    }

    private func handleAppear() {
        // Restore map settings from session state
        selectedLayer = appState.navigationMapState.selectedLayer
        mapOrientationMode = appState.navigationMapState.orientationMode
        // Start GPS updates when navigation view opens
        locationManager.startLocationUpdates()
        // Center on aircraft location immediately (synchronous, not via async dispatch)
        // so the map renders at the correct position from the first frame
        if let location = locationManager.currentLocation {
            mapState.region = MKCoordinateRegion(center: location.coordinate, span: initialSpan)
            mapState.cameraDistance = initialCameraDistance
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

    private func handleDisappear() {
        // Keep the zoom for next time. (v6.0 · P2)
        appState.navigationMapState.cameraDistance = mapState.cameraDistance
        appState.navigationMapState.latitudeDelta = mapState.region.span.latitudeDelta
        // Stop GPS updates when navigation view closes (if not in a flight)
        locationManager.stopLocationUpdates()
        streamingCTRCheckTask?.cancel()
        streamingCTRCheckTask = nil
    }

    private func handleLocationChange(_ newLocation: CLLocation?) {
        // Increment counter to force map view updates (ensures aircraft annotation moves)
        locationUpdateCounter += 1
        updateTrackVectorEMA()

        // Not with the legs panel open: its band follows the aircraft itself, and leaves the shared
        // state as the pilot had it for the panel to put back. (6.1, option C)
        if isFollowingAircraft, !navSheetExpanded, let location = newLocation {
            if !hasInitiallyCentered {
                // First fix after opening (no position was available at open) — snap to a tight,
                // centered view rather than re-centering at whatever stale zoom was left. (v4 UI/UX Revamp)
                mapState.region = MKCoordinateRegion(center: location.coordinate, span: initialSpan)
                mapState.cameraDistance = initialCameraDistance
                hasInitiallyCentered = true
            } else {
                updateMapStateForLocation(location)
            }
        }

        // In track-up mode, update heading to match course (using cached heading)
        if mapOrientationMode == .trackUp, let course = locationManager.currentCourseDegrees {
            mapState.cameraHeading = course
        }

        // Waypoints passed (ATO) are marked in the GPS pipeline, `LocationManager`. (v6.0.1)

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

    private func handleLayerChange(to newLayer: MapLayerType) {
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

    /// The zoom the map opens at: where it was left, else about 6 NM across.
    private var initialSpan: MKCoordinateSpan {
        let delta = appState.navigationMapState.latitudeDelta ?? 0.1
        return MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta)
    }

    private var initialCameraDistance: Double {
        appState.navigationMapState.cameraDistance ?? 10000
    }

    // MARK: - Hazards

    /// Hazards with distance recomputed against LIVE position and the planned route, ranked.
    ///
    /// The proxy's own figure is measured to the nearest polygon vertex and frozen at fetch time,
    /// so it drifts as the aircraft moves and overstates distance for long thin areas. With the
    /// polygon in hand the app recomputes properly — nearest EDGE, current position — and also
    /// tests the planned route, so a hazard sitting over the destination ranks above a closer one
    /// that will never be reached.
    private var rankedSigmets: [SigmetHazardItem] {
        guard let aircraft = locationManager.getCurrentCoordinate() else {
            return aviationWeatherService.sigmets.map { SigmetHazardItem(sigmet: $0, assessment: nil) }
        }
        let route = flightPlanManager.activeFlightPlan?.waypoints.map(\.coordinate) ?? []
        return aviationWeatherService.sigmets
            .map { SigmetHazardItem(
                sigmet: $0,
                assessment: SigmetRelevance.assess(polygon: $0.ring, aircraft: aircraft, route: route)
            ) }
            .sorted {
                let l = $0.assessment, r = $1.assessment
                if l?.severityRank != r?.severityRank {
                    return (l?.severityRank ?? 9) < (r?.severityRank ?? 9)
                }
                return (l?.distanceNm ?? $0.sigmet.distanceNm) < (r?.distanceNm ?? $1.sigmet.distanceNm)
            }
    }

    private func refreshHazards() async {
        guard let coordinate = locationManager.getCurrentCoordinate() else { return }
        await aviationWeatherService.refresh(near: coordinate)
    }

    // MARK: - Standard Layout (iPad and iPhone without active flight plan)

    /// Width of the landscape side column: the kneeboard leg table's narrowest row, with its padding.
    /// The map keeps 760 pt, enough for the next-waypoint card and the controls row. (review #1, R-01)
    private static let sideColumnWidth: CGFloat = 420

    /// The landscape legs panel's height, at most: the chart's lower half, less the aircraft's half
    /// symbol and a margin. The map centres the aircraft when it follows it, so the aircraft, the next
    /// waypoint and the map's controls stay in view with the panel open; past that it scrolls. (6.1)
    static func landscapeLegsMaxHeight(mapHeight: CGFloat) -> CGFloat {
        max(0, mapHeight / 2 - 36)
    }

    private func standardLayoutBody(geometry: GeometryProxy) -> some View {
        // Landscape: the map takes the full height and the frequencies, legs and thumb controls move
        // to a column on the right. A 104 pt bar across a 820 pt-tall screen left the map a letterbox.
        // (on-device review #1, R-01)
        //
        // Landscape only when clearly wider than tall. The Cockpit's map pane on an iPad in portrait is
        // nearly square (about 820 x 870 pt in the phases that show the instrument strip), so a plain
        // width > height flipped it to the side column as soon as anything above it grew a few points,
        // and only in those phases: the phase bar's taller touch area did exactly that. A real
        // landscape pane is 1.5 to 2.5 times wider than tall. (v6.0 review, fixed layout)
        let landscape = geometry.size.width > geometry.size.height * 1.2
        let columns = landscape && leadingColumn != nil
        let mapAreaWidth = columns ? geometry.size.width - leadingColumnWidth
            : landscape ? geometry.size.width - Self.sideColumnWidth : geometry.size.width
        // The closures below run later, in their own view's update: read the proxy here, while it
        // is current.
        let height = geometry.size.height
        // Each large part of the map is a view of its own (`SeparateView`): built inline, this body's
        // value was about 33 KB, and rendering it overflowed the device's 1 MB main-thread stack.
        return Group {
            if columns, let leadingColumn {
                // A phone on its side, in the Cockpit: the Cockpit's column on the left with the thumb
                // bar at its foot, the map beside it at full height, the frequencies along its bottom.
                // (iPhone pass, I7)
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        leadingColumn
                        Spacer(minLength: 0)
                        // 6 pt under the strip: the column is to fit a 6.1" phone's 369 pt over the home
                        // indicator, the thumb row whole. (6.1, device check)
                        navThumbColumnCompact
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                            .padding(.bottom, 12)
                    }
                    .frame(width: leadingColumnWidth)
                    .background(theme.panel.ignoresSafeArea())
                    .overlay(alignment: .trailing) { Rectangle().fill(theme.panelStroke).frame(width: 1) }

                    SeparateView { columnsMapArea(legsMaxHeight: height * 0.5) }
                }
            } else if landscape {
                // The legs and every frequency open over the chart's foot, beside the column, rather than
                // in it: in the column they had the room its controls left, a strip that showed a row and
                // a half. (6.1, device check) The map's footer rides above them, the undo toast with it.
                let legsMaxHeight = Self.landscapeLegsMaxHeight(mapHeight: height)
                HStack(spacing: 0) {
                    SeparateView {
                        mapArea(bottomPanel: EmptyView?.none,
                                footerClearance: navSheetExpanded ? legsPanelHeight(maxHeight: legsMaxHeight) : 0)
                    }
                    .overlay(alignment: .bottom) {
                        if navSheetExpanded {
                            SeparateView { landscapeLegsPanel(maxHeight: legsMaxHeight) }
                                .transition(.move(edge: .bottom))
                        }
                    }
                    SeparateView { sideColumn }
                        .frame(width: Self.sideColumnWidth)
                }
            } else {
                // The legs and every frequency open inside the bottom panel, never taller than 40 %
                // of the map: past that they scroll, and the thumb bar stays on screen. (M-06)
                SeparateView {
                    mapArea(bottomPanel: SeparateView { bottomPanel(legsMaxHeight: height * 0.4) })
                }
            }
        }
        // Declared once here, so both layouts have them.
        .sheet(isPresented: $showSigmets) {
            SigmetSheet(hazards: rankedSigmets)
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
        .fullScreenCover(isPresented: $showFlightPlanning) {
            FlightPlanningView()
                .environment(appState)
                .environmentObject(flightPlanManager)
                .environmentObject(airportDataService)
                .environmentObject(aircraftDataService)
                .environmentObject(openAIPDataService)
                .environmentObject(locationManager)
        }
        .fullScreenCover(isPresented: $showGPSStatusModal) {
            GPSStatusInfoSheet(currentStatus: locationManager.gpsSignalStatus, isPresented: $showGPSStatusModal)
        }
        .task {
            // The fetch belongs HERE, next to the only consumer. It previously lived only in
            // FlightView, so opening Navigation from Home — with no active flight — showed no chip
            // at all, because nothing had ever fetched. Self-throttled to the proxy's 5-minute
            // window, so appearing repeatedly costs nothing.
            await refreshHazards()
        }
        .onAppear { mapWidth = mapAreaWidth }
        .onChange(of: mapAreaWidth) { _, width in mapWidth = width }
    }

    /// The landscape phone's map, beside the Cockpit's column: as much chart as the height allows. The
    /// next waypoint on one line, the controls in a short column on the right edge, the frequencies on
    /// two lines at the bottom, and over the chart only the chips that come and go. The card, a row of
    /// controls, the pane bar and the tall frequency bar left the map about a third of its column.
    /// (iPhone pass, I7)
    private func columnsMapArea(legsMaxHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            chartWithChrome(top: VStack(spacing: 8) {
                nextWaypointLine
                SeparateView { occasionalChips(pillLeading: true) }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8),
            bottom: VStack(spacing: 8) {
                MapUndoToast(undoOffer: $undoOffer)
                    .padding(.horizontal, 16)
                // The controls at the foot of the chart, by the thumb, leaving the top (what's
                // ahead, in Track up) clear, and the scale and the chart's source beside them. Not with
                // the legs open: the band is a view. (6.1, option C)
                if chrome.showsMapControls || chrome.showsMapStatus {
                    SeparateView { columnsMapFoot }
                        .padding(.horizontal, 10)
                }
            }
            .padding(.bottom, 8)
            .sheet(isPresented: $showCacheInfoModal) { cacheInfoSheet })

            // The frequencies, and the legs when opened, under the chart rather than over it.
            VStack(spacing: 0) {
                freqLine
                if navSheetExpanded {
                    Rectangle().fill(theme.panelStroke).frame(height: 1)
                    SeparateView { legsPanelContent(maxHeight: legsMaxHeight) }
                }
            }
            .background(theme.panel.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Rectangle().fill(theme.panelStroke).frame(height: 1) }
        }
    }

    /// The next waypoint on one line: the ident in magenta, then bearing, distance and time. Tap for
    /// every leg and frequency. A diversion shows its tag and the way back to the route.
    @ViewBuilder
    private var nextWaypointLine: some View {
        if let plan = flightPlanManager.activeFlightPlan, !flightPlanManager.isFlightPlanCompleted,
           plan.nextWaypoint != nil, let ident = plan.nextWaypointName(.phoneNextLine) {
            let diversion = plan.diversion
            HStack(spacing: 12) {
                Button(action: toggleLegsAndFrequencies) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if diversion != nil {
                            Text(L10n.Trip.divertTag)
                                .font(.aero(size: CockpitType.label, weight: .bold))
                                .foregroundColor(theme.actionText)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(theme.warning, in: RoundedRectangle(cornerRadius: 6))
                        } else {
                            Image(systemName: "arrow.right")
                                .font(.aero(size: CockpitType.label, weight: .bold))
                                .foregroundColor(theme.route)
                        }
                        Text(ident)
                            .font(.aero(size: CockpitType.response, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.route)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Spacer(minLength: 6)
                        // One length whatever the figures: each in a field as wide as its widest, "—"
                        // while there is none, so they hold still and the ident keeps its size. (6.1)
                        Text(NextWaypointReadout.phoneLine(bearing: liveBearingText,
                                                           distance: nextWaypointDistanceValue,
                                                           ete: nextLegLive?.ete))
                            .font(.aero(size: CockpitType.label, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(L10n.Nav.legsAndFrequencies)
                if diversion != nil {
                    Button { flightPlanManager.resumeRoute() } label: {
                        Text(L10n.Trip.resumeRoute)
                            .font(.aero(size: CockpitType.label, weight: .bold))
                            .foregroundColor(theme.action)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 44)
                            .overlay(Capsule().strokeBorder(theme.action, lineWidth: 1.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.panelStroke, lineWidth: 1))
        }
    }

    /// Map, the orientation and Centre in a row at the foot of the chart: labelled when they fit, icons
    /// with their names for VoiceOver when they don't (French runs longer). Zoom is a pinch.
    private var mapControlsBottomRow: some View {
        ViewThatFits(in: .horizontal) {
            mapControlsLabelled
            mapControlsIcons
        }
        .sheet(isPresented: $showMapSheet) { mapSheet }
    }

    /// The landscape phone's foot of the chart: the chart's source and the scale bar at the left of
    /// the controls, in their band. Stacked over the controls, they reached the middle of a chart about
    /// 340 pt tall, by the aircraft. The controls keep their labels where all fits (a Pro Max), else go
    /// to their icons, the fallback French already took; on a phone too narrow even for that (an iPhone
    /// SE), the source and the scale go back over the controls. The portrait phone and the iPad keep
    /// theirs over the chart's bottom left corner: there it is a corner. (6.1, device check)
    private var columnsMapFoot: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 0) {
                columnsMapStatus
                Spacer(minLength: 8)
                mapControlsLabelled
            }
            HStack(alignment: .bottom, spacing: 0) {
                columnsMapStatus
                Spacer(minLength: 8)
                mapControlsIcons
            }
            VStack(alignment: .leading, spacing: 8) {
                columnsMapStatus
                mapControlsIcons
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .sheet(isPresented: $showMapSheet) { mapSheet }
    }

    /// The source and the scale in the landscape phone's band, as wide whatever the zoom: the scale bar
    /// runs 60 to 100 pt, and a band that changed its mind with every pinch would move the controls.
    private var columnsMapStatus: some View {
        mapStatus
            .frame(minWidth: 100, alignment: .bottomLeading)
            .fixedSize()
    }

    private var mapControlsLabelled: some View {
        HStack(spacing: 8) {
            mapSheetButton(labelled: true)
            orientationButton
            chromeButton(icon: isFollowingAircraft ? "location.fill" : "location",
                         title: L10n.Nav.centre, prominent: !isFollowingAircraft) { centerOnAircraft() }
        }
    }

    private var mapControlsIcons: some View {
        HStack(spacing: 8) {
            mapSheetButton(labelled: false)
            chromeIconButton(icon: mapOrientationMode == .northUp ? "location.north.line" : "location.north.line.fill",
                             label: mapOrientationMode == .northUp ? L10n.Nav.northUp : L10n.Nav.trackUp) {
                toggleOrientation()
            }
            chromeIconButton(icon: isFollowingAircraft ? "location.fill" : "location", label: L10n.Nav.centre,
                             prominent: !isFollowingAircraft) { centerOnAircraft() }
        }
    }

    private var mapSheet: some View {
        MapSheet(selectedLayer: $selectedLayer, isOfflineMode: isOfflineMode, mapCenter: mapState.region.center)
            .environment(appState)
            .environment(\.cockpitTheme, theme)
            .environmentObject(openAIPDataService)
            .environmentObject(dataStatusManager)
            .environmentObject(offlineMapManager)
    }

    /// Map, with the stale-airspace cue on it.
    private func mapSheetButton(labelled: Bool) -> some View {
        Group {
            if labelled {
                chromeButton(icon: "square.stack.3d.up", title: L10n.Nav.mapSheet) { showMapSheet = true }
            } else {
                chromeIconButton(icon: "square.stack.3d.up", label: L10n.Nav.mapSheet) { showMapSheet = true }
            }
        }
        .overlay(alignment: .topTrailing) {
            if airspaceDataNeedsAttention {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.aero(size: 14, weight: .bold))
                    .foregroundColor(theme.warning)
                    .padding(4)
                    .background(theme.panel, in: Circle())
                    .offset(x: 8, y: -8)
                    .accessibilityLabel(Text("Airspace data is out of date"))
            }
        }
    }

    /// A control as a square icon, its name kept for VoiceOver.
    private func chromeIconButton(icon: String, label: String, prominent: Bool = false,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.aero(size: CockpitType.label, weight: .semibold))
                .foregroundColor(prominent ? theme.actionText : theme.action)
                .frame(width: CockpitTarget.control, height: CockpitTarget.control)
                .background(RoundedRectangle(cornerRadius: 14).fill(prominent ? theme.action : theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(prominent ? Color.clear : theme.panelStroke, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// NOW and NEXT on two lines: the station over the frequency. The landscape phone's version of
    /// `freqCard`, about 20 pt shorter.
    private var freqLine: some View {
        let current = phaseFreqItems.first { $0.role == .current }
        let next = phaseFreqItems.first { $0.role == .next }
        return Button(action: toggleLegsAndFrequencies) {
            HStack(spacing: 10) {
                freqLineCell(tag: L10n.Nav.freqCurrent, tint: theme.onTarget, item: current)
                Rectangle().fill(theme.panelStroke).frame(width: 1, height: 36)
                freqLineCell(tag: L10n.Nav.freqNext, tint: theme.info, item: next)
                Image(systemName: navSheetExpanded ? "chevron.down" : "chevron.up")
                    .font(.aero(size: CockpitType.label, weight: .bold))
                    .foregroundColor(theme.action)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(theme.action.opacity(0.14)))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A hint, not a label: a label replaced the station and frequency, so VoiceOver never read the
        // NOW and NEXT frequencies at all. (v6.0 review)
        .accessibilityHint(L10n.Nav.legsAndFrequencies)
    }

    private func freqLineCell(tag: String, tint: Color, item: PhaseFrequency?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(tag)
                    .font(.aero(size: 13, weight: .bold))
                    .foregroundColor(tint)
                Text(item?.station ?? "—")
                    .font(.aero(size: 13))
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
            }
            FrequencyLineText(text: item?.freq ?? "—",
                              font: .aero(size: CockpitType.label, weight: .bold, design: .monospaced),
                              color: theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The map with its chrome: the top bar (full-screen only), the next-waypoint card and the map's
    /// controls on top, the scale bar and the undo toast at the bottom, and — in portrait — the
    /// bottom panel. `footerClearance`: room kept under the scale bar and the undo toast, for the
    /// landscape legs panel laid over the chart's foot.
    private func mapArea<Panel: View>(bottomPanel: Panel?, footerClearance: CGFloat = 0) -> some View {
        // The phone: the next waypoint on one line and the controls at the foot of the chart, as on
        // its side. With the card and a row of controls on top, a phone in cruise had about 150 pt
        // of chart left, the aircraft under the controls. (round 6, I-06)
        let compact = CockpitScale.current == .phone
        return VStack(spacing: 0) {
            chartWithChrome(top: VStack(spacing: 0) {
                if !isInCockpit {
                    topBar
                        .padding(.horizontal)
                        .padding(.top)
                }

                // What a pilot reads most, big and on top: the next waypoint. Then the map's own
                // controls, labelled. (v6.0 · P3) What comes and goes sits under them, so it never
                // moves them. (6.1)
                VStack(spacing: compact ? 8 : 10) {
                    if compact {
                        nextWaypointLine
                    } else {
                        SeparateView { nextWaypointCard }
                    }
                    if routesOnTop {
                        routesButton()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Not with the legs open: the band under the card is a view. (6.1, option C)
                    if !compact && chrome.showsMapControls {
                        SeparateView { mapControlsRow }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    SeparateView { occasionalChips(pillLeading: false) }
                }
                .padding(.horizontal, compact ? 10 : 16)
                .padding(.top, compact ? 8 : 10)
            },
            bottom: VStack(spacing: 8) {
                mapFooter
                if compact && chrome.showsMapControls {
                    SeparateView { mapControlsBottomRow }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 10)
                }
            }
            .padding(.bottom, (compact ? 8 : 0) + footerClearance),
            panelInset: footerClearance)

            if let bottomPanel { bottomPanel }
        }
    }

    /// The chart, its chrome laid over it: over, not stacked, so the chrome never makes the pane taller
    /// than its room. Stacked, the card, the controls and the route pill pushed the thumb bar half off
    /// a phone in climb. (round 6, I-06)
    ///
    /// With the legs and frequencies open, the chart left between the top chrome and the panel is the
    /// band (`legsBand`): measured here, in the chart's own space, as the map view runs under a safe
    /// area where the chart doesn't. `panelInset`: how much of the chart's foot the panel lies over (in
    /// landscape; elsewhere it is under the chart). (6.1, option C)
    private func chartWithChrome<Top: View, Bottom: View>(top: Top, bottom: Bottom,
                                                         panelInset: CGFloat = 0) -> some View {
        Color.clear
            // Under the chrome, so the card and the undo stay live.
            .overlay { if chrome.bandClosesPanel { legsBandCover } }
            .overlay(alignment: .top) {
                top.background(GeometryReader { proxy in
                    Color.clear.preference(key: ChartChromeBottomKey.self,
                                           value: proxy.frame(in: .named(Self.chartSpace)).maxY)
                })
            }
            .overlay(alignment: .bottom) { bottom }
            .clipped()
            .background {
                mapContent.ignoresSafeArea()
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ChartMapFrameKey.self,
                                               value: proxy.frame(in: .named(Self.chartSpace)))
                    })
            }
            .background(GeometryReader { proxy in
                Color.clear
                    .preference(key: ChartSizeKey.self, value: proxy.size)
                    .preference(key: ChartPanelInsetKey.self, value: panelInset)
                    .preference(key: ChartMeasuredOpenKey.self, value: chrome.bandClosesPanel)
            })
            .coordinateSpace(name: Self.chartSpace)
            .onPreferenceChange(ChartSizeKey.self) { chartGeometry.chartSize = $0 }
            .onPreferenceChange(ChartChromeBottomKey.self) { chartGeometry.chromeBottom = $0 }
            .onPreferenceChange(ChartMapFrameKey.self) { chartGeometry.mapFrame = $0 }
            .onPreferenceChange(ChartPanelInsetKey.self) { chartGeometry.panelInset = $0 }
            .onPreferenceChange(ChartMeasuredOpenKey.self) { chartGeometry.measuredOpen = $0 }
    }

    private static let chartSpace = "navChart"

    /// What comes and goes over the chart, under the next waypoint and the map's controls: the Cockpit's
    /// chips (BRIEFING, the deferred count; on the phone) and the SIGMET chip (only with a hazard in
    /// range: a chip always there stops being read) on one row, then the off-screen route's pill. None of
    /// them moves another. The chips keep the row's left and the SIGMET chip its right, so either comes
    /// without moving the other (on the iPad, which has no chips, the SIGMET chip keeps the left); and
    /// while the pill shows, the row above it keeps its full height, empty or not. The chips used to sit
    /// over the next waypoint and push it down 54 pt on the phone, and a SIGMET after a data refresh moved
    /// the pill down 38 pt. (6.1, stability)
    ///
    /// Laid out by the caller's stack, one view each. `pillLeading`: the pill at the left edge rather
    /// than in the middle.
    @ViewBuilder
    private func occasionalChips(pillLeading: Bool) -> some View {
        let sigmets = rankedSigmets
        let showsPill = chrome.showsRouteOffScreenPill && routeOffScreenHint != nil
        // The phone's Cockpit is where the chips come; elsewhere, once they have come.
        let sharesRow = (CockpitScale.current == .phone && onShowChecklist != nil) || mapAccessoryHeight != nil
        let chipsHeight = sharesRow ? (mapAccessoryHeight ?? Self.cockpitChipsHeight) : 0
        if mapTopAccessory != nil || !sigmets.isEmpty || showsPill {
            HStack(alignment: .top, spacing: 8) {
                if let mapTopAccessory {
                    mapTopAccessory
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: MapAccessoryHeightKey.self, value: proxy.size.height)
                        })
                }
                if sharesRow { Spacer(minLength: 0) }
                ZStack(alignment: .topLeading) {
                    if showsPill {
                        // The chip's own height, kept for the pill under it.
                        SigmetChip(hazards: Self.sigmetChipMeasure) {}
                            .hidden()
                            .accessibilityHidden(true)
                    }
                    SigmetChip(hazards: sigmets) { showSigmets = true }
                }
                if !sharesRow { Spacer(minLength: 0) }
            }
            .frame(minHeight: showsPill ? chipsHeight : 0, alignment: .top)
            .onPreferenceChange(MapAccessoryHeightKey.self) { height in
                if height > 0 { mapAccessoryHeight = height }
            }
        }
        if chrome.showsRouteOffScreenPill {
            routeOffScreenPill(leading: pillLeading)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: routeOffScreenHint) // (UX-18)
        }
    }

    /// The Cockpit's chips over the chart before they have been measured: a chip (`CockpitChip`) in the
    /// 6 pt panel the Cockpit puts them on.
    private static var cockpitChipsHeight: CGFloat { CockpitType.size(kneeboard: 52, phone: 46) + 12 }

    /// A hazard to measure the SIGMET chip by, never shown.
    private static let sigmetChipMeasure = [SigmetHazardItem(
        sigmet: AviationWeatherService.Sigmet(firId: nil, firName: nil, hazard: "TS", qualifier: nil, baseFt: nil,
                                              topFt: nil, validFrom: nil, validTo: nil, distanceNm: 0,
                                              containsPoint: false, coords: [], raw: nil),
        assessment: nil)]

    /// The band, with the legs open: a tap on it closes the panel as the chevron does, and the map
    /// under it takes no pan, pinch, rotation or marker tap. VoiceOver gets the same as a named action
    /// (the map hides its markers from VoiceOver meanwhile). (6.1, option C)
    private var legsBandCover: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { toggleLegsAndFrequencies() }
            .accessibilityElement()
            .accessibilityLabel(L10n.Nav.mapSheet)
            .accessibilityAction(named: L10n.Nav.closeLegsAndFrequencies) { toggleLegsAndFrequencies() }
    }

    /// The map's chrome for the panel's state: with the legs open, the map's controls go and the band is
    /// a view. (6.1, option C)
    private var chrome: LegsPanelMap.Chrome { .forPanel(open: navSheetExpanded) }

    /// The band the open legs panel leaves, as the map views take it; nil with the panel closed. It
    /// frames the waypoint previewed from the leg table while there is one, else the navigation target
    /// (the next waypoint, or the diversion field).
    private var legsBand: LegsPanelMap.Band? {
        guard navSheetExpanded else { return nil }
        let geometry = chartGeometry
        var waypoint: CLLocationCoordinate2D?
        if let plan = flightPlanManager.activeFlightPlan, !flightPlanManager.isFlightPlanCompleted {
            if let index = previewWaypointIndex, plan.waypoints.indices.contains(index) {
                waypoint = plan.waypoints[index].coordinate
            } else {
                waypoint = plan.navigationTarget?.coordinate
            }
        }
        return LegsPanelMap.Band(
            rect: geometry.measuredOpen
                ? LegsPanelMap.bandRect(chartSize: geometry.chartSize, chromeBottom: geometry.chromeBottom,
                                        mapFrame: geometry.mapFrame, panelInset: geometry.panelInset)
                : nil,
            viewSize: geometry.mapFrame.size,
            aircraft: locationManager.currentLocation?.coordinate,
            waypoint: waypoint,
            heading: mapOrientationMode == .trackUp
                ? (locationManager.currentCourseDegrees ?? mapState.cameraHeading) : 0)
    }

    /// The panel opened: keep the map as it is, to put it back on closing, and show the leg being flown.
    private func legsPanelOpened() {
        legsRevealPending = true
        cameraBeforeLegs = LegsPanelMap.SavedCamera(
            center: mapState.region.center, span: mapState.region.span, distance: mapState.cameraDistance,
            heading: mapState.cameraHeading, following: isFollowingAircraft)
    }

    /// The panel closed: the map as it was (following the aircraft, or where the pilot had panned to).
    /// The shared state gets it here; the map view puts its camera there once the panel is gone.
    private func legsPanelClosed() {
        previewWaypointIndex = nil
        guard let saved = cameraBeforeLegs else { return }
        cameraBeforeLegs = nil
        let camera = LegsPanelMap.restored(
            saved, aircraft: locationManager.currentLocation?.coordinate,
            trackUpCourse: mapOrientationMode == .trackUp ? locationManager.currentCourseDegrees : nil)
        mapState.region = MKCoordinateRegion(center: camera.center, span: camera.span)
        mapState.cameraDistance = camera.distance
        mapState.cameraHeading = camera.heading
        isFollowingAircraft = camera.following
    }

    /// The phone with no leg to fly, so the thumb bar would only hold Routes: no route on the map, or
    /// no flight running (Plan › Map on the ground, where the bar is the way to the routes since the
    /// leg controls went in-flight-only). In flight, the way to a route sits where the next waypoint
    /// would be, rather than alone on a bar of its own at the foot of the screen; in Plan › Map there
    /// is none, as the picker above has Routes. (round 6, I-06)
    private var phoneWithNoLegToFly: Bool {
        CockpitScale.current == .phone
            && (flightPlanManager.activeFlightPlan == nil || !appState.isFlightActive)
            // In the Cockpit's flight the foot has the check slot, and Routes joins it there. (6.1)
            && !showsCheckSlot
    }

    /// The Cockpit's map in flight: the check slot leads the bottom row, in the same place in every
    /// phase. (6.1, check slot)
    private var showsCheckSlot: Bool { appState.isFlightActive && onShowChecklist != nil }

    /// Approach and landing: GO AROUND and TOUCH-AND-GO after the slot, as on the checklist pane, in
    /// place of the route's buttons (the destination is marked by the landing). (6.1, mockup M3) From
    /// circuit height too, where the slot shows the landing check: the proposal's "circuit / final".
    /// The slot doesn't move for them (`MapThumbRow`).
    private var showsEventButtons: Bool {
        showsCheckSlot && (appState.currentPhase == .approach || appState.currentPhase == .landing
                           || appState.landingCheckShown)
    }

    private var routesOnTop: Bool { phoneWithNoLegToFly && onShowRoutes == nil }

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
    /// The traffic circuits, VFR routes and sectors drawn for the region. (6.2.0)
    @State private var vfrContent: VFRMapContent = .empty()
    @State private var lastSpatialRegion: MKCoordinateRegion?

    /// What redraws the aerodrome procedures besides the region. (6.2.0)
    private var vfrLayerKey: VFRLayerFollower.Key {
        VFRLayerFollower.Key(selection: VFRLayerSelection(settings: appState.settings),
                             revision: vfrProcedureService.revision, palette: VFRMapPalette(theme: theme),
                             firstAerodromes: VFRMapDensity.endpointAerodromes(of: flightPlanManager.activeFlightPlan))
    }

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
        let region = mapState.bandRegion ?? mapState.region
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

        recomputeVFRContent(region: region)
    }

    /// The aerodrome procedures for `region`: nothing past 40 NM across, labels within 20 NM, at most 80,
    /// the flight's destination and departure first (`VFRMapContent.make`). (6.2.0)
    private func recomputeVFRContent(region: MKCoordinateRegion) {
        let palette = VFRMapPalette(theme: theme)
        let selection = VFRLayerSelection(settings: appState.settings)
        let service = OFMDataService.shared
        guard selection.isAnyOn, service.isLoaded, VFRMapDensity.showsProcedures(in: region) else {
            vfrContent = .empty(palette)
            return
        }
        vfrContent = VFRMapContent.make(
            candidates: service.procedures(in: region), region: region, selection: selection, palette: palette,
            firstAerodromes: VFRMapDensity.endpointAerodromes(of: flightPlanManager.activeFlightPlan),
            fieldPosition: { airportDataService.findAirport(byIdent: $0)?.coordinate },
            cycle: { (service.cycles[$0]?.airac, service.region(forCountry: $0)) })
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
                vfrContent: vfrContent,
                onWaypointATOTap: { index in
                    flightPlanManager.recordATO(forWaypointAt: index)
                },
                onAirportDivert: airportDivert,
                legsBand: legsBand
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
                vfrContent: vfrContent,
                onWaypointATOTap: { index in
                    flightPlanManager.recordATO(forWaypointAt: index)
                },
                onAirportDivert: airportDivert,
                legsBand: legsBand
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
            if showsCloseButton {
                Button(action: { isPresented = false }) {
                    Image(systemName: "chevron.down")
                        .font(.aero(size: 16, weight: .bold))
                        .foregroundColor(theme.textPrimary)
                        .frame(width: 44, height: 44)
                        .background(theme.panel.opacity(0.92), in: Circle())
                }
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
                                     font: .aero(size: 14, weight: .medium, design: .monospaced),
                                     color: theme.textPrimary)

                        // Speed, Altitude, Heading on second row
                        HStack(spacing: 10) {
                            // Speed (color-coded based on target)
                            HStack(spacing: 2) {
                                Text("\(Int(locationManager.currentSpeedKnots))")
                                    .font(.aero(size: 16, weight: .bold, design: .monospaced))
                                Text("kt")
                                    .font(.aero(size: 10, weight: .medium))
                            }
                            .foregroundColor(speedColor)

                            // Altitude
                            HStack(spacing: 2) {
                                Text("\(Int(locationManager.currentAltitudeFeet))")
                                    .font(.aero(size: 16, weight: .bold, design: .monospaced))
                                Text("ft")
                                    .font(.aero(size: 10, weight: .medium))
                            }
                            .foregroundColor(theme.textPrimary)   // data is white (v6.0 · P5)

                            // Heading
                            HStack(spacing: 2) {
                                Text(String(format: "%03d", currentHeading))
                                    .font(.aero(size: 16, weight: .bold, design: .monospaced))
                                Text("°")
                                    .font(.aero(size: 10, weight: .medium))
                            }
                            .foregroundColor(theme.textPrimary)   // data is white (v6.0 · P5)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)

                    // "Next Check" integrated in info box
                    if appState.isFlightActive {
                        Rectangle()
                            .fill(theme.textDim.opacity(0.3))
                            .frame(height: 0.5)

                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle")
                                .font(.aero(size: 10))
                            Text(appState.currentPhase.title)
                                .font(.aero(size: 11, weight: .medium))
                        }
                        .foregroundColor(theme.action)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                }
                .background(theme.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
            } else {
                // Horizontal layout for iPad
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        // Current time
                        NavClockText(useUTC: appState.settings.alwaysUseUTC,
                                     font: .aero(size: 16, weight: .medium, design: .monospaced),
                                     color: theme.textPrimary)

                        // Divider
                        Rectangle()
                            .fill(theme.textDim)
                            .frame(width: 1, height: 20)

                        // Speed (color-coded based on target)
                        HStack(spacing: 4) {
                            Text("\(Int(locationManager.currentSpeedKnots))")
                                .font(.aero(size: 18, weight: .bold, design: .monospaced))
                            Text("kt")
                                .font(.aero(size: 12, weight: .medium))
                        }
                        .foregroundColor(speedColor)

                        // Altitude
                        HStack(spacing: 4) {
                            Text("\(Int(locationManager.currentAltitudeFeet))")
                                .font(.aero(size: 18, weight: .bold, design: .monospaced))
                            Text("ft")
                                .font(.aero(size: 12, weight: .medium))
                        }
                        .foregroundColor(theme.textPrimary)   // data is white (v6.0 · P5)

                        // Heading
                        HStack(spacing: 4) {
                            Text(String(format: "%03d", currentHeading))
                                .font(.aero(size: 18, weight: .bold, design: .monospaced))
                            Text("°")
                                .font(.aero(size: 12, weight: .medium))
                        }
                        .foregroundColor(theme.textPrimary)   // data is white (v6.0 · P5)

                        // Current phase, inline. When FREDA is due it becomes a tappable amber ⟳ FREDA
                        // badge (tap: FREDA done); otherwise a plain gold phase label — a disabled
                        // Button was dimming the text. (v4 UI/UX Revamp — re-cruise; FREDA 6.1)
                        if appState.isFlightActive {
                            Rectangle().fill(theme.textDim).frame(width: 1, height: 20)
                            if appState.fredaDue {
                                Button(action: { appState.confirmFreda() }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .font(.aero(size: 11, weight: .bold))
                                        Text(verbatim: "FREDA")
                                            .font(.aero(size: 13, weight: .semibold))
                                            .lineLimit(1)
                                    }
                                    .foregroundColor(theme.warning)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Text(appState.currentPhase.title)
                                    .font(.aero(size: 13, weight: .semibold))
                                    .foregroundColor(theme.action)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .fixedSize(horizontal: true, vertical: false)
                .background(theme.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
            }

            Spacer()

            // The map's own controls (base chart, overlays, orientation, zoom) moved to the labelled
            // row under the next-waypoint card. The GPS status came up from the bottom bar, which is
            // the thumb bar now. (v6.0 · P3)
            Button(action: { showGPSStatusModal = true }) {
                HStack(spacing: 8) {
                    StatusIndicator(gpsStatusIndicator, size: 10)
                    Text("GPS")
                        .font(.aero(size: CockpitType.label, weight: .semibold))
                        .foregroundColor(theme.textPrimary)
                }
                .padding(.horizontal, 14)
                .frame(minWidth: 44, minHeight: 44)
                .background(theme.panel, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.GPS.status)
        }
    }

    // MARK: - Bottom Controls

    /// The scale bar and the offline/cache badge, bottom left over the map, and the undo toast over
    /// them. (The landscape phone has them in the controls' band instead: `columnsMapFoot`.)
    ///
    /// The toast lies over the corner rather than under it: stacked, its six seconds after every MARK
    /// and every waypoint the flight marked lifted the scale and the badge, a button, by 100 pt. Now
    /// nothing moves; the scale and the badge are under the toast meanwhile. (6.1, stability)
    private var mapFooter: some View {
        ZStack(alignment: .bottom) {
            // Not with the legs open: the band is a view, the undo stays. (6.1, option C)
            if chrome.showsMapStatus {
                HStack(alignment: .bottom) {
                    mapStatus
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }

            MapUndoToast(undoOffer: $undoOffer)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $showCacheInfoModal) { cacheInfoSheet }
    }

    /// The offline/cache badge over the scale bar. A tap on the badge says where the chart comes from.
    private var mapStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isOfflineMode || isCachedMode {
                Button(action: { showCacheInfoModal = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "internaldrive.fill")
                        Text(isOfflineMode ? L10n.Nav.offline : L10n.Nav.cached)
                    }
                    .font(.aero(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isOfflineMode ? theme.danger.opacity(0.9) : theme.action.opacity(0.9))
                    )
                }
            }
            SwissScaleBar(region: mapState.region, mapWidth: mapWidth, nauticalMiles: appState.settings.distanceInNauticalMiles)
                // Never in a tap's way: on a phone's short chart the route's pill can reach it. (6.1)
                .allowsHitTesting(false)
        }
    }

    private var cacheInfoSheet: some View {
        CacheInfoSheet(isOfflineMode: isOfflineMode)
            .environment(appState)
            .environmentObject(offlineMapManager)
    }

    /// Portrait: opaque, pinned to the bottom edge — the frequencies to hand, the legs and every
    /// frequency when opened (at most `legsMaxHeight`, scrolling past it), and the thumb bar. No chart
    /// ink behind the numbers. (v6.0 · P3, C6; on-device review #1, M-06)
    private func bottomPanel(legsMaxHeight: CGFloat, includesThumbBar: Bool = true) -> some View {
        VStack(spacing: 0) {
            freqCard
            if navSheetExpanded {
                Rectangle().fill(theme.panelStroke).frame(height: 1)
                SeparateView { legsPanelContent(maxHeight: legsMaxHeight) }
            }
            if includesThumbBar && !phoneWithNoLegToFly {
                Rectangle().fill(theme.panelStroke).frame(height: 1)
                navThumbBar
            }
        }
        .background(theme.panel.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle().fill(theme.panelStroke).frame(height: 1)
        }
    }

    /// Landscape: the bottom panel's content as a column. NOW and NEXT on top, with the chevron that
    /// opens the legs and every frequency (`landscapeLegsPanel`, over the chart beside the column), and
    /// the thumb controls at the bottom, where the hand rests. (on-device review #1, R-01)
    ///
    /// The column used to keep the legs and frequencies open between the two, in the room the
    /// controls left it: once the check slot took a row of its own, a strip with its title cut and a
    /// row and a half to scroll. (6.1, device check)
    private var sideColumn: some View {
        VStack(spacing: 0) {
            Button(action: toggleLegsAndFrequencies) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        freqCell(tag: L10n.Nav.freqCurrent, tint: theme.onTarget,
                                 item: phaseFreqItems.first { $0.role == .current })
                        freqCell(tag: L10n.Nav.freqNext, tint: theme.info,
                                 item: phaseFreqItems.first { $0.role == .next })
                    }
                    legsChevron
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A hint, not a label, as on the portrait card: VoiceOver still reads NOW and NEXT.
            .accessibilityHint(L10n.Nav.legsAndFrequencies)
            Rectangle().fill(theme.panelStroke).frame(height: 1)
            Spacer(minLength: 0)
            navThumbColumn
                .padding(16)
        }
        .background(theme.panel.ignoresSafeArea(edges: [.bottom, .trailing]))
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.panelStroke).frame(width: 1)
        }
    }

    /// Landscape, opened from the column's NOW / NEXT (or the next-waypoint card, or More): the legs
    /// and every frequency, opaque over the chart's foot, from the column to the left edge. Over the
    /// chart, so nothing in the column moves; at its foot, as the portrait panel opens, so the next
    /// waypoint, the map's controls and the aircraft stay in view (`landscapeLegsMaxHeight`). The same
    /// chevron closes it.
    private func landscapeLegsPanel(maxHeight: CGFloat) -> some View {
        legsPanelContent(maxHeight: maxHeight)
            .background(theme.panel.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Rectangle().fill(theme.panelStroke).frame(height: 1) }
    }

    /// The open panel's content, at most `maxHeight`: the legs and every frequency in a scroll view as
    /// tall as they are, and Emergency pinned under it, outside the scroll, always whole. At the foot of
    /// the list it was half cut in portrait, and about 20 pt short in landscape, until scrolled.
    /// (6.1, option C)
    private func legsPanelContent(maxHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            legsScroll(maxHeight: max(0, maxHeight - emergencyFooterHeight))
            emergencyFooter
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: EmergencyFooterHeightKey.self, value: proxy.size.height)
                })
        }
        .onPreferenceChange(EmergencyFooterHeightKey.self) { emergencyFooterHeight = $0 }
    }

    /// The open panel's height for at most `maxHeight`, Emergency included: what the landscape panel
    /// covers of the chart's foot.
    private func legsPanelHeight(maxHeight: CGFloat) -> CGFloat {
        min(legsPanelContentHeight, max(0, maxHeight - emergencyFooterHeight)) + emergencyFooterHeight
    }

    /// Emergency, at the panel's foot, lined up with the frequency column above it: its right-hand
    /// column beside the legs, the panel's width under them or with no route. A hairline over it, as the
    /// list scrolls under it.
    ///
    /// Placed by the same rule as the column (`LegsPanelColumns`), not by the column's measured frame:
    /// a frequency typed for a waypoint made the column wider than its 300 pt, Emergency took that width,
    /// and the panel, then the whole map pane, came out wider than the screen and moved right. (6.1,
    /// device check)
    @ViewBuilder
    private var emergencyFooter: some View {
        let emergency = phaseFreqItems.filter(\.isEmergency)
        if !emergency.isEmpty {
            LegsPanelColumns(content: .frequencyFoot(hasLegs: flightPlanManager.activeFlightPlan != nil)) {
                VStack(spacing: 0) {
                    Rectangle().fill(theme.panelStroke).frame(height: 1)
                    ForEach(emergency) { freqRow($0, large: true) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
    }

    /// The legs and every frequency in a scroll view as tall as they are, up to `maxHeight`: the panel's
    /// one scroll, nothing inside it scrolls on its own. Opened, it brings the leg being flown into view
    /// when it is below the fold (`LegsPanelReveal`). (6.1, device check)
    private func legsScroll(maxHeight: CGFloat) -> some View {
        ScrollViewReader { reader in
            ScrollView {
                SeparateView { legsAndFrequencies }
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: LegsPanelHeightKey.self, value: proxy.size.height)
                    })
            }
            .frame(height: min(legsPanelContentHeight, maxHeight))
            .onPreferenceChange(LegsPanelHeightKey.self) { height in
                legsPanelContentHeight = height
                // Once the scroll has its height: on the next turn, after the frame above takes it.
                guard legsRevealPending, height > 0 else { return }
                legsRevealPending = false
                DispatchQueue.main.async { revealLegBeingFlown(reader) }
            }
        }
    }

    /// The leg being flown, in the open panel's scroll, scrolling only as far as it needs: not at all
    /// when it is in view.
    private func revealLegBeingFlown(_ reader: ScrollViewProxy) {
        guard let plan = flightPlanManager.activeFlightPlan,
              let row = LegsPanelReveal.row(currentWaypointIndex: plan.currentWaypointIndex,
                                            waypointCount: plan.waypoints.count) else { return }
        reader.scrollTo(LegsPanelReveal.RowID(index: row), anchor: nil)
    }

    /// The chevron of the NOW / NEXT card (portrait) and of the column's NOW / NEXT (landscape): up to
    /// open the legs and every frequency, which rise from the foot of the map in both, down to close.
    private var legsChevron: some View {
        Image(systemName: navSheetExpanded ? "chevron.down" : "chevron.up")
            .font(.aero(size: CockpitType.label, weight: .bold))
            .foregroundColor(theme.action)
            .frame(width: CockpitType.size(kneeboard: 52, phone: 44),
                   height: CockpitType.size(kneeboard: 52, phone: 44))
            .background(Circle().fill(theme.action.opacity(0.14)))
    }

    // MARK: - Kneeboard chrome, iPad (v6.0 · P3)
    //
    // Sized to be read from a thigh, about 55 cm away (see `CockpitType`): the next waypoint in a big
    // card on top, the map's controls labelled beneath it, the frequencies and the thumb bar at the
    // bottom on an opaque panel. The phone uses the same chrome since its pass (I4), with fallbacks
    // where a row runs out of room.

    /// The next waypoint: the ident in magenta (the active route), then bearing, distance, ETE and ETA.
    /// Tap for every leg and frequency. It replaces a 13 pt line in the bottom bar. (review C3)
    @ViewBuilder
    private var nextWaypointCard: some View {
        if let plan = flightPlanManager.activeFlightPlan, !flightPlanManager.isFlightPlanCompleted,
           plan.nextWaypoint != nil, let ident = plan.nextWaypointName(.compact),
           let fullIdent = plan.nextWaypointName(.mapCard) {
            let diversion = plan.diversion
            let filed = diversion != nil && (threadManager.thread(forPlanId: plan.id)?.hasOpenFlightPlan ?? false)
            VStack(alignment: .leading, spacing: 10) {
                Button(action: toggleLegsAndFrequencies) {
                    // One row where it fits; in a narrow window (Slide Over), ETA goes first, then the
                    // ident takes a line above the figures. The phone uses the one-line version.
                    // (iPhone pass, I4; round 6) A short reporting point is "E (LSGC)" only where that
                    // fits beside every figure: the plain "E" comes before any figure gives way. (6.0.1)
                    ViewThatFits(in: .horizontal) {
                        SeparateView {
                            HStack(alignment: .center, spacing: 18) {
                                nextWaypointIdent(fullIdent, diverting: diversion != nil)
                                Spacer(minLength: 8)
                                nextWaypointCells(withETA: true)
                            }
                        }
                        HStack(alignment: .center, spacing: 18) {
                            nextWaypointIdent(ident, diverting: diversion != nil)
                            Spacer(minLength: 8)
                            nextWaypointCells(withETA: true)
                        }
                        HStack(alignment: .center, spacing: 14) {
                            nextWaypointIdent(ident, diverting: diversion != nil)
                            Spacer(minLength: 8)
                            nextWaypointCells(withETA: false)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            nextWaypointIdent(ident, diverting: diversion != nil)
                            HStack(spacing: 14) {
                                nextWaypointCells(withETA: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(L10n.Nav.legsAndFrequencies)

                if let diversion {
                    HStack(spacing: 12) {
                        // Filed: the one thing to say on the radio. Nothing else until the ground.
                        if filed {
                            Text(L10n.Trip.tellFIS(diversion.ident))
                                .font(.aero(size: CockpitType.label))
                                .foregroundColor(theme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button { flightPlanManager.resumeRoute() } label: {
                            Text(L10n.Trip.resumeRoute)
                                .font(.aero(size: CockpitType.label, weight: .bold))
                                .foregroundColor(theme.action)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 52)
                                .overlay(Capsule().strokeBorder(theme.action, lineWidth: 1.5))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16).fill(theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.panelStroke, lineWidth: 1))
        }
    }

    private func nextWaypointIdent(_ ident: String, diverting: Bool) -> some View {
        HStack(spacing: 10) {
            if diverting {
                Text(L10n.Trip.divertTag)
                    .font(.aero(size: CockpitType.label, weight: .bold))
                    .foregroundColor(theme.actionText)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(theme.warning, in: RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "arrow.right")
                    .font(.aero(size: CockpitType.response, weight: .bold))
                    .foregroundColor(theme.route)
            }
            Text(ident)
                .font(.aero(size: CockpitType.item, weight: .bold, design: .monospaced))
                .foregroundColor(theme.route)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }

    /// Each cell as wide as the widest value its format gives (`NavValueCell`), so the card's layout
    /// depends on the waypoint's name only, which changes at a passage, not with every fix.
    @ViewBuilder
    private func nextWaypointCells(withETA: Bool) -> some View {
        let live = nextLegLive
        NavValueCell(label: "BRG", reading: .init(liveBearingText ?? "—"),
                     widest: .init(NextWaypointReadout.widestBearing))
        NavValueCell(label: "DIST", reading: .init(nextWaypointDistanceValue ?? "—", unit: "NM"),
                     widest: .init(NextWaypointReadout.widestDistance, unit: "NM"))
        NavValueCell(label: "ETE",
                     reading: live.map { .init(NextWaypointReadout.eteValue($0.ete), unit: NextWaypointReadout.eteUnit($0.ete)) }
                        ?? .init("—"),
                     widest: NextWaypointReadout.widestMinutes, orWidest: NextWaypointReadout.widestHours)
        if withETA {
            NavValueCell(label: "ETA", reading: .init(live.map { NextWaypointReadout.eta($0.eta) } ?? "—"),
                         widest: .init(NextWaypointReadout.widestETA))
        }
    }

    /// Distance to the next waypoint, without its unit.
    private var nextWaypointDistanceValue: String? {
        guard let loc = locationManager.currentLocation,
              let dist = flightPlanManager.distanceToNextWaypoint(from: loc) else { return nil }
        return NextWaypointReadout.distance(dist)
    }

    /// Time and clock time to the next waypoint at the current ground speed. Nothing below 30 kt:
    /// taxiing at 8 kt, the 12 NM to the first waypoint would read as an hour and a half.
    private var nextLegLive: (ete: TimeInterval, eta: Date)? {
        guard let loc = locationManager.currentLocation else { return nil }
        let gs = locationManager.currentSpeedKnots
        guard gs >= 30, let ete = flightPlanManager.etaToNextWaypoint(from: loc, groundSpeedKnots: gs) else { return nil }
        return (ete, Date().addingTimeInterval(ete))
    }

    private func toggleLegsAndFrequencies() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) { navSheetExpanded.toggle() }
    }

    /// The map's own controls, each with its name: base chart and overlays behind "Map", the
    /// orientation as two words, re-centring on its own, and zoom. They used to be three unlabelled
    /// icons, and the airplane was the base chart. Zoom goes first when the row runs out of room;
    /// pinching still zooms. (review C1, C5)
    private var mapControlsRow: some View {
        // In a narrow window, North up / Track up becomes one button showing the current mode, and
        // zoom goes when even that leaves no room. The phone has the row at the chart's foot.
        // (iPhone pass, I4; round 6)
        ViewThatFits(in: .horizontal) {
            mapControls(withZoom: true)
            mapControls(withZoom: false)
            mapControls(withZoom: true, orientationSegments: false)
            mapControls(withZoom: false, orientationSegments: false)
        }
        .sheet(isPresented: $showMapSheet) {
            MapSheet(selectedLayer: $selectedLayer, isOfflineMode: isOfflineMode, mapCenter: mapState.region.center)
                .environment(appState)
                .environment(\.cockpitTheme, theme)
                .environmentObject(openAIPDataService)
                .environmentObject(dataStatusManager)
                .environmentObject(offlineMapManager)
        }
    }

    private func mapControls(withZoom: Bool, orientationSegments: Bool = true) -> some View {
        HStack(spacing: CockpitType.size(kneeboard: 10, phone: 8)) {
            chromeButton(icon: "square.stack.3d.up", title: L10n.Nav.mapSheet) { showMapSheet = true }
                .overlay(alignment: .topTrailing) {
                    // Airspace data aging or stale: the cue sits on the button that leads to it.
                    if airspaceDataNeedsAttention {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.aero(size: 14, weight: .bold))
                            .foregroundColor(theme.warning)
                            .padding(4)
                            .background(theme.panel, in: Circle())
                            .offset(x: 8, y: -8)
                            .accessibilityLabel(Text("Airspace data is out of date"))
                    }
                }
            if orientationSegments {
                orientationToggle
            } else {
                orientationButton
            }
            // Filled when the map has been moved off the aircraft: the one control that matters then.
            chromeButton(icon: isFollowingAircraft ? "location.fill" : "location",
                         title: L10n.Nav.centre, prominent: !isFollowingAircraft) { centerOnAircraft() }
            if withZoom {
                HStack(spacing: 10) {
                    zoomButton(icon: "minus", label: L10n.Nav.zoomOut) { zoom(by: 2.0) }
                    zoomButton(icon: "plus", label: L10n.Nav.zoomIn) { zoom(by: 0.5) }
                }
            }
        }
    }

    /// `height`: taller than a map control, in a row of the thumb bar's height (Routes beside the check
    /// slot). `fillsWidth`: the row's width (Routes under the slot in the landscape column).
    private func chromeButton(icon: String, title: String, prominent: Bool = false, height: CGFloat? = nil,
                              fillsWidth: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.aero(size: CockpitType.label, weight: .semibold))
                Text(title)
                    .font(.aero(size: CockpitType.label, weight: .bold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundColor(prominent ? theme.actionText : theme.action)
            .padding(.horizontal, CockpitType.size(kneeboard: 16, phone: 12))
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: height ?? CockpitTarget.control)
            .background(RoundedRectangle(cornerRadius: 14).fill(prominent ? theme.action : theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(prominent ? Color.clear : theme.panelStroke, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// North up / Track up, both words on screen and the current one filled. It was the middle state
    /// of a three-state arrow button with no label. (review C5)
    private var orientationToggle: some View {
        HStack(spacing: 0) {
            orientationSegment(.northUp, title: L10n.Nav.northUp)
            orientationSegment(.trackUp, title: L10n.Nav.trackUp)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.panelStroke, lineWidth: 1))
    }

    /// The phone's orientation control: one button, named after the current mode; a tap switches it.
    private var orientationButton: some View {
        let northUp = mapOrientationMode == .northUp
        return chromeButton(icon: northUp ? "location.north.line" : "location.north.line.fill",
                            title: northUp ? L10n.Nav.northUp : L10n.Nav.trackUp) { toggleOrientation() }
            .accessibilityValue(northUp ? L10n.Nav.northUp : L10n.Nav.trackUp)
    }

    private func orientationSegment(_ mode: MapOrientationMode, title: String) -> some View {
        let selected = mapOrientationMode == mode
        return Button { if !selected { toggleOrientation() } } label: {
            Text(title)
                .font(.aero(size: CockpitType.label, weight: .bold))
                .lineLimit(1)
                .fixedSize()
                .foregroundColor(selected ? theme.actionText : theme.action)
                .padding(.horizontal, 14)
                .frame(minHeight: CockpitTarget.control - 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(selected ? theme.action : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func zoomButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.aero(size: CockpitType.response, weight: .semibold))
                .foregroundColor(theme.action)
                .frame(width: CockpitTarget.control, height: CockpitTarget.control)
                .background(RoundedRectangle(cornerRadius: 14).fill(theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.panelStroke, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The two frequencies to have set: the one to talk to now and the next. Tap for every leg and
    /// every frequency along the way.
    private var freqCard: some View {
        let current = phaseFreqItems.first { $0.role == .current }
        let next = phaseFreqItems.first { $0.role == .next }
        return Button(action: toggleLegsAndFrequencies) {
            HStack(spacing: CockpitType.size(kneeboard: 16, phone: 10)) {
                freqCell(tag: L10n.Nav.freqCurrent, tint: theme.onTarget, item: current)
                Rectangle().fill(theme.panelStroke).frame(width: 1, height: 52)
                freqCell(tag: L10n.Nav.freqNext, tint: theme.info, item: next)
                legsChevron
            }
            .padding(.horizontal, CockpitType.size(kneeboard: 16, phone: 12))
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A hint, not a label: a label replaced the station and frequency, so VoiceOver never read the
        // NOW and NEXT frequencies at all. (v6.0 review)
        .accessibilityHint(L10n.Nav.legsAndFrequencies)
    }

    private func freqCell(tag: String, tint: Color, item: PhaseFrequency?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(tag)
                    .font(.aero(size: CockpitType.label, weight: .bold))
                    .foregroundColor(tint)
                Text(item?.station ?? "—")
                    .font(.aero(size: CockpitType.label))
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
            }
            // One line, whatever was typed for a waypoint: a second line made the card taller. (6.1)
            FrequencyLineText(text: item?.freq ?? "—",
                              font: .aero(size: CockpitType.response, weight: .bold, design: .monospaced),
                              color: theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Every leg (planned, flown, ahead or over) and every frequency, opened from either card.
    /// Side by side on an iPad, one above the other on a phone (`LegsPanelColumns`). With no route, the
    /// frequencies alone, the width of the panel from its left edge: the side-by-side version, its legs
    /// empty, left them 300 pt wide in the middle of the panel, where "130.355" wrapped. (6.1, device
    /// check)
    private var legsAndFrequencies: some View {
        Group {
            if flightPlanManager.activeFlightPlan != nil {
                LegsPanelColumns {
                    legsColumn
                    freqColumn(large: true)
                }
            } else {
                freqColumn(large: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var legsColumn: some View {
        if let plan = flightPlanManager.activeFlightPlan {
            VStack(alignment: .leading, spacing: 10) {
                waypointList(plan: plan, large: true)
                destinationSummaryView
                progressRow(plan: plan)
            }
        }
    }

    /// The thumb bar: the leg timer, MARK as the big button (named after the waypoint), Divert, and
    /// everything else under More. Reset lives in More, with undo, not beside MARK. (review C2)
    /// With no route on the map there is nothing to time or mark: the way to put one there is a
    /// normal-size button, not a 104 pt bar. (on-device review #1, R-01)
    ///
    /// Only in flight. The same map is Plan › Map on the ground (`isInCockpit` there too), and with a
    /// route armed it offered START LEG, MARK and DIVERT: a tap recorded a time over a waypoint and
    /// advanced the leg before the flight existed, so the leg timer and the nav log's times were wrong
    /// once airborne. On the ground the row is the way to the routes, as with no route. (v6.0 review)
    ///
    /// In the Cockpit's flight the check slot leads the row, in one frame whatever follows it: MARK with
    /// Divert and More, GO AROUND and TOUCH-AND-GO, or Routes (`MapThumbRow`). (6.1)
    @ViewBuilder
    private var navThumbBar: some View {
        let spacing = CockpitType.size(kneeboard: 12, phone: 8)
        if thumbRow == .routes {
            routesButtonRow()
        } else {
            Group {
                switch thumbRow {
                case .slotThenFlightEvents:
                    slotRow(spacing: spacing, divertAndMoreAxis: .horizontal) { flightEventButtons(spacing: spacing) }
                case .slotThenMark:
                    if let plan = flightPlanManager.activeFlightPlan {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let state = legTimerState(plan)
                            // The leg timer moves into MARK, the button that ends the leg. (mockup M2)
                            slotRow(spacing: spacing, divertAndMoreAxis: .horizontal) {
                                HStack(spacing: spacing) {
                                    navPrimaryButton(plan, started: state.started, leg: state)
                                    divertAndMore(plan, leg: state, axis: .horizontal, spacing: spacing)
                                }
                            }
                        }
                    }
                case .slotThenRoutes:
                    slotRow(spacing: spacing, divertAndMoreAxis: .horizontal) {
                        routesButton(height: CheckSlotButton.height, fillsWidth: true)
                    }
                case .legTimerThenMark:
                    if let plan = flightPlanManager.activeFlightPlan {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let state = legTimerState(plan)
                            HStack(spacing: spacing) {
                                legTimerReadout(elapsed: state.elapsed, planned: state.planned, running: state.running,
                                                started: state.started)
                                navPrimaryButton(plan, started: state.started)
                                divertAndMore(plan, leg: state, axis: .horizontal, spacing: spacing)
                            }
                        }
                    }
                case .routes:
                    EmptyView()
                }
            }
            .padding(.horizontal, CockpitType.size(kneeboard: 16, phone: 12))
            .padding(.vertical, CockpitType.size(kneeboard: 12, phone: 10))
        }
    }

    /// The bottom row for the flight as it stands (portrait, and the phone on its side).
    private var thumbRow: MapThumbRow {
        MapThumbRow.make(showsCheckSlot: showsCheckSlot, showsEventButtons: showsEventButtons,
                         hasRoute: flightPlanManager.activeFlightPlan != nil, flightActive: appState.isFlightActive)
    }

    /// The check slot, when this map is the Cockpit's in flight. (6.1)
    @ViewBuilder
    private func checkSlot() -> some View {
        if let onShowChecklist {
            CockpitCheckSlot(onShowChecklist: onShowChecklist)
        }
    }

    /// The check slot, then `rest` in the room it leaves: the slot as wide as MARK beside Divert and More,
    /// whatever `rest` is, so it holds still when the row changes round it (`CheckSlotRowLayout`).
    /// `divertAndMoreAxis`: Divert and More side by side (the thumb bar) or one above the other (the
    /// phone on its side), as the row with MARK has them.
    private func slotRow<Rest: View>(spacing: CGFloat, divertAndMoreAxis: Axis,
                                     @ViewBuilder rest: () -> Rest) -> some View {
        CheckSlotRowLayout(spacing: spacing) {
            checkSlot()
            divertAndMoreMeasure(axis: divertAndMoreAxis, spacing: divertAndMoreAxis == .horizontal ? spacing : 8)
            rest()
        }
    }

    /// Divert and More as `divertAndMore` lays them out, unseen: what the slot's width is measured by.
    private func divertAndMoreMeasure(axis: Axis, spacing: CGFloat) -> some View {
        let stacked = axis == .vertical
        return EqualWidthStack(axis: axis, spacing: spacing) {
            if !flightPlanManager.isFlightPlanCompleted {
                thumbSecondaryLabel(icon: "arrow.triangle.turn.up.right.diamond.fill", title: L10n.Trip.divert,
                                    tint: theme.action, stacked: stacked)
            }
            thumbSecondaryLabel(icon: "ellipsis.circle", title: L10n.Nav.more, tint: theme.action, stacked: stacked)
        }
        .hidden()
        .accessibilityHidden(true)
    }

    /// GO AROUND and TOUCH-AND-GO after the slot, sharing what it leaves: approach and landing (mockup
    /// M3), and from circuit height. Hold 1 s to confirm, or a single tap in circuits, as on the
    /// checklist pane.
    private func flightEventButtons(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            MapFlightEventButton(event: .goAround)
                .frame(maxWidth: .infinity)
            MapFlightEventButton(event: .touchAndGo)
                .frame(maxWidth: .infinity)
        }
    }

    /// The landscape phone's version, under the Cockpit's column: the slot (or the leg timer), MARK, and
    /// Divert and More stacked, half height, so MARK keeps its width. (iPhone pass, I7)
    @ViewBuilder
    private var navThumbColumnCompact: some View {
        switch thumbRow {
        case .slotThenFlightEvents:
            slotRow(spacing: 8, divertAndMoreAxis: .vertical) { flightEventButtons(spacing: 8) }
        case .slotThenMark:
            if let plan = flightPlanManager.activeFlightPlan {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let state = legTimerState(plan)
                    slotRow(spacing: 8, divertAndMoreAxis: .vertical) {
                        HStack(spacing: 8) {
                            navPrimaryButton(plan, started: state.started, leg: state)
                            divertAndMore(plan, leg: state, axis: .vertical, stacked: true)
                        }
                    }
                }
            }
        case .slotThenRoutes:
            slotRow(spacing: 8, divertAndMoreAxis: .vertical) {
                routesButton(height: CheckSlotButton.height, fillsWidth: true)
            }
        case .legTimerThenMark:
            if let plan = flightPlanManager.activeFlightPlan {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let state = legTimerState(plan)
                    HStack(spacing: 8) {
                        legTimerReadout(elapsed: state.elapsed, planned: state.planned, running: state.running,
                                        started: state.started)
                        navPrimaryButton(plan, started: state.started)
                        divertAndMore(plan, leg: state, axis: .vertical, stacked: true)
                    }
                }
            }
        case .routes:
            routesButtonRow(padded: false)
        }
    }

    /// The landscape side column's version, in two rows so the legs keep room above it: the leg timer
    /// and Divert, then MARK with More beside it, where the thumb rests. In the Cockpit's flight the
    /// check slot heads them, the column's width, whatever the row under it (`MapThumbColumn`).
    @ViewBuilder
    private var navThumbColumn: some View {
        let plan = flightPlanManager.activeFlightPlan
        switch MapThumbColumn.make(showsCheckSlot: showsCheckSlot, showsEventButtons: showsEventButtons,
                                   hasRoute: plan != nil, flightActive: appState.isFlightActive) {
        case .slotOverFlightEvents:
            VStack(spacing: 12) {
                checkSlot()
                HStack(spacing: 12) {
                    MapFlightEventButton(event: .goAround, narrow: true)
                    MapFlightEventButton(event: .touchAndGo, narrow: true)
                }
            }
        case .slotOverMark:
            // The slot on top, where the leg timer and Divert were; the leg timer in MARK.
            if let plan {
                VStack(spacing: 12) {
                    checkSlot()
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let state = legTimerState(plan)
                        // Divert and More stacked, half height, so MARK keeps the width for its leg line.
                        HStack(spacing: 12) {
                            navPrimaryButton(plan, started: state.started, leg: state)
                            divertAndMore(plan, leg: state, axis: .vertical, stacked: true)
                        }
                    }
                }
            }
        case .slotOverRoutes:
            // No route: the slot as with one, and Routes where MARK would be, as tall, so the slot
            // doesn't move when a route is armed. (6.1)
            VStack(spacing: 12) {
                checkSlot()
                routesButton(height: CheckSlotButton.height, fillsWidth: true)
            }
        case .legTimerOverMark:
            if let plan {
                legTimerOverMark(plan)
            }
        case .routes:
            routesButtonRow()
        }
    }

    /// The landscape column in flight without the check slot: the leg timer and Divert, then MARK with
    /// More beside it. Divert over More, so the two share a width.
    private func legTimerOverMark(_ plan: FlightPlan) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let state = legTimerState(plan)
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    legTimerReadout(elapsed: state.elapsed, planned: state.planned, running: state.running,
                                    started: state.started)
                        .frame(maxWidth: .infinity, minHeight: CockpitTarget.thumb, alignment: .leading)
                    navPrimaryButton(plan, started: state.started)
                }
                divertAndMore(plan, leg: state, axis: .vertical, spacing: 12)
            }
        }
    }

    /// Routes alone on the ground (Plan › Map). (In the Cockpit's flight with no route, Routes follows
    /// the check slot: `MapThumbRow.slotThenRoutes`.) `padded`: false under the landscape phone's column,
    /// which pads its thumb row itself.
    private func routesButtonRow(padded: Bool = true) -> some View {
        HStack(spacing: CockpitType.size(kneeboard: 12, phone: 8)) {
            routesButton()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, padded ? 16 : 0)
        .padding(.vertical, padded ? 12 : 0)
    }

    /// `fillsWidth`: the rest of the row after the check slot, or a row of its own under it in the
    /// landscape column.
    private func routesButton(height: CGFloat? = nil, fillsWidth: Bool = false) -> some View {
        chromeButton(icon: "point.topleft.down.to.point.bottomright.curvepath",
                     title: L10n.Ground.planRoutes, height: height, fillsWidth: fillsWidth) {
            if let onShowRoutes { onShowRoutes() } else { showFlightPlanning = true }
        }
    }

    private struct LegTimerState {
        let planned: TimeInterval?
        let running: Bool
        let elapsed: TimeInterval
        var started: Bool { running || elapsed > 0.5 }
    }

    private func legTimerState(_ plan: FlightPlan) -> LegTimerState {
        LegTimerState(planned: plan.legArriving(at: plan.currentWaypointIndex)?.totalLegEET,
                      running: flightPlanManager.isChronometerRunning,
                      elapsed: flightPlanManager.chronometerElapsed)
    }

    /// START LEG before the timer runs, then MARK named after the waypoint. `leg`: beside the check slot
    /// the leg timer has no place of its own and becomes MARK's second line, "LEG 2:05 / 17:32" (the
    /// phone: "LSGC · 2:05"). (6.1, mockup M2)
    @ViewBuilder
    private func navPrimaryButton(_ plan: FlightPlan, started: Bool, leg: LegTimerState? = nil) -> some View {
        if !started {
            thumbPrimaryButton(icon: "stopwatch", title: L10n.Nav.startLegTimer) {
                flightPlanManager.startChronometer()
            }
        } else if plan.currentWaypointIndex < plan.waypoints.count {
            let index = plan.currentWaypointIndex
            let name = plan.waypoints[index].name
            if CockpitScale.current == .phone {
                // The phone: the waypoint under MARK, where "MARK LSGC" on one line had to shrink.
                let parts = [name.isEmpty ? nil : name, leg.map { legTimeText($0, planned: false) }].compactMap { $0 }
                thumbPrimaryButton(icon: "mappin.and.ellipse", title: L10n.Nav.mark,
                                   subtitle: parts.isEmpty ? nil : parts.joined(separator: " · ")) {
                    markWaypoint(at: index, in: plan)
                }
            } else {
                thumbPrimaryButton(icon: "mappin.and.ellipse",
                                   title: name.isEmpty ? L10n.Nav.mark : "\(L10n.Nav.mark) \(name)",
                                   subtitle: leg.map { "\(L10n.Nav.leg) \(legTimeText($0, planned: true))" }) {
                    markWaypoint(at: index, in: plan)
                }
            }
        } else {
            Spacer(minLength: 0)
        }
    }

    /// The leg time so far, against the planned one where there's room ("2:05 / 17:32"); paused, it says so.
    private func legTimeText(_ state: LegTimerState, planned: Bool) -> String {
        var text = formatClock(state.elapsed)
        if planned, let plannedTime = state.planned { text += " / \(formatClock(plannedTime))" }
        if !state.running { text += " ‖" }
        return text
    }

    /// Divert (while the route has a leg to fly) and More, one width for both: side by side in the thumb
    /// bar, one above the other in the landscape columns (`stacked`: half height each, beside MARK).
    private func divertAndMore(_ plan: FlightPlan, leg state: LegTimerState, axis: Axis, stacked: Bool = false,
                               spacing: CGFloat = 8) -> some View {
        EqualWidthStack(axis: axis, spacing: spacing) {
            if !flightPlanManager.isFlightPlanCompleted { divertThumbButton(plan, stacked: stacked) }
            navMoreMenu(running: state.running, started: state.started, stacked: stacked)
        }
    }

    private func divertThumbButton(_ plan: FlightPlan, stacked: Bool = false) -> some View {
        thumbSecondaryButton(icon: "arrow.triangle.turn.up.right.diamond.fill",
                             title: L10n.Trip.divert,
                             tint: plan.diversion != nil ? theme.warning : theme.action,
                             stacked: stacked) { openDivert(nil) }
    }

    /// Leg time so far against the planned leg time, and how far ahead or over.
    private func legTimerReadout(elapsed: TimeInterval, planned: TimeInterval?, running: Bool,
                                 started: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.Nav.leg)
                .font(.aero(size: CockpitType.label, weight: .semibold))
                .foregroundColor(theme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(started ? formatClock(elapsed) : "–:––")
                    .font(.aero(size: CockpitType.response, weight: .bold, design: .monospaced))
                    .foregroundColor(running ? theme.textPrimary : theme.textSecondary)
                // The planned leg time only where there is room for it; the line under says how far
                // ahead or over. (iPhone pass)
                if let planned, CockpitScale.current == .kneeboard {
                    Text("/ \(formatClock(planned))")
                        .font(.aero(size: CockpitType.label, design: .monospaced))
                        .foregroundColor(theme.textSecondary)
                }
            }
            if started, let planned {
                let delta = planned - elapsed
                Text((delta >= 0 ? "▲ " : "▼ ") + formatClock(abs(delta)))
                    .font(.aero(size: CockpitType.label, weight: .semibold, design: .monospaced))
                    .foregroundColor(delta >= 0 ? theme.onTarget : theme.warning)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func thumbPrimaryButton(icon: String, title: String, subtitle: String? = nil,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                HStack(spacing: CockpitType.size(kneeboard: 12, phone: 8)) {
                    Image(systemName: icon).font(.aero(size: CockpitType.button, weight: .bold))
                    Text(title)
                        .font(.aero(size: CockpitType.button, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.aero(size: CockpitType.label, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .foregroundColor(theme.actionText)
            .padding(.horizontal, CockpitType.size(kneeboard: 16, phone: 10))
            .frame(maxWidth: .infinity, minHeight: CockpitTarget.thumb)
            .background(RoundedRectangle(cornerRadius: 18).fill(theme.action))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(subtitle.map { "\(title) \($0)" } ?? title)
    }

    private func thumbSecondaryButton(icon: String, title: String, tint: Color, stacked: Bool = false,
                                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            thumbSecondaryLabel(icon: icon, title: title, tint: tint, stacked: stacked)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    /// `stacked`: half height, icon beside the word, for two buttons one above the other (the landscape
    /// phone). Narrower on the phone, where MARK needs the width. (iPhone pass) It fills the width it is
    /// offered, so `divertAndMore` can give Divert and More one width.
    @ViewBuilder
    private func thumbSecondaryLabel(icon: String, title: String, tint: Color, stacked: Bool = false) -> some View {
        Group {
            if stacked {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.aero(size: CockpitType.label, weight: .semibold))
                    Text(title)
                        .font(.aero(size: CockpitType.label, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(.horizontal, 10)
                .frame(minWidth: 96, maxWidth: .infinity, minHeight: (CockpitTarget.thumb - 8) / 2)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: icon).font(.aero(size: CockpitType.response, weight: .semibold))
                    Text(title)
                        .font(.aero(size: CockpitType.label, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(.horizontal, CockpitType.size(kneeboard: 12, phone: 8))
                .frame(minWidth: CockpitType.size(kneeboard: 120, phone: 64), maxWidth: .infinity,
                       minHeight: CockpitTarget.thumb)
            }
        }
        .foregroundColor(tint)
        .background(RoundedRectangle(cornerRadius: stacked ? 12 : 18).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: stacked ? 12 : 18).stroke(tint.opacity(0.45), lineWidth: 1))
        .contentShape(Rectangle())
    }

    /// The rarer actions: the leg timer's pause and reset (reset offers undo), the legs and
    /// frequencies, and the routes.
    private func navMoreMenu(running: Bool, started: Bool, stacked: Bool = false) -> some View {
        Menu {
            if started {
                Button {
                    running ? flightPlanManager.pauseChronometer() : flightPlanManager.startChronometer()
                } label: {
                    Label(running ? L10n.Nav.pauseChronometer : L10n.Nav.startChronometer,
                          systemImage: running ? "pause.fill" : "play.fill")
                }
                Button(role: .destructive) { resetLegTimer() } label: {
                    Label(L10n.Nav.resetChronometer, systemImage: "arrow.counterclockwise")
                }
            }
            Button(action: toggleLegsAndFrequencies) {
                Label(L10n.Nav.legsAndFrequencies, systemImage: "list.bullet")
            }
            Button { if let onShowRoutes { onShowRoutes() } else { showFlightPlanning = true } } label: {
                Label(L10n.Ground.planRoutes, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
        } label: {
            thumbSecondaryLabel(icon: "ellipsis.circle", title: L10n.Nav.more, tint: theme.action, stacked: stacked)
        }
        .accessibilityLabel(L10n.Nav.more)
    }

    private var liveBearingText: String? {
        guard let loc = locationManager.currentLocation,
              let brg = flightPlanManager.bearingToNextWaypoint(from: loc) else { return nil }
        return NextWaypointReadout.bearing(brg)
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
        // Diverting: the field you are going to is the next call, whatever the route says. (v5.1)
        if let diversion = flightPlanManager.activeFlightPlan?.diversion {
            next = contact(airfieldFreqs(for: diversion.ident).map { (label: "\(diversion.ident) \($0.type)", freq: $0.freq) })
        }
        if next == nil, flightPlanManager.activeFlightPlan?.diversion == nil,
           let plan = flightPlanManager.activeFlightPlan {
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

    /// The frequency column — by default just CURRENT + NEXT (what a VFR pilot needs to hand); "All
    /// Frequencies" reveals every station along the journey in order. (v4 UI/UX Revamp — current/next)
    /// EMERGENCY is pinned under the scroll, lined up with this column (`emergencyFooter`). (6.1, option C)
    /// Every station whole, in the panel's one scroll: past five, they had a scroll of their own inside
    /// it. (6.1, device check)
    private func freqColumn(large: Bool) -> some View {
        let nonEmergency = phaseFreqItems.filter { !$0.isEmergency }
        let essentials = nonEmergency.filter { $0.role == .current || $0.role == .next }
        let hasMore = nonEmergency.count > essentials.count
        let visible = showAllFreqs ? nonEmergency : essentials
        return VStack(alignment: .leading, spacing: 0) {
            Text(L10n.Nav.radioFrequencies)
                .font(.aero(size: large ? CockpitType.label : 9, weight: .semibold)).tracking(large ? 0 : 0.4)
                .foregroundColor(theme.info)
                .lineLimit(1)
                .padding(.bottom, 4)
            ForEach(visible) { freqRow($0, large: large) }
            if hasMore {
                // No animated expand/collapse under Reduce Motion (UX-18)
                Button(action: { withAnimation(reduceMotion ? nil : .default) { showAllFreqs.toggle() } }) {
                    HStack(spacing: large ? 6 : 3) {
                        Text(showAllFreqs ? L10n.Nav.showLess : "\(L10n.Nav.allFrequencies) (\(nonEmergency.count))")
                        Image(systemName: showAllFreqs ? "chevron.up" : "chevron.down").font(.aero(size: large ? 16 : 9))
                    }
                    .font(.aero(size: large ? CockpitType.label : 10))
                    .foregroundColor(large ? theme.action : theme.textDim)
                    .frame(minHeight: large ? 44 : nil)
                    .contentShape(Rectangle())
                }
                .padding(.vertical, 3)
            }
        }
    }

    /// A station and its frequency (`FrequencyRow`).
    private func freqRow(_ item: PhaseFrequency, large: Bool = false) -> some View {
        FrequencyRow(item: item, large: large)
    }

    /// `large`: the iPad kneeboard panel (v6.0 · P6). Rows read at 20–24 pt; heading and distance
    /// drop out, since the next-waypoint card already shows them live for the leg being flown.
    ///
    /// Every leg, whole, in the panel's one scroll (`legsScroll`). It had a scroll of its own, five rows
    /// tall, inside the panel's: the legs scrolled, then the whole panel did. (6.1, device check)
    private func waypointList(plan: FlightPlan, compact: Bool = false, large: Bool = false) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(plan.waypoints.enumerated()), id: \.element.id) { index, wpt in
                waypointRow(plan: plan, index: index, wpt: wpt, compact: compact, large: large)
                    .id(LegsPanelReveal.RowID(index: index))
                if index < plan.waypoints.count - 1 {
                    Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
                }
            }
        }
    }

    private func waypointRow(plan: FlightPlan, index: Int, wpt: FlightPlanWaypoint, compact: Bool = false,
                             large: Bool = false) -> some View {
        let isCurrent = index == plan.currentWaypointIndex
        let isPast = index < plan.currentWaypointIndex
        let isPreview = previewWaypointIndex == index
        let leg = plan.legArriving(at: index)
        let actual = actualLegTime(plan: plan, index: index, isCurrent: isCurrent, isPast: isPast, wpt: wpt)
        // A previewed waypoint ahead can be flown to straight away, skipping the ones before it —
        // and a waypoint of the route is where a diversion can rejoin it. (v5.1)
        let offersDirect = isPreview && (index > plan.currentWaypointIndex || plan.diversion != nil)
        // DIRECT over the row's ACT and Δ, empty on a waypoint ahead, rather than beside the row: beside
        // it, it took its width from the name, all of it beside the frequencies. (6.1, device check)
        let actualAndDelta = large ? LegRowMetrics.actualAndDeltaWidth : 44 + 6 + 52
        return waypointRowButton(plan: plan, index: index, wpt: wpt, compact: compact, large: large,
                                 isCurrent: isCurrent, isPast: isPast, isPreview: isPreview, leg: leg, actual: actual)
            .overlay(alignment: .trailing) {
                if offersDirect {
                    Button {
                        flightPlanManager.directTo(waypointAt: index)
                        previewWaypointIndex = nil
                        // It re-centred the map on the aircraft. The band now frames the new leg, and the
                        // map follows the aircraft once the panel closes. (6.1, option C)
                        cameraBeforeLegs?.following = true
                    } label: {
                        Text(L10n.Trip.directToWaypoint)
                            .font(.aero(size: large ? CockpitType.label : 12, weight: .bold))
                            .foregroundColor(theme.actionText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .padding(.horizontal, 10)
                            .frame(minHeight: large ? 44 : 36)
                            .background(theme.action, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(width: actualAndDelta, alignment: .trailing)
                    .padding(.trailing, LegRowMetrics.horizontalPadding)
                }
            }
    }

    private func waypointRowButton(plan: FlightPlan, index: Int, wpt: FlightPlanWaypoint, compact: Bool,
                                   large: Bool = false,
                                   isCurrent: Bool, isPast: Bool, isPreview: Bool,
                                   leg: FlightPlanWaypoint?, actual: TimeInterval?) -> some View {
        // Column widths follow the type (`LegRowMetrics`).
        let indexWidth: CGFloat = large ? LegRowMetrics.indexWidth : 16
        let timeWidth: CGFloat = large ? LegRowMetrics.timeWidth : 44
        let deltaWidth: CGFloat = large ? LegRowMetrics.deltaWidth : 52
        return Button(action: { handleWaypointTap(index: index, plan: plan, isPast: isPast) }) {
            HStack(spacing: LegRowMetrics.spacing) {
                // Sequence number — matches the numbered disc on the map. (v4 UI/UX Revamp)
                Text("\(index + 1)")
                    .font(.aero(size: large ? CockpitType.label : 11, weight: .bold, design: .monospaced))
                    .foregroundColor(isCurrent ? theme.route : theme.textSecondary)
                    .frame(width: indexWidth, alignment: .center)
                Image(systemName: isPast ? "circle.fill" : (isCurrent ? "location.fill" : "circle"))
                    .font(.aero(size: large ? 14 : 9))
                    .foregroundColor(isPast ? theme.onTarget : (isCurrent ? theme.route : theme.textDim))
                Text(wpt.name.isEmpty ? "WPT \(index + 1)" : wpt.name)
                    // The label size, like the times beside it: at 24 pt a name had to shrink to fit the
                    // landscape column. The current leg reads by its colour.
                    .font(.aero(size: large ? CockpitType.label : 13, weight: isCurrent ? .bold : .regular, design: .monospaced))
                    .foregroundColor(isCurrent ? theme.route : theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(large ? 0.8 : 1)
                Spacer(minLength: LegRowMetrics.nameGap)
                // Fixed-width columns so every row's heading / distance / PLAN / ACT / Δ line up,
                // whether or not a leg has been flown yet. (v4 UI/UX Revamp — column alignment)
                HStack(spacing: LegRowMetrics.timeSpacing) {
                    // Heading + distance kept on iPad; dropped on the narrow iPhone table. (v4 UI/UX Revamp)
                    if !compact && !large {
                        Text(leg?.formattedMagneticCourse ?? "")
                            .foregroundColor(theme.textSecondary).frame(width: 38, alignment: .trailing)
                        Text(leg?.distance.map { String(format: "%.1f", $0) } ?? "")
                            .foregroundColor(theme.textSecondary).frame(width: 40, alignment: .trailing)
                    }
                    Text((leg?.totalLegEET).map { formatClock($0) } ?? "")  // PLAN (EET)
                        .foregroundColor(large ? theme.textSecondary : theme.textDim).frame(width: timeWidth, alignment: .trailing)
                    Text(actual.map { formatClock($0) } ?? "")            // ACT / live
                        .foregroundColor(isCurrent ? theme.route : theme.onTarget)
                        .frame(width: timeWidth, alignment: .trailing)
                    legDeltaText(planned: leg?.totalLegEET, actual: actual)  // Δ ahead/over
                        .frame(width: deltaWidth, alignment: .trailing)
                }
                .font(.aero(size: large ? CockpitType.label : 10, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(large ? 0.8 : 1)   // shrink a little rather than cut a time short
            }
            .padding(.horizontal, LegRowMetrics.horizontalPadding).padding(.vertical, large ? 9 : 7)
            .background(isPreview ? theme.info.opacity(0.14)
                        : (isCurrent ? theme.route.opacity(0.10) : Color.clear))
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
                .foregroundColor(d >= 0 ? theme.onTarget : theme.warning)
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

    /// Tap a waypoint to preview it; tap the active/previewed one to return. The leg table only shows in
    /// the open panel, whose band frames the aircraft and the previewed waypoint in place of the next
    /// one. The map the pilot left isn't touched, so closing the panel still puts it back. (It centred the
    /// map on the waypoint, under the panel; 6.1, option C)
    private func previewWaypoint(index: Int, plan: FlightPlan) {
        guard plan.waypoints.indices.contains(index) else { return }
        if previewWaypointIndex == index || index == plan.currentWaypointIndex {
            previewWaypointIndex = nil
        } else {
            previewWaypointIndex = index
        }
    }

    private func progressRow(plan: FlightPlan) -> some View {
        HStack(spacing: 10) {
            ProgressView(value: plan.progress)
                .progressViewStyle(.linear)
                .tint(theme.onTarget)
            HStack(spacing: 3) {
                ForEach(0..<plan.waypoints.count, id: \.self) { i in
                    Circle()
                        .fill(i < plan.currentWaypointIndex ? theme.onTarget
                              : (i == plan.currentWaypointIndex ? theme.route : theme.textDim.opacity(0.5)))
                        .frame(width: 5, height: 5)
                }
            }
        }
    }

    /// Destination endpoint, total remaining distance (live to next + remaining planned legs), and the
    /// planned ETA at the destination. (v4 UI/UX Revamp — row 2)
    private var destinationSummary: (dest: String, remainingNM: Double, eta: Date?)? {
        guard let plan = flightPlanManager.activeFlightPlan,
              plan.waypoints.count >= 2,
              let dest = plan.waypoints.last else { return nil }
        // Diverting: the destination IS the diversion field, straight there. Adding the rest of the
        // route to the distance to the field would be a number describing no flight at all. (v5.1)
        if let diversion = plan.diversion {
            guard let loc = locationManager.currentLocation,
                  let d = flightPlanManager.distanceToNextWaypoint(from: loc) else {
                return (diversion.ident, 0, nil)
            }
            let gs = locationManager.currentSpeedKnots
            return (diversion.ident, d, gs > 30 ? Date().addingTimeInterval(d / gs * 3600) : nil)
        }
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
            HStack(spacing: 8) {
                Text("DEST")
                    .font(.aero(size: CockpitType.label, weight: .semibold))
                    .foregroundColor(theme.textSecondary)
                Text(s.dest)
                    .font(.aero(size: CockpitType.label, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.textPrimary)
                Text("·").foregroundColor(theme.textDim)
                Text(String(format: "%.0f NM", s.remainingNM))
                    .font(.aero(size: CockpitType.label, design: .monospaced))
                    .foregroundColor(theme.textPrimary)
                if let eta = s.eta {
                    Text("·").foregroundColor(theme.textDim)
                    Text("ETA \(eta.formatted(date: .omitted, time: .shortened))")
                        .font(.aero(size: CockpitType.label, design: .monospaced))
                        .foregroundColor(theme.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }


    private func markWaypoint(at index: Int, in plan: FlightPlan) {
        let timer = flightPlanManager.legTimerSnapshot
        flightPlanManager.markWaypoint()
        guard let timer else { return }
        let name = plan.waypoints[index].name.isEmpty ? "WPT \(index + 1)" : plan.waypoints[index].name
        offerUndo(L10n.Nav.markedAt(name, Date().formatted(date: .omitted, time: .shortened))) {
            flightPlanManager.undoMark(ofWaypointAt: index, timer: timer)
        }
    }

    private func resetLegTimer() {
        guard let timer = flightPlanManager.legTimerSnapshot else { return }
        flightPlanManager.resetChronometer()
        offerUndo(L10n.Nav.legTimerReset) { flightPlanManager.restoreLegTimer(timer) }
    }

    // MARK: - Undo (v6.0 · C2)

    /// A mis-tap in turbulence is taken back with one tap, for a few seconds.
    private func offerUndo(_ message: String, undo: @escaping () -> Void) {
        // One undo at a time: this one is newer than a waypoint the flight marked on its own.
        flightPlanManager.dismissAutoMarkNotice()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            undoOffer = NavUndoOffer(message: message, undo: undo)
        }
    }

    /// A duration as "M:SS" (or "H:MM:SS" past an hour). (v4 UI/UX Revamp)
    private func formatClock(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: - Divert (v5.1)

    /// "Divert here" in an airport's callout: in flight only, like the thumb bar's Divert. Plan › Map on
    /// the ground is this same map, and with a route armed the callout offered it there too, leaving a
    /// diversion on the route before the flight existed. (v6.0 review, 1694b7c; found by the 6.0 manual)
    private var airportDivert: ((String) -> Void)? {
        appState.isFlightActive ? { ident in openDivert(ident) } : nil
    }

    private func openDivert(_ ident: String?) {
        divertPreselect = ident
        showDivert = true
    }

    // MARK: - Off-screen route (v4.4.0)

    /// Where the armed route is, when none of it is on the map. nil the moment any of it is visible,
    /// so this never nags in flight.
    ///
    /// Computed rather than cached: it is a pure function of the plan and the region, and re-deriving
    /// it costs a handful of segment tests against a map that is redrawing chart tiles anyway. Caching
    /// it would mean observing `mapState.region`, which changes on every pan.
    private var routeOffScreenHint: RouteVisibility.OffScreenHint? {
        guard let plan = flightPlanManager.activeFlightPlan,
              !flightPlanManager.isFlightPlanCompleted else { return nil }
        return RouteVisibility.offScreenHint(route: plan.waypoints.map(\.coordinate),
                                             region: mapState.region)
    }

    /// The pill itself. Shared by both layouts — the map opening on the aircraft with the route
    /// somewhere else is not an iPhone-only situation, it is just far more common there because the
    /// viewport is smaller. (v4.4.0 device-test feedback) `leading`: at the left edge, under the chips.
    @ViewBuilder
    private func routeOffScreenPill(leading: Bool) -> some View {
        if let hint = routeOffScreenHint {
            Button { fitActiveRoute() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.aero(size: 11, weight: .semibold))
                        .foregroundColor(theme.action)
                    Text(L10n.Nav.routeOffScreen(Int(hint.distanceNm.rounded()), hint.bearingLabel))
                        .font(.aero(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.textPrimary)
                    Text(L10n.Nav.showRoute)
                        .font(.aero(size: 11, weight: .bold))
                        .foregroundColor(theme.action)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)   // 44 pt like every other control on this map
                .floatingChromeBackground(cornerRadius: 22)
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(theme.action.opacity(0.45), lineWidth: 1)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: leading ? .infinity : nil, alignment: .leading)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Frame the whole active route, and stop following the aircraft — the pilot asked to look
    /// somewhere else, so snapping straight back would undo the tap.
    private func fitActiveRoute() {
        guard let plan = flightPlanManager.activeFlightPlan else { return }
        let coordinates = plan.waypoints.map(\.coordinate).filter { CLLocationCoordinate2DIsValid($0) }
        guard !coordinates.isEmpty else { return }
        // Stop following the aircraft first: the pilot asked to look somewhere else, and snapping
        // straight back would undo the tap. Then hand the framing to the map, which is the only party
        // that knows the viewport's aspect ratio.
        isFollowingAircraft = false
        mapState.pendingFitCoordinates = coordinates
        mapState.objectWillChange.send()   // the fit flag isn't @Published; nudge updateUIView
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
        case .emergency: return L10n.Nav.freqEmergency
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
        // With the map's width known, the bar is as wide as it draws, so it can share a row (the
        // landscape phone's foot of the chart). Until then, the container's width stands in for it.
        if mapWidth > 0 {
            card(mapWidthPoints: mapWidth)
                .frame(height: 50, alignment: .topLeading)
        } else {
            GeometryReader { geometry in
                card(mapWidthPoints: geometry.size.width)
            }
            .frame(height: 50)  // Fixed height for the scale bar container
        }
    }

    private func card(mapWidthPoints: CGFloat) -> some View {
        let info = scaleInfo(mapWidthPoints: mapWidthPoints)
        return VStack(alignment: .leading, spacing: 2) {
            // Scale text
            Text(info.text)
                .font(.aero(size: 11, weight: .medium))
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
        .font: UIFont.aero(size: diameter * 0.56, weight: .heavy),
        .foregroundColor: UIColor.white,
        .paragraphStyle: para,
    ]
    let textSize = text.size(withAttributes: attrs)
    text.draw(at: CGPoint(x: circleRect.midX - textSize.width / 2, y: circleRect.midY - textSize.height / 2), withAttributes: attrs)

    let finalImage = UIGraphicsGetImageFromCurrentImageContext()
    if let finalImage { waypointMarkerImageCache[key] = finalImage }
    return finalImage
}

/// Re-lifts every non-tile overlay above freshly-(re)added tile overlays. Base/OpenAIP chart tiles
/// are added at the same `.aboveLabels` level as the polygon/polyline overlays, so MapKit's
/// insertion order buries the existing airspace/track/route overlays under a newly added tile —
/// user-visible as "airspace disappears on layer switch until toggled off/on". The per-overlay
/// diff-guards can't catch this (the buried overlays are still on the map), so call this after any
/// tile (re-)add. Shared by BOTH map representables. (v4.2 layer-switch fix)
private func reliftNonTileOverlays(on mapView: MKMapView) {
    let buried = mapView.overlays.filter { !($0 is MKTileOverlay) }
    guard !buried.isEmpty else { return }
    mapView.removeOverlays(buried)
    for overlay in buried { mapView.addOverlay(overlay, level: .aboveLabels) }
}

/// Inserts a tile overlay at the BOTTOM of the `.aboveLabels` stack (after any existing tiles,
/// before the first polygon/polyline), so a late tile (re-)add can never bury the airspace/track/
/// route overlays — regardless of which code path adds it or when. This is the structural fix;
/// `reliftNonTileOverlays` stays as repair for any pre-existing inversion. (v4.2 layer-switch fix)
private func insertTileBelowShapes(_ tile: MKTileOverlay, on mapView: MKMapView) {
    let tileCount = mapView.overlays(in: .aboveLabels).filter { $0 is MKTileOverlay }.count
    mapView.insertOverlay(tile, at: tileCount, level: .aboveLabels)
}

/// Incrementally reconciles the airspace polygon overlays on `mapView` with `polygons`.
///
/// Removes only the overlays that are no longer visible and adds only the newly-visible ones,
/// instead of tearing down and re-adding the entire set whenever it changes at all — so a pan that
/// shifts a few airspaces in/out doesn't rebuild the rest. (PR-11)
///
/// Shared by both map representables. `NativeMapViewUIKit` had this diff and `SwissMapView` kept an
/// inline full-rebuild, so panning the Swiss ICAO / Landeskarte / SWISSIMAGE layers re-created every
/// visible airspace polygon on each change while the Apple Maps layer did not. That divergence is
/// exactly the failure mode duplicated code produces: one copy got the optimisation, the other was
/// missed. One implementation now serves both.
private func updateAirspaceOverlays(on mapView: MKMapView, polygons: [AirspacePolygon]) {
    let existing = mapView.overlays.compactMap { $0 as? AirspacePolygon }
    let existingIds = Set(existing.map { $0.airspaceId })
    let newIds = Set(polygons.map { $0.airspaceId })

    guard existingIds != newIds else { return }

    let toRemove = existing.filter { !newIds.contains($0.airspaceId) }
    if !toRemove.isEmpty { mapView.removeOverlays(toRemove) }

    let toAdd = polygons.filter { !existingIds.contains($0.airspaceId) }
    for polygon in toAdd {
        mapView.addOverlay(polygon, level: .aboveLabels)
    }
}

/// The open legs panel's band on a map view, for both representables: one implementation, as
/// `updateAirspaceOverlays` is, since two copies drift. (6.1, option C)
///
/// While the panel is open the band has the camera: it frames the aircraft and the next waypoint
/// (`LegsPanelMap.place`) on every update, so it follows the aircraft, and the map takes no pan, pinch,
/// rotation or marker tap. The shared state is left alone meanwhile (the coordinators send what the band
/// shows to `SharedMapState.bandRegion` instead), so it still holds the map the pilot left, or, once the
/// panel closes, what `NavigationMapView` puts back.
final class LegsBandDriver {
    /// The panel is open, or its camera is still being put back: the update pass leaves its own camera
    /// sync out, and the coordinator doesn't write the band's region into the shared state.
    private(set) var ownsCamera = false
    private var isOpen = false
    /// The last pass's framing, which `routeAhead` keeps, and the waypoint it framed.
    private var framing: LegsPanelMap.Framing?
    private var framedWaypoint: CLLocationCoordinate2D?
    private var lastCamera: MKMapCamera?
    /// The pilot's zoom, in map points per screen point, as last seen with the panel closed: the zoom
    /// the band frames at, whatever the panel does to the map view's size.
    private var pilotScale: Double?
    /// Zoom per metre of camera distance with the map at rest, and the map's height then, last with the
    /// panel closed and last of all. MapKit's field of view is set by the map's height: the same camera
    /// distance is a coarser chart in a shorter map (twice as coarse with the panel open in portrait).
    /// Read at rest: during an animated move the camera already says where it is going, the map still
    /// shows where it was.
    private var pilotScalePerMetre: (value: Double, height: CGFloat)?
    private var scalePerMetre: (value: Double, height: CGFloat)?
    /// The map's zoom range as the panel found it, put back on closing.
    private var zoomRangeBeforeBand: MKMapView.CameraZoomRange?
    /// Bumped on every open and close, so a restore queued by a close doesn't land on a reopened band.
    private var generation = 0
    /// The band has moved the camera somewhere the map wasn't, and the chart there is to be redrawn
    /// once the camera is at rest.
    private var redrawsTilesAtRest = false

    /// The map came to rest (the coordinator's `regionDidChange`): note its zoom, the pilot's when the
    /// band doesn't have the camera.
    func mapCameToRest(_ mapView: MKMapView) {
        let distance = mapView.camera.centerCoordinateDistance
        guard let scale = Self.scale(of: mapView), distance > 0 else { return }
        scalePerMetre = (scale / distance, mapView.bounds.height)
        if let restoring, abs(mapView.bounds.height - restoring.height) < 1 {
            // Back to its height: now the pilot's camera, exactly.
            finishRestore(mapView, mapState: restoring.mapState)
            return
        }
        if redrawsTilesAtRest {
            redrawsTilesAtRest = false
            Self.redrawTiles(on: mapView)
        }
        guard !ownsCamera else { return }
        pilotScale = scale
        pilotScalePerMetre = scalePerMetre
    }

    /// One update pass. True while the band has the camera.
    func update(_ mapView: MKMapView, band: LegsPanelMap.Band?, mapState: SharedMapState) -> Bool {
        guard let band else {
            if isOpen { close(mapView, mapState: mapState) }
            return ownsCamera
        }
        if !isOpen { open(mapView) }
        frame(mapView, band: band)
        return true
    }

    private func open(_ mapView: MKMapView) {
        // A map that hasn't moved since it was made: its zoom as it stands.
        if pilotScale == nil { mapCameToRest(mapView) }
        // Unless a restore is still on its way: then the range it will put back.
        if !ownsCamera { zoomRangeBeforeBand = mapView.cameraZoomRange }
        isOpen = true
        ownsCamera = true
        generation += 1
        restoring = nil
        framing = nil
        framedWaypoint = nil
        lastCamera = nil
        mapView.isScrollEnabled = false
        mapView.isZoomEnabled = false
        mapView.isRotateEnabled = false
        // An open callout would sit on the band with nothing to close it.
        for annotation in mapView.selectedAnnotations { mapView.deselectAnnotation(annotation, animated: false) }
        // VoiceOver reaches the band through its own element, which closes the panel.
        mapView.accessibilityElementsHidden = true
    }

    private func frame(_ mapView: MKMapView, band: LegsPanelMap.Band) {
        // No position: the camera stays where it is. Not measured with the panel open yet: wait for it.
        guard let aircraft = band.aircraft, CLLocationCoordinate2DIsValid(aircraft), let rect = band.rect,
              band.viewSize.height > 0, let pilotScale, let measured = scalePerMetre else { return }
        if !Self.same(band.waypoint, framedWaypoint) {
            // Another waypoint (MARK, a pass, Direct to, a preview): decide afresh how far is far.
            framing = nil
            framedWaypoint = band.waypoint
        }
        // MapKit centres the camera in the map's safe area, not in the view: on a map running under the
        // home indicator, or under the status bar, the middle is that much off.
        let safe = mapView.safeAreaInsets
        let cameraPoint = CGPoint(x: safe.left + (band.viewSize.width - safe.left - safe.right) / 2,
                                  y: safe.top + (band.viewSize.height - safe.top - safe.bottom) / 2)
        let placement = LegsPanelMap.place(aircraft: MKMapPoint(aircraft), waypoint: band.waypoint.map(MKMapPoint.init),
                                           heading: band.heading, band: rect, viewSize: band.viewSize,
                                           cameraPoint: cameraPoint, scale: pilotScale, previous: framing)
        framing = placement.framing
        // The camera distance that gives that zoom in the map as laid out with the panel open, from the
        // last zoom per metre measured at rest, taken to the band's height (MapKit's field of view is
        // set by the map's height). Measured at that height already once the map has settled there.
        let perMetre = Double(measured.value) * Double(measured.height) / Double(band.viewSize.height)
        allowPilotsZoom(on: mapView, scalePerMetre: perMetre)
        let camera = MKMapCamera(lookingAtCenter: placement.center.coordinate,
                                 fromDistance: pilotScale * placement.zoomOut / perMetre,
                                 pitch: 0, heading: band.heading)
        if let last = lastCamera, Self.isSame(last, camera, scale: pilotScale * placement.zoomOut) { return }
        // The first framing moves the camera, and in portrait the map's size: the chart's tiles are
        // redrawn once it is at rest. Later ones follow the aircraft, as following it does.
        if lastCamera == nil { redrawsTilesAtRest = true }
        lastCamera = camera
        mapView.setCamera(camera, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func close(_ mapView: MKMapView, mapState: SharedMapState) {
        isOpen = false
        generation += 1
        let closing = generation
        mapView.isScrollEnabled = true
        mapView.isZoomEnabled = true
        mapView.isRotateEnabled = true
        mapView.accessibilityElementsHidden = false
        // Back to the shared state's camera (NavigationMapView writes what the map returns to as the
        // panel closes), on the next turn of the run loop and once the map view has its size back. In
        // portrait it grows back as the panel closes, and MapKit keeps the chart's scale as it grows,
        // not the camera distance: set at the band's size, the pilot's distance came back about twice
        // as far out. So the camera goes back at the pilot's zoom for the size the map has now, grows
        // with it, and is put back exactly once the map is as tall as the pilot left it.
        DispatchQueue.main.async { [weak self, weak mapView] in
            guard let self, let mapView, self.generation == closing else { return }
            let height = self.pilotScalePerMetre?.height ?? mapView.bounds.height
            guard abs(mapView.bounds.height - height) >= 1 else {
                self.finishRestore(mapView, mapState: mapState)
                return
            }
            self.restoring = (mapState, height)
            mapView.setCamera(Self.camera(of: mapState, distanceTimes: mapView.bounds.height / height), animated: false)
            // Should the map not come back to that height (it turned meanwhile), as it stands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak mapView] in
                guard let self, let mapView, self.generation == closing, self.restoring != nil else { return }
                self.finishRestore(mapView, mapState: mapState)
            }
        }
    }

    /// The map closing back to the pilot's camera, and the height it will have then.
    private var restoring: (mapState: SharedMapState, height: CGFloat)?

    private func finishRestore(_ mapView: MKMapView, mapState: SharedMapState) {
        restoring = nil
        if let range = zoomRangeBeforeBand { mapView.cameraZoomRange = range }
        zoomRangeBeforeBand = nil
        // Not animated, and the shared state then synced to what the map shows, as for "Show" on the
        // route pill: nothing may observe a camera half way back and write it into the state.
        mapView.setCamera(Self.camera(of: mapState), animated: false)
        ownsCamera = false
        lastCamera = nil
        Self.redrawTiles(on: mapView)
        mapState.updateFromRegion(mapView.region)
        mapState.endBand()
    }

    /// The shared state's camera; `distanceTimes`: as far, times that.
    private static func camera(of mapState: SharedMapState, distanceTimes: Double = 1) -> MKMapCamera {
        MKMapCamera(lookingAtCenter: mapState.region.center, fromDistance: mapState.cameraDistance * distanceTimes,
                    pitch: 0, heading: mapState.cameraHeading)
    }

    /// The swisstopo charts stop zooming in at a camera distance (`SwissMapView.cameraZoomRange`, tuned
    /// against the tiles there are). In the band's shorter map that distance is a coarser chart than the
    /// pilot had: the closest zoom comes down as far as gives the same chart scale, so the same tiles,
    /// while the band is up.
    /// Only for a map at least 2 % shorter than the pilot's, and changed only by more than 2 %: setting
    /// the range again for the measures' rounding (the landscape band, as tall as the map) left holes in
    /// the chart.
    private func allowPilotsZoom(on mapView: MKMapView, scalePerMetre: Double) {
        guard let range = zoomRangeBeforeBand, let pilot = pilotScalePerMetre, scalePerMetre > 0 else { return }
        let base = range.minCenterCoordinateDistance
        var closest = base * pilot.value / scalePerMetre
        if closest > base * 0.98 { closest = base }
        let current = mapView.cameraZoomRange.minCenterCoordinateDistance
        guard abs(current - closest) > max(1, closest * 0.02),
              let band = MKMapView.CameraZoomRange(minCenterCoordinateDistance: closest,
                                                   maxCenterCoordinateDistance: range.maxCenterCoordinateDistance)
        else { return }
        mapView.cameraZoomRange = band
    }

    /// MapKit draws only some of the tiles it is handed while a still map settles, and sometimes stops
    /// asking for them at all (`LateTileRedraw`): a band that doesn't move (on the ground, in Plan ›
    /// Map, on the simulator's fixed position) showed the chart with holes, or none, until the panel
    /// closed, one opening in three. Once the band's camera is at rest, the overlays' own redraw, and
    /// their reload if the redraw goes unanswered.
    private static func redrawTiles(on mapView: MKMapView) {
        for case let tiles as LateTileRedrawing in mapView.overlays {
            tiles.redraw.tileArrived()
        }
    }

    /// Map points per screen point, across the middle of the map.
    static func scale(of mapView: MKMapView) -> Double? {
        let bounds = mapView.bounds
        guard bounds.width > 100, bounds.height > 1 else { return nil }
        let a = MKMapPoint(mapView.convert(CGPoint(x: bounds.midX - 50, y: bounds.midY), toCoordinateFrom: mapView))
        let b = MKMapPoint(mapView.convert(CGPoint(x: bounds.midX + 50, y: bounds.midY), toCoordinateFrom: mapView))
        let scale = hypot(b.x - a.x, b.y - a.y) / 100
        return scale.isFinite && scale > 0 ? scale : nil
    }

    /// Within half a point, half a percent of zoom and half a degree: not worth moving the camera for.
    private static func isSame(_ a: MKMapCamera, _ b: MKMapCamera, scale: Double) -> Bool {
        let moved = hypot(MKMapPoint(a.centerCoordinate).x - MKMapPoint(b.centerCoordinate).x,
                          MKMapPoint(a.centerCoordinate).y - MKMapPoint(b.centerCoordinate).y) / scale
        let turned = abs(a.heading - b.heading).truncatingRemainder(dividingBy: 360)
        return moved < 0.5
            && abs(a.centerCoordinateDistance / b.centerCoordinateDistance - 1) < 0.005
            && min(turned, 360 - turned) < 0.5
    }

    private static func same(_ a: CLLocationCoordinate2D?, _ b: CLLocationCoordinate2D?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return a.latitude == b.latitude && a.longitude == b.longitude
        default: return false
        }
    }
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
    var vfrContent: VFRMapContent = .empty()  // Traffic circuits, VFR routes and sectors (6.2.0)
    var onWaypointATOTap: ((Int) -> Void)?  // Callback when user taps/long-presses a waypoint to set ATO
    var onAirportDivert: ((String) -> Void)?  // "Divert here" from an airport callout (v5.1)
    /// The open legs panel's band, which then has the camera (`LegsBandDriver`). (6.1, option C)
    var legsBand: LegsPanelMap.Band? = nil

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
            insertTileBelowShapes(overlay, on: mapView)
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

        // Track vector. Only wipe when the feature is OFF; on a transient empty (brief GPS gap / <5 kt)
        // keep the existing vector instead of blanking it. (v4 UI/UX Revamp fix)
        //
        // Replaced only when it moved. The overlays arrive as new objects on every SwiftUI pass, several
        // per GPS fix, and swapping identical ones was most of this function's time in a 30 s Time
        // Profiler trace of the Cockpit's map in cruise (MapKit's removeOverlays + addOverlay, about
        // 460 of 500 ms), plus MapKit redrawing them each time. (v6.0 review, render-perf-001)
        let existingTrackVector = mapView.overlays.compactMap { $0 as? TrackVectorPolyline }
        if !trackVectorEnabled {
            mapView.removeOverlays(existingTrackVector)
            context.coordinator.trackVectorGeometry = []
        } else if !trackVectorOverlays.isEmpty {
            let geometry = TrackVectorPolyline.geometry(of: trackVectorOverlays)
            if geometry != context.coordinator.trackVectorGeometry || existingTrackVector.isEmpty {
                mapView.removeOverlays(existingTrackVector)
                for tv in trackVectorOverlays { mapView.addOverlay(tv, level: .aboveLabels) }
                context.coordinator.trackVectorGeometry = geometry
            }
        }

        // The open legs panel's band has the camera, and the map takes no gesture, until the panel has
        // closed and the camera is back where the pilot left it. (6.1, option C)
        let bandOwnsCamera = context.coordinator.legsBand.update(mapView, band: legsBand, mapState: mapState)

        // Handle heading reset request (user tapped compass)
        if !bandOwnsCamera, mapState.pendingHeadingReset {
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

        // Frame the whole active route ("Show" on the off-screen route pill). MapKit does the
        // aspect-ratio maths; the top inset clears the floating chrome, as the builder's fit does.
        if !bandOwnsCamera, let fit = mapState.pendingFitCoordinates, !fit.isEmpty {
            mapState.pendingFitCoordinates = nil
            let rects = fit.map { MKMapRect(origin: MKMapPoint($0), size: MKMapSize(width: 0, height: 0)) }
            let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            mapView.setVisibleMapRect(union,
                                      edgePadding: UIEdgeInsets(top: 130, left: 50, bottom: 130, right: 50),
                                      animated: false)
            // Sync the shared state to what the map now shows. Without this the next update pass sees
            // a changed region alongside the PRE-FIT `cameraDistance` and re-applies that camera,
            // silently undoing the fit — which looked like "Show" zooming into the middle of the route
            // instead of framing it. Non-animated for the same reason: nothing may observe an
            // in-between state and write it back.
            //
            // On the swisstopo layers the result is CENTRED but may not be fully contained:
            // `cameraZoomRange` caps zoom-out at 600 km because the chart tiles stop existing beyond
            // it, and a long east–west route in a portrait viewport needs more than that. That is the
            // layer's limit, not a framing bug — the route ends up under the pilot's thumb either way.
            mapState.cameraDistance = mapView.camera.centerCoordinateDistance
            mapState.updateFromRegion(mapView.region)
            return
        }

        // Update camera from shared state if significantly different (preserves heading)
        let regionChanged = !context.coordinator.regionsAreEqual(mapView.region, mapState.region)
        if !bandOwnsCamera && regionChanged && !context.coordinator.isUserInteracting {
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
        if !bandOwnsCamera && !regionChanged && !context.coordinator.isUserInteracting {
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

        // Traffic circuits, VFR routes and sectors, under the route: nothing while the content is the
        // one drawn, which is every GPS tick. (6.2.0)
        VFRMapLayer.sync(vfrContent, on: mapView, state: context.coordinator.vfrLayer)

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

        // Skip rebuilding when the visible set hasn't changed since the last update. (PERF-27)
        guard existingIds != newIds else { return }

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
        // Skip rebuilding when the visible set hasn't changed since the last update. (PERF-27)
        guard existingIds != newIds else { return }
        mapView.removeAnnotations(existing.filter { !newIds.contains($0.navaid.id) })
        for navaid in visibleNavaids where !existingIds.contains(navaid.id) {
            mapView.addAnnotation(NavaidAnnotation(navaid: navaid))
        }
    }

    private func updateObstacleAnnotations(_ mapView: MKMapView, context: Context) {
        let existing = mapView.annotations.compactMap { $0 as? ObstacleAnnotation }
        let existingIds = Set(existing.map { $0.obstacle.id })
        let newIds = Set(visibleObstacles.map { $0.id })
        // Skip rebuilding when the visible set hasn't changed since the last update. (PERF-27)
        guard existingIds != newIds else { return }
        mapView.removeAnnotations(existing.filter { !newIds.contains($0.obstacle.id) })
        for obstacle in visibleObstacles where !existingIds.contains(obstacle.id) {
            mapView.addAnnotation(ObstacleAnnotation(obstacle: obstacle))
        }
    }

    private func updateReportingPointAnnotations(_ mapView: MKMapView, context: Context) {
        // Skips rebuilding when the visible set hasn't changed since the last update (PERF-27).
        ReportingPointAnnotation.sync(visibleReportingPoints, on: mapView,
                                      revision: &context.coordinator.reportingPointLabelRevision)
    }

    private func updateFlightPlanOverlay(_ mapView: MKMapView, context: Context) {
        // Last, whatever path is taken below: the route rebuild removes every route polyline, the
        // diversion line included. (v5.1)
        defer { refreshDiversionLine(on: mapView, plan: activeFlightPlan, from: currentLocation) }
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
            .joined(separator: "|") + "@\(currentWaypointIndex)" + "→\(flightPlan.diversion?.ident ?? "")"
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
            // Diverting: the rest of the route stays on the map for "Resume", dimmed. (v5.1)
            remainingPolyline.isCompletedSegment = flightPlan.diversion != nil
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
            insertTileBelowShapes(overlay, on: mapView)
            // The tile just landed above any existing airspace/track/route overlays — re-lift them. (v4.2 layer-switch fix)
            reliftNonTileOverlays(on: mapView)
        } else if !showOpenAIPTiles && hasOverlay {
            let overlaysToRemove = mapView.overlays.filter { $0 is OpenAIPTileOverlay }
            mapView.removeOverlays(overlaysToRemove)
        }
    }

    private func updateAirspaceOverlays(_ mapView: MKMapView, context: Context) {
        AeroCheck.updateAirspaceOverlays(on: mapView, polygons: airspacePolygons)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: NativeMapViewUIKit
        /// The track vector on the map, as `TrackVectorPolyline.geometry(of:)`, so an update only
        /// replaces it when it moved. (v6.0 review)
        var trackVectorGeometry: [Double] = []
        var isUserInteracting = false
        /// Signature of the last-rendered flight plan, so the overlay is rebuilt only on change. (PR-10)
        var lastFlightPlanSignature: String?
        /// `ReportingPointAnnotation.labelRevision` the markers were labelled at. (6.0.1)
        var reportingPointLabelRevision = -1
        /// The open legs panel's band. (6.1, option C)
        let legsBand = LegsBandDriver()
        /// The aerodrome procedures drawn, and their palette. (6.2.0)
        let vfrLayer = VFRMapLayer.State()

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
            // The band moves the camera itself; the map takes no gesture meanwhile.
            guard !legsBand.ownsCamera else { return }
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
            // Its zoom at rest, for the legs panel's band: the pilot's, unless the band has the camera.
            legsBand.mapCameToRest(mapView)
            // The band's camera is not the pilot's: the shared state keeps theirs, to go back to.
            if legsBand.ownsCamera {
                parent.mapState.updateBandRegion(mapView.region)
                return
            }
            parent.mapState.updateFromRegion(mapView.region)
            // Sync camera distance and heading so they're preserved when switching layers
            parent.mapState.updateFromCamera(mapView.camera)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            // OpenAIP tile overlay
            if let tileOverlay = overlay as? OpenAIPTileOverlay {
                return LateTileRedraw.renderer(for: tileOverlay)
            }

            // Traffic circuits, VFR routes and sectors: their own classes, before the generic MKPolyline
            // branch below, which would draw them as the flown track. (6.2.0)
            if let renderer = VFRMapLayer.renderer(for: overlay, palette: vfrLayer.palette) {
                return renderer
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
                if flightPlanPolyline.isDiversion {
                    // Diversion — amber, a non-normal state, so it cannot be mistaken for the planned route. (v5.1)
                    renderer.strokeColor = UIColor(red: 0.898, green: 0.655, blue: 0.227, alpha: 1.0)
                    renderer.lineWidth = 5
                    renderer.lineCap = .round
                    return renderer
                }
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
                renderer.strokeColor = UIColor.flownTrack
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

            // A traffic circuit's altitude or a VFR route's name, and its callout. (6.2.0)
            if let label = VFRMapLayer.annotationView(for: annotation, on: mapView, palette: vfrLayer.palette) {
                return label
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
                // "LSGC Les Eplatures · on request", plus a remark's own line when it has one. (6.0.1)
                rpView.detailCalloutAccessoryView = reportingPointAnnotation.calloutDetailView()
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
            // Ownship: white with a dark outline, the flight-deck convention; gold sank into the ICAO
            // chart's own yellows. (v6.0 · P5)
            let ownshipColor = UIColor.white
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
                let tintedImage = image.withTintColor(ownshipColor, renderingMode: .alwaysOriginal)
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
            // "Divert here", with a route to divert from. Opens the Divert sheet on this field, where the
            // time, runway and the big button are. (v5.1)
            if parent.activeFlightPlan != nil, parent.onAirportDivert != nil {
                let button = UIButton(type: .system)
                button.setImage(UIImage(systemName: "arrow.triangle.turn.up.right.diamond.fill"), for: .normal)
                button.tintColor = UIColor(red: 0.898, green: 0.655, blue: 0.227, alpha: 1.0)
                button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
                button.accessibilityLabel = L10n.Trip.divert
                annotationView.rightCalloutAccessoryView = button
            }

            if let freqLines = annotation.frequencyLines {
                let detailLabel = UILabel()
                detailLabel.numberOfLines = 0

                let attributed = NSMutableAttributedString()
                // Airport name line
                let nameAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.aero(size: 12, weight: .medium),
                    .foregroundColor: UIColor.label
                ]
                attributed.append(NSAttributedString(string: annotation.airport.name + "\n", attributes: nameAttrs))
                // Frequency lines
                let freqAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.aero(size: 12, monospaced: true),
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

        // MARK: - Divert from an airport callout (v5.1)

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                     calloutAccessoryControlTapped control: UIControl) {
            guard let airport = view.annotation as? AirportAnnotation else { return }
            mapView.deselectAnnotation(airport, animated: true)
            parent.onAirportDivert?(airport.airport.ident)
        }

        // MARK: - Waypoint ATO Tap/Long-Press

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            // Nothing on the band answers a tap: no callout, no time over a waypoint. (6.1, option C)
            if legsBand.ownsCamera {
                mapView.deselectAnnotation(annotation, animated: false)
                return
            }
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
            guard gesture.state == .began, !legsBand.ownsCamera,
                  let annotationView = gesture.view as? MKAnnotationView,
                  let waypointAnnotation = annotationView.annotation as? FlightPlanWaypointAnnotation else { return }
            parent.onWaypointATOTap?(waypointAnnotation.waypointIndex)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
}


// MARK: - Map Sheet (iPad, v6.0 · C1)

/// Everything about how the map looks, behind one labelled "Map" button: the base chart, a preset for
/// the phase of flight, then each overlay. It replaces three unlabelled buttons, one of them an
/// airplane that opened the base-chart picker. Opened in flight, so the rows are kneeboard-sized.
struct MapSheet: View {
    @Environment(\.cockpitTheme) private var theme
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var offlineMapManager: OfflineMapManager
    @Binding var selectedLayer: MapLayerType
    let isOfflineMode: Bool
    /// Where the map is, for the aerodrome procedures' missing-data hint. (6.2.0)
    var mapCenter: CLLocationCoordinate2D? = nil
    @State private var showCacheInfo = false

    /// Aeronautical first: the chart a VFR pilot navigates on, then the swisstopo maps, then Apple's.
    private static let baseCharts: [MapLayerType] = [.icao, .landeskarten, .swissimage, .satellite, .standard]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    baseChartSection
                    presetsSection
                    OverlaysSections(mapCenter: mapCenter)
                    MapDataCredits()
                }
                .padding(.vertical, 16)
            }
            .background(theme.background)
            .navigationTitle(L10n.Nav.mapSheet)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Button.done) { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showCacheInfo) {
            CacheInfoSheet(isOfflineMode: isOfflineMode)
                .environment(appState)
                .environmentObject(offlineMapManager)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Base chart

    private var baseChartSection: some View {
        section(L10n.Nav.baseChart) {
            if isOfflineMode {
                // Offline, the cached ICAO chart is the only one there is.
                Button { showCacheInfo = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "internaldrive.fill").font(.aero(size: 20)).foregroundColor(theme.warning)
                        Text(L10n.Nav.offlineICAOOnly)
                            .font(.aero(size: CockpitType.label))
                            .foregroundColor(theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Image(systemName: "info.circle").font(.aero(size: 22)).foregroundColor(theme.action)
                    }
                    .padding(16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                ForEach(Array(Self.baseCharts.enumerated()), id: \.element) { index, layer in
                    if index > 0 { Divider().padding(.leading, 60) }
                    baseChartRow(layer)
                }
            }
        }
    }

    private func baseChartRow(_ layer: MapLayerType) -> some View {
        let selected = selectedLayer == layer
        return Button { selectedLayer = layer } label: {
            HStack(spacing: 12) {
                Image(systemName: layer.icon)
                    .font(.aero(size: 20))
                    .foregroundColor(selected ? theme.action : theme.textSecondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.name(of: layer))
                        .font(.aero(size: CockpitType.label, weight: selected ? .bold : .medium))
                        .foregroundColor(theme.textPrimary)
                    if layer == .icao && !appState.settings.forceICAOChartLayer {
                        Text(L10n.MapLayer.icaoHint)
                            .font(.aero(size: 15))
                            .foregroundColor(theme.textSecondary)
                    }
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.aero(size: 24))
                    .foregroundColor(selected ? theme.action : theme.textDim)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func name(of layer: MapLayerType) -> String {
        switch layer {
        case .icao: return L10n.MapLayer.icao
        case .landeskarten: return L10n.MapLayer.landeskarte
        case .swissimage: return L10n.MapLayer.swissimage
        case .satellite: return L10n.MapLayer.satellite
        case .standard: return L10n.MapLayer.standard
        }
    }

    // MARK: Presets

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L10n.Nav.presets)
            HStack(spacing: 10) {
                ForEach(MapPreset.allCases, id: \.self) { preset in
                    presetButton(preset)
                }
            }
            .padding(.horizontal, 16)
            Text(L10n.Nav.presetsHint)
                .font(.aero(size: 15))
                .foregroundColor(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
        }
    }

    private func presetButton(_ preset: MapPreset) -> some View {
        let active = preset.matches(appState.settings)
        return Button {
            preset.apply(to: &appState.settings)
            appState.saveSettings()
        } label: {
            Text(preset.title)
                .font(.aero(size: CockpitType.label, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundColor(active ? theme.actionText : theme.action)
                .frame(maxWidth: .infinity, minHeight: CockpitTarget.control)
                .background(RoundedRectangle(cornerRadius: 14).fill(active ? theme.action : theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(active ? Color.clear : theme.panelStroke, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: Layout

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.aero(size: 15, weight: .semibold))
            .foregroundColor(theme.textSecondary)
            .padding(.horizontal, 20)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(title)
            VStack(spacing: 0) { content() }
                .background(theme.panel)
                .cornerRadius(12)
                .padding(.horizontal, 16)
        }
    }
}

/// What the map shows for a phase of flight, in one tap. Airspace is on in every preset: it is the
/// layer that keeps a VFR flight legal. (v6.0 · P3)
///
/// Approach and Everything also show the aerodrome procedures (traffic circuits, VFR routes and
/// sectors); Cruise doesn't. The glider, UL and helicopter circuits are left as the pilot set them: an
/// opt-in no preset turns on. (6.2.0)
enum MapPreset: CaseIterable {
    /// Airspace and reporting points: what to avoid and where to call.
    case cruise
    /// Adds the airports, the obstacles around them, and their circuits and VFR routes.
    case approach
    /// Every marker, and the circuits and VFR routes.
    case everything

    var title: String {
        switch self {
        case .cruise: return L10n.Nav.presetCruise
        case .approach: return L10n.Nav.presetApproach
        case .everything: return L10n.Nav.presetEverything
        }
    }

    /// airspace, airports, navaids, reporting points, obstacles, traffic circuits, VFR routes
    private var flags: (airspace: Bool, airports: Bool, navaids: Bool, reportingPoints: Bool, obstacles: Bool,
                        circuits: Bool, vfrRoutes: Bool) {
        switch self {
        case .cruise: return (true, false, false, true, false, false, false)
        case .approach: return (true, true, false, true, true, true, true)
        case .everything: return (true, true, true, true, true, true, true)
        }
    }

    func apply(to settings: inout AppSettings) {
        let f = flags
        settings.showOpenAIPOverlay = f.airspace
        settings.showAirportsOnMap = f.airports
        settings.showNavaidsOnMap = f.navaids
        settings.showReportingPointsOnMap = f.reportingPoints
        settings.showObstaclesOnMap = f.obstacles
        settings.showVFRCircuitsOnMap = f.circuits
        settings.showVFRRoutesOnMap = f.vfrRoutes
    }

    func matches(_ settings: AppSettings) -> Bool {
        let f = flags
        return settings.showOpenAIPOverlay == f.airspace
            && settings.showAirportsOnMap == f.airports
            && settings.showNavaidsOnMap == f.navaids
            && settings.showReportingPointsOnMap == f.reportingPoints
            && settings.showObstaclesOnMap == f.obstacles
            && settings.showVFRCircuitsOnMap == f.circuits
            && settings.showVFRRoutesOnMap == f.vfrRoutes
    }
}

/// The overlay switches (airspace and tiles, markers, track vector), in the Map sheet. (v6.0 · C1)
struct OverlaysSections: View {
    @Environment(\.cockpitTheme) private var theme
    @Environment(AppState.self) private var appState
    @EnvironmentObject var openAIPDataService: OpenAIPDataService
    @EnvironmentObject var dataStatusManager: DataStatusManager
    @ObservedObject private var navaidService = OpenAIPNavaidDataService.shared
    @ObservedObject private var obstacleService = OpenAIPObstacleDataService.shared
    @ObservedObject private var reportingPointService = OpenAIPReportingPointDataService.shared
    @ObservedObject private var vfrProcedureService = OFMDataService.shared
    /// Where the map is: the aerodrome procedures' hint names the country there when its data is missing.
    var mapCenter: CLLocationCoordinate2D? = nil
    /// Settings, opened at Navigation & Maps for the no-data download flow (v4.2 UX fix), or at Data &
    /// Storage for the VFR procedures (6.2.0).
    @State private var settingsSection: SettingsView.Section?

    private var anyMarkerOn: Bool {
        appState.settings.showAirportsOnMap || appState.settings.showNavaidsOnMap ||
        appState.settings.showReportingPointsOnMap || appState.settings.showObstaclesOnMap
    }

    /// Same aging/stale condition that lights the amber badge on the Layers button — gives that badge a
    /// plain-language explanation. (v4.1 follow-up)
    private var airspaceNeedsUpdate: Bool {
        if dataStatusManager.debugForceStale { return true }
        guard openAIPDataService.isDataAvailable, let lastUpdated = openAIPDataService.lastUpdated else { return false }
        let freshness = FreshnessThresholds.aeronautical.freshness(lastUpdated: lastUpdated, now: Date())
        return freshness == .aging || freshness == .stale
    }

    private var isUpdatingAeroData: Bool {
        openAIPDataService.isDownloading || navaidService.isDownloading
            || obstacleService.isDownloading || reportingPointService.isDownloading
            || vfrProcedureService.isDownloading
    }

    var body: some View {
        VStack(spacing: 16) {
            if airspaceNeedsUpdate || isUpdatingAeroData {
                staleDataBanner
            }
            groupCard(L10n.Nav.airspaceCharts) {
                toggleRow(icon: "shield", title: L10n.Nav.airspace, isOn: appState.settings.showOpenAIPOverlay) {
                    appState.settings.showOpenAIPOverlay.toggle(); appState.saveSettings()
                }
                // The toggle can be ON with no data downloaded — the layer then renders
                // nothing. Say so where the user is looking, and route straight to the
                // download flow (country selection lives in Settings → Navigation & Maps;
                // updateAeroData can't help here, it only refreshes existing countries). (v4.2 UX fix)
                if appState.settings.showOpenAIPOverlay && !openAIPDataService.isDataAvailable && !openAIPDataService.isDownloading {
                    Divider().padding(.leading, 56)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.aero(.footnote))
                                .foregroundColor(theme.warning)   // the caution token, not a fixed orange (v6.0 review)
                                .accessibilityHidden(true)
                            Text(L10n.Nav.airspaceNoData)
                                .font(.aero(.caption))
                                .foregroundColor(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button {
                            settingsSection = .navigation
                        } label: {
                            Text(L10n.Nav.downloadAirspaceData)
                                .font(.aero(.caption).weight(.semibold))
                                .foregroundColor(theme.action)
                        }
                        .padding(.leading, 24)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                Divider().padding(.leading, 56)
                toggleRow(icon: "square.grid.3x3", title: L10n.Nav.mapTiles, isOn: appState.settings.showOpenAIPTiles) {
                    appState.settings.showOpenAIPTiles.toggle(); appState.saveSettings()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.Nav.mapMarkers)
                        .font(.aero(size: 13, weight: .semibold))
                        .foregroundColor(theme.textSecondary)
                    Spacer()
                    Button(anyMarkerOn ? L10n.Nav.hideAll : L10n.Nav.showAll) {
                        setAllMarkers(!anyMarkerOn)
                    }
                    .font(.aero(size: 13, weight: .semibold))
                    .foregroundColor(theme.action)
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
                .background(theme.panel)
                .cornerRadius(12)
                .padding(.horizontal, 16)
            }

            aerodromeProceduresCard

            groupCard(L10n.Nav.flightSection) {
                toggleRow(icon: "location.north.line", title: L10n.Nav.trackVector, isOn: appState.settings.showTrackVector) {
                    appState.settings.showTrackVector.toggle(); appState.saveSettings()
                }
            }
        }
        .sheet(item: $settingsSection) { section in
            // Settings opened at a section (same deep-link mechanism as Home's data chip): Navigation &
            // Maps, where country selection + the download flow live (v4.2 UX fix), or Data & Storage.
            SettingsView(initialSection: section)
        }
    }

    // MARK: Aerodrome procedures (6.2.0)

    /// Traffic circuits, VFR arrival and departure routes with their sectors, and the glider, UL and
    /// helicopter circuits, from open flightmaps. All off by default; Approach and Everything turn the
    /// first two on.
    private var aerodromeProceduresCard: some View {
        groupCard(L10n.VFRMap.aerodromeProcedures) {
            toggleRow(icon: "arrow.triangle.capsulepath", title: L10n.VFRMap.showCircuits,
                      isOn: appState.settings.showVFRCircuitsOnMap) {
                appState.settings.showVFRCircuitsOnMap.toggle(); appState.saveSettings()
            }
            Divider().padding(.leading, 56)
            toggleRow(icon: "arrow.triangle.merge", title: L10n.VFRMap.showRoutes,
                      isOn: appState.settings.showVFRRoutesOnMap) {
                appState.settings.showVFRRoutesOnMap.toggle(); appState.saveSettings()
            }
            Divider().padding(.leading, 56)
            toggleRow(icon: "wind", title: L10n.VFRMap.showNonPowered,
                      isOn: appState.settings.showNonPoweredCircuitsOnMap) {
                appState.settings.showNonPoweredCircuitsOnMap.toggle(); appState.saveSettings()
            }
            if let country = vfrCountryWithoutData {
                Divider().padding(.leading, 56)
                Button { settingsSection = .dataStorage } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                            .foregroundColor(theme.action)
                            .accessibilityHidden(true)
                        Text(L10n.VFRMap.downloadHint(country))
                            .font(.aero(size: 15))
                            .foregroundColor(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The country under the map when a procedures switch is on, open flightmaps publishes it, and none
    /// of it is on this device: what the hint asks to download.
    private var vfrCountryWithoutData: String? {
        guard VFRLayerSelection(settings: appState.settings).isAnyOn, let mapCenter,
              !vfrProcedureService.isDownloading else { return nil }
        let supported = Set(vfrProcedureService.supportedCountries)
        let downloaded = Set(vfrProcedureService.downloadedCountries)
        return CountryBoundaries.shared.countries(near: mapCenter, bufferNm: 0)
            .filter { supported.contains($0) && !downloaded.contains($0) }
            .sorted().first
    }

    private func setAllMarkers(_ on: Bool) {
        appState.settings.showAirportsOnMap = on
        appState.settings.showNavaidsOnMap = on
        appState.settings.showReportingPointsOnMap = on
        appState.settings.showObstaclesOnMap = on
        appState.saveSettings()
    }

    /// Worded stale-data warning + inline update, so the Layers-button badge isn't cryptic on its own.
    /// Update re-downloads all OpenAIP layers (airspace + navaids + obstacles + reporting points) for the
    /// cached countries, since they age together, and open flightmaps' VFR procedures. (v4.1 follow-up)
    private var staleDataBanner: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.aero(size: 18))
                    .foregroundColor(theme.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Airspace data is out of date"))
                        .font(.aero(size: 13.5, weight: .semibold))
                        .foregroundColor(theme.warning)
                    Text(String(localized: "It may not reflect recent airspace changes."))
                        .font(.aero(size: 12))
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                if isUpdatingAeroData {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.8)
                        Text(String(localized: "Updating…"))
                            .font(.aero(size: 12.5))
                            .foregroundColor(theme.textSecondary)
                    }
                } else {
                    Button(action: updateAeroData) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise").font(.aero(size: 12, weight: .semibold))
                            Text(String(localized: "Update")).font(.aero(size: 12.5, weight: .semibold))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 9).fill(theme.action))
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.warning.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.warning.opacity(0.4), lineWidth: 1))
        )
        .padding(.horizontal, 16)
    }

    private func updateAeroData() {
        // Refresh the UNION of every layer's downloaded countries — using one layer's set would, with
        // per-layer pruning, shrink the others to it. (download-integrity fix)
        let countries = Array(Set(openAIPDataService.downloadedCountries)
            .union(navaidService.downloadedCountries)
            .union(obstacleService.downloadedCountries)
            .union(reportingPointService.downloadedCountries)
            .union(vfrProcedureService.downloadedCountries))
        guard !countries.isEmpty else { return }
        Task {
            await openAIPDataService.downloadData(for: countries)
            await navaidService.downloadData(for: countries)
            await obstacleService.downloadData(for: countries)
            await reportingPointService.downloadData(for: countries)
            // The circuits and VFR routes of the countries OFM covers, new cycle included. (6.2.0)
            await vfrProcedureService.downloadData(for: countries)
            dataStatusManager.recompute()
        }
    }

    @ViewBuilder
    private func groupCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.aero(size: 13, weight: .semibold))
                .foregroundColor(theme.textSecondary)
                .padding(.horizontal, 20)
            VStack(spacing: 0) { content() }
                .background(theme.panel)
                .cornerRadius(12)
                .padding(.horizontal, 16)
        }
    }

    private func toggleRow(icon: String, title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).font(.aero(size: 20))
                    .foregroundColor(isOn ? theme.action : theme.textSecondary).frame(width: 32)
                // Opened in flight as well, from the iPad Map sheet: kneeboard-size rows. (v6.0 · P6)
                Text(title).font(.aero(size: CockpitType.label, weight: .medium)).foregroundColor(theme.textPrimary)
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.aero(size: 24))
                    .foregroundColor(isOn ? theme.action : theme.textDim)
            }
            .padding(.horizontal, 16).frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The Map sheet's credits: open flightmaps for the circuits and VFR routes, with the cycle on disk,
/// and OpenAIP for the airspace and the markers. (6.2.0; the README said the sheet credited OpenAIP, and
/// it didn't.)
struct MapDataCredits: View {
    @Environment(\.cockpitTheme) private var theme
    @ObservedObject private var vfrProcedureService = OFMDataService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(VFRMapStrings.credit(cycles: vfrProcedureService.cycles.values.map(\.airac)))
            if let attributed = try? AttributedString(markdown: L10n.DataStorage.openAIPAttribution) {
                Text(attributed)
            } else {
                Text(L10n.DataStorage.openAIPAttribution)
            }
        }
        .font(.aero(size: 13))
        .foregroundColor(theme.textSecondary)
        .tint(theme.action)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }
}

// MARK: - Swiss Map View (UIKit Wrapper)

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
    var vfrContent: VFRMapContent = .empty()  // Traffic circuits, VFR routes and sectors (6.2.0)
    var onWaypointATOTap: ((Int) -> Void)?  // Callback when user taps/long-presses a waypoint to set ATO
    var onAirportDivert: ((String) -> Void)?  // "Divert here" from an airport callout (v5.1)
    /// The open legs panel's band, which then has the camera (`LegsBandDriver`). (6.1, option C)
    var legsBand: LegsPanelMap.Band? = nil

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
                // The layer the map shows NOW, as the coordinator last set it, not the one this view
                // was made with: Plan › Map and the Cockpit's MAP pane are made on ICAO and switched
                // to the pilot's layer by the first update, before this runs. Re-adding the make-time
                // ICAO chart under SWISSIMAGE or the national map left it past its last tile level,
                // blank, and the coordinator (still on the pilot's layer) never put it right. (6.1.0)
                let coordinator = context.coordinator
                let layer = coordinator.currentLayerType ?? self.layerType

                // Set correct zoom range
                mapView.cameraZoomRange = cameraZoomRange(for: layer, forceICAO: coordinator.currentForceICAO)

                // Re-add the overlay
                if layer == .icao {
                    let overlay = ICAOSegelflugkarteTileOverlay(
                        forceICAO: coordinator.currentForceICAO,
                        offlineMapManager: coordinator.offlineMapManager,
                        isStrictOfflineMode: coordinator.isStrictOfflineMode,
                        hasSegelflugCache: coordinator.hasSegelflugCache
                    )
                    overlay.canReplaceMapContent = true
                    insertTileBelowShapes(overlay, on: mapView)
                } else if let layerId = layer.swisstopoLayerIdentifier {
                    let overlay = SwisstopoTileOverlay(
                        layerIdentifier: layerId,
                        tileExtension: layer.tileExtension,
                        minimumZ: layer.minimumZoom,
                        maximumZ: layer.maximumZoom
                    )
                    overlay.canReplaceMapContent = true
                    insertTileBelowShapes(overlay, on: mapView)
                }

                // Re-add OpenAIP tile overlay if it was enabled (removed above with all MKTileOverlays)
                if self.showOpenAIPTiles {
                    let openAIPOverlay = OpenAIPTileOverlay(
                        cacheManager: self.openAIPCacheManager,
                        isStrictOfflineMode: coordinator.isStrictOfflineMode
                    )
                    insertTileBelowShapes(openAIPOverlay, on: mapView)
                }

                // The base tile was just re-added on TOP (same .aboveLabels level), which buries the
                // flight-plan route line. Invalidate the route diff-guard so the next updateUIView
                // redraws the route above the tile. (v4 UI/UX Revamp fix — route line was invisible on Swiss layers)
                context.coordinator.lastFlightPlanSignature = nil
                // And re-lift any other overlays (airspace etc.) the fresh tile just buried. (v4.2 layer-switch fix)
                reliftNonTileOverlays(on: mapView)

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
        // The open legs panel's band has the camera, and the map takes no gesture, until the panel has
        // closed and the camera is back where the pilot left it. (6.1, option C)
        let bandOwnsCamera = context.coordinator.legsBand.update(mapView, band: legsBand, mapState: mapState)

        // Handle heading reset request (user tapped compass)
        if !bandOwnsCamera, mapState.pendingHeadingReset {
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

        // Frame the whole active route ("Show" on the off-screen route pill). MapKit does the
        // aspect-ratio maths; the top inset clears the floating chrome, as the builder's fit does.
        if !bandOwnsCamera, let fit = mapState.pendingFitCoordinates, !fit.isEmpty {
            mapState.pendingFitCoordinates = nil
            let rects = fit.map { MKMapRect(origin: MKMapPoint($0), size: MKMapSize(width: 0, height: 0)) }
            let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            mapView.setVisibleMapRect(union,
                                      edgePadding: UIEdgeInsets(top: 130, left: 50, bottom: 130, right: 50),
                                      animated: false)
            // Sync the shared state to what the map now shows. Without this the next update pass sees
            // a changed region alongside the PRE-FIT `cameraDistance` and re-applies that camera,
            // silently undoing the fit — which looked like "Show" zooming into the middle of the route
            // instead of framing it. Non-animated for the same reason: nothing may observe an
            // in-between state and write it back.
            //
            // On the swisstopo layers the result is CENTRED but may not be fully contained:
            // `cameraZoomRange` caps zoom-out at 600 km because the chart tiles stop existing beyond
            // it, and a long east–west route in a portrait viewport needs more than that. That is the
            // layer's limit, not a framing bug — the route ends up under the pilot's thumb either way.
            mapState.cameraDistance = mapView.camera.centerCoordinateDistance
            mapState.updateFromRegion(mapView.region)
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
        // Not while the legs panel's band holds a closer one (`LegsBandDriver`). (6.1, option C)
        if !bandOwnsCamera, mapView.cameraZoomRange != newZoomRange {
            mapView.cameraZoomRange = newZoomRange
        }

        // Update OpenAIP tile overlay
        let hasOpenAIPOverlay = mapView.overlays.contains(where: { $0 is OpenAIPTileOverlay })
        var tilesTouched = overlayChanged
        if showOpenAIPTiles && !hasOpenAIPOverlay {
            let openAIPOverlay = OpenAIPTileOverlay(
                cacheManager: openAIPCacheManager,
                isStrictOfflineMode: isStrictOfflineMode
            )
            insertTileBelowShapes(openAIPOverlay, on: mapView)
            tilesTouched = true
        } else if !showOpenAIPTiles && hasOpenAIPOverlay {
            let overlaysToRemove = mapView.overlays.filter { $0 is OpenAIPTileOverlay }
            mapView.removeOverlays(overlaysToRemove)
        }

        // A layer switch / tile toggle just added fresh tiles above the existing airspace/track/route
        // overlays — re-lift them or they stay buried. (v4.2 layer-switch fix)
        if tilesTouched {
            reliftNonTileOverlays(on: mapView)
        }

        // Update airspace polygon overlays (incremental diff, shared with NativeMapViewUIKit)
        updateAirspaceOverlays(on: mapView, polygons: airspacePolygons)

        // Track vector. Only wipe when the feature is OFF; on a transient empty (brief GPS gap / <5 kt)
        // keep the existing vector instead of blanking it. (v4 UI/UX Revamp fix)
        //
        // Replaced only when it moved. The overlays arrive as new objects on every SwiftUI pass, several
        // per GPS fix, and swapping identical ones was most of this function's time in a 30 s Time
        // Profiler trace of the Cockpit's map in cruise (MapKit's removeOverlays + addOverlay, about
        // 460 of 500 ms), plus MapKit redrawing them each time. (v6.0 review, render-perf-001)
        let existingTrackVector = mapView.overlays.compactMap { $0 as? TrackVectorPolyline }
        if !trackVectorEnabled {
            mapView.removeOverlays(existingTrackVector)
            context.coordinator.trackVectorGeometry = []
        } else if !trackVectorOverlays.isEmpty {
            let geometry = TrackVectorPolyline.geometry(of: trackVectorOverlays)
            if geometry != context.coordinator.trackVectorGeometry || existingTrackVector.isEmpty {
                mapView.removeOverlays(existingTrackVector)
                for tv in trackVectorOverlays { mapView.addOverlay(tv, level: .aboveLabels) }
                context.coordinator.trackVectorGeometry = geometry
            }
        }

        // Update camera from shared state (preserves heading)
        let regionChanged = !context.coordinator.regionsAreEqual(mapView.region, mapState.region)
        if overlayChanged && !bandOwnsCamera {
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
        } else if !bandOwnsCamera && regionChanged && !context.coordinator.isUserInteracting {
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
        if !bandOwnsCamera && !regionChanged && !overlayChanged && !context.coordinator.isUserInteracting {
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
            Self.removeTrackForRecolour(on: mapView)
        }

        // Update track overlay
        updateTrackOverlay(mapView, context: context)

        // Update flight plan overlay
        updateFlightPlanOverlay(mapView, context: context)

        // Traffic circuits, VFR routes and sectors, under the route: nothing while the content is the
        // one drawn, which is every GPS tick. (6.2.0)
        VFRMapLayer.sync(vfrContent, on: mapView, state: context.coordinator.vfrLayer)

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

        // Skip rebuilding when the visible set hasn't changed since the last update. (PERF-27)
        guard existingIds != newIds else { return }

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

    /// A layer switch takes the flown track off, so it comes back in the colour of the new layer (magenta
    /// on the ICAO chart). Only the track: this removed every `MKPolyline` but the route, the tiles and
    /// the track vector, which would have taken the aerodrome procedures with it. (6.2.0)
    static func removeTrackForRecolour(on mapView: MKMapView) {
        let track = mapView.overlays.filter { $0 is GPSTrackPolyline }
        if !track.isEmpty { mapView.removeOverlays(track) }
    }

    private func updateNavaidAnnotations(_ mapView: MKMapView, context: Context) {
        let existing = mapView.annotations.compactMap { $0 as? NavaidAnnotation }
        let existingIds = Set(existing.map { $0.navaid.id })
        let newIds = Set(visibleNavaids.map { $0.id })
        // Skip rebuilding when the visible set hasn't changed since the last update. (PERF-27)
        guard existingIds != newIds else { return }
        mapView.removeAnnotations(existing.filter { !newIds.contains($0.navaid.id) })
        for navaid in visibleNavaids where !existingIds.contains(navaid.id) {
            mapView.addAnnotation(NavaidAnnotation(navaid: navaid))
        }
    }

    private func updateObstacleAnnotations(_ mapView: MKMapView, context: Context) {
        let existing = mapView.annotations.compactMap { $0 as? ObstacleAnnotation }
        let existingIds = Set(existing.map { $0.obstacle.id })
        let newIds = Set(visibleObstacles.map { $0.id })
        // Skip rebuilding when the visible set hasn't changed since the last update. (PERF-27)
        guard existingIds != newIds else { return }
        mapView.removeAnnotations(existing.filter { !newIds.contains($0.obstacle.id) })
        for obstacle in visibleObstacles where !existingIds.contains(obstacle.id) {
            mapView.addAnnotation(ObstacleAnnotation(obstacle: obstacle))
        }
    }

    private func updateReportingPointAnnotations(_ mapView: MKMapView, context: Context) {
        // Skips rebuilding when the visible set hasn't changed since the last update (PERF-27).
        ReportingPointAnnotation.sync(visibleReportingPoints, on: mapView,
                                      revision: &context.coordinator.reportingPointLabelRevision)
    }

    private func updateFlightPlanOverlay(_ mapView: MKMapView, context: Context) {
        // Last, whatever path is taken below: the route rebuild removes every route polyline, the
        // diversion line included. (v5.1)
        defer { refreshDiversionLine(on: mapView, plan: activeFlightPlan, from: currentLocation) }
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
            .joined(separator: "|") + "@\(currentWaypointIndex)" + "→\(flightPlan.diversion?.ident ?? "")"
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
            // Diverting: the rest of the route stays on the map for "Resume", dimmed. (v5.1)
            remainingPolyline.isCompletedSegment = flightPlan.diversion != nil
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
            insertTileBelowShapes(overlay, on: mapView)
        } else if let layerId = layerType.swisstopoLayerIdentifier {
            let overlay = SwisstopoTileOverlay(
                layerIdentifier: layerId,
                tileExtension: layerType.tileExtension,
                minimumZ: layerType.minimumZoom,
                maximumZ: layerType.maximumZoom
            )
            overlay.canReplaceMapContent = true
            insertTileBelowShapes(overlay, on: mapView)
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
        /// The track vector on the map, as `TrackVectorPolyline.geometry(of:)`, so an update only
        /// replaces it when it moved. (v6.0 review)
        var trackVectorGeometry: [Double] = []
        /// Signature of the last-rendered flight plan, so the overlay is rebuilt only on change. (PR-10)
        var lastFlightPlanSignature: String?
        /// `ReportingPointAnnotation.labelRevision` the markers were labelled at. (6.0.1)
        var reportingPointLabelRevision = -1
        var currentLayerType: MapLayerType?
        var currentForceICAO: Bool = false
        var offlineMapManager: OfflineMapManager?
        var isStrictOfflineMode: Bool = false
        var hasSegelflugCache: Bool = false
        private var isUpdatingRegion = false
        var isUserInteracting = false
        /// The open legs panel's band. (6.1, option C)
        let legsBand = LegsBandDriver()
        /// The aerodrome procedures drawn, and their palette. (6.2.0)
        let vfrLayer = VFRMapLayer.State()

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
                insertTileBelowShapes(overlay, on: mapView)
            } else if let layerId = layerType.swisstopoLayerIdentifier {
                let overlay = SwisstopoTileOverlay(
                    layerIdentifier: layerId,
                    tileExtension: layerType.tileExtension,
                    minimumZ: layerType.minimumZoom,
                    maximumZ: layerType.maximumZoom
                )
                overlay.canReplaceMapContent = true
                insertTileBelowShapes(overlay, on: mapView)
            }

            return true
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // The band moves the camera itself; the map takes no gesture meanwhile.
            guard !legsBand.ownsCamera else { return }
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
            // Its zoom at rest, for the legs panel's band: the pilot's, unless the band has the camera.
            legsBand.mapCameToRest(mapView)
            // The band's camera is not the pilot's: the shared state keeps theirs, to go back to.
            if legsBand.ownsCamera {
                parent.mapState.updateBandRegion(mapView.region)
                return
            }
            guard !isUpdatingRegion else { return }
            isUpdatingRegion = true
            parent.mapState.updateFromRegion(mapView.region)
            // Sync camera distance and heading so they're preserved when switching layers
            parent.mapState.updateFromCamera(mapView.camera)
            isUpdatingRegion = false
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            // Traffic circuits, VFR routes and sectors: their own classes, before the generic MKPolyline
            // branch below, which would draw them in the flown track's colour. (6.2.0)
            if let renderer = VFRMapLayer.renderer(for: overlay, palette: vfrLayer.palette) {
                return renderer
            }

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
                return LateTileRedraw.renderer(for: tileOverlay)
            }

            // Flight plan route (magenta - high visibility on aviation charts)
            if let flightPlanPolyline = overlay as? FlightPlanRoutePolyline {
                let renderer = MKPolylineRenderer(polyline: flightPlanPolyline)
                if flightPlanPolyline.isDiversion {
                    // Diversion — amber, a non-normal state, so it cannot be mistaken for the planned route. (v5.1)
                    renderer.strokeColor = UIColor(red: 0.898, green: 0.655, blue: 0.227, alpha: 1.0)
                    renderer.lineWidth = 5
                    renderer.lineCap = .round
                    return renderer
                }
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
                    renderer.strokeColor = UIColor.flownTrack
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

            // A traffic circuit's altitude or a VFR route's name, and its callout. (6.2.0)
            if let label = VFRMapLayer.annotationView(for: annotation, on: mapView, palette: vfrLayer.palette) {
                return label
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
                // "LSGC Les Eplatures · on request", plus a remark's own line when it has one. (6.0.1)
                rpView.detailCalloutAccessoryView = reportingPointAnnotation.calloutDetailView()
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
            // Ownship: white with a dark outline, the flight-deck convention; gold sank into the ICAO
            // chart's own yellows. (v6.0 · P5)
            let ownshipColor = UIColor.white
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
                let tintedImage = image.withTintColor(ownshipColor, renderingMode: .alwaysOriginal)
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
            // "Divert here", with a route to divert from. Opens the Divert sheet on this field, where the
            // time, runway and the big button are. (v5.1)
            if parent.activeFlightPlan != nil, parent.onAirportDivert != nil {
                let button = UIButton(type: .system)
                button.setImage(UIImage(systemName: "arrow.triangle.turn.up.right.diamond.fill"), for: .normal)
                button.tintColor = UIColor(red: 0.898, green: 0.655, blue: 0.227, alpha: 1.0)
                button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
                button.accessibilityLabel = L10n.Trip.divert
                annotationView.rightCalloutAccessoryView = button
            }

            if let freqLines = annotation.frequencyLines {
                let detailLabel = UILabel()
                detailLabel.numberOfLines = 0

                let attributed = NSMutableAttributedString()
                // Airport name line
                let nameAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.aero(size: 12, weight: .medium),
                    .foregroundColor: UIColor.label
                ]
                attributed.append(NSAttributedString(string: annotation.airport.name + "\n", attributes: nameAttrs))
                // Frequency lines
                let freqAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.aero(size: 12, monospaced: true),
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

        // MARK: - Divert from an airport callout (v5.1)

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                     calloutAccessoryControlTapped control: UIControl) {
            guard let airport = view.annotation as? AirportAnnotation else { return }
            mapView.deselectAnnotation(airport, animated: true)
            parent.onAirportDivert?(airport.airport.ident)
        }

        // MARK: - Waypoint ATO Tap/Long-Press

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            // Nothing on the band answers a tap: no callout, no time over a waypoint. (6.1, option C)
            if legsBand.ownsCamera {
                mapView.deselectAnnotation(annotation, animated: false)
                return
            }
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
            guard gesture.state == .began, !legsBand.ownsCamera,
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
    /// The straight line from the aircraft to a diversion field. (v5.1)
    var isDiversion: Bool = false
    var diversionIdent: String?
}

/// Draw — or keep — the line from the aircraft to the diversion field. Shared by both map
/// representables. Rebuilt only once the aircraft has moved ~150 m or the field changed, so it follows
/// the aircraft without redrawing on every fix. (v5.1)
func refreshDiversionLine(on mapView: MKMapView, plan: FlightPlan?, from location: CLLocation?) {
    let existing = mapView.overlays.compactMap { $0 as? FlightPlanRoutePolyline }.filter(\.isDiversion)
    guard let diversion = plan?.diversion, let location else {
        if !existing.isEmpty { mapView.removeOverlays(existing) }
        return
    }
    if existing.count == 1, let line = existing.first, line.diversionIdent == diversion.ident, line.pointCount == 2 {
        var start = CLLocationCoordinate2D()
        line.getCoordinates(&start, range: NSRange(location: 0, length: 1))
        if CLLocation(latitude: start.latitude, longitude: start.longitude).distance(from: location) < 150 { return }
    }
    mapView.removeOverlays(existing)
    let line = FlightPlanRoutePolyline(coordinates: [location.coordinate, diversion.coordinate], count: 2)
    line.isDiversion = true
    line.diversionIdent = diversion.ident
    mapView.addOverlay(line, level: .aboveLabels)
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
class TrackVectorPolyline: MKPolyline {
    /// Every point of every segment, in order, with each segment's class and length: equal when the
    /// vector drawn would be the same.
    static func geometry(of overlays: [MKPolyline]) -> [Double] {
        overlays.flatMap { polyline -> [Double] in
            let points = UnsafeBufferPointer(start: polyline.points(), count: polyline.pointCount)
            return [polyline is TrackVectorCasingPolyline ? 1 : 0, Double(polyline.pointCount)]
                + points.flatMap { [$0.x, $0.y] }
        }
    }
}

/// The dark casing drawn under each track-vector segment for legibility on any map. (v4 UI/UX Revamp fix)
class TrackVectorCasingPolyline: TrackVectorPolyline {}

// MARK: - Swisstopo tile overlays
// `ICAOSegelflugkarteTileOverlay` and `SwisstopoTileOverlay` moved to the shared
// `Services/SwisstopoTileOverlays.swift` (v4 UI/UX Revamp design-system consolidation — they were
// duplicated as `WaypointPicker*` in FlightPlanEditorView). All map consumers use them from there.

// MARK: - GPS Status Info Sheet

/// Modal sheet explaining GPS status indicators
/// GPS Status modal — presented via .fullScreenCover as a centered card over dimmed background
struct GPSStatusInfoSheet: View {
    @Environment(\.cockpitTheme) private var theme
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
        case .good: return theme.onTarget
        case .degraded: return .orange
        case .lost: return theme.danger
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
                    .font(.aero(size: 40))
                    .foregroundColor(theme.action)
                    .padding(.top, 24)

                // Title
                Text(L10n.GPS.statusTitle)
                    .font(.aero(size: 18, weight: .bold))
                    .foregroundColor(theme.textPrimary)

                // Current status
                HStack {
                    Text(L10n.GPS.currentStatus)
                        .font(.aero(size: 14))
                        .foregroundColor(theme.textSecondary)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(currentStatusColor)
                            .frame(width: 10, height: 10)
                        Text(currentStatusText)
                            .font(.aero(size: 14, weight: .semibold))
                            .foregroundColor(currentStatusColor)
                    }
                }
                .padding(.horizontal, 20)

                Divider()
                    .padding(.horizontal, 16)

                // Status explanations
                VStack(spacing: 14) {
                    statusRow(
                        color: theme.onTarget,
                        title: L10n.GPS.signalGood,
                        description: L10n.GPS.statusGoodDesc
                    )
                    statusRow(
                        color: .orange,
                        title: L10n.GPS.signalDegraded,
                        description: L10n.GPS.statusDegradedDesc
                    )
                    statusRow(
                        color: theme.danger,
                        title: L10n.GPS.signalLost,
                        description: L10n.GPS.statusLostDesc
                    )
                }
                .padding(.horizontal, 20)

                // Done button
                Button(action: { isPresented = false }) {
                    Text(L10n.Button.done)
                        .font(.aero(size: 15, weight: .semibold))
                        .foregroundColor(theme.action)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .background(theme.background)
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
                    .font(.aero(size: 14, weight: .semibold))
                    .foregroundColor(theme.textPrimary)
                Text(description)
                    .font(.aero(size: 12))
                    .foregroundColor(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Cache Info Sheet

/// Modal sheet explaining cache status and usage
struct CacheInfoSheet: View {
    @Environment(\.cockpitTheme) private var theme
    let isOfflineMode: Bool
    @Environment(AppState.self) private var appState
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
                    .font(.aero(size: 40))
                    .foregroundColor(isOfflineMode ? theme.danger : theme.action)
                    .padding(.top, 20)

                // Title
                Text(isOfflineMode ? L10n.Nav.offlineModeActive : L10n.Nav.usingCachedCharts)
                    .font(.aero(size: 18, weight: .bold))
                    .foregroundColor(theme.textPrimary)

                // Description
                VStack(spacing: 8) {
                    if isOfflineMode {
                        if hasFullOfflineSupport {
                            Text(L10n.Nav.offlineDesc)
                                .font(.aero(size: 13))
                                .foregroundColor(theme.textSecondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(L10n.Nav.offlineICAOOnly)
                                .font(.aero(size: 13))
                                .foregroundColor(theme.textSecondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(L10n.Nav.downloadSegelflugkarteDesc)
                                .font(.aero(size: 11))
                                .foregroundColor(theme.warning)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(L10n.Nav.cachedChartsDesc)
                            .font(.aero(size: 13))
                            .foregroundColor(theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(L10n.Nav.cachedTilesDesc)
                            .font(.aero(size: 11))
                            .foregroundColor(theme.textDim)
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
                                .foregroundColor(theme.textSecondary)
                            Spacer()
                            Text(offlineMapManager.cacheVersion)
                                .foregroundColor(theme.onTarget)
                        }
                    }

                    // Segelflug Cache
                    HStack {
                        Text(L10n.Nav.segelflugkarte)
                            .foregroundColor(theme.textSecondary)
                        Spacer()
                        if offlineMapManager.isSegelflugCacheAvailable {
                            Text(offlineMapManager.segelflugCacheVersion)
                                .foregroundColor(theme.onTarget)
                        } else {
                            Text(L10n.Nav.notCached)
                                .foregroundColor(theme.textDim)
                        }
                    }

                    HStack {
                        Text(L10n.Nav.totalSize)
                            .foregroundColor(theme.textSecondary)
                        Spacer()
                        Text(offlineMapManager.formattedCacheSize)
                            .foregroundColor(theme.textPrimary)
                    }
                }
                .font(.aero(size: 11))
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.panel)
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
                            .font(.aero(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.onTarget)
                            )
                        }
                        .padding(.horizontal, 16)

                        // Stay Offline button (secondary)
                        Button(action: { dismiss() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "wifi.slash")
                                Text(L10n.Nav.stayOffline)
                            }
                            .font(.aero(size: 14, weight: .medium))
                            .foregroundColor(theme.danger.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(theme.danger.opacity(0.15))
                            )
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.bottom, 16)
                }
            }
            .background(theme.background)
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
        .environment(AppState())
        .environmentObject(LocationManager())
        .environmentObject(OfflineMapManager())
        .environmentObject(OpenAIPCacheManager())
        .environmentObject(OpenAIPDataService())
        .environmentObject(FlightEventDetector())
        .environmentObject(DataStatusManager(providers: [], networkMonitor: NetworkMonitor(stub: .disconnected)))
}

/// The open legs-and-frequencies panel's natural height, measured inside its scroll view.
private struct LegsPanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The height of Emergency, pinned to the open panel's foot. (6.1, option C)
private struct EmergencyFooterHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// What the chart measures of itself, in its own space, for the band the open legs panel leaves
/// (`LegsPanelMap.bandRect`). (6.1, option C)
private struct ChartGeometry: Equatable {
    var chartSize: CGSize = .zero
    /// The bottom of the chrome over the chart's top: the next-waypoint card, and what comes and goes
    /// with it (the cautions, a hazard).
    var chromeBottom: CGFloat = 0
    /// The map view's frame, which runs past the chart under a safe area.
    var mapFrame: CGRect = .zero
    /// How much of the chart's foot the panel lies over: in landscape, where it opens over the chart.
    var panelInset: CGFloat = 0
    /// Whether these are the measures with the panel open. The pass that opens it still has the closed
    /// chart's (the map's controls under the card, in portrait a taller chart).
    var measuredOpen = false
}

/// One reader each, but the views beside it hand in the default too: a reader's value is never zero.
private struct ChartSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct MapAccessoryHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ChartChromeBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ChartMapFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct ChartMeasuredOpenKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct ChartPanelInsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Buttons side by side or one above the other, all one width: Divert and More, in the thumb bar and
/// beside MARK in the landscape columns. More is a `Menu`, which sizes to its label, so it came out
/// narrower than Divert, and much narrower in French ("Plus" beside "Déroutement"). (6.1, device check)
///
/// The pair takes the room the two buttons want, so MARK and the check slot beside it keep theirs:
/// one above the other, the wider one's width, as a stack of the two took; side by side, half of
/// both, the longer word a little smaller (its label scales down to 0.7) and the shorter one's button
/// wider. As wide as the wider side by side, the pair left MARK and the slot about 55 pt each on a
/// phone in French. Each button must fill the width it is offered (`maxWidth: .infinity`); the pair
/// keeps its width whatever it is offered, and MARK gives.
struct EqualWidthStack: Layout {
    var axis: Axis = .vertical
    var spacing: CGFloat = 8

    /// The one width, from what each button wants.
    static func buttonWidth(ideals: [CGFloat], axis: Axis) -> CGFloat {
        guard !ideals.isEmpty else { return 0 }
        switch axis {
        case .vertical: return ideals.max() ?? 0
        case .horizontal: return ideals.reduce(0, +) / CGFloat(ideals.count)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = buttonWidth(subviews)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let gaps = spacing * CGFloat(subviews.count - 1)
        switch axis {
        case .vertical:
            return CGSize(width: width, height: heights.reduce(0, +) + gaps)
        case .horizontal:
            return CGSize(width: width * CGFloat(subviews.count) + gaps, height: heights.max() ?? 0)
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = buttonWidth(subviews)
        var origin = bounds.origin
        for subview in subviews {
            let height = axis == .horizontal
                ? bounds.height
                : subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            subview.place(at: origin, proposal: ProposedViewSize(width: width, height: height))
            switch axis {
            case .vertical: origin.y += height + spacing
            case .horizontal: origin.x += width + spacing
            }
        }
    }

    private func buttonWidth(_ subviews: Subviews) -> CGFloat {
        Self.buttonWidth(ideals: subviews.map { $0.sizeThatFits(.unspecified).width }, axis: axis)
    }
}

/// The map's bottom row in flight with the check slot: the slot, then the rest of the row (MARK with
/// Divert and More; GO AROUND and TOUCH-AND-GO; Routes). The slot keeps one frame whatever follows it,
/// as wide as MARK beside Divert and More: half of what Divert and More leave. In circuits the row
/// changes every lap, at circuit height and again on the runway, and the slot moved to the middle of it
/// each time. (6.1, the author's call: the slot stays left)
///
/// Three subviews: the slot, Divert and More as a hidden measure (`reference`, laid out but never seen),
/// and the rest of the row, which takes the width the slot leaves.
struct CheckSlotRowLayout: Layout {
    var spacing: CGFloat

    /// The slot's width in a row `rowWidth` wide, beside Divert and More `reference` wide.
    static func slotWidth(rowWidth: CGFloat, reference: CGFloat, spacing: CGFloat) -> CGFloat {
        max(0, (rowWidth - reference - 2 * spacing) / 2)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let width = rowWidth(proposal, subviews)
        let slot = Self.slotWidth(rowWidth: width, reference: referenceWidth(subviews), spacing: spacing)
        let rest = max(0, width - slot - spacing)
        let height = max(subviews[0].sizeThatFits(ProposedViewSize(width: slot, height: proposal.height)).height,
                         subviews[2].sizeThatFits(ProposedViewSize(width: rest, height: proposal.height)).height)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let slot = Self.slotWidth(rowWidth: bounds.width, reference: referenceWidth(subviews), spacing: spacing)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: slot, height: bounds.height))
        // Hidden: it only measures.
        subviews[1].place(at: bounds.origin, proposal: .unspecified)
        subviews[2].place(at: CGPoint(x: bounds.minX + slot + spacing, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: max(0, bounds.width - slot - spacing), height: bounds.height))
    }

    private func referenceWidth(_ subviews: Subviews) -> CGFloat {
        subviews[1].sizeThatFits(.unspecified).width
    }

    /// The width offered, or with none (or no bound), what the row wants: a slot as wide as the rest's.
    private func rowWidth(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        if let width = proposal.width, width.isFinite { return width }
        let reference = referenceWidth(subviews)
        let slot = subviews[0].sizeThatFits(.unspecified).width
        return 2 * slot + reference + 2 * spacing
    }
}

/// The next waypoint's figures, as the card and the phone's line show them, and the widest value each
/// format gives. B612 Mono draws every character the same width, so the widest is the longest. (6.1,
/// stability)
enum NextWaypointReadout {
    /// "206°"
    static func bearing(_ degrees: Double) -> String { String(format: "%03d°", Int(degrees)) }

    /// "9.9", without its unit.
    static func distance(_ nauticalMiles: Double) -> String { String(format: "%.1f", nauticalMiles) }

    /// ETE in minutes, "13 min", or "1:07 h" past the hour. As "13:07" beside an ETA of "13:58" it
    /// read as a clock time.
    static func eteValue(_ ete: TimeInterval) -> String {
        let minutes = Int((ete / 60).rounded())
        return minutes < 60 ? "\(minutes)" : String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    static func eteUnit(_ ete: TimeInterval) -> String {
        Int((ete / 60).rounded()) < 60 ? "min" : "h"
    }

    /// The clock time, as the device writes it.
    static func eta(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static let widestBearing = "000°"
    /// Up to 999.9 NM: further away than that, the cell's value shrinks rather than widening it.
    static let widestDistance = "000.0"
    /// The ETE's two forms: up to 59 min, then up to 9:59 h.
    static let widestMinutes = NavValueCell.Reading("00", unit: "min")
    static let widestHours = NavValueCell.Reading("0:00", unit: "h")

    /// A clock time with two digits to its hour (and AM or PM where the device writes them).
    static var widestETA: String {
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 1
        components.hour = 22
        components.minute = 58
        return Calendar.current.date(from: components).map(eta) ?? "00:00"
    }

    /// The phone's line, "206° ·  9.9 NM · 12 min": every figure right-aligned in a field as long as its
    /// widest, and "—" where there is none yet (no fix; under 30 kt, no ETE), so the line keeps one
    /// length. Dropping a missing figure, as the line did, moved the others at the take-off. The
    /// distance's field holds 99.9 NM; a farther waypoint lengthens it by a character.
    static func phoneLine(bearing: String?, distance: String?, ete: TimeInterval?) -> String {
        let eteText = ete.map { "\(eteValue($0)) \(eteUnit($0))" }
        return [padded(bearing ?? "—", to: 4),
                padded(distance ?? "—", to: 4) + " NM",
                padded(eteText ?? "—", to: 6)].joined(separator: " · ")
    }

    private static func padded(_ text: String, to length: Int) -> String {
        String(repeating: " ", count: max(0, length - text.count)) + text
    }
}

/// A label over a value, for the next-waypoint card. As wide as the widest value its format gives
/// (`widest`, and `orWidest` for a format with two forms), whatever it shows now: each cell took its
/// value's width, so 10.0 → 9.9 NM, 59 min → 1:00 h or a figure → "—" slid the cells to its left, and
/// could flip the card to another of its layouts, as much as 59 pt taller. (6.1, stability)
struct NavValueCell: View {
    struct Reading: Equatable {
        let value: String
        var unit: String?

        init(_ value: String, unit: String? = nil) {
            self.value = value
            self.unit = unit
        }
    }

    let label: String
    let reading: Reading
    let widest: Reading
    var orWidest: Reading?

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.aero(size: CockpitType.label, weight: .semibold))
                .foregroundColor(theme.textSecondary)
            // The widest, unseen, sizes the cell; the value sits over it, from its left edge.
            ZStack(alignment: .leading) {
                line(widest)
                if let orWidest { line(orWidest) }
            }
            .hidden()
            .accessibilityHidden(true)
            .overlay(alignment: .leading) {
                line(reading)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func line(_ reading: Reading) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(reading.value)
                .font(.aero(size: CockpitType.response, weight: .bold, design: .monospaced))
                .foregroundColor(theme.textPrimary)
            if let unit = reading.unit {
                Text(unit)
                    .font(.aero(size: CockpitType.label))
                    .foregroundColor(theme.textSecondary)
            }
        }
    }
}

/// A frequency on one line, at its size or a little under, never wrapped. What a pilot typed for a
/// waypoint can be long ("119.175 Bern Information"); it wrapped and made the NOW / NEXT card a line
/// taller (29 pt on the phone). Past the scaling, the words go, not the frequency: cut at the end, or at
/// the start where the frequency ends the text. (6.1, stability)
struct FrequencyLineText: View {
    let text: String
    let font: Font
    let color: Color

    var body: some View {
        ZStack(alignment: .leading) {
            // A line's height at full size: scaled, the text alone came out 5 pt shorter, the card too.
            Text(verbatim: "0")
                .font(font)
                .hidden()
                .accessibilityHidden(true)
            let parts = FrequencyRow.parts(of: text)
            if parts.count > 1 {
                // Several frequencies typed ("Info 124.705 / Tower 118.125 / Ground 121.900"): all of them
                // if they fit, else the first one whole and a sign there are more, which the open panel
                // lists. Cut at its start, the text read "….125 / Ground 121.900": the first frequency
                // gone and the second cut in its digits. (6.1.0 device check)
                ViewThatFits(in: .horizontal) {
                    line(text)
                    line(Self.firstOfSeveral(parts))
                    line(parts[0])
                }
                .accessibilityLabel(text)
            } else {
                line(text)
            }
        }
    }

    private func line(_ shown: String) -> some View {
        Text(shown)
            .font(font)
            .foregroundColor(color)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .truncationMode(Self.cutsAtStart(shown) ? .head : .tail)
    }

    /// The first of several typed frequencies, and a sign that more follow.
    static func firstOfSeveral(_ parts: [String]) -> String {
        parts.count > 1 ? parts[0] + " / …" : parts.first ?? ""
    }

    /// Whether the text ends with a frequency after some words ("Bern Info 120.100"): then the words are
    /// cut at the start, so the digits stay.
    static func cutsAtStart(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: #"[0-9]{3}[.,][0-9]{1,3}$"#, options: .regularExpression) else {
            return false
        }
        return range.lowerBound != trimmed.startIndex
    }
}

/// A station and its frequency in the open panel's list. The frequency is dialled as read: it keeps one
/// line and every digit, and the station gives way, smaller, then cut. Beside a long name it wrapped as
/// "130.35" over "5". (6.1, device check)
///
/// What a pilot typed for a waypoint can be any length ("Info 124.705 / Tower 118.125 / Ground
/// 121.900"). Where it leaves the station less than a few letters, it goes under the station, at the
/// right, one part per line, split at "/". Each part keeps one line: a little smaller (down to the label
/// size), then cut, never wrapped. On the station's line at its full width, it squeezed the station to
/// nothing and made the row, the frequency column, then Emergency lined up under it, and so the whole
/// panel wider than the screen: the map pane moved right and the frequencies ran off it. The row is
/// never wider than it is offered. (6.1, device check)
struct FrequencyRow: View {
    let item: PhaseFrequency
    /// The kneeboard panel's sizes (v6.0 · P6); the small ones are the old sheet's.
    var large = true

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            oneLine
            underTheStation
        }
        .padding(.vertical, large ? 8 : 3)
    }

    /// The parts of what was typed, one per line under the station: split at "/", each trimmed.
    static func parts(of text: String) -> [String] {
        let parts = text.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [text] : parts
    }

    /// What the station keeps, at the least, for its frequency to stay on its line: about four capitals.
    static func stationRoom(large: Bool) -> CGFloat {
        3 * (large ? CockpitType.label : 11)
    }

    /// The station, then the frequency at the far end: every "130.355", as it always was. Measured with
    /// the station at its room, so a long name gives way rather than send its frequency under it.
    private var oneLine: some View {
        HStack(spacing: large ? 10 : 6) {
            tag
            station
                .frame(idealWidth: Self.stationRoom(large: large))
            Spacer(minLength: 6)
            Text(item.freq)
                .font(frequencyFont)
                .foregroundColor(frequencyColor)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// The station on its line, then each part of what was typed on its own, at the right.
    private var underTheStation: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: large ? 10 : 6) {
                tag
                station
            }
            ForEach(Array(Self.parts(of: item.freq).enumerated()), id: \.offset) { _, part in
                FrequencyLineText(text: part, font: frequencyFont, color: frequencyColor)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// A short NOW / NEXT tag in its colour; nothing on the other rows. (v4 UI/UX Revamp)
    @ViewBuilder
    private var tag: some View {
        if let roleTag {
            Text(roleTag.title)
                .font(.aero(size: large ? 16 : 8, weight: .bold)).tracking(0.3)
                .foregroundColor(roleTag.tint)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(roleTag.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
        }
    }

    private var roleTag: (title: String, tint: Color)? {
        switch item.role {
        case .current: return (L10n.Nav.freqCurrent, theme.onTarget)
        case .next: return (L10n.Nav.freqNext, theme.info)
        default: return nil
        }
    }

    private var station: some View {
        Text(item.station)
            .font(.aero(size: large ? CockpitType.label : 11, weight: item.highlighted ? .semibold : .regular))
            .foregroundColor(item.isEmergency ? theme.danger : theme.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(large ? 0.7 : 1)
    }

    private var frequencyFont: Font {
        .aero(size: large ? CockpitType.row : 13, weight: item.highlighted ? .bold : .regular, design: .monospaced)
    }

    /// Frequencies are data: white in flight on the kneeboard panel. (v6.0 · P5)
    private var frequencyColor: Color {
        item.highlighted && !large ? theme.onTarget : theme.textPrimary
    }
}

/// The leg table's columns in the open panel, at the kneeboard sizes the phone uses too. Each time column
/// is as wide as its widest value: B612 Mono is about 0.6 em wide, so at 20 pt "17:32" needs 60 pt and
/// "▲15:15" about 72. Exact rather than scaled, so the times stay whole wherever the legs are laid out;
/// the name takes what they leave, a little smaller, then cut.
enum LegRowMetrics {
    static let horizontalPadding: CGFloat = 8
    static let spacing: CGFloat = 8
    static let indexWidth: CGFloat = 26
    /// The dot, the arrow or the circle before the name, at most. Each keeps its own width (on a phone on
    /// its side, "LSZQ" has no point to spare).
    static let iconWidth: CGFloat = 18
    /// The least room between the name and the times.
    static let nameGap: CGFloat = 6
    static let timeSpacing: CGFloat = 6
    static let timeWidth: CGFloat = 68
    static let deltaWidth: CGFloat = 82

    /// A row without its name.
    static var fixedWidth: CGFloat {
        2 * horizontalPadding + indexWidth + iconWidth + 4 * spacing + nameGap
            + 2 * timeWidth + deltaWidth + 2 * timeSpacing
    }

    /// ACT and Δ, both empty on a waypoint ahead: where DIRECT goes on a previewed one.
    static var actualAndDeltaWidth: CGFloat { timeWidth + timeSpacing + deltaWidth }

    /// The least of a name the legs keep beside the frequencies: an ICAO code, four characters of B612
    /// Mono at 20 pt.
    static let shortNameWidth: CGFloat = 48
}

/// The open panel's two columns, the legs and then the frequencies: side by side wherever the legs keep
/// their times whole and a short name beside the frequencies' 300 pt (every iPad in portrait, the mini's
/// 744 pt included, and the iPad's panel on its side), one above the other on a phone. Decided on the
/// width alone. `ViewThatFits` decided on the legs' ideal width, every name and the DEST line at full
/// size: a route with one long name (SAIGNELÉGIER) put the frequencies under the legs, out of view until
/// scrolled. Beside the frequencies, the names give way instead. (6.1, device check)
///
/// Never wider than it is offered, whatever is inside. `frequencyFoot` places its content (Emergency,
/// pinned under the scroll) where the frequency column runs above it.
struct LegsPanelColumns: Layout {
    enum Content: Equatable {
        /// Two subviews: the legs, then the frequencies.
        case legsAndFrequencies
        /// The frequency column's foot, under the column: beside the legs when there are any, else the
        /// panel's width.
        case frequencyFoot(hasLegs: Bool)
    }

    var content: Content = .legsAndFrequencies

    static let frequencyWidth: CGFloat = 300
    static let columnSpacing: CGFloat = 24
    static let stackSpacing: CGFloat = 16

    /// The narrowest width that has the legs beside the frequencies.
    static var sideBySideWidth: CGFloat {
        LegRowMetrics.fixedWidth + LegRowMetrics.shortNameWidth + columnSpacing + frequencyWidth
    }

    static func isSideBySide(width: CGFloat) -> Bool {
        width >= sideBySideWidth
    }

    /// Where the frequency column runs across `width`.
    static func frequencyColumn(width: CGFloat, hasLegs: Bool) -> (minX: CGFloat, width: CGFloat) {
        hasLegs && isSideBySide(width: width) ? (width - frequencyWidth, frequencyWidth) : (0, width)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = width(for: proposal, subviews: subviews)
        return CGSize(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    /// The width offered; asked for an ideal size, the widest subview's.
    private func width(for proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
        if let width = proposal.width, width.isFinite { return width }
        return subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        func height(_ index: Int, _ width: CGFloat) -> CGFloat {
            subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        switch content {
        case .legsAndFrequencies where subviews.count == 2 && Self.isSideBySide(width: width):
            let column = Self.frequencyColumn(width: width, hasLegs: true)
            let legsWidth = column.minX - Self.columnSpacing
            return [CGRect(x: 0, y: 0, width: legsWidth, height: height(0, legsWidth)),
                    CGRect(x: column.minX, y: 0, width: column.width, height: height(1, column.width))]
        case .legsAndFrequencies:
            return stacked(x: 0, width: width, spacing: Self.stackSpacing, subviews: subviews)
        case .frequencyFoot(let hasLegs):
            let column = Self.frequencyColumn(width: width, hasLegs: hasLegs)
            return stacked(x: column.minX, width: column.width, spacing: 0, subviews: subviews)
        }
    }

    /// One above the other, each `width` wide from `x`.
    private func stacked(x: CGFloat, width: CGFloat, spacing: CGFloat, subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = []
        var y: CGFloat = 0
        for subview in subviews {
            let height = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            frames.append(CGRect(x: x, y: y, width: width, height: height))
            y += height + spacing
        }
        return frames
    }
}

/// What the open legs panel brings into view when it is below the fold: the leg being flown, the row
/// of the waypoint flown to. On a long route, a leg far down it opened out of view. Pure, so it is
/// tested without a view. (6.1, device check)
enum LegsPanelReveal {
    /// A leg's row in the panel's scroll.
    struct RowID: Hashable {
        let index: Int
    }

    /// The row of the leg being flown; once the route is flown, its last row. None without legs.
    static func row(currentWaypointIndex: Int, waypointCount: Int) -> Int? {
        guard waypointCount > 0 else { return nil }
        return min(max(currentWaypointIndex, 0), waypointCount - 1)
    }
}

/// The flight-event overlay, except where the map is embedded in a view that already has one.
private struct FlightEventOverlayUnlessEmbedded: ViewModifier {
    let isEmbedded: Bool
    let detector: FlightEventDetector
    let appState: AppState

    func body(content: Content) -> some View {
        if isEmbedded {
            content
        } else {
            content.flightEventConfirmationOverlay(detector: detector, appState: appState)
        }
    }
}

/// Redraws the aerodrome procedures when what they depend on changes, other than the region: the three
/// switches, the data (a download, the first load), the palette, the plan's ends (drawn first). Loads
/// the data when a switch is on. One modifier rather than five `onChange`s on the map's long body.
/// (6.2.0)
struct VFRLayerFollower: ViewModifier {
    struct Key: Equatable {
        let selection: VFRLayerSelection
        let revision: Int
        let palette: VFRMapPalette
        let firstAerodromes: [String]
    }

    let key: Key
    let onChange: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear { loadIfNeeded(key.selection) }
            .onChange(of: key) { _, new in
                loadIfNeeded(new.selection)
                onChange()
            }
    }

    /// The procedures are decoded on demand, the first time a layer needs them: never at launch with
    /// every switch off.
    private func loadIfNeeded(_ selection: VFRLayerSelection) {
        guard selection.isAnyOn, !OFMDataService.shared.isLoaded else { return }
        Task { await OFMDataService.shared.ensureLoaded() }
    }
}

/// A MARK or a leg-timer reset that can still be taken back. (v6.0 · C2) Or a waypoint the flight
/// marked on its own, whose offer is rebuilt on every render under the notice's id. (v6.0.1)
struct NavUndoOffer: Identifiable {
    var id = UUID()
    let message: String
    var style: NavUndoToast.Style = .filled
    let undo: () -> Void
}

extension NavUndoOffer {
    /// "LSGC marked automatically at 14:37", taken back like a MARK. (v6.0.1)
    @MainActor
    static func autoMark(_ notice: FlightPlanManager.AutoMarkNotice, in manager: FlightPlanManager) -> NavUndoOffer {
        NavUndoOffer(id: notice.id,
                     message: L10n.Nav.markedAutomaticallyAt(notice.waypointName,
                                                             notice.passedAt.formatted(date: .omitted, time: .shortened)),
                     style: .outlined) {
            manager.undoAutoMark(notice)
        }
    }
}

extension NavUndoOffer {
    /// "CLIMB CHECK done from memory", taken back with UNDO. Outlined: on the checklist pane it sits
    /// right above NEXT, which took CHECK's place, and on the map right above the slot. (6.1)
    @MainActor
    static func memoryConfirmation(_ confirmation: AppState.MemoryConfirmation, in appState: AppState) -> NavUndoOffer {
        NavUndoOffer(id: confirmation.id,
                     message: L10n.Cockpit.doneFromMemoryToast(confirmation.phase.shortTitle),
                     style: .outlined) {
            appState.undoMemoryConfirmation(confirmation.id)
        }
    }
}

extension NavUndoOffer {
    /// "FREDA done at 14:34", taken back with UNDO. Outlined, as a memory check's. (6.1)
    @MainActor
    static func fredaConfirmation(_ confirmation: AppState.FredaConfirmation, in appState: AppState) -> NavUndoOffer {
        NavUndoOffer(id: confirmation.id,
                     message: L10n.Freda.doneToast(confirmation.doneAt.formatted(date: .omitted, time: .shortened)),
                     style: .outlined) {
            appState.undoFredaConfirmation(confirmation.id)
        }
    }

    /// The check just confirmed, still to offer back: a memory check or a FREDA, the newer of the two
    /// when both are. (6.1)
    @MainActor
    static func checkConfirmation(in appState: AppState) -> NavUndoOffer? {
        let memory = appState.memoryConfirmationToOffer
        let freda = appState.fredaConfirmationToOffer
        if let freda, memory.map({ $0.confirmedAt <= freda.doneAt }) ?? true {
            return .fredaConfirmation(freda, in: appState)
        }
        return memory.map { .memoryConfirmation($0, in: appState) }
    }
}

extension AppState {
    /// The memory check confirmation still to offer back: within its six seconds. (6.1)
    var memoryConfirmationToOffer: MemoryConfirmation? {
        guard let confirmation = memoryConfirmation,
              Date().timeIntervalSince(confirmation.confirmedAt) < Self.memoryConfirmationUndoWindow else { return nil }
        return confirmation
    }

    /// FREDA done, still to offer back: within the same six seconds. (6.1)
    var fredaConfirmationToOffer: FredaConfirmation? {
        guard let confirmation = fredaConfirmation,
              Date().timeIntervalSince(confirmation.doneAt) < Self.memoryConfirmationUndoWindow else { return nil }
        return confirmation
    }

    /// Clears whichever check confirmation `id` is: the toast's six seconds are up.
    func dismissCheckConfirmation(_ id: UUID) {
        dismissMemoryConfirmation(id)
        dismissFredaConfirmation(id)
    }
}

/// The undo toast, over a pane and never in its layout, for six seconds: MARK and the leg-timer reset
/// on the map, and a waypoint the flight marked on its own on the map and the checklist pane.
/// (v6.0 · C2, v6.0.1)
struct NavUndoToast: View {
    /// MARK's and the leg-timer reset's UNDO take back the pilot's own tap: filled, as in 6.0. The
    /// flight's own mark is not the pilot's action, and its UNDO sits right above CHECK on the checklist
    /// pane for six seconds: outlined, a secondary action that a thumb aiming for CHECK is less likely
    /// to take. Both at the kneeboard sizes below.
    enum Style {
        case filled
        case outlined
    }

    /// The message and UNDO's label: the in-flight label size (20 pt on the iPad). (v6.0.1)
    static var textSize: CGFloat { CockpitType.label }
    /// UNDO's height: the 15 mm control (78 pt on the iPad, 92 on the phone). (v6.0.1)
    static var buttonHeight: CGFloat { CockpitTarget.transient }

    @Environment(\.cockpitTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let offer: NavUndoOffer
    /// Clears the offer: after UNDO, or when its six seconds are up.
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Text(offer.message)
                .font(.aero(size: Self.textSize, weight: .semibold))
                .foregroundColor(theme.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                offer.undo()
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { onDismiss() }
            } label: {
                Text(L10n.Nav.undo.uppercased())
                    .font(.aero(size: Self.textSize, weight: .heavy))
                    .foregroundColor(offer.style == .filled ? theme.actionText : theme.action)
                    .frame(minWidth: 104, minHeight: Self.buttonHeight)
                    .background(buttonShape)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 16).fill(theme.panel.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.panelStroke, lineWidth: 1))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: offer.id) {
            AccessibilityNotification.Announcement(offer.message).post()
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { onDismiss() }
        }
    }

    @ViewBuilder
    private var buttonShape: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        switch offer.style {
        case .filled: shape.fill(theme.action)
        case .outlined: shape.strokeBorder(theme.action, lineWidth: 2)
        }
    }
}

/// The map's undo toast: its own MARK or leg-timer reset or, in flight, a waypoint the flight just
/// marked on its own. Only one at a time: each withdraws the other. A view of its own rather than a
/// part of the map's body, which is already as deep as the stack allows (see `SeparateView`). (v6.0.1)
struct MapUndoToast: View {
    @Binding var undoOffer: NavUndoOffer?
    @Environment(AppState.self) private var appState
    @EnvironmentObject private var flightPlanManager: FlightPlanManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: NavUndoOffer? {
        // A memory check or a FREDA just confirmed from the slot (6.1): the pilot's latest tap here.
        if appState.isFlightActive, let confirmation = NavUndoOffer.checkConfirmation(in: appState) {
            return confirmation
        }
        if appState.isFlightActive, let notice = flightPlanManager.autoMarkNotice {
            return .autoMark(notice, in: flightPlanManager)
        }
        return undoOffer
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let offer = shown {
                NavUndoToast(offer: offer) {
                    if offer.id == undoOffer?.id { undoOffer = nil }
                    flightPlanManager.dismissAutoMarkNotice(offer.id)
                    appState.dismissCheckConfirmation(offer.id)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: flightPlanManager.autoMarkNotice?.id)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: appState.memoryConfirmation?.id)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: appState.fredaConfirmation?.id)
        // A waypoint the flight marked on its own, or a check just confirmed, supersedes the undo of an
        // older MARK or reset.
        .onChange(of: flightPlanManager.autoMarkNotice?.id) { _, id in
            if id != nil { undoOffer = nil }
        }
        .onChange(of: appState.memoryConfirmation?.id) { _, id in
            if id != nil { undoOffer = nil }
        }
        .onChange(of: appState.fredaConfirmation?.id) { _, id in
            if id != nil { undoOffer = nil }
        }
    }
}

/// The Cockpit's checklist pane host for a waypoint the flight marked on its own, and for a memory
/// check just confirmed with ✓ DONE or a FREDA just done (6.1): the map pane has its own, which also
/// carries MARK's undo. (v6.0.1)
struct AutoMarkUndoToast: View {
    /// The phone's narrower margins.
    var narrow = false
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: NavUndoOffer? {
        if let confirmation = NavUndoOffer.checkConfirmation(in: appState) {
            return confirmation
        }
        return flightPlanManager.autoMarkNotice.map { .autoMark($0, in: flightPlanManager) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let offer = shown {
                NavUndoToast(offer: offer) {
                    flightPlanManager.dismissAutoMarkNotice(offer.id)
                    appState.dismissCheckConfirmation(offer.id)
                }
                .padding(.horizontal, narrow ? 12 : 16)
                .padding(.bottom, 8)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: flightPlanManager.autoMarkNotice?.id)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: appState.memoryConfirmation?.id)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: appState.fredaConfirmation?.id)
    }
}
