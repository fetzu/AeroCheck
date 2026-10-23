import XCTest
import CoreLocation
@testable import AeroCheck

/// Free practice (6.4.0): the aerodromes a dry run can fly from the app's data, the choice on final, Next
/// check, a route that follows the Cockpit, the end's summary, the band's place, and where it all shows.
@MainActor
final class DryRunPracticeTests: XCTestCase {

    override func tearDown() {
        FlightClock.endVirtual()
        DryRunCenter.shared.end()
        DryRunCenter.shared.discardPrepared()
        DryRunCenter.shared.startRequest = nil
        super.tearDown()
    }

    private let lsgc = DryRunAerodrome.make(
        ident: "LSGC", name: "Les Eplatures", reference: CLLocationCoordinate2D(latitude: 47.0839, longitude: 6.79284),
        elevationFt: 3368, heading: 241, lengthM: 1130, circuitSide: .right)
    private let ins = CLLocationCoordinate2D(latitude: 47.0240, longitude: 7.1620)

    // MARK: - Aerodromes from the app's data

    private func airport(_ ident: String, _ latitude: Double, _ longitude: Double, elevation: Int) -> Airport {
        Airport(id: 1, ident: ident, type: .smallAirport, name: ident, latitude: latitude, longitude: longitude,
                elevation: elevation, continent: "EU", isoCountry: "CH", isoRegion: "", municipality: nil,
                scheduledService: false, gpsCode: ident, iataCode: nil, localCode: nil)
    }

    private func runway(_ le: String, _ he: String, lengthFt: Int, closed: Bool = false,
                        leEnd: (Double, Double)? = nil, heEnd: (Double, Double)? = nil,
                        leHeading: Double? = nil) -> Runway {
        Runway(id: 1, airportRef: 1, airportIdent: "X", lengthFt: lengthFt, widthFt: 60, surface: "ASP",
               lighted: false, closed: closed, leIdent: le, leLatitude: leEnd?.0, leLongitude: leEnd?.1,
               leElevationFt: nil, leHeadingDegT: leHeading, leDisplacedThresholdFt: nil, heIdent: he,
               heLatitude: heEnd?.0, heLongitude: heEnd?.1, heElevationFt: nil,
               heHeadingDegT: leHeading.map { ($0 + 180).truncatingRemainder(dividingBy: 360) },
               heDisplacedThresholdFt: nil, pcn: nil, leToraFt: nil, leLdaFt: nil, heToraFt: nil, heLdaFt: nil)
    }

    /// LSZQ's powered circuit as open flightmaps draws it, from the 25 end round to the 07 threshold.
    private func lszqCircuit(reversed: Bool = false) throws -> VFRProcedure {
        var points = [(7.03373, 47.39356), (7.05466, 47.39851), (7.05579, 47.4001), (7.04636, 47.41809),
                      (7.044, 47.41884), (6.98485, 47.40447), (6.98375, 47.40284), (6.99369, 47.38507),
                      (6.99602, 47.38434), (7.02427, 47.39125)]
        if reversed { points.reverse() }
        let line = points.map { "[\($0.0), \($0.1)]" }.joined(separator: ", ")
        return try JSONDecoder().decode(VFRProcedure.self, from: Data("""
        {"id": "c", "ad": "LSZQ", "kind": "circuit", "name": "LSZQ circuit", "use": "fw", "cat": null, "alt": 2900,
         "line": [\(line)]}
        """.utf8))
    }

    func testAnAerodromeFromTheAppsDataFliesTheRunwayItsCircuitLandsOn() throws {
        let field = airport("LSZQ", 47.392408, 7.028956, elevation: 1866)
        let rwy = runway("07", "25", lengthFt: 2483, leEnd: (47.39125, 7.02427), heEnd: (47.39356, 7.03373))
        let made = try XCTUnwrap(DryRunAerodrome.make(airport: field, runways: [rwy], circuits: [lszqCircuit()]))
        XCTAssertEqual(made.threshold.latitude, DryRunAerodrome.lszq.threshold.latitude, accuracy: 1e-6)
        XCTAssertEqual(made.circuitSide, .left)
        XCTAssertEqual(made.patternAltitudeFt, 2900)
        XCTAssertEqual(made.runwayHeading, DryRunAerodrome.lszq.runwayHeading, accuracy: 0.5)

        // The same circuit drawn the other way lands on 25.
        let other = try XCTUnwrap(DryRunAerodrome.make(airport: field, runways: [rwy], circuits: [lszqCircuit(reversed: true)]))
        XCTAssertEqual(other.threshold.latitude, 47.39356, accuracy: 1e-6)
        XCTAssertEqual(other.runwayHeading, (DryRunAerodrome.lszq.runwayHeading + 180).truncatingRemainder(dividingBy: 360), accuracy: 0.5)
    }

