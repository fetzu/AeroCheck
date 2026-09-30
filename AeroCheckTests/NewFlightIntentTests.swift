import XCTest
import CoreLocation
@testable import AeroCheck

/// Thread-first flight creation (v5.0.0).
///
/// The load-bearing rule here is that a duplicate carries the INTENT and never the EVIDENCE. Most of
/// this suite exists to keep that true as the type grows.
final class NewFlightIntentTests: XCTestCase {

    private let lszq = CLLocationCoordinate2D(latitude: 47.4247, longitude: 7.1869)
    private let lsgy = CLLocationCoordinate2D(latitude: 46.7619, longitude: 6.6141)

    private func resolver(_ known: [String: CLLocationCoordinate2D],
                          elevations: [String: Double] = [:]) -> (String) -> FlightPlan.ResolvedPlace? {
        { ident in
            let key = ident.uppercased()
            guard let coordinate = known[key] else { return nil }
            return FlightPlan.ResolvedPlace(coordinate: coordinate, elevationFeet: elevations[key])
        }
    }

    private func intent(from: String = "LSZQ",
                        to: String = "LSGY",
                        kind: FlightKind = .crossCountry) -> NewFlightIntent {
        NewFlightIntent(departureIdent: from,
                        arrivalIdent: to,
                        departureTime: nil,
                        aircraftTypeId: "dr400-140b",
                        aircraftRegistration: "HB-KFD",
                        aircraftModelName: "DR400/140B",
                        kind: kind)
    }

    // MARK: - Building a plan

    func testBothEndsBecomeWaypointsWhenTheyResolve() {
        let plan = FlightPlan.from(intent: intent(),
                                   resolve: resolver(["LSZQ": lszq, "LSGY": lsgy]))
        XCTAssertEqual(plan.waypoints.map(\.name), ["LSZQ", "LSGY"])
        XCTAssertEqual(plan.aircraftRegistration, "HB-KFD")
    }

    func testAnUnresolvedIdentProducesNoWaypointRatherThanAGuess() {
        // Country detection — customs, DABS, GAFOR — runs on coordinates. A fabricated position would
        // put the flight in the wrong country, which is the exact defect this release already fixed.
        let plan = FlightPlan.from(intent: intent(to: "ZZZZ"),
                                   resolve: resolver(["LSZQ": lszq]))
        XCTAssertEqual(plan.waypoints.map(\.name), ["LSZQ"])
    }

    func testAFlightCanBeCreatedWithNothingResolved() {
        // The whole point of thread-first: you can create Saturday's flight before the airport layer
        // is downloaded, and add the route later.
        let plan = FlightPlan.from(intent: intent(), resolve: { _ in nil })
        XCTAssertTrue(plan.waypoints.isEmpty)
        XCTAssertEqual(plan.aircraftTypeId, "dr400-140b")
    }

    func testCircuitsProduceOneWaypointNotAZeroLengthLeg() {
        // Two identical waypoints would draw a leg of zero length and invite a division by zero in
        // the timing maths downstream.
        let plan = FlightPlan.from(intent: intent(to: "LSZQ", kind: .circuits),
                                   resolve: resolver(["LSZQ": lszq]))
        XCTAssertEqual(plan.waypoints.map(\.name), ["LSZQ"])
    }

    func testADestinationEqualToTheDepartureIsNotDuplicated() {
        let plan = FlightPlan.from(intent: intent(to: "lszq"),
                                   resolve: resolver(["LSZQ": lszq]))
        XCTAssertEqual(plan.waypoints.map(\.name), ["LSZQ"])
    }

    // MARK: - Waypoint altitudes (v5.x)

    /// The ends of a route are on the ground; anything between them is overflown. Leaving every
    /// altitude nil gave the route profile nothing to plot and the ICAO level field nothing to say.
    func testEndpointsTakeFieldElevationAndOverflightsClearIt() {
        var intent = self.intent(to: "LSGY")
        intent.departureIdent = "LSZQ"
        let plan = FlightPlan.from(
            intent: intent,
            resolve: resolver(["LSZQ": lszq, "LSGY": lsgy],
                              elevations: ["LSZQ": 1660, "LSGY": 1349]))

        XCTAssertEqual(plan.waypoints.first?.altitude, 1660, "departure sits at field elevation")
        XCTAssertEqual(plan.waypoints.last?.altitude, 1349, "arrival sits at field elevation")
    }

