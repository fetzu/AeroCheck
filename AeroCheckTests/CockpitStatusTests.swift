import XCTest
import CoreLocation
import MapKit
@testable import AeroCheck

/// The MAP page's status slot and the chart's chrome rules (6.2.0): the slot's priority and each
/// state's inputs, OFF ROUTE with its hysteresis and its suppressions, CHART OFFLINE, the edge arrow
/// and the scale's two seconds.
final class CockpitStatusTests: XCTestCase {

    // MARK: - Priority

    private var everything: CockpitStatusRule.Inputs {
        CockpitStatusRule.Inputs(undoOffered: true, gps: .lost, offRouteNM: 1.4, chartOffline: true,
                                 tellFISField: "LSGC", sigmetOnPath: "TS", briefing: .approach)
    }

    /// UNDO > GPS > OFF ROUTE > CHART OFFLINE > TELL FIS > SIGMET > BRIEFING, one at a time.
    func testTheSlotShowsTheHighestStatePending() {
        XCTAssertEqual(CockpitStatusRule.pending(everything), [
            .undo, .gps(.lost), .offRoute(crossTrackNM: 1.4), .chartOffline, .tellFIS(field: "LSGC"),
            .sigmet(summary: "TS"), .briefing(.approach),
        ])

        var inputs = everything
        XCTAssertEqual(CockpitStatusRule.current(inputs), .undo, "the pilot's own tap first, for its six seconds")
        inputs.undoOffered = false
        XCTAssertEqual(CockpitStatusRule.current(inputs), .gps(.lost))
        inputs.gps = nil
        XCTAssertEqual(CockpitStatusRule.current(inputs), .offRoute(crossTrackNM: 1.4))
        inputs.offRouteNM = nil
        XCTAssertEqual(CockpitStatusRule.current(inputs), .chartOffline)
        inputs.chartOffline = false
        XCTAssertEqual(CockpitStatusRule.current(inputs), .tellFIS(field: "LSGC"))
        inputs.tellFISField = nil
        XCTAssertEqual(CockpitStatusRule.current(inputs), .sigmet(summary: "TS"))
        inputs.sigmetOnPath = nil
        XCTAssertEqual(CockpitStatusRule.current(inputs), .briefing(.approach))
        inputs.briefing = nil
        XCTAssertNil(CockpitStatusRule.current(inputs), "a dark slot")
    }

    /// The others wait: once UNDO's window is over, what was pending shows.
    func testWhenUndoEndsTheWaitingStateShows() {
        var inputs = CockpitStatusRule.Inputs(undoOffered: true, briefing: .departure)
        XCTAssertEqual(CockpitStatusRule.current(inputs), .undo)
        inputs.undoOffered = false
        XCTAssertEqual(CockpitStatusRule.current(inputs), .briefing(.departure))
    }

    func testEachStateHasItsToneAndIdentifier() {
        let expected: [(CockpitStatus, CockpitStatus.Tone, String)] = [
            (.undo, .neutral, "status.undo"),
            (.gps(.degraded), .caution, "status.gps"),
            (.gps(.lost), .warning, "status.gps"),
            (.offRoute(crossTrackNM: 1.2), .caution, "status.offRoute"),
            (.chartOffline, .caution, "status.chartOffline"),
            (.tellFIS(field: "LSGC"), .caution, "status.tellFIS"),
            (.sigmet(summary: "TS"), .caution, "status.sigmet"),
            (.briefing(.departure), .action, "status.briefing"),
        ]
        for (state, tone, identifier) in expected {
            XCTAssertEqual(state.tone, tone, "\(state)")
            XCTAssertEqual(state.accessibilityIdentifier, identifier, "\(state)")
        }
    }

    // MARK: - Each state's inputs