    func testWithoutACircuitTheLongestRunwayFromItsLowEndLeftHand() throws {
        let field = airport("LSXX", 47, 7, elevation: 1500)
        let short = runway("09", "27", lengthFt: 1500, leEnd: (47.0, 6.995), heEnd: (47.0, 7.005))
        let long = runway("18", "36", lengthFt: 3000, leEnd: (47.006, 7.0), heEnd: (46.994, 7.0))
        let made = try XCTUnwrap(DryRunAerodrome.make(airport: field, runways: [short, long]))
        XCTAssertEqual(made.runwayHeading, 180, accuracy: 0.5, "the longest, from its low end")
        XCTAssertEqual(made.circuitSide, .left)
        XCTAssertEqual(made.patternAltitudeFt, 2500)
    }

    /// A US field without an open flightmaps circuit flies its NASR pattern: the side of the runway it lands on and the
    /// field's TPA, where every such dry run flew left-hand at 1,000 ft (the author's v65-17, 23 Oct 2026). (6.5.0)
    func testAUSFieldFliesItsNASRPattern() throws {
        let field = airport("KXXX", 37, -122, elevation: 7)
        let rwy = runway("04", "22", lengthFt: 2500, leEnd: (36.997, -122.003), heEnd: (37.003, -121.997))
        let pattern = NASRPatterns.Aerodrome(tpa: .init(agl: 800, msl: 807),
                                             ends: [.init(rwy: "04", pattern: .right), .init(rwy: "22", pattern: .left)])
        let made = try XCTUnwrap(DryRunAerodrome.make(airport: field, runways: [rwy], pattern: pattern))
        XCTAssertEqual(made.runwayHeading, 39, accuracy: 3, "the low end, 04")
        XCTAssertEqual(made.circuitSide, .right, "04's pattern")
        XCTAssertEqual(made.patternAltitudeFt, 807)
        // No NASR entry: as before.
        let plain = try XCTUnwrap(DryRunAerodrome.make(airport: field, runways: [rwy]))
        XCTAssertEqual(plain.circuitSide, .left)
        XCTAssertEqual(plain.patternAltitudeFt, 1007)
    }

    func testOnlyAHeadingLaysTheRunwayOutOnTheReferencePoint() throws {
        let field = airport("LSXY", 46.9, 7.4, elevation: 1700)
        let made = try XCTUnwrap(DryRunAerodrome.make(airport: field, runways: [runway("14", "32", lengthFt: 2600, leHeading: 141)]))
        XCTAssertEqual(made.runwayHeading, 141, accuracy: 0.5)
        XCTAssertLessThan(DryRunGeo.distance(made.runwayCentre, made.reference), 5)
    }

    /// Bellechasse (LSTB): OurAirports gives 08/26 and a length, no ends and no heading, and open flightmaps no
    /// thresholds. The designator lays it out, as for some 16,000 aerodromes in the data.
    func testOnlyADesignatorLaysTheRunwayOutOnTheReferencePoint() throws {
        let field = airport("LSTB", 46.979, 7.081, elevation: 1421)
        let made = try XCTUnwrap(DryRunAerodrome.make(airport: field, runways: [runway("08", "26", lengthFt: 1608)]))
        XCTAssertEqual(made.runwayHeading, 80, accuracy: 0.5)
        XCTAssertEqual(made.runwayLengthM, 490, accuracy: 2)
        XCTAssertLessThan(DryRunGeo.distance(made.runwayCentre, made.reference), 5)

        XCTAssertEqual(DryRunAerodrome.designatorHeading("26L"), 260)
        XCTAssertEqual(DryRunAerodrome.designatorHeading("36"), 0)
        XCTAssertEqual(DryRunAerodrome.designatorHeading("7"), 70)
        XCTAssertNil(DryRunAerodrome.designatorHeading("H1"))
        XCTAssertNil(DryRunAerodrome.designatorHeading("N"))
        XCTAssertNil(DryRunAerodrome.designatorHeading("37"))
        // A helipad's "H1" never makes a runway, however long the data says it is.
        XCTAssertNil(DryRunAerodrome.make(airport: field, runways: [runway("H1", "H1", lengthFt: 600)]))
    }

