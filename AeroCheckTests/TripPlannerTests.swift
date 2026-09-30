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

    /// The first leg took off 16 minutes late, LINE UP tapped or not: its ETOs count from the take-off,
    /// and the next leg's estimated departure follows its arrival. (6.1)
    func testTheNextLegsEstimateFollowsTheFirstLegsTakeoff() {
        let plan = route(["AAAA", "BBBB", "CCCC"], lons: [7.0, 7.3, 7.6])
        let (first, second) = TripPlanner.split(plan, at: 1)!
        let flying = first.anchoringETOs(on: t0.addingTimeInterval(16 * 60))!
        XCTAssertEqual(flying.plannedDepartureTime, t0, "the planned departure stays the plan")

        let moved = TripPlanner.refreshed(second, after: flying)
        XCTAssertEqual(moved?.plannedDepartureTime, second.plannedDepartureTime?.addingTimeInterval(16 * 60))
    }

    /// A leg that has flown keeps its estimate and its fuel when the leg before it changes later: they
    /// are what it was planned with. (LINE UP used to stop the chain by making the estimate a chosen
    /// departure; it no longer touches the departure.) (6.1)
    func testALegThatHasFlownIsNotReestimated() {
        let plan = route(["AAAA", "BBBB", "CCCC"], lons: [7.0, 7.3, 7.6])
        var (first, second) = TripPlanner.split(plan, at: 1)!
        second = second.anchoringETOs(on: t0.addingTimeInterval(2 * 3600))!
        first.plannedDepartureTime = t0.addingTimeInterval(3600)
        first.calculateRouteData()
        XCTAssertNil(TripPlanner.refreshed(second, after: first))
    }

    /// The stop carried the wind of the leg leaving it; after the split that leg is the second leg's
    /// first, and the wind goes with it. (6.1)
    func testSplittingKeepsTheWindTheSecondLegWasPlannedWith() {
        FlightPlan.windsAloftProvider = { _, _, _ in FlightPlan.WindAloft(directionDegTrue: 90, speedKt: 20) }
        defer { FlightPlan.windsAloftProvider = nil }
        let plan = route(["AAAA", "BBBB", "CCCC"], lons: [7.0, 7.3, 7.6])
        FlightPlan.windsAloftProvider = nil

        let (_, second) = TripPlanner.split(plan, at: 1)!
        XCTAssertEqual(second.waypoints[0].planningWind, plan.waypoints[1].planningWind)
        XCTAssertEqual(second.waypoints[0].estimatedElapsedTime ?? 0, plan.waypoints[1].estimatedElapsedTime ?? 0,
                       accuracy: 1, "still timed against the easterly, with no forecast in the cache")
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

    // MARK: - Several stops at once (6.1)

    private func landing(_ candidate: TripPlanner.StopCandidate, minutes: Int = 30,
                         refuel: Bool = false) -> TripPlanner.Landing {
        TripPlanner.Landing(candidate: candidate, stopover: Stopover(groundMinutes: minutes, refuel: refuel))
    }

    /// "Land here" on a saved route: split at each aerodrome switched on, each leg keeping its part of
    /// the route, the first leg the plan's identity, the stops landed on at field elevation.
    func testLandingHereSplitsTheRouteAndEachLegKeepsItsWaypoints() {
        let plan = route(["AAAA", "W1", "BBBB", "W2", "CCCC", "W3", "DDDD"],
                         lons: [7.0, 7.3, 7.6, 7.9, 8.2, 8.5, 8.8])
        let found = TripPlanner.stopCandidates(along: plan.waypoints, aerodromes: [
            aerodrome("BBBB", lat: 47.0, lon: 7.6, elevation: 1400),
            aerodrome("CCCC", lat: 47.0, lon: 8.2, elevation: 1600),
        ])
        let legs = TripPlanner.legs(of: plan, landingAt: found.map { landing($0) })
        XCTAssertEqual(legs.map { $0.waypoints.map(\.name) },
                       [["AAAA", "W1", "BBBB"], ["BBBB", "W2", "CCCC"], ["CCCC", "W3", "DDDD"]])
        XCTAssertEqual(legs[0].id, plan.id, "the first leg is the flight itself")
        XCTAssertEqual(Set(legs.map(\.id)).count, 3)
        XCTAssertEqual(legs[0].waypoints.last?.altitude, 1400)
        XCTAssertEqual(legs[1].waypoints.first?.altitude, 1400)
        XCTAssertEqual(legs[1].waypoints[1].altitude, 5000, "the route's own altitudes are kept")
        XCTAssertEqual(legs[2].waypoints.first?.altitude, 1600)
        XCTAssertEqual(legs.dropFirst().map(\.departureIsEstimate), [true, true])
        XCTAssertEqual(legs.last?.alternateAerodrome, "LSGC", "the alternate stays with the destination")
    }

    func testWithNoLandingTheRouteStaysOneFlight() {
        let plan = route(["AAAA", "BBBB", "CCCC"], lons: [7.0, 7.3, 7.6])
        let legs = TripPlanner.legs(of: plan, landingAt: [])
        XCTAssertEqual(legs.count, 1)
        XCTAssertEqual(legs.first?.id, plan.id)
        XCTAssertEqual(legs.first?.waypoints.map(\.name), ["AAAA", "BBBB", "CCCC"])
    }

    /// Ticked in any order, the stops are landed at in the order the route reaches them, and each one
    /// keeps its own time on the ground: the second leg leaves when the first lands plus 45 min, the
    /// third when the second lands plus 0.
    func testSeveralStopsAreFlownInRouteOrderWithTheirOwnGroundTimes() throws {
        let plan = route(["AAAA", "W1", "W2", "W3", "DDDD"], lons: [7.0, 7.3, 7.6, 7.9, 8.2])
        let found = TripPlanner.stopCandidates(along: plan.waypoints, aerodromes: [
            aerodrome("LATE", lat: 47.05, lon: 7.75),      // abeam between W2 and W3, 3 NM north
            aerodrome("ERLY", lat: 47.0, lon: 7.3),        // is W1
        ])
        let late = try XCTUnwrap(found.first { $0.aerodrome.ident == "LATE" })
        let early = try XCTUnwrap(found.first { $0.aerodrome.ident == "ERLY" })
        let legs = TripPlanner.legs(of: plan, landingAt: [landing(late, minutes: 0), landing(early, minutes: 45)])
        XCTAssertEqual(legs.map { $0.waypoints.map(\.name) },
                       [["AAAA", "ERLY"], ["ERLY", "W2", "LATE"], ["LATE", "W3", "DDDD"]],
                       "W1 is the stop itself; the off-route field goes where it adds least")
        XCTAssertEqual(legs[1].stopover, Stopover(groundMinutes: 45))
        XCTAssertEqual(legs[2].stopover, Stopover(groundMinutes: 0))
        let landed1 = try XCTUnwrap(legs[0].waypoints.last?.estimatedTimeOver)
        let landed2 = try XCTUnwrap(legs[1].waypoints.last?.estimatedTimeOver)
        XCTAssertEqual(legs[1].plannedDepartureTime, landed1.addingTimeInterval(45 * 60))
        XCTAssertEqual(legs[2].plannedDepartureTime, landed2)
    }

    func testTwoOffRouteStopsAreBothInsertedWhereTheyAddLeast() {
        let plan = route(["AAAA", "W1", "W2", "DDDD"], lons: [7.0, 7.4, 7.8, 8.2])
        let found = TripPlanner.stopCandidates(along: plan.waypoints, aerodromes: [
            aerodrome("NRTH", lat: 47.05, lon: 7.2),
            aerodrome("STH2", lat: 46.95, lon: 8.0),
        ])
        let (updated, stops) = TripPlanner.routeStopping(at: found, in: plan)
        XCTAssertEqual(updated.waypoints.map(\.name), ["AAAA", "NRTH", "W1", "W2", "STH2", "DDDD"])
        XCTAssertEqual(stops.map(\.index), [1, 4])
        XCTAssertEqual(stops.map(\.candidate.aerodrome.ident), ["NRTH", "STH2"])
        XCTAssertEqual(TripPlanner.routeStopping(at: found + found, in: plan).stops.count, 2,
                       "an aerodrome ticked twice stops the route once")
    }

    /// Split one after the other, a refuel at the second stop used to bring back what the first leg
    /// left in the tanks. It brings back the route's planned fuel, as a single split does.
    func testARefuelAtALaterStopBringsBackThePlannedFuel() {
        let plan = route(["A", "B", "C", "D"], lons: [7.0, 7.3, 7.6, 7.9])
        let legs = TripPlanner.legs(of: plan, stops: [
            (index: 1, stopover: Stopover(refuel: false), ident: nil, elevation: nil),
            (index: 2, stopover: Stopover(refuel: true), ident: nil, elevation: nil),
        ])
        XCTAssertEqual(legs[1].fuelOnBoard!, 80 - legs[0].tripFuel!, accuracy: 0.001)
        XCTAssertEqual(legs[2].fuelOnBoard, 80)
    }

    // MARK: - Stops on a local flight (6.1)

    private func localFlight(lon: Double = 7.0) -> FlightPlan {
        var plan = FlightPlan(name: "HOME", plannedDepartureTime: t0, fuelFlow: 20, fuelOnBoard: 80)
        plan.waypoints = [FlightPlanWaypoint(name: "HOME", coordinate: .init(latitude: 47.0, longitude: lon),
                                             altitude: 1400, plannedGroundSpeed: 100)]
        return plan
    }

    func testALocalFlightListsTheAerodromesAroundItsFieldNearestFirst() {
        let home = localFlight().waypoints[0].coordinate
        let found = TripPlanner.stopCandidates(around: home, aerodromes: [
            aerodrome("FAR1", lat: 47.0, lon: 7.8),     // 32.7 NM
            aerodrome("NEAR", lat: 47.0, lon: 7.2),     // 8.2 NM
            aerodrome("HOME", lat: 47.0, lon: 7.005),   // the field itself
            aerodrome("GONE", lat: 47.0, lon: 8.1),     // 45 NM: beyond the radius
        ])
        XCTAssertEqual(found.map(\.aerodrome.ident), ["NEAR", "FAR1"])
        XCTAssertEqual(found[0].alongNM, 8.2, accuracy: 0.1, "the distance from the field")
        XCTAssertTrue(found.allSatisfy { $0.waypointIndex == nil })
        XCTAssertEqual(TripPlanner.localStopRadiusNM, 40)
    }

    /// LSZQ, then "Add a stop…" at LSGE and LSGN: out to each stop in the order ticked, and back home.
    func testALocalFlightFliesOutToItsStopsInTheOrderTickedAndBack() {
        let plan = localFlight()
        let found = TripPlanner.stopCandidates(around: plan.waypoints[0].coordinate, aerodromes: [
            aerodrome("NEAR", lat: 47.0, lon: 7.2, elevation: 1500),
            aerodrome("FAR1", lat: 47.1, lon: 7.6, elevation: 1700),
        ])
        let near = found[0], far = found[1]
        let legs = TripPlanner.legs(of: plan, landingAt: [landing(far, minutes: 45), landing(near)])
        XCTAssertEqual(legs.map { $0.waypoints.map(\.name) }, [["HOME", "FAR1"], ["FAR1", "NEAR"], ["NEAR", "HOME"]],
                       "the order ticked, not the nearest first")
        XCTAssertEqual(legs[0].id, plan.id)
        XCTAssertEqual(legs[0].waypoints.first?.altitude, 1400)
        XCTAssertEqual(legs[0].waypoints.last?.altitude, 1700, "a stop is landed on")
        XCTAssertEqual(legs[2].waypoints.last?.altitude, 1400, "back on the field it left")
        XCTAssertEqual(legs[2].waypoints.last?.coordinate.longitude, 7.0)
        XCTAssertNotEqual(legs[0].waypoints.first?.id, legs[2].waypoints.last?.id)
        XCTAssertEqual(legs[1].stopover?.groundMinutes, 45)
        XCTAssertTrue(legs.allSatisfy { $0.totalDistance > 5 && $0.totalEET > 0 })
        XCTAssertEqual(legs[1].plannedDepartureTime,
                       legs[0].waypoints.last?.estimatedTimeOver?.addingTimeInterval(45 * 60))
    }

    // MARK: - A leg's stop, edited after the trip exists (6.1)

    func testANewGroundTimeMovesTheLegsEstimatedDeparture() throws {
        let plan = route(["AAAA", "BBBB", "CCCC"], lons: [7.0, 7.3, 7.6])
        let (first, second) = TripPlanner.split(plan, at: 1, stopover: Stopover(groundMinutes: 30))!
        let edited = try XCTUnwrap(TripPlanner.settingStopover(Stopover(groundMinutes: 75), on: second,
                                                               after: first, plannedFOB: 80))
        XCTAssertEqual(edited.stopover, Stopover(groundMinutes: 75))
        XCTAssertEqual(edited.plannedDepartureTime, second.plannedDepartureTime?.addingTimeInterval(45 * 60))
        XCTAssertEqual(edited.departureIsEstimate, true)
        XCTAssertEqual(edited.waypoints.last?.estimatedTimeOver,
                       second.waypoints.last?.estimatedTimeOver?.addingTimeInterval(45 * 60), "its ETOs follow")
        XCTAssertNil(TripPlanner.settingStopover(Stopover(groundMinutes: 75), on: edited, after: first, plannedFOB: 80),
                     "no change, no write")
    }

    func testARefuelSetOnTheLegPageBringsBackTheTripsFuel() throws {
        let plan = route(["AAAA", "BBBB", "CCCC"], lons: [7.0, 7.3, 7.6])
        let (first, second) = TripPlanner.split(plan, at: 1)!
        let refuelled = try XCTUnwrap(TripPlanner.settingStopover(Stopover(refuel: true), on: second,
                                                                  after: first, plannedFOB: 80))
        XCTAssertEqual(refuelled.fuelOnBoard, 80)
        XCTAssertEqual(refuelled.plannedDepartureTime, second.plannedDepartureTime, "same time on the ground")
        let back = try XCTUnwrap(TripPlanner.settingStopover(Stopover(refuel: false), on: refuelled,
                                                             after: first, plannedFOB: 80))
        XCTAssertEqual(back.fuelOnBoard!, 80 - first.tripFuel!, accuracy: 0.001, "what the first leg leaves")
    }

    /// A departure the pilot chose stays through a refuel, and gives way to an estimate when the time
    /// on the ground changes: the last thing set counts.
    func testAChosenDepartureGivesWayOnlyToANewGroundTime() throws {
        let plan = route(["AAAA", "BBBB", "CCCC"], lons: [7.0, 7.3, 7.6])
        var (first, second) = TripPlanner.split(plan, at: 1)!
        let chosen = t0.addingTimeInterval(4 * 3600)
        second.plannedDepartureTime = chosen
        second.departureIsEstimate = false
        let refuelled = try XCTUnwrap(TripPlanner.settingStopover(Stopover(refuel: true), on: second,
                                                                  after: first, plannedFOB: 80))
        XCTAssertEqual(refuelled.plannedDepartureTime, chosen)
        XCTAssertEqual(refuelled.firmDepartureTime, chosen)

        let longer = try XCTUnwrap(TripPlanner.settingStopover(Stopover(groundMinutes: 60, refuel: true),
                                                               on: refuelled, after: first, plannedFOB: 80))
        XCTAssertEqual(longer.departureIsEstimate, true)
        XCTAssertEqual(longer.plannedDepartureTime,
                       first.waypoints.last?.estimatedTimeOver?.addingTimeInterval(3600))
        XCTAssertNil(longer.firmDepartureTime, "an estimate arms no reminder")

        first.plannedDepartureTime = nil
        first.calculateRouteData()
        let undated = try XCTUnwrap(TripPlanner.settingStopover(Stopover(groundMinutes: 90), on: second,
                                                                after: first, plannedFOB: 80))
        XCTAssertEqual(undated.firmDepartureTime, chosen, "with nothing to estimate from, the chosen time stays")
    }

    func testALegThatHasFlownKeepsItsStop() {
        let plan = route(["AAAA", "BBBB", "CCCC"], lons: [7.0, 7.3, 7.6])
        let (first, second) = TripPlanner.split(plan, at: 1)!
        let flown = second.anchoringETOs(on: t0.addingTimeInterval(2 * 3600))!
        XCTAssertNil(TripPlanner.settingStopover(Stopover(groundMinutes: 90), on: flown, after: first, plannedFOB: 80))
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