    /// The header's rule: a flight not recording is NO GPS whatever the signal; nothing while simulating.
    func testGPSFollowsTheHeadersRule() {
        func alarm(_ active: Bool, _ tracking: Bool, _ signal: GPSSignalStatus,
                   simulating: Bool = false) -> CockpitStatus.GPSAlarm? {
            CockpitStatusRule.gpsAlarm(isFlightActive: active, isTracking: tracking, signal: signal,
                                       isSimulating: simulating)
        }
        XCTAssertNil(alarm(true, true, .good))
        XCTAssertEqual(alarm(true, true, .degraded), .degraded)
        XCTAssertEqual(alarm(true, true, .lost), .lost)
        XCTAssertEqual(alarm(true, false, .good), .lost, "an active flight not recording loses its track")
        XCTAssertNil(alarm(false, false, .lost), "no flight, no recording: dim in the header, nothing here")
        XCTAssertNil(alarm(true, true, .degraded, simulating: true), "GPS · SIM is held at degraded on purpose")
        XCTAssertNil(alarm(true, false, .lost, simulating: true))
    }

    func testTellFISOnlyWithAnOpenATCFlightPlan() {
        XCTAssertEqual(CockpitStatusRule.tellFIS(diversionIdent: "LSGC", hasOpenATCFlightPlan: true), "LSGC")
        XCTAssertNil(CockpitStatusRule.tellFIS(diversionIdent: "LSGC", hasOpenATCFlightPlan: false))
        XCTAssertNil(CockpitStatusRule.tellFIS(diversionIdent: nil, hasOpenATCFlightPlan: true))
    }

    private func hazard(_ name: String, inside: Bool = false, crossesRoute: Bool = false,
                        distance: Double = 40) -> SigmetHazardItem {
        SigmetHazardItem(
            sigmet: AviationWeatherService.Sigmet(firId: "LSAS", firName: nil, hazard: name, qualifier: nil,
                                                  baseFt: nil, topFt: nil, validFrom: nil, validTo: nil,
                                                  distanceNm: distance, containsPoint: inside, coords: [], raw: nil),
            assessment: SigmetRelevance.Assessment(distanceNm: distance, containsAircraft: inside,
                                                   intersectsRoute: crossesRoute, routeDistanceNm: nil))
    }

    /// Only a SIGMET on the aircraft's path takes the slot; the others go to More.
    func testOnlyASigmetOnThePathTakesTheSlot() {
        let offPath = hazard("ICE", distance: 12)
        XCTAssertNil(CockpitStatusRule.sigmetOnPath([offPath]))
        XCTAssertNil(CockpitStatusRule.sigmetOnPath([]))
        let across = hazard("TURB", crossesRoute: true)
        let inside = hazard("TS", inside: true, distance: 0)
        XCTAssertEqual(CockpitStatusRule.sigmetOnPath([offPath, across])?.sigmet.hazard, "TURB")
        XCTAssertEqual(CockpitStatusRule.sigmetOnPath([inside, across])?.sigmet.hazard, "TS",
                       "the first of the ranked list on the path")
    }

    func testBriefingIsThePhasesBriefing() {
        XCTAssertEqual(ChecklistPhase.beforeDeparture.briefingType, .departure)
        XCTAssertEqual(ChecklistPhase.descent.briefingType, .approach)
        XCTAssertNil(ChecklistPhase.cruise.briefingType)
        let inputs = CockpitStatusRule.Inputs(briefing: ChecklistPhase.descent.briefingType)
        XCTAssertEqual(CockpitStatusRule.current(inputs), .briefing(.approach))
    }

    // MARK: - OFF ROUTE

    /// An east-west leg along 46.5°N, 7.0°E to 7.5°E. A sixtieth of a degree of latitude is a mile.
    private let leg = OffRouteRule.Leg(from: .init(latitude: 46.5, longitude: 7.0),
                                       to: .init(latitude: 46.5, longitude: 7.5))

    private func abeam(_ nm: Double, longitude: Double = 7.25) -> CLLocationCoordinate2D {
        .init(latitude: 46.5 + nm / 60, longitude: longitude)
    }

    private func flying(_ nm: Double) -> OffRouteRule.Input {
        OffRouteRule.Input(leg: leg, aircraft: abeam(nm), airborne: true, gpsGood: true)
    }

