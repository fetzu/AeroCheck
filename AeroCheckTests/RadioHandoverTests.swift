import XCTest
import CoreLocation
@testable import AeroCheck

/// `RadioHandover`: NEXT comes due, the pilot's tap switches, the app catches up at the latest point. The author's
/// answers of 19 Oct 2026 to the proposal "Frequency Handover" (6.4.3).
///
/// The route of `RadioTimelineTests`: east along 47°N from a field at 7.0° E to one at 8.2° E, 49 NM, at 100 kt; Geneva
/// Info west of 7.75° E (the boundary about 30.7 NM out), Zurich Info east of it. CTR ALPHA from 7.40° to 7.50° E
/// (its boundary about 16.4 NM out, its exit about 20.5 NM); its call is due 5 min (8.3 NM) before the boundary.
final class RadioHandoverTests: XCTestCase {

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
    private let lsxa = Station(frequency: "122.050", callSign: "LSXA AFIS")
    private let alpha = Station(frequency: "130.150", callSign: "ALPHA TWR")

    private func waypoints() -> [FlightPlanWaypoint] {
        let lons = [7.0, 7.3, 7.6, 7.9, 8.2]
        let alts: [Double] = [1500, 5000, 5000, 5000, 1500]
        let names = ["LSXA", "B", "C", "D", "LSXB"]
        var plan = FlightPlan(waypoints: lons.indices.map { i in
            FlightPlanWaypoint(name: names[i], coordinate: .init(latitude: 47.0, longitude: lons[i]),
                               altitude: alts[i], plannedGroundSpeed: 100)
        })
        plan.calculateRouteData()
        return plan.waypoints
    }

    private func ctr(_ lon: ClosedRange<Double> = 7.40...7.50, name: String = "CTR ALPHA",
                     frequency: (String, String) = ("130.150", "ALPHA TOWER")) -> Airspace {
        let lat = 46.9...47.1
        let ring: [[Double]] = [
            [lon.lowerBound, lat.lowerBound], [lon.lowerBound, lat.upperBound],
            [lon.upperBound, lat.upperBound], [lon.upperBound, lat.lowerBound], [lon.lowerBound, lat.lowerBound],
        ]
        return Airspace(
            id: name, name: name, type: 4, icaoClass: 3, country: "CH",
            upperCeiling: AltitudeLimit(value: 130, unit: 6, referenceDatum: 2),
            lowerCeiling: AltitudeLimit(value: 0, unit: 1, referenceDatum: 0),
            geometry: AirspaceGeometry(type: "Polygon", coordinates: [ring]), activity: nil,
            frequencies: [AirspaceFrequency(value: frequency.0, name: frequency.1, primary: true, unit: nil)])
    }

    private func timeline(_ airspaces: [Airspace] = [], atis: String? = "128.525") -> RadioTimeline {
        RouteRadioPlanner.plan(.init(
            waypoints: waypoints(), airspaces: airspaces,
            departure: RouteRadioPlanner.Aerodrome(ident: "LSXA", contact: lsxa, atis: nil, ground: nil),
            destination: RouteRadioPlanner.Aerodrome(ident: "LSXB", contact: Station(frequency: "118.125", callSign: "LSXB TWR"),
                                                     atis: atis, ground: nil),
            fis: { [geneva, zurich] point in point.longitude < 7.75 ? geneva : zurich })).timeline
    }

    /// One reading at `nm`, the state carried on.
    @discardableResult
    private func read(_ handover: inout RadioHandover, _ t: RadioTimeline, at nm: Double, departureOver: Bool = true,
                      speed: Double = 100) -> (reading: RadioHandover.Reading, switched: RadioHandover.Switch?) {
        let result = handover.advanced(on: t, at: .init(progressNM: nm, speedKt: speed, departureOver: departureOver))
        handover = result.state
        return (result.reading, result.switched)
    }

    private func moment(_ nm: Double, departureOver: Bool = true) -> RadioTimeline.Moment {
        .init(progressNM: nm, speedKt: 100, departureOver: departureOver)
    }

    /// The pilot taps NEXT at `nm`.
    private func tapNext(_ handover: inout RadioHandover, _ t: RadioTimeline, at nm: Double) {
        let reading = read(&handover, t, at: nm).reading
        guard let next = reading.next else { return XCTFail("nothing NEXT at \(nm)") }
        handover = reading.nextIsListen
            ? handover.hearing(next, endsNM: reading.listenEndsNM ?? nm)
            : handover.switching(to: next, kind: reading.nextKind, on: t, at: moment(nm))
    }