    func testNoOpenRunwayNoDryRunButOpenFlightmapsThresholdsWillDo() throws {
        let field = airport("LSXZ", 47, 7, elevation: 1500)
        XCTAssertNil(DryRunAerodrome.make(airport: field, runways: [runway("09", "27", lengthFt: 2000, closed: true,
                                                                        leEnd: (47, 6.99), heEnd: (47, 7.01))]))
        XCTAssertNil(DryRunAerodrome.make(airport: field, runways: []))
        let thresholds = [VFRThreshold(runway: "09", position: VFRCoordinate(latitude: 47, longitude: 6.99), trueBearing: 90),
                          VFRThreshold(runway: "27", position: VFRCoordinate(latitude: 47, longitude: 7.01), trueBearing: 270)]
        let made = try XCTUnwrap(DryRunAerodrome.make(airport: field, runways: [], thresholds: thresholds))
        XCTAssertEqual(made.runwayLengthM, 1517, accuracy: 10)
    }

    func testRunwayEndsAreTheSameWrittenEitherWay() {
        XCTAssertTrue(DryRunAerodrome.sameRunwayEnd("07", "7"))
        XCTAssertTrue(DryRunAerodrome.sameRunwayEnd("25L", "25 L"))
        XCTAssertFalse(DryRunAerodrome.sameRunwayEnd("07", "25"))
        XCTAssertFalse(DryRunAerodrome.sameRunwayEnd("25L", "25R"))
    }

    // MARK: - The choice on final

    /// Asked once a final, at 250 ft above the field, not at its start: the pilot has the final to choose.
    func testTheLandingIsAskedAt250FeetOncePerFinal() {
        let generator = DryRunGenerator(departure: .lszq, mission: .circuits, seed: 3)
        var heights: [Double] = []
        var lastAltitudeM = 0.0
        var onFinalSeen = 0
        var answers: [DryRunGenerator.Landing] = [.goAround, .fullStop]
        generator.pilot.landing = { field in
            heights.append(lastAltitudeM / DryRunGeo.metresPerFoot - field.elevationFt)
            return answers.isEmpty ? .fullStop : answers.removeFirst()
        }
        generator.pilot.afterFullStop = { _ in .vacate }
        var wasOnFinal = false
        for _ in 0..<(2 * 3600) where !generator.isParkedForGood {
            lastAltitudeM = generator.nextFix().altitudeM
            if generator.isOnFinal, !wasOnFinal { onFinalSeen += 1 }
            wasOnFinal = generator.isOnFinal
        }
        XCTAssertEqual(heights.count, 2, "asked on each final")
        XCTAssertEqual(onFinalSeen, 2)
        for height in heights { XCTAssertLessThan(height, 280); XCTAssertGreaterThan(height, 150) }
        XCTAssertNotNil(generator.mark("goAround"))
        XCTAssertNotNil(generator.mark("touchdown"))
    }

    /// The author's seventh round (r7-14): straight to the line up check from the phase bar, ENGINE START never
    /// pressed, the aircraft stayed parked; once it moved, the roll began with the line up check still open.
    func testAPilotWhoJumpsToTheLineUpCheckTakesOffOnceItIsDone() throws {
        let flight = try DryRunHeadless(self, setup: DryRunSetup(mission: .circuits(.lszq), rate: 0))
        flight.wait(5)
        flight.appState.goToPhase(.lineUp)
        XCTAssertTrue(flight.fly(until: { flight.session.generator.waitingAt == .takeoff }, within: 400), "lined up")
        flight.wait(30)
        XCTAssertNil(flight.session.generator.mark("takeoffRoll"), "the line up check first")
        XCTAssertTrue(flight.session.isWaiting)
        DryRunCoach.workThroughCurrentCheck(flight.appState)
        XCTAssertTrue(flight.fly(until: { flight.session.generator.isAirborne }, within: 120), "then the roll")
    }