    func testCrossTrackIsTheDistanceFromTheLeg() {
        XCTAssertEqual(OffRouteRule.crossTrackNM(abeam(1.2), leg: leg), 1.2, accuracy: 1e-9)
        XCTAssertEqual(OffRouteRule.crossTrackNM(abeam(-0.4), leg: leg), 0.4, accuracy: 1e-9)
        XCTAssertEqual(OffRouteRule.crossTrackNM(abeam(0), leg: leg), 0, accuracy: 1e-9)
    }

    /// Past either end of the leg, the distance is to that end.
    func testPastEitherEndTheDistanceIsToThatEnd() {
        // A mile of longitude at the aircraft's latitude, as the route search's flat projection takes it.
        func degreesEast(_ nm: Double, atLatitude latitude: Double) -> Double {
            nm / (60 * cos(latitude * .pi / 180))
        }
        let beyond = CLLocationCoordinate2D(latitude: 46.5, longitude: 7.5 + degreesEast(2, atLatitude: 46.5))
        XCTAssertEqual(OffRouteRule.crossTrackNM(beyond, leg: leg), 2, accuracy: 1e-9)
        let latitude = 46.5 + 1.5 / 60
        let before = CLLocationCoordinate2D(latitude: latitude,
                                            longitude: 7.0 - degreesEast(2, atLatitude: latitude))
        XCTAssertEqual(OffRouteRule.crossTrackNM(before, leg: leg), 2.5, accuracy: 1e-9)
    }

    /// On above 1.0 NM, off below 0.7 NM; in between it stays as it was.
    func testOffRouteHasHysteresis() {
        var rule = OffRouteRule()
        XCTAssertNil(rule.update(flying(0.5)))
        XCTAssertNil(rule.update(flying(0.95)))
        XCTAssertNil(rule.update(flying(0.99)))
        XCTAssertEqual(try XCTUnwrap(rule.update(flying(1.05))), 1.05, accuracy: 1e-9)
        XCTAssertTrue(rule.isOffRoute)
        XCTAssertEqual(try XCTUnwrap(rule.update(flying(0.8))), 0.8, accuracy: 1e-9, "still off until below 0.7")
        XCTAssertNotNil(rule.update(flying(0.71)))
        XCTAssertNil(rule.update(flying(0.69)))
        XCTAssertFalse(rule.isOffRoute)
        XCTAssertNil(rule.update(flying(0.9)), "back under 1.0: on route again")
        XCTAssertNotNil(rule.update(flying(-1.3)), "either side of the leg")
    }

    func testTheHysteresisAsAPureFunction() {
        XCTAssertFalse(OffRouteRule.isOffRoute(crossTrackNM: 0.85, wasOffRoute: false))
        XCTAssertTrue(OffRouteRule.isOffRoute(crossTrackNM: 0.85, wasOffRoute: true))
        XCTAssertTrue(OffRouteRule.isOffRoute(crossTrackNM: 1.01, wasOffRoute: false))
        XCTAssertFalse(OffRouteRule.isOffRoute(crossTrackNM: 0.6, wasOffRoute: true))
        XCTAssertFalse(OffRouteRule.isOffRoute(crossTrackNM: 1.0, wasOffRoute: false), "above 1.0, not at it")
        XCTAssertTrue(OffRouteRule.isOffRoute(crossTrackNM: 0.7, wasOffRoute: true), "below 0.7, not at it")
        XCTAssertFalse(OffRouteRule.isOffRoute(crossTrackNM: .nan, wasOffRoute: true))
    }