    /// Left the departure at the level-off, 3 NM out, with a tap: on Geneva Info.
    private func onGeneva(_ t: RadioTimeline) -> RadioHandover {
        var handover = RadioHandover()
        read(&handover, t, at: 0, departureOver: false)
        tapNext(&handover, t, at: 3)
        XCTAssertEqual(handover.station, geneva)
        return handover
    }

    // MARK: - Due, the pilot's switch, the app's

    /// On the ground and in the climb the departure is NOW. At the level-off NEXT comes due; NOW stays until the tap.
    func testLeavingTheDepartureComesDueAtTheLevelOff() {
        let t = timeline()
        var handover = RadioHandover()
        let ground = read(&handover, t, at: 0, departureOver: false).reading
        XCTAssertEqual(ground.now?.station, lsxa)
        XCTAssertEqual(ground.next, geneva)
        XCTAssertFalse(ground.nextIsDue)
        let levelled = read(&handover, t, at: 3).reading
        XCTAssertEqual(levelled.now?.station, lsxa, "NOW waits for the tap")
        XCTAssertEqual(levelled.next, geneva)
        XCTAssertTrue(levelled.nextIsDue)
        XCTAssertEqual(levelled.dueLeft ?? 0, 1, accuracy: 0.01, "the line full where it came due")
        XCTAssertEqual(read(&handover, t, at: 6.5).reading.dueLeft ?? 0, 0.5, accuracy: 0.02, "halfway to 10 NM")
        tapNext(&handover, t, at: 6.5)
        let after = read(&handover, t, at: 6.6).reading
        XCTAssertEqual(after.now?.station, geneva)
        XCTAssertFalse(after.nextIsDue)
    }

    /// No tap: 10 NM out the app leaves the departure by itself, and says so.
    func testTheDepartureIsLeftByItselfTenMilesOut() {
        let t = timeline()
        var handover = RadioHandover()
        read(&handover, t, at: 0, departureOver: false)
        XCTAssertNil(read(&handover, t, at: 9.9).switched)
        let out = read(&handover, t, at: 10.1)
        XCTAssertEqual(out.switched, RadioHandover.Switch(from: lsxa, to: geneva))
        XCTAssertEqual(out.reading.now?.station, geneva)
    }

    /// A departure inside its own zone on its frequency: one station, no switch in the zone; left by itself 2 NM out of
    /// it rather than 10 NM out.
    func testADepartureInsideItsZoneIsLeftOutOfIt() {
        let own = ctr(6.9...7.1, name: "CTR XA", frequency: ("122.050", "XA TOWER"))
        let t = timeline([own])
        let exit = t.calls.first { $0.kind == .unit }!.toNM
        var handover = RadioHandover()
        read(&handover, t, at: 0, departureOver: false)
        let inside = read(&handover, t, at: exit - 1).reading
        XCTAssertEqual(inside.now?.station.callSign, "LSXA AFIS")
        XCTAssertFalse(inside.nextIsDue, "the zone is the field's own frequency")
        let out = read(&handover, t, at: exit + 0.5).reading
        XCTAssertTrue(out.nextIsDue, "out of the zone after the level-off: the FIS due")
        XCTAssertEqual(out.next, geneva)
        XCTAssertNil(read(&handover, t, at: exit + RadioTimeline.zoneExitMarginNM - 0.1).switched)
        XCTAssertEqual(read(&handover, t, at: exit + RadioTimeline.zoneExitMarginNM + 0.1).switched?.to, geneva)
    }

    /// The destination inside its zone: due 5 min before the boundary, caught up at it.
    func testTheDestinationIsCaughtUpAtItsZonesBoundary() {
        let field = ctr(8.05...8.3, name: "CTR XB", frequency: ("118.125", "XB TOWER"))
        let t = timeline([field], atis: nil)
        let destination = t.calls.first { $0.kind == .destination }!
        var handover = onGeneva(t)
        tapNext(&handover, t, at: 30)   // Zurich Info, 2 min before its boundary
        XCTAssertEqual(handover.station, zurich)
        let due = read(&handover, t, at: destination.fromNM - 8.0).reading
        XCTAssertEqual(due.next?.callSign, "LSXB TWR")
        XCTAssertTrue(due.nextIsDue)
        XCTAssertNil(read(&handover, t, at: destination.fromNM - 0.1).switched)
        XCTAssertEqual(read(&handover, t, at: destination.fromNM + 0.1).switched?.to.callSign, "LSXB TWR")
    }