    /// The author's eighth round (r8-3, r8-4): on the iPad the go-arounds were neither counted nor taken (the
    /// checks stayed at the after landing check), while touch-and-goes and full stops were. A device whose timer
    /// fires late feeds the fixes in batches; each must reach the detector at its own time, or it keeps one fix a
    /// batch and misses the go-around's dip.
    func testFixesFedInBatchesStillShowTheGoAround() throws {
        let flight = try DryRunHeadless(self, setup: DryRunSetup(mission: .circuits(.lszq), rate: 0, landings: [.goAround]))
        flight.takeOff()
        let generator = flight.session.generator
        XCTAssertTrue(flight.fly(until: { flight.session.isOnFinal }, within: 1500))
        flight.appState.goToPhase(.landing)
        DryRunCoach.workThroughCurrentCheck(flight.appState)
        flight.appState.nextPhase()
        XCTAssertEqual(flight.appState.currentPhase, .afterLanding, "the landing check done before the go-around")
        flight.waitInBatches(of: 30, count: 12)
        XCTAssertNotNil(generator.mark("goAround"))
        XCTAssertEqual(flight.appState.currentFlight?.goAroundCount, 1, "\(flight.world.detector.emittedEvents)")
        XCTAssertEqual(flight.appState.currentPhase, .climb, "back to the climb check")
        XCTAssertEqual(flight.appState.circuitLoopMarks?.touchAndGoes, 1, "counted on the loop over the bar")
        XCTAssertGreaterThan(flight.appState.currentFlight?.gpsTrack.count ?? 0, 100, "the track as dense as fix by fix")
    }

    /// The card's choice is what the aircraft does, and each final starts on a full stop again.
    func testTheCardOnFinalDecidesAndEachFinalStartsOnAFullStop() throws {
        let flight = try DryRunHeadless(self, setup: DryRunSetup(mission: .circuits(.lszq), rate: 0))
        flight.takeOff()
        XCTAssertTrue(flight.fly(until: { flight.session.isOnFinal }, within: 900), "on final")
        XCTAssertEqual(flight.session.finalChoice, .fullStop)
        // The flight waits for the pilot's pick (r6-19: at 30× the card came and went before a tap).
        XCTAssertTrue(flight.session.awaitsFinalChoice)
        XCTAssertTrue(flight.session.isWaiting)
        flight.session.finalChoice = .touchAndGo
        XCTAssertFalse(flight.session.awaitsFinalChoice)
        XCTAssertTrue(flight.fly(until: { flight.session.generator.mark("touchdown") != nil }, within: 300))
        flight.wait(40)
        XCTAssertTrue(flight.session.generator.isAirborne, "a touch-and-go: away again")
        XCTAssertTrue(flight.fly(until: { flight.session.isOnFinal }, within: 900), "the next final")
        XCTAssertEqual(flight.session.finalChoice, .fullStop, "the default again")
    }

    // MARK: - Next check

    func testNextCheckSpeedsOnUntilTheAircraftWaitsOrACheckFallsDue() throws {
        let flight = try DryRunHeadless(self, setup: DryRunSetup(mission: .circuits(.lszq), rate: 0))
        flight.wait(5)
        flight.session.skipToNextCheck()
        XCTAssertFalse(flight.session.isSkipping, "nothing to speed through while the aircraft waits")

        flight.appState.recordEngineStart()
        flight.wait(2)
        flight.session.skipToNextCheck()
        XCTAssertTrue(flight.session.isSkipping)
        XCTAssertEqual(FlightClock.virtual?.rate, DryRunSession.skipRate)
        XCTAssertTrue(flight.fly(until: { !flight.session.isSkipping }, within: 400), "stops at the holding point")
        XCTAssertTrue(flight.session.isWaiting)

        flight.appState.goToPhase(.beforeDeparture)
        flight.appState.nextPhase()
        flight.wait(2)
        flight.session.skipToNextCheck()
        XCTAssertTrue(flight.fly(until: { !flight.session.isSkipping }, within: 400), "stops lined up")
        XCTAssertEqual(flight.session.generator.waitingAt, .takeoff, "the line up check before the roll (r7-14)")

        DryRunCoach.workThroughCurrentCheck(flight.appState)
        flight.wait(2)
        flight.session.skipToNextCheck()
        XCTAssertTrue(flight.session.isSkipping)
        let cues = flight.appState.flightCues
        XCTAssertTrue(flight.fly(until: { !flight.session.isSkipping }, within: 400), "stops when the cues move")
        XCTAssertNotEqual(flight.appState.flightCues, cues)
    }