    /// Dark without good GPS, diverting, in circuits, on the ground, with no fix or no leg.
    func testOffRouteIsSuppressedUnlessEveryConditionHolds() {
        let far = flying(3)
        XCTAssertNotNil(OffRouteRule.evaluate(far, wasOffRoute: false))
        var input = far
        input.gpsGood = false
        XCTAssertNil(OffRouteRule.evaluate(input, wasOffRoute: true), "GPS not good: the two never contradict")
        input = far
        input.diverting = true
        XCTAssertNil(OffRouteRule.evaluate(input, wasOffRoute: true), "diverting")
        input = far
        input.inCircuits = true
        XCTAssertNil(OffRouteRule.evaluate(input, wasOffRoute: true), "in circuits")
        input = far
        input.airborne = false
        XCTAssertNil(OffRouteRule.evaluate(input, wasOffRoute: true), "on the ground")
        input = far
        input.aircraft = nil
        XCTAssertNil(OffRouteRule.evaluate(input, wasOffRoute: true), "no fix")
        input = far
        input.leg = nil
        XCTAssertNil(OffRouteRule.evaluate(input, wasOffRoute: true), "no leg to fly")
    }

    /// A suppression starts the rule again from on-route.
    func testASuppressionResetsTheHysteresis() {
        var rule = OffRouteRule()
        XCTAssertNotNil(rule.update(flying(1.2)))
        var degraded = flying(0.8)
        degraded.gpsGood = false
        XCTAssertNil(rule.update(degraded))
        XCTAssertNil(rule.update(flying(0.8)), "0.8 NM shows only on the way down from above 1.0")
    }

    private func plan(next: Int) -> FlightPlan {
        var plan = FlightPlan(waypoints: [
            FlightPlanWaypoint(name: "LSZQ", coordinate: .init(latitude: 47.4247, longitude: 7.1869)),
            FlightPlanWaypoint(name: "WPT", coordinate: .init(latitude: 47.20, longitude: 7.00)),
            FlightPlanWaypoint(name: "LSGC", coordinate: .init(latitude: 47.0839, longitude: 6.7928)),
        ])
        plan.currentWaypointIndex = next
        return plan
    }

    /// The leg is waypoint n−1 to n: none on the way to the departure, none once the destination is
    /// marked, none while diverting.
    func testTheActiveLegIsFromTheLastWaypointToTheNext() throws {
        XCTAssertNil(OffRouteRule.activeLeg(of: nil))
        XCTAssertNil(OffRouteRule.activeLeg(of: plan(next: 0)), "the leg to the departure")
        let second = try XCTUnwrap(OffRouteRule.activeLeg(of: plan(next: 2)))
        XCTAssertEqual(second.from.latitude, 47.20)
        XCTAssertEqual(second.to.latitude, 47.0839)
        XCTAssertNil(OffRouteRule.activeLeg(of: plan(next: 3)), "the destination marked")

        var diverting = plan(next: 2)
        diverting.diversion = Diversion(ident: "LSGN", name: "Neuchâtel", latitude: 46.9575, longitude: 6.8647,
                                        leftRouteAt: 2)
        XCTAssertNil(OffRouteRule.activeLeg(of: diverting))
        let input = OffRouteRule.Input(plan: diverting, aircraft: abeam(5), inCircuits: false, airborne: true,
                                       gpsGood: true)
        XCTAssertTrue(input.diverting)
        XCTAssertNil(OffRouteRule.evaluate(input, wasOffRoute: false))
    }

    /// From the plan, 2 NM off the second leg in flight: OFF ROUTE.
    func testFromThePlanAnAircraftOffTheLegIsOffRoute() throws {
        let flown = plan(next: 2)
        let leg = try XCTUnwrap(OffRouteRule.activeLeg(of: flown))
        let midpoint = CLLocationCoordinate2D(latitude: (leg.from.latitude + leg.to.latitude) / 2,
                                              longitude: (leg.from.longitude + leg.to.longitude) / 2)
        let off = CLLocationCoordinate2D(latitude: midpoint.latitude + 2 / 60, longitude: midpoint.longitude)
        let input = OffRouteRule.Input(plan: flown, aircraft: off, inCircuits: false, airborne: true, gpsGood: true)
        XCTAssertGreaterThan(try XCTUnwrap(OffRouteRule.evaluate(input, wasOffRoute: false)), 1.0)
        let onIt = OffRouteRule.Input(plan: flown, aircraft: midpoint, inCircuits: false, airborne: true, gpsGood: true)
        XCTAssertNil(OffRouteRule.evaluate(onIt, wasOffRoute: false))
    }

