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

extension MapLayerType {
    /// What a map shows for this choice over `region`: the chart picked, or, with the whole view outside swisstopo's
    /// charts, the next best, Apple's map (its satellite view for SWISSIMAGE). The choice itself stays: back over
    /// Switzerland, the chart comes back. The ICAO chart on a US route showed nothing, on Plan › Map and in the dry
    /// run alike (the author's device check, 23 Oct 2026). (6.5.0)
    func shown(over region: MKCoordinateRegion) -> MapLayerType {
        guard isSwissLayer, !SwissChartCoverage.reaches(region) else { return self }
        return self == .swissimage ? .satellite : .standard
    }
}

/// Where swisstopo's charts draw: Switzerland and Liechtenstein, with the ICAO chart's margin over the borders. (6.5.0)
enum SwissChartCoverage {
    static let minLat = 45.3, maxLat = 48.3, minLon = 5.3, maxLon = 11.2

    /// Whether any of `region` is over it.
    static func reaches(_ region: MKCoordinateRegion) -> Bool {
        let halfLat = region.span.latitudeDelta / 2, halfLon = region.span.longitudeDelta / 2
        return region.center.latitude + halfLat >= minLat && region.center.latitude - halfLat <= maxLat
            && region.center.longitude + halfLon >= minLon && region.center.longitude - halfLon <= maxLon
    }
}


/// A fit's region (a leg from ROUTE, Show on the route pill) reaches the shared state a turn later:
/// `SharedMapState.updateFromRegion` defers it, to publish outside the view update. Until it does, the
/// shared state still holds the region from before the fit, and an update pass in that window moved the
/// camera back there at the fit's zoom: a leg tapped on ROUTE opened MAP on the aircraft with the leg's
/// bar (6.2 device check; 8 of 10 relaunches on MAP framed on a leg, on the simulator). Noted at the fit,
/// let go as soon as the shared region is anything but the one the fit replaced; the regions reported
/// before the fit, which would let it go too early, are dropped (`SharedMapState.updateFromFit`). (6.2)
struct FitRegionSync {
    private(set) var staleRegion: MKCoordinateRegion?

    /// The map was just fitted; `shared` is what the shared state still says until the fit reaches it.
    mutating func fitted(replacing shared: MKCoordinateRegion) {
        staleRegion = shared
    }

    /// Whether `shared` is still the region the last fit replaced: the camera keeps the fit meanwhile.
    mutating func isStale(_ shared: MKCoordinateRegion) -> Bool {
        guard let stale = staleRegion else { return false }
        if Self.same(shared, stale) { return true }
        staleRegion = nil
        return false
    }

