import Foundation
import CoreGraphics
import CoreLocation
import MapKit

// MARK: - The status slot

/// What the MAP page's status slot shows: one state at a time, the highest of those pending; the
/// others wait their turn. The view words them and picks the colour from `tone`. (6.2.0)
enum CockpitStatus: Equatable {
    /// The pilot's own tap to take back: MARK, the leg-timer reset, a memory check or FREDA done, or a
    /// waypoint the flight marked on its own. Six seconds (`NavUndoToast`).
    case undo
    /// GPS DEGRADED (amber), or NO GPS (red): lost, or a flight not recording.
    case gps(GPSAlarm)
    /// OFF ROUTE x.x NM (amber): the cross-track distance to the leg being flown.
    case offRoute(crossTrackNM: Double)
    /// CHART OFFLINE (amber): the chart on screen can neither be fetched nor drawn from the cache.
    case chartOffline
    /// "Tell FIS: diverting to LSGC" (amber): diverting with an ATC flight plan still open.
    case tellFIS(field: String)
    /// A SIGMET on the aircraft's path (amber): the one the slot names.
    case sigmet(summary: String)
    /// BRIEFING (cyan, touchable): before departure and in the descent.
    case briefing(BriefingType)

    enum GPSAlarm: Equatable {
        case degraded
        case lost
    }

    /// The colour family: the in-flight colour contract (amber caution, red warning, cyan touchable).
    enum Tone: Equatable {
        /// The undo toast's own panel.
        case neutral
        case caution
        case warning
        case action
    }

    var tone: Tone {
        switch self {
        case .undo: return .neutral
        case .gps(.lost): return .warning
        case .gps(.degraded), .offRoute, .chartOffline, .tellFIS, .sigmet: return .caution
        case .briefing: return .action
        }
    }

    /// `status.<state>`, for the UI tests.
    var accessibilityIdentifier: String {
        switch self {
        case .undo: return "status.undo"
        case .gps: return "status.gps"
        case .offRoute: return "status.offRoute"
        case .chartOffline: return "status.chartOffline"
        case .tellFIS: return "status.tellFIS"
        case .sigmet: return "status.sigmet"
        case .briefing: return "status.briefing"
        }
    }
}

/// Which state the slot shows. Pure: the view gathers the inputs and draws the answer. (6.2.0)
///
/// Priority, highest first: UNDO > GPS > OFF ROUTE > CHART OFFLINE > TELL FIS > SIGMET on path >
/// BRIEFING. UNDO comes first because it answers the pilot's own tap and is useless once its six
/// seconds are over; the GPS state stays in the header and the strip's flags meanwhile.
enum CockpitStatusRule {
    struct Inputs: Equatable {
        /// An undo offer is up (`MapUndoToast.shown` would show one).
        var undoOffered = false
        /// `gpsAlarm(isFlightActive:isTracking:signal:isSimulating:)`.
        var gps: CockpitStatus.GPSAlarm?
        /// What `OffRouteRule.update` returned.
        var offRouteNM: Double?
        /// `ChartAvailability.isChartOffline`.
        var chartOffline = false
        /// `tellFIS(diversionIdent:hasOpenATCFlightPlan:)`.
        var tellFISField: String?
        /// The SIGMET on the aircraft's path to name, if any (`sigmetOnPath`).
        var sigmetOnPath: String?
        /// `appState.currentPhase.briefingType`.
        var briefing: BriefingType?
    }

    /// The state the slot shows, or nil for a dark slot.
    static func current(_ inputs: Inputs) -> CockpitStatus? {
        pending(inputs).first
    }

    /// Every state that would show, highest first: the first one shows, the others wait.
    static func pending(_ inputs: Inputs) -> [CockpitStatus] {
        var states: [CockpitStatus] = []
        if inputs.undoOffered { states.append(.undo) }
        if let alarm = inputs.gps { states.append(.gps(alarm)) }
        if let nm = inputs.offRouteNM { states.append(.offRoute(crossTrackNM: nm)) }
        if inputs.chartOffline { states.append(.chartOffline) }
        if let field = inputs.tellFISField { states.append(.tellFIS(field: field)) }
        if let summary = inputs.sigmetOnPath { states.append(.sigmet(summary: summary)) }
        if let briefing = inputs.briefing { states.append(.briefing(briefing)) }
        return states
    }