    func testAirborneAndGoodGPSForTheRule() {
        let now = Date()
        XCTAssertFalse(OffRouteRule.isAirborne(lineUpTime: nil, landingTime: nil))
        XCTAssertTrue(OffRouteRule.isAirborne(lineUpTime: now, landingTime: nil))
        XCTAssertFalse(OffRouteRule.isAirborne(lineUpTime: now, landingTime: now))

        XCTAssertTrue(OffRouteRule.gpsIsGood(isTracking: true, signal: .good, isSimulating: false))
        XCTAssertFalse(OffRouteRule.gpsIsGood(isTracking: true, signal: .degraded, isSimulating: false))
        XCTAssertFalse(OffRouteRule.gpsIsGood(isTracking: true, signal: .lost, isSimulating: false))
        XCTAssertFalse(OffRouteRule.gpsIsGood(isTracking: false, signal: .good, isSimulating: false))
        XCTAssertTrue(OffRouteRule.gpsIsGood(isTracking: true, signal: .degraded, isSimulating: true),
                      "a simulated position is held at degraded, and OFF ROUTE is what it is for")
    }

    // MARK: - CHART OFFLINE

    private let overSwitzerland = MKCoordinateRegion(center: .init(latitude: 46.8, longitude: 8.2),
                                                     span: .init(latitudeDelta: 1, longitudeDelta: 1.4))
    private let overParis = MKCoordinateRegion(center: .init(latitude: 48.85, longitude: 2.35),
                                               span: .init(latitudeDelta: 1, longitudeDelta: 1.4))

    /// Online, the ICAO chart, both caches downloaded, zoom 9 over Switzerland.
    private func chart(_ layer: MapLayerType = .icao, offlineMode: Bool = false, connected: Bool = true,
                       icao: Bool = true, glider: Bool = false, forceICAO: Bool = false, zoom: Int = 9,
                       region: MKCoordinateRegion? = nil) -> ChartAvailability.Input {
        ChartAvailability.Input(selectedLayer: layer, offlineMode: offlineMode, isConnected: connected,
                                icaoCached: icao, gliderCached: glider, forceICAOChartLayer: forceICAO,
                                zoom: zoom, region: region ?? overSwitzerland)
    }

    private func offline(_ input: ChartAvailability.Input) -> Bool {
        ChartAvailability.isChartOffline(input)
    }

    /// Online, the chart can always be fetched: today's CACHED goes dark, and so does every layer.
    func testOnlineTheChartIsNeverOffline() {
        XCTAssertFalse(offline(chart()), "today's CACHED")
        for layer in MapLayerType.allCases {
            XCTAssertFalse(offline(chart(layer, icao: false, zoom: 14, region: overParis)), "\(layer)")
        }
    }

    /// Strict offline mode (today's red OFFLINE): dark where the cache covers; CHART OFFLINE zoomed out
    /// past 7 or outside Switzerland, network or not.
    func testStrictOfflineModeIsDarkWhereTheCacheCovers() {
        XCTAssertFalse(offline(chart(offlineMode: true)))
        XCTAssertFalse(offline(chart(offlineMode: true, zoom: CacheableLayer.icao.minZoom)))
        XCTAssertTrue(offline(chart(offlineMode: true, zoom: CacheableLayer.icao.minZoom - 1)))
        XCTAssertTrue(offline(chart(offlineMode: true, region: overParis)))
        XCTAssertTrue(offline(chart(offlineMode: true, connected: true, region: overParis)),
                      "strict mode never fetches")
    }

    /// Strict mode draws the ICAO chart whatever was picked.
    func testStrictOfflineModeDrawsTheICAOChart() {
        XCTAssertEqual(ChartAvailability.chartOnScreen(chart(.satellite, offlineMode: true)), .icao)
        XCTAssertFalse(offline(chart(.satellite, offlineMode: true, connected: false)))
    }