    /// An unknown elevation stays unknown: a fabricated altitude in a flight plan is worse than an
    /// empty one the pilot fills in.
    func testAnUnknownElevationLeavesTheAltitudeEmpty() {
        let plan = FlightPlan.from(intent: intent(),
                                   resolve: resolver(["LSZQ": lszq, "LSGY": lsgy]))
        XCTAssertNil(plan.waypoints.first?.altitude)
        XCTAssertNil(plan.waypoints.last?.altitude)
    }

    // MARK: - Labels

    func testCircuitsAreLabelledByTheirField() {
        XCTAssertEqual(intent(to: "", kind: .circuits).routeLabel, L10n.Flights.circuitsAt("LSZQ"))
        XCTAssertEqual(intent(kind: .circuits).resolvedArrivalIdent, "LSZQ",
                       "circuits return to where they started")
    }

    func testACrossCountryLabelReadsFromArrowTo() {
        XCTAssertEqual(intent().routeLabel, "LSZQ → LSGY")
    }

    // MARK: - Duplicate the intent, never the evidence

    func testDuplicatingAFlightCarriesRouteAndAircraftButNoTiming() {
        var flight = Flight(airplane: "dr400-140b",
                            aircraftRegistration: "HB-KFD",
                            aircraftType: "DR400/140B")
        flight.departureAirportIdent = "LSZQ"
        flight.arrivalAirportIdent = "LSGY"
        flight.blockOffTime = Date(timeIntervalSince1970: 1_790_000_000)

        let again = NewFlightIntent(duplicating: flight)
        XCTAssertEqual(again.departureIdent, "LSZQ")
        XCTAssertEqual(again.arrivalIdent, "LSGY")
        XCTAssertEqual(again.aircraftRegistration, "HB-KFD")
        // The app has no idea when you intend to fly it again, and a plausible wrong time in a flight
        // plan is worse than an empty one.
        XCTAssertNil(again.departureTime)
    }

    func testAnIntentCannotCarryPreparationAtAll() {
        // The rule is enforced by the type, not by discipline: there is nowhere in a NewFlightIntent
        // to put a ticked task, so a duplicate cannot arrive pre-prepared even by accident. If
        // someone adds task state to this struct, this test is the argument against it.
        let mirror = Mirror(reflecting: intent())
        let labels = mirror.children.compactMap(\.label)
        for forbidden in ["task", "state", "done", "completed", "filed", "tick"] {
            XCTAssertFalse(labels.contains { $0.lowercased().contains(forbidden) },
                           "an intent must not carry preparation: found \(labels)")
        }
    }

    func testAReturnToTheSameFieldWithSeveralLandingsReadsAsCircuits() {
        var flight = Flight(airplane: "dr400-140b", aircraftRegistration: "HB-KFD", aircraftType: "DR400/140B")
        flight.departureAirportIdent = "LSZQ"
        flight.arrivalAirportIdent = "LSZQ"
        flight.fullStopCount = 1
        flight.touchAndGoCount = 5
        XCTAssertEqual(NewFlightIntent.inferredKind(for: flight), .circuits)
    }

    func testASingleLandingBackHomeIsNotCircuits() {
        // Out and back on one landing is a cross-country that happened to return, not pattern work.
        var flight = Flight(airplane: "dr400-140b", aircraftRegistration: "HB-KFD", aircraftType: "DR400/140B")
        flight.departureAirportIdent = "LSZQ"
        flight.arrivalAirportIdent = "LSZQ"
        flight.fullStopCount = 1
        XCTAssertEqual(NewFlightIntent.inferredKind(for: flight), .crossCountry)
    }

    func testDuplicatingAPlanKeepsItsEndsAndAircraft() {
        var plan = FlightPlan(name: "Test", aircraftTypeId: "dr400-140b",
                              aircraftRegistration: "HB-KFD", aircraftModelName: "DR400/140B")
        plan.waypoints = [
            FlightPlanWaypoint(name: "LSZQ", coordinate: lszq),
            FlightPlanWaypoint(name: "LSGY", coordinate: lsgy),
        ]
        let again = NewFlightIntent(duplicating: plan)
        XCTAssertEqual(again.departureIdent, "LSZQ")
        XCTAssertEqual(again.arrivalIdent, "LSGY")
        XCTAssertEqual(again.kind, .crossCountry)
        XCTAssertNil(again.departureTime)
    }

