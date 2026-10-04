import CoreLocation
import SwiftUI
import XCTest
@testable import AeroCheck

/// The Companion iPhone's NAV screen in the Cockpit's frame (6.2.0): what it reads from the iPad's stream
/// (the plan rebuilt from its snapshot, the next line, the NOW line, RADIO, the act band's MARK) and its
/// fixed layout (the read band and the act band keep their frames whatever they show).
@MainActor
final class CompanionNavScreenTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FlightPlan.planningCalibrationProvider = nil
        FlightPlan.windsAloftProvider = nil
        FlightPlan.magneticDeclinationProvider = nil
    }

    override func tearDown() {
        FlightPlan.planningCalibrationProvider = nil
        FlightPlan.windsAloftProvider = nil
        FlightPlan.magneticDeclinationProvider = nil
        super.tearDown()
    }

    // MARK: - A route, as the iPad streams it

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// LSZQ → LSGC → LSGN → LSZB, LSGC with the frequency typed for it, timed by the planner.
    private func plan(next: Int = 1) -> FlightPlan {
        var plan = FlightPlan(name: "LSZQ → LSZB", waypoints: [
            FlightPlanWaypoint(name: "LSZQ", coordinate: .init(latitude: 47.4247, longitude: 7.1869), frequency: "120.375"),
            FlightPlanWaypoint(name: "LSGC", coordinate: .init(latitude: 47.0839, longitude: 6.7928), frequency: "120.155"),
            FlightPlanWaypoint(name: "LSGN", coordinate: .init(latitude: 46.9575, longitude: 6.8647)),
            FlightPlanWaypoint(name: "LSZB", coordinate: .init(latitude: 46.9141, longitude: 7.4971), frequency: "121.025"),
        ], plannedDepartureTime: t0)
        plan.calculateRouteData()
        plan.currentWaypointIndex = next
        return plan
    }

    private func snapshot(_ plan: FlightPlan) throws -> CompanionFlightPlanSnapshot {
        // Through the wire, as the phone gets it.
        try JSONDecoder().decode(CompanionFlightPlanSnapshot.self,
                                 from: JSONEncoder().encode(CompanionConnectivityManager.flightPlanSnapshot(of: plan)))
    }

    /// The stream: over the Jura at 100 kt on a track of 230°, the leg timer running for 101 s.
    private func flightData(index: Int = 1, latitude: Double? = 47.20, longitude: Double? = 7.00,
                            speedMPS: Double? = 51.44, running: Bool = true, elapsed: TimeInterval = 101,
                            now: CompanionFrequency? = nil, next: CompanionFrequency? = nil) -> CompanionFlightData {
        CompanionFlightData(isFlightActive: true, currentPhase: "CRUISE", currentPhaseRawValue: 9, isCircuitMode: false,
                            engineStartTime: nil, lineUpTime: t0, landingTime: nil, alwaysUseUTC: false,
                            latitude: latitude, longitude: longitude, speedMPS: speedMPS, altitudeFeet: 4_500,
                            courseDegrees: 230, gpsSignalStatus: "good", ownGPSAvailable: true, gpsSource: "own",
                            cockpitThemeMode: "day", currentWaypointIndex: index,
                            chronometerStartTime: running ? t0 : nil, chronometerElapsed: elapsed,
                            aircraftRegistration: "F-HVXA", aircraftType: "WT9 Dynamic", timestamp: t0,
                            nowFrequency: now, nextFrequency: next)
    }

    // MARK: - The plan, rebuilt

    /// Every leg figure the phone draws survives the trip: the legs read on the phone as on the iPad.
    func testThePlanRebuiltFromTheSnapshotReadsAsTheIPads() throws {
        let original = plan(next: 2)
        let rebuilt = FlightPlan(companion: try snapshot(original))
        XCTAssertEqual(rebuilt.id, original.id)
        XCTAssertEqual(rebuilt.currentWaypointIndex, 2)
        XCTAssertEqual(rebuilt.waypoints.map(\.name), original.waypoints.map(\.name))
        for index in original.waypoints.indices {
            XCTAssertEqual(rebuilt.legArriving(at: index)?.distance, original.legArriving(at: index)?.distance)
            XCTAssertEqual(rebuilt.legArriving(at: index)?.totalLegEET, original.legArriving(at: index)?.totalLegEET)
            XCTAssertEqual(rebuilt.estimatedTimeOver(at: index), original.estimatedTimeOver(at: index))
            XCTAssertEqual(rebuilt.waypoints[index].frequency, original.waypoints[index].frequency)
        }
        XCTAssertEqual(rebuilt.navigationTarget, original.navigationTarget)
    }

    /// The stream's waypoint index is the fresher one (the snapshot goes on change and every 3 s), kept
    /// within the route.
    func testTheStreamsWaypointIsTheOneFlownTo() throws {
        let snap = try snapshot(plan(next: 1))
        XCTAssertEqual(FlightPlan(companion: snap, currentWaypointIndex: 2).currentWaypointIndex, 2)
        XCTAssertEqual(FlightPlan(companion: snap, currentWaypointIndex: CompanionWireLimits.maxIndex).currentWaypointIndex, 4,
                       "past the end: the route flown")
        XCTAssertEqual(FlightPlan(companion: snap).currentWaypointIndex, 1)
    }

    /// Diverting on the iPad: the phone's target is the field, as the iPad's.
    func testADiversionComesBackAsTheTarget() throws {
        var diverting = plan(next: 2)
        diverting.diversion = Diversion(ident: "LSGN", name: "Neuchâtel", latitude: 46.9575, longitude: 6.8647,
                                        frequency: "AFIS 121.050", leftRouteAt: 2)
        let rebuilt = FlightPlan(companion: try snapshot(diverting))
        XCTAssertEqual(rebuilt.diversion?.ident, "LSGN")
        XCTAssertEqual(rebuilt.diversion?.name, "Neuchâtel")
        XCTAssertEqual(rebuilt.navigationTarget, diverting.navigationTarget)
    }

    // MARK: - The next line

    /// The leg being flown as the iPad's next line measures it: the distance and bearing from the streamed
    /// position, the ETE at the streamed ground speed, and the turn from the track.
    func testTheNextLineMeasuresAsTheIPad() throws {
        let original = plan(next: 1)
        let data = flightData()
        let nav = CompanionNav(flightData: data, snapshot: try snapshot(original))
        let next = try XCTUnwrap(nav.next)
        let here = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 47.20, longitude: 7.00),
                              altitude: 4_500 / CompanionNav.feetPerMetre, horizontalAccuracy: 5, verticalAccuracy: 5,
                              timestamp: t0)
        let manager = makeTestPlanManager()
        manager.activeFlightPlan = original
        XCTAssertEqual(next.ident, "LSGC")
        XCTAssertEqual(try XCTUnwrap(next.distanceNM), try XCTUnwrap(manager.distanceToNextWaypoint(from: here)), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(next.bearing), try XCTUnwrap(manager.bearingToNextWaypoint(from: here)), accuracy: 1e-9)
        XCTAssertEqual(next.ete, NextLegLive.ete(distanceNM: next.distanceNM, groundSpeedKnots: 51.44 * CompanionNav.knotsPerMetrePerSecond))
        XCTAssertEqual(try XCTUnwrap(next.turn), CompanionFlightView.signedAngle(try XCTUnwrap(next.bearing) - 230), accuracy: 1e-9)
        XCTAssertFalse(next.diverting)
    }

    /// The read band's next line (`ReadBandNextLine`, the phone Cockpit's) from the stream: the same name,
    /// bearing, distance and ETE, the ETA at that ETE; "—" everywhere with no leg. (6.2.0, the read band)
    func testTheReadBandsNextLineReadsTheStream() throws {
        let nav = CompanionNav(flightData: flightData(), snapshot: try snapshot(plan(next: 1)))
        let next = try XCTUnwrap(nav.next)
        let figures = NextFigures(companion: nav, now: t0)
        XCTAssertEqual(figures.ident, "LSGC")
        XCTAssertEqual(figures.fullIdent, "LSGC")
        XCTAssertEqual(figures.bearing, next.bearing)
        XCTAssertEqual(figures.distanceNM, next.distanceNM)
        XCTAssertEqual(figures.live?.ete, next.ete)
        XCTAssertEqual(figures.live?.eta, t0.addingTimeInterval(try XCTUnwrap(next.ete)))
        XCTAssertFalse(figures.diverting)
        XCTAssertEqual(NextFigures(companion: CompanionNav(flightData: flightData(index: 4), snapshot: try snapshot(plan())),
                                   now: t0), .none, "the route flown")
        XCTAssertEqual(NextFigures(companion: CompanionNav(flightData: flightData(), snapshot: nil), now: t0), .none, "no route")
    }

    /// No fix: the name, no figures. The route flown, or no route: no leg, the line kept with "—".
    func testTheNextLineWithoutAFixOrALeg() throws {
        let noFix = CompanionNav(flightData: flightData(latitude: nil, longitude: nil), snapshot: try snapshot(plan()))
        let next = try XCTUnwrap(noFix.next)
        XCTAssertNil(next.distanceNM)
        XCTAssertNil(next.bearing)
        XCTAssertNil(next.ete)
        XCTAssertNil(next.turn)
        XCTAssertNil(CompanionNav(flightData: flightData(index: 4), snapshot: try snapshot(plan())).next)
        XCTAssertNil(CompanionNav(flightData: flightData(), snapshot: nil).next)
    }

    /// The iPad's coordinates come as sent: one the phone can't place gives no distance, and no DEST
    /// distance to it either.
    func testATargetThatCannotBePlacedIsNotMeasured() throws {
        var bad = try snapshot(plan(next: 1))
        let lsgc = bad.waypoints[1]
        bad = CompanionFlightPlanSnapshot(
            planId: bad.planId, planName: bad.planName,
            waypoints: bad.waypoints.enumerated().map { index, wp in
                index != 1 ? wp : CompanionWaypoint(id: lsgc.id, name: lsgc.name, latitude: 1e30, longitude: 6.79,
                                                    altitude: nil, frequency: nil, magneticCourse: nil,
                                                    distance: lsgc.distance, plannedGroundSpeed: nil,
                                                    estimatedElapsedTime: lsgc.estimatedElapsedTime, legEETExtra: nil,
                                                    cumulativeEET: nil, estimatedTimeOver: lsgc.estimatedTimeOver,
                                                    actualTimeOver: nil, remarks: "")
            },
            currentWaypointIndex: 1, totalDistance: bad.totalDistance, totalEET: bad.totalEET,
            plannedDepartureTime: bad.plannedDepartureTime, chronometerStartTime: nil)
        let nav = CompanionNav(flightData: flightData(), snapshot: bad)
        XCTAssertNil(nav.next?.distanceNM)
        XCTAssertNil(nav.next?.bearing)
        XCTAssertNil(DestinationInput(snapshot: bad, flightData: flightData(), now: t0).liveDistanceNM)
    }

    // MARK: - The NOW line and RADIO

    func testTheNowLineShowsTheIPadsNowAndNext() {
        let fis = CompanionFrequency(station: "Geneva Info", frequency: "126.350")
        let lsgc = CompanionFrequency(station: "LSGC AFIS", frequency: "120.155")
        XCTAssertEqual(CompanionNowLine.make(flightData: flightData(now: fis, next: lsgc), plan: plan()),
                       .radio(now: fis, next: lsgc))
        XCTAssertEqual(CompanionNowLine.make(flightData: flightData(now: fis), plan: plan()), .radio(now: fis, next: nil),
                       "NEXT unknown: its cell says so, the line stays")
    }

    /// From an iPad that sends neither: today's FREQ, the frequency typed for the waypoint flown to (or the
    /// field diverted to), else GUARD.
    func testFromAnOlderIPadTheNowLineIsTheFreq() throws {
        XCTAssertEqual(CompanionNowLine.make(flightData: flightData(), plan: plan(next: 1)),
                       .freq(station: "LSGC", frequency: "120.155"))
        XCTAssertEqual(CompanionNowLine.make(flightData: flightData(), plan: plan(next: 2)),
                       .freq(station: "GUARD", frequency: "121.50"))
        var diverting = plan(next: 2)
        diverting.diversion = Diversion(ident: "LSGN", name: "Neuchâtel", latitude: 46.9575, longitude: 6.8647,
                                        frequency: "AFIS 121.050", leftRouteAt: 2)
        XCTAssertEqual(CompanionNowLine.make(flightData: flightData(), plan: diverting),
                       .freq(station: "LSGN", frequency: "AFIS 121.050"))
        XCTAssertEqual(CompanionNowLine.make(flightData: nil, plan: nil), .freq(station: "GUARD", frequency: "121.50"))
    }

    /// RADIO: NOW and NEXT tagged, the field diverted to, then the frequencies typed for the waypoints from
    /// the one flown to on (those passed dropped), each once.
    func testRadioListsTheStationsInTheOrderOfUse() {
        let fis = CompanionFrequency(station: "Geneva Info", frequency: "126.350")
        let lsgc = CompanionFrequency(station: "LSGC", frequency: "120.155")
        let items = CompanionRadio.stations(flightData: flightData(now: fis, next: lsgc), plan: plan(next: 1))
        XCTAssertEqual(items.map(\.freq), ["126.350", "120.155", "121.025"])
        XCTAssertEqual(items.map(\.role), [.current, .next, .other])
        XCTAssertFalse(items.contains { $0.isEmergency }, "Emergency is pinned under the list")

        var diverting = plan(next: 2)
        diverting.diversion = Diversion(ident: "LSGN", name: "Neuchâtel", latitude: 46.9575, longitude: 6.8647,
                                        frequency: "AFIS 121.050", leftRouteAt: 2)
        XCTAssertEqual(CompanionRadio.stations(flightData: flightData(), plan: diverting).map(\.station), ["LSGN", "LSZB"])
    }

    // MARK: - MARK

    func testTheSecondSlotIsStartLegThenMark() throws {
        XCTAssertEqual(CompanionMarkState.make(plan: plan(), flightData: flightData(running: false, elapsed: 0)), .startLeg)
        XCTAssertEqual(CompanionMarkState.make(plan: plan(), flightData: flightData()),
                       .mark(waypointIndex: 1, name: "LSGC", legTime: "1:41"))
        XCTAssertEqual(CompanionMarkState.make(plan: plan(), flightData: flightData(running: false, elapsed: 101)),
                       .mark(waypointIndex: 1, name: "LSGC", legTime: "1:41 ‖"), "paused, it says so")
        XCTAssertEqual(CompanionMarkState.make(plan: nil, flightData: flightData()), .unavailable, "no route")
        XCTAssertEqual(CompanionMarkState.make(plan: plan(next: 4), flightData: flightData()), .unavailable, "the route flown")
        var timed = plan()
        timed.waypoints[1].actualTimeOver = t0
        XCTAssertEqual(CompanionMarkState.make(plan: timed, flightData: flightData()), .unavailable, "already timed")
    }

    // MARK: - Fixed layout

    /// The read band keeps one height whatever it shows: no route, a route, diverting, no fix, a long
    /// name, 9.9 → 10.0 NM and 59 → 60 min, an older iPad's FREQ, a long station. The page under it never
    /// moves. (Fails with the old strip, which only sat at the bottom, and a NOW line that took the
    /// station's lines.)
    func testTheReadBandKeepsItsHeight() throws {
        let fis = CompanionFrequency(station: "Bern Information", frequency: "119.175 Bern Information")
        let lsgc = CompanionFrequency(station: "LSGC AFIS", frequency: "120.155")
        var long = plan(next: 1)
        long.waypoints[1].name = "SAIGNELÉGIER"
        var diverting = plan(next: 2)
        diverting.diversion = Diversion(ident: "LSGN", name: "Neuchâtel", latitude: 46.9575, longitude: 6.8647,
                                        leftRouteAt: 2)
        // Due north of LSGC, `nm` from it, at `kt`: 9.9 and 10.0 NM at 100 kt; 59 min and 1:00 h at 30 kt.
        func near(_ nm: Double, _ kt: Double) -> CompanionFlightData {
            flightData(latitude: 47.0839 + nm / 60, longitude: 6.7928, speedMPS: kt / CompanionNav.knotsPerMetrePerSecond,
                       now: fis, next: lsgc)
        }
        let states: [(String, CompanionFlightData?, FlightPlan?)] = [
            ("no route", flightData(), nil),
            ("route, NOW and NEXT", flightData(now: fis, next: lsgc), plan()),
            ("route, an older iPad", flightData(), plan()),
            ("diverting", flightData(now: lsgc), diverting),
            ("no fix", flightData(latitude: nil, longitude: nil, speedMPS: nil, now: fis, next: lsgc), plan()),
            ("long name", flightData(now: fis, next: lsgc), long),
            ("9.9 NM", near(9.9, 100), plan()),
            ("10.0 NM", near(10.05, 100), plan()),
            ("59 min", near(29.4, 30), plan()),
            ("1:00 h", near(30.1, 30), plan()),
            ("the route flown", flightData(index: 4, now: fis), plan()),
        ]
        var heights: [String: CGFloat] = [:]
        for (name, data, route) in states {
            let snap = try route.map(snapshot)
            let band = CompanionReadBand(flightData: data, nav: CompanionNav(flightData: data, snapshot: snap), onShowNav: {})
            heights[name] = Self.height(of: band, width: 402)
        }
        let first = try XCTUnwrap(heights["no route"])
        XCTAssertGreaterThan(first, 0)
        for (name, height) in heights {
            XCTAssertEqual(height, first, accuracy: 0.5, "\(name): \(height) against \(first)")
        }
    }

    /// The act band's four frames come from the width alone: START LEG or MARK, a slot from the iPad or
    /// none, Divert offered or not, they never move. At the device's measures, where the slots' faces
    /// (set at the device's sizes) fit: on the iPad the tests run on, an iPad's width.
    func testTheActBandKeepsItsFrames() throws {
        let manager = CompanionConnectivityManager(defaults: makeTestDefaults(), usesWiFiAware: false)
        let slot = CheckSlot(phase: .cruise, line: .items(2), icon: .list, tone: .due, action: .showChecklist)
        var frames: [String: [Int: CGRect]] = [:]
        let states: [(String, CompanionFlightData, FlightPlan?, CheckSlot?, Bool)] = [
            ("START LEG, a slot, Divert", flightData(running: false, elapsed: 0), plan(), slot, true),
            ("MARK, no slot, no Divert", flightData(), plan(), nil, false),
            ("no route", flightData(), nil, slot, false),
        ]
        for (name, data, route, checkSlot, divert) in states {
            var snap = try route.map(snapshot)
            if let current = snap { snap = Self.withDivert(current, divert) }
            var placed: [Int: CGRect] = [:]
            let band = CompanionActBand(nav: CompanionNav(flightData: data, snapshot: snap), flightData: data,
                                        snapshot: snap, checkSlot: checkSlot, onCheckSlot: { _ in },
                                        onPlace: { placed[$0] = $1 })
            Self.render(band.environmentObject(manager), size: CGSize(width: 820, height: 160))
            XCTAssertEqual(placed.count, 4, name)
            frames[name] = placed
        }
        let first = try XCTUnwrap(frames["START LEG, a slot, Divert"])
        for (name, placed) in frames {
            for index in 0..<4 {
                let a = try XCTUnwrap(placed[index]), b = try XCTUnwrap(first[index])
                XCTAssertEqual(a.minX, b.minX, accuracy: 0.5, "\(name) slot \(index + 1)")
                XCTAssertEqual(a.width, b.width, accuracy: 0.5, "\(name) slot \(index + 1)")
                XCTAssertEqual(a.height, b.height, accuracy: 0.5, "\(name) slot \(index + 1)")
            }
        }
        // MARK where RECORD ATO was a wide button, the slot left of it as on the phone Cockpit.
        XCTAssertLessThan(try XCTUnwrap(first[0]).minX, try XCTUnwrap(first[1]).minX)
        XCTAssertEqual(try XCTUnwrap(first[1]).height, CockpitTarget.thumb, accuracy: 0.5, "the thumb bar's height")
    }

    // MARK: - Helpers

    private static func withDivert(_ snap: CompanionFlightPlanSnapshot, _ supports: Bool) -> CompanionFlightPlanSnapshot {
        CompanionFlightPlanSnapshot(planId: snap.planId, planName: snap.planName, waypoints: snap.waypoints,
                                    currentWaypointIndex: snap.currentWaypointIndex, totalDistance: snap.totalDistance,
                                    totalEET: snap.totalEET, plannedDepartureTime: snap.plannedDepartureTime,
                                    chronometerStartTime: snap.chronometerStartTime, diversion: snap.diversion,
                                    supportsDivert: supports)
    }

    /// The height `view` takes at `width`, in the day theme.
    private static func height<V: View>(of view: V, width: CGFloat) -> CGFloat {
        let host = UIHostingController(rootView: view.environment(\.cockpitTheme, CockpitTheme.resolve(.day)))
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    private static func render<V: View>(_ view: V, size: CGSize) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
            .environment(\.cockpitTheme, CockpitTheme.resolve(.day)))
        renderer.proposedSize = ProposedViewSize(size)
        _ = renderer.uiImage
    }
}