    /// The setting without an ICAO cache isn't strict mode: the map ignores it and fetches.
    func testOfflineModeWithoutACacheStillFetches() {
        let input = chart(offlineMode: true, icao: false)
        XCTAssertFalse(ChartAvailability.isStrictOffline(input))
        XCTAssertTrue(ChartAvailability.isOnline(input))
        XCTAssertFalse(offline(input))
        XCTAssertTrue(offline(chart(offlineMode: true, connected: false, icao: false)))
    }

    /// No network on a covered ICAO chart: dark.
    func testNoNetworkOverTheCachedICAOChartIsDark() {
        XCTAssertFalse(offline(chart(connected: false)))
        XCTAssertFalse(offline(chart(connected: false, forceICAO: true, zoom: 13)), "the ICAO chart forced, zoomed in")
    }

    /// No network on any other layer, zoom or area: CHART OFFLINE.
    func testNoNetworkAnywhereElseIsChartOffline() {
        for layer in [MapLayerType.standard, .satellite, .landeskarten, .swissimage] {
            XCTAssertTrue(offline(chart(layer, connected: false)), "\(layer): MapKit's cache is not ours to vouch for")
        }
        XCTAssertTrue(offline(chart(connected: false, zoom: 6)), "zoomed out past the cache")
        XCTAssertTrue(offline(chart(connected: false, region: overParis)), "outside the cache's box")
        XCTAssertTrue(offline(chart(connected: false, icao: false)), "nothing downloaded")
    }

    /// Above zoom 11 the ICAO layer is the glider chart, cached on its own.
    func testTheGliderChartNeedsItsOwnCache() {
        let zoomedIn = CacheableLayer.icao.maxZoom + 1
        XCTAssertEqual(ChartAvailability.chartOnScreen(chart(zoom: zoomedIn)), .glider)
        XCTAssertEqual(ChartAvailability.chartOnScreen(chart(zoom: CacheableLayer.icao.maxZoom)), .icao)
        XCTAssertTrue(offline(chart(connected: false, glider: false, zoom: zoomedIn)))
        XCTAssertFalse(offline(chart(connected: false, glider: true, zoom: zoomedIn)))
        // Forced, the ICAO chart stays, and its cache covers.
        XCTAssertEqual(ChartAvailability.chartOnScreen(chart(forceICAO: true, zoom: zoomedIn)), .icao)
    }

    /// Strict mode draws the glider chart only with its cache; without it the ICAO chart is forced.
    func testStrictOfflineModeTurnsToTheGliderChartOnlyWithItsCache() {
        let zoomedIn = CacheableLayer.icao.maxZoom + 1
        XCTAssertEqual(ChartAvailability.chartOnScreen(chart(offlineMode: true, glider: true, zoom: zoomedIn)), .glider)
        XCTAssertFalse(offline(chart(offlineMode: true, glider: true, zoom: zoomedIn)))
        XCTAssertEqual(ChartAvailability.chartOnScreen(chart(offlineMode: true, glider: false, zoom: zoomedIn)), .icao)
        XCTAssertFalse(offline(chart(offlineMode: true, glider: false, zoom: zoomedIn)))
    }

    /// Any part of the screen over the cache's box counts; the box is the download's own.
    func testTheRegionMeetsTheCacheBoxWhenAnyOfItIsOverIt() {
        XCTAssertTrue(ChartAvailability.regionMeetsCacheBox(overSwitzerland))
        XCTAssertFalse(ChartAvailability.regionMeetsCacheBox(overParis))
        let box = OfflineMapManager.switzerlandBounds
        let straddlingTheWest = MKCoordinateRegion(center: .init(latitude: 46.2, longitude: box.minLon - 0.5),
                                                   span: .init(latitudeDelta: 0.5, longitudeDelta: 1.2))
        XCTAssertTrue(ChartAvailability.regionMeetsCacheBox(straddlingTheWest))
        let justWest = MKCoordinateRegion(center: .init(latitude: 46.2, longitude: box.minLon - 0.7),
                                          span: .init(latitudeDelta: 0.5, longitudeDelta: 1.2))
        XCTAssertFalse(ChartAvailability.regionMeetsCacheBox(justWest))
    }

    // MARK: - The edge arrow

