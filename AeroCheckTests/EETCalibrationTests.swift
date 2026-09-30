import XCTest
import CoreLocation
@testable import AeroCheck

/// What the pilot's flights teach planning (6.1): the departure allowance per departure aerodrome, the
/// arrival allowance per arrival aerodrome, the cruise speed per registration, the fallback from an
/// aerodrome to all of them to +5, the blend, the clamps, the flights that teach nothing, and where it
/// all ends up (the store, the plans still to fly, the provenance line).
///
/// Flights are synthetic tracks flown by `Track`: a fix every ~6 s, a take-off roll and a landing
/// `TrackTimes` measures as on a real flight.
final class EETCalibrationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FlightPlan.planningCalibrationProvider = nil
        FlightPlan.windsAloftProvider = nil
        FlightPlan.magneticDeclinationProvider = nil
    }

    override func tearDown() {
        FlightPlan.planningCalibrationProvider = nil
        super.tearDown()
    }

    // MARK: - A synthetic flight

    /// A GPS track, flown leg by leg.
    private struct Track {
        var points: [GPSPoint] = []
        var time: Date
        var position: CLLocationCoordinate2D
        var altitudeFt: Double

        mutating func fix(speedKt: Double, course: Double) {
            points.append(GPSPoint(latitude: position.latitude, longitude: position.longitude,
                                   altitude: altitudeFt * 0.3048, timestamp: time, speed: speedKt / 1.94384, course: course))
        }

        /// Straight to `target` at a ground speed, the altitude changing evenly on the way.
        mutating func fly(to target: CLLocationCoordinate2D, groundSpeedKt: Double, altitudeFt end: Double? = nil) {
            let start = position, startAltitude = altitudeFt, endAltitude = end ?? altitudeFt
            let seconds = EETCalibration.distanceNM(start, target) / groundSpeedKt * 3600
            let steps = max(1, Int((seconds / 6).rounded(.up)))
            let course = start.bearing(to: target)
            for k in 1...steps {
                let f = Double(k) / Double(steps)
                time = time.addingTimeInterval(seconds / Double(steps))
                position = CLLocationCoordinate2D(latitude: start.latitude + (target.latitude - start.latitude) * f,
                                                  longitude: start.longitude + (target.longitude - start.longitude) * f)
                altitudeFt = startAltitude + (endAltitude - startAltitude) * f
                fix(speedKt: groundSpeedKt, course: course)
            }
        }

        /// On the ground along `course`, one fix every 6 s at each speed.
        mutating func roll(_ speeds: [Double], course: Double) {
            for speed in speeds {
                let nm = speed * 6 / 3600
                let c = course * .pi / 180
                position = CLLocationCoordinate2D(
                    latitude: position.latitude + nm * cos(c) / 60,
                    longitude: position.longitude + nm * sin(c) / (60 * cos(position.latitude * .pi / 180)))
                time = time.addingTimeInterval(6)
                fix(speedKt: speed, course: course)
            }
        }

        /// A point `nm` from `from` along `course`.
        static func point(_ from: CLLocationCoordinate2D, _ nm: Double, _ course: Double) -> CLLocationCoordinate2D {
            let c = course * .pi / 180
            return CLLocationCoordinate2D(latitude: from.latitude + nm * cos(c) / 60,
                                          longitude: from.longitude + nm * sin(c) / (60 * cos(from.latitude * .pi / 180)))
        }
    }

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let field = 1_400.0
    private let lszq = CLLocationCoordinate2D(latitude: 47.0, longitude: 7.0)
    private let w1 = CLLocationCoordinate2D(latitude: 47.0, longitude: 7.2)
    private let w2 = CLLocationCoordinate2D(latitude: 47.0, longitude: 7.4)
    private let lsgn = CLLocationCoordinate2D(latitude: 47.0, longitude: 7.6)

    private struct Flown {
        var flight: Flight
        var takeoff: Date
        var landing: Date
        /// Over W1, and 0.45 NM before the destination (over it, as the arrival measures it).
        var overW1: Date
        var overhead: Date
    }

    /// LSZQ → W1 → W2 → LSGN (24.5 NM east), with the plan when `planned`: a climb to 4,500 ft at 80 kt,
    /// the cruise at `cruiseGroundSpeedKt`, a descent to circuit height, over the field, 1.5 NM beyond it,
    /// back and down to land. `detour`: 7 NM out to the north and back between W1 and W2.
    private func flown(planned: Bool = true, cruiseGroundSpeedKt: Double = 100, detour: Bool = false,
                       wind: FlightPlanWaypoint.PlanningWind? = nil, registration: String = "F-HVXA",
                       circuitLoops: Int = 0, startingDay day: Double = 0) throws -> Flown {
        var track = Track(time: t0.addingTimeInterval(day * 86_400), position: Track.point(lszq, 0.3, 270), altitudeFt: field)
        track.fix(speedKt: 0, course: 90)
        track.roll([8, 8, 8], course: 90)
        track.roll([15, 30, 45, 55], course: 90)
        track.fly(to: w1, groundSpeedKt: 80, altitudeFt: 4_500)
        let overW1 = track.time
        if detour {
            track.fly(to: CLLocationCoordinate2D(latitude: 47.15, longitude: 7.3), groundSpeedKt: cruiseGroundSpeedKt)
        }
        track.fly(to: w2, groundSpeedKt: cruiseGroundSpeedKt)
        track.fly(to: Track.point(lsgn, 0.45, 270), groundSpeedKt: 95, altitudeFt: field + 1_000)
        let overhead = track.time
        track.fly(to: Track.point(lsgn, 1.5, 90), groundSpeedKt: 90)
        for _ in 0..<circuitLoops {
            track.fly(to: Track.point(lsgn, 1.5, 0), groundSpeedKt: 80)
            track.fly(to: Track.point(lsgn, 1.5, 90), groundSpeedKt: 80)
        }
        track.fly(to: lsgn, groundSpeedKt: 60, altitudeFt: field)
        track.roll([40, 25, 12, 6, 6], course: 270)

        let times = TrackTimes.analyze(track: track.points, engineStart: nil, engineShutdown: nil)
        let takeoff = try XCTUnwrap(times.takeoff), landing = try XCTUnwrap(times.landing)
        var flight = Flight(airplane: "wt9-dynamic", aircraftRegistration: registration,
                            startTime: track.points.first?.timestamp, lineUpTime: takeoff, landingTime: landing,
                            departureAirportIdent: "LSZQ", arrivalAirportIdent: "LSGN",
                            gpsTrack: track.points, fullStopCount: 1, fullStopTimes: [landing])
        if planned {
            var plan = FlightPlan(name: "LSZQ → LSGN", aircraftRegistration: registration)
            plan.waypoints = [
                FlightPlanWaypoint(name: "LSZQ", coordinate: lszq, altitude: field, pointKind: .aerodrome, sourceId: "LSZQ"),
                FlightPlanWaypoint(name: "W1", coordinate: w1, altitude: 4_500),
                FlightPlanWaypoint(name: "W2", coordinate: w2, altitude: 4_500),
                FlightPlanWaypoint(name: "LSGN", coordinate: lsgn, altitude: field, pointKind: .aerodrome, sourceId: "LSGN"),
            ]
            plan.calculateRouteData()
            if let wind { for i in 0..<3 { plan.waypoints[i].planningWind = wind } }
            flight.flightPlan = plan
            flight.flightPlanId = plan.id
        }
        return Flown(flight: flight, takeoff: takeoff, landing: landing, overW1: overW1, overhead: overhead)
    }

    // MARK: - One flight

    /// Departure: over the first waypoint, minus the take-off, minus the planned first leg. Arrival: the
    /// landing, minus over the destination.
    func testAPlannedFlightGivesItsDepartureAndArrivalAtItsAerodromes() throws {
        let f = try flown()
        let m = EETCalibration.measure(f.flight)
        let plannedFirstLeg = try XCTUnwrap(f.flight.flightPlan?.waypoints[0].estimatedElapsedTime)
        XCTAssertEqual(m.departureAerodrome, "LSZQ")
        XCTAssertEqual(m.arrivalAerodrome, "LSGN")
        XCTAssertEqual(try XCTUnwrap(m.departureMinutes),
                       (f.overW1.timeIntervalSince(f.takeoff) - plannedFirstLeg) / 60, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(m.arrivalMinutes), f.landing.timeIntervalSince(f.overhead) / 60, accuracy: 0.12)
        XCTAssertGreaterThan(try XCTUnwrap(m.arrivalMinutes), 2, "over it, 1.5 NM beyond and back: minutes, not seconds")
    }

    /// Without a plan: the time to 5 NM beyond 5 NM at the flight's cruise ground speed, and the arrival
    /// over the straight line from the take-off to the landing.
    func testAFlightWithoutAPlanIsMeasuredOnItsTrack() throws {
        let f = try flown(planned: false)
        let m = EETCalibration.measure(f.flight)
        XCTAssertEqual(m.departureAerodrome, "LSZQ")
        let departure = try XCTUnwrap(m.departureMinutes)
        XCTAssertGreaterThan(departure, 0, "a climb at 80 kt is slower than the cruise")
        XCTAssertLessThan(departure, 3)
        XCTAssertEqual(try XCTUnwrap(m.arrivalMinutes), f.landing.timeIntervalSince(f.overhead) / 60, accuracy: 0.12)
    }

    /// Back where it started: no departure or arrival to measure without a plan.
    func testALocalFlightWithoutAPlanTeachesNoAllowance() throws {
        var track = Track(time: t0, position: lszq, altitudeFt: field)
        track.fix(speedKt: 0, course: 90)
        track.roll([15, 30, 45, 55], course: 90)
        track.fly(to: Track.point(lszq, 3, 90), groundSpeedKt: 80, altitudeFt: 3_000)
        track.fly(to: Track.point(lszq, 3, 0), groundSpeedKt: 90)
        track.fly(to: Track.point(lszq, 1.5, 90), groundSpeedKt: 70, altitudeFt: 2_400)
        track.fly(to: lszq, groundSpeedKt: 60, altitudeFt: field)
        track.roll([40, 25, 12], course: 270)
        let flight = Flight(airplane: "wt9-dynamic", aircraftRegistration: "F-HVXA", startTime: t0,
                            departureAirportIdent: "LSZQ", arrivalAirportIdent: "LSZQ", gpsTrack: track.points)
        let m = EETCalibration.measure(flight)
        XCTAssertNil(m.departureMinutes)
        XCTAssertNil(m.arrivalMinutes)
    }

    // MARK: - Exclusions (§7 of the analysis)

    func testCircuitsTeachNothing() throws {
        var f = try flown()
        f.flight.arrivalAirportIdent = "LSZQ"
        f.flight.touchAndGoCount = 2
        f.flight.touchAndGoTimes = [f.takeoff.addingTimeInterval(400), f.takeoff.addingTimeInterval(800)]
        XCTAssertEqual(EETCalibration.measure(f.flight).departureMinutes, nil)
        XCTAssertEqual(EETCalibration.measure(f.flight).arrivalMinutes, nil)
    }

    func testATouchAndGoAtTheDestinationDropsTheArrivalOnly() throws {
        var f = try flown()
        f.flight.touchAndGoCount = 1
        f.flight.touchAndGoTimes = [f.landing.addingTimeInterval(-60)]
        let m = EETCalibration.measure(f.flight)
        XCTAssertNil(m.arrivalMinutes)
        XCTAssertNotNil(m.departureMinutes)
    }

    func testAGoAroundAtTheDepartureDropsTheDepartureOnly() throws {
        var f = try flown()
        f.flight.goAroundCount = 1
        f.flight.goAroundTimes = [f.takeoff.addingTimeInterval(60)]
        let m = EETCalibration.measure(f.flight)
        XCTAssertNil(m.departureMinutes)
        XCTAssertNotNil(m.arrivalMinutes)
    }

    /// A diversion or a waypoint taken back: the plan says nothing. The departure is still measured on
    /// the track; the arrival is not (it was somewhere else, or the route was not followed).
    func testADiversionOrATakenBackWaypointLeavesThePlanOut() throws {
        var diverted = try flown()
        diverted.flight.flightPlan?.diversion = Diversion(ident: "LSGN", name: "x", latitude: lsgn.latitude,
                                                          longitude: lsgn.longitude, leftRouteAt: 2)
        var takenBack = try flown()
        let secondWaypoint = try XCTUnwrap(takenBack.flight.flightPlan?.waypoints[1].id)
        takenBack.flight.flightPlan?.takenBackWaypointIds = [secondWaypoint]
        let planned = try XCTUnwrap(EETCalibration.measure(try flown().flight).departureMinutes)
        for f in [diverted, takenBack] {
            let m = EETCalibration.measure(f.flight)
            XCTAssertNil(m.arrivalMinutes)
            let planFree = try XCTUnwrap(m.departureMinutes)
            XCTAssertNotEqual(planFree, planned, accuracy: 0.01, "the 5 NM measure, not the plan's")
        }
    }

    func testFewerThanSixtyPercentOfTheWaypointsPassedLeavesThePlanOut() throws {
        var f = try flown()
        var plan = try XCTUnwrap(f.flight.flightPlan)
        // Two waypoints 10 NM north of anything flown: one of three passed.
        plan.waypoints.insert(FlightPlanWaypoint(name: "N1", coordinate: CLLocationCoordinate2D(latitude: 47.17, longitude: 7.3),
                                                 altitude: 4_500), at: 2)
        plan.waypoints.insert(FlightPlanWaypoint(name: "N2", coordinate: CLLocationCoordinate2D(latitude: 47.17, longitude: 7.35),
                                                 altitude: 4_500), at: 3)
        f.flight.flightPlan = plan
        XCTAssertNil(EETCalibration.measure(f.flight).arrivalMinutes)
    }

    /// Landed somewhere else than planned is a diversion, recorded or not (plans flown before 5.1 have
    /// none): no arrival, and the departure is the track's own.
    func testLandingElsewhereThanPlannedLeavesThePlanOut() throws {
        var f = try flown()
        var plan = try XCTUnwrap(f.flight.flightPlan)
        plan.waypoints[3].coordinate = CLLocationCoordinate2D(latitude: 47.3, longitude: 7.6)
        f.flight.flightPlan = plan
        let m = EETCalibration.measure(f.flight)
        XCTAssertNil(m.arrivalMinutes)
        XCTAssertNotEqual(try XCTUnwrap(m.departureMinutes), try XCTUnwrap(EETCalibration.measure(try flown().flight).departureMinutes),
                          accuracy: 0.01)
    }

    /// A long wait in the circuit is the arrival, not a detour: the route is measured to over the
    /// destination. (29 Sep, LSGN: ten minutes of circuit put the whole leg over 1.3 times the plan.)
    func testALongCircuitIsTheArrivalNotARouteDeviation() throws {
        let f = try flown(circuitLoops: 4)
        let arrival = try XCTUnwrap(EETCalibration.measure(f.flight).arrivalMinutes)
        XCTAssertEqual(arrival, f.landing.timeIntervalSince(f.overhead) / 60, accuracy: 0.12)
        XCTAssertGreaterThan(arrival, 10)
    }

    func testATrackMoreThanOnePointThreeTimesThePlanLeavesThePlanOut() throws {
        let f = try flown(detour: true)
        XCTAssertNil(EETCalibration.measure(f.flight).arrivalMinutes)
    }

    func testAGapInTheAirTeachesNothing() throws {
        var f = try flown()
        let hole = f.overW1.addingTimeInterval(60)...f.overW1.addingTimeInterval(150)
        f.flight.gpsTrack.removeAll { hole.contains($0.timestamp) }
        let m = EETCalibration.measure(f.flight)
        XCTAssertNil(m.departureMinutes)
        XCTAssertNil(m.arrivalMinutes)
        XCTAssertNil(m.cruiseKIAS)
    }

    func testSeveralLandingsTeachNothing() throws {
        var f = try flown()
        f.flight.fullStopCount = 2
        f.flight.fullStopTimes = [f.takeoff.addingTimeInterval(600), f.landing]
        XCTAssertNil(EETCalibration.measure(f.flight).departureMinutes)
    }

    // MARK: - Cruise

    /// The ground speed with the wind the plan stored taken out: 125 kt over the ground with 20 kt on
    /// the tail is 105 kt true, which at 4,500 ft stands for this KIAS.
    func testTheCruiseIsTheGroundSpeedWithThePlannedWindTakenOut() throws {
        let wind = FlightPlanWaypoint.PlanningWind(directionDegTrue: 270, speedKt: 20, source: .forecast, validAt: nil)
        let f = try flown(cruiseGroundSpeedKt: 125, wind: wind)
        let kias = try XCTUnwrap(EETCalibration.measure(f.flight).cruiseKIAS)
        XCTAssertEqual(kias, CruiseSpeedModel.basisKIAS(trueAirspeed: 105, altitudeFt: 4_500), accuracy: 0.3)
    }

    /// Without a wind to take out (no plan, courses too alike for the triangle): no cruise.
    func testNoWindNoCruise() throws {
        XCTAssertNil(EETCalibration.measure(try flown(planned: false).flight).cruiseKIAS)
        XCTAssertNil(EETCalibration.measure(try flown().flight).cruiseKIAS, "a plan computed without a wind")
    }

    /// Courses spread over 120° or more: the wind triangle finds the wind itself. 100 kt true in a
    /// westerly 20 kt, flown east, north and south-west, with no plan.
    func testTheWindTriangleGivesTheCruiseWhenTheCoursesSpread() throws {
        func groundSpeed(course: Double) -> Double {
            // The ground speed along `course` at 100 kt true with the air moving east at 20 kt.
            let c = course * .pi / 180
            let along = 20 * sin(c), across = 20 * cos(c)
            return along + (100 * 100 - across * across).squareRoot()
        }
        var track = Track(time: t0, position: lszq, altitudeFt: field)
        track.fix(speedKt: 0, course: 90)
        track.roll([15, 30, 45, 55], course: 90)
        let c1 = CLLocationCoordinate2D(latitude: 47.0, longitude: 7.25)
        track.fly(to: c1, groundSpeedKt: 80, altitudeFt: 4_500)
        let c2 = Track.point(c1, 9, 90)
        track.fly(to: c2, groundSpeedKt: groundSpeed(course: 90))
        let c3 = Track.point(c2, 9, 0)
        track.fly(to: c3, groundSpeedKt: groundSpeed(course: 0))
        let c4 = Track.point(c3, 9, 225)
        track.fly(to: c4, groundSpeedKt: groundSpeed(course: 225))
        track.fly(to: Track.point(lsgn, 1.5, 90), groundSpeedKt: 90, altitudeFt: field + 1_000)
        track.fly(to: lsgn, groundSpeedKt: 60, altitudeFt: field)
        track.roll([40, 25, 12], course: 270)
        let flight = Flight(airplane: "wt9-dynamic", aircraftRegistration: "F-HVXA", startTime: t0,
                            departureAirportIdent: "LSZQ", arrivalAirportIdent: "LSGN", gpsTrack: track.points)
        let kias = try XCTUnwrap(EETCalibration.measure(flight).cruiseKIAS)
        XCTAssertEqual(kias, CruiseSpeedModel.basisKIAS(trueAirspeed: 100, altitudeFt: 4_500), accuracy: 0.5)
    }

    func testTheWindTriangleFindsTheCircle() throws {
        let wind = (east: 12.0, north: -5.0)
        let vectors = stride(from: 0.0, to: 200, by: 10).map { heading -> (east: Double, north: Double) in
            let h = heading * .pi / 180
            return (wind.east + 110 * sin(h), wind.north + 110 * cos(h))
        }
        let fit = try XCTUnwrap(WindTriangleFit.fit(vectors))
        XCTAssertEqual(fit.trueAirspeed, 110, accuracy: 1e-6)
        XCTAssertEqual(fit.windEast, 12, accuracy: 1e-6)
        XCTAssertEqual(fit.windNorth, -5, accuracy: 1e-6)
        XCTAssertEqual(fit.spreadDegrees, 190, accuracy: 1e-6)
        XCTAssertLessThan(fit.rms, 1e-6)
    }

    // MARK: - From samples to an allowance

    private func samples(_ values: [Double], from day: Int = 0) -> [EETCalibration.Sample] {
        values.enumerated().map { EETCalibration.Sample(date: t0.addingTimeInterval(Double(day + $0.offset) * 86_400), value: $0.element) }
    }

    /// Three flights at the aerodrome give it its own figure, drawn towards +5 with fewer than five.
    func testAnAerodromeWithThreeFlightsHasItsOwnAllowance() {
        var snapshot = EETCalibration.Snapshot()
        snapshot.departures = ["LSZQ": samples([1, 1.2, 0.8])]
        let allowance = EETCalibration.departureAllowance(at: "lszq", in: snapshot)
        XCTAssertEqual(allowance.source, .aerodrome)
        XCTAssertEqual(allowance.flights, 3)
        XCTAssertEqual(allowance.aerodrome, "LSZQ")
        XCTAssertEqual(allowance.minutes, 3, "5 + 3/5 × (1 − 5) = 2.6, to the minute")
        snapshot.departures["LSZQ"] = samples([1, 1.2, 0.8, 1.1, 0.9, 1])
        XCTAssertEqual(EETCalibration.departureAllowance(at: "LSZQ", in: snapshot).minutes, 1, "full weight from five")
    }

    /// Fewer at the aerodrome: the pilot's flights everywhere (five at least), then +5.
    func testTheFallbackIsThePilotsFlightsEverywhereThenFiveMinutes() {
        var snapshot = EETCalibration.Snapshot()
        snapshot.arrivals = ["LSGN": samples([9, 10]), "LSGE": samples([7, 8, 6], from: 5)]
        let everywhere = EETCalibration.arrivalAllowance(at: "LSGN", in: snapshot)
        XCTAssertEqual(everywhere.source, .allAerodromes)
        XCTAssertEqual(everywhere.flights, 5)
        XCTAssertEqual(everywhere.minutes, 8, "the median of 9, 10, 7, 8, 6")
        XCTAssertEqual(everywhere.aerodrome, "LSGN")

        snapshot.arrivals = ["LSGN": samples([9, 10]), "LSGE": samples([7])]
        XCTAssertEqual(EETCalibration.arrivalAllowance(at: "LSGN", in: snapshot), .standard(at: "LSGN"))
        XCTAssertEqual(EETCalibration.arrivalAllowance(at: nil, in: .empty).minutes, 5)
    }

    func testAllowancesAreClamped() {
        var snapshot = EETCalibration.Snapshot()
        snapshot.departures = ["LSZQ": samples([-2, -1, -3, -2, -1])]
        snapshot.arrivals = ["LSGN": samples([20, 25, 18, 30, 22])]
        XCTAssertEqual(EETCalibration.departureAllowance(at: "LSZQ", in: snapshot).minutes, 0)
        XCTAssertEqual(EETCalibration.arrivalAllowance(at: "LSGN", in: snapshot).minutes, 15)
        snapshot.departures = ["LSZQ": samples([9, 9, 9, 9, 9])]
        XCTAssertEqual(EETCalibration.departureAllowance(at: "LSZQ", in: snapshot).minutes, 6)
    }

    /// The last 20 flights, whatever came before: a long-gone habit does not hold the figure.
    func testOnlyTheLastTwentyFlightsCount() {
        var snapshot = EETCalibration.Snapshot()
        snapshot.arrivals = ["LSGN": samples(Array(repeating: 12, count: 30) + Array(repeating: 3, count: 20))]
        XCTAssertEqual(EETCalibration.arrivalAllowance(at: "LSGN", in: snapshot).minutes, 3)
        XCTAssertEqual(EETCalibration.arrivalAllowance(at: "LSGN", in: snapshot).flights, 20)
    }

    /// The logbook becomes a snapshot keyed by aerodrome and registration, the most recent 20 each.
    func testTheSnapshotKeepsEachAerodromesAndRegistrationsSamples() throws {
        let wind = FlightPlanWaypoint.PlanningWind(directionDegTrue: 270, speedKt: 20, source: .forecast, validAt: nil)
        let flights = try (0..<3).map { try flown(cruiseGroundSpeedKt: 125, wind: wind, startingDay: Double($0)).flight }
            + [try flown(planned: false, registration: "HB-PFA", startingDay: 3).flight]
        let snapshot = EETCalibration.snapshot(from: flights)
        XCTAssertEqual(snapshot.departures["LSZQ"]?.count, 4)
        XCTAssertEqual(snapshot.arrivals["LSGN"]?.count, 4)
        XCTAssertEqual(snapshot.cruise["F-HVXA"]?.count, 3)
        XCTAssertNil(snapshot.cruise["HB-PFA"], "no wind to take out")
        XCTAssertEqual(snapshot.logbookFingerprint, EETCalibration.fingerprint(of: flights))
        XCTAssertEqual(snapshot.departures["LSZQ"]?.map(\.date), snapshot.departures["LSZQ"]?.map(\.date).sorted())
    }

    // MARK: - The plan

    private func plan(registration: String = "F-HVXA", owned: Bool = true) -> FlightPlan {
        var plan = FlightPlan(name: "LSZQ → LSGN", aircraftRegistration: registration)
        plan.waypoints = [
            FlightPlanWaypoint(name: "LSZQ", coordinate: lszq, altitude: field, pointKind: .aerodrome, sourceId: "LSZQ"),
            FlightPlanWaypoint(name: "W1", coordinate: w1, altitude: 4_500),
            FlightPlanWaypoint(name: "LSGN", coordinate: lsgn, altitude: field),
        ]
        plan.flightOwned = owned ? true : nil
        return plan
    }

    private func calibrated(departure: Int, arrival: Int) -> (FlightPlan) -> FlightPlan.PlanningCalibration {
        { plan in
            FlightPlan.PlanningCalibration(
                cruise: CruiseSpeed(kias: 97, source: .aircraftData),
                departureAllowance: EETAllowance(minutes: departure, aerodrome: plan.departureAerodromeIdent,
                                                 source: .aerodrome, flights: 6),
                arrivalAllowance: EETAllowance(minutes: arrival, aerodrome: plan.destinationAerodromeIdent,
                                               source: .standard))
        }
    }

    /// The plan's two ends take the allowances learned there, keep them, and say so.
    func testThePlanTakesAndKeepsItsAllowancesAndSaysWhereTheyComeFrom() throws {
        FlightPlan.planningCalibrationProvider = calibrated(departure: 1, arrival: 8)
        var p = plan()
        p.calculateRouteData()
        XCTAssertEqual(p.waypoints[0].legEETExtra, 60)
        XCTAssertEqual(p.waypoints[2].legEETExtra, 480)
        let legs = try XCTUnwrap(p.waypoints[0].estimatedElapsedTime) + (try XCTUnwrap(p.waypoints[1].estimatedElapsedTime))
        XCTAssertEqual(p.totalEET, 60 + legs + 480, accuracy: 1e-6)
        XCTAssertEqual(p.departureAllowance?.aerodrome, "LSZQ")
        XCTAssertEqual(p.arrivalAllowance?.aerodrome, "LSGN", "an ICAO name counts as the aerodrome")
        XCTAssertFalse(p.planningCalibrationIsStale)
        XCTAssertEqual(p.eetProvenanceParts, [
            L10n.EETPlanning.departure("+1", at: "LSZQ", L10n.EETPlanning.flights(6)),
            L10n.EETPlanning.arrival("+8", at: "LSGN", L10n.EETPlanning.standard),
            L10n.EETPlanning.cruise("97", L10n.EETPlanning.cruiseAircraftData),
        ])
        FlightPlan.planningCalibrationProvider = calibrated(departure: 2, arrival: 8)
        XCTAssertTrue(p.planningCalibrationIsStale)
    }

    /// A plan computed before 6.1 stored nothing: it says the +5 it was computed with.
    func testAnOlderPlanSaysItsFiveMinutes() throws {
        var older = plan()
        older.calculateRouteData()
        older.departureAllowance = nil
        older.arrivalAllowance = nil
        older.plannedCruise = nil
        XCTAssertEqual(older.eetProvenanceParts, [
            L10n.EETPlanning.departure("+5", at: "LSZQ", L10n.EETPlanning.standard),
            L10n.EETPlanning.arrival("+5", at: "LSGN", L10n.EETPlanning.standard),
        ])
    }

    /// The flights still to fly are retimed when the calibration changes; a route of the library, a plan
    /// already flown and the plan being flown are not.
    @MainActor
    func testThePlannedFlightsStillToFlyAreRetimed() throws {
        let manager = makeTestPlanManager()
        var due = plan()
        due.calculateRouteData()
        var route = plan(owned: false)
        route.calculateRouteData()
        var flown = plan()
        flown.calculateRouteData()
        flown.waypoints[0].actualTimeOver = t0
        // A route a flight follows: the one kind of route with a date.
        var followed = plan(owned: false)
        followed.plannedDepartureTime = t0.addingTimeInterval(86_400)
        followed.calculateRouteData()
        var departed = plan()
        departed.plannedDepartureTime = t0.addingTimeInterval(-3_600)
        departed.calculateRouteData()
        [due, route, flown, followed, departed].forEach(manager.add)

        FlightPlan.planningCalibrationProvider = calibrated(departure: 2, arrival: 9)
        manager.refreshPlanningCalibration(now: t0)

        func extra(_ id: UUID) -> TimeInterval? { manager.flightPlans.first { $0.id == id }?.waypoints[0].legEETExtra }
        XCTAssertEqual(extra(due.id), 120)
        XCTAssertEqual(extra(followed.id), 120)
        XCTAssertEqual(extra(route.id), 300, "a route of the library")
        XCTAssertEqual(extra(flown.id), 300, "already flown")
        XCTAssertEqual(extra(departed.id), 300, "its departure is past")
    }

    // MARK: - The store

    /// END FLIGHT learns again, off the main actor; the result is kept for the next launch, and only a
    /// different logbook is learned from again.
    @MainActor
    func testTheStoreLearnsKeepsAndGivesPlansTheirCalibration() async throws {
        let defaults = makeTestDefaults()
        let store = EETCalibrationStore(defaults: defaults)
        let flights = try (0..<3).map { try flown(startingDay: Double($0)).flight }
        store.refresh(from: flights)
        await store.waitForRefresh()
        XCTAssertEqual(store.snapshot.departures["LSZQ"]?.count, 3)
        XCTAssertEqual(store.revision, 1)

        let relaunched = EETCalibrationStore(defaults: defaults)
        XCTAssertEqual(relaunched.snapshot, store.snapshot)
        relaunched.refresh(from: flights)
        await relaunched.waitForRefresh()
        XCTAssertEqual(relaunched.revision, 0, "the same logbook: nothing to learn")

        var p = plan()
        p.waypoints[2].pointKind = .aerodrome
        p.waypoints[2].sourceId = "LSGN"
        let calibration = relaunched.calibration(for: p)
        XCTAssertEqual(calibration.departureAllowance.source, .aerodrome)
        XCTAssertEqual(calibration.departureAllowance.flights, 3)
        XCTAssertEqual(calibration.arrivalAllowance.source, .aerodrome)
        XCTAssertEqual(calibration.cruise, .standard)
    }

    /// A test AppState must never learn into (or from) the app's own store.
    @MainActor
    func testAConfinedAppStateHasNoStoreUnlessGivenOne() {
        XCTAssertNil(makeTestAppState().eetCalibration)
    }
}