/// Two DEST lines alike to within a float's last bits: one from the iPad's own fix, one from the figures
/// it streamed (its altitude sent in feet, back in metres on the phone).
func assertSameDestination(_ a: DestinationEstimate, _ b: DestinationEstimate, _ message: String = "",
                           file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.kind, b.kind, message, file: file, line: line)
    XCTAssertEqual(a.ident, b.ident, message, file: file, line: line)
    XCTAssertEqual(a.nextIdent, b.nextIdent, message, file: file, line: line)
    XCTAssertEqual(a.remainingNM ?? -1, b.remainingNM ?? -1, accuracy: 1e-6, message, file: file, line: line)
    XCTAssertEqual(a.ete ?? -1, b.ete ?? -1, accuracy: 1e-3, message, file: file, line: line)
    XCTAssertEqual(a.eta?.timeIntervalSinceReferenceDate ?? -1, b.eta?.timeIntervalSinceReferenceDate ?? -1,
                   accuracy: 1e-3, message, file: file, line: line)
    XCTAssertEqual(a.plannedETO, b.plannedETO, message, file: file, line: line)
    XCTAssertEqual(a.plannedDestinationETO, b.plannedDestinationETO, message, file: file, line: line)
    XCTAssertEqual(a.delta, b.delta, message, file: file, line: line)
    XCTAssertEqual(a.track?.notches, b.track?.notches, message, file: file, line: line)
    XCTAssertEqual(a.track?.nextIndex, b.track?.nextIndex, message, file: file, line: line)
    XCTAssertEqual(a.track?.flown ?? -1, b.track?.flown ?? -1, accuracy: 1e-9, message, file: file, line: line)
}
