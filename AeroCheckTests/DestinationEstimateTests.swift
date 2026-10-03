import XCTest
import CoreLocation
@testable import AeroCheck

/// The DEST line and the route to scale (6.2.0): `NextLegLive` (the NEXT cell's live leg), the plan
/// adapter, every case of `DestinationEstimator`, `RouteTrack` and the line's formatting.
///
/// The line's arithmetic, in short: remaining = live to NEXT + the planned legs after it; ETE = the
/// NEXT cell's ETE + the planned EETs after it, to OVER the destination (no arrival allowance); Δ =
/// the plan's time over the destination − ETA, ▲ ahead, ▼ behind.
final class DestinationEstimateTests: XCTestCase {

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

    // MARK: - A synthetic route

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// A → B → C → D: legs of 10, 20 and 30 NM; 15 min (10 + the 5-minute departure allowance), 20
    /// and 30 min. Over D at t0 + 65 min; the Flight Log's DEST ETO 5 minutes later. 1000 s flown.
    private func input(next: Int, live: Double?, gs: Double = 120) -> DestinationInput {
        DestinationInput(names: ["A", "B", "C", "D"],
                         legDistanceNM: [nil, 10, 20, 30],
                         legEET: [nil, 900, 1200, 1800],
                         nextIndex: next,
                         plannedOverDestination: t0.addingTimeInterval(3900),
                         plannedDestinationETO: t0.addingTimeInterval(4200),
                         destinationATO: nil,
                         diversionIdent: nil,
                         liveDistanceNM: live,
                         groundSpeedKnots: gs,
                         now: t0.addingTimeInterval(1000))
    }

    private func estimate(_ input: DestinationInput) throws -> DestinationEstimate {
        try XCTUnwrap(DestinationEstimator.estimate(input))
    }

    // MARK: - No line

    func testNoLineWithoutTwoWaypoints() {
        var single = input(next: 0, live: 1)
        single.names = ["A"]
        XCTAssertNil(DestinationEstimator.estimate(single))
        single.names = []
        XCTAssertNil(DestinationEstimator.estimate(single))
    }

    // MARK: - On the route

    /// Flying B → C, 5 NM from C at 120 kt: 150 s to C, then the 30-minute leg to D.
    func testOnRouteTheLiveLegPlusThePlannedLegsAfterIt() throws {
        let line = try estimate(input(next: 2, live: 5))
        XCTAssertEqual(line.kind, .route)
        XCTAssertEqual(line.ident, "D")
        XCTAssertEqual(try XCTUnwrap(line.remainingNM), 35, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(line.ete), 150 + 1800, accuracy: 1e-9)
        XCTAssertEqual(line.eta, t0.addingTimeInterval(1000 + 1950))
        XCTAssertEqual(line.plannedETO, t0.addingTimeInterval(3900), "over the field, not the Flight Log's ETO")
        XCTAssertEqual(line.plannedDestinationETO, t0.addingTimeInterval(4200))
        // Over D planned at 3900 s, estimated at 2950 s: 950 s ahead.
        XCTAssertEqual(try XCTUnwrap(line.delta), 950, accuracy: 1e-9)
    }

    /// The DEST ETE's first term is the NEXT cell's ETE, to the second.
    func testTheFirstTermIsTheNextCellsETE() throws {
        let line = try estimate(input(next: 2, live: 7.3, gs: 97))
        let next = try XCTUnwrap(NextLegLive(distanceNM: 7.3, groundSpeedKnots: 97))
        XCTAssertEqual(try XCTUnwrap(line.ete), next.ete + 1800, accuracy: 1e-9)
    }

    /// The last leg: the sums are empty. Δ is still against the time over the destination.
    func testOnTheLastLegTheLineIsTheNextCell() throws {
        let line = try estimate(input(next: 3, live: 12))
        XCTAssertEqual(try XCTUnwrap(line.remainingNM), 12, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(line.ete), 360, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(line.delta), 3900 - 1360, accuracy: 1e-9)
    }