    /// A late release: 5 min before the CTR NEXT is due and NOW stays the FIS; with no tap the app switches at the
    /// boundary, where the pilot must be on the tower.
    func testAZoneIsDueFiveMinutesOutAndCaughtUpAtItsBoundary() {
        let t = timeline([ctr()])
        let zone = t.calls.first { $0.kind == .unit }!
        var handover = onGeneva(t)
        let early = read(&handover, t, at: zone.fromNM - 8.6).reading
        XCTAssertEqual(early.next, alpha)
        XCTAssertFalse(early.nextIsDue)
        let due = read(&handover, t, at: zone.fromNM - 8.0).reading
        XCTAssertEqual(due.now?.station, geneva)
        XCTAssertEqual(due.next, alpha)
        XCTAssertTrue(due.nextIsDue)
        let late = read(&handover, t, at: zone.fromNM - 0.1)
        XCTAssertNil(late.switched)
        XCTAssertEqual(late.reading.dueLeft ?? 1, 0, accuracy: 0.03)
        let caught = read(&handover, t, at: zone.fromNM + 0.1)
        XCTAssertEqual(caught.switched, RadioHandover.Switch(from: geneva, to: alpha))
        XCTAssertEqual(caught.reading.now?.station, alpha)
    }

    /// An early release: a tap before NEXT is due switches; the app doesn't switch back, nor again at the boundary.
    /// Out of the zone, the FIS is due, and caught up 2 NM past the exit.
    func testAnEarlyTapHoldsAndTheExitComesDue() {
        let t = timeline([ctr()])
        let zone = t.calls.first { $0.kind == .unit }!
        var handover = onGeneva(t)
        tapNext(&handover, t, at: zone.fromNM - 12)
        XCTAssertEqual(handover.station, alpha)
        let held = read(&handover, t, at: zone.fromNM - 11).reading
        XCTAssertEqual(held.now?.station, alpha)
        XCTAssertEqual(held.next, geneva, "back to the FIS after the zone, not due yet")
        XCTAssertFalse(held.nextIsDue)
        XCTAssertNil(read(&handover, t, at: zone.fromNM + 0.1).switched, "no switch at the boundary: already on it")
        let exit = read(&handover, t, at: zone.toNM + 0.5).reading
        XCTAssertEqual(exit.now?.station, alpha)
        XCTAssertEqual(exit.next, geneva)
        XCTAssertTrue(exit.nextIsDue)
        XCTAssertEqual(read(&handover, t, at: zone.toNM + RadioTimeline.zoneExitMarginNM + 0.1).switched,
                       RadioHandover.Switch(from: alpha, to: geneva))
    }

    /// FIS to FIS: due 2 min before the boundary, caught up at it.
    func testAFISBoundaryIsDueTwoMinutesBefore() {
        let t = timeline(atis: nil)
        let boundary = t.calls.first { $0.kind == .fis && $0.station == zurich }!.fromNM
        var handover = onGeneva(t)
        XCTAssertFalse(read(&handover, t, at: boundary - 3.5).reading.nextIsDue)
        let due = read(&handover, t, at: boundary - 3.0).reading
        XCTAssertEqual(due.next, zurich)
        XCTAssertTrue(due.nextIsDue)
        XCTAssertEqual(read(&handover, t, at: boundary + 0.1).switched, RadioHandover.Switch(from: geneva, to: zurich))
    }

    // MARK: - LISTEN, ROUTE, a station skipped

    /// A tap on a LISTEN means heard: it leaves NEXT, which shows the call after it. A due call wins NEXT over a LISTEN.
    func testAListenTappedIsHeard() {
        let t = timeline()
        var handover = onGeneva(t)
        let boundary = t.calls.first { $0.kind == .fis && $0.station == zurich }!.fromNM
        let due = read(&handover, t, at: boundary - 1).reading
        XCTAssertTrue(due.nextIsDue, "the FIS due before the ATIS's LISTEN")
        tapNext(&handover, t, at: boundary - 1)
        let listen = read(&handover, t, at: boundary + 1).reading
        XCTAssertTrue(listen.nextIsListen)
        XCTAssertEqual(listen.next?.callSign, "LSXB ATIS")
        tapNext(&handover, t, at: boundary + 1)
        let after = read(&handover, t, at: boundary + 2).reading
        XCTAssertFalse(after.nextIsListen)
        XCTAssertEqual(after.next?.callSign, "LSXB TWR")
        XCTAssertEqual(after.now?.station, zurich, "a LISTEN heard never becomes NOW")
    }