    private let square = CGSize(width: 400, height: 400)
    private let centre = CLLocationCoordinate2D(latitude: 46.5, longitude: 7.5)
    private var region: MKCoordinateRegion {
        MKCoordinateRegion(center: centre, span: .init(latitudeDelta: 0.6, longitudeDelta: 0.8))
    }

    private func arrow(to aircraft: CLLocationCoordinate2D, heading: Double = 0,
                       size: CGSize? = nil) -> OwnshipEdgeArrow.Placement? {
        OwnshipEdgeArrow.place(aircraft: aircraft, region: region, heading: heading, size: size ?? square, inset: 20)
    }

    /// The aircraft on screen: no arrow.
    func testNoArrowWhileTheAircraftIsOnScreen() {
        XCTAssertNil(arrow(to: centre))
        XCTAssertNil(arrow(to: .init(latitude: 46.5, longitude: 7.85)), "near the edge, inside the inset")
        XCTAssertNil(arrow(to: centre, heading: 137))
    }

    /// North up: the arrow on the edge facing the aircraft, pointing at it.
    func testNorthUpTheArrowFacesTheAircraft() throws {
        let east = try XCTUnwrap(arrow(to: .init(latitude: 46.5, longitude: 9.5)))
        XCTAssertEqual(east.point.x, 380, accuracy: 1e-6)
        XCTAssertEqual(east.point.y, 200, accuracy: 1e-6)
        XCTAssertEqual(east.degrees, 90, accuracy: 1e-6)

        let north = try XCTUnwrap(arrow(to: .init(latitude: 48.5, longitude: 7.5)))
        XCTAssertEqual(north.point.x, 200, accuracy: 1e-6)
        XCTAssertEqual(north.point.y, 20, accuracy: 1e-6)
        XCTAssertEqual(north.degrees, 0, accuracy: 1e-6)

        let west = try XCTUnwrap(arrow(to: .init(latitude: 46.5, longitude: 5.0)))
        XCTAssertEqual(west.point.x, 20, accuracy: 1e-6)
        XCTAssertEqual(west.degrees, 270, accuracy: 1e-6)

        let south = try XCTUnwrap(arrow(to: .init(latitude: 44.5, longitude: 7.5)))
        XCTAssertEqual(south.point.y, 380, accuracy: 1e-6)
        XCTAssertEqual(south.degrees, 180, accuracy: 1e-6)
    }

    /// Track up, the chart turns by the heading, and so does the arrow.
    func testTrackUpTheArrowTurnsWithTheChart() throws {
        // Heading east: an aircraft further east is ahead, at the top.
        let ahead = try XCTUnwrap(arrow(to: .init(latitude: 46.5, longitude: 9.5), heading: 90))
        XCTAssertEqual(ahead.point.x, 200, accuracy: 1e-6)
        XCTAssertEqual(ahead.point.y, 20, accuracy: 1e-6)
        XCTAssertEqual(ahead.degrees, 0, accuracy: 1e-6)
        // And one to the north is on the left.
        let left = try XCTUnwrap(arrow(to: .init(latitude: 48.5, longitude: 7.5), heading: 90))
        XCTAssertEqual(left.point.x, 20, accuracy: 1e-6)
        XCTAssertEqual(left.degrees, 270, accuracy: 1e-6)
    }

    /// The scale comes from the region's width: the region's east edge is the chart's right edge north
    /// up and, heading east on a wide chart, its top edge (the turned chart's bounding region).
    func testTheProjectionScalesByTheRegionsWidth() throws {
        let eastEdge = CLLocationCoordinate2D(latitude: 46.5, longitude: 7.5 + 0.4)
        let northUp = try XCTUnwrap(OwnshipEdgeArrow.project(eastEdge, region: region, heading: 0, size: square))
        XCTAssertEqual(northUp.x, 400, accuracy: 1e-6)
        XCTAssertEqual(northUp.y, 200, accuracy: 1e-6)
        let wide = CGSize(width: 400, height: 200)
        let trackUp = try XCTUnwrap(OwnshipEdgeArrow.project(eastEdge, region: region, heading: 90, size: wide))
        XCTAssertEqual(trackUp.x, 200, accuracy: 1e-6)
        XCTAssertEqual(trackUp.y, 0, accuracy: 1e-6)
    }