    /// Until the take-off marks the departure, the departure is the target: every leg counts, and leg 1
    /// carries the departure allowance.
    func testBeforeTheDepartureIsMarkedEveryLegCounts() throws {
        let line = try estimate(input(next: 0, live: 0.3, gs: 35))
        XCTAssertEqual(try XCTUnwrap(line.remainingNM), 60.3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(line.ete), 0.3 / 35 * 3600 + 900 + 1200 + 1800, accuracy: 1e-9)
        XCTAssertEqual(line.track?.flown, 0)
        XCTAssertEqual(line.track?.nextIndex, 0)
    }

    // MARK: - Below 30 kt

    /// On the ground, taxiing or hovering: the distance and the plan's ETO, no ETE, ETA or Δ.
    func testBelowThirtyKnotsTheLineShowsThePlansETO() throws {
        for gs in [0, 8, 29.9] {
            let line = try estimate(input(next: 2, live: 5, gs: gs))
            XCTAssertEqual(try XCTUnwrap(line.remainingNM), 35, accuracy: 1e-9, "\(gs) kt")
            XCTAssertNil(line.ete, "\(gs) kt")
            XCTAssertNil(line.eta, "\(gs) kt")
            XCTAssertNil(line.delta, "\(gs) kt")
            XCTAssertEqual(line.plannedETO, t0.addingTimeInterval(3900), "\(gs) kt")
        }
        XCTAssertNotNil(try estimate(input(next: 2, live: 5, gs: 30)).ete, "30 kt is enough, as for the NEXT cell")
    }

    // MARK: - No fix

    /// No fix: the leg to NEXT counts whole, and nothing is timed.
    func testWithNoFixTheLegToNextCountsWhole() throws {
        let line = try estimate(input(next: 2, live: nil))
        XCTAssertEqual(try XCTUnwrap(line.remainingNM), 50, accuracy: 1e-9)
        XCTAssertNil(line.ete)
        XCTAssertNil(line.eta)
        XCTAssertNil(line.delta)
        XCTAssertEqual(line.plannedETO, t0.addingTimeInterval(3900))
        // The aircraft at the waypoint it last passed: B, 10 of 60 NM.
        XCTAssertEqual(try XCTUnwrap(line.track?.flown), 10.0 / 60, accuracy: 1e-12)
    }

    // MARK: - A planned EET missing

    /// A leg after NEXT without an EET leaves the ETE unknown, not short. The distance still shows.
    func testAMissingEETAfterNextLeavesNoETE() throws {
        var missing = input(next: 2, live: 5)
        missing.legEET[3] = nil
        let line = try estimate(missing)
        XCTAssertNil(line.ete)
        XCTAssertNil(line.eta)
        XCTAssertNil(line.delta)
        XCTAssertEqual(try XCTUnwrap(line.remainingNM), 35, accuracy: 1e-9)
    }

    /// The leg being flown is timed live: its own planned EET is not needed.
    func testAMissingEETOnTheLegBeingFlownChangesNothing() throws {
        var missing = input(next: 2, live: 5)
        missing.legEET[2] = nil
        missing.legEET[1] = nil
        XCTAssertEqual(try estimate(missing), try estimate(input(next: 2, live: 5)))
    }

    // MARK: - Diverting

    /// DEST is the field, straight there: no plan time, no Δ, no track.
    func testDivertingTheLineIsTheFieldStraightThere() throws {
        var diverting = input(next: 2, live: 8, gs: 100)
        diverting.diversionIdent = "LSGC"
        let line = try estimate(diverting)
        XCTAssertEqual(line.kind, .diversion)
        XCTAssertEqual(line.ident, "LSGC")
        XCTAssertEqual(line.remainingNM, 8)
        XCTAssertEqual(try XCTUnwrap(line.ete), 288, accuracy: 1e-9)
        XCTAssertEqual(line.eta, t0.addingTimeInterval(1288))
        XCTAssertNil(line.plannedETO)
        XCTAssertNil(line.delta)
        XCTAssertNil(line.track, "the route to scale hides while diverting")
    }

    func testDivertingWithNoFixShowsNoDistance() throws {
        var diverting = input(next: 2, live: nil, gs: 100)
        diverting.diversionIdent = "LSGC"
        let line = try estimate(diverting)
        XCTAssertNil(line.remainingNM)
        XCTAssertNil(line.ete)
    }