    func testKindDecidesHowMuchAdminAFlightCarries() {
        XCTAssertEqual(FlightKind.circuits.profile, .local)
        XCTAssertEqual(FlightKind.crossCountry.profile, .full)
    }

    // MARK: - Stops in Plan new flight (6.1)

    private func typed(_ stops: inout PlannedStops, _ idents: [String]) {
        for (row, ident) in zip(stops.rows, idents) { stops.setIdent(ident, for: row.id) }
    }

    func testTheTwoRowsAreFromAndTo() {
        let stops = PlannedStops(from: "LSZQ", to: "LSGE")
        XCTAssertEqual(stops.rows.indices.map(stops.role(at:)), [.from, .to])
        XCTAssertTrue(stops.stopIndices.isEmpty)
        XCTAssertEqual(stops.idents, ["LSZQ", "LSGE"])
        XCTAssertEqual(stops.legCount, 1)
        XCTAssertEqual(stops.stopovers, [], "two aerodromes are one flight: no stop")
    }

    /// The author's move: LSZQ, LSZQ in the two rows, then "Add a stop on the way". It used to append
    /// the stop after the destination (LSZQ → LSZQ → LSGE); it goes before TO.
    func testAStopAddedAfterLSZQLSZQGoesBetweenThem() {
        var stops = PlannedStops(from: "LSZQ", to: "LSZQ")
        XCTAssertEqual(stops.repeatedIdent, "LSZQ", "on its own, the same field twice is a local flight")
        let added = stops.addStop()
        XCTAssertEqual(stops.index(of: added), 1, "the new stop sits just before TO")
        stops.setIdent("lsge ", for: added)
        XCTAssertEqual(stops.idents, ["LSZQ", "LSGE", "LSZQ"])
        XCTAssertEqual(stops.rows.indices.map(stops.role(at:)), [.from, .stop(1), .to])
        XCTAssertEqual(stops.legCount, 2)
        XCTAssertNil(stops.repeatedIdent, "a round trip with a stop is not a local flight")
    }

    func testEveryNewStopGoesJustBeforeTo() {
        var stops = PlannedStops(from: "LSZQ", to: "LSZQ")
        stops.setIdent("LSGE", for: stops.addStop())
        stops.setIdent("LSGN", for: stops.addStop())
        XCTAssertEqual(stops.idents, ["LSZQ", "LSGE", "LSGN", "LSZQ"])
        XCTAssertEqual(stops.rows.indices.map(stops.role(at:)), [.from, .stop(1), .stop(2), .to])
        XCTAssertEqual(stops.stopIndices, 1..<3)
    }

    func testFromAndToCanBeClearedButNotRemoved() {
        var stops = PlannedStops(from: "LSZQ", to: "LSGN")
        let stop = stops.addStop()
        stops.removeStop(stops.rows[0].id)
        stops.removeStop(stops.rows[2].id)
        XCTAssertEqual(stops.rows.count, 3, "FROM and TO are the flight itself")
        stops.removeStop(stop)
        XCTAssertEqual(stops.rows.count, 2)
        stops.setIdent("", for: stops.rows[0].id)
        XCTAssertEqual(stops.rows.count, 2, "clearing FROM keeps its row")
        XCTAssertEqual(stops.idents, ["LSGN"])
        XCTAssertEqual(stops.legCount, 0)
    }

    func testStopsReorderAmongThemselvesAndTheEndsStayPut() {
        var stops = PlannedStops()
        _ = stops.addStop(); _ = stops.addStop(); _ = stops.addStop()
        typed(&stops, ["LSZQ", "LSGN", "LSGE", "LSGC", "LSZQ"])
        let from = stops.rows[0].id, to = stops.rows[4].id
        let lsge = stops.rows[2].id

        stops.moveStop(lsge, to: 1)
        XCTAssertEqual(stops.idents, ["LSZQ", "LSGE", "LSGN", "LSGC", "LSZQ"])

        stops.moveStop(lsge, to: 0)
        XCTAssertEqual(stops.index(of: lsge), 1, "a stop can't go before FROM")
        stops.moveStop(lsge, to: 4)
        XCTAssertEqual(stops.index(of: lsge), 3, "nor after TO")
        XCTAssertEqual(stops.idents, ["LSZQ", "LSGN", "LSGC", "LSGE", "LSZQ"])

        stops.moveStop(from, to: 2)
        stops.moveStop(to, to: 1)
        XCTAssertEqual(stops.rows.first?.id, from, "FROM doesn't move")
        XCTAssertEqual(stops.rows.last?.id, to, "TO doesn't move")
    }