    /// Towards a corner, the ray leaves through the corner.
    func testTheArrowLeavesThroughTheEdgeTheRayCrosses() throws {
        let corner = try XCTUnwrap(OwnshipEdgeArrow.place(screenPoint: CGPoint(x: 1200, y: 1200), size: square,
                                                          inset: 20))
        XCTAssertEqual(corner.point.x, 380, accuracy: 1e-9)
        XCTAssertEqual(corner.point.y, 380, accuracy: 1e-9)
        XCTAssertEqual(corner.degrees, 135, accuracy: 1e-9)
        let shallow = try XCTUnwrap(OwnshipEdgeArrow.place(screenPoint: CGPoint(x: 200 + 360, y: 200 - 90),
                                                           size: square, inset: 20))
        XCTAssertEqual(shallow.point.x, 380, accuracy: 1e-9)
        XCTAssertEqual(shallow.point.y, 200 - 45, accuracy: 1e-9)
    }

    func testNoArrowOnAChartTooSmallForItsInset() {
        XCTAssertNil(OwnshipEdgeArrow.place(screenPoint: CGPoint(x: 900, y: 0), size: CGSize(width: 30, height: 400),
                                            inset: 20))
        XCTAssertNil(OwnshipEdgeArrow.place(aircraft: centre, region: region, heading: 0, size: .zero, inset: 0))
    }

    // MARK: - The scale

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// A zoom shows the scale; it goes 2 s after the last change.
    func testTheScaleShowsForTwoSecondsAfterTheLastZoom() {
        var scale = ScaleVisibility()
        scale.note(zoom: 50_000, at: t0)
        XCTAssertFalse(scale.isVisible(at: t0), "the first value is the reference")
        scale.note(zoom: 45_000, at: t0.addingTimeInterval(1))
        XCTAssertTrue(scale.isVisible(at: t0.addingTimeInterval(1)))
        XCTAssertTrue(scale.isVisible(at: t0.addingTimeInterval(2.9)))
        XCTAssertFalse(scale.isVisible(at: t0.addingTimeInterval(3)))
        XCTAssertEqual(scale.hidesAt, t0.addingTimeInterval(3))

        // Another change keeps it up, 2 s from that one.
        scale.note(zoom: 40_000, at: t0.addingTimeInterval(2.5))
        XCTAssertTrue(scale.isVisible(at: t0.addingTimeInterval(4.4)))
        XCTAssertFalse(scale.isVisible(at: t0.addingTimeInterval(4.5)))
    }

    /// Following the aircraft moves the centre, not the zoom: no scale. Nor for a change of 1 % or less.
    func testTheScaleIgnoresFollowingAndJitter() {
        var scale = ScaleVisibility()
        for second in 0..<10 {
            scale.note(zoom: 50_000, at: t0.addingTimeInterval(Double(second)))
        }
        XCTAssertFalse(scale.isVisible(at: t0.addingTimeInterval(10)))
        scale.note(zoom: 50_400, at: t0.addingTimeInterval(11))
        XCTAssertFalse(scale.isVisible(at: t0.addingTimeInterval(11)), "0.8 %")
        XCTAssertNil(scale.hidesAt)
    }

    /// A slow pinch counts from the last change, not from the last fix: 0.6 % steps show it on the second.
    func testASlowZoomStillShowsTheScale() {
        var scale = ScaleVisibility()
        scale.note(zoom: 50_000, at: t0)
        scale.note(zoom: 50_300, at: t0.addingTimeInterval(0.1))
        XCTAssertFalse(scale.isVisible(at: t0.addingTimeInterval(0.1)))
        scale.note(zoom: 50_600, at: t0.addingTimeInterval(0.2))
        XCTAssertTrue(scale.isVisible(at: t0.addingTimeInterval(0.2)))
    }
}