    /// The header's GPS rule (`FlightView.gpsStatusColor`): a flight that isn't recording is NO GPS,
    /// whatever the signal; then lost or degraded. Nothing while a position is simulated (the header
    /// says "GPS · SIM", and the developer option holds the status at degraded on purpose).
    static func gpsAlarm(isFlightActive: Bool, isTracking: Bool, signal: GPSSignalStatus,
                         isSimulating: Bool) -> CockpitStatus.GPSAlarm? {
        guard !isSimulating else { return nil }
        if isFlightActive && !isTracking { return .lost }
        guard isTracking else { return nil }
        switch signal {
        case .good: return nil
        case .degraded: return .degraded
        case .lost: return .lost
        }
    }

    /// The field to tell FIS about: diverting, with the ATC flight plan filed and still open
    /// (`threadManager.thread(forPlanId:)?.hasOpenFlightPlan`).
    static func tellFIS(diversionIdent: String?, hasOpenATCFlightPlan: Bool) -> String? {
        hasOpenATCFlightPlan ? diversionIdent : nil
    }

    /// The SIGMET for the slot: the first of the ranked hazards on the aircraft's path (inside it, or
    /// across the route). The others go to More: dark cockpit.
    static func sigmetOnPath(_ ranked: [SigmetHazardItem]) -> SigmetHazardItem? {
        ranked.first(where: \.isOnPath)
    }
}

// MARK: - OFF ROUTE

/// OFF ROUTE: the aircraft more than a mile off the leg it is flying. On above 1.0 NM, off again below
/// 0.7 NM, so GPS jitter around one mile doesn't make it blink. A value: the view keeps one and feeds
/// it every fix. (6.2.0)
///
/// Dark unless every condition holds: a leg to fly (the active plan's `currentWaypointIndex` ≥ 1, the
/// leg from waypoint n−1 to n; not the leg to the departure, not after the destination), not
/// diverting, not in circuits, airborne (LINE UP tapped, no landing yet), and good GPS. Suppressed
/// without good GPS, so OFF ROUTE and the GPS state never contradict each other. A suppressed rule
/// starts again from on-route.
///
/// Until 6.2.0 nothing detected an aircraft off its route in flight: the off-screen route pill
/// (`RouteVisibility`) only said where the route was on the map.
struct OffRouteRule {
    /// NM: OFF ROUTE shows above this.
    static let showAboveNM = 1.0
    /// NM: and clears below this.
    static let clearBelowNM = 0.7

    /// The leg being flown: waypoint n−1 to waypoint n.
    struct Leg {
        let from: CLLocationCoordinate2D
        let to: CLLocationCoordinate2D
    }

    struct Input {
        /// Nil when there is no leg to fly (`activeLeg(of:)`).
        var leg: Leg?
        /// Nil with no fix.
        var aircraft: CLLocationCoordinate2D?
        var diverting = false
        var inCircuits = false
        var airborne = false
        /// `gpsIsGood(isTracking:signal:isSimulating:)`.
        var gpsGood = false
    }

    /// Whether OFF ROUTE shows now. The hysteresis's memory.
    private(set) var isOffRoute = false

    /// Feeds one fix: the cross-track distance to show, or nil for no OFF ROUTE.
    mutating func update(_ input: Input) -> Double? {
        let shown = Self.evaluate(input, wasOffRoute: isOffRoute)
        isOffRoute = shown != nil
        return shown
    }

    /// The cross-track distance to show, or nil: the conditions, then the hysteresis.
    static func evaluate(_ input: Input, wasOffRoute: Bool) -> Double? {
        guard let leg = input.leg, let aircraft = input.aircraft,
              !input.diverting, !input.inCircuits, input.airborne, input.gpsGood else { return nil }
        let crossTrack = crossTrackNM(aircraft, leg: leg)
        return isOffRoute(crossTrackNM: crossTrack, wasOffRoute: wasOffRoute) ? crossTrack : nil
    }

