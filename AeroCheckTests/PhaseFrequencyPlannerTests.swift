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
        // Within its 10 NM: NOW, and nothing NEXT at the route's end (6.4.0), never the field twice.
        let near = PhaseFrequencyPlanner.plan(position: Self.nearBressaucourt, plan: lastLeg, sources: Self.world.sources)
        XCTAssertEqual(near.current, .init(station: "LSZQ A/G", freq: "123.575"))
        XCTAssertNil(near.next)
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
                       "Zürich Info")
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

    /// A local flight from Bressaucourt and back, out of its circuit (the author's dry run checks, st-12, and
    /// 17 Oct): the field is NOW; NEXT is the area's Info, before any CTR around that the route doesn't enter.
    func testALocalFlightOutOfTheCircuitHasTheCTROrTheInfoNext() {
        var local = FlightPlan(name: "Triangle", waypoints: [
            Self.waypoint("LSZQ"),
            FlightPlanWaypoint(name: "TP1", coordinate: .init(latitude: 47.42, longitude: 7.17)),
            FlightPlanWaypoint(name: "TP2", coordinate: .init(latitude: 47.33, longitude: 7.12)),
            Self.waypoint("LSZQ")])
        local.currentWaypointIndex = 1
        let plan = PhaseFrequencyPlanner.plan(position: Self.nearBressaucourt, plan: local, sources: Self.world.sources)
        XCTAssertEqual(plan.current, .init(station: "LSZQ A/G", freq: "123.575"))
        XCTAssertEqual(plan.next, .init(station: "Zürich Info", freq: "124.700"), "the Swiss split's, at Bressaucourt")
        var world = Self.world
        world.ctrs = [(station: "GRENCHEN", frequency: "120.100")]
        XCTAssertEqual(PhaseFrequencyPlanner.plan(position: Self.nearBressaucourt, plan: local, sources: world.sources).next?.station,
                       "Zürich Info", "the area's Info, not a CTR the route doesn't enter")
        world.fisSectors = { _ in [.init(station: "BALE INFORMATION", freq: "130.900")] }
        XCTAssertEqual(PhaseFrequencyPlanner.plan(position: Self.nearBressaucourt, plan: local, sources: world.sources).next,
                       .init(station: "BALE INFORMATION", freq: "130.900"), "the data's sector at Bressaucourt: Bâle")
    }

    /// Back at the route's end, the field is NOW and nothing is NEXT: no CTR around (on final at Bressaucourt,
    /// NEXT read Les Eplatures, 20 NM off; 6.4.0, the fifth dry run checks).
    func testAtTheRoutesEndNothingIsNext() {
        var local = FlightPlan(name: "Triangle", waypoints: [
            Self.waypoint("LSZQ"),
            FlightPlanWaypoint(name: "TP1", coordinate: .init(latitude: 47.42, longitude: 7.17)),
            FlightPlanWaypoint(name: "TP2", coordinate: .init(latitude: 47.33, longitude: 7.12)),
            Self.waypoint("LSZQ")])
        local.currentWaypointIndex = 3
        var world = Self.world
        world.ctrs = [(station: "LES EPLATURES", frequency: "118.125")]
        let plan = PhaseFrequencyPlanner.plan(position: Self.nearBressaucourt, plan: local, sources: world.sources)
        XCTAssertEqual(plan.current, .init(station: "LSZQ A/G", freq: "123.575"))
        XCTAssertNil(plan.next)
    }

    // MARK: Arriving: rule A (6.4.1)

    /// LSZQ → LSZS through the Engadine's reporting points, as flown on 23 Sep.
    private static let samedan = CLLocationCoordinate2D(latitude: 46.5344, longitude: 9.8839)
    private static var engadine: World {
        var world = Self.world
        world.fields["LSZS"] = .init(coordinate: samedan, frequencies: [(type: "TWR", frequency: "135.325")])
        return world
    }
    private static func toSamedan(next: Int) -> FlightPlan {
        var plan = FlightPlan(name: "Samedan", waypoints: [
            waypoint("LSZQ"),
            FlightPlanWaypoint(name: "JULIER", coordinate: .init(latitude: 46.472, longitude: 9.729)),
            FlightPlanWaypoint(name: "SILVAPLANA", coordinate: .init(latitude: 46.461, longitude: 9.794)),
            FlightPlanWaypoint(name: "LSZS", coordinate: samedan)])
        plan.currentWaypointIndex = next
        return plan
    }
    /// About 8 NM west of Samedan, short of the Julier.
    private static let westOfJulier = CLLocationCoordinate2D(latitude: 46.48, longitude: 9.69)

    /// 8 NM out from Samedan, Julier and Silvaplana still ahead (both beyond its circuit): Samedan's tower is
    /// NOW, and nothing is NEXT. Until 6.4.1 NEXT read Zürich Info, the FIS the flight had just left.
    func testArrivingWithPointsAheadInTheFieldsZoneHasNothingNext() {
        let plan = PhaseFrequencyPlanner.plan(position: Self.westOfJulier, plan: Self.toSamedan(next: 1),
                                              sources: Self.engadine.sources)
        XCTAssertEqual(plan.current, .init(station: "LSZS TWR", freq: "135.325"))
        XCTAssertNil(plan.next)
    }

    /// Landed at Samedan, the route flown (`followLanding` takes the index past the last waypoint): the tower is
    /// NOW, nothing NEXT. Until 6.4.1, Zürich Info.
    func testLandedAtTheRoutesEndHasNothingNext() {
        let plan = PhaseFrequencyPlanner.plan(position: Self.samedan, plan: Self.toSamedan(next: 4),
                                              sources: Self.engadine.sources)
        XCTAssertEqual(plan.current, .init(station: "LSZS TWR", freq: "135.325"))
        XCTAssertNil(plan.next)
    }

    /// The route flown and the aircraft beyond the destination's 10 NM: a flight with no route's rules, the
    /// area's FIS NOW and the hand-off to the field NEXT.
    func testTheRouteFlownBeyondTenMilesFollowsTheNoRouteRules() {
        let away = CLLocationCoordinate2D(latitude: 46.75, longitude: 9.88)    // ~13 NM north of Samedan
        let plan = PhaseFrequencyPlanner.plan(position: away, plan: Self.toSamedan(next: 4),
                                              sources: Self.engadine.sources)
        XCTAssertEqual(plan.current?.station, "Zürich Info")
        XCTAssertEqual(plan.next, .init(station: "LSZS TWR", freq: "135.325"))
    }

    /// A local flight's leg back (rule A holds for round trips): after the first turn point outside the circuit,
    /// Bressaucourt is NOW and nothing is NEXT, though TP2 is still ahead; on the way out, the area's Info.
    func testALocalFlightsLegBackHasNothingNext() {
        var local = FlightPlan(name: "Triangle", waypoints: [
            Self.waypoint("LSZQ"),
            FlightPlanWaypoint(name: "TP1", coordinate: .init(latitude: 47.42, longitude: 7.17)),
            FlightPlanWaypoint(name: "TP2", coordinate: .init(latitude: 47.33, longitude: 7.12)),
            Self.waypoint("LSZQ")])
        local.currentWaypointIndex = 1
        XCTAssertEqual(PhaseFrequencyPlanner.plan(position: Self.nearBressaucourt, plan: local, sources: Self.world.sources).next,
                       .init(station: "Zürich Info", freq: "124.700"), "out to TP1: the area's Info")
        local.currentWaypointIndex = 2
        let back = PhaseFrequencyPlanner.plan(position: Self.nearBressaucourt, plan: local, sources: Self.world.sources)
        XCTAssertEqual(back.current, .init(station: "LSZQ A/G", freq: "123.575"))
        XCTAssertNil(back.next, "TP1 flown, outside the circuit: coming home")
    }

    // MARK: One frequency, one station (6.4.1)

    /// A route as the builder writes it: each aerodrome's waypoint carries its contact frequency, named with the
    /// bare ident (`RoutePoint.apply`).
    private static func asBuilt(_ plan: FlightPlan, _ world: World) -> FlightPlan {
        var built = plan
        for i in built.waypoints.indices {
            guard let field = world.fields[built.waypoints[i].name],
                  let contact = PhaseFrequencyPlanner.fieldFrequencies(field.frequencies).last else { continue }
            built.waypoints[i].frequency = contact.frequency
        }
        return built
    }

    /// The author's dr-3: NOW "LSZQ AFIS" and NEXT "LSZQ" on one frequency, because the waypoint's copy of the
    /// contact had another name. One frequency is one station: never NOW and NEXT at once, and the arriving rule
    /// works on a route built in the app.
    func testOneFrequencyIsNeverNowAndNext() {
        let world = Self.engadine
        let arriving = PhaseFrequencyPlanner.plan(position: Self.westOfJulier,
                                                  plan: Self.asBuilt(Self.toSamedan(next: 1), world), sources: world.sources)
        XCTAssertEqual(arriving.current, .init(station: "LSZS TWR", freq: "135.325"))
        XCTAssertNil(arriving.next, "the waypoint's 135.325 is the tower NOW names")

        var local = FlightPlan(name: "Triangle", waypoints: [
            Self.waypoint("LSZQ"),
            FlightPlanWaypoint(name: "TP1", coordinate: .init(latitude: 47.42, longitude: 7.17)),
            FlightPlanWaypoint(name: "TP2", coordinate: .init(latitude: 47.33, longitude: 7.12)),
            Self.waypoint("LSZQ")])
        local = Self.asBuilt(local, Self.world)
        local.currentWaypointIndex = 1
        XCTAssertEqual(PhaseFrequencyPlanner.plan(position: Self.nearBressaucourt, plan: local, sources: Self.world.sources).next,
                       .init(station: "Zürich Info", freq: "124.700"), "out to TP1: the area's Info")
        local.currentWaypointIndex = 2
        XCTAssertNil(PhaseFrequencyPlanner.plan(position: Self.nearBressaucourt, plan: local, sources: Self.world.sources).next,
                     "coming home")
        local.currentWaypointIndex = 3
        XCTAssertNil(PhaseFrequencyPlanner.plan(position: Self.nearBressaucourt, plan: local, sources: Self.world.sources).next)

        // Still the next field while it isn't NOW, under the database's name.
        let toLSGC = PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: Self.asBuilt(Self.route(next: 2), Self.world),
                                                sources: Self.world.sources)
        XCTAssertEqual(toLSGC.next, .init(station: "LSGC AFIS", freq: "120.350"))
    }

    /// 122.055 is the 8.33 kHz name of 122.050: one station for NOW and NEXT. (6.4.2)
    func testAnEightThirtyThreeChannelNameIsTheSameStation() {
        XCTAssertTrue(PhaseFrequencyPlanner.Entry(station: "LSZQ AFIS", freq: "122.050")
            .isSameStation(as: .init(station: "LSZQ AD", freq: "122.055")))
        XCTAssertFalse(PhaseFrequencyPlanner.Entry(station: "A", freq: "118.125")
            .isSameStation(as: .init(station: "B", freq: "118.135")))
    }

    /// ROUTE's radio lists a field's contact once, under the database's name; a frequency the pilot typed that
    /// the database doesn't have stays as typed.
    func testTheWaypointsCopyOfTheContactIsListedOnce() {
        let route = PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: Self.asBuilt(Self.route(next: 1), Self.world),
                                               sources: Self.world.sources).route
        let atLSZQ = route.filter { $0.freq == "123.575" }
        XCTAssertEqual(atLSZQ.map(\.station), ["LSZQ A/G"])

        var typed = Self.route(next: 3)
        typed.waypoints[3].frequency = "119.175"
        let plan = PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: typed, sources: Self.world.sources)
        XCTAssertEqual(plan.next, .init(station: "LSZQ", freq: "119.175"), "what the pilot typed wins")
    }

    /// Free practice circuits at Bressaucourt, no route: the field is NOW and nothing is NEXT, not the nearest CTR
    /// (NEXT read Les Eplatures; 6.4.0, the author's dry run checks, 18 Oct). On a route too.
    func testCircuitsKeepNothingNext() {
        var world = Self.world
        world.ctrs = [(station: "LES EPLATURES", frequency: "118.125")]
        let circuits = PhaseFrequencyPlanner.plan(position: Self.nearBressaucourt, plan: nil, circuits: true,
                                                  sources: world.sources)
        XCTAssertEqual(circuits.current, .init(station: "LSZQ A/G", freq: "123.575"))
        XCTAssertNil(circuits.next)
        XCTAssertFalse(circuits.route.contains { $0.role == .next })
        let onARoute = PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: Self.route(next: 1), circuits: true,
                                                  sources: world.sources)
        XCTAssertNil(onARoute.next, "circuits switched on at the end of a cross-country")
    }

    /// No route near a field: the area's Info is NEXT, before a CTR around (the nearest, in any direction).
    func testNoRouteNearAFieldHasTheInfoNextBeforeACTR() {
        var world = Self.world
        world.ctrs = [(station: "LES EPLATURES", frequency: "118.125")]
        XCTAssertEqual(PhaseFrequencyPlanner.plan(position: Self.nearBressaucourt, plan: nil, sources: world.sources).next,
                       .init(station: "Zürich Info", freq: "124.700"))
        XCTAssertEqual(PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: nil, sources: world.sources).next?.station,
                       "LES EPLATURES", "away from any field: the nearest CTR, as before")
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
            "Zürich Info|124.700",          // the FIS the way ahead enters (Bressaucourt is Zürich's)
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
        XCTAssertEqual(Array(route.map(\.station).prefix(3)), ["LSZG TWR", "Zürich Info", "LSZG ATIS"])
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

    /// On the ground in the Engadine with a Jura route: the aircraft's FIS (Zürich's), then the route's
    /// (Geneva's), which RADIO left out (device check, 5 Oct: LSZQ to LSGE from Tinizong).
    func testRouteRadioListsTheFISOfTheRouteNotOnlyTheAircrafts() {
        let tinizong = CLLocationCoordinate2D(latitude: 46.582, longitude: 9.616)
        let route = PhaseFrequencyPlanner.plan(position: tinizong, plan: Self.route(next: 0),
                                               sources: Self.world.sources).route
        let stations = route.map(\.station)
        XCTAssertEqual(stations.first, "Zürich Info", "NOW: the aircraft's FIS")
        XCTAssertTrue(stations.contains("Geneva Info"), "the route's: \(stations)")
        XCTAssertFalse(stations.contains { $0.hasPrefix("FIS ") }, "no FIS East or West: \(stations)")
    }

    /// Flying east out of Geneva's sector: Zürich Information after Geneva Information, in the order of use.
    func testRouteRadioListsTheNextFISInTheOrderItComes() {
        var plan = FlightPlan(name: "East", waypoints: [Self.waypoint("LSGC"),
                                                        FlightPlanWaypoint(name: "LSZH", coordinate: .init(latitude: 47.4647, longitude: 8.5492))])
        plan.currentWaypointIndex = 1
        let route = PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: plan, sources: Self.world.sources).route
        XCTAssertEqual(route.map(\.station).filter { $0.hasSuffix(" Info") }, ["Geneva Info", "Zürich Info"])
    }

    /// Diverting: the way is to the field diverted to, not along the route left.
    func testDivertingTheFISAreThoseOnTheWayToTheField() {
        var plan = Self.route(next: 2)
        plan.diversion = Diversion(ident: "LSZH", name: "Zurich", latitude: 47.4647, longitude: 8.5492, leftRouteAt: 2)
        let route = PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: plan, sources: Self.world.sources).route
        XCTAssertTrue(route.contains { $0.station == "Zürich Info" }, "\(route.map(\.station))")
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

    // MARK: - The FIS

    /// The published split, as OpenAIP's two Swiss FIS sectors draw it: until 6.2 a line at 7.45° E put
    /// Bressaucourt, Delémont, Saignelégier, Biel and Grenchen on Geneva's side, Brig on Zurich's.
    func testTheSwissFISSplitIsThePublishedOne() {
        let zurich: [(String, Double, Double)] = [
            ("LSZQ", 47.392, 7.030), ("Delémont", 47.36, 7.34), ("Saignelégier", 47.256, 7.003),
            ("Courtelary", 47.18, 7.07), ("Biel", 47.14, 7.25), ("LSZG", 47.182, 7.417), ("LSZB", 46.913, 7.499),
            ("Thun", 46.76, 7.63), ("Interlaken", 46.69, 7.86), ("LSZA", 46.004, 8.911), ("LSZS", 46.534, 9.884),
            ("Tinizong", 46.582, 9.616), ("LSZH", 47.465, 8.549)]
        let geneva: [(String, Double, Double)] = [
            ("LSGC", 47.084, 6.793), ("St-Imier", 47.15, 6.99), ("Neuchâtel", 46.99, 6.93), ("LSGE", 46.755, 7.076),
            ("Fribourg", 46.80, 7.15), ("Frutigen", 46.59, 7.65), ("LSGS", 46.219, 7.327), ("Brig", 46.32, 7.99),
            ("LSGG", 46.238, 6.109)]
        for (name, lat, lon) in zurich {
            XCTAssertEqual(SwissAirspaceSectors.getSector(for: .init(latitude: lat, longitude: lon)), .zurich, name)
            XCTAssertEqual(FISSectors.swiss(at: .init(latitude: lat, longitude: lon)),
                           .init(station: "Zürich Info", freq: "124.700"), name)
        }
        for (name, lat, lon) in geneva {
            XCTAssertEqual(SwissAirspaceSectors.getSector(for: .init(latitude: lat, longitude: lon)), .geneva, name)
            XCTAssertEqual(FISSectors.swiss(at: .init(latitude: lat, longitude: lon)),
                           .init(station: "Geneva Info", freq: "126.350"), name)
        }
        XCTAssertNil(FISSectors.swiss(at: .init(latitude: 48.5, longitude: 7.7)), "Strasbourg: not Switzerland")
    }

    /// The data's FIS sectors answer wherever they cover, a foreign one included; the Swiss split only
    /// where they don't. Flying to Bressaucourt: Geneva's, then Zürich's, then a foreign sector where the
    /// stub has no Swiss one (Bale Info), in the order the way enters them.
    func testTheDatasFISWinAndAForeignSectorIsListedInItsTurn() {
        var sources = Self.world.sources
        sources.fisSectors = { point in
            point.latitude > 47.30 && point.longitude < 7.20 ? [.init(station: "Bale Info", freq: "130.900")] : []
        }
        let route = PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: Self.route(next: 3), sources: sources).route
        XCTAssertEqual(route.map(\.station).filter { $0.hasSuffix(" Info") }, ["Geneva Info", "Zürich Info", "Bale Info"])
    }

    /// A FIS with several sectors is one station: Bale Info is 130.900 north of the Doubs (SIV BALE 1) and
    /// 135.855 over Franche-Comté (SIV BALE 2), and RADIO listed both (device check, 6 Oct). Once, with the
    /// frequency of the sector the aircraft is in, or else the first the way enters.
    func testAFISWithSeveralSectorsIsListedOnceWithTheSectorReachedFirst() {
        var sources = Self.world.sources
        sources.fisSectors = { point in
            if point.longitude < 7.0 { return [.init(station: "Bale Info", freq: "135.855")] }
            return point.latitude > 47.3 ? [.init(station: "Bale Info", freq: "130.900")] : []
        }
        var plan = FlightPlan(name: "West", waypoints: [Self.waypoint("LSZQ"), Self.waypoint("LSGC")])
        plan.currentWaypointIndex = 1
        let fromTheAjoie = PhaseFrequencyPlanner.plan(position: Self.nearBressaucourt, plan: plan, sources: sources).route
        XCTAssertEqual(fromTheAjoie.filter { $0.station == "Bale Info" }.map(\.freq), ["130.900"], "\(fromTheAjoie.map(\.station))")
        let fromTheDoubs = PhaseFrequencyPlanner.plan(position: .init(latitude: 47.30, longitude: 6.95), plan: plan,
                                                      sources: sources).route
        XCTAssertEqual(fromTheDoubs.filter { $0.station == "Bale Info" }.map(\.freq), ["135.855"])
    }

    /// Where two countries' sectors overlap from the ground (Zürich's and SIV BALE 1.2 over the Swiss
    /// Jura), only the country below's counts, whatever order the downloads loaded in: over the Ajoie a
    /// pilot calls Zürich Information, and Bale Info once the way goes into France (the author, 6 Oct).
    /// Another country's sector still counts where the country below has none.
    func testOverAnotherCountryItsOwnSectorCountsAlone() {
        let bale = Self.fisSector("SIV BALE 1.2", frequency: "130.900", name: "BALE INFORMATION", country: "FR")
        let zurich = Self.fisSector("ZÜRICH", frequency: "124.700", name: "ZÜRICH INFORMATION", country: "CH")
        for sectors in [[bale, zurich], [zurich, bale]] {
            XCTAssertEqual(FISSectors.stations(over: sectors, countriesBelow: ["CH"]).map(\.station), ["Zürich Info"])
            XCTAssertEqual(FISSectors.stations(over: sectors, countriesBelow: ["FR"]).map(\.station), ["Bale Info"])
        }
        XCTAssertEqual(FISSectors.stations(over: [bale], countriesBelow: ["CH"]).map(\.station), ["Bale Info"],
                       "no Swiss sector there: the foreign one")
        let otherBale = Self.fisSector("SIV BALE 2.1", frequency: "135.855", name: "BALE INFORMATION", country: "FR")
        XCTAssertEqual(FISSectors.stations(over: [otherBale, bale], countriesBelow: ["FR"]).count, 1, "one per FIS")
    }

    /// A data sector's station: its primary frequency, its name as RADIO writes it; none for a sector that
    /// starts high (SIV GENEVE 1 from 6,500 ft) or has no frequency.
    func testADataSectorsStation() {
        XCTAssertEqual(FISSectors.station(of: Self.fisSector("SIV BALE 1.2", frequency: "130.900", name: "BALE INFORMATION")),
                       .init(station: "Bale Info", freq: "130.900"))
        XCTAssertEqual(FISSectors.station(of: Self.fisSector("ZÜRICH", frequency: "124.700", name: "ZÜRICH INFORMATION")),
                       .init(station: "Zürich Info", freq: "124.700"))
        XCTAssertNil(FISSectors.station(of: Self.fisSector("SIV GENEVE 1", frequency: "126.350", name: "GENEVE INFORMATION",
                                                           lowerFeetMSL: 6_500)))
        XCTAssertNil(FISSectors.station(of: Self.fisSector("SIV X", frequency: nil, name: nil)))
        XCTAssertEqual(FISSectors.displayName("CHAMBERY APP"), "Chambery APP")
        XCTAssertEqual(FISSectors.displayName("GENEVA INFORMATION"), "Geneva Info")
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

    // MARK: - Without a route (q10), diverting (R7) (6.4.2)

    /// q10: without a route a field is NOW only inside its zone, else within its 3 NM circuit. dr-3 had the
    /// destination NOW 16 NM out, and Les Eplatures as it passed 4 NM aside.
    func testWithoutARouteAFieldIsNowOnlyInsideItsZone() {
        XCTAssertEqual(PhaseFrequencyPlanner.plan(position: Self.nearLesEplatures, plan: nil, sources: Self.world.sources).current?.station,
                       "Geneva Info", "4 NM from Les Eplatures, no zone known: outside its circuit")
        var world = Self.world
        world.zones = ["LSGC": 5]
        let inside = PhaseFrequencyPlanner.plan(position: Self.nearLesEplatures, plan: nil, sources: world.sources)
        XCTAssertEqual(inside.current, .init(station: "LSGC AFIS", freq: "120.350"), "inside its 5 NM zone")
        XCTAssertEqual(inside.next?.station, "Geneva Info")
        XCTAssertEqual(PhaseFrequencyPlanner.plan(position: Self.nearBressaucourt, plan: nil, sources: Self.world.sources).current?.station,
                       "LSZQ A/G", "2.5 NM out, in its circuit")
        let between = PhaseFrequencyPlanner.plan(position: Self.nearLesEplatures, plan: nil, sources: Self.world.sources)
        XCTAssertEqual(between.next, .init(station: "LSGC AFIS", freq: "120.350"), "the field ahead is the next call")
    }

    /// R7: diverting, the field diverted to is NEXT, then NOW 5 min before it (8.3 NM at 100 kt) or inside its
    /// zone, with nothing NEXT.
    func testDivertingTheFieldIsNowFiveMinutesBeforeIt() {
        var route = Self.route(next: 2)
        route.diversion = Self.diversion("LSZQ")
        let away = PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: route, sources: Self.world.sources)
        XCTAssertEqual(away.next, .init(station: "LSZQ A/G", freq: "123.575"))
        let sevenOut = CLLocationCoordinate2D(latitude: 47.275, longitude: 7.03)
        let close = PhaseFrequencyPlanner.plan(position: sevenOut, plan: route,
                                               situation: .init(groundSpeedKt: 100), sources: Self.world.sources)
        XCTAssertEqual(close.current, .init(station: "LSZQ A/G", freq: "123.575"))
        XCTAssertNil(close.next)
        let slow = PhaseFrequencyPlanner.plan(position: sevenOut, plan: route,
                                              situation: .init(groundSpeedKt: 60), sources: Self.world.sources)
        XCTAssertEqual(slow.next?.station, "LSZQ A/G", "at 60 kt, 7 NM is 7 min")
    }

    /// q4 without a route: a FIS area at the aircraft's altitude is NOW's FIS (Bâle Information over AZ4 above
    /// 2,000 ft AGL), else the sectors; with no altitude, the sectors.
    func testWithoutARouteAFISAreaAtTheAircraftsAltitude() {
        var world = Self.world
        world.fisArea = { _, altitude in altitude >= 3_840 ? .init(station: "Bale Info", freq: "130.900") : nil }
        let high = PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: nil, situation: .init(altitudeFt: 4_500),
                                              sources: world.sources)
        XCTAssertEqual(high.current, .init(station: "Bale Info", freq: "130.900"))
        let low = PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: nil, situation: .init(altitudeFt: 3_000),
                                             sources: world.sources)
        XCTAssertEqual(low.current?.station, "Geneva Info")
        XCTAssertEqual(PhaseFrequencyPlanner.plan(position: Self.enRoute, plan: nil, sources: world.sources).current?.station,
                       "Geneva Info")
    }

    /// The aerodromes on the way are a setting, on by default, also for settings saved before 6.4.2.
    func testAerodromesOnTheWayAreOnByDefault() throws {
        XCTAssertTrue(AppSettings().showFieldsOnTheWay)
        let older = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings()).replacingKey("showFieldsOnTheWay"))
        XCTAssertTrue(older.showFieldsOnTheWay)
    }

    // MARK: - On the route: the radio timeline (6.4.2)

    /// A route east along 47°N from LSXA (7.0° E) to LSXB (8.2° E), 49 NM, Geneva Info west of 7.75° E and
    /// Zurich Info east of it (`RadioTimelineTests` has the same).
    private static func timelineRoute(next: Int = 1) -> FlightPlan {
        let lons = [7.0, 7.3, 7.6, 7.9, 8.2]
        let names = ["LSXA", "B", "C", "D", "LSXB"]
        var plan = FlightPlan(name: "East", waypoints: lons.indices.map { i in
            FlightPlanWaypoint(name: names[i], coordinate: .init(latitude: 47.0, longitude: lons[i]),
                               altitude: i == 0 || i == 4 ? 1500 : 5000, plannedGroundSpeed: 100)
        })
        plan.calculateRouteData()
        plan.currentWaypointIndex = next
        return plan
    }

    private static func timeline(for plan: FlightPlan, airspaces: [Airspace] = []) -> RadioTimeline {
        let geneva = RouteRadioPlanner.Station(frequency: "126.350", callSign: "GENEVA INFO")
        let zurich = RouteRadioPlanner.Station(frequency: "124.700", callSign: "ZURICH INFO")
        return RouteRadioPlanner.plan(.init(
            waypoints: plan.waypoints, airspaces: airspaces,
            departure: .init(ident: "LSXA", contact: .init(frequency: "122.050", callSign: "LSXA AFIS"), atis: nil, ground: nil),
            destination: .init(ident: "LSXB", contact: .init(frequency: "118.125", callSign: "LSXB TWR"),
                               atis: "128.525", ground: nil),
            fis: { $0.longitude < 7.75 ? geneva : zurich })).timeline
    }

    /// No field near: the timeline alone decides.
    private static let empty = World(fields: [:])

    private func onRoute(longitude: Double, latitude: Double = 47.0, next: Int, departureOver: Bool = true,
                         airspaces: [Airspace] = [], plan custom: FlightPlan? = nil,
                         world: World = PhaseFrequencyPlannerTests.empty) -> PhaseFrequencyPlanner.Plan {
        let plan = custom ?? Self.timelineRoute(next: next)
        let situation = PhaseFrequencyPlanner.Situation(timeline: Self.timeline(for: plan, airspaces: airspaces),
                                                        groundSpeedKt: 100, departureOver: departureOver)
        return PhaseFrequencyPlanner.plan(position: .init(latitude: latitude, longitude: longitude), plan: plan,
                                          situation: situation, sources: world.sources)
    }

    /// With the Cockpit's handover (6.4.3): at the level-off NOW stays the departure and NEXT comes due, its line full;
    /// the plan gives the state back for the Cockpit to keep; without the handover, 6.4.2's NOW moves by itself.
    func testWithTheHandoverNowWaitsAndNextComesDue() {
        let plan = Self.timelineRoute(next: 1)
        let situation = PhaseFrequencyPlanner.Situation(timeline: Self.timeline(for: plan), groundSpeedKt: 100,
                                                        departureOver: false, handover: RadioHandover())
        let ground = PhaseFrequencyPlanner.plan(position: .init(latitude: 47.0, longitude: 7.0), plan: plan,
                                                situation: situation, sources: Self.empty.sources)
        XCTAssertEqual(ground.current?.station, "LSXA AFIS")
        XCTAssertEqual(ground.next?.due, false)
        let kept = try? XCTUnwrap(ground.handover)
        XCTAssertEqual(kept?.station?.callSign, "LSXA AFIS")

        var levelled = situation
        levelled.departureOver = true
        levelled.handover = kept
        let level = PhaseFrequencyPlanner.plan(position: .init(latitude: 47.0, longitude: 7.05), plan: plan,
                                               situation: levelled, sources: Self.empty.sources)
        XCTAssertEqual(level.current?.station, "LSXA AFIS", "NOW waits for the pilot's tap")
        XCTAssertEqual(level.next?.station, "Geneva Info")
        XCTAssertEqual(level.next?.due, true)
        XCTAssertEqual(level.next?.dueLeft ?? 0, 1, accuracy: 0.01)
        let route = level.route
        XCTAssertEqual(route.first { $0.role == .next }?.due, true, "ROUTE's NEXT due as well")
        XCTAssertNil(level.switched)

        XCTAssertEqual(onRoute(longitude: 7.05, next: 1).current?.station, "Geneva Info", "no handover: as in 6.4.2")
    }

    /// dr-3's first stretch: the departure field until the level-off, the Info it climbs into NEXT; then that
    /// Info, the next one NEXT.
    func testOnTheRouteNowAndNextFollowTheTimeline() {
        let climbing = onRoute(longitude: 7.05, next: 1, departureOver: false)
        XCTAssertEqual(climbing.current, .init(station: "LSXA AFIS", freq: "122.050"))
        XCTAssertEqual(climbing.next, .init(station: "Geneva Info", freq: "126.350"))
        let level = onRoute(longitude: 7.05, next: 1)
        XCTAssertEqual(level.current, .init(station: "Geneva Info", freq: "126.350"))
        XCTAssertEqual(level.next, .init(station: "Zurich Info", freq: "124.700"))
        let before = onRoute(longitude: 7.5, next: 2)
        XCTAssertEqual(before.current, .init(station: "Geneva Info", freq: "126.350"))
        XCTAssertEqual(before.next, .init(station: "Zurich Info", freq: "124.700"))
        let across = onRoute(longitude: 7.8, next: 3)
        XCTAssertEqual(across.current, .init(station: "Zurich Info", freq: "124.700"))
        XCTAssertEqual(across.next, .init(station: "LSXB ATIS", freq: "128.525", listen: true),
                       "within 10 min of the destination's call, its ATIS")
    }

    /// The ATIS, 10 min before the destination's call: NEXT, tagged LISTEN; then the contact NOW, nothing NEXT.
    func testTheDestinationsATISIsListenThenTheContactIsNow() {
        let listen = onRoute(longitude: 7.85, next: 3)
        XCTAssertEqual(listen.next, .init(station: "LSXB ATIS", freq: "128.525", listen: true))
        XCTAssertEqual(listen.route.first { $0.role == .next }?.listen, true)
        let called = onRoute(longitude: 8.05, next: 4)
        XCTAssertEqual(called.current?.station, "LSXB TWR")
        XCTAssertNil(called.next)
    }

    /// A TMA the FIS clears is named beside NOW; a zone active by NOTAM says HX.
    func testATMABesideNowAndHX() {
        let tma = Airspace(id: "TMA GOLF 2", name: "TMA GOLF 2", type: 7, icaoClass: 2, country: "CH",
                           upperCeiling: AltitudeLimit(value: 130, unit: 6, referenceDatum: 2),
                           lowerCeiling: AltitudeLimit(value: 0, unit: 1, referenceDatum: 0),
                           geometry: AirspaceGeometry(type: "Polygon", coordinates: [[[7.45, 46.9], [7.45, 47.1], [7.65, 47.1], [7.65, 46.9], [7.45, 46.9]]]),
                           activity: nil, frequencies: [AirspaceFrequency(value: "126.350", name: "GENEVA INFORMATION", primary: true, unit: nil)])
        let inside = onRoute(longitude: 7.5, next: 2, airspaces: [tma])
        XCTAssertEqual(inside.current, .init(station: "Geneva Info", freq: "126.350", note: "TMA GOLF"))
        XCTAssertEqual(inside.route.first?.stationWithNote, "Geneva Info · TMA GOLF")

        let ctr = Airspace(id: "CTR ALPHA (HX)", name: "CTR ALPHA (HX)", type: 4, icaoClass: 3, country: "CH",
                           upperCeiling: AltitudeLimit(value: 130, unit: 6, referenceDatum: 2),
                           lowerCeiling: AltitudeLimit(value: 0, unit: 1, referenceDatum: 0),
                           geometry: AirspaceGeometry(type: "Polygon", coordinates: [[[7.40, 46.9], [7.40, 47.1], [7.50, 47.1], [7.50, 46.9], [7.40, 46.9]]]),
                           activity: nil, frequencies: [AirspaceFrequency(value: "130.150", name: "ALPHA TOWER", primary: true, unit: nil)])
        XCTAssertEqual(onRoute(longitude: 7.45, next: 2, airspaces: [ctr]).current?.station, "ALPHA TWR HX",
                       "a zone's station as the nav log prints it")
    }

    /// More than 5 NM off the route, or diverting, the timeline is left for the rules without a route.
    func testOffTheRouteOrDivertingTheTimelineIsLeft() {
        XCTAssertEqual(onRoute(longitude: 7.05, next: 1, departureOver: false).current?.station, "LSXA AFIS")
        let off = onRoute(longitude: 7.05, latitude: 47.1, next: 1, departureOver: false)
        XCTAssertEqual(off.current?.station, "Geneva Info", "6 NM north: the area's FIS, the rules without a route")
        var diverting = Self.timelineRoute(next: 2)
        diverting.diversion = Diversion(ident: "LSZG", name: "LSZG", latitude: 47.1816, longitude: 7.4172, leftRouteAt: 2)
        let reading = onRoute(longitude: 7.35, next: 2, plan: diverting, world: Self.world)
        XCTAssertEqual(reading.next, .init(station: "LSZG TWR", freq: "120.100"))
    }

    /// ROUTE's radio on the route: NOW, NEXT, then the calls ahead in order, the ATIS tagged LISTEN before the
    /// contact, 121.500 last.
    func testRouteRadioIsTheTimelineFromNowOn() {
        let stations = onRoute(longitude: 7.05, next: 1).route
        XCTAssertEqual(stations.map(\.station), ["Geneva Info", "Zurich Info", "LSXB ATIS", "LSXB TWR", SwissCommonFrequency.emergency.name])
        XCTAssertEqual(stations.map(\.listen), [false, false, true, false, false])
    }

    /// ROUTE on the route lists a CTR around once: not again under its own name when the timeline has its
    /// frequency (the destination's tower, 8.33 kHz name or not).
    func testRouteRadioListsACTRAroundOnlyOnce() {
        var world = Self.empty
        world.ctrs = [(station: "XB (HX)", frequency: "118.130"), (station: "BERN (HX)", frequency: "121.025")]
        let route = onRoute(longitude: 7.05, next: 1, world: world).route
        let stations = route.map(\.station)
        XCTAssertFalse(stations.contains("XB (HX)"), stations.description)
        XCTAssertTrue(stations.contains("BERN (HX)"))
        // Nearby, off the route, after the route's calls: ROUTE heads them so (the author's device check r3-6).
        XCTAssertEqual(route.filter(\.nearby).map(\.station), ["BERN (HX)"])
        XCTAssertEqual(route.firstIndex { $0.nearby }, route.lastIndex { !$0.nearby && !$0.isEmergency }.map { $0 + 1 })
    }

    /// The Cockpit's radio reads a timeline only for the route it was built for.
    func testTheRadioReadsATimelineOnlyForItsRoute() {
        let radio = CockpitRadio()
        radio.publish = { _ in }
        let plan = Self.timelineRoute(next: 1)
        radio.setTimeline(Self.timeline(for: plan), for: plan)
        radio.update(position: .init(latitude: 47.0, longitude: 7.05), plan: plan,
                     situation: .init(groundSpeedKt: 100, departureOver: true), sources: Self.empty.sources)
        XCTAssertEqual(radio.next?.station, "Zurich Info")
        var other = plan
        other.waypoints[2].frequency = "119.000"
        radio.update(position: .init(latitude: 47.0, longitude: 7.05), plan: other,
                     situation: .init(groundSpeedKt: 100, departureOver: true), sources: Self.empty.sources)
        XCTAssertNotEqual(radio.next?.station, "Zurich Info", "an edited route waits for its own timeline")
    }

    /// The Cockpit's radio with the handover (6.4.3): a tap on NEXT switches and is offered back, a second tap within a
    /// second is ignored, UNDO puts the pilot back; the app's own switch is reported, and undone it isn't made again; a
    /// row of ROUTE › RADIO makes its station NOW.
    func testTheRadioSwitchesOnATapAndTakesItBack() {
        let radio = CockpitRadio()
        radio.publish = { _ in }
        var kept: RadioHandover?
        radio.onHandover = { kept = $0 }
        var reported: [String] = []
        var undoReported: (() -> Void)?
        radio.onSwitched = { message, undo in
            reported.append(message)
            undoReported = undo
        }
        let plan = Self.timelineRoute(next: 1)
        radio.setTimeline(Self.timeline(for: plan), for: plan)
        func fly(_ longitude: Double, departureOver: Bool = true) {
            radio.update(position: .init(latitude: 47.0, longitude: longitude), plan: plan,
                         situation: .init(groundSpeedKt: 100, departureOver: departureOver), sources: Self.empty.sources)
        }

        XCTAssertEqual(radio.tapNext(at: Date()).isOffTimeline, true, "before the first reading: ROUTE")
        fly(7.0, departureOver: false)
        XCTAssertTrue(radio.onTimeline)
        XCTAssertEqual(radio.now?.station, "LSXA AFIS")
        XCTAssertEqual(radio.next?.due, false)
        fly(7.05)
        XCTAssertEqual(radio.now?.station, "LSXA AFIS", "NOW waits for the tap")
        XCTAssertEqual(radio.next?.station, "Geneva Info")
        XCTAssertEqual(radio.next?.due, true)

        let tap = Date()
        guard case .taken(let taken) = radio.tapNext(at: tap) else { return XCTFail("the tap switches") }
        XCTAssertEqual(taken.message, L10n.Read.switched("Geneva Info"))
        XCTAssertEqual(radio.now?.station, "Geneva Info")
        XCTAssertEqual(kept?.station?.callSign, "GENEVA INFO", "kept with the flight")
        XCTAssertEqual(radio.tapNext(at: tap.addingTimeInterval(0.5)).isIgnored, true, "a bounce isn't a second tap")
        XCTAssertEqual(radio.now?.station, "Geneva Info")
        taken.undo()
        XCTAssertEqual(radio.now?.station, "LSXA AFIS", "UNDO: back on the field")
        XCTAssertEqual(radio.next?.due, true)
        XCTAssertTrue(reported.isEmpty)

        fly(7.27)   // 11 NM out, no tap: the app leaves the field by itself
        XCTAssertEqual(reported, [L10n.Read.switchedAutomatically("Geneva Info")])
        XCTAssertEqual(radio.now?.station, "Geneva Info")
        XCTAssertEqual(radio.tapNext(at: Date()).isIgnored, true,
                       "NEXT changed under the finger: the tap was for the call the app took")
        XCTAssertEqual(radio.now?.station, "Geneva Info")
        undoReported?()
        XCTAssertEqual(radio.now?.station, "LSXA AFIS")
        XCTAssertEqual(radio.next?.station, "Geneva Info")
        XCTAssertEqual(radio.next?.due, true)
        XCTAssertNil(radio.next?.dueLeft, "no line: the app won't switch again")
        fly(7.29)
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(radio.now?.station, "LSXA AFIS")

        guard let zurich = radio.stations.first(where: { $0.station == "Zurich Info" }) else {
            return XCTFail("Zurich Info on ROUTE")
        }
        XCTAssertTrue(CockpitRadio.picks(zurich))
        XCTAssertEqual(radio.select(zurich)?.message, L10n.Read.switched("Zurich Info"))
        XCTAssertEqual(radio.now?.station, "Zurich Info", "picked on ROUTE")
        XCTAssertFalse(CockpitRadio.picks(.emergency))
    }

    /// The Companion iPhone's tap (6.4.3, q9 B): the iPad switches while its NEXT is still the frequency the phone
    /// showed, and offers it back there too; a tap for another does nothing; the phone's UNDO takes back that switch
    /// only, once, within its six seconds.
    func testThePhoneSwitchesByTheFrequencyItShowed() {
        let radio = CockpitRadio()
        radio.publish = { _ in }
        var offered: [String] = []
        radio.onTaken = { offered.append($0.message) }
        let plan = Self.timelineRoute(next: 1)
        radio.setTimeline(Self.timeline(for: plan), for: plan)
        func fly(_ longitude: Double, departureOver: Bool = true) {
            radio.update(position: .init(latitude: 47.0, longitude: longitude), plan: plan,
                         situation: .init(groundSpeedKt: 100, departureOver: departureOver), sources: Self.empty.sources)
        }
        fly(7.0, departureOver: false)
        fly(7.05)
        let t = Date()
        XCTAssertFalse(radio.tapNext(fromPhone: "124.700", at: t), "NEXT is Geneva Info: a late tap does nothing")
        XCTAssertEqual(radio.now?.station, "LSXA AFIS")
        XCTAssertTrue(radio.tapNext(fromPhone: "126.35", at: t), "the same frequency, however it is written")
        XCTAssertEqual(radio.now?.station, "Geneva Info")
        XCTAssertEqual(offered, [L10n.Read.switched("Geneva Info")], "offered back on the iPad too")
        XCTAssertFalse(radio.undoPhoneSwitch("124.700", at: t.addingTimeInterval(1)), "another switch's UNDO")
        XCTAssertTrue(radio.undoPhoneSwitch("126.35", at: t.addingTimeInterval(2)))
        XCTAssertEqual(radio.now?.station, "LSXA AFIS")
        XCTAssertFalse(radio.undoPhoneSwitch("126.35", at: t.addingTimeInterval(3)), "once")

        let later = t.addingTimeInterval(10)
        XCTAssertTrue(radio.tapNext(fromPhone: "126.350", at: later))
        XCTAssertFalse(radio.undoPhoneSwitch("126.350", at: later.addingTimeInterval(UndoOfferRule.window + 1)),
                       "past UNDO's six seconds")
        XCTAssertEqual(radio.now?.station, "Geneva Info")
    }

    /// The due state reaches the Companion iPhone and the Watch, the share kept to 0...1 whatever the wire says;
    /// an older iPad sends neither, nor the switch. (6.4.3)
    func testTheDueStateReachesThePhoneAndTheWatch() throws {
        let item = PhaseFrequency(station: "LSZG TWR HX", freq: "120.105", highlighted: true, isEmergency: false,
                                  role: .next, due: true, dueLeft: 0.4)
        XCTAssertEqual(item.watchInfo.due, true)
        let read = try JSONDecoder().decode(CompanionFrequency.self, from: JSONEncoder().encode(CompanionFrequency(item)))
        XCTAssertEqual(read.due, true)
        XCTAssertEqual(read.dueLeft ?? 0, 0.4, accuracy: 1e-9)
        let wild = try JSONDecoder().decode(CompanionFrequency.self,
                                            from: Data(#"{"station":"X","frequency":"120.105","due":true,"dueLeft":7}"#.utf8))
        XCTAssertEqual(wild.dueLeft, 1)
        let older = try JSONDecoder().decode(CompanionFrequency.self, from: Data(#"{"station":"X","frequency":"120.105"}"#.utf8))
        XCTAssertNil(older.due)
        XCTAssertNil(older.dueLeft)
        XCTAssertNil(try JSONDecoder().decode(CompanionFlightData.self, from: Data("{}".utf8)).radioSwitch)
        XCTAssertEqual(try JSONDecoder().decode(CompanionFlightData.self, from: Data(#"{"radioSwitch":true}"#.utf8)).radioSwitch, true)
        let command = try JSONDecoder().decode(CompanionCommand.self,
                                               from: JSONEncoder().encode(CompanionCommand.switchRadio(frequency: "120.105")))
        guard case .switchRadio(let frequency) = command else { return XCTFail("the switch on the wire") }
        XCTAssertEqual(frequency, "120.105")
    }

    /// On the timeline with nothing NEXT (the destination's tower NOW, its ATIS behind), a tap on NEXT does nothing.
    func testATapOnAnEmptyNextDoesNothing() {
        let radio = CockpitRadio()
        radio.publish = { _ in }
        let plan = Self.timelineRoute(next: 4)
        radio.setTimeline(Self.timeline(for: plan), for: plan)
        radio.update(position: .init(latitude: 47.0, longitude: 8.19), plan: plan,
                     situation: .init(groundSpeedKt: 100, departureOver: true), sources: Self.empty.sources)
        XCTAssertTrue(radio.onTimeline)
        XCTAssertNil(radio.next?.freq)
        XCTAssertEqual(radio.tapNext(at: Date()).isIgnored, true)
    }

    /// Off a route's timeline the handover stays out: NEXT's tap opens ROUTE.
    func testWithoutATimelineNextOpensRoute() {
        let radio = CockpitRadio()
        radio.publish = { _ in }
        let plan = Self.timelineRoute(next: 1)
        radio.update(position: .init(latitude: 47.0, longitude: 7.05), plan: plan,
                     situation: .init(groundSpeedKt: 100, departureOver: true), sources: Self.empty.sources)
        XCTAssertFalse(radio.onTimeline)
        XCTAssertEqual(radio.tapNext(at: Date()).isOffTimeline, true)
        XCTAssertNil(radio.handover)
    }

    /// LISTEN reaches the Watch and the Companion iPhone as a key of their own.
    func testListenReachesTheWatchAndThePhone() throws {
        let item = PhaseFrequency(station: "LSXB ATIS", freq: "128.525", highlighted: false, isEmergency: false,
                                  role: .next, listen: true)
        XCTAssertEqual(item.watchInfo.listen, true)
        XCTAssertEqual(item.watchInfo.role, .next)
        let wire = try JSONEncoder().encode(CompanionFrequency(item))
        XCTAssertEqual(try JSONDecoder().decode(CompanionFrequency.self, from: wire).listen, true)
        let older = try JSONDecoder().decode(CompanionFrequency.self, from: Data(#"{"station":"LSXB TWR","frequency":"118.125"}"#.utf8))
        XCTAssertNil(older.listen)
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
        var fisSectors: (CLLocationCoordinate2D) -> [PhaseFrequencyPlanner.Entry] = { _ in [] }
        /// Each field's zone, as a centre and a radius (NM): none, its 3 NM circuit counts.
        var zones: [String: Double] = [:]
        var fisArea: (CLLocationCoordinate2D, Double) -> PhaseFrequencyPlanner.Entry? = { _, _ in nil }

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
                nearbyCTRs: { _ in ctrs },
                fisSectors: fisSectors,
                isInFieldZone: { [zones] field, point in
                    zones[field.ident].map {
                        CLLocation(latitude: point.latitude, longitude: point.longitude)
                            .distance(from: CLLocation(latitude: field.coordinate.latitude,
                                                       longitude: field.coordinate.longitude)) / 1852 <= $0
                    }
                },
                fisArea: fisArea)
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
    /// About 2.5 NM south of Bressaucourt, inside its circuit (until 6.4.2 about 3 NM, just outside it: a field
    /// was NOW within 10 NM then).
    private static let nearBressaucourt = CLLocationCoordinate2D(latitude: 47.35, longitude: 7.03)

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

    /// A FIS sector (OpenAIP type 33) over the Jura, from `lowerFeetMSL` to FL100.
    private static func fisSector(_ name: String, frequency: String?, name station: String?,
                                  lowerFeetMSL: Int = 0, country: String = "FR") -> Airspace {
        let ring: [[Double]] = [[6.8, 47.0], [6.8, 47.5], [7.4, 47.5], [7.4, 47.0], [6.8, 47.0]]
        return Airspace(
            id: name, name: name, type: 33, icaoClass: 8, country: country,
            upperCeiling: AltitudeLimit(value: 100, unit: 6, referenceDatum: 2),
            lowerCeiling: AltitudeLimit(value: lowerFeetMSL, unit: 1, referenceDatum: lowerFeetMSL == 0 ? 0 : 1),
            geometry: AirspaceGeometry(type: "Polygon", coordinates: [ring]),
            activity: nil,
            frequencies: frequency.map { [AirspaceFrequency(value: $0, name: station, primary: true, unit: nil)] })
    }

    private static func diversion(_ ident: String) -> Diversion {
        let field = world.fields[ident]!
        return Diversion(ident: ident, name: ident, latitude: field.coordinate.latitude,
                         longitude: field.coordinate.longitude, leftRouteAt: 2)
    }
}

private extension Data {
    /// The JSON without one key: a save from before that setting.
    func replacingKey(_ key: String) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: self) as? [String: Any] ?? [:]
        object.removeValue(forKey: key)
        return try JSONSerialization.data(withJSONObject: object)
    }
}

private extension CockpitRadio.NextTap {
    var isIgnored: Bool { if case .ignored = self { return true }; return false }
    var isOffTimeline: Bool { if case .offTimeline = self { return true }; return false }
}
