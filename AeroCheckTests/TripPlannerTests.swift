import XCTest
import CoreLocation
@testable import AeroCheck

/// `TripPlanner`: turning a route into the legs of a trip and keeping the legs consistent. (v5.1)
///
/// Synthetic routes east along 47°N at 100 kt. A waypoint every 0.3° of longitude is 12.3 NM apart.
final class TripPlannerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func route(_ names: [String], lons: [Double], lat: Double = 47.0) -> FlightPlan {
        var plan = FlightPlan(name: "Route", plannedDepartureTime: t0, fuelFlow: 20, fuelOnBoard: 80)
        plan.waypoints = zip(names, lons).map { name, lon in
            FlightPlanWaypoint(name: name, coordinate: .init(latitude: lat, longitude: lon),
                               altitude: 5000, plannedGroundSpeed: 100)
        }
        plan.alternateAerodrome = "LSGC"
        plan.calculateRouteData()
        return plan
    }

    private func aerodrome(_ ident: String, lat: Double, lon: Double, elevation: Double? = 1500,
                           ppr: Bool = false) -> TripPlanner.Aerodrome {
        TripPlanner.Aerodrome(ident: ident, name: ident, latitude: lat, longitude: lon,
                              elevationFeet: elevation, frequency: nil, isPPR: ppr)
    }

    // MARK: - Split

    func testSplittingKeepsTheFirstLegsIdentityAndSharesTheStop() {
        let plan = route(["AAAA", "W1", "BBBB", "W2", "CCCC"], lons: [7.0, 7.3, 7.6, 7.9, 8.2])
        guard let (first, second) = TripPlanner.split(plan, at: 2, fieldElevationFeet: 1400) else {
            return XCTFail("split refused")
        }
        XCTAssertEqual(first.id, plan.id, "a followed flight keeps its plan and its thread")
        XCTAssertNotEqual(second.id, plan.id)
        XCTAssertEqual(first.waypoints.map(\.name), ["AAAA", "W1", "BBBB"])
        XCTAssertEqual(second.waypoints.map(\.name), ["BBBB", "W2", "CCCC"])
        XCTAssertNotEqual(first.waypoints.last?.id, second.waypoints.first?.id,
                          "waypoint ids stay unique per plan")
        XCTAssertEqual(first.waypoints.last?.altitude, 1400, "the stop is landed on, at field elevation")
        XCTAssertEqual(second.waypoints.first?.altitude, 1400)
        XCTAssertEqual(second.waypoints[1].altitude, 5000, "the leg after the stop keeps its altitude")
    }

    func testTheAlternateMovesToTheLegThatEndsAtTheDestination() {
        let plan = route(["AAAA", "BBBB", "CCCC"], lons: [7.0, 7.3, 7.6])
        let (first, second) = TripPlanner.split(plan, at: 1)!
        XCTAssertNil(first.alternateAerodrome)
        XCTAssertEqual(second.alternateAerodrome, "LSGC")
    }

    func testTheSecondLegDepartsAnEstimatedGroundTimeAfterTheFirstLands() {
        let plan = route(["AAAA", "BBBB", "CCCC"], lons: [7.0, 7.3, 7.6])
        let (first, second) = TripPlanner.split(plan, at: 1, stopover: Stopover(groundMinutes: 45))!
        let arrival = first.waypoints.last!.estimatedTimeOver!
        XCTAssertEqual(second.plannedDepartureTime, arrival.addingTimeInterval(45 * 60))
        XCTAssertEqual(second.departureIsEstimate, true)
        XCTAssertNil(second.firmDepartureTime, "an estimate must never arm a reminder")
        XCTAssertEqual(first.firmDepartureTime, t0)
        XCTAssertNotNil(second.estimatedTimeOver(at: 1), "the estimate is what gives its nav log ETOs")
    }

    func testWithoutARefuelTheNextLegStartsWithWhatIsLeft() {
        let plan = route(["AAAA", "BBBB", "CCCC"], lons: [7.0, 7.3, 7.6])
        let (first, kept) = TripPlanner.split(plan, at: 1, stopover: Stopover(refuel: false))!
        XCTAssertEqual(kept.fuelOnBoard!, 80 - first.tripFuel!, accuracy: 0.001)
        let (_, refuelled) = TripPlanner.split(plan, at: 1, stopover: Stopover(refuel: true))!
        XCTAssertEqual(refuelled.fuelOnBoard, 80, "a refuel brings the planned fuel back")
    }

    func testEndpointsCannotBeStops() {
        let plan = route(["AAAA", "BBBB", "CCCC"], lons: [7.0, 7.3, 7.6])
        XCTAssertNil(TripPlanner.split(plan, at: 0))
        XCTAssertNil(TripPlanner.split(plan, at: 2))
    }

    func testSeveralStopsMakeTheLegsInOrder() {
        let plan = route(["A", "B", "C", "D", "E"], lons: [7.0, 7.3, 7.6, 7.9, 8.2])
        let legs = TripPlanner.legs(of: plan, stops: [(index: 3, stopover: Stopover(), ident: nil, elevation: nil),
                                                      (index: 1, stopover: Stopover(), ident: nil, elevation: nil)])
        XCTAssertEqual(legs.map { $0.waypoints.map(\.name) }, [["A", "B"], ["B", "C", "D"], ["D", "E"]])
    }

    func testJoiningUndoesASplit() {
        let plan = route(["AAAA", "W1", "BBBB", "W2", "CCCC"], lons: [7.0, 7.3, 7.6, 7.9, 8.2])
        let (first, second) = TripPlanner.split(plan, at: 2)!
        let joined = TripPlanner.join(first, second)
        XCTAssertEqual(joined.id, plan.id)
        XCTAssertEqual(joined.waypoints.map(\.name), plan.waypoints.map(\.name))
        XCTAssertEqual(joined.alternateAerodrome, "LSGC")
        XCTAssertEqual(joined.totalDistance, plan.totalDistance, accuracy: 0.001)
    }

    // MARK: - Keeping later legs in step

    func testMovingTheFirstLegMovesTheNextLegsEstimate() {
        let plan = route(["AAAA", "BBBB", "CCCC"], lons: [7.0, 7.3, 7.6])
        let legs = TripPlanner.split(plan, at: 1)!
        var first = legs.first
        let second = legs.second
        first.plannedDepartureTime = t0.addingTimeInterval(3600)
        first.calculateRouteData()
        let moved = TripPlanner.refreshed(second, after: first)
        XCTAssertEqual(moved?.plannedDepartureTime, second.plannedDepartureTime?.addingTimeInterval(3600))
        XCTAssertNil(TripPlanner.refreshed(moved!, after: first), "no change, no write")
    }

    func testADepartureThePilotChoseIsNeverOverwritten() {
        let plan = route(["AAAA", "BBBB", "CCCC"], lons: [7.0, 7.3, 7.6])
        var (first, second) = TripPlanner.split(plan, at: 1)!
        second.departureIsEstimate = nil
        first.plannedDepartureTime = t0.addingTimeInterval(3600)
        first.calculateRouteData()
        XCTAssertNil(TripPlanner.refreshed(second, after: first))
    }

    // MARK: - Aerodromes along the route

    func testStopCandidatesAreOrderedAlongTheRouteWithinTheCorridor() {
        let plan = route(["AAAA", "W1", "BBBB", "CCCC"], lons: [7.0, 7.3, 7.6, 7.9])
        let found = TripPlanner.stopCandidates(along: plan.waypoints, aerodromes: [
            aerodrome("ONRT", lat: 47.0, lon: 7.6),              // is waypoint 2
            aerodrome("NRTH", lat: 47.05, lon: 7.45),            // 3 NM north
            aerodrome("FARR", lat: 47.2, lon: 7.45),             // 12 NM north: outside
            aerodrome("DEPT", lat: 47.0, lon: 7.001),            // the departure itself
        ])
        XCTAssertEqual(found.map(\.aerodrome.ident), ["NRTH", "ONRT"])
        XCTAssertEqual(found[0].offsetNM, 3, accuracy: 0.1)
        XCTAssertNil(found[0].waypointIndex)
        XCTAssertEqual(found[1].waypointIndex, 2, "an aerodrome the route already visits is that waypoint")
    }

    func testAnOffRouteStopIsInsertedWhereItAddsLeast() {
        let plan = route(["AAAA", "W1", "BBBB", "CCCC"], lons: [7.0, 7.3, 7.6, 7.9])
        let candidate = TripPlanner.stopCandidates(along: plan.waypoints,
                                                   aerodromes: [aerodrome("NRTH", lat: 47.05, lon: 7.45)]).first!
        let (updated, index) = TripPlanner.routeStopping(at: candidate, in: plan)
        XCTAssertEqual(index, 2)
        XCTAssertEqual(updated.waypoints.map(\.name), ["AAAA", "W1", "NRTH", "BBBB", "CCCC"])
        let (first, second) = TripPlanner.split(updated, at: index, stopIdent: "NRTH")!
        XCTAssertEqual(first.waypoints.last?.name, "NRTH")
        XCTAssertEqual(second.waypoints.map(\.name), ["NRTH", "BBBB", "CCCC"])
    }

    // MARK: - Continuing after a diversion

    func testTheContinuationRejoinsTheRoutePastTheDiversionField() {
        var plan = route(["AAAA", "W1", "W2", "W3", "W4", "DDDD"], lons: [7.0, 7.3, 7.6, 7.9, 8.2, 8.5])
        // Left the route before W2 and landed at a field abeam W3, 4 NM south.
        plan.diversion = Diversion(ident: "FFFF", name: "Field", latitude: 46.933, longitude: 7.9,
                                   elevationFeet: 1300, frequency: nil, startedAt: t0, leftRouteAt: 2)
        let field = aerodrome("FFFF", lat: 46.933, lon: 7.9, elevation: 1300)
        let next = TripPlanner.continuation(of: plan, from: field)
        XCTAssertEqual(next.waypoints.map(\.name), ["FFFF", "W4", "DDDD"],
                       "past the field, never back to W2/W3, and not straight to the destination")
        XCTAssertEqual(next.waypoints.first?.altitude, 1300)
        XCTAssertNotEqual(next.id, plan.id)
        XCTAssertNil(next.diversion)
        XCTAssertNil(next.plannedDepartureTime, "the pilot says when; nobody knows yet")
        XCTAssertTrue(next.waypoints.allSatisfy { $0.actualTimeOver == nil })
    }

    func testAFieldPastTheLastWaypointGoesStraightToTheDestination() {
        var plan = route(["AAAA", "W1", "DDDD"], lons: [7.0, 7.3, 7.6])
        plan.diversion = Diversion(ident: "FFFF", name: "Field", latitude: 47.05, longitude: 7.5,
                                   elevationFeet: nil, frequency: nil, startedAt: t0, leftRouteAt: 2)
        let next = TripPlanner.continuation(of: plan, from: aerodrome("FFFF", lat: 47.05, lon: 7.5))
        XCTAssertEqual(next.waypoints.map(\.name), ["FFFF", "DDDD"])
    }

    // MARK: - Landing somewhere else

    func testLandingElsewhereRecordsADiversionEvenWithoutTheButton() {
        // Nobody pressed Divert: END FLIGHT knows where the aircraft stopped, and that is a fact.
        var plan = route(["AAAA", "W1", "W2", "DDDD"], lons: [7.0, 7.3, 7.6, 7.9])
        plan.waypoints[1].actualTimeOver = t0.addingTimeInterval(600)
        let landing = t0.addingTimeInterval(1500)
        let settled = TripPlanner.settlingDiversion(plan, landedAt: aerodrome("FFFF", lat: 46.9, lon: 7.5),
                                                    landing: landing)
        XCTAssertEqual(settled.diversion?.ident, "FFFF")
        XCTAssertEqual(settled.diversion?.leftRouteAt, 2, "left the route after the last waypoint passed")
        XCTAssertEqual(settled.diversion?.landedAt, landing)
        XCTAssertNil(settled.diversion?.startedAt, "no button, no start time")
    }

    func testLandingAtTheDestinationIsNotADiversion() {
        let plan = route(["AAAA", "W1", "DDDD"], lons: [7.0, 7.3, 7.6])
        XCTAssertNil(TripPlanner.settlingDiversion(plan, landedAt: aerodrome("DDDD", lat: 47.0, lon: 7.6),
                                                   landing: t0).diversion)
        XCTAssertNil(TripPlanner.settlingDiversion(plan, landedAt: aerodrome("XXXX", lat: 47.01, lon: 7.61),
                                                   landing: t0).diversion,
                     "a field within 2 NM of the destination is the destination under another ident")
    }

    func testADiversionInTheAirKeepsWhereItLeftTheRoute() {
        var plan = route(["AAAA", "W1", "W2", "DDDD"], lons: [7.0, 7.3, 7.6, 7.9])
        plan.diversion = Diversion(ident: "FFFF", name: "Field", latitude: 46.9, longitude: 7.5,
                                   elevationFeet: nil, frequency: nil, startedAt: t0, leftRouteAt: 1)
        let settled = TripPlanner.settlingDiversion(plan, landedAt: aerodrome("FFFF", lat: 46.9, lon: 7.5),
                                                    landing: t0.addingTimeInterval(900))
        XCTAssertEqual(settled.diversion?.leftRouteAt, 1)
        XCTAssertEqual(settled.diversion?.startedAt, t0)
        XCTAssertNotNil(settled.diversion?.landedAt)

        let backOnPlan = TripPlanner.settlingDiversion(plan, landedAt: aerodrome("DDDD", lat: 47.0, lon: 7.9),
                                                       landing: t0)
        XCTAssertNil(backOnPlan.diversion, "diverted, then made the destination after all")
    }

    // MARK: - The nav log of a diverted flight

    func testTheNavLogGreysWhatWasNotFlownAndEndsAtTheDiversion() {
        var plan = route(["AAAA", "W1", "W2", "DDDD"], lons: [7.0, 7.3, 7.6, 7.9])
        plan.waypoints[0].actualTimeOver = t0
        plan.waypoints[1].actualTimeOver = t0.addingTimeInterval(600)
        plan.diversion = Diversion(ident: "FFFF", name: "Field", latitude: 46.9, longitude: 7.5,
                                   elevationFeet: 1300, frequency: "AFIS 123.200", startedAt: t0.addingTimeInterval(700),
                                   leftRouteAt: 2, landedAt: t0.addingTimeInterval(1500))
        let rows = FlightPlanExportService.navLogRows(plan, radio: RouteRadioPlanner.manualOnly(plan.waypoints))
        XCTAssertEqual(rows.count, 5, "the route, then the diversion field")
        XCTAssertEqual(rows.map(\.notFlown), [false, false, true, true, false])
        XCTAssertEqual(rows[4].name, "→ FFFF")
        XCTAssertTrue(rows[4].isDiversion)
        XCTAssertEqual(rows[4].alt, "1300")
        XCTAssertFalse(rows[4].ato.isEmpty, "the landing time is its ATO")
        XCTAssertTrue(rows[4].remarks.contains("AFIS 123.200"))
    }

    func testALaterLegsNavLogSaysItsDepartureIsAnEstimate() {
        let plan = route(["AAAA", "BBBB", "CCCC"], lons: [7.0, 7.3, 7.6])
        let (_, second) = TripPlanner.split(plan, at: 1, stopover: Stopover(groundMinutes: 45))!
        let rows = FlightPlanExportService.navLogRows(second, radio: RouteRadioPlanner.manualOnly(second.waypoints))
        XCTAssertTrue(rows[0].eto.hasPrefix("≈"))
        XCTAssertEqual(rows[0].remarks.first, L10n.Trip.estimatedDepartureRemark(45))
    }
}
