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