    /// On above 1.0 NM, off below 0.7 NM; in between, as it was.
    static func isOffRoute(crossTrackNM: Double, wasOffRoute: Bool) -> Bool {
        guard crossTrackNM.isFinite else { return false }
        return wasOffRoute ? crossTrackNM >= clearBelowNM : crossTrackNM > showAboveNM
    }

    /// NM from the leg's segment (past either end, from that end): the route search's measure.
    static func crossTrackNM(_ aircraft: CLLocationCoordinate2D, leg: Leg) -> Double {
        RoutePointSearch.crossTrackNM(aircraft, leg.from, leg.to)
    }

    /// The leg the active plan flies, or nil: before the take-off marks the departure (n = 0), once the
    /// destination is marked (n ≥ count), or while diverting (the route is not being flown).
    static func activeLeg(of plan: FlightPlan?) -> Leg? {
        guard let plan, plan.diversion == nil else { return nil }
        let next = plan.currentWaypointIndex
        guard next >= 1, next < plan.waypoints.count else { return nil }
        return Leg(from: plan.waypoints[next - 1].coordinate, to: plan.waypoints[next].coordinate)
    }

    /// Airborne for the rule: LINE UP tapped, and no landing since.
    static func isAirborne(lineUpTime: Date?, landingTime: Date?) -> Bool {
        lineUpTime != nil && landingTime == nil
    }

    /// Good GPS for the rule: recording, with a good signal. A simulated position (Developer Options)
    /// counts as good: the developer option holds the status at degraded on purpose, the slot shows no
    /// GPS state for it, and OFF ROUTE is what one simulates a position away from the route to see.
    static func gpsIsGood(isTracking: Bool, signal: GPSSignalStatus, isSimulating: Bool) -> Bool {
        isTracking && (signal == .good || isSimulating)
    }
}

extension OffRouteRule.Input {
    /// The rule's input from the active plan and the flight.
    init(plan: FlightPlan?, aircraft: CLLocationCoordinate2D?, inCircuits: Bool, airborne: Bool, gpsGood: Bool) {
        self.init(leg: OffRouteRule.activeLeg(of: plan), aircraft: aircraft,
                  diverting: plan?.diversion != nil, inCircuits: inCircuits, airborne: airborne, gpsGood: gpsGood)
    }
}

// MARK: - CHART OFFLINE

/// CHART OFFLINE: the chart drawn on screen can neither be fetched (offline mode, or no network) nor
/// drawn from the offline cache (another layer, a zoom outside the cached range, or outside the cache's
/// box around Switzerland). (6.2.0)
///
/// It replaces the map's CACHED / OFFLINE badge, which told the pilot where the tiles came from, a
/// fact with nothing to do: CACHED (online, from the cache) goes dark, and so does OFFLINE wherever the
/// cache covers. Not covered: holes in a partial download (no per-tile check), and the OpenAIP online
/// tiles. Apple's layers, the Landeskarte and SWISSIMAGE count as never cached: MapKit's own cache is
/// not ours to vouch for.
enum ChartAvailability {
    /// The chart the map draws.
    enum Chart: Equatable {
        /// The ICAO chart, cached at `CacheableLayer.icao`'s zooms.
        case icao
        /// The glider chart, which the ICAO layer switches to above zoom 11 (`ICAOSegelflugkarteTileOverlay`).
        case glider
        /// Any other layer: never cached by the app.
        case uncached(MapLayerType)
    }

    struct Input {
        /// The layer the pilot picked (`selectedLayer`).
        var selectedLayer: MapLayerType
        /// `settings.offlineMode`.
        var offlineMode: Bool
        /// `dataStatusManager.networkMonitor.isConnected`.
        var isConnected: Bool
        /// `offlineMapManager.isCacheAvailable`.
        var icaoCached: Bool
        /// `offlineMapManager.isSegelflugCacheAvailable`.
        var gliderCached: Bool
        /// `settings.forceICAOChartLayer`.
        var forceICAOChartLayer: Bool
        /// The map's zoom level (`NavigationMapView.estimatedZoomLevel`).
        var zoom: Int
        /// What the map shows.
        var region: MKCoordinateRegion
    }