    // MARK: - A route

    /// A MARK ahead of the aircraft is the pilot's record, not where to fly: the aircraft flies on to the point;
    /// a DIRECT TO, which leaves the points it skips without a time, is flown (the author's sixth round, r6-4).
    /// The leg timer runs from the take-off, START LEG pressed or not (17 Oct: START LEG stayed all the way).
    func testAMarkAheadIsARecordADirectToIsFlown() throws {
        let plan = FlightPlan(name: "Dry", waypoints: [
            FlightPlanWaypoint(name: "LSZQ", coordinate: DryRunAerodrome.lszq.reference),
            FlightPlanWaypoint(name: "INS", coordinate: ins),
            FlightPlanWaypoint(name: "MID", coordinate: CLLocationCoordinate2D(latitude: 47.06, longitude: 6.98)),
            FlightPlanWaypoint(name: "LSGC", coordinate: lsgc.reference)])
        let setup = DryRunSetup(mission: .route(plan, departure: .lszq, destination: lsgc), rate: 0)
        let flight = try DryRunHeadless(self, setup: setup, plan: plan)
        flight.takeOff()
        flight.wait(60)
        XCTAssertTrue(flight.world.plans.isChronometerRunning, "the first leg timed from the take-off")
        XCTAssertEqual(flight.session.generator.legIndex, 0, "on the way to INS")
        flight.world.plans.markWaypoint()
        flight.wait(5)
        XCTAssertEqual(flight.session.generator.legIndex, 0, "INS marked early: still on the way to it")
        flight.world.plans.directTo(waypointAt: 3)
        flight.wait(5)
        XCTAssertEqual(flight.session.generator.legIndex, 2, "DIRECT TO LSGC, MID skipped: flown")
    }

    /// A go-around at a route's end, from a cruise far above the circuit: the final still comes down past
    /// 250 ft, the app sees the go-around, and with no card in a dry run the checks go back to the climb check,
    /// circuits taken up (the author's fifth round, a-2: the first one went unseen, the checks stayed on the
    /// landing check).
    func testAGoAroundAtARoutesEndFromAHighCruiseIsSeenAndTaken() throws {
        let plan = FlightPlan(name: "Dry", waypoints: [
            FlightPlanWaypoint(name: "LSZQ", coordinate: DryRunAerodrome.lszq.reference),
            FlightPlanWaypoint(name: "INS", coordinate: ins, altitude: 6500),
            FlightPlanWaypoint(name: "LSGC", coordinate: lsgc.reference)])
        let setup = DryRunSetup(mission: .route(plan, departure: .lszq, destination: lsgc), rate: 0)
        let flight = try DryRunHeadless(self, setup: setup, plan: plan)
        flight.session.resolveAerodrome = { $0 == "LSGC" ? self.lsgc : $0 == "LSZQ" ? .lszq : nil }
        flight.takeOff()
        XCTAssertTrue(flight.fly(until: { flight.session.isOnFinal }, within: 3600), "on final at LSGC")
        flight.session.finalChoice = .goAround
        XCTAssertTrue(flight.fly(until: { flight.session.generator.mark("goAround") != nil }, within: 600))
        XCTAssertTrue(flight.fly(until: { !(flight.appState.currentFlight?.goAroundTimes.isEmpty ?? true) }, within: 120),
                      "\(flight.world.detector.emittedEvents)")
        XCTAssertNil(flight.world.detector.pendingGoAround, "no card left to answer")
        XCTAssertEqual(flight.appState.currentPhase, .climb)
        XCTAssertTrue(flight.appState.isCircuitMode, "circuits taken up at the route's end")
    }

