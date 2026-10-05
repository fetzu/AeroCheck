import CoreLocation
import XCTest
@testable import AeroCheck

/// NOW, NEXT and every frequency on the way (6.2: out of the map, `PhaseFrequencyPlanner`), and the
/// Cockpit's one source of them (`CockpitRadio`). The first half pins the rules the map applied until
/// 6.2, unchanged by the move: Plan › Map's panel and the map's NOW | NEXT come from them. The second
/// half is ROUTE's RADIO, every frequency in the order of use (the plan's Q6).
@MainActor
final class PhaseFrequencyPlannerTests: XCTestCase {

    // MARK: - NOW and NEXT, as the map had them

    func testNearAFieldNowIsItsContactNotItsATIS() {
        let plan = PhaseFrequencyPlanner.plan(position: Self.nearGrenchen, plan: nil, sources: Self.world.sources)
        XCTAssertEqual(plan.current, .init(station: "LSZG TWR", freq: "120.100"))
    }

    func testEnRouteNowIsTheAreasInfo() {
        // 13 NM from Grenchen, 15 from Les Eplatures: west of 7.45° E, Geneva's side.
        let plan = PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: nil, sources: Self.world.sources)
        XCTAssertEqual(plan.current, .init(station: "Geneva Info", freq: "126.350"))
    }

    func testAFieldWithoutFrequenciesIsPassedOver() {
        var world = Self.world
        world.fields["LSXX"] = .init(coordinate: .init(latitude: 47.172, longitude: 7.402), frequencies: [])
        let plan = PhaseFrequencyPlanner.plan(position: Self.nearGrenchen, plan: nil, sources: world.sources)
        XCTAssertEqual(plan.current?.station, "LSZG TWR", "the strip with no frequency is not NOW")
    }

    func testNextIsTheNextFieldOfTheRoute() {
        // Grenchen, E, Les Eplatures, Bressaucourt, flying to E: the next field after it.
        let toE = PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: Self.route(next: 1), sources: Self.world.sources)
        XCTAssertEqual(toE.next, .init(station: "LSGC AFIS", freq: "120.350"))
        // Flying to Les Eplatures, more than 10 NM out: Les Eplatures itself. Until 6.2 the field flown
        // to was passed over and NEXT already read Bressaucourt.
        let toLSGC = PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: Self.route(next: 2), sources: Self.world.sources)
        XCTAssertEqual(toLSGC.current, .init(station: "Geneva Info", freq: "126.350"))
        XCTAssertEqual(toLSGC.next, .init(station: "LSGC AFIS", freq: "120.350"))
    }

    func testOnceTheFieldFlownToIsNowNextIsTheFieldAfterIt() {
        // Within 10 NM of Les Eplatures, still flying to it: it is NOW, Bressaucourt NEXT.
        let plan = PhaseFrequencyPlanner.plan(position: Self.nearLesEplatures, plan: Self.route(next: 2),
                                              sources: Self.world.sources)
        XCTAssertEqual(plan.current, .init(station: "LSGC AFIS", freq: "120.350"))
        XCTAssertEqual(plan.next, .init(station: "LSZQ A/G", freq: "123.575"))
    }

    func testOnTheLastLegTheDestinationIsNextUntilItIsNow() {
        let lastLeg = Self.route(next: 3)
        XCTAssertEqual(PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: lastLeg, sources: Self.world.sources).next,
                       .init(station: "LSZQ A/G", freq: "123.575"))
        // Within its 10 NM: NOW, and NEXT the area's Info as before (no CTR around), never the field twice.
        let near = PhaseFrequencyPlanner.plan(position: Self.nearBressaucourt, plan: lastLeg, sources: Self.world.sources)
        XCTAssertEqual(near.current, .init(station: "LSZQ A/G", freq: "123.575"))
        XCTAssertNotEqual(near.next, near.current)
    }

    func testDivertingNextIsTheFieldDivertedTo() {
        var route = Self.route(next: 2)
        route.diversion = Self.diversion("LSZQ")
        let plan = PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: route, sources: Self.world.sources)
        XCTAssertEqual(plan.next, .init(station: "LSZQ A/G", freq: "123.575"))
    }

    func testWithoutAFieldAheadNextIsTheNearestCTRThenTheHandOff() {
        var world = Self.world
        world.ctrs = [(station: "BERN", frequency: "121.025")]
        XCTAssertEqual(PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: nil, sources: world.sources).next,
                       .init(station: "BERN", freq: "121.025"))
        // No CTR: en route the nearest field is next; at a field, the area's Info.
        XCTAssertEqual(PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: nil, sources: Self.world.sources).next?.station,
                       "LSZG TWR")
        XCTAssertEqual(PhaseFrequencyPlanner.plan(position: Self.nearGrenchen, plan: nil, sources: Self.world.sources).next?.station,
                       "Zurich Info")
    }

    func testACTRWithoutAFrequencyIsNotNext() {
        var world = Self.world
        world.ctrs = [(station: "BERN", frequency: nil), (station: "PAYERNE", frequency: "119.075")]
        let plan = PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: nil, sources: world.sources)
        XCTAssertEqual(plan.next?.station, "LSZG TWR", "the nearest CTR has no frequency: the hand-off, as before")
    }

    func testWithoutAFixThePlansOrder() {
        let plan = PhaseFrequencyPlanner.plan(position: nil, plan: Self.route(next: 0), sources: Self.world.sources)
        XCTAssertEqual(plan.current, .init(station: "LSZG TWR", freq: "120.100"))
        XCTAssertEqual(plan.next, .init(station: "LSGC AFIS", freq: "120.350"), "E has none: the next field")
    }

    func testWithoutTheAirportDatabaseTheFrequenciesTyped() {
        var world = Self.world
        world.hasAirportData = false
        var route = Self.route(next: 0)
        route.waypoints[1].frequency = "Bern Info 119.175"
        let plan = PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: route, sources: world.sources)
        XCTAssertNil(plan.current, "the departure's frequency comes from the database")
        XCTAssertEqual(plan.next, .init(station: "E", freq: "Bern Info 119.175"))
    }

    func testNextIsDroppedWhenItIsNow() {
        // Circuits at Grenchen: the field ahead is the field.
        let circuit = FlightPlan(name: "Circuits", waypoints: [Self.waypoint("LSZG"), Self.waypoint("LSZG")])
        let plan = PhaseFrequencyPlanner.plan(position: Self.nearGrenchen, plan: circuit, sources: Self.world.sources)
        XCTAssertEqual(plan.current?.station, "LSZG TWR")
        XCTAssertNil(plan.next)
    }

    func testThePanelListsEachStationOnceEmergencyLast() {
        var world = Self.world
        world.ctrs = [(station: "GRENCHEN", frequency: "120.100"), (station: "BERN", frequency: "121.025")]
        let panel = PhaseFrequencyPlanner.plan(position: Self.nearGrenchen, plan: Self.route(next: 0),
                                               sources: world.sources).panel
        let keys = panel.map { "\($0.station)|\($0.freq)" }
        XCTAssertEqual(keys.count, Set(keys).count, "no repeats: \(keys)")
        XCTAssertEqual(panel.first?.role, .current)
        XCTAssertEqual(panel.last?.station, L10n.Nav.freqEmergency)
        XCTAssertEqual(panel.last?.freq, "121.500")
        XCTAssertEqual(panel.filter(\.isEmergency).count, 1)
        // As before: NOW, NEXT, the field's set, the route's, the area's, the CTRs.
        XCTAssertEqual(Array(keys.prefix(3)), ["LSZG TWR|120.100", "LSGC AFIS|120.350", "LSZG ATIS|125.950"])
        XCTAssertTrue(keys.contains("LSZQ A/G|123.575"), "every field of the route, ahead or not")
        XCTAssertTrue(keys.contains("BERN|121.025"))
        XCTAssertTrue(panel.dropFirst(2).filter { !$0.isEmergency }.allSatisfy { $0.role == .other })
    }

    // MARK: - ROUTE's RADIO, in the order of use

    func testRouteRadioIsInTheOrderOfUse() {
        var world = Self.world
        world.ctrs = [(station: "BERN", frequency: "121.025")]
        let route = PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: Self.route(next: 1),
                                               sources: world.sources).route
        XCTAssertEqual(route.map { "\($0.station)|\($0.freq)" }, [
            "Geneva Info|126.350",          // NOW
            "LSGC AFIS|120.350",            // NEXT
            "LSZQ A/G|123.575",             // the route on from the waypoint flown to (E has none)
            "FIS West|119.175",             // the area
            "BERN|121.025",                 // the CTRs around
            "\(L10n.Nav.freqEmergency)|121.500",
        ])
        XCTAssertEqual(route.map(\.role), [.current, .next, .other, .other, .other, .emergency])
    }

    func testRouteRadioDropsTheFieldsPassed() {
        let route = PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: Self.route(next: 1),
                                               sources: Self.world.sources).route
        XCTAssertFalse(route.contains { $0.station.hasPrefix("LSZG") }, "Grenchen is behind: \(route.map(\.station))")
    }

    func testAtTheFieldItsATISFollowsNow() {
        // Circuits at Grenchen, no route: the field's ATIS right after NOW and NEXT.
        let route = PhaseFrequencyPlanner.plan(position: Self.nearGrenchen, plan: nil, sources: Self.world.sources).route
        XCTAssertEqual(Array(route.map(\.station).prefix(3)), ["LSZG TWR", "Zurich Info", "LSZG ATIS"])
    }

    func testDivertingTheFieldsATISComesBeforeTheRoute() {
        var plan = Self.route(next: 2)
        plan.diversion = Self.diversion("LSZQ")
        var world = Self.world
        world.fields["LSZQ"]?.frequencies.insert((type: "ATIS", frequency: "128.025"), at: 0)
        let route = PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: plan, sources: world.sources).route
        XCTAssertEqual(Array(route.map(\.station).prefix(3)), ["Geneva Info", "LSZQ A/G", "LSZQ ATIS"])
    }

    func testTheRouteFlownLeavesNoRouteStations() {
        let route = PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: Self.route(next: 4),
                                               sources: Self.world.sources).route
        XCTAssertFalse(route.contains { $0.station.hasPrefix("LSGC") || $0.station.hasPrefix("LSZQ") && $0.role == .other })
        XCTAssertEqual(route.last?.isEmergency, true)
    }

    /// On the ground in the Engadine with a Jura route: the aircraft's area (Zurich's), then the route's
    /// (Geneva's), which RADIO left out (device check, 5 Oct: LSZQ to LSGE from Tinizong).
    func testRouteRadioListsTheAreasOfTheRouteNotOnlyTheAircrafts() {
        let tinizong = CLLocationCoordinate2D(latitude: 46.582, longitude: 9.616)
        let route = PhaseFrequencyPlanner.plan(position: tinizong, plan: Self.route(next: 0),
                                               sources: Self.world.sources).route
        let stations = route.map(\.station)
        XCTAssertEqual(stations.first, "Zurich Info", "NOW: the aircraft's area")
        let zurich = try? XCTUnwrap(stations.firstIndex(of: "FIS East"))
        let geneva = try? XCTUnwrap(stations.firstIndex(of: "Geneva Info"))
        XCTAssertNotNil(geneva, "the route's area: \(stations)")
        XCTAssertTrue(stations.contains("FIS West"), "\(stations)")
        if let zurich, let geneva { XCTAssertLessThan(zurich, geneva, "the aircraft's area first, then the way's") }
    }

    /// Flying east out of Geneva's area: Zurich's Info and FIS come after Geneva's, in the order of use.
    func testRouteRadioListsTheNextAreaInTheOrderItComes() {
        var plan = FlightPlan(name: "East", waypoints: [Self.waypoint("LSGC"),
                                                        FlightPlanWaypoint(name: "LSZH", coordinate: .init(latitude: 47.4647, longitude: 8.5492))])
        plan.currentWaypointIndex = 1
        let route = PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: plan, sources: Self.world.sources).route
        let areas = route.map(\.station).filter { ["Geneva Info", "FIS West", "Zurich Info", "FIS East"].contains($0) }
        XCTAssertEqual(areas, ["Geneva Info", "FIS West", "Zurich Info", "FIS East"])
    }

    /// Diverting: the way is to the field diverted to, not along the route left.
    func testDivertingTheAreasAreThoseOnTheWayToTheField() {
        var plan = Self.route(next: 2)
        plan.diversion = Diversion(ident: "LSZH", name: "Zurich", latitude: 47.4647, longitude: 8.5492, leftRouteAt: 2)
        let route = PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: plan, sources: Self.world.sources).route
        XCTAssertTrue(route.contains { $0.station == "Zurich Info" }, "\(route.map(\.station))")
    }

    /// The way is walked every 5 NM at most, the leg's end included.
    func testTheWayIsWalkedEveryFiveMiles() {
        let start = CLLocationCoordinate2D(latitude: 47.0, longitude: 7.0)
        let end = CLLocationCoordinate2D(latitude: 47.0, longitude: 7.5)          // about 20 NM
        let steps = PhaseFrequencyPlanner.steps(from: start, to: end)
        XCTAssertEqual(steps.count, 5)
        XCTAssertEqual(steps.last?.longitude ?? 0, 7.5, accuracy: 1e-9)
        XCTAssertEqual(PhaseFrequencyPlanner.steps(from: start, to: start).count, 1, "a leg of nothing: its end")
    }

    // MARK: - The Cockpit's radio

    func testTheRadioComputesAgainOnceTheAircraftMovedAHundredthOfADegree() {
        let radio = CockpitRadio()
        radio.publish = { _ in }
        let sources = Self.world.sources
        radio.update(position: Self.enRoute, plan: nil, sources: sources)
        XCTAssertEqual(radio.computations, 1)
        radio.noteMove(to: Self.moved(Self.enRoute, by: 0.009), plan: nil, sources: sources)
        XCTAssertEqual(radio.computations, 1, "under 0.01°: the lists stay")
        radio.noteMove(to: Self.moved(Self.enRoute, by: 0.011), plan: nil, sources: sources)
        XCTAssertEqual(radio.computations, 2)
        radio.noteMove(to: nil, plan: nil, sources: sources)
        XCTAssertEqual(radio.computations, 3, "the fix lost: the plan's order")
        radio.noteMove(to: nil, plan: nil, sources: sources)
        XCTAssertEqual(radio.computations, 3)
    }

    func testTheRadioSplitsNowNextAndEmergency() {
        let radio = CockpitRadio()
        radio.publish = { _ in }
        radio.update(position: Self.enRoute, plan: Self.route(next: 1), sources: Self.world.sources)
        XCTAssertEqual(radio.now?.station, "Geneva Info")
        XCTAssertEqual(radio.next?.station, "LSGC AFIS")
        XCTAssertEqual(radio.stations.first?.station, "Geneva Info")
        XCTAssertFalse(radio.stations.contains(where: \.isEmergency))
        XCTAssertEqual(radio.emergency.map(\.freq), ["121.500"])
    }

    func testTheWatchHearsOfANewListOnly() {
        let radio = CockpitRadio()
        var sent: [[FrequencyInfo]] = []
        radio.publish = { sent.append($0.map(\.watchInfo)) }
        radio.update(position: Self.enRoute, plan: nil, sources: Self.world.sources)
        radio.update(position: Self.enRoute, plan: nil, sources: Self.world.sources)
        XCTAssertEqual(sent.count, 1, "the same list is not sent twice")
        radio.update(position: Self.nearGrenchen, plan: nil, sources: Self.world.sources)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.last?.first?.name, "LSZG TWR")
        XCTAssertEqual(sent.last?.first?.role, .now)
        XCTAssertEqual(sent.last?.last?.role, .emergency)
    }

    func testAMoveIsAHundredthOfADegreeEitherWay() {
        let here = CLLocationCoordinate2D(latitude: 47, longitude: 7)
        XCTAssertFalse(CockpitRadio.movedSignificantly(from: here, to: here))
        XCTAssertTrue(CockpitRadio.movedSignificantly(from: here, to: .init(latitude: 47, longitude: 7.01)))
        XCTAssertTrue(CockpitRadio.movedSignificantly(from: here, to: .init(latitude: 46.99, longitude: 7)))
        XCTAssertTrue(CockpitRadio.movedSignificantly(from: nil, to: here))
        XCTAssertFalse(CockpitRadio.movedSignificantly(from: nil, to: nil))
    }

    // MARK: - Fixtures

    /// A Jura corner of Switzerland: Grenchen (towered, with an ATIS), Les Eplatures (AFIS), Bressaucourt
    /// (A/G). Frequencies as the airport database writes them.
    private struct World {
        struct Field {
            var coordinate: CLLocationCoordinate2D
            var frequencies: [(type: String, frequency: String)]
        }

        var fields: [String: Field]
        var ctrs: [(station: String, frequency: String?)] = []
        var hasAirportData = true

        var sources: PhaseFrequencyPlanner.Sources {
            let fields = self.fields
            let ctrs = self.ctrs
            return PhaseFrequencyPlanner.Sources(
                hasAirportData: hasAirportData,
                nearestFields: { point in
                    let here = CLLocation(latitude: point.latitude, longitude: point.longitude)
                    return fields
                        .map { (ident: $0.key, coordinate: $0.value.coordinate,
                                distance: here.distance(from: CLLocation(latitude: $0.value.coordinate.latitude,
                                                                         longitude: $0.value.coordinate.longitude)) / 1852) }
                        .filter { $0.distance <= PhaseFrequencyPlanner.nearestFieldRadiusNM }
                        .sorted { $0.distance < $1.distance }
                        .prefix(PhaseFrequencyPlanner.nearestFieldLimit)
                        .map { PhaseFrequencyPlanner.Field(ident: $0.ident, coordinate: $0.coordinate) }
                },
                fieldFrequencies: { ident in fields[ident.uppercased()]?.frequencies ?? [] },
                nearbyCTRs: { _ in ctrs })
        }
    }

    private static let world = World(fields: [
        "LSZG": .init(coordinate: .init(latitude: 47.1816, longitude: 7.4172),
                      frequencies: [(type: "GND", frequency: "121.825"), (type: "ATIS", frequency: "125.950"),
                                    (type: "TWR", frequency: "120.100")]),
        "LSGC": .init(coordinate: .init(latitude: 47.0839, longitude: 6.7929),
                      frequencies: [(type: "AFIS", frequency: "120.350")]),
        "LSZQ": .init(coordinate: .init(latitude: 47.3923, longitude: 7.0296),
                      frequencies: [(type: "A/G", frequency: "123.575")]),
    ])

    /// About a mile from Grenchen, east of 7.45° E: Zurich's side.
    private static let nearGrenchen = CLLocationCoordinate2D(latitude: 47.170, longitude: 7.460)
    /// Between Grenchen and Les Eplatures, more than 10 NM from either, Geneva's side.
    private static let enRoute = CLLocationCoordinate2D(latitude: 47.05, longitude: 7.15)
    /// About 4 NM east of Les Eplatures.
    private static let nearLesEplatures = CLLocationCoordinate2D(latitude: 47.10, longitude: 6.88)
    /// About 3 NM south of Bressaucourt.
    private static let nearBressaucourt = CLLocationCoordinate2D(latitude: 47.34, longitude: 7.03)

    private static func moved(_ point: CLLocationCoordinate2D, by degrees: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.latitude + degrees, longitude: point.longitude)
    }

    private static func waypoint(_ name: String) -> FlightPlanWaypoint {
        FlightPlanWaypoint(name: name, coordinate: world.fields[name]?.coordinate
                           ?? CLLocationCoordinate2D(latitude: 47.13, longitude: 7.10))
    }

    /// Grenchen, E (a reporting point), Les Eplatures, Bressaucourt; `next` the waypoint flown to.
    private static func route(next: Int) -> FlightPlan {
        var plan = FlightPlan(name: "Jura", waypoints: ["LSZG", "E", "LSGC", "LSZQ"].map(waypoint))
        plan.currentWaypointIndex = next
        return plan
    }

    private static func diversion(_ ident: String) -> Diversion {
        let field = world.fields[ident]!
        return Diversion(ident: ident, name: ident, latitude: field.coordinate.latitude,
                         longitude: field.coordinate.longitude, leftRouteAt: 2)
    }
}
