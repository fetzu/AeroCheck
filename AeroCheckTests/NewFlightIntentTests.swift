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

    private func resolver(_ known: [String: CLLocationCoordinate2D]) -> (String) -> CLLocationCoordinate2D? {
        { known[$0.uppercased()] }
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

    // MARK: - Labels and creatability

    func testCircuitsAreLabelledByTheirField() {
        XCTAssertEqual(intent(to: "", kind: .circuits).routeLabel, L10n.Flights.circuitsAt("LSZQ"))
        XCTAssertEqual(intent(kind: .circuits).resolvedArrivalIdent, "LSZQ",
                       "circuits return to where they started")
    }

    func testACrossCountryLabelReadsFromArrowTo() {
        XCTAssertEqual(intent().routeLabel, "LSZQ → LSGY")
    }

    func testADepartureIsTheOnlyThingRequired() {
        XCTAssertTrue(intent(to: "").isCreatable, "a route can arrive later")
        XCTAssertFalse(intent(from: "  ").isCreatable)
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
}