    /// A station off the route picked in ROUTE ("contact Bern Approach"): NOW from there; the zone ahead stays due and
    /// is caught up at its boundary.
    func testAStationPickedOffTheRouteKeepsTheZoneDue() {
        let t = timeline([ctr()])
        let zone = t.calls.first { $0.kind == .unit }!
        var handover = onGeneva(t)
        read(&handover, t, at: zone.fromNM - 6)
        let bern = Station(frequency: "127.325", callSign: "BERN APP")
        handover = handover.switching(to: bern, kind: nil, on: t, at: moment(zone.fromNM - 5))
        let picked = read(&handover, t, at: zone.fromNM - 4).reading
        XCTAssertEqual(picked.now?.station, bern)
        XCTAssertEqual(picked.next, alpha)
        XCTAssertTrue(picked.nextIsDue)
        XCTAssertEqual(read(&handover, t, at: zone.fromNM + 0.1).switched, RadioHandover.Switch(from: bern, to: alpha))
    }

    /// Switched past a station to a later one (the zone skipped on the controller's word): the zone is behind the
    /// pilot, never due again nor caught up.
    func testAStationSkippedIsBehind() {
        let t = timeline([ctr()], atis: nil)
        let zone = t.calls.first { $0.kind == .unit }!
        var handover = onGeneva(t)
        handover = handover.switching(to: zurich, kind: .fis, on: t, at: moment(zone.fromNM - 6))
        for nm in stride(from: zone.fromNM - 5, through: zone.toNM + 3, by: 1) {
            let step = read(&handover, t, at: nm)
            XCTAssertNil(step.switched, "\(nm)")
            XCTAssertNotEqual(step.reading.next, alpha, "\(nm)")
            XCTAssertEqual(step.reading.now?.station, zurich, "\(nm)")
        }
    }

    /// A rebuilt timeline keeps the pilot's station; the changes before the aircraft are taken as done.
    func testARebuiltTimelineKeepsThePilotsStation() {
        let t = timeline([ctr()])
        let zone = t.calls.first { $0.kind == .unit }!
        var handover = onGeneva(t)
        read(&handover, t, at: zone.fromNM - 4)
        handover.rebase = true
        let rebased = read(&handover, t, at: zone.fromNM - 3)
        XCTAssertNil(rebased.switched)
        XCTAssertEqual(rebased.reading.now?.station, geneva)
        XCTAssertEqual(rebased.reading.next, alpha, "the zone still ahead")
    }

    /// An aerodrome at its reporting points, V a few miles out: due at the level-off, and with no tap the app switches
    /// 30 s before V, not 10 NM out (the dr-3 replay of 19 Oct switched to LSGC TWR past V), nor at V, where the
    /// point's own mark hid the switch's pill.
    func testAReportingPointsCallIsCaughtUpAtTheFirstPoint() {
        var plan = FlightPlan(waypoints: waypoints())
        plan.waypoints[1] = FlightPlanWaypoint(name: "V", coordinate: .init(latitude: 47.0, longitude: 7.09),
                                               altitude: 5000, plannedGroundSpeed: 100)
        plan.waypoints[1].aerodromeICAO = "LSXC"
        plan.calculateRouteData()
        let lsxcTower = Station(frequency: "118.130", callSign: "LSXC TWR")
        let lsxc = RadioTimeline.NearbyField(ident: "LSXC", coordinate: .init(latitude: 47.15, longitude: 7.09),
                                             contact: lsxcTower)
        let t = RouteRadioPlanner.plan(.init(
            waypoints: plan.waypoints, airspaces: [],
            departure: RouteRadioPlanner.Aerodrome(ident: "LSXA", contact: lsxa, atis: nil, ground: nil),
            destination: RouteRadioPlanner.Aerodrome(ident: "LSXB", contact: Station(frequency: "118.125", callSign: "LSXB TWR"),
                                                     atis: nil, ground: nil),
            fis: { [geneva, zurich] point in point.longitude < 7.75 ? geneva : zurich },
            fieldsNearby: [lsxc])).timeline
        let v = t.waypointNM[1]
        var handover = RadioHandover()
        read(&handover, t, at: 0, departureOver: false)
        let levelled = read(&handover, t, at: 1.5).reading
        XCTAssertEqual(levelled.now?.station, lsxa)
        XCTAssertEqual(levelled.next, lsxcTower)
        XCTAssertTrue(levelled.nextIsDue)
        XCTAssertNotNil(levelled.dueLeft, "the line runs out at V")
        let lead = RadioTimeline.pointLatestLead * 100 / 3600
        XCTAssertNil(read(&handover, t, at: v - lead - 0.1).switched)
        XCTAssertEqual(read(&handover, t, at: v - lead + 0.1).switched?.to, lsxcTower, "30 s before V")
    }