    /// Strict offline mode, as the map applies it (`NavigationMapView.isOfflineMode`): the setting, with
    /// an ICAO cache to fall back on. Without one the map ignores the setting and fetches.
    static func isStrictOffline(_ input: Input) -> Bool {
        input.offlineMode && input.icaoCached
    }

    /// Whether the map may fetch tiles: not in strict offline mode, and connected.
    static func isOnline(_ input: Input) -> Bool {
        !isStrictOffline(input) && input.isConnected
    }

    /// The chart on screen, as the map picks it (`mapContent`, `ICAOSegelflugkarteTileOverlay.layerInfo`):
    /// strict mode draws the ICAO layer whatever was picked; the ICAO layer turns to the glider chart
    /// above zoom 11, unless the ICAO chart is forced (the setting, or strict mode without a glider cache).
    static func chartOnScreen(_ input: Input) -> Chart {
        let strict = isStrictOffline(input)
        let layer = strict ? MapLayerType.icao : input.selectedLayer
        guard layer == .icao else { return .uncached(layer) }
        let forceICAO = input.forceICAOChartLayer || (strict && !input.gliderCached)
        return !forceICAO && input.zoom > CacheableLayer.icao.maxZoom ? .glider : .icao
    }

    /// Whether the offline cache can draw the chart on screen: that chart cached, the zoom in its
    /// cached range, and the region over the cache's box.
    static func cacheCovers(_ input: Input) -> Bool {
        let cached: Bool
        let minZoom: Int
        switch chartOnScreen(input) {
        case .icao:
            cached = input.icaoCached
            minZoom = CacheableLayer.icao.minZoom
        case .glider:
            cached = input.gliderCached
            minZoom = CacheableLayer.segelflug.minZoom
        case .uncached:
            return false
        }
        return cached && input.zoom >= minZoom && regionMeetsCacheBox(input.region)
    }

    /// CHART OFFLINE ⇔ not online and not covered by the cache.
    static func isChartOffline(_ input: Input) -> Bool {
        !isOnline(input) && !cacheCovers(input)
    }

    /// Whether any of `region` lies over the box the cache was downloaded for (`OfflineMapManager`).
    static func regionMeetsCacheBox(_ region: MKCoordinateRegion) -> Bool {
        let box = OfflineMapManager.switzerlandBounds
        let halfLat = abs(region.span.latitudeDelta) / 2
        let halfLon = abs(region.span.longitudeDelta) / 2
        return region.center.latitude - halfLat <= box.maxLat
            && region.center.latitude + halfLat >= box.minLat
            && region.center.longitude - halfLon <= box.maxLon
            && region.center.longitude + halfLon >= box.minLon
    }
}

// MARK: - The edge arrow

/// The arrow at the chart's edge pointing to the aircraft once the map is panned away from it. (6.2.0)
enum OwnshipEdgeArrow {
    struct Placement: Equatable {
        /// Where the arrow sits, on the inset rectangle's edge, in the chart's coordinates.
        let point: CGPoint
        /// Where it points: degrees clockwise from the top of the screen (`rotationEffect` of an
        /// arrow drawn pointing up).
        let degrees: Double
    }

    /// The arrow for an aircraft at `aircraft` on a chart of `size` showing `region`, or nil when the
    /// aircraft is on screen (inside the chart less `inset` on every side).
    ///
    /// `heading` is the map camera's: 0 north up, the track in track up, where the chart turns and
    /// MapKit reports the region bounding what is shown. The scale is taken from that region's width
    /// accordingly, so it holds in both orientations.
    static func place(aircraft: CLLocationCoordinate2D, region: MKCoordinateRegion, heading: Double,
                      size: CGSize, inset: CGFloat) -> Placement? {
        guard let point = project(aircraft, region: region, heading: heading, size: size) else { return nil }
        return place(screenPoint: point, size: size, inset: inset)
    }