    /// The representables' `regionsAreEqual`.
    static func same(_ a: MKCoordinateRegion, _ b: MKCoordinateRegion) -> Bool {
        let epsilon = 0.0001
        return abs(a.center.latitude - b.center.latitude) < epsilon
            && abs(a.center.longitude - b.center.longitude) < epsilon
            && abs(a.span.latitudeDelta - b.span.latitudeDelta) < epsilon
            && abs(a.span.longitudeDelta - b.span.longitudeDelta) < epsilon
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
    /// The room left around `pendingFitCoordinates`, when not the route pill's: a leg shown from ROUTE
    /// is framed clear of the chrome over the chart (`LegFraming.edgePadding`). Consumed with it. (6.2)
    var pendingFitPadding: UIEdgeInsets?
    /// Where a search sends the camera: an aerodrome, at a distance the layer's zoom range may hold
    /// back. Consumed by the representables like `pendingFitCoordinates`, and for the same reason: set
    /// at once, not animated, then synced to this state, or a report of the old region takes the camera
    /// back. (6.2.0)
    var pendingCameraMove: PendingCameraMove?
    /// The aerodrome a search chose, whose callout opens once the camera and its marker are there
    /// (`PilotMapMarkers.openPendingCallout`). (6.2.0)
    var pendingCallout: PendingCallout?
    /// The aerodrome a search chose while the airport layer is off: its marker alone is drawn, for its card, until the
    /// card closes. (6.8.0, device check pm-10)
    var searchedAerodrome: Airport?
    /// What the map shows while the legs panel's band has the camera, for the airports and airspace
    /// drawn on it. The band never writes `region`, `cameraDistance` or `cameraHeading`: they keep the
    /// map the pilot left, which closing the panel puts back. nil with the panel closed. (6.1, option C)
    @Published var bandRegion: MKCoordinateRegion?
    /// The pilot's zoom as the band last measured it, with the panel closed (`LegsBandDriver`): kept here
    /// because the map view isn't. Portrait and landscape are different views, and a map made with the
    /// panel open, the device just turned, has never shown the pilot's chart: its band never framed until
    /// the panel closed. (6.3.0, the author's device check fix1-4)
    var bandPilotZoom: (scale: Double, perMetre: Double, height: CGFloat)?
    /// An annotation's callout is open (an aerodrome, a reporting point, a procedure's label): the chrome
    /// laid over the chart where a callout opens, the scale bar and the off-screen route pill, steps aside
    /// until it closes. Kept by the representables' coordinators from MapKit's selection. (6.2.0)
    @Published private(set) var isCalloutOpen = false
    /// How far the chrome at the chart's bottom left reaches above the scale bar (Plan › Map's allowance line): the
    /// imagery credits sit above it. (6.8.0)
    @Published var footerLift: CGFloat = 0

    init() {
        // Default to Switzerland center
        self.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 46.8, longitude: 8.2),
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        )
    }

    func updateFromRegion(_ newRegion: MKCoordinateRegion) {
        // Defer state updates to avoid "Publishing changes from within view updates" warning
        let generation = fitGeneration
        DispatchQueue.main.async { [weak self] in
            // A fit came since: this region is older than the one it framed (`updateFromFit`).
            guard let self, generation == self.fitGeneration else { return }
            self.region = newRegion
        }
    }

    /// The region the map was just fitted to (a leg from ROUTE, Show on the route pill). It replaces any
    /// region still on its way: the map delegate reports every camera move a turn later, and the report
    /// of the camera set before the fit landed after it and put the map back where it was (6.2 device
    /// check; with `FitRegionSync`).
    func updateFromFit(_ newRegion: MKCoordinateRegion) {
        fitGeneration &+= 1
        updateFromRegion(newRegion)
    }

    /// Bumped by each fit; a region sync queued before it is dropped.
    private var fitGeneration = 0

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

    /// The MapLibre view's callout opened or closed. Published a turn later: the map's delegate calls come during
    /// a view update, where publishing is not allowed. (6.2.0, 6.8.0)
    @MainActor
    func noteCalloutOpen(_ open: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, open != self.isCalloutOpen else { return }
            self.isCalloutOpen = open
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
/// session state, but for the layer, which the device keeps (`AppState.selectMapLayer`). (Phase 4 —
/// AppState decomposition: state extraction)
struct NavigationMapState: Equatable {
    var selectedLayer: MapLayerType = .icao
    var orientationMode: MapOrientationMode = .northUp
    /// The zoom the map was left at, so reopening it (or switching the Cockpit back to MAP) doesn't
    /// throw away the scale the pilot chose. nil until the map has been shown once. (v6.0 · P2)
    var cameraDistance: Double?
    var latitudeDelta: Double?

    /// Where the device keeps the layer. (6.2)
    static let layerKey = "map.selectedLayer"

    /// The layer last picked on this device; the ICAO chart the first time.
    static func savedLayer(in defaults: UserDefaults) -> MapLayerType {
        defaults.string(forKey: layerKey).flatMap(MapLayerType.init(rawValue:)) ?? .icao
    }
}

extension MapOrientationMode: Equatable {}

/// Full-screen navigation map view with aircraft position tracking
struct NavigationMapView: View {
    /// Whose map it is. (6.2, the act band)
    enum Chrome: Equatable {
        /// Plan › Map, and the full-screen map: every piece of the map's own chrome, Routes at its foot.
        case plan
        /// The Cockpit's MAP page, in the Cockpit's layout: the act band under it holds what the map's
        /// thumb row did.
        case cockpit(CockpitLayout)
    }

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
    @ObservedObject private var reportingPointCatalog = ReportingPointCatalog.shared   // OpenAIP + open flightmaps (6.2.0)
    /// The aerodrome procedures (6.2.0): its `revision` redraws them when a download or the first load lands.
    @ObservedObject private var vfrProcedureService = OFMDataService.shared
    /// The US traffic patterns, for the approach view: its `revision` too. (6.5.0)
    @ObservedObject private var nasrPatterns = NASRPatternService.shared
    @ObservedObject private var pilotMap = PilotMapDownloads.shared   // the allowance line (6.8.0)
    /// A dry run's: the runway it lands on is the one in use on its map. (6.5.0)
    @Environment(\.dryRunSession) private var dryRunSession

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
    // The approach view's runway in use: the briefing's wind (`FlightView.briefingContext`). (6.2.0)
    @EnvironmentObject var windDataService: WindDataService
    @EnvironmentObject var windsAloftService: WindsAloftService
    /// For the one line a diversion shows when a flight plan was filed. (v5.1)
    @EnvironmentObject var threadManager: FlightThreadManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The callouts' official chart opens in the browser. (6.2.0)
    @Environment(\.openURL) private var openURL

    @Binding var isPresented: Bool
    /// False in the Plan tab, where the map is a section of the screen rather than a cover to close.
    /// (v6.0 · P1)
    var showsCloseButton: Bool = true
    /// Whose map it is: Plan › Map's (and the full-screen one's), or the Cockpit's MAP page, which has no
    /// thumb row (the act band is the Cockpit's, under every page) and no side column on an iPad on its
    /// side (the same frame as in portrait, wider). On a phone on its side the Cockpit builds the column
    /// itself, and the map is the chart beside it. (6.2, the act band)
    var chrome: Chrome = .plan
    /// Where "Routes" goes instead of opening the routes as a cover: Plan › Map switches to its own
    /// Routes section, rather than stacking a second copy of it over the tab. (on-device review #4)
    var onShowRoutes: (() -> Void)? = nil
    /// "Divert here" in an airport's callout, in flight: the Cockpit's Divert sheet, on the field. TELL FIS
    /// in the status slot opens it too.
    var onDivert: ((String?) -> Void)? = nil
    /// The Cockpit's drawers, from the status slot: GPS and BRIEFING (`FlightView.openReference`). (6.2)
    var onOpenReference: ((HUDReference) -> Void)? = nil
    /// The Cockpit's: MARK's UNDO, the leg ROUTE asked to show. Nil in Plan › Map.
    @Environment(CockpitNavState.self) private var cockpitNav: CockpitNavState?
    /// The Cockpit's OFF ROUTE and More's requests to the chart. Nil in Plan › Map. (6.2, PR 4)
    @Environment(CockpitMapState.self) private var cockpitMap: CockpitMapState?
    /// The status slot shows a state: what MAP frames is kept clear of it. (6.2, PR 4)
    @State private var mapStatusShown = false
    /// The zoom MAP had before it framed a leg from ROUTE: put back with "Back to aircraft". (6.2)
    @State private var zoomBeforeLeg: LegZoom?
    /// A leg to frame once the chart has measured itself: the room its chrome takes. (6.2)
    @State private var legFramePending = false
    /// The device's layer from the first frame: made on the ICAO chart and switched by `handleAppear`, the
    /// map drew one chart, then the other, and the switch's forced tile refresh made Plan › Map flash.
    /// (6.2, device check)
    @State private var selectedLayer: MapLayerType = NavigationMapState.savedLayer(in: .standard)
    /// The layer drawn: the one picked, Apple's map where its chart has nothing to show (`MapLayerType.shown(over:)`).
    /// (6.5.0)
    private var shownLayer: MapLayerType { selectedLayer.shown(over: mapState.region) }
    @State private var isFollowingAircraft: Bool = true
    /// iPad: base chart and overlays in one labelled sheet. (v6.0 · C1)
    @State private var showMapSheet: Bool = false
    /// Plan › Map's aerodrome search, from the magnifying glass left of Map. (6.2.0)
    @State private var showAerodromeSearch: Bool = false
    /// The aerodrome whose note a callout opened. (6.7.0)
    @State private var aerodromeNote: AerodromeRef?
    /// The aerodrome chosen in it: the map goes there once the sheet has gone.
    @State private var chosenAerodrome: Airport?
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
    @State private var locationUpdateCounter: Int = 0 // Forces map view updates on location change

    @State private var showGPSStatusModal: Bool = false
    @State private var streamingCTRCheckTask: Task<Void, Never>?

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
              shownLayer == .icao else {
            return false
        }
        // If forceICAOChartLayer is ON, we're always using ICAO (and cache)
        if appState.settings.forceICAOChartLayer {
            return true
        }
        // Otherwise, the ICAO chart's zooms, or the glider chart's with its own cache (from z11 since 6.4.2)
        let currentZoom = estimatedZoomLevel
        return currentZoom < ICAOSegelflugkarteTileOverlay.gliderMinZoom || offlineMapManager.isSegelflugCacheAvailable
    }

    /// Estimate current zoom level from map region span
    /// This is used to determine if we're in the cached ICAO range or Segelflugkarte range
    private var estimatedZoomLevel: Int {
        // Calculate zoom level from latitude span
        // At zoom 0, the world is 360° wide; each zoom level halves the span
        // Formula: zoom ≈ log2(360 / span); CHART OFFLINE reads the same (6.2)
        ChartAvailability.zoom(latitudeDelta: mapState.region.span.latitudeDelta)
    }

    // Shared map state for preserving position between layers
    @StateObject private var mapState = SharedMapState()

    // Track actual map width for accurate scale bar
    @State private var mapWidth: CGFloat = 0

    /// The current flight's GPS track, drawn on the map.
    private var displayGpsTrack: [GPSPoint] {
        appState.currentFlight?.gpsTrack ?? []
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
        // Embedded (the Cockpit, Plan › Map), the screen around it has its own.
        .modifier(FlightEventOverlayUnlessEmbedded(isEmbedded: !showsCloseButton,
                                                   detector: flightEventDetector, appState: appState))
        // The pilot's note on an aerodrome, from its callout: written on the ground, read in flight. (6.7.0)
        .sheet(item: $aerodromeNote) { ref in
            AerodromeNoteSheet(aerodrome: ref, readOnly: appState.isFlightActive)
                .environmentObject(AerodromeNoteStore.shared)
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
        // The region published, not `mapState.region`: a @Published property sends before it holds the
        // new value, so the content was for the region before. Plan › Map's search moves the camera
        // once, and its aerodrome's marker never came (simulator, 11 Oct). (6.2.0)
        .onReceive(mapState.$region) { region in
            recomputeMapSpatialContent(published: region)
        }
        // The band's chart, while the legs panel is open. (6.1, option C)
        .onReceive(mapState.$bandRegion) { _ in
            recomputeMapSpatialContent()
        }
        .onChange(of: navSheetExpanded) { _, open in
            if open { legsPanelOpened() } else { legsPanelClosed() }
        }
        // A leg from ROUTE, framed once the chart knows the room its chrome takes. (6.2)
        .onChange(of: chartGeometry.chartSize) { _, size in
            if legFramePending && size != .zero { frameRequestedLeg() }
        }
        .onChange(of: appState.settings.showAirportsOnMap) { _, _ in recomputeMapSpatialContent(force: true) }
        .onChange(of: appState.settings.showNavaidsOnMap) { _, _ in recomputeMapSpatialContent(force: true) }
        .onChange(of: appState.settings.showObstaclesOnMap) { _, _ in recomputeMapSpatialContent(force: true) }
        .onChange(of: appState.settings.showReportingPointsOnMap) { _, _ in recomputeMapSpatialContent(force: true) }
        // The aerodrome procedures: their switches, their data, the palette and the plan's ends. (6.2.0)
        // The third switch also brings open flightmaps' helicopter and glider reporting points.
        .modifier(VFRLayerFollower(key: vfrLayerKey) { recomputeMapSpatialContent(force: true) })
        .onChange(of: appState.currentPhase) { _, _ in
            recomputePhaseFrequencies()
            evaluateFredaOutsideTheCockpit()
            // The approach view opens from the Approach phase. (6.2.0)
            if appState.isFlightActive { recomputeMapSpatialContent(force: true) }
        }
        .onChange(of: flightPlanManager.activeFlightPlan?.currentWaypointIndex) { _, _ in recomputePhaseFrequencies() }
        .onReceive(fredaEvalTimer) { _ in
            evaluateFredaOutsideTheCockpit()
            // Re-prime the track-vector EMA each tick so a stationary device (no GPS *change*) keeps a
            // valid vector after a Nav→Checklist→Nav round trip. (v4 UI/UX Revamp fix)
            updateTrackVectorEMA()
        }
    }

    /// FREDA's evaluation, but in the Cockpit, where `FlightView` runs it every 5 s and on every phase
    /// whatever the page: the map's was a second one. (6.2)
    private func evaluateFredaOutsideTheCockpit() {
        guard chrome == .plan else { return }
        appState.evaluateFreda(lastPassage: FredaWaypointPassage.latest(in: flightPlanManager.activeFlightPlan))
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
        .onChange(of: reportingPointCatalog.revision) { _, _ in recomputeMapSpatialContent(force: true) }
        .onChange(of: locationManager.currentLocation) { _, newLocation in handleLocationChange(newLocation) }
        .onChange(of: selectedLayer) { _, newLayer in handleLayerChange(to: newLayer) }
        // One choice for every map: picked in the route builder, or on the other map of a split screen, it shows here
        // at once (the author's device check, 23 Oct 2026). (6.5.0)
        .onChange(of: appState.navigationMapState.selectedLayer) { _, layer in
            if selectedLayer != layer { selectedLayer = layer }
        }
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
        // A leg tapped on ROUTE: framed instead, as soon as the chart has measured its chrome. (6.2)
        if framedLeg != nil {
            zoomBeforeLeg = LegZoom(distance: initialCameraDistance, latitudeDelta: initialSpan.latitudeDelta)
            legFramePending = true
            if chartGeometry.chartSize != .zero { frameRequestedLeg() }
        }
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
        #if DEBUG
        frameForCaptureIfAsked()
        #endif
    }

    private func handleDisappear() {
        // Keep the zoom for next time (v6.0 · P2): the pilot's, not a leg's framing, which ends with the
        // page. (6.2)
        if let zoom = zoomBeforeLeg {
            appState.navigationMapState.cameraDistance = zoom.distance
            appState.navigationMapState.latitudeDelta = zoom.latitudeDelta
            zoomBeforeLeg = nil
            cockpitNav?.endLegFraming()
        } else {
            appState.navigationMapState.cameraDistance = mapState.cameraDistance
            appState.navigationMapState.latitudeDelta = mapState.region.span.latitudeDelta
        }
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
        // Kept for the session and the device's next launches. (6.2)
        appState.selectMapLayer(newLayer)
        // The approach view fades the charts only. (6.2.0)
        recomputeVFRContent(region: mapState.region)
        // No region nudge after a switch any more (the span moved by 1.001 and back, 0.1 s apart, "to force tile
        // loading"): `ChartTileRenderer` asks for its tiles itself since 6.4.2, and the map is no longer rebuilt
        // on a switch. (6.7.0)
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
        //
        // The Cockpit's map has no side column: an iPad on its side gets the portrait arrangement, the
        // frame wider, its act band under the page; beside the phone's column on its side it is the
        // chart alone too. (6.2)
        //
        // Nothing before the pane has its size: SwiftUI's first pass measures it 32 x 0, which read as landscape,
        // and Plan › Map built a first map there, threw it away 80 ms later in portrait and built another (7 of 8
        // opens; the other way round on an iPad on its side). A pane under 100 pt tall is no layout to choose, and
        // the map is built once, in the right one (the map tile review, F4). (6.4.2)
        let measured = chrome != .plan || geometry.size.height >= 100
        let landscape = measured && chrome == .plan && geometry.size.width > geometry.size.height * 1.2
        let mapAreaWidth = landscape ? geometry.size.width - Self.sideColumnWidth : geometry.size.width
        // The closures below run later, in their own view's update: read the proxy here, while it
        // is current.
        let height = geometry.size.height
        // Each large part of the map is a view of its own (`SeparateView`): built inline, this body's
        // value was about 33 KB, and rendering it overflowed the device's 1 MB main-thread stack.
        return Group {
            if !measured {
                Color.clear
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
            } else if chrome == .plan {
                // The legs and every frequency open inside the bottom panel, never taller than 40 %
                // of the map: past that they scroll, and the thumb bar stays on screen. (M-06)
                SeparateView {
                    mapArea(bottomPanel: SeparateView { bottomPanel(legsMaxHeight: height * 0.4) })
                }
            } else {
                // The Cockpit's chart, to the act band (beside the phone's column on its side, at full
                // height), and its own chrome over it (`CockpitChartChrome`). The next waypoint and NOW |
                // NEXT are in the read band, over every page; the controls row, CACHED, the scale, the chips,
                // the route's pill and the undo toast left the chart for the stack, the status slot and
                // More. Everything above is Plan › Map's alone. (6.2)
                SeparateView { cockpitMapArea }
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
                // From a leg shown from ROUTE: the leg is the one flown again, the aircraft the view.
                if framedLeg != nil { backToAircraft() }
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

    /// The next waypoint on one line: the ident in magenta, then bearing, distance and time. Tap for
    /// every leg and frequency. A diversion shows its tag and the way back to the route. Plan › Map's on
    /// the phone: the Cockpit's next waypoint is in its read band, on its side too since 6.2.
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
                .accessibilityIdentifier("map.nextLine")
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
        .sheet(isPresented: $showAerodromeSearch, onDismiss: showChosenAerodrome) { aerodromeSearchSheet }
    }

    private var mapControlsLabelled: some View {
        HStack(spacing: 8) {
            aerodromeSearchButton
            mapSheetButton(labelled: true)
            orientationButton
            chromeButton(icon: isFollowingAircraft ? "location.fill" : "location",
                         title: L10n.Nav.centre, prominent: !isFollowingAircraft) { centerOnAircraft() }
        }
    }

    private var mapControlsIcons: some View {
        HStack(spacing: 8) {
            aerodromeSearchButton
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
        MapSheet(selectedLayer: $selectedLayer, shownLayer: shownLayer, isOfflineMode: isOfflineMode, mapCenter: mapState.region.center,
                     mapRegion: mapState.region)
            .environment(appState)
            .environment(\.cockpitTheme, theme)
            .environmentObject(openAIPDataService)
            .environmentObject(dataStatusManager)
            .environmentObject(offlineMapManager)
    }

    /// The magnifying glass left of Map: an aerodrome by its ICAO code or its name, and the map goes
    /// there (`AirfieldSearchSheet`). Plan › Map's only: the Cockpit's map has Divert's search. (6.2.0)
    private var aerodromeSearchButton: some View {
        chromeIconButton(icon: "magnifyingglass", label: L10n.Nav.searchAerodromes) { showAerodromeSearch = true }
            .accessibilityIdentifier("map.searchAerodromes")
    }

    private var aerodromeSearchSheet: some View {
        AirfieldSearchSheet(reference: mapState.region.center) { chosenAerodrome = $0 }
            .environmentObject(airportDataService)
    }

    /// The sheet has gone, and the keyboard with it: the map goes to the aerodrome chosen, if any. Moved
    /// while the sheet was still going, the map was laid out again afterwards and the aerodrome ended up
    /// at the chart's foot (simulator, 11 Oct).
    private func showChosenAerodrome() {
        guard let airport = chosenAerodrome else { return }
        chosenAerodrome = nil
        showAerodrome(airport)
    }

    #if DEBUG
    /// DEV-ONLY (`AEROCHECK_SCENE=circuits`, the website's `circuits` shot): Plan › Map framed on LSZQ as the
    /// search frames an aerodrome, about 8 NM across, without the callout the shot had to close. (6.3.0)
    /// `AEROCHECK_SCENE=atlas`: Basel, 45 NM across, Mulhouse and Freiburg in view. (6.8.0)
    private func frameForCaptureIfAsked() {
        guard chrome == .plan else { return }
        let scene = ProcessInfo.processInfo.environment["AEROCHECK_SCENE"]?.lowercased()
        if scene == "atlas" {
            isFollowingAircraft = false
            mapState.pendingCallout = nil
            mapState.pendingCameraMove = PendingCameraMove(center: CLLocationCoordinate2D(latitude: 47.70, longitude: 7.55),
                                                           spanNM: 45)
            mapState.objectWillChange.send()
            return
        }
        guard scene == "circuits" else { return }
        Task {
            await airportDataService.ensureLoaded()
            // The airport list may still be downloading on a fresh simulator.
            let field = airportDataService.findAirport(byIdent: "LSZQ") ?? Airport(
                id: 0, ident: "LSZQ", type: .smallAirport, name: "Bressaucourt",
                latitude: 47.3497, longitude: 7.0278, elevation: 1860, continent: "EU",
                isoCountry: "CH", isoRegion: "CH-JU", municipality: nil, scheduledService: false,
                gpsCode: nil, iataCode: nil, localCode: nil)
            isFollowingAircraft = false
            mapState.pendingCallout = nil
            mapState.pendingCameraMove = PendingCameraMove(to: field)
            mapState.objectWillChange.send()
        }
    }
    #endif

    /// An aerodrome chosen in the search: the map goes there, about 8 NM across, and stops following the
    /// aircraft (the pilot asked to look there), and its callout opens as a tap on its marker would. With the airport
    /// layer off, that aerodrome's marker is drawn alone until its card closes. (6.8.0, device check pm-10)
    private func showAerodrome(_ airport: Airport) {
        isFollowingAircraft = false
        mapState.searchedAerodrome = AirfieldSearch.needsItsOwnMarker(airport, airportsLayerOn: appState.settings.showAirportsOnMap)
            ? airport : nil
        mapState.pendingCallout = AirfieldSearch.opensCard(airport)
            ? PendingCallout(airport, until: Date().addingTimeInterval(AirfieldSearch.calloutWait))
            : nil
        mapState.pendingCameraMove = PendingCameraMove(to: airport)
        mapState.objectWillChange.send()   // neither is @Published; nudge updateUIView
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

    /// NOW, as Plan › Map works it out (`recomputePhaseFrequencies`); the Cockpit's is its read band's.
    private var nowFrequency: PhaseFrequency? {
        phaseFreqItems.first { $0.role == .current }
    }

    /// NEXT, as NOW.
    private var nextFrequency: PhaseFrequency? {
        phaseFreqItems.first { $0.role == .next }
    }

    /// Plan › Map's map with its chrome: the top bar (full-screen only), the next-waypoint card and the
    /// map's controls on top, the scale bar at the bottom, and in portrait the bottom panel.
    /// `footerClearance`: room kept under the scale bar, for the landscape legs panel laid over the
    /// chart's foot. (The Cockpit's chart is `cockpitMapArea`, 6.2.)
    private func mapArea<Panel: View>(bottomPanel: Panel?, footerClearance: CGFloat = 0) -> some View {
        // The phone: the next waypoint on one line and the controls at the foot of the chart, as on
        // its side. With the card and a row of controls on top, a phone in cruise had about 150 pt
        // of chart left, the aircraft under the controls. (round 6, I-06)
        let compact = CockpitScale.current == .phone
        return VStack(spacing: 0) {
            chartWithChrome(top: VStack(spacing: 0) {
                if showsCloseButton {
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
                    if !compact && panelChrome.showsMapControls {
                        SeparateView { mapControlsRow }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            // An aerodrome's callout near the top opens under the row: the row steps aside,
                            // as the scale bar does, so the callout reads whole. (6.7.0)
                            .modifier(StepsAsideForCallout(isHidden: mapState.isCalloutOpen, reduceMotion: reduceMotion))
                    }
                    SeparateView { occasionalChips }
                }
                .padding(.horizontal, compact ? 10 : 16)
                .padding(.top, compact ? 8 : 10)
            },
            bottom: VStack(spacing: 8) {
                mapFooter
                if compact && panelChrome.showsMapControls {
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
            .overlay { if panelChrome.bandClosesPanel { legsBandCover } }
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
                    .preference(key: ChartMeasuredOpenKey.self, value: panelChrome.bandClosesPanel)
            })
            .coordinateSpace(name: Self.chartSpace)
            .onPreferenceChange(ChartSizeKey.self) { chartGeometry.chartSize = $0 }
            .onPreferenceChange(ChartChromeBottomKey.self) { chartGeometry.chromeBottom = $0 }
            .onPreferenceChange(ChartMapFrameKey.self) { chartGeometry.mapFrame = $0 }
            .onPreferenceChange(ChartPanelInsetKey.self) { chartGeometry.panelInset = $0 }
            .onPreferenceChange(ChartMeasuredOpenKey.self) { chartGeometry.measuredOpen = $0 }
    }

    private static let chartSpace = "navChart"

    /// What comes and goes over Plan › Map's chart, under the next waypoint and the map's controls: the
    /// SIGMET chip (only with a hazard in range: a chip always there stops being read), then the off-screen
    /// route's pill, the one never moving the other. A SIGMET after a data refresh moved the pill down
    /// 38 pt. (6.1, stability) The Cockpit's chips, which shared the row, left its chart in 6.2 (PR 4) for
    /// the status slot and More, and its pill for OFF ROUTE, the edge arrow and More's whole route.
    ///
    /// Laid out by the caller's stack, one view each.
    @ViewBuilder
    private var occasionalChips: some View {
        let sigmets = rankedSigmets
        let showsPill = showsRouteOffScreenPill && routeOffScreenHint != nil
        if !sigmets.isEmpty || showsPill {
            HStack(alignment: .top, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if showsPill {
                        // The chip's own height, kept for the pill under it.
                        SigmetChip(hazards: Self.sigmetChipMeasure) {}
                            .hidden()
                            .accessibilityHidden(true)
                    }
                    SigmetChip(hazards: sigmets) { showSigmets = true }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 0, alignment: .top)
        }
        if showsRouteOffScreenPill {
            routeOffScreenPill
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: routeOffScreenHint) // (UX-18)
                .modifier(StepsAsideForCallout(isHidden: mapState.isCalloutOpen, reduceMotion: reduceMotion))
        }
    }

    /// The off-screen route's pill, but not with the legs open. (6.1, option C)
    private var showsRouteOffScreenPill: Bool {
        panelChrome.showsRouteOffScreenPill
    }

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
    private var panelChrome: LegsPanelMap.Chrome { .forPanel(open: navSheetExpanded) }

    /// The band the open legs panel leaves, as the map views take it; nil with the panel closed. It
    /// frames the waypoint previewed from the leg table while there is one, else the navigation target
    /// (the next waypoint, or the diversion field). In flight with the aircraft; on the ground (Plan ›
    /// Map, no flight) the leg ending there, its two ends, since the "aircraft" is then the device on the
    /// desk (6.3.0, the author's device check carry-1).
    private var legsBand: LegsPanelMap.Band? {
        guard navSheetExpanded else { return nil }
        let geometry = chartGeometry
        var waypoint: CLLocationCoordinate2D?
        var legStart: CLLocationCoordinate2D?
        if let plan = flightPlanManager.activeFlightPlan, !flightPlanManager.isFlightPlanCompleted {
            let end: Int?
            if let index = previewWaypointIndex, plan.waypoints.indices.contains(index) {
                waypoint = plan.waypoints[index].coordinate
                end = index
            } else {
                waypoint = plan.navigationTarget?.coordinate
                end = plan.diversion == nil ? plan.currentWaypointIndex : nil
            }
            if !appState.isFlightActive, let end, plan.waypoints.indices.contains(end) {
                legStart = plan.waypoints[max(0, end - 1)].coordinate
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
                ? (locationManager.currentCourseDegrees ?? mapState.cameraHeading) : 0,
            legStart: legStart)
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

    /// Routes at the foot of the map: Plan › Map's on the iPad. The phone's picker has Routes already.
    /// (round 6, I-06)
    private var showsRoutesRow: Bool {
        CockpitScale.current != .phone
    }

    /// The full-screen map on a phone, with nowhere else to go to the routes: Routes over the chart.
    private var routesOnTop: Bool {
        CockpitScale.current == .phone && onShowRoutes == nil
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
    /// The traffic circuits, VFR routes and sectors drawn for the region. (6.2.0)
    @State private var vfrContent: VFRMapContent = .empty()
    @State private var lastSpatialRegion: MKCoordinateRegion?

    /// What redraws the aerodrome procedures besides the region. (6.2.0)
    private var vfrLayerKey: VFRLayerFollower.Key {
        VFRLayerFollower.Key(selection: VFRLayerSelection(settings: appState.settings),
                             revision: vfrProcedureService.revision, patternsRevision: nasrPatterns.revision,
                             palette: VFRMapPalette(theme: theme),
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
    /// `published`: the region `mapState` is publishing, which it doesn't hold yet. (6.2.0)
    private func recomputeMapSpatialContent(force: Bool = false, published: MKCoordinateRegion? = nil) {
        let region = mapState.bandRegion ?? published ?? mapState.region
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
        // OpenAIP's and the open flightmaps points it lacks, loaded when first shown (6.2.0).
        if appState.settings.showReportingPointsOnMap,
           ReportingPointCatalog.shared.isDataAvailable {
            let rpHalfLat = region.span.latitudeDelta / 2
            let rpHalfLon = region.span.longitudeDelta / 2
            ReportingPointCatalog.shared.loadIfNeeded()
            visibleReportingPoints = ReportingPointCatalog.shared.points(
                latRange: (region.center.latitude - rpHalfLat)...(region.center.latitude + rpHalfLat),
                lonRange: (region.center.longitude - rpHalfLon)...(region.center.longitude + rpHalfLon),
                includingNonPowered: appState.settings.showsNonPoweredReportingPoints)
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
        guard selection.isAnyOn, VFRMapDensity.showsProcedures(in: region) else {
            vfrContent = .empty(palette)
            return
        }
        guard service.isLoaded else {
            // No open flightmaps data here (the US has none): the approach view still shows a US field's pattern
            // from NASR, with the traffic circuits. (6.5.0)
            let approach = selection.circuits ? approachFields(region: region, candidates: [], selection: selection) : []
            vfrContent = approach.isEmpty ? .empty(palette) : VFRMapContent(items: [], showsLabels: false, palette: palette,
                                                                             approach: approach)
            return
        }
        let candidates = service.procedures(in: region)
        vfrContent = VFRMapContent.make(
            candidates: candidates, region: region, selection: selection, palette: palette,
            firstAerodromes: VFRMapDensity.endpointAerodromes(of: flightPlanManager.activeFlightPlan),
            fieldPosition: { airportDataService.findAirport(byIdent: $0)?.coordinate },
            cycle: { (service.cycles[$0]?.airac, service.region(forCountry: $0)) },
            approach: approachFields(region: region, candidates: candidates, selection: selection))
    }

    /// The approach view's aerodromes (6.2.0, the author's design "E"): in flight, the destination or the
    /// field diverted to, within 10 NM of the aircraft or from the Approach phase on, with the runway in
    /// use from the briefing's wind; in Plan › Map, the aerodromes with procedures in view once the map
    /// spans 8 NM or less (no runway in use on the ground). At most three.
    private func approachFields(region: MKCoordinateRegion, candidates: [VFRProcedure],
                                selection: VFRLayerSelection) -> [VFRApproachField] {
        let byField = Dictionary(grouping: candidates) { $0.aerodrome.uppercased() }
        var idents: [String]
        var windFrom: Double?
        if appState.isFlightActive {
            guard let plan = flightPlanManager.activeFlightPlan,
                  let target = plan.diversion?.ident.uppercased() ?? VFRMapDensity.endpointAerodromes(of: plan).first,
                  let airport = airportDataService.findAirport(byIdent: target) else { return [] }
            let distanceNM = locationManager.getCurrentCoordinate().map {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                    .distance(from: CLLocation(latitude: airport.latitude, longitude: airport.longitude)) / 1852
            }
            let onApproach = appState.currentPhase == .approach || appState.currentPhase == .landing
            guard onApproach || (distanceNM ?? .infinity) <= 10 else { return [] }
            idents = [target]
            // A dry run marks the runway it lands on: its simulation decides, not the real wind at the real field
            // (the author's v65-17, 23 Oct 2026: 31 marked at Palo Alto, the aircraft on 13). (6.5.0)
            if let field = dryRunSession?.generator.landingAerodrome, field.ident.uppercased() == target {
                windFrom = field.runwayHeading
            } else {
                windFrom = BriefingWindLadder.select(
                    metars: aviationWeatherService.ladderCandidates,
                    station: windDataService.currentWindData,
                    model: windsAloftService.surfaceCandidate(near: locationManager.getCurrentCoordinate()),
                    aircraftAltitudeM: locationManager.currentAltitudeMeters,
                    now: Date())?.directionDeg.map(Double.init)
            }
        } else {
            guard VFRMapDensity.spanNM(of: region) <= 8 else { return [] }
            let halfLat = region.span.latitudeDelta / 2, halfLon = region.span.longitudeDelta / 2
            idents = byField.keys.filter { ident in
                guard let airport = airportDataService.findAirport(byIdent: ident) else { return false }
                return abs(airport.latitude - region.center.latitude) <= halfLat
                    && abs(airport.longitude - region.center.longitude) <= halfLon
            }.sorted()
            // The US fields in view whose pattern NASR publishes: there are no open flightmaps circuits there. (6.5.0)
            if selection.circuits {
                let us = airportDataService.findNearestAirports(to: region.center, limit: 12, maxDistanceNm: 8)
                    .filter { $0.isoCountry == "US" && !idents.contains($0.ident.uppercased())
                        && abs($0.latitude - region.center.latitude) <= halfLat
                        && abs($0.longitude - region.center.longitude) <= halfLon }
                idents += us.map { $0.ident.uppercased() }.filter { nasrPatterns.aerodrome($0) != nil }
            }
        }
        return idents.prefix(3).compactMap { ident -> VFRApproachField? in
            guard let airport = airportDataService.findAirport(byIdent: ident) else { return nil }
            let reference = VFRCoordinate(latitude: airport.latitude, longitude: airport.longitude)
            let runways = VFRRunwayEnds.runways(thresholds: OFMDataService.shared.thresholds(forAerodrome: ident),
                                                airportRunways: airportDataService.getRunways(for: ident),
                                                reference: reference)
            let circuits = (byField[ident] ?? OFMDataService.shared.procedures(forAerodrome: ident))
                .filter { $0.kind == .circuit && selection.includes($0) }
            // A US field's pattern side and altitude, from NASR (loaded the first time a US field asks). (6.5.0)
            let pattern = airport.isoCountry == "US" ? nasrPatterns.aerodrome(ident) : nil
            return VFRApproachField.make(ident: ident, reference: reference, runways: runways, circuits: circuits,
                                         windFrom: windFrom, parachuting: airportDataService.hasParachuting(ident),
                                         pattern: pattern)
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

        // One map whatever the layer: a swisstopo chart as an overlay, Apple's as the map type. Two views, one per
        // kind, rebuilt the map at every switch between them and at the edge of the charts. (6.7.0)
        // Always pass offlineMapManager so cache can be used opportunistically
        // In offline mode, only force ICAO if Segelflug cache is not available
        let effectiveForceICAO = appState.settings.forceICAOChartLayer || (isOfflineMode && !hasFullOfflineSupport)
        AeroMapView(
            layerType: isOfflineMode ? .icao : shownLayer,
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
            legsBand: legsBand,
            onOpenOfficialChart: { openURL($0) },
            onOpenAerodromeNote: { aerodromeNote = $0 },
            isInFlight: appState.isFlightActive,
            features: dryRunSession == nil ? .navigation : .dryRun
        )
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

    /// The scale bar and the offline/cache badge, bottom left over Plan › Map's chart. (Its undo toast, for
    /// MARK and the waypoints the flight marks, went with the Cockpit's chart to `CockpitChartChrome` in
    /// 6.2: on the ground there is nothing to take back.)
    private var mapFooter: some View {
        ZStack(alignment: .bottom) {
            // Not with the legs open: the band is a view. (6.1, option C)
            if panelChrome.showsMapStatus {
                HStack(alignment: .bottom) {
                    mapStatus
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .sheet(isPresented: $showCacheInfoModal) { cacheInfoSheet }
    }

    /// The offline/cache badge over the scale bar. A tap on the badge says where the chart comes from.
    private var mapStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if pilotMap.allowanceLevel != .open, !isOfflineMode {
                PilotMapAllowanceLine(downloads: pilotMap, center: mapState.region.center)
                    .modifier(StepsAsideForCallout(isHidden: mapState.isCalloutOpen, reduceMotion: reduceMotion))
                    // The imagery credits move up above the line, never under it.
                    .background(GeometryReader { proxy in
                        Color.clear
                            .onAppear { mapState.footerLift = proxy.size.height + 8 }
                            .onChange(of: proxy.size.height) { _, height in mapState.footerLift = height + 8 }
                    })
                    .onDisappear { mapState.footerLift = 0 }
            }
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
                .modifier(StepsAsideForCallout(isHidden: mapState.isCalloutOpen, reduceMotion: reduceMotion))
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
    private func bottomPanel(legsMaxHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            freqCard
            if navSheetExpanded {
                Rectangle().fill(theme.panelStroke).frame(height: 1)
                SeparateView { legsPanelContent(maxHeight: legsMaxHeight) }
            }
            if showsRoutesRow {
                Rectangle().fill(theme.panelStroke).frame(height: 1)
                routesButtonRow()
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
                        freqCell(tag: L10n.Nav.freqCurrent, tint: theme.onTarget, item: nowFrequency)
                        freqCell(tag: L10n.Nav.freqNext, tint: theme.info, item: nextFrequency)
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
            routesButtonRow()
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
            legsScroll(maxHeight: max(0, maxHeight - emergencyFooterHeight - previewDirectBarHeight))
            previewDirectBar
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
        let fixed = emergencyFooterHeight + previewDirectBarHeight
        return min(legsPanelContentHeight, max(0, maxHeight - fixed)) + fixed
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
            // The leg being flown and NOW / NEXT never under a soft edge (`SharpScrollEdges`). (6.2)
            .modifier(SharpScrollEdges())
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

    /// Time and clock time to the next waypoint at the current ground speed: `NextLegLive`, the one rule
    /// the NEXT cell and the DEST line read too. Nothing below 30 kt: taxiing at 8 kt, the 12 NM to the
    /// first waypoint would read as an hour and a half.
    private var nextLegLive: NextLegLive? {
        guard let loc = locationManager.currentLocation else { return nil }
        return NextLegLive(distanceNM: flightPlanManager.distanceToNextWaypoint(from: loc),
                           groundSpeedKnots: locationManager.currentSpeedKnots)
    }

    /// The legs and every frequency, in Plan › Map's panel. (The Cockpit's are on ROUTE, 6.2.)
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
            MapSheet(selectedLayer: $selectedLayer, shownLayer: shownLayer, isOfflineMode: isOfflineMode, mapCenter: mapState.region.center,
                     mapRegion: mapState.region)
                .environment(appState)
                .environment(\.cockpitTheme, theme)
                .environmentObject(openAIPDataService)
                .environmentObject(dataStatusManager)
                .environmentObject(offlineMapManager)
        }
        .sheet(isPresented: $showAerodromeSearch, onDismiss: showChosenAerodrome) { aerodromeSearchSheet }
    }

    private func mapControls(withZoom: Bool, orientationSegments: Bool = true) -> some View {
        HStack(spacing: CockpitType.size(kneeboard: 10, phone: 8)) {
            aerodromeSearchButton
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

    /// A labelled map control.
    private func chromeButton(icon: String, title: String, prominent: Bool = false,
                              action: @escaping () -> Void) -> some View {
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
            .frame(minHeight: CockpitTarget.control)
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
        Button(action: toggleLegsAndFrequencies) {
            HStack(spacing: CockpitType.size(kneeboard: 16, phone: 10)) {
                freqCell(tag: L10n.Nav.freqCurrent, tint: theme.onTarget, item: nowFrequency)
                Rectangle().fill(theme.panelStroke).frame(width: 1, height: 52)
                freqCell(tag: L10n.Nav.freqNext, tint: theme.info, item: nextFrequency)
                legsChevron
            }
            .padding(.horizontal, CockpitType.size(kneeboard: 16, phone: 12))
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("map.legsToggle")
        // A hint, not a label: a label replaced the station and frequency, so VoiceOver never read the
        // NOW and NEXT frequencies at all. (v6.0 review)
        .accessibilityHint(L10n.Nav.legsAndFrequencies)
    }

    private func freqCell(tag: String, tint: Color, item: PhaseFrequency?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                // On one line, the station's name giving way: the German NÄCHSTE broke over two on an
                // iPhone, "NÄCHST" above "E". (6.5.0, screenshots)
                Text(tag)
                    .font(.aero(size: CockpitType.label, weight: .bold))
                    .foregroundColor(tint)
                    .fixedSize()
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
                VStack(alignment: .leading, spacing: 12) {
                    // Over both columns, at the panel's width: beside the frequencies its figures had
                    // no room. (6.2)
                    destinationLine
                    LegsPanelColumns {
                        legsColumn
                        freqColumn(large: true)
                    }
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
            waypointList(plan: plan, large: true)
        }
    }

    /// The Cockpit's DEST line, in place of the "DEST · NM · ETA" row and the progress bar with its dots
    /// under the legs. Without the route to scale since 6.3.0 (the author's fix9-4): the legs show how the
    /// waypoints split the route.
    @ViewBuilder
    private var destinationLine: some View {
        if let plan = flightPlanManager.activeFlightPlan,
           let estimate = DestinationEstimator.estimate(DestinationInput(
               plan: plan, location: locationManager.currentLocation,
               groundSpeedKnots: locationManager.currentSpeedKnots)) {
            // Never wider than the panel: in a narrow window it widened the panel, then the map pane.
            OfferedWidth {
                // One line, without the route to scale: each leg below shows its distance. (6.3.0, fix9-4)
                DestinationLine(estimate: estimate, scale: CockpitScale.current,
                                onResumeRoute: { flightPlanManager.resumeRoute() }, showsTrack: false)
            }
        }
    }

    /// Routes alone on the ground (Plan › Map). (In the Cockpit, with no route, Routes is in the act
    /// band, where MARK would be.)
    private func routesButtonRow() -> some View {
        HStack(spacing: CockpitType.size(kneeboard: 12, phone: 8)) {
            routesButton()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func routesButton() -> some View {
        chromeButton(icon: "point.topleft.down.to.point.bottomright.curvepath", title: L10n.Ground.planRoutes) {
            if let onShowRoutes { onShowRoutes() } else { showFlightPlanning = true }
        }
    }

    private var liveBearingText: String? {
        guard let loc = locationManager.currentLocation,
              let brg = flightPlanManager.bearingToNextWaypoint(from: loc) else { return nil }
        return NextWaypointReadout.bearing(brg)
    }

    // MARK: - Phase-aware frequencies (v4 UI/UX Revamp C2)

    /// Plan › Map's frequencies: NOW and NEXT, then every station along the way behind "All
    /// frequencies", Emergency last (`PhaseFrequencyPlanner`), and the same list to the Watch. Cached,
    /// recomputed on the phase, the leg, new data and a real move, since it asks for the nearest airports.
    /// The Cockpit's map reads `CockpitRadio`'s instead, which follows the flight on every page and sends
    /// the Watch its list: nothing to do here. (v4 UI/UX Revamp C2; 6.2)
    private func recomputePhaseFrequencies() {
        guard chrome == .plan else { return }
        let items = PhaseFrequencyPlanner.plan(
            position: locationManager.currentLocation?.coordinate, plan: flightPlanManager.activeFlightPlan,
            circuits: appState.isCircuitMode,
            sources: .live(airports: airportDataService, openAIP: openAIPDataService)).panel
        phaseFreqItems = items
        // Mirror this exact list (content + NOW/NEXT + order) to the Apple Watch. (Watch freq sync)
        WatchConnectivityManager.shared.updatePanelFrequencies(items.map(\.watchInfo))
    }

    // MARK: - Track vector (v4 UI/UX Revamp C4)

    /// Update the EMA of ground speed + ground track on each GPS fix. Track is averaged via sin/cos so
    /// it never wraps; α≈0.15 favours recent fixes (~10 s time constant). (v4 UI/UX Revamp C4)
    private func updateTrackVectorEMA() {
        if let c = locationManager.currentLocation?.coordinate { lastKnownCoordinate = c }
        let gs = max(0, locationManager.currentSpeedKnots)
        let alpha = 0.15
        #if DEBUG
        // A screenshot scene holds one fix: the vector is its course and speed at once, not a mean that leaves the
        // simulator's own fix behind over minutes and points elsewhere in each shot. (screenshot run, 6.6.0)
        if MarketingLocationProvider.shared.isActive, let course = locationManager.currentCourseDegrees {
            smoothedGroundSpeed = gs
            smoothedTrackSin = sin(course * .pi / 180)
            smoothedTrackCos = cos(course * .pi / 180)
            hasTrackVectorEMA = true
            return
        }
        #endif
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
        // On the iPad's open panel, each leg's distance to the route's scale. (6.3.0, fix9-4)
        let longest = large && CockpitScale.current != .phone ? RouteLegRow.longestLegNM(plan) : nil
        return VStack(spacing: 0) {
            ForEach(Array(plan.waypoints.enumerated()), id: \.element.id) { index, wpt in
                waypointRow(plan: plan, index: index, wpt: wpt, compact: compact, large: large, longestLegNM: longest)
                    .id(LegsPanelReveal.RowID(index: index))
                if index < plan.waypoints.count - 1 {
                    Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
                }
            }
        }
    }

    private func waypointRow(plan: FlightPlan, index: Int, wpt: FlightPlanWaypoint, compact: Bool = false,
                             large: Bool = false, longestLegNM: Double? = nil) -> some View {
        let isPast = index < plan.currentWaypointIndex
        let isPreview = previewWaypointIndex == index
        // A previewed waypoint ahead can be flown to straight away, skipping the ones before it, and a
        // waypoint of the route is where a diversion can rejoin it (v5.1): DIRECT is under the legs, the
        // panel's width (`previewDirectBar`), and the row stays as its neighbours. (6.2.0)
        return RouteLegRow(plan: plan, index: index, compact: compact, large: large, isPreview: isPreview,
                           actual: nil, showsFlown: false, longestLegNM: longestLegNM) {
            handleWaypointTap(index: index, plan: plan, isPast: isPast)
        }
    }

    /// The previewed waypoint DIRECT can fly to now, if any (`LegsPanelDirectBar.offers`).
    private var previewDirectTarget: (index: Int, name: String)? {
        // In flight only, as Divert: on the ground it re-armed the route from there before any flight; a
        // route is changed in the route builder. (6.3.0, the author's pick, 11 Oct)
        guard appState.isFlightActive,
              let plan = flightPlanManager.activeFlightPlan, let index = previewWaypointIndex,
              plan.waypoints.indices.contains(index),
              LegsPanelDirectBar.offers(index: index, currentIndex: plan.currentWaypointIndex,
                                        diverting: plan.diversion != nil) else { return nil }
        let name = plan.waypoints[index].name
        return (index, name.isEmpty ? "WPT \(index + 1)" : name)
    }

    /// DIRECT to the previewed waypoint, under the legs and over Emergency, while one is previewed.
    @ViewBuilder
    private var previewDirectBar: some View {
        if let target = previewDirectTarget {
            LegsPanelDirectBar(waypointName: target.name) {
                flightPlanManager.directTo(waypointAt: target.index)
                previewWaypointIndex = nil
                // It re-centred the map on the aircraft. The band now frames the new leg, and the map follows
                // the aircraft once the panel closes. (6.1, option C)
                cameraBeforeLegs?.following = true
            }
            .padding(.horizontal, 16)
        }
    }

    /// What `previewDirectBar` takes of the panel's height while it shows.
    private var previewDirectBarHeight: CGFloat {
        previewDirectTarget == nil ? 0 : LegsPanelDirectBar.height
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
    /// one (on the ground, the leg ending at that waypoint: `legsBand`). The map the pilot left isn't touched, so closing the panel still puts it back. (It centred the
    /// map on the waypoint, under the panel; 6.1, option C)
    private func previewWaypoint(index: Int, plan: FlightPlan) {
        guard plan.waypoints.indices.contains(index) else { return }
        if previewWaypointIndex == index || index == plan.currentWaypointIndex {
            previewWaypointIndex = nil
        } else {
            previewWaypointIndex = index
        }
    }

    // MARK: - Divert (v5.1)

    /// "Divert here" in an airport's callout: in flight only, like the act band's Divert, whose sheet it
    /// opens on the field. Plan › Map on the ground is this same map, and with a route armed the callout
    /// offered it there too, leaving a diversion on the route before the flight existed. (v6.0 review,
    /// 1694b7c; found by the 6.0 manual)
    private var airportDivert: ((String) -> Void)? {
        guard appState.isFlightActive, let onDivert else { return nil }
        return { ident in onDivert(ident) }
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
    /// viewport is smaller. (v4.4.0 device-test feedback)
    @ViewBuilder
    private var routeOffScreenPill: some View {
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
        // MAP showing a leg from ROUTE: Centre is "Back to aircraft", the pilot's zoom with it. (6.2)
        if framedLeg != nil {
            backToAircraft()
            return
        }
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

    // MARK: - The Cockpit's chart (6.2, PR 4)

    /// The Cockpit's MAP: the chart, the aircraft, the route and the airspace, and over them only the
    /// chrome of `CockpitChartChrome` (the stack at the right edge, the status slot at the top left, the
    /// edge arrow once panned, the scale while zooming). A leg shown from ROUTE has its bar along the foot,
    /// left of the stack.
    private var cockpitMapArea: some View {
        cockpitChartPresentations(
            chartWithChrome(top: EmptyView(), bottom: cockpitLegBar)
                .overlay { SeparateView { cockpitChartChrome } })
    }

    /// The chrome, wired to this map.
    private var cockpitChartChrome: some View {
        CockpitChartChrome(mapState: mapState, networkMonitor: dataStatusManager.networkMonitor,
                           orientation: mapOrientationMode, isFollowingAircraft: isFollowingAircraft,
                           airspaceNeedsAttention: airspaceDataNeedsAttention,
                           selectedLayer: isOfflineMode ? .icao : shownLayer, sigmets: rankedSigmets,
                           showsStack: cockpitShowsStack, footRoom: cockpitLegFootRoom,
                           actions: MapChromeActions(
                               toggleOrientation: { toggleOrientation() },
                               showLayers: { showMapSheet = true },
                               centre: { centerOnAircraft() },
                               zoomIn: { zoom(by: 0.5) },
                               zoomOut: { zoom(by: 2.0) },
                               openStatus: { openStatus($0) }))
            .onPreferenceChange(MapStatusShownKey.self) { mapStatusShown = $0 }
    }

    /// The Cockpit chart's sheets (the layers, where the chart comes from) and More's requests (the whole
    /// route, the SIGMETs).
    private func cockpitChartPresentations(_ content: some View) -> some View {
        content
            .sheet(isPresented: $showMapSheet) { mapSheet }
            .sheet(isPresented: $showCacheInfoModal) { cacheInfoSheet }
            .onChange(of: cockpitMap?.wholeRouteRequest) { _, _ in fitActiveRoute() }
            .onChange(of: cockpitMap?.hazardsRequest) { _, _ in showSigmets = true }
    }

    /// A tap on the status slot: what the state is about.
    private func openStatus(_ status: CockpitStatus) {
        switch status {
        case .undo: break
        case .gps: onOpenReference?(.gps)
        case .offRoute: frameAircraftAndLeg()
        case .chartOffline: showCacheInfoModal = true
        case .tellFIS: onDivert?(nil)
        case .sigmet: showSigmets = true
        case .briefing(let type): onOpenReference?(type == .departure ? .departureBriefing : .approachBriefing)
        }
    }

    /// OFF ROUTE tapped: the aircraft and the leg it is off, framed clear of the chrome. The aircraft is no
    /// longer followed; centre brings it back.
    private func frameAircraftAndLeg() {
        guard let leg = OffRouteRule.activeLeg(of: flightPlanManager.activeFlightPlan) else { return }
        let coordinates = ([leg.from, leg.to] + [locationManager.currentLocation?.coordinate].compactMap { $0 })
            .filter(CLLocationCoordinate2DIsValid)
        isFollowingAircraft = false
        mapState.pendingFitPadding = cockpitFramingPadding
        mapState.pendingFitCoordinates = coordinates
        mapState.objectWillChange.send()   // the fit isn't @Published; nudge updateUIView
    }

    /// On the phone a leg's bar takes the chart's foot, and the stack gives way (Back to aircraft is centre
    /// then); the iPad keeps it, the bar left of it.
    private var cockpitShowsStack: Bool {
        !(framedLeg != nil && CockpitScale.current == .phone)
    }

    /// A leg's bar: a control's height and its 8 pt padding.
    private static var legBarHeight: CGFloat { CockpitTarget.control + 16 }

    /// What a leg's bar takes of the chart's foot, with the stack's margin under it.
    private var cockpitLegFootRoom: CGFloat {
        guard framedLeg != nil else { return 0 }
        return Self.legBarHeight + MapChromeGeometry.Metrics(.current).margin
    }

    /// The chrome's frames on this chart, as `CockpitChartChrome` lays them out.
    private var cockpitChromeGeometry: MapChromeGeometry {
        MapChromeGeometry(size: chartGeometry.chartSize, scale: .current, showsStack: cockpitShowsStack,
                          footRoom: cockpitLegFootRoom)
    }

    /// The room around what MAP frames: clear of the chrome, within the caps a short chart needs.
    private var cockpitFramingPadding: UIEdgeInsets {
        LegFraming.edgePadding(chartSize: chartGeometry.chartSize,
                               chrome: cockpitChromeGeometry.framingChrome(statusShown: mapStatusShown))
    }

    /// A leg's bar at the chart's foot, from the left margin to the stack.
    private var cockpitLegBar: some View {
        let margin = MapChromeGeometry.Metrics(.current).margin
        let size = chartGeometry.chartSize
        let frame = cockpitChromeGeometry.legBarFrame(height: Self.legBarHeight)
        let trailing = size.width > 0 ? max(margin, size.width - frame.maxX) : margin
        return framedLegBar
            .padding(.leading, margin)
            .padding(.trailing, trailing)
            .padding(.bottom, margin)
    }

    // MARK: - A leg from ROUTE (6.2, the plan's Q7)

    /// The leg ROUTE asked MAP to show (the index of the waypoint it arrives at), in the Cockpit only.
    private var framedLeg: Int? {
        chrome == .plan ? nil : cockpitNav?.framedLeg
    }

    /// The zoom to come back to: the camera's distance and the region's span.
    struct LegZoom: Equatable {
        let distance: Double
        let latitudeDelta: Double
    }

    /// The leg framed: its two waypoints, clear of the chrome over the chart and of the bar at its foot, the
    /// aircraft no longer followed.
    private func frameRequestedLeg() {
        legFramePending = false
        guard let index = framedLeg, let plan = flightPlanManager.activeFlightPlan else { return }
        let coordinates = LegFraming.coordinates(of: plan, leg: index)
        guard !coordinates.isEmpty else {
            backToAircraft()
            return
        }
        isFollowingAircraft = false
        mapState.pendingFitPadding = cockpitFramingPadding
        mapState.pendingFitCoordinates = coordinates
        mapState.objectWillChange.send()   // the fit isn't @Published; nudge updateUIView
        // Appearing, the map view may not have its size yet, and keeps the fit pending: once more when
        // it has. (6.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [mapState] in
            if mapState.pendingFitCoordinates != nil { mapState.objectWillChange.send() }
        }
    }

    /// Back to the aircraft, followed again at the zoom the pilot had before the leg.
    private func backToAircraft() {
        cockpitNav?.endLegFraming()
        legFramePending = false
        isFollowingAircraft = true
        guard let zoom = zoomBeforeLeg else { return }
        zoomBeforeLeg = nil
        let center = locationManager.currentLocation?.coordinate ?? mapState.region.center
        mapState.cameraDistance = zoom.distance
        mapState.updateFromRegion(MKCoordinateRegion(
            center: center, span: MKCoordinateSpan(latitudeDelta: zoom.latitudeDelta, longitudeDelta: zoom.latitudeDelta)))
        if mapOrientationMode == .trackUp, let course = locationManager.currentCourseDegrees {
            mapState.cameraHeading = course
        }
    }

    /// While a leg shows: "Back to aircraft" and the leg's DIRECT or RESUME LEG (with its confirmation), at
    /// the chart's foot.
    @ViewBuilder
    private var framedLegBar: some View {
        if let index = framedLeg, let plan = flightPlanManager.activeFlightPlan, plan.waypoints.indices.contains(index) {
            let name = plan.waypoints[index].name.isEmpty ? "WPT \(index + 1)" : plan.waypoints[index].name
            FramedLegBar(waypointName: name,
                         action: LegFraming.action(leg: index, nextIndex: plan.currentWaypointIndex,
                                                   diverting: plan.diversion != nil),
                         onBack: { backToAircraft() },
                         onDirect: {
                             flightPlanManager.directTo(waypointAt: index)
                             backToAircraft()
                         },
                         onResume: { legResumeTarget = index })
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
    /// Listen-only: the destination's ATIS, an aerodrome on the way. Tagged LISTEN. (6.4.2)
    var listen = false
    /// An airspace named beside the station: a TMA the FIS clears. (6.4.2)
    var note: String? = nil
    /// Off the route: a CTR around the aircraft the route doesn't enter, listed on ROUTE under its own heading
    /// after the route's calls (the author's device check r3-6, 6.4.2).
    var nearby = false
    /// NEXT is due: the pilot is expected to switch now (the frequency handover, 6.4.3).
    var due = false
    /// While due, the share still to go before the app switches by itself, 1 to 0. (6.4.3)
    var dueLeft: Double? = nil

    /// The station with what is named beside it: "Geneva Info · TMA GENEVA".
    var stationWithNote: String { note.map { "\(station) · \($0)" } ?? station }
}

enum SwissCommonFrequency: CaseIterable {
    case genevaInfo
    case zurichInfo
    case emergency

    /// As RADIO shows a FIS from the data (`FISSectors.displayName`): "ZÜRICH INFORMATION" → "Zürich Info".
    /// Until 6.2 the table also had "FIS West" 119.175 (Alps Radar, the Geneva side's class C, not a FIS)
    /// and "FIS East" 125.225 (no Swiss frequency at all: Langen Radar, in Germany).
    var name: String {
        switch self {
        case .genevaInfo: return "Geneva Info"
        case .zurichInfo: return "Zürich Info"
        case .emergency: return L10n.Nav.freqEmergency
        }
    }

    var frequency: String {
        switch self {
        case .genevaInfo: return "126.350"
        case .zurichInfo: return "124.700"
        case .emergency: return "121.500"
        }
    }
}

/// The two Swiss FIS sectors: Zürich Information's and Geneva Information's.
enum SwissAirspaceSector {
    case zurich
    case geneva
}

/// The Swiss FIS split as published, for when the downloaded airspace data has no FIS sectors (`FISSectors`).
struct SwissAirspaceSectors {
    /// Check if a coordinate is within Swiss airspace bounds (approximate)
    static func isInSwitzerland(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude >= 45.8 && coordinate.latitude <= 47.9 &&
        coordinate.longitude >= 5.9 && coordinate.longitude <= 10.6
    }

    /// The line between the two sectors, from the French border on the Doubs (south-west of
    /// Saignelégier) to the Italian border near Binn: the open flightmaps sector boundary (OFMX `LSA62`
    /// GENEVA / `LS121` ZURICH, AIRAC 2610), the dashed CTA ZURICH / CTA GENEVA line of the eVFR Manual's
    /// COM 2-APP 2, and OpenAIP's two FIS sectors along it. (6.2)
    static let boundary: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 47.242778, longitude: 6.955278),   // 47°14'34"N 006°57'19"E
        CLLocationCoordinate2D(latitude: 46.769722, longitude: 7.503889),   // 46°46'11"N 007°30'14"E
        CLLocationCoordinate2D(latitude: 46.509722, longitude: 7.802500),   // 46°30'35"N 007°48'09"E
        CLLocationCoordinate2D(latitude: 46.514167, longitude: 7.991389),   // 46°30'51"N 007°59'29"E
        CLLocationCoordinate2D(latitude: 46.330833, longitude: 8.223333),   // 46°19'51"N 008°13'24"E
    ]

    /// Geneva's side: the boundary closed round the west and the south, outside the country.
    private static let genevaSide: [CLLocationCoordinate2D] = boundary + [
        CLLocationCoordinate2D(latitude: 45.0, longitude: 8.223333),
        CLLocationCoordinate2D(latitude: 45.0, longitude: 5.0),
        CLLocationCoordinate2D(latitude: 47.242778, longitude: 5.0),
    ]

    /// The sector a point is in. Until 6.2 a line at 7.45° E: Bressaucourt, Delémont, Biel and Grenchen
    /// came out Geneva's, Brig Zurich's.
    static func getSector(for coordinate: CLLocationCoordinate2D) -> SwissAirspaceSector {
        contains(genevaSide, coordinate) ? .geneva : .zurich
    }

    /// Ray casting, as `Airspace.containsPoint`.
    private static func contains(_ polygon: [CLLocationCoordinate2D], _ point: CLLocationCoordinate2D) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.latitude > point.latitude) != (b.latitude > point.latitude),
               point.longitude < (b.longitude - a.longitude) * (point.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

// MARK: - Callouts and the chrome over the chart (6.2.0)

/// Chrome laid over the chart that steps aside while a callout is open, the callout being what the
/// pilot asked to read: faded out rather than removed, so nothing else moves, and neither touchable nor
/// read while hidden. The off-screen route pill covered a callout's title, the scale bar its first
/// button, on the phone's Cockpit MAP.
struct StepsAsideForCallout: ViewModifier {
    let isHidden: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isHidden ? 0 : 1)
            .allowsHitTesting(!isHidden)
            .accessibilityHidden(isHidden)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isHidden)
    }
}

// MARK: - Swiss Scale Bar (mimics SwissTopo style)

struct SwissScaleBar: View {
    let region: MKCoordinateRegion
    var mapWidth: CGFloat = 0  // Actual map width in points, 0 means use fallback
    /// Aviation distance unit: NM (default for the nav map) vs metric. (v4 UI/UX Revamp — configurable in settings)
    var nauticalMiles: Bool = false
    /// The figure's size: 11 pt on Plan › Map; the in-flight label size on the Cockpit's MAP, where it is
    /// read in flight (`MapChromeGeometry.Metrics.textSize`, 20 pt on the iPad, 17 on the phone). (6.3.0)
    var labelSize: CGFloat = 11

    /// The card's padding above and below: less around a figure at the label size, so the card keeps the
    /// 50 pt the Cockpit's chrome gives it (`cardHeight`).
    static func verticalPadding(labelSize: CGFloat) -> CGFloat { labelSize > 11 ? 5 : 8 }

    /// The card's height: the figure's line, 2 pt, the 8 pt bar, the padding.
    static func cardHeight(labelSize: CGFloat) -> CGFloat {
        UIFont.aero(size: labelSize, weight: .medium).lineHeight + 2 + 8 + 2 * verticalPadding(labelSize: labelSize)
    }

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
                .font(.aero(size: labelSize, weight: .medium))
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
        .padding(.horizontal, 8)
        .padding(.vertical, Self.verticalPadding(labelSize: labelSize))
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

/// The markers' images, for both map engines (6.8.0: out of the MapKit delegate).
enum AeroMarkerImages {
    /// Size and colour by the aerodrome's type: blue for the large and medium ones, green for the small.
    static func airport(_ airport: Airport) -> UIImage? {
        switch airport.type {
        case .largeAirport:
            return aeroMarkerSymbol("airplane.circle.fill", color: UIColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 1.0),
                                    pointSize: 20, weight: .medium)
        case .mediumAirport:
            return aeroMarkerSymbol("airplane.circle", color: UIColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 0.9),
                                    pointSize: 16, weight: .medium)
        case .smallAirport:
            return aeroMarkerSymbol("airplane", color: UIColor(red: 0.4, green: 0.7, blue: 0.4, alpha: 0.9),
                                    pointSize: 14, weight: .medium)
        default:
            return aeroMarkerSymbol("circle.fill", color: UIColor.gray, pointSize: 12, weight: .medium)
        }
    }

    static let navaid = aeroMarkerSymbol("hexagon", color: UIColor(red: 1.0, green: 0.72, blue: 0.0, alpha: 1.0), pointSize: 13)

    static let obstacle = aeroMarkerSymbol("exclamationmark.triangle.fill", color: UIColor(red: 0.95, green: 0.5, blue: 0.1, alpha: 1.0),
                                           pointSize: 13)

    static func reportingPoint(compulsory: Bool) -> UIImage? {
        aeroMarkerSymbol(compulsory ? "triangle.fill" : "triangle", color: UIColor(red: 0.85, green: 0.2, blue: 0.6, alpha: 1.0),
                         pointSize: 12)
    }

    /// A route waypoint's numbered disc: the next one bright magenta, the ones flown dimmed. Cached per state.
    static func waypoint(_ annotation: FlightPlanWaypointAnnotation) -> UIImage? {
        if annotation.isCurrentWaypoint {
            return cachedWaypointMarker(number: annotation.waypointIndex + 1, state: "current", iconName: "target",
                                        color: UIColor(red: 1.0, green: 0.0, blue: 0.8, alpha: 1.0))
        } else if annotation.isCompletedWaypoint {
            return cachedWaypointMarker(number: annotation.waypointIndex + 1, state: "completed", iconName: "checkmark.circle.fill",
                                        color: UIColor(red: 0.6, green: 0.3, blue: 0.5, alpha: 0.7))
        }
        return cachedWaypointMarker(number: annotation.waypointIndex + 1, state: "future", iconName: "circle.fill",
                                    color: UIColor(red: 0.9, green: 0.4, blue: 0.7, alpha: 0.9))
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
    /// What the map draws for it where it is: Apple's map outside the Swiss charts. Said under the list when it isn't
    /// the chart picked. (6.5.0)
    var shownLayer: MapLayerType? = nil
    let isOfflineMode: Bool
    /// Where the map is, for the aerodrome procedures' missing-data hint. (6.2.0)
    var mapCenter: CLLocationCoordinate2D? = nil
    /// What the map shows as the sheet opens, for whether the Swiss charts are offered. (6.8.0)
    var mapRegion: MKCoordinateRegion? = nil
    @State private var showCacheInfo = false

    /// The maps for everywhere first, then Switzerland's, each marked so (the author's device check pm-6, 6.8.0):
    /// the Atlas, the aerial imagery, the ICAO chart (with the charts it gives way to), the National Map, SWISSIMAGE.
    static let baseCharts: [MapLayerType] = [.standard, .satellite, .icao, .landeskarten, .swissimage]

    /// The list as offered: the Swiss charts only for a pilot based in Switzerland (an LS… home aerodrome) or while the
    /// map shows part of it, and always the chart in use, so it can be switched away from (the author's answer to
    /// question 13, 30 Oct 2026).
    static func offeredCharts(homeIdent: String?, mapRegion: MKCoordinateRegion?, selected: MapLayerType) -> [MapLayerType] {
        let swiss = (homeIdent?.uppercased().hasPrefix("LS") ?? false)
            || (mapRegion.map(SwissChartCoverage.reaches) ?? true)
        return baseCharts.filter { !$0.isSwissLayer || swiss || $0 == selected }
    }

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
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.close) { dismiss() }
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
                ForEach(Array(Self.offeredCharts(homeIdent: appState.settings.homeAerodromeIdent, mapRegion: mapRegion,
                                                 selected: selectedLayer).enumerated()), id: \.element) { index, layer in
                    if index > 0 { Divider().padding(.leading, 60) }
                    baseChartRow(layer)
                    if layer == .icao && selectedLayer == .icao {
                        icaoEveryZoomRow
                    }
                }
                if let shownLayer, shownLayer != selectedLayer {
                    Divider().padding(.leading, 60)
                    Text(L10n.MapLayer.switzerlandOnly(Self.name(of: selectedLayer), Self.name(of: shownLayer)))
                        .font(.aero(size: 15))
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
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
                // The ICAO chart with the charts it gives way to, in its name, no line under it (the author's device
                // check mp-1, 6.4.2): the National Map too since 6.7.0, as the route builder names it; the glider
                // chart last offline; the ICAO chart alone when forced.
                VStack(alignment: .leading, spacing: 2) {
                    Text(layer == .icao ? Self.icaoName(forced: appState.settings.forceICAOChartLayer, offline: isOfflineMode)
                         : Self.name(of: layer))
                        .font(.aero(size: CockpitType.label, weight: selected ? .bold : .medium))
                        .foregroundColor(theme.textPrimary)
                    if layer.isSwissLayer {
                        Text(L10n.MapLayer.switzerlandOnlyShort)
                            .font(.aero(size: 14))
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

    /// Under the ICAO row while it is the base chart: keep the ICAO chart at every zoom, where it otherwise gives way to
    /// the glider map, then the National Map. From Navigation & Maps, which Settings no longer has (the author's
    /// answer 14 A, 30 Oct 2026). Offline it gives way to the glider map only. (6.8.0)
    private var icaoEveryZoomRow: some View {
        let isOn = appState.settings.forceICAOChartLayer
        return Button {
            appState.settings.forceICAOChartLayer.toggle()
            appState.saveSettings()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.MapLayer.icaoEveryZoom)
                        .font(.aero(size: CockpitType.label, weight: .medium))
                        .foregroundColor(theme.textPrimary)
                    Text(L10n.MapLayer.icaoEveryZoomDetail)
                        .font(.aero(size: 14))
                        .foregroundColor(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.aero(size: 24))
                    .foregroundColor(isOn ? theme.action : theme.textDim)
            }
            .padding(.leading, 60)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("mapSheet.icaoEveryZoom")
    }

    /// The ICAO layer's name by what it shows. (6.7.0)
    static func icaoName(forced: Bool, offline: Bool) -> String {
        forced ? L10n.MapLayer.icao : offline ? L10n.MapLayer.icaoGlider : L10n.MapLayer.icaoGliderNational
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
    /// The download hints' destination: the page of the country under the map in Offline data, or Offline data itself
    /// when the map is over no country (the author's mockup 6, 30 Oct 2026). (v4.2, 6.2.0, 6.8.0)
    @State private var dataRoute: OfflineDataRoute?

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
                            dataRoute = mapCenter
                                .flatMap { CountryBoundaries.shared.countries(near: $0, bufferNm: 0).sorted().first }
                                .map(OfflineDataRoute.country) ?? .offlineData
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
        .sheet(item: $dataRoute) { route in
            OfflineDataRouteView(route: route)
        }
    }

    // MARK: Aerodrome procedures (6.2.0)

    /// Traffic circuits, VFR arrival and departure routes with their sectors, and the glider, UL and
    /// helicopter circuits (and reporting points), from open flightmaps. All off by default; Approach and
    /// Everything turn the first two on.
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
                Button { dataRoute = .country(country) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                            .foregroundColor(theme.action)
                            .accessibilityHidden(true)
                        Text(L10n.VFRMap.downloadHint(OpenAIPConfig.countryName(for: country)))
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
    /// Update re-downloads all OpenAIP layers (airspace + navaids + obstacles + reporting points, and the
    /// aerodromes since 6.4.2) for the cached countries, since they age together, and open flightmaps' VFR
    /// procedures. (v4.1 follow-up)
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
            .union(vfrProcedureService.downloadedCountries)
            .union(OpenAIPAirportDataService.shared.downloadedCountries))
        guard !countries.isEmpty else { return }
        Task {
            await openAIPDataService.downloadData(for: countries)
            await navaidService.downloadData(for: countries)
            await obstacleService.downloadData(for: countries)
            await reportingPointService.downloadData(for: countries)
            // OpenAIP's aerodromes too, for the frequencies' names (8.33 kHz): until 6.4.2 only Settings fetched
            // them. (6.4.2)
            await OpenAIPAirportDataService.shared.downloadData(for: countries)
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

/// A map surface: what it draws and what its taps do, drawn by MapLibre (`PilotMapView`). Until 6.8.0 this was the
/// MapKit view itself; the inputs, the features and the builders shared with the drawing stayed. (6.8.0, PR 9)
struct AeroMapView: View {
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
    /// Opens an aerodrome's official chart from its callout (the browser); nil: no chart in the callouts. (6.2.0)
    var onOpenOfficialChart: ((URL) -> Void)?
    /// A callout's More or Add a note: the pilot's note on that aerodrome. (6.7.0)
    var onOpenAerodromeNote: ((AerodromeRef) -> Void)?
    /// In flight the callouts' controls take the Cockpit's sizes. (6.2.0)
    var isInFlight: Bool = false
    /// What this surface draws and what its taps do; the inputs it leaves out are ignored. (6.7.0)
    var features: MapFeatures = .navigation
    /// The route builder's route, its pins and its editing (`PlannedRouteLayer`). (6.7.0)
    var plannedRoute = PlannedRoute()
    /// The crossed airspace tapped in the route builder's list, drawn brighter. (#4)
    var selectedAirspaceId: String?
    /// Takes the region on every frame of a move, `mapState` only at rest: what follows the map live (the route
    /// builder's profile band) reads it, and nothing else is rebuilt 60 times a second. (6.4.2)
    var liveRegion: LiveMapRegion?

    // The inputs as this surface's features let them through; the MapLibre view reads them too. (6.7.0, 6.8.0)
    var shownAirports: [Airport] {
        guard features.contains(.airports) else { return [] }
        // A searched aerodrome with the layer off: its marker alone, for its card. (6.8.0)
        if let searched = mapState.searchedAerodrome, !visibleAirports.contains(where: { $0.ident == searched.ident }) {
            return visibleAirports + [searched]
        }
        return visibleAirports
    }
    var shownNavaids: [Navaid] { features.contains(.navaids) ? visibleNavaids : [] }
    var shownObstacles: [Obstacle] { features.contains(.obstacles) ? visibleObstacles : [] }
    var shownReportingPoints: [ReportingPoint] { features.contains(.reportingPoints) ? visibleReportingPoints : [] }
    var shownAirspace: [AirspacePolygon] { features.contains(.airspace) ? airspacePolygons : [] }
    private var shownOpenAIPTiles: Bool { features.contains(.openAIPTiles) && showOpenAIPTiles }
    var shownProcedures: VFRMapContent { features.contains(.procedures) ? vfrContent : .empty() }
    var shownPlan: FlightPlan? { features.contains(.route) ? activeFlightPlan : nil }
    var shownAircraft: CLLocation? { features.contains(.aircraft) ? currentLocation : nil }
    var shownTrack: [GPSPoint] { features.contains(.track) ? gpsTrack : [] }
    var shownTrackVector: Bool { features.contains(.trackVector) && trackVectorEnabled }
    var chartOpener: ((URL) -> Void)? { features.contains(.officialChartCallout) ? onOpenOfficialChart : nil }
    var divertHandler: ((String) -> Void)? { features.contains(.divertCallout) ? onAirportDivert : nil }
    var noteOpener: ((AerodromeRef) -> Void)? { features.contains(.noteCallout) ? onOpenAerodromeNote : nil }
    var atoTap: ((Int) -> Void)? { features.contains(.recordATO) ? onWaypointATOTap : nil }
    var shownPlannedRoute: PlannedRoute {
        guard features.contains(.plannedRoute) else { return PlannedRoute() }
        var route = features.contains(.editRoute) ? plannedRoute : plannedRoute.drawnOnly
        if !features.contains(.addToRouteCallout) { route.onPointAdd = nil }
        return route
    }
    var shownAirspaceSelection: String? { features.contains(.airspace) ? selectedAirspaceId : nil }

    /// The ICAO layer's closest camera when it stops at the glider chart (forced, offline). (6.4.2)
    static let icaoGliderClosestDistance: CLLocationDistance = ChartPolicy.gliderClosestDistance

    /// `distance` within `range`.
    static func clamped(_ distance: Double, to range: MKMapView.CameraZoomRange) -> Double {
        min(max(distance, range.minCenterCoordinateDistance), range.maxCenterCoordinateDistance)
    }

    /// The route's lines: what is flown dimmed, what is left bright (dimmed too while diverting, kept for "Resume").
    /// Both map engines draw these. (v5.1, 6.8.0)
    static func routePolylines(for plan: FlightPlan) -> [FlightPlanRoutePolyline] {
        guard plan.waypoints.count >= 2 else { return [] }
        let coordinates = plan.waypoints.map(\.coordinate)
        let current = plan.currentWaypointIndex
        var lines: [FlightPlanRoutePolyline] = []
        if current > 0 {
            let flown = Array(coordinates.prefix(current + 1))
            let line = FlightPlanRoutePolyline(coordinates: flown, count: flown.count)
            line.isCompletedSegment = true
            lines.append(line)
        }
        if current < coordinates.count {
            let left = Array(coordinates.suffix(from: current))
            let line = FlightPlanRoutePolyline(coordinates: left, count: left.count)
            line.isCompletedSegment = plan.diversion != nil
            lines.append(line)
        }
        return lines
    }

    /// The flight's lines as MapKit draws them, for both map engines: the route (magenta, amber when diverting), the
    /// track vector over its casing, the flown track (magenta on the ICAO chart, else the flown-track colour). Nil
    /// for any other overlay. (6.8.0: out of the delegate)
    static func lineRenderer(for overlay: MKOverlay, layerType: MapLayerType) -> MKOverlayRenderer? {
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
            // Bright magenta for visibility on aeronautical charts; gold on the others.
            renderer.strokeColor = layerType == .icao ? UIColor(red: 1.0, green: 0.0, blue: 0.8, alpha: 1.0) : UIColor.flownTrack
            renderer.lineWidth = 3
            return renderer
        }
        return nil
    }

    /// The ownship: the airplane symbol in white with a dark outline (the flight-deck convention; gold sank into the
    /// ICAO chart's own yellows), pointing east (heading 90°). Both map engines draw it. (v6.0 · P5, 6.8.0)
    static let ownshipImage: UIImage? = {
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .bold)
        guard let image = UIImage(systemName: "airplane", withConfiguration: config) else { return nil }
        let strokeWidth: CGFloat = 2.0
        let size = CGSize(width: image.size.width + strokeWidth * 2, height: image.size.height + strokeWidth * 2)
        return UIGraphicsImageRenderer(size: size).image { _ in
            // The outline: offset copies in black, then the symbol in white on top.
            let offsets: [CGPoint] = [
                CGPoint(x: -strokeWidth, y: 0), CGPoint(x: strokeWidth, y: 0),
                CGPoint(x: 0, y: -strokeWidth), CGPoint(x: 0, y: strokeWidth),
                CGPoint(x: -strokeWidth * 0.7, y: -strokeWidth * 0.7), CGPoint(x: strokeWidth * 0.7, y: -strokeWidth * 0.7),
                CGPoint(x: -strokeWidth * 0.7, y: strokeWidth * 0.7), CGPoint(x: strokeWidth * 0.7, y: strokeWidth * 0.7),
            ]
            let outline = image.withTintColor(.black, renderingMode: .alwaysOriginal)
            for offset in offsets { outline.draw(at: CGPoint(x: strokeWidth + offset.x, y: strokeWidth + offset.y)) }
            image.withTintColor(.white, renderingMode: .alwaysOriginal).draw(at: CGPoint(x: strokeWidth, y: strokeWidth))
        }
    }()

    var body: some View {
        PilotMapView(map: self)
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
func subsampledTrackCoordinates(_ track: [GPSPoint]) -> [CLLocationCoordinate2D] {
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
                        Button(L10n.Button.close) { dismiss() }
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

/// A clock HH:mm:ss display (the flight's clock, `FlightClock.now`: the wall clock outside a DEBUG
/// ground replay) that ticks itself once per second via `TimelineView` instead of the
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
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(Self.string(for: FlightClock.now, useUTC: useUTC))
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
        // Listen-only, in NEXT's place or further down ROUTE: LISTEN. (6.4.2)
        if item.listen && item.role != .current { return (L10n.Nav.freqListen, theme.info) }
        switch item.role {
        case .current: return (L10n.Nav.freqCurrent, theme.onTarget)
        case .next: return (L10n.Nav.freqNext, theme.info)
        default: return nil
        }
    }

    private var station: some View {
        Text(item.stationWithNote)
            .font(.aero(size: large ? CockpitType.label : 11, weight: item.highlighted ? .semibold : .regular))
            .foregroundColor(item.isEmergency ? theme.danger : theme.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(large ? 0.7 : 1)
    }

    private var frequencyFont: Font {
        .aero(size: large ? CockpitType.row : 13, weight: item.highlighted ? .bold : .regular, design: .monospaced)
    }

    /// Frequencies are data: white in flight on the kneeboard panel (v6.0 · P5); a CTR off the route as its
    /// station, a step back from the route's calls (6.4.2).
    private var frequencyColor: Color {
        if item.nearby { return theme.textSecondary }
        return item.highlighted && !large ? theme.onTarget : theme.textPrimary
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

    /// A phone's rows, tighter: one line a row with PLAN, ACT and Δ, the name taking what is left (about
    /// 106 pt on an iPhone 17, SAIGNELÉGIER at about 14 pt), where two lines a row left ROUTE's legs "all
    /// over the place" (device check, 11 Oct). PLAN keeps "17:03" (55 pt), Δ "▲15:19" (66 pt) at full size,
    /// and an hour's "1h05" too since 6.3.0 (`ActLegTimer.columnClock`; "1:05:12" shrank to 80 %). (6.2.0)
    static func indexWidth(_ scale: CockpitScale) -> CGFloat { scale == .phone ? 20 : indexWidth }
    static func spacing(_ scale: CockpitScale) -> CGFloat { scale == .phone ? 6 : spacing }
    static func nameGap(_ scale: CockpitScale) -> CGFloat { scale == .phone ? 4 : nameGap }
    static func timeWidth(_ scale: CockpitScale) -> CGFloat { scale == .phone ? 58 : timeWidth }
    static func deltaWidth(_ scale: CockpitScale) -> CGFloat { scale == .phone ? 66 : deltaWidth }
    static func timeSpacing(_ scale: CockpitScale) -> CGFloat { scale == .phone ? 4 : timeSpacing }
    static func horizontalPadding(_ scale: CockpitScale) -> CGFloat { scale == .phone ? 6 : horizontalPadding }

    /// A row without its name.
    static var fixedWidth: CGFloat {
        2 * horizontalPadding + indexWidth + iconWidth + 4 * spacing + nameGap
            + 2 * timeWidth + deltaWidth + 2 * timeSpacing
    }

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
        /// The US traffic patterns' (`NASRPatternService`). (6.5.0)
        var patternsRevision = 0
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
    /// When it was made: it can be taken back for six seconds from then, on any page
    /// (`UndoOfferRule`). (6.2)
    var madeAt = FlightClock.now
    let undo: () -> Void
}

extension NavUndoOffer {
    /// "LSGC marked automatically at 14:37", taken back like a MARK. (v6.0.1)
    @MainActor
    static func autoMark(_ notice: FlightPlanManager.AutoMarkNotice, in manager: FlightPlanManager) -> NavUndoOffer {
        NavUndoOffer(id: notice.id,
                     message: L10n.Nav.markedAutomaticallyAt(notice.waypointName,
                                                             notice.passedAt.formatted(date: .omitted, time: .shortened)),
                     style: .outlined, madeAt: notice.madeAt) {
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
                     style: .outlined, madeAt: confirmation.confirmedAt) {
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
                     style: .outlined, madeAt: confirmation.doneAt) {
            appState.undoFredaConfirmation(confirmation.id)
        }
    }
}

extension NavUndoOffer {
    /// "Go-around detected and recorded", taken back with UNDO: a go-around, touch-and-go or full stop recorded
    /// as soon as it is detected, with no card (6.4.0).
    @MainActor
    static func takenEvent(_ taken: AppState.TakenFlightEvent, in appState: AppState) -> NavUndoOffer {
        NavUndoOffer(id: taken.id, message: L10n.Cockpit.eventTaken(taken.type), madeAt: taken.takenAt) {
            appState.undoTakenEvent(taken.id)
        }
    }
}

extension AppState {
    /// Clears whichever check confirmation `id` is: the toast's six seconds are up.
    func dismissCheckConfirmation(_ id: UUID) {
        dismissMemoryConfirmation(id)
        dismissFredaConfirmation(id)
        dismissTakenEvent(id)
    }
}

/// The undo toast, over a page and never in its layout, for the six seconds of its offer: MARK and the
/// leg-timer reset (the act band's), a waypoint the flight marked on its own, a check just done, on
/// CHECKLIST and ROUTE (MAP has it in its status slot). (v6.0 · C2, v6.0.1)
///
/// On the phone it is compact (6.2): the message on two lines (three at the most) beside an UNDO a control
/// tall (`compactButtonHeight`), about 62 pt in all. With UNDO the 15 mm control of the kneeboard it was
/// 108 pt, and on ROUTE it covered nearly all the legs of a phone's scroll (about 136 pt on an iPhone 17)
/// for its six seconds.
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
    /// The phone's UNDO: a control's height (50 pt), over the 44 pt minimum, so the toast leaves the page
    /// under it in view. (6.2)
    static var compactButtonHeight: CGFloat { CockpitTarget.control(.phone) }

    /// The toast's sizes: the kneeboard's (the iPad's), or the phone's compact one.
    struct Metrics: Equatable {
        /// The message and UNDO: the in-flight label size, the phone's when compact.
        let textSize: CGFloat
        let buttonHeight: CGFloat
        let buttonMinWidth: CGFloat
        let messageLines: Int
        let spacing: CGFloat
        let leading: CGFloat
        let trailing: CGFloat
        let vertical: CGFloat
        let cornerRadius: CGFloat
        let buttonCornerRadius: CGFloat

        init(compact: Bool) {
            textSize = CockpitType.label(for: compact ? .phone : .kneeboard)
            // The 15 mm control on the kneeboard (`CockpitTarget.transient`'s 78 pt).
            buttonHeight = compact ? NavUndoToast.compactButtonHeight : CockpitType.size(kneeboard: 78, phone: 92, scale: .kneeboard)
            // "ANNULER" at the label size, with its margins.
            buttonMinWidth = compact ? 96 : 104
            // Three on the phone where it must, never cut: a 12-letter waypoint, in French, with a
            // 12-hour clock ("SAIGNELÉGIER marqué automatiquement à 10:58 PM"). Two otherwise.
            messageLines = compact ? 3 : 2
            spacing = compact ? 10 : 16
            leading = compact ? 14 : 18
            trailing = compact ? 6 : 8
            vertical = compact ? 6 : 8
            cornerRadius = compact ? 14 : 16
            buttonCornerRadius = compact ? 10 : 12
        }
    }


    @Environment(\.cockpitTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let offer: NavUndoOffer
    /// Compact on the phone, whose pages are short. Tests set it.
    var compact = CockpitScale.current == .phone
    /// Clears the offer: after UNDO, or when its six seconds are up.
    let onDismiss: () -> Void

    var body: some View {
        let metrics = Metrics(compact: compact)
        HStack(spacing: metrics.spacing) {
            Text(offer.message)
                .font(.aero(size: metrics.textSize, weight: .semibold))
                .foregroundColor(theme.textPrimary)
                .lineLimit(metrics.messageLines)
                // The phone's message takes all the room beside UNDO: a spacer there cost it the stack's
                // spacing twice, a line on the longest messages.
                .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
                .accessibilityIdentifier("undoToast.message")
            if !compact { Spacer(minLength: 8) }
            Button {
                offer.undo()
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { onDismiss() }
            } label: {
                Text(L10n.Nav.undo.uppercased())
                    .font(.aero(size: metrics.textSize, weight: .heavy))
                    .lineLimit(1)
                    .foregroundColor(offer.style == .filled ? theme.actionText : theme.action)
                    .frame(minWidth: metrics.buttonMinWidth, minHeight: metrics.buttonHeight)
                    .background(buttonShape(metrics))
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("undoToast.undo")
        }
        .padding(.leading, metrics.leading)
        .padding(.trailing, metrics.trailing)
        .padding(.vertical, metrics.vertical)
        .background(RoundedRectangle(cornerRadius: metrics.cornerRadius).fill(theme.panel.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: metrics.cornerRadius).stroke(theme.panelStroke, lineWidth: 1))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .modifier(UndoOfferExpiry(offer: offer, onDismiss: onDismiss))
    }

    @ViewBuilder
    private func buttonShape(_ metrics: Metrics) -> some View {
        let shape = RoundedRectangle(cornerRadius: metrics.buttonCornerRadius)
        switch offer.style {
        case .filled: shape.fill(theme.action)
        case .outlined: shape.strokeBorder(theme.action, lineWidth: 2)
        }
    }
}

/// An offer's six seconds, counted from when it was made, not from when its view came (`UndoOfferRule`):
/// a page switch doesn't give it six more. VoiceOver hears the message once, when it comes. (6.2)
struct UndoOfferExpiry: ViewModifier {
    let offer: NavUndoOffer
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.task(id: offer.id) {
            let left = UndoOfferRule.remaining(offer.madeAt)
            if left > UndoOfferRule.window - 1 { AccessibilityNotification.Announcement(offer.message).post() }
            try? await Task.sleep(for: .seconds(left))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { onDismiss() }
        }
    }
}

extension NavUndoOffer {
    /// The one offer to show (`UndoOfferRule`): the newest made, for its six seconds, whichever kind it is
    /// (a check just confirmed, a waypoint the flight marked, the act band's MARK or reset); an older one
    /// never again. `flightOnly`: the confirmations and the marks only in flight, as on MAP
    /// (`CockpitChartChrome`). (6.1; the rule 6.2)
    @MainActor
    static func shown(in appState: AppState, flightPlanManager: FlightPlanManager, cockpitNav: CockpitNavState?,
                      flightOnly: Bool) -> NavUndoOffer? {
        let inFlight = !flightOnly || appState.isFlightActive
        // Two made at the same instant: the check, then the waypoint, then the band, as before.
        var offers: [NavUndoOffer] = []
        if inFlight {
            if let memory = appState.memoryConfirmation { offers.append(.memoryConfirmation(memory, in: appState)) }
            if let freda = appState.fredaConfirmation { offers.append(.fredaConfirmation(freda, in: appState)) }
            if let taken = appState.takenFlightEvent { offers.append(.takenEvent(taken, in: appState)) }
            if let notice = flightPlanManager.autoMarkNotice { offers.append(.autoMark(notice, in: flightPlanManager)) }
        }
        if let band = cockpitNav?.undoOffer { offers.append(band) }
        let lastMadeAt = UndoOfferRule.lastMadeAt(inFlight ? appState.lastCheckOfferAt : nil,
                                                  inFlight ? flightPlanManager.lastAutoMarkOfferAt : nil,
                                                  cockpitNav?.lastOfferAt)
        let current = UndoOfferRule.current(offers.map { .init(id: $0.id, madeAt: $0.madeAt) }, lastMadeAt: lastMadeAt)
        return offers.first { $0.id == current?.id }
    }
}

/// The Cockpit's checklist page host for a waypoint the flight marked on its own, a memory check just
/// confirmed with ✓ DONE or a FREDA just done (6.1), and the act band's MARK or reset (More's reset is
/// on this page too since 6.2): the map page has its own, in the status slot (`CockpitChartChrome`).
/// (v6.0.1)
struct AutoMarkUndoToast: View {
    /// The phone's narrower margins.
    var narrow = false
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @Environment(AppState.self) private var appState
    @Environment(CockpitNavState.self) private var cockpitNav: CockpitNavState?

    var body: some View {
        ZStack(alignment: .bottom) {
            if let offer = NavUndoOffer.shown(in: appState, flightPlanManager: flightPlanManager,
                                              cockpitNav: cockpitNav, flightOnly: false) {
                NavUndoToast(offer: offer) {
                    if offer.id == cockpitNav?.undoOffer?.id { cockpitNav?.undoOffer = nil }
                    flightPlanManager.dismissAutoMarkNotice(offer.id)
                    appState.dismissCheckConfirmation(offer.id)
                }
                .coachTarget(.undoToast)
                .padding(.horizontal, narrow ? 12 : 16)
                .padding(.bottom, 8)
            }
        }
        .modifier(UndoOfferFollower(cockpitNav: cockpitNav))
    }
}

/// The toasts' animations, and the newer offer withdrawing the band's older one: a waypoint the flight
/// marked on its own, or a check just confirmed, supersedes the undo of an older MARK or reset.
struct UndoOfferFollower: ViewModifier {
    let cockpitNav: CockpitNavState?
    @Environment(AppState.self) private var appState
    @EnvironmentObject private var flightPlanManager: FlightPlanManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: flightPlanManager.autoMarkNotice?.id)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: appState.memoryConfirmation?.id)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: appState.fredaConfirmation?.id)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: appState.takenFlightEvent?.id)
            .onChange(of: flightPlanManager.autoMarkNotice?.id) { _, id in
                if id != nil { cockpitNav?.undoOffer = nil }
            }
            .onChange(of: appState.memoryConfirmation?.id) { _, id in
                if id != nil { cockpitNav?.undoOffer = nil }
            }
            .onChange(of: appState.fredaConfirmation?.id) { _, id in
                if id != nil { cockpitNav?.undoOffer = nil }
            }
            .onChange(of: appState.takenFlightEvent?.id) { _, id in
                if id != nil { cockpitNav?.undoOffer = nil }
            }
    }
}

/// Plan › Map's line once 80 % of the month's online map is used, or all of it: what that means, and the download of
/// the region under the chart when it isn't on the device. Never in the Cockpit: nothing comes up in flight. (6.8.0)
struct PilotMapAllowanceLine: View {
    @ObservedObject var downloads: PilotMapDownloads
    let center: CLLocationCoordinate2D
    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        let region = downloads.missingRegion(at: center)
        HStack(spacing: 10) {
            Image(systemName: "map")
                .accessibilityHidden(true)
            Text(downloads.allowanceLevel == .exhausted ? L10n.PilotMap.lineExhausted : L10n.PilotMap.lineNear)
                .fixedSize(horizontal: false, vertical: true)
            if let region {
                if case let .downloading(fraction) = downloads.state(of: region.id) {
                    Text(L10n.PilotMap.downloading(fraction))
                        .monospacedDigit()
                } else {
                    Button(L10n.PilotMap.lineDownload(region.displayName)) { downloads.download(region) }
                        .font(.aero(size: 13, weight: .bold))
                        .foregroundColor(theme.action)
                        .frame(minHeight: 44)
                }
            }
        }
        .font(.aero(size: 13, weight: .semibold))
        .foregroundColor(theme.textPrimary)
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(theme.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.warning.opacity(0.8), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("map.allowanceLine")
    }
}