    /// A route flown from the world's copy of the plan, and a divert made in the Cockpit flown next: back to
    /// LSZQ, where it lands.
    func testARouteFollowsTheCockpitsDivert() throws {
        let plan = FlightPlan(name: "Dry", waypoints: [
            FlightPlanWaypoint(name: "LSZQ", coordinate: DryRunAerodrome.lszq.reference),
            FlightPlanWaypoint(name: "INS", coordinate: ins),
            FlightPlanWaypoint(name: "LSGC", coordinate: lsgc.reference)])
        let setup = DryRunSetup(mission: .route(plan, departure: .lszq, destination: lsgc), rate: 0)
        let flight = try DryRunHeadless(self, setup: setup, plan: plan)
        flight.session.resolveAerodrome = { $0 == "LSZQ" ? .lszq : nil }
        XCTAssertNotNil(flight.world.plans.activeFlightPlan, "the copy armed in the world")
        XCTAssertEqual(flight.appState.currentFlight?.flightPlanId, plan.id)
        flight.takeOff()
        XCTAssertTrue(flight.session.generator.isAirborne)
        flight.wait(120)
        flight.world.plans.divert(to: TripPlanner.Aerodrome(ident: "LSZQ", name: "Bressaucourt",
                                                            latitude: DryRunAerodrome.lszq.reference.latitude,
                                                            longitude: DryRunAerodrome.lszq.reference.longitude,
                                                            elevationFeet: 1866, frequency: nil, isPPR: false))
        flight.wait(2)
        XCTAssertTrue(flight.fly(until: { flight.session.generator.mark("touchdown") != nil }, within: 2400), "landed")
        flight.appState.goToPhase(.afterLanding)
        XCTAssertTrue(flight.fly(until: { flight.session.generator.isParkedForGood }, within: 600), "parked")
        flight.wait(30)
        XCTAssertEqual(flight.world.detector.emittedEvents.last?.airportIdent, "LSZQ", "\(flight.world.detector.emittedEvents)")
    }

    // MARK: - The end

    func testTheEndSummarisesWhatWasFlownAndSaysWhatToTryNext() {
        let summary = DryRunSummary.make(
            title: "Circuits at LSZQ", aircraft: "WT9 · F-HVXA", checksDone: 12, wasCircuits: true, diverted: false,
            marks: [("lineUp", 200), ("takeoffRoll", 240), ("liftoff", 260), ("touchdown", 715), ("touchAndGo", 720),
                    ("liftoff", 735), ("touchdown", 1790), ("stopped", 1800)],
            seconds: 41 * 60)
        XCTAssertEqual(summary.lines.map(\.event), [.takeoff, .touchAndGo, .fullStop])
        XCTAssertEqual(summary.landings, 2)
        XCTAssertEqual(summary.goArounds, 0)
        XCTAssertEqual(summary.checksTotal, 14, "circuits skip cruise and descent")
        XCTAssertEqual(DryRunSummary.clock(summary.seconds), "0:41")
        XCTAssertEqual(summary.nextTime, L10n.DryRun.nextGoAround)
        XCTAssertEqual(DryRunSummary.text(of: summary.lines[1]), L10n.DryRun.touchAndGoAt("0:12"))

        var route = summary
        route.wasCircuits = false
        XCTAssertEqual(route.nextTime, L10n.DryRun.nextDivert)
        route.diverted = true
        XCTAssertEqual(route.nextTime, L10n.DryRun.nextCircuits)
    }