    /// The destination's arrival point (D, LSXB's point): due 2 min before it, and with no tap the app switches 30 s
    /// before it, not at it (ST-URSANNE's mark hid the switch's pill in the dr-3 replay of 19 Oct).
    func testTheDestinationIsCaughtUpBeforeItsArrivalPoint() {
        var wps = waypoints()
        wps[3].aerodromeICAO = "LSXB"
        let t = RouteRadioPlanner.plan(.init(
            waypoints: wps, airspaces: [],
            departure: RouteRadioPlanner.Aerodrome(ident: "LSXA", contact: lsxa, atis: nil, ground: nil),
            destination: RouteRadioPlanner.Aerodrome(ident: "LSXB", contact: Station(frequency: "118.125", callSign: "LSXB TWR"),
                                                     atis: nil, ground: nil),
            fis: { [geneva, zurich] point in point.longitude < 7.75 ? geneva : zurich })).timeline
        let d = t.waypointNM[3]
        var handover = onGeneva(t)
        tapNext(&handover, t, at: 30)
        XCTAssertEqual(handover.station, zurich)
        let due = read(&handover, t, at: d - 3.0).reading
        XCTAssertEqual(due.next?.callSign, "LSXB TWR")
        XCTAssertTrue(due.nextIsDue)
        let lead = RadioTimeline.pointLatestLead * 100 / 3600
        XCTAssertNil(read(&handover, t, at: d - lead - 0.1).switched)
        XCTAssertEqual(read(&handover, t, at: d - lead + 0.1).switched?.to.callSign, "LSXB TWR")
    }

    /// An early release inside the departure's own zone: the FIS is NOW, and NEXT is what comes after it, never the
    /// field just left (the Grenchen replay read LSZG TWR HX in NEXT after an early tap to Zürich Info).
    func testAnEarlyTapInsideAZoneLooksPastIt() {
        let own = ctr(6.9...7.1, name: "CTR XA", frequency: ("122.050", "XA TOWER"))
        let t = timeline([own])
        var handover = RadioHandover()
        read(&handover, t, at: 0, departureOver: false)
        tapNext(&handover, t, at: 2)
        XCTAssertEqual(handover.station, geneva)
        let after = read(&handover, t, at: 2.1).reading
        XCTAssertEqual(after.now?.station, geneva)
        XCTAssertEqual(after.next, zurich)
        XCTAssertFalse(after.nextIsDue)
    }

    /// The app never switches to a stretch under a minute: a FIS boundary 0.4 NM before the destination's latest
    /// point is passed by, and the app goes from Geneva Info to the destination in one switch (Bâle Info held 20 s
    /// before LSZQ in the dr-3 replay with no tap).
    func testTheAppSkipsAStretchUnderAMinute() {
        var wps = waypoints()
        wps[3].aerodromeICAO = "LSXB"
        let tower = Station(frequency: "118.125", callSign: "LSXB TWR")
        let t = RouteRadioPlanner.plan(.init(
            waypoints: wps, airspaces: [],
            departure: RouteRadioPlanner.Aerodrome(ident: "LSXA", contact: lsxa, atis: nil, ground: nil),
            destination: RouteRadioPlanner.Aerodrome(ident: "LSXB", contact: tower, atis: nil, ground: nil),
            fis: { [geneva, zurich] point in point.longitude < 7.87 ? geneva : zurich })).timeline
        let boundary = t.calls.first { $0.kind == .fis && $0.station == zurich }!.fromNM
        let latest = t.waypointNM[3] - RadioTimeline.pointLatestLead * 100 / 3600
        XCTAssertLessThan(latest - boundary, 1.0, "the fixture: Zürich Info's stretch under 1.67 NM")
        var handover = onGeneva(t)
        for nm in stride(from: 10.0, through: boundary - 0.1, by: 1) { XCTAssertNil(read(&handover, t, at: nm).switched) }
        let passed = read(&handover, t, at: boundary + 0.1)
        XCTAssertNil(passed.switched, "Zürich Info's stretch is too short")
        XCTAssertEqual(passed.reading.now?.station, geneva)
        XCTAssertEqual(read(&handover, t, at: latest + 0.1).switched, RadioHandover.Switch(from: geneva, to: tower))
    }