    /// The aircraft's point on the chart (it may lie off it): its offset from the centre in map
    /// points, scaled, then turned by −heading.
    static func project(_ aircraft: CLLocationCoordinate2D, region: MKCoordinateRegion, heading: Double,
                        size: CGSize) -> CGPoint? {
        guard size.width > 0, size.height > 0, region.span.longitudeDelta > 0,
              CLLocationCoordinate2DIsValid(aircraft), heading.isFinite else { return nil }
        let radians = heading * .pi / 180
        // The region bounds the chart turned by the heading: its width spans W|cos| + H|sin| points.
        let boundingWidth = Double(size.width) * abs(cos(radians)) + Double(size.height) * abs(sin(radians))
        let mapPointsPerPoint = MKMapSize.world.width * region.span.longitudeDelta / 360 / boundingWidth
        let centre = MKMapPoint(region.center)
        let target = MKMapPoint(aircraft)
        let dx = (target.x - centre.x) / mapPointsPerPoint
        let dy = (target.y - centre.y) / mapPointsPerPoint
        // Turned by −heading (screen y points down).
        let x = dx * cos(-radians) - dy * sin(-radians)
        let y = dx * sin(-radians) + dy * cos(-radians)
        return CGPoint(x: Double(size.width) / 2 + x, y: Double(size.height) / 2 + y)
    }

    /// The arrow for a point already on the chart's coordinates (`MKMapView.convert` gives one), or nil
    /// when it is inside the inset rectangle: where the ray from the centre leaves that rectangle.
    static func place(screenPoint point: CGPoint, size: CGSize, inset: CGFloat) -> Placement? {
        let halfWidth = Double(size.width) / 2 - Double(inset)
        let halfHeight = Double(size.height) / 2 - Double(inset)
        guard halfWidth > 0, halfHeight > 0, point.x.isFinite, point.y.isFinite else { return nil }
        let vx = Double(point.x) - Double(size.width) / 2
        let vy = Double(point.y) - Double(size.height) / 2
        guard abs(vx) > halfWidth || abs(vy) > halfHeight else { return nil }
        let scale = min(vx == 0 ? .infinity : halfWidth / abs(vx), vy == 0 ? .infinity : halfHeight / abs(vy))
        var degrees = atan2(vx, -vy) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        if degrees >= 360 { degrees -= 360 }
        return Placement(point: CGPoint(x: Double(size.width) / 2 + vx * scale,
                                        y: Double(size.height) / 2 + vy * scale),
                         degrees: degrees)
    }
}

// MARK: - The scale

/// The chart's scale shows only while the zoom changes: from a change of more than 1 % until 2 s after
/// the last one. Following the aircraft moves the centre, not the zoom, so it never shows it. (6.2.0)
struct ScaleVisibility {
    /// Seconds the scale stays after the last change.
    static let shownFor: TimeInterval = 2
    /// A relative change smaller than this is not a zoom.
    static let threshold = 0.01

    /// The zoom measure the last change was counted from.
    private(set) var reference: Double?
    /// When the zoom last changed.
    private(set) var changedAt: Date?

    /// Notes the zoom now: the camera's distance, or any measure that moves with the zoom and not with
    /// the centre or the heading (a turned chart's region grows with the heading). The first value is
    /// the reference and shows nothing.
    mutating func note(zoom: Double, at now: Date = FlightClock.now) {
        guard zoom.isFinite, zoom > 0 else { return }
        guard let reference else {
            self.reference = zoom
            return
        }
        if abs(zoom - reference) / reference > Self.threshold {
            self.reference = zoom
            changedAt = now
        }
    }

    func isVisible(at now: Date = FlightClock.now) -> Bool {
        guard let hidesAt else { return false }
        return now < hidesAt
    }

    /// When the scale goes, for the view to schedule its fade.
    var hidesAt: Date? {
        changedAt?.addingTimeInterval(Self.shownFor)
    }
}