    /// Each stop's time on the ground and refuel belong to the aerodrome, so they move with it.
    func testAStopsGroundTimeAndRefuelFollowItsAerodrome() {
        var stops = PlannedStops(from: "LSZQ", to: "LSZQ")
        let lsge = stops.addStop(), lsgn = stops.addStop()
        stops.setIdent("LSGE", for: lsge)
        stops.setIdent("LSGN", for: lsgn)
        XCTAssertEqual(stops.stopovers, [Stopover(), Stopover()], "the default stop until the pilot sets one")

        stops.setStopover(Stopover(groundMinutes: 45, refuel: true), for: lsge)
        stops.setStopover(Stopover(groundMinutes: 0, refuel: false), for: lsgn)
        XCTAssertEqual(stops.stopovers, [Stopover(groundMinutes: 45, refuel: true),
                                         Stopover(groundMinutes: 0, refuel: false)])

        stops.moveStop(lsgn, to: 1)
        XCTAssertEqual(stops.idents, ["LSZQ", "LSGN", "LSGE", "LSZQ"])
        XCTAssertEqual(stops.stopovers, [Stopover(groundMinutes: 0, refuel: false),
                                         Stopover(groundMinutes: 45, refuel: true)])
    }

    func testAnEmptyStopIsNotALegToNowhere() {
        var stops = PlannedStops(from: "LSZQ", to: "LSGE")
        let blank = stops.addStop()
        stops.setStopover(Stopover(groundMinutes: 90, refuel: true), for: blank)
        stops.setIdent("  ", for: blank)
        XCTAssertEqual(stops.idents, ["LSZQ", "LSGE"])
        XCTAssertEqual(stops.legCount, 1)
        XCTAssertEqual(stops.stopovers, [], "a blank row's stop goes with it")
    }

    /// The note under the fields names the field and offers the stop, rather than steering to a
    /// turning point.
    func testTheSameFieldTwiceNamesTheField() {
        XCTAssertEqual(PlannedStops(from: "lszq", to: "LSZQ").repeatedIdent, "LSZQ")
        XCTAssertNil(PlannedStops(from: "LSZQ", to: "LSGE").repeatedIdent)
        var stops = PlannedStops(from: "LSZQ", to: "LSZQ")
        stops.setIdent("LSZQ", for: stops.addStop())
        XCTAssertEqual(stops.repeatedIdent, "LSZQ", "a stop at the field just left is a local flight too")

        let note = L10n.PlanFlight.sameAerodrome("LSZQ")
        XCTAssertTrue(note.contains("LSZQ"))
        XCTAssertFalse(note.contains("%@"))
    }

    // MARK: - Starting at home (6.1)

    private var blank: NewFlightIntent { intent(from: "", to: "") }

    /// Nothing seeds the sheet (Today, Plan › Flights): FROM is the home aerodrome, and TO is home
    /// again, back home.
    func testANewFlightStartsAndEndsAtHome() {
        let stops = PlannedStops.opening(for: blank, home: "lszq ")
        XCTAssertEqual(stops.rows.map(\.ident), ["LSZQ", "LSZQ"])
        XCTAssertEqual(stops.legCount, 1, "one flight, local until a stop or another TO")
        XCTAssertEqual(stops.repeatedIdent, "LSZQ", "the note offers the stop on the way")
    }

    /// "Plan this again" brings its own FROM and TO; so does a flight seeded with one end only.
    func testASeededSheetKeepsItsOwnAerodromes() {
        XCTAssertEqual(PlannedStops.opening(for: intent(from: "LSGG", to: "LSZS"), home: "LSZQ").rows.map(\.ident),
                       ["LSGG", "LSZS"])
        XCTAssertEqual(PlannedStops.opening(for: intent(from: "", to: "LSGE"), home: "LSZQ").rows.map(\.ident),
                       ["", "LSGE"])
        XCTAssertEqual(PlannedStops.opening(for: intent(from: "LSGN", to: ""), home: "LSZQ").rows.map(\.ident),
                       ["LSGN", ""])
    }