    /// Below 30 kt the field is not timed either: the same rule as the NEXT cell (the old DEST summary
    /// needed more than 30 kt here, and 30 or more on the NEXT cell).
    func testDivertingBelowThirtyKnotsIsNotTimed() throws {
        var diverting = input(next: 2, live: 8, gs: 29)
        diverting.diversionIdent = "LSGC"
        XCTAssertNil(try estimate(diverting).ete)
        diverting.groundSpeedKnots = 30
        XCTAssertNotNil(try estimate(diverting).ete)
    }

    // MARK: - Completed

    /// The destination marked: nothing left, the full track, and the final Δ from the ATO.
    func testOnceTheDestinationIsMarkedTheLineGivesTheFinalDelta() throws {
        var done = input(next: 4, live: nil)
        done.destinationATO = t0.addingTimeInterval(3900 + 120)
        let line = try estimate(done)
        XCTAssertEqual(line.kind, .completed)
        XCTAssertEqual(line.ident, "D")
        XCTAssertEqual(line.remainingNM, 0)
        XCTAssertNil(line.ete)
        XCTAssertNil(line.eta)
        XCTAssertEqual(line.delta, -120)
        XCTAssertEqual(line.track?.flown, 1)
        XCTAssertNil(line.track?.nextIndex)
        XCTAssertEqual(DestinationFormat.delta(-120).text, "▼2")
    }

    func testCompletedWithoutAnATOHasNoDelta() throws {
        XCTAssertNil(try estimate(input(next: 4, live: nil)).delta)
    }

    // MARK: - Ahead or behind: the leg rows' convention

    func testDeltaReadsInWholeMinutesWithTheLegRowsSigns() {
        XCTAssertEqual(DestinationFormat.delta(180).text, "▲3")
        XCTAssertEqual(DestinationFormat.delta(180).tone, .ahead)
        XCTAssertEqual(DestinationFormat.delta(-240).text, "▼4")
        XCTAssertEqual(DestinationFormat.delta(-240).tone, .behind)
        XCTAssertEqual(DestinationFormat.delta(0).text, "±0")
        XCTAssertEqual(DestinationFormat.delta(0).tone, .even)
        // Under half a minute either way is on time; a minute and a half is two.
        XCTAssertEqual(DestinationFormat.delta(29).text, "±0")
        XCTAssertEqual(DestinationFormat.delta(-29).text, "±0")
        XCTAssertEqual(DestinationFormat.delta(-29).tone, .even)
        XCTAssertEqual(DestinationFormat.delta(90).text, "▲2")
        XCTAssertEqual(DestinationFormat.delta(-90).text, "▼2")
        XCTAssertEqual(DestinationFormat.delta(.nan).text, "±0", "never a trap on a bad figure")
    }

    // MARK: - Formatting

    func testTheLinesValuesAreWrittenAsTheNextCellWritesThem() {
        XCTAssertEqual(DestinationFormat.distance(82.6), "83 NM")
        XCTAssertEqual(DestinationFormat.distance(0), "0 NM")
        XCTAssertEqual(DestinationFormat.eteValue(42 * 60), "42")
        XCTAssertEqual(DestinationFormat.eteUnit(42 * 60), "min")
        XCTAssertEqual(DestinationFormat.eteValue(67 * 60), "1:07")
        XCTAssertEqual(DestinationFormat.eteUnit(67 * 60), "h")
        XCTAssertEqual(DestinationFormat.eteValue(59 * 60 + 40), "1:00", "59:40 rounds to the hour")
        XCTAssertEqual(DestinationFormat.clock(t0), NextWaypointReadout.eta(t0))
    }

    // MARK: - NextLegLive

    func testNextLegLiveNeedsAFixAndThirtyKnots() throws {
        XCTAssertNil(NextLegLive.ete(distanceNM: nil, groundSpeedKnots: 120))
        XCTAssertNil(NextLegLive.ete(distanceNM: 10, groundSpeedKnots: 29.99))
        XCTAssertNil(NextLegLive.ete(distanceNM: 10, groundSpeedKnots: .nan))
        XCTAssertNil(NextLegLive.ete(distanceNM: .infinity, groundSpeedKnots: 100))
        XCTAssertEqual(NextLegLive.ete(distanceNM: 10, groundSpeedKnots: 30), 1200)
        let live = try XCTUnwrap(NextLegLive(distanceNM: 10, groundSpeedKnots: 120, now: t0))
        XCTAssertEqual(live.ete, 300)
        XCTAssertEqual(live.eta, t0.addingTimeInterval(300))
    }

