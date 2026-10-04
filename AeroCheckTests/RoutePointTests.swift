import XCTest
import CoreLocation
@testable import AeroCheck

/// What the route builder makes of an aerodrome, a navaid or a reporting point (its "+", its snap and
/// its search, 6.0.1): where it goes in the route, what the waypoint is called and carries, how older
/// plans and builds read the new fields, and what the nav log and the avionics GPX print for it.
final class RoutePointTests: XCTestCase {

    // MARK: - Fixtures

    private func coordinate(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func airport(_ ident: String, _ lat: Double, _ lon: Double, elevation: Int? = 1_400) -> Airport {
        Airport(id: ident.hashValue, ident: ident, type: .smallAirport, name: ident, latitude: lat, longitude: lon,
                elevation: elevation, continent: "EU", isoCountry: "CH", isoRegion: "CH-NE",
                municipality: nil, scheduledService: false, gpsCode: ident, iataCode: nil, localCode: nil)
    }

    /// LSZQ → LSZB, about 34 NM, south-east.
    private lazy var lszq = airport("LSZQ", 47.3922, 7.0296, elevation: 1_690)
    private lazy var lszb = airport("LSZB", 46.9141, 7.4971, elevation: 1_674)
    private lazy var lsgc = airport("LSGC", 47.0839, 6.7928, elevation: 3_368)

    private func navaids() throws -> [Navaid] {
        try Navaid.parse(geoJSON: Data("""
        { "type": "FeatureCollection", "features": [
          { "type": "Feature",
            "properties": { "_id": "62616c96abdcc7f0ccbbe519", "name": "CORVATSCH", "identifier": "CVA",
              "type": 0, "channel": "57Y", "frequency": { "value": "112.050", "unit": 2 },
              "elevation": { "value": 3279, "unit": 0, "referenceDatum": 1 } },
            "geometry": { "type": "Point", "coordinates": [7.2, 47.2] } }
        ] }
        """.utf8))
    }

    private func reportingPoint(name: String?, remarks: String?, id: String = "629cc7abf4b4089a578e3c55",
                                lat: Double = 47.137167, lon: Double = 6.975833) throws -> ReportingPoint {
        var properties: [String: Any] = ["_id": id, "compulsory": false, "airports": ["6261519e0e8346dfd925198a"],
                                         "elevation": ["value": 821, "unit": 0, "referenceDatum": 1],
                                         "geometry": ["type": "Point", "coordinates": [lon, lat]]]
        if let name { properties["name"] = name }
        if let remarks { properties["remarks"] = remarks }
        let data = try OpenAIPLayerCache<ReportingPoint>.featureCollectionData(fromCoreAPIItems: [properties])
        return try XCTUnwrap(ReportingPoint.parse(geoJSON: data).first)
    }

    private let lesEplatures = ReportingPointAerodrome(icao: "LSGC", name: "LES EPLATURES")

    private func pointE() throws -> RoutePoint {
        let e = try reportingPoint(name: "E", remarks: "Les Eplatures VRP - E {ELESE}")
        return .reportingPoint(e, ReportingPointLabel(point: e, aerodrome: lesEplatures))
    }

    private func route(_ points: CLLocationCoordinate2D...) -> [FlightPlanWaypoint] {
        points.enumerated().map { FlightPlanWaypoint(name: "P\($0.offset)", coordinate: $0.element) }
    }

    // MARK: - Where the "+" puts a point

    func testThePlusAppendsOnlyWhileThereIsNoDestination() {
        let point = coordinate(47.1, 7.2)
        XCTAssertEqual(FlightPlanManager.bestLegInsertionIndex(for: point, in: []), 0)
        XCTAssertEqual(FlightPlanManager.bestLegInsertionIndex(for: point, in: route(lszq.coordinate)), 1)
    }

    /// Beyond the destination, the press-and-hold add extends the route; the "+" keeps the
    /// destination and goes on the last leg.
    func testThePlusNeverMovesTheDestinationOrTheDeparture() {
        let wps = route(lszq.coordinate, lszb.coordinate)
        let beyondDestination = coordinate(46.75, 7.70)
        XCTAssertEqual(FlightPlanManager.bestInsertionIndex(for: beyondDestination, in: wps), 2)
        XCTAssertEqual(FlightPlanManager.bestLegInsertionIndex(for: beyondDestination, in: wps), 1)
        let beforeDeparture = coordinate(47.55, 6.85)
        XCTAssertEqual(FlightPlanManager.bestInsertionIndex(for: beforeDeparture, in: wps), 0)
        XCTAssertEqual(FlightPlanManager.bestLegInsertionIndex(for: beforeDeparture, in: wps), 1)
    }

    func testThePlusTakesTheLegItLeastLengthens() {
        // Three legs going east; the point sits just south of the middle one.
        let wps = route(coordinate(47.0, 7.0), coordinate(47.0, 7.3), coordinate(47.0, 7.6), coordinate(47.0, 7.9))
        XCTAssertEqual(FlightPlanManager.bestLegInsertionIndex(for: coordinate(46.97, 7.45), in: wps), 2)
        XCTAssertEqual(FlightPlanManager.bestLegInsertionIndex(for: coordinate(47.02, 7.1), in: wps), 1)
        XCTAssertEqual(FlightPlanManager.bestLegInsertionIndex(for: coordinate(47.02, 7.8), in: wps), 3)
    }

    /// The aerodrome "+" used to append after the destination and become it. Now: mid-route, no field
    /// elevation as a planned altitude, its contact frequency, one write.
    @MainActor
    func testAnAerodromeAddedMidRouteKeepsTheDestination() {
        let plans = makeTestPlanManager()
        var plan = FlightPlan(name: "Mid", waypoints: [
            RoutePoint.aerodrome(lszq).waypoint(asEndpoint: true),
            RoutePoint.aerodrome(lszb).waypoint(asEndpoint: true),
        ])
        plan.calculateRouteData()
        plans.flightPlans = [plan]
        let lsgcNearTheLeg = airport("LSZG", 47.1817, 7.4172)   // Grenchen, a few NM off the leg
        let point = RoutePoint.aerodrome(lsgcNearTheLeg)
        let index = FlightPlanManager.bestLegInsertionIndex(for: point.coordinate, in: plan.waypoints)
        plans.insertWaypoint(point.waypoint(asEndpoint: false, contactFrequency: "120.100"), to: plan.id, at: index)

        let saved = try? XCTUnwrap(plans.flightPlans.first)
        XCTAssertEqual(saved?.waypoints.map(\.name), ["LSZQ", "LSZG", "LSZB"])
        let mid = saved?.waypoints[1]
        XCTAssertNil(mid?.altitude, "mid-route, the field elevation is no planned altitude")
        XCTAssertEqual(mid?.frequency, "120.100")
        XCTAssertEqual(mid?.callSign, "LSZG")
        XCTAssertEqual(mid?.pointKind, .aerodrome)
        XCTAssertEqual(mid?.sourceId, "LSZG")
        XCTAssertNil(mid?.plannedGroundSpeed, "no airspeed of its own: its leg takes the aircraft's cruise speed (6.1)")
        XCTAssertEqual(saved?.waypoints.first?.altitude, 1_690, "an endpoint takes the elevation")
    }

    // MARK: - What the waypoint is

    /// The waypoint keeps the point's plain name ("E") and its aerodrome's code beside it, for the
    /// surfaces with room to qualify it. Its ident and source come along; what an older build's
    /// snap onto LSGC wrote (its call sign, one of its frequencies) goes.
    func testAReportingPointKeepsItsNameAndBringsItsIdentAndSource() throws {
        var wp = FlightPlanWaypoint(name: "LSGC", coordinate: lsgc.coordinate, frequency: "118.000", callSign: "LSGC")
        let earlier = RoutePoint.aerodrome(lsgc).snapValues(aerodromeFrequencies: ["119.300", "118.000"])
        try pointE().apply(to: &wp, asEndpoint: false, replacing: earlier)
        XCTAssertEqual(wp.name, "E")
        XCTAssertEqual(wp.aerodromeICAO, "LSGC")
        XCTAssertEqual(wp.pointKind, .vrp)
        XCTAssertEqual(wp.sourceId, "629cc7abf4b4089a578e3c55")
        XCTAssertEqual(wp.code, "ELESE")
        XCTAssertNil(wp.frequency, "LSGC's frequency belonged to what the waypoint was")
        XCTAssertNil(wp.callSign)
        XCTAssertEqual(wp.latitude, 47.137167, accuracy: 1e-6)
        XCTAssertNil(wp.altitude)

        let witzwil = try reportingPoint(name: "WITZWIL", remarks: nil, id: "w")
        let named = RoutePoint.reportingPoint(witzwil, ReportingPointLabel(point: witzwil, aerodrome: nil))
            .waypoint(asEndpoint: true)
        XCTAssertEqual(named.name, "WITZWIL")
        XCTAssertNil(named.code)
        XCTAssertNil(named.aerodromeICAO)
        XCTAssertEqual(named.altitude, Double(Int((821 * 3.28084).rounded())), "an endpoint takes its elevation")
    }

    func testAPointWithoutANameKeepsTheWaypointsName() throws {
        let unnamed = try reportingPoint(name: nil, remarks: nil, id: "u")
        var wp = FlightPlanWaypoint(name: "WPT", coordinate: coordinate(47, 7))
        RoutePoint.reportingPoint(unnamed, ReportingPointLabel(point: unnamed, aerodrome: lesEplatures))
            .apply(to: &wp, asEndpoint: false)
        XCTAssertEqual(wp.name, "WPT")
        XCTAssertEqual(wp.pointKind, .vrp)
        XCTAssertEqual(wp.routeName(.full), "WPT", "no aerodrome for a name that isn't the point's")
    }

    /// The bug: a waypoint snapped to a VOR carried 112.050 as its frequency, which the nav log
    /// prints as the station to call. The navaid writes nothing in the radio fields now, and what an
    /// older build's snap onto LSZQ wrote there goes.
    func testANavaidIsNamedByItsIdentAndLeavesTheRadioEmpty() throws {
        let cva = try XCTUnwrap(navaids().first)
        var wp = FlightPlanWaypoint(name: "LSZQ", coordinate: lszq.coordinate, frequency: "122.050", callSign: "LSZQ")
        RoutePoint.navaid(cva).apply(to: &wp, asEndpoint: false,
                                     replacing: RoutePoint.aerodrome(lszq).snapValues(aerodromeFrequencies: ["122.050"]))
        XCTAssertEqual(wp.name, "CVA")
        XCTAssertNil(wp.callSign)
        XCTAssertNil(wp.frequency)
        XCTAssertEqual(wp.pointKind, .navaid)
        XCTAssertEqual(wp.sourceId, "62616c96abdcc7f0ccbbe519")
        XCTAssertNil(wp.code)
        XCTAssertNil(wp.aerodromeICAO)

        var fresh = FlightPlanWaypoint(name: "WPT", coordinate: coordinate(47.2, 7.21))
        RoutePoint.navaid(cva).apply(to: &fresh, asEndpoint: false)
        XCTAssertNil(fresh.frequency, "never the VOR's own frequency")
        XCTAssertNil(fresh.callSign)
    }

    // MARK: - Snapping keeps what the pilot typed (author decision 2026-09-29)

    /// A frequency and a call sign the pilot typed on their own point survive a snap onto a
    /// reporting point or a navaid: no snap wrote them.
    func testSnappingKeepsAFrequencyAndACallSignThePilotTyped() throws {
        let cva = try XCTUnwrap(navaids().first)
        let here = coordinate(47.137, 6.976)
        for kind in [nil, WaypointPointKind.user] {
            let typed = FlightPlanWaypoint(name: "WPT", coordinate: here, frequency: "124.700",
                                           callSign: "ZURICH INFO", pointKind: kind)
            let earlier = RoutePoint.origin(of: typed, among: [try pointE(), .navaid(cva), .aerodrome(lsgc)])
            XCTAssertNil(earlier, "the pilot's own point was made from nothing on the chart")

            var onE = typed
            try pointE().apply(to: &onE, asEndpoint: false, replacing: .none)
            XCTAssertEqual(onE.frequency, "124.700")
            XCTAssertEqual(onE.callSign, "ZURICH INFO")
            XCTAssertEqual(onE.name, "E")

            var onCVA = typed
            RoutePoint.navaid(cva).apply(to: &onCVA, asEndpoint: false, replacing: .none)
            XCTAssertEqual(onCVA.frequency, "124.700")
            XCTAssertEqual(onCVA.callSign, "ZURICH INFO")
        }
    }

    /// An older build's snap onto a VOR left its NAV frequency and its ident as the call sign, and
    /// recorded neither kind nor source: the VOR is found by name and position, and only what it
    /// wrote goes. A call sign typed over it afterwards stays.
    func testSnappingClearsWhatAnOlderBuildsNavaidSnapWrote() throws {
        let cva = try XCTUnwrap(navaids().first)
        let byOldBuild = FlightPlanWaypoint(name: "CVA", coordinate: cva.coordinate, frequency: "112.05", callSign: "CVA")
        let origin = try XCTUnwrap(RoutePoint.origin(of: byOldBuild, among: [.aerodrome(lszq), .navaid(cva)]))
        XCTAssertEqual(origin.sourceId, cva.id)
        let earlier = origin.snapValues()
        XCTAssertEqual(earlier, SnapValues(callSign: "CVA", frequencies: ["112.050"]))

        var onE = byOldBuild
        try pointE().apply(to: &onE, asEndpoint: false, replacing: earlier)
        XCTAssertNil(onE.frequency, "112.05 is the 112.050 the old snap wrote")
        XCTAssertNil(onE.callSign)

        var retyped = byOldBuild
        retyped.callSign = "GENEVA INFO"
        try pointE().apply(to: &retyped, asEndpoint: false, replacing: earlier)
        XCTAssertNil(retyped.frequency)
        XCTAssertEqual(retyped.callSign, "GENEVA INFO", "typed by the pilot after the snap")

        // Named after the VOR but not on it (moved in the editor): the pilot's point, nothing goes.
        var moved = byOldBuild
        moved.coordinate = coordinate(cva.latitude + 0.01, cva.longitude)
        XCTAssertNil(RoutePoint.origin(of: moved, among: [.navaid(cva)]))
    }

    /// A waypoint this build snapped onto an aerodrome says so (kind and source): the aerodrome's
    /// ident goes, and so does any of its frequencies, but a frequency the pilot typed stays.
    func testSnappingAnAerodromeWaypointKeepsATypedFrequency() throws {
        var wp = RoutePoint.aerodrome(lszq).waypoint(asEndpoint: false, contactFrequency: "122.050")
        let origin = try XCTUnwrap(RoutePoint.origin(of: wp, among: [.aerodrome(lszq)]))
        let earlier = origin.snapValues(aerodromeFrequencies: ["122.050", "120.400"])

        var snapped = wp
        try pointE().apply(to: &snapped, asEndpoint: false, replacing: earlier)
        XCTAssertNil(snapped.frequency)
        XCTAssertNil(snapped.callSign)

        wp.frequency = "124.700"
        try pointE().apply(to: &wp, asEndpoint: false, replacing: earlier)
        XCTAssertEqual(wp.frequency, "124.700")
        XCTAssertNil(wp.callSign, "LSZQ was the snap's")
        XCTAssertNil(RoutePoint.origin(of: wp, among: [.aerodrome(lszq)]), "a reporting point wrote nothing")
    }

    /// Snap a VOR into a route: the nav log's row is named after it, and its radio column is no
    /// longer the VOR's frequency.
    func testNavLogRowAfterSnappingAVOR() throws {
        let cva = try XCTUnwrap(navaids().first)
        var plan = FlightPlan(name: "VOR", waypoints: [
            RoutePoint.aerodrome(lszq).waypoint(asEndpoint: true, contactFrequency: "122.050"),
            FlightPlanWaypoint(name: "WPT", coordinate: coordinate(47.2, 7.21)),
            RoutePoint.aerodrome(lszb).waypoint(asEndpoint: true, contactFrequency: "121.025"),
        ])
        RoutePoint.navaid(cva).apply(to: &plan.waypoints[1], asEndpoint: false)
        plan.calculateRouteData()
        let rows = FlightPlanExportService.navLogRows(plan, radio: RouteRadioPlanner.manualOnly(plan.waypoints))
        XCTAssertEqual(rows[1].name, "CVA")
        XCTAssertNil(rows[1].station, "no station typed on the VOR: the nav log's airspace station applies")
        XCTAssertEqual(rows[0].station?.frequency, "122.050")
    }

    func testSnapTakesAnAerodromeThenANavaidThenAReportingPoint() throws {
        let cva = try XCTUnwrap(navaids().first)
        let e = try reportingPoint(name: "E", remarks: nil)
        let label = ReportingPointLabel(point: e, aerodrome: nil)
        let here = coordinate(47.2, 7.21)
        let farAerodrome = airport("LSXX", 47.21, 7.25)   // farther than the navaid
        let nearAerodrome = airport("LSYY", 47.2, 7.205)
        func target(_ a: Airport?, _ n: Navaid?, _ rp: Bool) -> String? {
            switch RoutePoint.snapTarget(near: here, aerodrome: a, navaid: n, reportingPoint: rp ? (e, label) : nil) {
            case .aerodrome(let x): return x.ident
            case .navaid(let x): return x.identifier
            case .reportingPoint(let x, _): return x.name
            case nil: return nil
            }
        }
        XCTAssertEqual(target(nearAerodrome, cva, true), "LSYY")
        XCTAssertEqual(target(farAerodrome, cva, true), "CVA", "a nearer navaid wins over an aerodrome")
        XCTAssertEqual(target(nil, cva, true), "CVA", "a reporting point only when nothing else is in range")
        XCTAssertEqual(target(nil, nil, true), "E")
        XCTAssertNil(target(nil, nil, false))
    }

    // MARK: - Older plans, older builds

    /// A waypoint as 6.0 wrote it: none of the new keys.
    private let oldWaypointJSON = """
    {"id":"6B1E5C2A-3F0E-4B7B-9C55-1B8E0F3C7A10","name":"E","latitude":47.137167,"longitude":6.975833,
     "remarks":"","plannedGroundSpeed":100}
    """

    func testAWaypointFromBeforeTheNewFieldsDecodes() throws {
        let wp = try JSONDecoder().decode(FlightPlanWaypoint.self, from: Data(oldWaypointJSON.utf8))
        XCTAssertEqual(wp.name, "E")
        XCTAssertNil(wp.pointKind)
        XCTAssertNil(wp.sourceId)
        XCTAssertNil(wp.code)
        XCTAssertNil(wp.aerodromeICAO)
        XCTAssertEqual(wp.routeName(.full), "E")
    }

    func testTheNewFieldsRoundTripAndAnUnknownKindDoesNotFailThePlan() throws {
        var plan = FlightPlan(name: "Round trip", waypoints: [try pointE().waypoint(asEndpoint: false)])
        plan.calculateRouteData()
        let decoded = try JSONDecoder().decode(FlightPlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(decoded.waypoints.first?.pointKind, .vrp)
        XCTAssertEqual(decoded.waypoints.first?.code, "ELESE")
        XCTAssertEqual(decoded.waypoints.first?.sourceId, "629cc7abf4b4089a578e3c55")
        XCTAssertEqual(decoded.waypoints.first?.aerodromeICAO, "LSGC")

        // A kind a later build adds ("ifr") reads as the pilot's own point, and the plan still loads.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        var waypoints = try XCTUnwrap(object["waypoints"] as? [[String: Any]])
        waypoints[0]["pointKind"] = "ifr"
        object["waypoints"] = waypoints
        let later = try JSONDecoder().decode(FlightPlan.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(later.waypoints.first?.pointKind, .user)
        XCTAssertEqual(later.waypoints.first?.name, "E")
    }

    /// An older build (or peer) decodes the waypoint as 6.0 declared it: the new keys are ignored, the
    /// name and position survive.
    func testAnOlderBuildIgnoresTheNewKeys() throws {
        struct WaypointAsIn60: Decodable {
            let id: UUID
            let name: String
            let latitude: Double
            let longitude: Double
            let remarks: String
        }
        let data = try JSONEncoder().encode(try pointE().waypoint(asEndpoint: false))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"code\":\"ELESE\""))
        let old = try JSONDecoder().decode(WaypointAsIn60.self, from: data)
        XCTAssertEqual(old.name, "E")
        XCTAssertEqual(old.latitude, 47.137167, accuracy: 1e-6)
    }

    // MARK: - Avionics GPX

    private func gpx(_ plan: FlightPlan, descriptions: [UUID: String] = [:]) throws -> String {
        let data = try XCTUnwrap(FlightPlanExportService.exportToAvionicsGPX(plan, pointDescriptions: descriptions))
        return String(decoding: data, as: UTF8.self)
    }

    /// The ident names the point in the avionics ("E" is shared by ten Swiss points); the description
    /// says what it is. A point without an ident keeps its name, and none is ever made up.
    func testGPXNamesAReportingPointByItsIdentAndDescribesIt() throws {
        let e = try pointE().waypoint(asEndpoint: false)
        let witzwilPoint = try reportingPoint(name: "WITZWIL", remarks: nil, id: "w", lat: 46.98, lon: 7.07)
        let witzwil = RoutePoint.reportingPoint(witzwilPoint, ReportingPointLabel(point: witzwilPoint, aerodrome: nil))
            .waypoint(asEndpoint: false)
        let southE = try reportingPoint(name: "E", remarks: nil, id: "s", lat: 46.9, lon: 7.5)
        let plainE = RoutePoint.reportingPoint(southE, ReportingPointLabel(point: southE, aerodrome: nil))
            .waypoint(asEndpoint: false)
        var plan = FlightPlan(name: "GPX", waypoints: [
            RoutePoint.aerodrome(lszq).waypoint(asEndpoint: true), e, witzwil, plainE,
            RoutePoint.aerodrome(lszb).waypoint(asEndpoint: true),
        ])
        plan.calculateRouteData()

        let described = try gpx(plan, descriptions: [e.id: "E · LSGC Les Eplatures"])
        XCTAssertTrue(described.contains("<name>ELESE</name>"), described)
        XCTAssertTrue(described.contains("<desc>E · LSGC Les Eplatures</desc>"), described)
        XCTAssertTrue(described.contains("<name>WITZWIL</name>"))
        XCTAssertTrue(described.contains("<name>E</name>"), "no ident: the plain name, nothing made up")
        XCTAssertTrue(described.contains("<name>LSZQ</name>"))

        // Without the aerodrome at hand, the description is at least the point's name.
        XCTAssertTrue(try gpx(plan).contains("<name>ELESE</name>\n      <desc>E</desc>"))

        // Moved off the point in the builder or the editor, the waypoint is the pilot's again.
        var moved = e
        moved.pointKind = .user
        moved.code = nil
        XCTAssertEqual(FlightPlanExportService.gpxName(of: moved), "E")
    }

    /// The ident goes in the GPX only: not in the nav log (what a pilot reads out), nor in the ATC
    /// flight plan, whose route field takes the plain name as the chart prints it.
    func testTheIdentNeverReachesTheNavLogOrTheATCFlightPlan() throws {
        var plan = FlightPlan(name: "Log", waypoints: [
            RoutePoint.aerodrome(lszq).waypoint(asEndpoint: true), try pointE().waypoint(asEndpoint: false),
            RoutePoint.aerodrome(lszb).waypoint(asEndpoint: true),
        ])
        plan.calculateRouteData()
        let rows = FlightPlanExportService.navLogRows(plan, radio: RouteRadioPlanner.manualOnly(plan.waypoints))
        XCTAssertFalse(rows.map(\.name).contains { $0.contains("ELESE") })
        XCTAssertFalse(rows.flatMap(\.remarks).contains { $0.contains("ELESE") })

        let atc = plan.toICAOFlightPlan()
        XCTAssertTrue(atc.contains("DCT E DCT"), atc)
        XCTAssertFalse(atc.contains("ELESE"))
        XCTAssertFalse(atc.contains("(LSGC)"), "a bracket would end the ICAO message")
    }

    // MARK: - Route names (author decision 2026-09-29)

    /// "E (LSGC)" where there is room: the nav log and its exports, the route list, the iPad map
    /// card, the Cockpit's NEXT cell (which falls back to "E" where it doesn't fit, 6.2). "E" on the
    /// phone's next line.
    func testAShortReportingPointIsQualifiedWhereThereIsRoom() throws {
        var plan = FlightPlan(name: "Names", waypoints: [
            RoutePoint.aerodrome(lszq).waypoint(asEndpoint: true), try pointE().waypoint(asEndpoint: false),
            RoutePoint.aerodrome(lsgc).waypoint(asEndpoint: true),
        ])
        plan.calculateRouteData()
        let rows = FlightPlanExportService.navLogRows(plan, radio: RouteRadioPlanner.manualOnly(plan.waypoints))
        XCTAssertEqual(rows.map(\.name), ["LSZQ", "E (LSGC)", "LSGC"])
        XCTAssertEqual(plan.waypoints[1].routeName(.routeList), "E (LSGC)")
        XCTAssertEqual(RouteRadioPlanner.displayName(plan.waypoints[1], index: 1, form: .navLog), "E (LSGC)")
        XCTAssertEqual(plan.waypoints[1].name, "E", "the stored name stays the point's own")

        plan.currentWaypointIndex = 1
        XCTAssertEqual(plan.nextWaypointName(.cockpitNext), "E (LSGC)")
        XCTAssertEqual(plan.nextWaypointName(.phoneNextLine), "E")
        XCTAssertEqual(plan.nextWaypointName(.mapCard), "E (LSGC)")
        plan.diversion = Diversion(ident: "LSZG", name: "GRENCHEN", latitude: 47.18, longitude: 7.42, leftRouteAt: 1)
        XCTAssertEqual(plan.nextWaypointName(.mapCard), "LSZG", "diverting: the field, as before")
    }

    func testOnlyAShortReportingPointNameTakesItsAerodrome() throws {
        func name(_ name: String, kind: WaypointPointKind?, icao: String?) -> String {
            FlightPlanWaypoint(name: name, coordinate: coordinate(47, 7), pointKind: kind, aerodromeICAO: icao)
                .routeName(.full)
        }
        XCTAssertEqual(name("NE", kind: .vrp, icao: "LSGC"), "NE (LSGC)")
        XCTAssertEqual(name("S1", kind: .vrp, icao: "LSZH"), "S1 (LSZH)")
        XCTAssertEqual(name("WITZWIL", kind: .vrp, icao: "LSMP"), "WITZWIL", "a named point is plain")
        XCTAssertEqual(name("ECHO", kind: .vrp, icao: "LSGC"), "ECHO")
        XCTAssertEqual(name("E", kind: .vrp, icao: nil), "E", "an aerodrome without a code")
        XCTAssertEqual(name("E", kind: .vrp, icao: " "), "E")
        XCTAssertEqual(name("E", kind: .user, icao: "LSGC"), "E", "moved off the point: the pilot's")
        XCTAssertEqual(name("WIL", kind: .navaid, icao: nil), "WIL")
        XCTAssertEqual(name("LSZQ", kind: .aerodrome, icao: nil), "LSZQ")
        XCTAssertEqual(name("E", kind: nil, icao: nil), "E", "a 6.0 waypoint")

        let e = try reportingPoint(name: "E", remarks: nil)
        XCTAssertEqual(ReportingPointLabel(point: e, aerodrome: lesEplatures).routeName(.full), "E (LSGC)")
        XCTAssertEqual(ReportingPointLabel(point: e, aerodrome: lesEplatures).routeName(.compact), "E")
        XCTAssertEqual(ReportingPointLabel(point: e, aerodrome: nil).routeName(.full), "E")
    }
}