    func testWithoutAHomeAerodromeTheSheetOpensEmpty() {
        XCTAssertEqual(PlannedStops.opening(for: blank, home: nil).rows.map(\.ident), ["", ""])
        XCTAssertEqual(PlannedStops.opening(for: blank, home: "  ").rows.map(\.ident), ["", ""])
        XCTAssertEqual(PlannedStops.opening(for: blank, home: "L$ZQ").rows.map(\.ident), ["", ""],
                       "a value no aerodrome code can have is not a home")
    }

    // MARK: - Landing on the way, from a saved route (6.1)

    private func candidate(_ ident: String, along: Double, waypoint: Int? = nil) -> TripPlanner.StopCandidate {
        TripPlanner.StopCandidate(
            aerodrome: TripPlanner.Aerodrome(ident: ident, name: ident, latitude: 47, longitude: 7,
                                             elevationFeet: nil, frequency: nil, isPPR: false),
            alongNM: along, offsetNM: waypoint == nil ? 3 : 0, waypointIndex: waypoint)
    }

    /// Every switch off is one flight; each "Land here" adds a leg, listed in flying order whatever
    /// order they were switched on in.
    func testEachLandHereAddsALegInFlyingOrder() {
        var landings = RouteLandings(candidates: [candidate("LSGN", along: 60, waypoint: 5),
                                                  candidate("LSGE", along: 40, waypoint: 3),
                                                  candidate("LSGC", along: 80)])
        XCTAssertEqual(landings.candidates.map(\.aerodrome.ident), ["LSGE", "LSGN", "LSGC"])
        XCTAssertEqual(landings.legCount, 1)
        XCTAssertTrue(landings.landings.isEmpty)

        landings.setLanding(true, at: "LSGN")
        landings.setLanding(true, at: "LSGE")
        XCTAssertEqual(landings.landings.map(\.ident), ["LSGE", "LSGN"])
        XCTAssertEqual(landings.legCount, 3)

        landings.setLanding(false, at: "LSGE")
        XCTAssertEqual(landings.landings.map(\.ident), ["LSGN"])
        landings.setLanding(true, at: "XXXX")
        XCTAssertEqual(landings.legCount, 2, "only an aerodrome on the list can be landed at")
    }

    func testAStopsGroundTimeStaysWithItsLandingUntilSwitchedOff() {
        var landings = RouteLandings(candidates: [candidate("LSGE", along: 40, waypoint: 3)])
        landings.setStopover(Stopover(groundMinutes: 60), at: "LSGE")
        XCTAssertTrue(landings.landings.isEmpty, "no stop where the flight doesn't land")
        landings.setLanding(true, at: "LSGE")
        XCTAssertEqual(landings.landings.first?.stopover, Stopover())
        landings.setStopover(Stopover(groundMinutes: 60, refuel: true), at: "LSGE")
        landings.setLanding(true, at: "LSGE")
        XCTAssertEqual(landings.landings.first?.stopover, Stopover(groundMinutes: 60, refuel: true),
                       "switching on what is on changes nothing")
        landings.setLanding(false, at: "LSGE")
        landings.setLanding(true, at: "LSGE")
        XCTAssertEqual(landings.landings.first?.stopover, Stopover(), "switched off and on, it starts over")
    }

    /// "Land somewhere else…": the aerodrome joins the list in its place along the route, switched on.
    func testLandingSomewhereElseJoinsTheListInItsPlace() {
        var landings = RouteLandings(candidates: [candidate("LSGE", along: 40, waypoint: 3),
                                                  candidate("LSGN", along: 60, waypoint: 5)])
        landings.add(candidate("LSZG", along: 50))
        XCTAssertEqual(landings.candidates.map(\.aerodrome.ident), ["LSGE", "LSZG", "LSGN"])
        XCTAssertEqual(landings.landings.map(\.ident), ["LSZG"])
        landings.add(candidate("LSGE", along: 40, waypoint: 3))
        XCTAssertEqual(landings.candidates.count, 3, "one already listed is switched on, not listed twice")
        XCTAssertEqual(landings.landings.map(\.ident), ["LSGE", "LSZG"])
    }
}