    // MARK: - The plan adapter, on a real plan

    /// LSZQ → (an unnamed point) → E → LSGC, timed as the planner times it: no wind, the standard
    /// cruise and the 5-minute allowances.
    private func juraPlan(departure: Date) -> FlightPlan {
        var plan = FlightPlan(
            name: "LSZQ → LSGC",
            waypoints: [
                FlightPlanWaypoint(name: "LSZQ", coordinate: .init(latitude: 47.4247, longitude: 7.1869)),
                FlightPlanWaypoint(name: "", coordinate: .init(latitude: 47.20, longitude: 7.00)),
                FlightPlanWaypoint(name: "E", coordinate: .init(latitude: 47.00, longitude: 6.90)),
                FlightPlanWaypoint(name: "LSGC", coordinate: .init(latitude: 47.0839, longitude: 6.7928)),
            ],
            plannedDepartureTime: departure)
        plan.calculateRouteData()
        return plan
    }

    /// The leg data as the leg rows read it: on the departure waypoint of each leg.
    func testThePlanAdapterReadsTheLegsAsTheLegRowsDo() throws {
        let plan = juraPlan(departure: t0)
        let input = DestinationInput(plan: plan, location: nil, groundSpeedKnots: 0, now: t0)
        XCTAssertEqual(input.names, ["LSZQ", "WPT 2", "E", "LSGC"])
        XCTAssertNil(input.legDistanceNM[0])
        XCTAssertNil(input.legEET[0])
        for index in 1...3 {
            XCTAssertEqual(input.legDistanceNM[index], plan.waypoints[index - 1].distance, "leg \(index)")
            XCTAssertEqual(input.legDistanceNM[index], plan.legArriving(at: index)?.distance, "leg \(index)")
        }
        // Leg 1 carries the departure allowance; the last leg, no arrival allowance.
        let eet = plan.waypoints.map { $0.estimatedElapsedTime ?? -1 }
        XCTAssertEqual(try XCTUnwrap(input.legEET[1]), eet[0] + 300, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(input.legEET[2]), eet[1], accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(input.legEET[3]), eet[2], accuracy: 1e-9)
        XCTAssertEqual(plan.waypoints[3].legEETExtra, 300, "the arrival allowance sits on the destination")
        XCTAssertEqual(input.nextIndex, 0)
        XCTAssertNil(input.diversionIdent)
    }

    /// The time over the destination leaves the arrival allowance out; the Flight Log's ETO keeps it.
    func testThePlannedTimeOverTheDestinationLeavesTheArrivalAllowanceOut() throws {
        let plan = juraPlan(departure: t0)
        let input = DestinationInput(plan: plan, location: nil, groundSpeedKnots: 0, now: t0)
        let over = try XCTUnwrap(input.plannedOverDestination)
        let legs = input.legEET.compactMap { $0 }.reduce(0, +)
        XCTAssertEqual(over.timeIntervalSince(t0), legs, accuracy: 1e-6)
        XCTAssertEqual(input.plannedDestinationETO, plan.estimatedTimeOver(at: 3))
        XCTAssertEqual(try XCTUnwrap(input.plannedDestinationETO).timeIntervalSince(over), 300, accuracy: 1e-6)
    }

    /// With a missing EET the adapter says so rather than reading 0 (`totalLegEET` would).
    func testTheAdapterKeepsAMissingEETMissing() {
        var plan = juraPlan(departure: t0)
        plan.waypoints[1].estimatedElapsedTime = nil
        let input = DestinationInput(plan: plan, location: nil, groundSpeedKnots: 0, now: t0)
        XCTAssertNil(input.legEET[2])
        XCTAssertNotNil(input.legEET[3])
    }