    /// Ended from the Menu: the flight abandoned in the world, the page with what was flown, the world gone.
    func testEndingFromTheMenuShowsTheDryRunsPage() throws {
        let flight = try DryRunHeadless(self, setup: DryRunSetup(mission: .circuits(.lszq), rate: 0))
        flight.takeOff()
        flight.wait(120)
        flight.session.stop()
        guard case .over(let summary) = flight.session.state else { return XCTFail("no page") }
        XCTAssertEqual(summary.takeoffs, 1)
        XCTAssertEqual(summary.title, L10n.DryRun.circuitsAt("LSZQ"))
        XCTAssertTrue(flight.session.hasEnded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: flight.world.root.path))
        XCTAssertNil(FlightClock.virtual)
    }

    // MARK: - The band

    func testTheBandTakesTheStatusBarsPlace() {
        let iPad = DryRunBandMetrics(width: 820, height: 1180, safeTop: 0, isPad: true)
        XCTAssertEqual(iPad.height, 44)
        XCTAssertEqual(iPad.extraTop, 44)
        XCTAssertTrue(iPad.holdsControls)
        XCTAssertEqual(DryRunBandMetrics(width: 820, height: 1156, safeTop: 24, isPad: true).extraTop, 20)

        let phone = DryRunBandMetrics(width: 402, height: 812, safeTop: 62, isPad: false)
        XCTAssertTrue(phone.hasIsland)
        XCTAssertEqual(phone.height, 62)
        XCTAssertEqual(phone.extraTop, 0, "nothing below moves on a phone upright")
        XCTAssertFalse(phone.holdsControls, "the phone's are in the Menu")

        let onItsSide = DryRunBandMetrics(width: 874, height: 402, safeTop: 0, isPad: false)
        XCTAssertEqual(onItsSide.layout, .columns)
        XCTAssertEqual(onItsSide.height, 28)
        XCTAssertEqual(onItsSide.finalCardBottom, 12)
    }

    // MARK: - The setup

    func testARouteIsFlownBetweenItsAerodromesAtItsCruise() {
        var departure = FlightPlanWaypoint(name: "Bressaucourt", coordinate: DryRunAerodrome.lszq.reference)
        departure.pointKind = .aerodrome
        departure.sourceId = "lszq"
        let plan = FlightPlan(name: "Dry", waypoints: [
            departure,
            FlightPlanWaypoint(name: "INS", coordinate: ins, altitude: 5500),
            FlightPlanWaypoint(name: "LSGC", coordinate: lsgc.reference)])
        XCTAssertEqual(DryRunSetup.aerodromeIdent(of: plan.waypoints[0]), "LSZQ")
        XCTAssertEqual(DryRunSetup.enRoutePoints(of: plan).count, 1)
        XCTAssertEqual(DryRunSetup.cruiseAltitudeFt(of: plan, departure: .lszq, destination: lsgc), 5500)
        let unplanned = FlightPlan(name: "Dry", waypoints: [departure, FlightPlanWaypoint(name: "LSGC", coordinate: lsgc.reference)])
        XCTAssertEqual(DryRunSetup.cruiseAltitudeFt(of: unplanned, departure: .lszq, destination: lsgc),
                       lsgc.patternAltitudeFt + 2000)
        XCTAssertEqual(DryRunSetup(mission: .route(plan, departure: .lszq, destination: lsgc)).title, "LSZQ → LSGC")
        XCTAssertEqual(DryRunSetup.paceLabel(4), "4×")
    }

    func testTheWorldFliesTheAircraftChosen() {
        let meta = RemoteAircraftMetadata(
            id: "pa28-181", aircraftType: "PA28", registration: "HB-PFA", modelName: "Piper Archer II",
            shortModelName: "PA-28-181", aeroclub: nil, version: "1.0", lastUpdated: "2026-01-01", isFree: false,
            stallSpeed: 50, pageCount: 4, hasAccess: true, availableLanguages: ["en"])
        XCTAssertEqual(DryRunWorld.settings(from: AppSettings(), aircraft: .remote(meta)).selectedRemoteAircraftId, "pa28-181")
        var flown = AppSettings()
        flown.selectedRemoteAircraftId = "pa28-181"
        let wt9 = DryRunWorld.settings(from: flown, aircraft: .bundled(.wt9Dynamic))
        XCTAssertNil(wt9.selectedRemoteAircraftId)
        XCTAssertEqual(wt9.selectedAircraft, .wt9Dynamic)
        let world = DryRunWorld(settings: AppSettings(), base: makeTestDirectory())
        addTeardownBlock { @MainActor in world.tearDown() }
        XCTAssertEqual(DryRunCenter.performance(of: world, settings: AppSettings()), .wt9)
    }

    // MARK: - Where it shows

    func testTheStartSheetAndTheCockpitShowWhereTheyWereAsked() async {
        let center = DryRunCenter.shared
        center.requestStart(presenter: "editor")
        XCTAssertEqual(center.presenter, "editor")
        XCTAssertNotNil(center.startRequest)
        center.startRequest = nil

        let airports = AirportDataService(openAIPAirports: makeTestOpenAIPAirportLayer { _ in [] },
                                          rootDirectory: makeTestDirectory())
        airports.injectForReplay([DryRunAerodrome.lszq.airport])
        let aircraftData = makeTestAircraftDataService(subscriptionManager: makeTestSubscriptionManager())
        let outcome = await center.prepare(DryRunSetup(mission: .circuits(.lszq)), settings: { AppSettings() },
                                           airports: airports, aircraftData: aircraftData, isFlightActive: false)
        XCTAssertEqual(outcome, .started)
        XCTAssertFalse(center.launchPrepared(from: DryRunCenter.rootPresenter), "not the root's to show")
        XCTAssertFalse(center.isRunning)
        XCTAssertTrue(center.launchPrepared(from: "editor"))
        XCTAssertTrue(center.isRunning)
        center.requestStart()
        XCTAssertNil(center.startRequest, "nothing during a dry run")
        center.end()
        XCTAssertFalse(center.isRunning)
    }
}

