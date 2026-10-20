import XCTest
import CoreLocation
@testable import AeroCheck

/// `RadioTimeline`: NOW and NEXT along the route, the author's answers of 18 Oct 2026 (6.4.2).
///
/// The route runs east along 47°N, from a field at 7.0° E over three waypoints at 0.3° steps (about 12.3 NM, 7.4 min
/// at 100 kt per leg) to a field at 8.2° E, 49 NM in all. The FIS is Geneva Info west of 7.75° E (about 30.7 NM out)
/// and Zurich Info east of it. At 100 kt, 5 min is 8.3 NM and 10 min 16.7 NM.
final class RadioTimelineTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FlightPlan.windsAloftProvider = nil
        FlightPlan.magneticDeclinationProvider = nil
    }

    override func tearDown() {
        FlightPlan.windsAloftProvider = nil
        FlightPlan.magneticDeclinationProvider = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private typealias Station = RouteRadioPlanner.Station
    private let geneva = Station(frequency: "126.350", callSign: "GENEVA INFO")
    private let zurich = Station(frequency: "124.700", callSign: "ZURICH INFO")
    private let departure = RouteRadioPlanner.Aerodrome(ident: "LSXA", contact: Station(frequency: "122.050", callSign: "LSXA AFIS"),
                                                        atis: nil, ground: nil)
    private let destination = RouteRadioPlanner.Aerodrome(ident: "LSXB", contact: Station(frequency: "118.125", callSign: "LSXB TWR"),
                                                          atis: "128.525", ground: nil)

    private func waypoints(arrivalPointOf ident: String? = nil) -> [FlightPlanWaypoint] {
        let lons = [7.0, 7.3, 7.6, 7.9, 8.2]
        let alts: [Double] = [1500, 5000, 5000, 5000, 1500]
        let names = ["LSXA", "B", "C", "D", "LSXB"]
        var plan = FlightPlan(waypoints: lons.indices.map { i in
            FlightPlanWaypoint(name: names[i], coordinate: .init(latitude: 47.0, longitude: lons[i]),
                               altitude: alts[i], plannedGroundSpeed: 100)
        })
        if let ident { plan.waypoints[3].aerodromeICAO = ident }
        plan.calculateRouteData()
        return plan.waypoints
    }

    private func airspace(_ name: String, type: Int, icaoClass: Int?, lon: ClosedRange<Double>,
                          lat: ClosedRange<Double> = 46.9...47.1, country: String = "CH",
                          frequency: (String, String)? = nil) -> Airspace {
        let ring: [[Double]] = [
            [lon.lowerBound, lat.lowerBound], [lon.lowerBound, lat.upperBound],
            [lon.upperBound, lat.upperBound], [lon.upperBound, lat.lowerBound], [lon.lowerBound, lat.lowerBound],
        ]
        return Airspace(
            id: name, name: name, type: type, icaoClass: icaoClass, country: country,
            upperCeiling: AltitudeLimit(value: 130, unit: 6, referenceDatum: 2),
            lowerCeiling: AltitudeLimit(value: 0, unit: 1, referenceDatum: 0),
            geometry: AirspaceGeometry(type: "Polygon", coordinates: [ring]), activity: nil,
            frequencies: frequency.map { [AirspaceFrequency(value: $0.0, name: $0.1, primary: true, unit: nil)] })
    }

    private func plan(_ airspaces: [Airspace] = [], waypoints wps: [FlightPlanWaypoint]? = nil,
                      departure dep: RouteRadioPlanner.Aerodrome?? = .none,
                      destination dest: RouteRadioPlanner.Aerodrome?? = .none,
                      fields: [RadioTimeline.NearbyField] = []) -> RouteRadioPlanner.Plan {
        RouteRadioPlanner.plan(.init(
            waypoints: wps ?? waypoints(), airspaces: airspaces,
            departure: dep ?? departure, destination: dest ?? destination,
            fis: { [geneva, zurich] point in point.longitude < 7.75 ? geneva : zurich },
            fieldsNearby: fields))
    }

    private func timeline(_ airspaces: [Airspace] = [], waypoints wps: [FlightPlanWaypoint]? = nil,
                          destination dest: RouteRadioPlanner.Aerodrome?? = .none,
                          fields: [RadioTimeline.NearbyField] = []) -> RadioTimeline {
        plan(airspaces, waypoints: wps, destination: dest, fields: fields).timeline
    }

    private func read(_ t: RadioTimeline, at nm: Double, speed: Double = 100, departureOver: Bool = true,
                      fieldsOnTheWay: Bool = true) -> RadioTimeline.Reading {
        t.reading(.init(progressNM: nm, speedKt: speed, departureOver: departureOver, fieldsOnTheWay: fieldsOnTheWay))
    }

    /// The FIS boundary along the route.
    private func boundary(_ t: RadioTimeline) -> Double {
        t.calls.first { $0.kind == .fis && $0.station == zurich }!.fromNM
    }

    // MARK: - Departure (q3)

    func testTheDepartureIsNowUntilTheLevelOffWithTheFISNext() {
        let t = timeline()
        let climbing = read(t, at: 2, departureOver: false)
        XCTAssertEqual(climbing.now?.station.callSign, "LSXA AFIS")
        XCTAssertEqual(climbing.next, geneva)
        let level = read(t, at: 2, departureOver: true)
        XCTAssertEqual(level.now?.station, geneva)
        XCTAssertEqual(level.next, zurich)
    }

    func testOnTheGroundTheDepartureIsNow() {
        let reading = read(timeline(), at: 0, speed: 0, departureOver: false)
        XCTAssertEqual(reading.now?.kind, .departure)
        XCTAssertEqual(reading.next, geneva)
    }

    /// A climb that never levels off leaves the field 10 NM out.
    func testTheDepartureEndsTenMilesOutWithoutALevelOff() {
        XCTAssertEqual(read(timeline(), at: 10.5, departureOver: false).now?.station, geneva)
    }

    /// A field in its own CTR keeps NOW to the CTR's exit, level-off or not, under the field's name.
    func testADepartureInsideItsCTRKeepsNowToTheExit() {
        let ctr = airspace("CTR XA", type: 4, icaoClass: 3, lon: 6.9...7.2, frequency: ("122.050", "XA TOWER"))
        let t = timeline([ctr])
        XCTAssertEqual(read(t, at: 5, departureOver: false).now?.station.callSign, "LSXA AFIS")
        XCTAssertEqual(read(t, at: 5, departureOver: true).now?.station.frequency, "122.050")
        XCTAssertEqual(read(t, at: 5, departureOver: true).now?.station.callSign, "LSXA AFIS",
                       "the aerodrome's own zone under its name after the level-off too")
        XCTAssertEqual(read(t, at: 9.5, departureOver: true).now?.station, geneva)
    }

    // MARK: - 8.33 kHz channel names (R6)

    /// 120.105 is the 8.33 kHz name of 120.100 MHz: the airport database writes Grenchen's tower 120.100, OpenAIP
    /// 120.105; LSZQ's 122.050 is the radio index's 122.055. One frequency, one station (the Grenchen replay).
    func testAnEightThirtyThreeChannelNameIsItsFrequency() {
        XCTAssertTrue(Station.isSameFrequency("120.100", "120.105"))
        XCTAssertTrue(Station.isSameFrequency("122.050", "122.055"))
        XCTAssertTrue(Station.isSameFrequency("118.125", "118.130"))
        XCTAssertTrue(Station.isSameFrequency("124.7", "124.700"))
        XCTAssertFalse(Station.isSameFrequency("118.125", "118.135"), "8.33 kHz above it")
        XCTAssertFalse(Station.isSameFrequency("118.135", "118.140"))
        XCTAssertFalse(Station.isSameFrequency("120.100", "120.125"))
        XCTAssertEqual(Station.hertz("118.135"), 118_133_333)
        XCTAssertNil(Station.hertz("Bern Info"))
        XCTAssertTrue(Station.isSameFrequency("Bern Info", "Bern Info"))
    }

    /// The aerodrome in its own CTR, written two ways: NOW is the aerodrome under its name, on the zone's channel.
    func testAnAerodromeAndItsZoneWrittenTwoWaysAreOneStation() {
        let ctr = airspace("CTR XA", type: 4, icaoClass: 3, lon: 6.9...7.2, frequency: ("122.055", "XA TOWER"))
        let t = timeline([ctr])
        let now = read(t, at: 5, departureOver: false).now
        XCTAssertEqual(now?.station.callSign, "LSXA AFIS")
        XCTAssertEqual(now?.station.frequency, "122.055")
        XCTAssertEqual(read(t, at: 5, departureOver: false).next, geneva, "never the zone's 122.055 after the field's 122.050")
    }

    /// Of two names for one frequency, the 8.33 kHz channel's: the author's 19 Oct answers, Bern 121.030 (its CTR
    /// writes 121.025), Les Eplatures 118.130 (118.125), Grenchen 120.105 (the airport database 120.100).
    func testOfTwoNamesTheEightThirtyThreeChannelsWins() {
        XCTAssertTrue(Station.isEightThirtyThreeName("121.030"))
        XCTAssertTrue(Station.isEightThirtyThreeName("118.135"))
        XCTAssertFalse(Station.isEightThirtyThreeName("121.025"))
        XCTAssertFalse(Station.isEightThirtyThreeName("124.7"))
        XCTAssertEqual(Station.preferredName("121.025", "121.030"), "121.030")
        XCTAssertEqual(Station.preferredName("118.130", "118.125"), "118.130")
        XCTAssertEqual(Station.preferredName("124.700", "124.70"), "124.700", "both 25 kHz names: the first")
    }

    /// Bern: the destination's tower 121.030, its CTR 121.025. The whole flight says 121.030: NOW in the CTR, the
    /// nav log's row into it, the Radio box (one line).
    func testOneFrequencyHasOneNameAcrossTheFlight() {
        let bern = RouteRadioPlanner.Aerodrome(ident: "LSXB", contact: Station(frequency: "121.030", callSign: "LSXB TWR"),
                                               atis: nil, ground: nil)
        let ctr = airspace("CTR XB", type: 4, icaoClass: 3, lon: 8.05...8.3, frequency: ("121.025", "XB TOWER"))
        let result = plan([ctr], destination: .some(bern))
        let t = result.timeline
        XCTAssertEqual(read(t, at: t.totalNM - 1).now?.station.frequency, "121.030")
        XCTAssertFalse(result.rows.contains { $0.station?.frequency == "121.025" }, result.rows.map { $0.station?.frequency ?? "-" }.description)
        XCTAssertTrue(result.rows.flatMap(\.remarks).allSatisfy { !$0.contains("121.025") })
        XCTAssertFalse(result.stations.contains { $0.frequency == "121.025" })
        // Grenchen the other way round: the airport database's 120.100, the CTR's 120.105.
        let grenchen = RouteRadioPlanner.Aerodrome(ident: "LSXA", contact: Station(frequency: "120.100", callSign: "LSXA TWR"),
                                                   atis: nil, ground: nil)
        let own = airspace("CTR XA", type: 4, icaoClass: 3, lon: 6.9...7.2, frequency: ("120.105", "XA TOWER"))
        let fromGrenchen = plan([own], departure: .some(grenchen))
        XCTAssertEqual(fromGrenchen.rows[0].station?.frequency, "120.105")
        XCTAssertEqual(read(fromGrenchen.timeline, at: 0, speed: 0, departureOver: false).now?.station.frequency, "120.105")
    }

    // MARK: - FIS (q4, q5)

    func testTheNextFISIsNextAndNowChangesAtItsBoundary() {
        let t = timeline(destination: .some(nil))
        let b = boundary(t)
        XCTAssertEqual(b, 30.7, accuracy: 0.5)
        let before = read(t, at: b - 0.3)
        XCTAssertEqual(before.now?.station, geneva)
        XCTAssertEqual(before.next, zurich)
        XCTAssertEqual(read(t, at: b + 0.3).now?.station, zurich)
    }

    // MARK: - Zones (q6)

    private func alphaCTR(_ name: String = "CTR ALPHA") -> Airspace {
        airspace(name, type: 4, icaoClass: 3, lon: 7.40...7.50, frequency: ("130.150", "ALPHA TOWER"))
    }

    func testAZoneIsNowFiveMinutesBeforeItsBoundaryAndUntilItsExit() {
        let t = timeline([alphaCTR()])
        let zone = t.calls.first { $0.kind == .unit }!
        XCTAssertEqual(zone.fromNM, 16.4, accuracy: 0.3)
        let early = read(t, at: zone.fromNM - 8.7)
        XCTAssertEqual(early.now?.station, geneva)
        XCTAssertEqual(early.next?.callSign, "ALPHA TWR")
        XCTAssertEqual(read(t, at: zone.fromNM - 8.0).now?.station.callSign, "ALPHA TWR")
        XCTAssertEqual(read(t, at: zone.toNM - 0.2).now?.station.callSign, "ALPHA TWR")
        XCTAssertEqual(read(t, at: zone.toNM + 0.2).now?.station, geneva)
    }

    /// Five minutes are fewer miles for a slower aircraft: at 60 kt the call starts 5 NM out.
    func testTheMinutesFollowTheGroundSpeed() {
        let t = timeline([alphaCTR()])
        let zone = t.calls.first { $0.kind == .unit }!
        XCTAssertEqual(read(t, at: zone.fromNM - 5.5, speed: 60).now?.station, geneva)
        XCTAssertEqual(read(t, at: zone.fromNM - 4.5, speed: 60).now?.station.callSign, "ALPHA TWR")
    }

    func testAnHXZoneCountsAsActiveAndSaysSo() {
        let t = timeline([alphaCTR("CTR ALPHA (HX)")])
        let zone = t.calls.first { $0.kind == .unit }!
        XCTAssertTrue(zone.station.isHX)
        XCTAssertEqual(read(t, at: zone.fromNM).now?.station.callSign, "ALPHA TWR")
    }

    /// An aerodrome whose reporting points the route flies is called there, its zone entered or not: from 5 min before
    /// its first point to 2 NM past its last (Les Eplatures over V and E, the author's device check r3-2).
    func testAnAerodromesReportingPointsAreCalledThere() {
        var wps = waypoints()
        wps[2].aerodromeICAO = "LSXC"
        let lsxc = RadioTimeline.NearbyField(ident: "LSXC", coordinate: .init(latitude: 47.15, longitude: 7.6),
                                             contact: Station(frequency: "118.130", callSign: "LSXC TWR"))
        let t = timeline(waypoints: wps, fields: [lsxc])
        let point = t.waypointNM[2]
        XCTAssertEqual(read(t, at: point - 8.7).now?.station, geneva)
        XCTAssertEqual(read(t, at: point - 8.7).next?.callSign, "LSXC TWR")
        XCTAssertEqual(read(t, at: point - 8.0).now?.station.callSign, "LSXC TWR")
        XCTAssertEqual(read(t, at: point + 1.8).now?.station.callSign, "LSXC TWR")
        XCTAssertEqual(read(t, at: point + 2.2).now?.station, geneva)
        // A point a few miles out (V, 6.7 NM from LSGN): the departure stays NOW on the ground and to the level-off,
        // the aerodrome NEXT; then the aerodrome (the dr-3 replay of 19 Oct read LSGC TWR on the ground at LSGN).
        var nearPlan = FlightPlan(waypoints: waypoints())
        nearPlan.waypoints[1] = FlightPlanWaypoint(name: "V", coordinate: .init(latitude: 47.0, longitude: 7.09),
                                                   altitude: 5000, plannedGroundSpeed: 100)
        nearPlan.waypoints[1].aerodromeICAO = "LSXC"
        nearPlan.calculateRouteData()
        let early = timeline(waypoints: nearPlan.waypoints, fields: [lsxc])
        let ground = read(early, at: 0, speed: 100, departureOver: false)
        XCTAssertEqual(ground.now?.station.callSign, "LSXA AFIS")
        XCTAssertEqual(ground.next?.callSign, "LSXC TWR")
        XCTAssertEqual(read(early, at: 1.5, departureOver: false).now?.station.callSign, "LSXA AFIS", "climbing")
        XCTAssertEqual(read(early, at: 0.5, speed: 30, departureOver: false).next?.callSign, "LSXC TWR",
                       "NEXT in the climb, before its 5 min have begun: the level-off may come after them")
        XCTAssertEqual(read(early, at: 1.5, departureOver: true).now?.station.callSign, "LSXC TWR", "levelled off")
        // Not the departure's or the destination's points: those have their own calls.
        var own = waypoints()
        own[2].aerodromeICAO = "LSXA"
        XCTAssertFalse(timeline(waypoints: own, fields: [lsxc]).calls.contains { $0.kind == .unit })
    }

    /// One frequency, one name: a TMA over the destination on its tower's frequency is called by the destination too,
    /// HX as its CTR is. Bern's read "BERN TWR", "LSZB TWR", then "LSZB TWR HX" (the route 3 replay, 19 Oct 2026).
    func testAZoneOverTheDestinationOnItsFrequencyIsCalledByIt() {
        let bern = RouteRadioPlanner.Aerodrome(ident: "LSXB", contact: Station(frequency: "121.030", callSign: "LSXB TWR"),
                                               atis: nil, ground: nil)
        let tma = airspace("TMA XB", type: 7, icaoClass: 3, lon: 7.85...8.3, frequency: ("121.030", "XB TOWER"))
        let ctr = airspace("CTR XB (HX)", type: 4, icaoClass: 3, lon: 8.1...8.3, frequency: ("121.025", "XB TOWER"))
        // TMA BERN 1 publishes no frequency and doesn't reach the field: CTR BERN's, borrowed.
        let tma1 = airspace("TMA XB 1", type: 7, icaoClass: 3, lon: 7.8...7.95)
        for t in [plan([tma, ctr], destination: .some(bern)).timeline, plan([tma1, ctr], destination: .some(bern)).timeline] {
            let names = stride(from: 25.0, to: t.totalNM, by: 1).compactMap { read(t, at: $0).now?.station }
                .filter { $0.hasSameFrequency(as: bern.contact) }
            XCTAssertFalse(names.isEmpty)
            XCTAssertEqual(Set(names.map(\.callSign)), ["LSXB TWR"], names.map(\.callSign).description)
            XCTAssertTrue(names.allSatisfy(\.isHX))
        }
    }

    /// On the ground the departure is NOW, a zone a few miles out notwithstanding; in the climb the zone takes NOW
    /// 5 min before its boundary, as it must be called before entry.
    func testOnTheGroundTheDepartureIsNowBeforeAZoneNearby() {
        let ctr = airspace("CTR ALPHA", type: 4, icaoClass: 3, lon: 7.08...7.2, frequency: ("130.150", "ALPHA TOWER"))
        let t = timeline([ctr])
        let ground = read(t, at: 0, speed: 100, departureOver: false)
        XCTAssertEqual(ground.now?.station.callSign, "LSXA AFIS")
        XCTAssertEqual(ground.next?.callSign, "ALPHA TWR")
        XCTAssertEqual(read(t, at: 1, departureOver: false).now?.station.callSign, "ALPHA TWR")
    }

    /// A CTR crossed on the way is called by the aerodrome inside it, on its 8.33 kHz name: "GRENCHEN TWR HX"
    /// was too wide for NOW, which showed no name at all (the author's device check zn-3, 19 Oct 2026).
    func testAZoneOnTheWayIsCalledByItsAerodrome() {
        let inside = RadioTimeline.NearbyField(ident: "LSXC", coordinate: .init(latitude: 47.05, longitude: 7.45),
                                               contact: Station(frequency: "130.155", callSign: "LSXC TWR"))
        let t = timeline([alphaCTR("CTR ALPHA (HX)")], fields: [inside])
        let zone = t.calls.first { $0.kind == .unit }!
        let now = read(t, at: zone.fromNM).now?.station
        XCTAssertEqual(now?.callSign, "LSXC TWR")
        XCTAssertEqual(now?.frequency, "130.155")
        XCTAssertEqual(now?.isHX, true)
        XCTAssertFalse(t.listens.contains { $0.station.callSign == "LSXC TWR" }, "in a zone, never a field on the way")
        // An aerodrome on another frequency leaves the zone its own name.
        let other = RadioTimeline.NearbyField(ident: "LSXC", coordinate: inside.coordinate,
                                              contact: Station(frequency: "123.605", callSign: "LSXC A/G"))
        XCTAssertEqual(timeline([alphaCTR()], fields: [other]).calls.first { $0.kind == .unit }?.station.callSign, "ALPHA TWR")
    }

    /// TMA GENEVA: the clearance comes from Geneva Information. NOW stays the Info, named with the TMA from
    /// 10 min before.
    func testATMAClearedByTheFISKeepsTheInfoWithTheTMABeside() {
        let tma = airspace("TMA GOLF 2", type: 7, icaoClass: 2, lon: 7.45...7.65, frequency: ("126.350", "GENEVA INFORMATION"))
        let t = timeline([tma])
        let call = t.calls.first { $0.kind == .tmaViaFIS }!
        XCTAssertEqual(call.note, "TMA GOLF")
        XCTAssertEqual(call.lead, 600)
        XCTAssertNil(read(t, at: call.fromNM - 17.5).now?.note)
        let named = read(t, at: call.fromNM - 16.0)
        XCTAssertEqual(named.now?.note, "TMA GOLF")
        XCTAssertEqual(named.now?.station.frequency, "126.350")
        XCTAssertNil(read(t, at: call.toNM + 0.2).now?.note)
    }

    /// TMA ZUERICH: its data gives ZUERICH TERMINAL, the chart legend the FIS. Crossed on the Info, in the nav log's
    /// rows too; another country's class C TMA keeps its station.
    func testASwissClassCTMAIsCrossedOnTheFIS() {
        let tma = airspace("TMA ZULU 2A", type: 7, icaoClass: 2, lon: 7.80...7.88, frequency: ("127.755", "ZULU TERMINAL"))
        let result = plan([tma])
        let call = result.timeline.calls.first { $0.kind == .tmaViaFIS }
        XCTAssertEqual(call?.station.frequency, "124.700")
        XCTAssertEqual(call?.note, "TMA ZULU")
        XCTAssertEqual(result.rows[3].station?.frequency, "124.700", "the leg into the TMA, on the Info")
        XCTAssertTrue(result.rows[3].remarks.contains { $0.hasPrefix("▸ TMA ZULU 2A (C) +") }, result.rows[3].remarks.description)
        XCTAssertFalse(result.stations.contains { $0.frequency == "127.755" }, result.stations.description)

        let german = airspace("TMA ZULU 2A", type: 7, icaoClass: 2, lon: 7.80...7.88, country: "DE",
                              frequency: ("127.755", "ZULU TERMINAL"))
        let abroad = plan([german])
        XCTAssertEqual(abroad.timeline.calls.first { $0.kind == .unit }?.station.frequency, "127.755")
        XCTAssertTrue(abroad.stations.contains { $0.frequency == "127.755" })
    }

    /// Two stretches of one frequency (a CTR's two sectors) are one call: NOW doesn't change between them.
    func testZoneStretchesOnOneFrequencyAreOneCall() {
        let one = airspace("CTR ALPHA 1", type: 4, icaoClass: 3, lon: 7.40...7.45, frequency: ("130.150", "ALPHA TOWER"))
        let two = airspace("CTR ALPHA 2", type: 4, icaoClass: 3, lon: 7.45...7.55, frequency: ("130.150", "ALPHA TOWER"))
        XCTAssertEqual(timeline([one, two]).calls.filter { $0.kind == .unit }.count, 1)
    }

    /// A zone the route may enter (its ceiling in ft AGL, the ground unknown) never takes NOW; it is listed.
    func testAPossibleZoneIsListedNeverNow() {
        var rmz = airspace("RMZ GOLF", type: 6, icaoClass: 6, lon: 7.35...7.55, frequency: ("120.105", "GOLF INFORMATION"))
        rmz = Airspace(id: rmz.id, name: rmz.name, type: 6, icaoClass: 6, country: "CH",
                       upperCeiling: AltitudeLimit(value: 2000, unit: 1, referenceDatum: 0),
                       lowerCeiling: AltitudeLimit(value: 0, unit: 1, referenceDatum: 0),
                       geometry: rmz.geometry, activity: nil, frequencies: rmz.frequencies)
        let t = timeline([rmz])
        XCTAssertEqual(t.possible.first?.station.callSign, "GOLF INFO")
        XCTAssertFalse(t.calls.contains { $0.station.frequency == "120.105" })
    }

    // MARK: - Destination (q8, q9)

    func testTheDestinationIsNowFiveMinutesOut() {
        let t = timeline()
        XCTAssertEqual(read(t, at: t.totalNM - 8.7).now?.station, zurich)
        XCTAssertEqual(read(t, at: t.totalNM - 8.7, departureOver: true).next?.callSign, "LSXB ATIS",
                       "the ATIS, listen-only, from 10 min before the call")
        XCTAssertEqual(read(t, at: t.totalNM - 8.0).now?.station.callSign, "LSXB TWR")
    }

    /// The arrival point (the route's last point of that aerodrome) 2 min ahead comes first: 3.3 NM before D.
    func testTheDestinationIsNowTwoMinutesBeforeItsArrivalPoint() {
        let t = timeline(waypoints: waypoints(arrivalPointOf: "LSXB"))
        let d = t.waypointNM[3]
        XCTAssertEqual(read(t, at: d - 3.6).now?.station, zurich)
        XCTAssertEqual(read(t, at: d - 3.0).now?.station.callSign, "LSXB TWR")
    }

    /// Another aerodrome's point is no arrival point.
    func testAnotherAerodromesPointIsNoArrivalPoint() {
        let t = timeline(waypoints: waypoints(arrivalPointOf: "LSXC"))
        XCTAssertEqual(read(t, at: t.waypointNM[3] - 3.0).now?.station, zurich)
    }

    /// A destination in its CTR is called 5 min before the CTR, under its own name.
    func testTheDestinationsZoneBoundaryIsItsCallPoint() {
        let ctr = airspace("CTR XB", type: 4, icaoClass: 3, lon: 8.05...8.3, frequency: ("118.125", "XB TOWER"))
        let t = timeline([ctr])
        let entry = t.calls.first { $0.kind == .destination }!.fromNM
        XCTAssertEqual(entry, t.calls.first { $0.kind == .unit }!.fromNM, accuracy: 0.01)
        XCTAssertLessThan(entry, t.totalNM - 4)
        XCTAssertEqual(read(t, at: entry - 8.7).now?.station, zurich)
        XCTAssertEqual(read(t, at: entry - 8.0).now?.station.callSign, "LSXB TWR")
    }

    /// q9: the ATIS in NEXT, LISTEN, from 10 min before the call point until it; then the contact is NOW and
    /// nothing is NEXT.
    func testTheATISIsListenInNextFromTenMinutesBeforeTheCall() {
        let t = timeline()
        let call = t.totalNM - 8.33
        let before = read(t, at: call - 17.0)
        XCTAssertFalse(before.nextIsListen)
        let listen = read(t, at: call - 16.0)
        XCTAssertEqual(listen.next?.callSign, "LSXB ATIS")
        XCTAssertTrue(listen.nextIsListen)
        let called = read(t, at: call + 0.3)
        XCTAssertEqual(called.now?.station.callSign, "LSXB TWR")
        XCTAssertNil(called.next)
    }

    /// After landing at the route's end (`followLanding` takes the progress to its length): nothing NEXT (#419).
    func testAfterLandingNothingIsNext() {
        let t = timeline()
        let landed = read(t, at: t.totalNM, speed: 0)
        XCTAssertEqual(landed.now?.station.callSign, "LSXB TWR")
        XCTAssertNil(landed.next)
    }

    /// Without the destination's frequencies the FIS stays to the end.
    func testWithoutTheDestinationsContactTheFISStays() {
        let t = timeline(destination: .some(nil))
        XCTAssertEqual(read(t, at: t.totalNM - 1).now?.station, zurich)
        XCTAssertNil(read(t, at: t.totalNM - 1).next)
    }

    // MARK: - One frequency, one station (R6)

    func testNextNeverRepeatsNowsFrequency() {
        let sameAsFIS = RouteRadioPlanner.Aerodrome(ident: "LSXB", contact: Station(frequency: "124.70", callSign: "LSXB A/G"),
                                                    atis: nil, ground: nil)
        let t = timeline(destination: .some(sameAsFIS))
        let reading = read(t, at: boundary(t) + 1)
        XCTAssertEqual(reading.now?.station, zurich)
        XCTAssertNil(reading.next)
    }

    // MARK: - Aerodromes on the way (q7 and its note)

    private func field(_ ident: String, latitude: Double, longitude: Double = 7.6) -> RadioTimeline.NearbyField {
        RadioTimeline.NearbyField(ident: ident, coordinate: .init(latitude: latitude, longitude: longitude),
                                  contact: Station(frequency: "123.605", callSign: "\(ident) A/G"))
    }

    /// The destination without an ATIS, so its window doesn't cover the field's.
    private var destinationWithoutATIS: RouteRadioPlanner.Aerodrome {
        RouteRadioPlanner.Aerodrome(ident: "LSXB", contact: destination.contact, atis: nil, ground: nil)
    }

    /// 1.2 NM off the route: in NEXT, LISTEN, from 5 min before abeam to 2 NM past; NOW stays the Info.
    func testAnAerodromeOnTheWayIsListenInNext() {
        let t = timeline(destination: .some(destinationWithoutATIS), fields: [field("LSXC", latitude: 47.02)])
        let abeam = t.waypointNM[2]
        XCTAssertFalse(read(t, at: abeam - 8.7).nextIsListen)
        let listen = read(t, at: abeam - 8.0)
        XCTAssertEqual(listen.next?.callSign, "LSXC A/G")
        XCTAssertTrue(listen.nextIsListen)
        XCTAssertEqual(listen.now?.station, geneva)
        XCTAssertTrue(read(t, at: abeam + 1.8).nextIsListen)
        XCTAssertFalse(read(t, at: abeam + 2.2).nextIsListen)
    }

    func testAerodromesOnTheWayCanBeTurnedOff() {
        let t = timeline(fields: [field("LSXC", latitude: 47.02)])
        let reading = read(t, at: t.waypointNM[2] - 4, fieldsOnTheWay: false)
        XCTAssertFalse(reading.nextIsListen)
        XCTAssertEqual(reading.next, zurich)
    }

    /// 3.6 NM aside is not on the way; nor is a field with a zone of its own (its zone is a call when the route
    /// enters it), nor the departure or the destination.
    func testOnlyAerodromesWithinTwoMilesAndNoZoneAreOnTheWay() {
        XCTAssertTrue(timeline(fields: [field("LSXC", latitude: 47.06)]).listens.allSatisfy { $0.kind == .atis })
        let ctr = airspace("CTR CHARLIE", type: 4, icaoClass: 3, lon: 7.55...7.65, lat: 47.01...47.2,
                           frequency: ("119.000", "CHARLIE TOWER"))
        XCTAssertTrue(timeline([ctr], fields: [field("LSXC", latitude: 47.02)]).listens.allSatisfy { $0.kind == .atis },
                      "a CTR around the field, even one the route stays under or beside")
        XCTAssertTrue(timeline(fields: [field("LSXB", latitude: 47.0, longitude: 8.2)]).listens.allSatisfy { $0.kind == .atis })
    }

    /// An out-and-back passes an aerodrome twice: a LISTEN each way (LSPL on the Grenchen loop, the author's device
    /// check ls-1, 19 Oct 2026, had it on the way out only).
    func testAnAerodromePassedTwiceIsListenEachWay() {
        var loop = FlightPlan(waypoints: [7.0, 7.6, 7.02].enumerated().map { i, lon in
            FlightPlanWaypoint(name: ["LSXA", "TP", "LSXB"][i], coordinate: .init(latitude: 47.0, longitude: lon),
                               altitude: i == 1 ? 5000 : 1500, plannedGroundSpeed: 100)
        })
        loop.calculateRouteData()
        let noATIS = RouteRadioPlanner.Aerodrome(ident: "LSXB", contact: destination.contact, atis: nil, ground: nil)
        let t = timeline(waypoints: loop.waypoints, destination: .some(noATIS),
                         fields: [field("LSXC", latitude: 47.02, longitude: 7.3)])
        let passes = t.listens.filter { $0.kind == .fieldOnTheWay }.map(\.atNM)
        XCTAssertEqual(passes.count, 2, passes.description)
        XCTAssertEqual(passes.first ?? 0, t.waypointNM[1] / 2, accuracy: 1)
        XCTAssertEqual(passes.last ?? 0, t.waypointNM[1] + (t.totalNM - t.waypointNM[1]) / 2 - 0.4, accuracy: 1.5)
        XCTAssertEqual(read(t, at: passes.last! - 1).next?.callSign, "LSXC A/G")
        XCTAssertTrue(read(t, at: passes.last! - 1).nextIsListen)
    }

    /// The destination's ATIS and an aerodrome on the way, one after the other: the one whose window ends first,
    /// the field passed, then the ATIS (the author's device check ls-1, 19 Oct 2026: LSPL abeam on the way back to
    /// Grenchen, where the ATIS used to win and LSPL never showed). ROUTE lists both.
    func testTwoListensComeOneAfterTheOther() {
        let t = timeline(fields: [field("LSXD", latitude: 47.01, longitude: 7.9)])
        let abeam = t.waypointNM[3]
        let before = read(t, at: abeam - 9)
        XCTAssertEqual(before.next?.callSign, "LSXB ATIS", "the ATIS alone in its window")
        let field = read(t, at: abeam - 1)
        XCTAssertEqual(field.next?.callSign, "LSXD A/G")
        XCTAssertTrue(field.nextIsListen)
        let after = read(t, at: abeam + 2.2)
        XCTAssertEqual(after.next?.callSign, "LSXB ATIS")
        XCTAssertTrue(after.nextIsListen)
        let route = t.ahead(.init(progressNM: abeam - 1, speedKt: 100, departureOver: true))
        XCTAssertEqual(route.filter(\.listen).map(\.station.callSign), ["LSXD A/G", "LSXB ATIS"])
    }

    // MARK: - FIS areas (q4)

    /// The server's file for Bâle Information over AZ4, as the job writes it.
    private static let az4File = """
    {"v":1,"generated":"2026-10-18T18:45:48Z","areas":[{"id":"ch-bale-az4","country":"CH","station":"BALE INFORMATION",
    "frequency":"130.900","airspace":{"name":"TMA BALE ZURICH AZ4","type":7,"icaoClass":4},"source":"French eAIP"}]}
    """

    /// A stand-in for AZ4 over the route between 7.4° and 7.6° E: class E from 2,000 ft AGL.
    private func az4(floorAGL: Int = 2000, name: String = "TMA BALE ZURICH AZ4", country: String = "CH") -> Airspace {
        Airspace(id: name, name: name, type: 7, icaoClass: 4, country: country,
                 upperCeiling: AltitudeLimit(value: 100, unit: 6, referenceDatum: 2),
                 lowerCeiling: AltitudeLimit(value: floorAGL, unit: 1, referenceDatum: 0),
                 geometry: AirspaceGeometry(type: "Polygon", coordinates: [[[7.4, 46.9], [7.4, 47.1], [7.6, 47.1], [7.6, 46.9], [7.4, 46.9]]]),
                 activity: nil, frequencies: nil)
    }

    private func areas(_ airspaces: [Airspace]) throws -> [FISArea] {
        FISArea.areas(of: try JSONDecoder().decode(FISAreaFile.self, from: Data(Self.az4File.utf8)), in: airspaces)
    }

    func testTheServersFileNamesAnAirspaceTheDeviceDraws() throws {
        let found = try areas([az4(), alphaCTR()])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.station, Station(frequency: "130.900", callSign: "BALE INFO"))
        XCTAssertEqual(found.first?.airspaces.map(\.name), ["TMA BALE ZURICH AZ4"])
        XCTAssertTrue(try areas([az4(name: "TMA BALE ZURICH AZ4 T3")]).isEmpty, "another part")
        XCTAssertTrue(try areas([az4(country: "FR")]).isEmpty, "another country's")
        XCTAssertTrue(try areas([]).isEmpty, "the country not downloaded: the sectors as before")
    }

    /// Over AZ4 at the leg's cruise (5,000 ft, 3,500 ft over 1,500 ft of ground): Bâle Information, between
    /// Geneva's stretches.
    func testAFISAreaIsTheFISWhereTheCruiseIsInIt() throws {
        let result = RouteRadioPlanner.plan(.init(
            waypoints: waypoints(), airspaces: [], departure: departure, destination: destination,
            fis: { [geneva, zurich] point in point.longitude < 7.75 ? geneva : zurich },
            fisAreas: try areas([az4()]), groundFallbackFt: 1500))
        let stations = result.timeline.calls.filter { $0.kind == .fis }.map(\.station.callSign)
        XCTAssertEqual(stations, ["GENEVA INFO", "BALE INFO", "GENEVA INFO", "ZURICH INFO"])
        let bale = result.timeline.calls.first { $0.station.callSign == "BALE INFO" }!
        XCTAssertEqual(bale.fromNM, 16.4, accuracy: 1.1)
        XCTAssertTrue(result.stations.contains { $0.label == "BALE INFO" && $0.frequency == "130.900" }, "on the nav log")
        // Its floor above the cruise (6,000 ft AGL over 1,500 ft of ground is 7,500 ft): no Bâle.
        let high = RouteRadioPlanner.plan(.init(
            waypoints: waypoints(), airspaces: [], departure: departure, destination: destination,
            fis: { [geneva, zurich] point in point.longitude < 7.75 ? geneva : zurich },
            fisAreas: try areas([az4(floorAGL: 6000)]), groundFallbackFt: 1500))
        XCTAssertFalse(high.timeline.calls.contains { $0.station.callSign == "BALE INFO" })
        // The ground unknown (no terrain, no aerodrome elevation): a floor in ft AGL can't be judged, no Bâle.
        let unknown = RouteRadioPlanner.plan(.init(
            waypoints: waypoints(), airspaces: [], departure: departure, destination: destination,
            fis: { [geneva, zurich] point in point.longitude < 7.75 ? geneva : zurich },
            fisAreas: try areas([az4()])))
        XCTAssertFalse(unknown.timeline.calls.contains { $0.station.callSign == "BALE INFO" })
    }

    // MARK: - ROUTE's radio

    func testAheadIsEveryCallFromNowOnInOrder() {
        let t = timeline([alphaCTR()], fields: [field("LSXC", latitude: 47.02)])
        let names = t.ahead(.init(progressNM: 2, speedKt: 100, departureOver: false)).map(\.station.callSign)
        XCTAssertEqual(names, ["GENEVA INFO", "LSXA AFIS", "ALPHA TWR", "LSXC A/G", "ZURICH INFO", "LSXB ATIS", "LSXB TWR"])
        let later = t.ahead(.init(progressNM: 35, speedKt: 100, departureOver: true)).map(\.station.callSign)
        XCTAssertEqual(later, ["ZURICH INFO", "LSXB ATIS", "LSXB TWR"])
    }

    // MARK: - Progress along the route

    func testProgressIsTheFixOnTheLegFlownTo() {
        let t = timeline()
        let wps = waypoints().map(\.coordinate)
        let mid = CLLocationCoordinate2D(latitude: 47.02, longitude: 7.45)
        let progress = t.progress(of: mid, flyingTo: 2, waypoints: wps)!
        XCTAssertEqual(progress.nm, (t.waypointNM[1] + t.waypointNM[2]) / 2, accuracy: 0.2)
        XCTAssertEqual(progress.offRouteNM, 1.2, accuracy: 0.1)
        XCTAssertEqual(t.progress(of: wps[0], flyingTo: 0, waypoints: wps)!.nm, 0)
        XCTAssertEqual(t.progress(of: wps[4], flyingTo: 5, waypoints: wps)!.nm, t.totalNM)
        XCTAssertEqual(t.progress(of: CLLocationCoordinate2D(latitude: 47.0, longitude: 7.2), flyingTo: 2,
                                  waypoints: wps)!.nm, t.waypointNM[1], accuracy: 0.01, "never behind the leg's start")
    }
}