    /// The app's own switch undone: the pilot stays on the FIS, the tower stays due in NEXT without the line, and the
    /// app doesn't switch again; the pilot's tap takes it.
    func testAnUndoneSwitchStaysDueAndIsNotMadeAgain() {
        let t = timeline([ctr()])
        let zone = t.calls.first { $0.kind == .unit }!
        var handover = onGeneva(t)
        read(&handover, t, at: zone.fromNM - 8.0)
        let before = handover
        XCTAssertEqual(read(&handover, t, at: zone.fromNM + 0.1).switched?.to, alpha)
        handover = before.declining(alpha, at: handover.takenAtNM)
        let undone = read(&handover, t, at: zone.fromNM + 0.2)
        XCTAssertNil(undone.switched, "the app doesn't switch again")
        XCTAssertEqual(undone.reading.now?.station, geneva)
        XCTAssertEqual(undone.reading.next, alpha)
        XCTAssertTrue(undone.reading.nextIsDue)
        XCTAssertNil(undone.reading.dueLeft, "no line: the app won't switch")
        XCTAssertNil(read(&handover, t, at: zone.fromNM + 2).switched)
        tapNext(&handover, t, at: zone.fromNM + 2)
        XCTAssertEqual(handover.station, alpha)
        XCTAssertNil(handover.declined)
    }

    /// The departure left by itself 10 NM out, undone: NOW stays the field, Geneva Info due without the line, no
    /// second switch.
    func testAnUndoneDepartureSwitchKeepsTheField() {
        let t = timeline()
        var handover = RadioHandover()
        read(&handover, t, at: 0, departureOver: false)
        read(&handover, t, at: 9.9)
        let before = handover
        XCTAssertEqual(read(&handover, t, at: 10.1).switched?.to, geneva)
        handover = before.declining(geneva, at: handover.takenAtNM)
        let undone = read(&handover, t, at: 10.5)
        XCTAssertNil(undone.switched)
        XCTAssertEqual(undone.reading.now?.station, lsxa, "the pilot's station, past its latest point")
        XCTAssertEqual(undone.reading.next, geneva)
        XCTAssertTrue(undone.reading.nextIsDue)
        XCTAssertNil(undone.reading.dueLeft)
        XCTAssertNil(read(&handover, t, at: 14).switched)
    }

    /// Read first past the level-off (a relaunch without the state): on the station the latest rules put the pilot
    /// on, not back on the departure.
    func testAFirstReadingMidRouteStartsWhereThePilotMustBe() {
        let t = timeline([ctr()])
        var handover = RadioHandover()
        let first = read(&handover, t, at: 12)
        XCTAssertNil(first.switched)
        XCTAssertEqual(first.reading.now?.station, geneva)
        XCTAssertEqual(first.reading.next, alpha)
        XCTAssertTrue(first.reading.nextIsDue, "the zone 4.4 NM ahead, due")
    }

    /// A relaunch mid-flight finds the pilot's station as it was left; the flight's end clears it.
    @MainActor
    func testARelaunchKeepsThePilotsStation() throws {
        let datastore = makeTestDatastore()
        let defaults = makeTestDefaults()
        let appState = makeTestAppState(datastore: datastore, defaults: defaults)
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.startFlight(withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9", circuitMode: false)
        addTeardownBlock { @MainActor in if appState.isFlightActive { appState.cancelFlight() } }
        appState.radioHandover = onGeneva(timeline([ctr()]))
        appState.checkpointActiveFlight(force: true)
        appState.flushPendingCheckpoint()

        let restored = makeTestAppState(datastore: datastore, defaults: defaults)
        XCTAssertTrue(restored.restoreActiveFlightState())
        addTeardownBlock { @MainActor in if restored.isFlightActive { restored.cancelFlight() } }
        XCTAssertEqual(restored.radioHandover?.station, geneva)
        restored.cancelFlight()
        XCTAssertNil(restored.radioHandover)
    }

    /// Kept with the flight: the state survives its encoding.
    func testTheStateIsKeptWithTheFlight() throws {
        let t = timeline([ctr()])
        var handover = onGeneva(t)
        tapNext(&handover, t, at: 10)
        let data = try JSONEncoder().encode(handover)
        XCTAssertEqual(try JSONDecoder().decode(RadioHandover.self, from: data), handover)
        XCTAssertEqual(try JSONDecoder().decode(RadioHandover.self, from: JSONEncoder().encode(RadioHandover())), RadioHandover())
    }
}