// MARK: - A dry run flown headless

/// A dry run in a world of its own, one second at a time with the clock pinned there, as its timer would feed
/// it, and the pilot doing what the Cockpit's buttons do.
@MainActor
final class DryRunHeadless {
    let session: DryRunSession
    let world: DryRunWorld
    /// Held here as the app holds its own: the GPS pipeline holds it weakly.
    let airports: AirportDataService
    var appState: AppState { world.appState }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var seconds = 0

    init(_ test: XCTestCase, setup: DryRunSetup, plan: FlightPlan? = nil, seed: UInt64 = 11) throws {
        airports = AirportDataService(openAIPAirports: test.makeTestOpenAIPAirportLayer { _ in [] },
                                      rootDirectory: test.makeTestDirectory())
        airports.injectForReplay(setup.aerodromes.map(\.airport))
        world = DryRunWorld(settings: AppSettings(), base: test.makeTestDirectory())
        if let plan {
            world.plans.add(plan)
            // The guided dry run keeps its route unarmed (START FLIGHT arms the flight's own copy), and has its
            // logbook's made-up flights, as `DryRunCenter.prepare` gives them.
            if !setup.isGuided { world.plans.activateFlightPlan(plan) }
        }
        if setup.isGuided {
            for _ in 0..<500 where world.appState.isLoadingFlights {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            world.appState.addMadeUpFlights(DryRunLogbook.flights(at: setup.departure, before: start))
        }
        session = DryRunSession(world: world, setup: setup, seed: seed)
        guard session.begin(airports: airports, now: start) else { throw XCTSkip("the flight didn't start") }
        let session = self.session
        test.addTeardownBlock { @MainActor in session.end() }
    }

    func wait(_ count: Int) {
        for _ in 0..<count {
            seconds += 1
            FlightClock.virtual = FlightClock.Virtual(wallAnchor: Date(),
                                                      virtualAnchor: start.addingTimeInterval(TimeInterval(seconds)),
                                                      rate: 0)
            session.feedDueFixes(upTo: FlightClock.now)
        }
    }

    /// The guided flight taken to its chapter, as the timer does behind the cover; the test's clock then goes
    /// on from there.
    func fastForward() {
        session.fastForward(budget: 4 * 3600)
        seconds = session.generator.t
    }

    /// The clock moved `seconds` at a time, the due fixes fed at once, as a timer firing late does.
    func waitInBatches(of seconds: Int, count: Int) {
        for _ in 0..<count {
            self.seconds += seconds
            FlightClock.virtual = FlightClock.Virtual(wallAnchor: Date(),
                                                      virtualAnchor: start.addingTimeInterval(TimeInterval(self.seconds)),
                                                      rate: 0)
            session.feedDueFixes(upTo: FlightClock.now)
        }
    }

    @discardableResult
    func fly(until done: () -> Bool, within limit: Int) -> Bool {
        for _ in 0..<limit where !done() { wait(1) }
        return done()
    }

    /// ENGINE START, the taxi, READY FOR LINE UP at the holding point, and the line up check on the runway.
    func takeOff() {
        wait(5)
        appState.recordEngineStart()
        fly(until: { self.session.isWaiting && self.seconds > 60 }, within: 400)
        appState.goToPhase(.beforeDeparture)
        appState.nextPhase()
        fly(until: { self.session.generator.waitingAt == .takeoff }, within: 120)
        DryRunCoach.workThroughCurrentCheck(appState)
        fly(until: { self.session.generator.isAirborne }, within: 300)
    }
}