    /// The live distance is the NEXT cell's: `FlightPlanManager.distanceToNextWaypoint` with the plan
    /// active, to the next waypoint and, diverting, to the field.
    @MainActor
    func testTheLiveDistanceIsTheNextCellsDistance() throws {
        let manager = makeTestPlanManager()
        var plan = juraPlan(departure: t0)
        plan.currentWaypointIndex = 2
        manager.activeFlightPlan = plan
        let here = CLLocation(latitude: 47.15, longitude: 6.97)
        let input = DestinationInput(plan: plan, location: here, groundSpeedKnots: 100, now: t0)
        XCTAssertEqual(try XCTUnwrap(input.liveDistanceNM),
                       try XCTUnwrap(manager.distanceToNextWaypoint(from: here)), accuracy: 1e-12)

        plan.diversion = Diversion(ident: "LSGN", name: "Neuchâtel", latitude: 46.9575, longitude: 6.8647,
                                   leftRouteAt: 2)
        manager.activeFlightPlan = plan
        let diverting = DestinationInput(plan: plan, location: here, groundSpeedKnots: 100, now: t0)
        XCTAssertEqual(diverting.diversionIdent, "LSGN")
        XCTAssertEqual(try XCTUnwrap(diverting.liveDistanceNM),
                       try XCTUnwrap(manager.distanceToNextWaypoint(from: here)), accuracy: 1e-12)
        XCTAssertNil(DestinationInput(plan: plan, location: nil, groundSpeedKnots: 100, now: t0).liveDistanceNM)
    }

    /// `NextLegLive` gives exactly the ETE the NEXT cell shows today: `etaToNextWaypoint` at 30 kt or more.
    @MainActor
    func testNextLegLiveIsTheNextCellsETE() throws {
        let manager = makeTestPlanManager()
        var plan = juraPlan(departure: t0)
        plan.currentWaypointIndex = 2
        manager.activeFlightPlan = plan
        let here = CLLocation(latitude: 47.15, longitude: 6.97)
        let distance = manager.distanceToNextWaypoint(from: here)
        for gs in [30.0, 64.5, 97, 135] {
            XCTAssertEqual(NextLegLive.ete(distanceNM: distance, groundSpeedKnots: gs),
                           manager.etaToNextWaypoint(from: here, groundSpeedKnots: gs), "\(gs) kt")
        }
        XCTAssertNotNil(manager.etaToNextWaypoint(from: here, groundSpeedKnots: 29))
        XCTAssertNil(NextLegLive.ete(distanceNM: distance, groundSpeedKnots: 29), "the cell's 30 kt rule")
    }

    /// Over waypoint 1 at its ETO, flying the next leg at its planned ground speed: the line's ETA is
    /// the plan's time over the destination, Δ ±0.
    func testFlownToThePlanTheDeltaIsEven() throws {
        var plan = juraPlan(departure: t0)
        plan.currentWaypointIndex = 2
        let overWaypoint1 = try XCTUnwrap(plan.estimatedTimeOver(at: 1))
        let leg = try XCTUnwrap(plan.legArriving(at: 2))
        let plannedGS = try XCTUnwrap(leg.distance) / XCTUnwrap(leg.estimatedElapsedTime) * 3600
        let atWaypoint1 = CLLocation(latitude: plan.waypoints[1].latitude, longitude: plan.waypoints[1].longitude)
        let line = try estimate(DestinationInput(plan: plan, location: atWaypoint1, groundSpeedKnots: plannedGS,
                                                 now: overWaypoint1))
        XCTAssertEqual(try XCTUnwrap(line.delta), 0, accuracy: 0.5)
        XCTAssertEqual(DestinationFormat.delta(try XCTUnwrap(line.delta)).text, "±0")
        // And the distance is the rest of the route.
        let rest = (2...3).compactMap { plan.legArriving(at: $0)?.distance }.reduce(0, +)
        XCTAssertEqual(try XCTUnwrap(line.remainingNM), rest, accuracy: 1e-6)
    }

    // MARK: - The route to scale

    /// The track's magenta notch has a name, for VoiceOver ("12 of 83 NM flown, next C"): the waypoint
    /// flown to, the departure until the take-off marks it; none diverting or once the destination is
    /// marked. (6.2, the DEST line's view)
    func testTheEstimateNamesTheWaypointFlownTo() throws {
        XCTAssertEqual(try estimate(input(next: 2, live: 5)).nextIdent, "C")
        XCTAssertEqual(try estimate(input(next: 0, live: 0.3, gs: 8)).nextIdent, "A")
        XCTAssertEqual(try estimate(input(next: 3, live: nil)).nextIdent, "D")
        var diverting = input(next: 2, live: 8)
        diverting.diversionIdent = "LSGC"
        XCTAssertNil(try estimate(diverting).nextIdent)
        XCTAssertNil(try estimate(input(next: 4, live: nil)).nextIdent)
    }

    func testTheNotchesSitAtEachWaypointsDistanceAlongTheRoute() throws {
        let track = try XCTUnwrap(RouteTrack.make(legDistanceNM: [nil, 10, 20, 30], nextIndex: 2,
                                                  remainingNM: 35, diverting: false))
        XCTAssertEqual(track.notches, [0, 10.0 / 60, 30.0 / 60, 1])
        XCTAssertEqual(track.nextIndex, 2)
        XCTAssertEqual(track.totalNM, 60)
        XCTAssertFalse(track.isPartial)
        XCTAssertEqual(track.flown, 25.0 / 60, accuracy: 1e-12)
        XCTAssertEqual(track.flownNM, 25, accuracy: 1e-9)
    }

    /// Between two waypoints, flown + remaining = total, so the bar and the numbers agree.
    func testFlownAndRemainingAddUpToTheRoute() throws {
        for next in 1...3 {
            let legs: [Double?] = [nil, 10, 20, 30]
            for live in stride(from: 0.0, through: legs[next]!, by: 2.5) {
                let line = try estimate(input(next: next, live: live))
                let track = try XCTUnwrap(line.track)
                XCTAssertEqual(track.flownNM + (line.remainingNM ?? .nan), track.totalNM, accuracy: 1e-9,
                               "next \(next), \(live) NM to go")
            }
        }
    }

    /// Off the line between the waypoints, the aircraft is held between them.
    func testTheFlownPartStaysBetweenTheWaypointsFlownBetween() throws {
        // Behind B (further than the whole leg from C): held at B.
        let behind = try XCTUnwrap(RouteTrack.make(legDistanceNM: [nil, 10, 20, 30], nextIndex: 2,
                                                   remainingNM: 30 + 26, diverting: false))
        XCTAssertEqual(behind.flown, 10.0 / 60, accuracy: 1e-12)
        // Remaining under what is after C: held at C.
        let beyond = try XCTUnwrap(RouteTrack.make(legDistanceNM: [nil, 10, 20, 30], nextIndex: 2,
                                                   remainingNM: 25, diverting: false))
        XCTAssertEqual(beyond.flown, 30.0 / 60, accuracy: 1e-12)
    }

    func testTheFlownPartAtEitherEnd() throws {
        let before = try XCTUnwrap(RouteTrack.make(legDistanceNM: [nil, 10, 20, 30], nextIndex: 0,
                                                   remainingNM: 60.4, diverting: false))
        XCTAssertEqual(before.flown, 0)
        let after = try XCTUnwrap(RouteTrack.make(legDistanceNM: [nil, 10, 20, 30], nextIndex: 4,
                                                  remainingNM: 0, diverting: false))
        XCTAssertEqual(after.flown, 1)
        XCTAssertNil(after.nextIndex)
    }

    func testNoTrackWhileDivertingOrForARouteWithNoLength() {
        XCTAssertNil(RouteTrack.make(legDistanceNM: [nil, 10, 20], nextIndex: 1, remainingNM: 25, diverting: true))
        XCTAssertNil(RouteTrack.make(legDistanceNM: [nil, 0, nil], nextIndex: 1, remainingNM: 0, diverting: false))
        XCTAssertNil(RouteTrack.make(legDistanceNM: [nil], nextIndex: 0, remainingNM: 0, diverting: false))
    }

    /// A leg without a planned distance has no length on the track, and the track says it is partial.
    func testALegWithoutADistanceIsDrawnWithNoLength() throws {
        let track = try XCTUnwrap(RouteTrack.make(legDistanceNM: [nil, 10, nil, 30], nextIndex: 3,
                                                  remainingNM: nil, diverting: false))
        XCTAssertEqual(track.notches, [0, 0.25, 0.25, 1])
        XCTAssertTrue(track.isPartial)
        XCTAssertEqual(track.flown, 0.25, "no fix: at the waypoint last passed")
    }
}
