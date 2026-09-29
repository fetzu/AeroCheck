import XCTest
import CoreLocation
@testable import AeroCheck

/// Tests for wind-corrected flight-plan leg timing.
///
/// Winds aloft are a PLANNING input: a forecast is the right tool for computing a leg's ground
/// speed and ETA before the flight, and the wrong tool for anything resembling a live instrument.
/// (`WindDataService` covers the separate surface-wind briefing input; `SpeedIndicatorTests` covers
/// why the in-flight readout is ground speed only.)
final class WindsAloftPlanningTests: XCTestCase {

    private func wind(_ from: Double, _ kt: Double) -> FlightPlan.WindAloft {
        FlightPlan.WindAloft(directionDegTrue: from, speedKt: kt)
    }

    override func tearDown() {
        FlightPlan.windsAloftProvider = nil
        super.tearDown()
    }

    // MARK: - Wind triangle

    func testDirectHeadwindSubtracts() {
        let gs = FlightPlan.windCorrectedGroundSpeed(
            trueAirspeedKt: 100, trueCourseDeg: 270, wind: wind(270, 20))
        XCTAssertEqual(gs!, 80, accuracy: 0.01, "wind on the nose costs its full strength")
    }

    func testDirectTailwindAdds() {
        let gs = FlightPlan.windCorrectedGroundSpeed(
            trueAirspeedKt: 100, trueCourseDeg: 90, wind: wind(270, 20))
        XCTAssertEqual(gs!, 120, accuracy: 0.01, "wind on the tail adds its full strength")
    }

    /// A pure crosswind still costs ground speed, because the aircraft must crab into it:
    /// GS = sqrt(TAS^2 - WS^2) = sqrt(100^2 - 20^2) = 97.98.
    func testPureCrosswindCostsGroundSpeed() {
        let gs = FlightPlan.windCorrectedGroundSpeed(
            trueAirspeedKt: 100, trueCourseDeg: 0, wind: wind(90, 20))
        XCTAssertEqual(gs!, sqrt(100 * 100 - 20 * 20), accuracy: 0.01)
        XCTAssertLessThan(gs!, 100, "crabbing always costs ground speed")
    }

    func testCalmWindLeavesAirspeedUnchanged() {
        let gs = FlightPlan.windCorrectedGroundSpeed(
            trueAirspeedKt: 100, trueCourseDeg: 123, wind: wind(0, 0))
        XCTAssertEqual(gs!, 100, accuracy: 0.01)
    }

    /// The direction convention must be "wind FROM", as forecasts and METARs give it. If it were
    /// silently treated as "wind TO", every headwind would become a tailwind — an ETA error in the
    /// optimistic direction, which is the dangerous one for fuel planning.
    func testDirectionIsInterpretedAsWindFrom() {
        let headwind = FlightPlan.windCorrectedGroundSpeed(
            trueAirspeedKt: 100, trueCourseDeg: 0, wind: wind(0, 25))!
        XCTAssertEqual(headwind, 75, accuracy: 0.01)
    }

    // MARK: - Refusals

    /// A crosswind component exceeding TAS means no heading holds the track. Returning nil lets the
    /// caller fall back to the zero-wind figure rather than reporting a clamped, invented speed.
    func testUnflyableCrosswindReturnsNil() {
        XCTAssertNil(FlightPlan.windCorrectedGroundSpeed(
            trueAirspeedKt: 20, trueCourseDeg: 0, wind: wind(90, 60)))
    }

    func testHeadwindStrongerThanAirspeedReturnsNil() {
        XCTAssertNil(FlightPlan.windCorrectedGroundSpeed(
            trueAirspeedKt: 40, trueCourseDeg: 270, wind: wind(270, 60)),
            "being blown backwards along the track is not a flyable leg")
    }

    func testNonFiniteAndNonPositiveInputsReturnNil() {
        XCTAssertNil(FlightPlan.windCorrectedGroundSpeed(
            trueAirspeedKt: 0, trueCourseDeg: 0, wind: wind(0, 10)))
        XCTAssertNil(FlightPlan.windCorrectedGroundSpeed(
            trueAirspeedKt: .nan, trueCourseDeg: 0, wind: wind(0, 10)))
        XCTAssertNil(FlightPlan.windCorrectedGroundSpeed(
            trueAirspeedKt: 100, trueCourseDeg: 0, wind: wind(.nan, 10)))
        XCTAssertNil(FlightPlan.windCorrectedGroundSpeed(
            trueAirspeedKt: 100, trueCourseDeg: 0, wind: wind(0, -5)))
    }

    // MARK: - Wind precedence

    /// A pilot-entered wind outranks the forecast: someone copying winds from a briefing has better
    /// information than a model. These fields have been editable in `WaypointEditorSheet` all along
    /// but were never read by leg timing, so entering a wind changed nothing.
    func testPilotEnteredWindBeatsForecast() {
        FlightPlan.windsAloftProvider = { _, _, _ in self.wind(90, 50) }
        var waypoint = FlightPlanWaypoint(coordinate: CLLocationCoordinate2D(latitude: 47, longitude: 7))
        waypoint.windDirection = 270
        waypoint.windSpeed = 15
        let used = FlightPlan.legWind(for: waypoint, at: waypoint.coordinate)
        XCTAssertEqual(used, wind(270, 15))
    }

    func testForecastUsedWhenNoPilotWind() {
        FlightPlan.windsAloftProvider = { _, _, _ in self.wind(180, 12) }
        let waypoint = FlightPlanWaypoint(coordinate: CLLocationCoordinate2D(latitude: 47, longitude: 7))
        XCTAssertEqual(FlightPlan.legWind(for: waypoint, at: waypoint.coordinate), wind(180, 12))
    }

    func testNoWindAtAllWhenProviderUnsetAndNothingEntered() {
        FlightPlan.windsAloftProvider = nil
        let waypoint = FlightPlanWaypoint(coordinate: CLLocationCoordinate2D(latitude: 47, longitude: 7))
        XCTAssertNil(FlightPlan.legWind(for: waypoint, at: waypoint.coordinate))
    }

    /// A half-entered wind (direction but no speed) must not be treated as a wind.
    func testPartialPilotWindIsIgnored() {
        FlightPlan.windsAloftProvider = nil
        var waypoint = FlightPlanWaypoint(coordinate: CLLocationCoordinate2D(latitude: 47, longitude: 7))
        waypoint.windDirection = 270
        XCTAssertNil(FlightPlan.legWind(for: waypoint, at: waypoint.coordinate))
    }

    // MARK: - End-to-end leg timing

    /// The whole point: a headwind must lengthen the leg's EET. Before this, `distance / speed`
    /// assumed zero wind on every leg.
    func testHeadwindLengthensLegEET() {
        let west = CLLocationCoordinate2D(latitude: 47.0, longitude: 7.0)
        let east = CLLocationCoordinate2D(latitude: 47.0, longitude: 8.0) // due east, ~45 NM

        func eet(withWind provider: ((CLLocationCoordinate2D, Double, Date?) -> FlightPlan.WindAloft?)?) -> TimeInterval {
            FlightPlan.windsAloftProvider = provider
            var plan = FlightPlan(name: "T", aircraftTypeId: "WT9",
                                  aircraftRegistration: "F-HVXA", aircraftModelName: "WT9")
            plan.waypoints = [
                FlightPlanWaypoint(name: "A", coordinate: west, plannedGroundSpeed: 100),
                FlightPlanWaypoint(name: "B", coordinate: east, plannedGroundSpeed: 100),
            ]
            plan.calculateRouteData()
            return plan.waypoints[0].estimatedElapsedTime ?? 0
        }

        let calm = eet(withWind: nil)
        let headwind = eet(withWind: { _, _, _ in self.wind(90, 25) })   // from the east, flying east
        let tailwind = eet(withWind: { _, _, _ in self.wind(270, 25) })  // from the west, flying east

        XCTAssertGreaterThan(calm, 0)
        XCTAssertGreaterThan(headwind, calm, "a headwind must lengthen the leg")
        XCTAssertLessThan(tailwind, calm, "a tailwind must shorten the leg")
        // 100 kt TAS against/with 25 kt => 75/125 kt GS, i.e. a third longer / a fifth shorter.
        XCTAssertEqual(headwind / calm, 100.0 / 75.0, accuracy: 0.02)
        XCTAssertEqual(tailwind / calm, 100.0 / 125.0, accuracy: 0.02)
    }

    // MARK: - Level selection

    func testNearestLevelPicksClosestHeight() {
        let forecast = WindsAloftService.Forecast(lat: 47.5, lon: 7, validAt: "x", levels: [
            .init(pressureHPa: 1000, heightFt: 545, directionDeg: 287, speedKt: 3),
            .init(pressureHPa: 925, heightFt: 2750, directionDeg: 302, speedKt: 9),
            .init(pressureHPa: 850, heightFt: 5115, directionDeg: 271, speedKt: 11),
        ])
        XCTAssertEqual(WindsAloftService.nearestLevel(in: forecast, toAltitudeFt: 3000)?.pressureHPa, 925)
        XCTAssertEqual(WindsAloftService.nearestLevel(in: forecast, toAltitudeFt: 0)?.pressureHPa, 1000)
        XCTAssertEqual(WindsAloftService.nearestLevel(in: forecast, toAltitudeFt: 9000)?.pressureHPa, 850)
    }

    /// The worker marks a level whose height the model omitted with -1; it must not be selected as
    /// "nearest to sea level".
    func testLevelsWithNoReportedHeightAreSkipped() {
        let forecast = WindsAloftService.Forecast(lat: 47.5, lon: 7, validAt: "x", levels: [
            .init(pressureHPa: 1000, heightFt: -1, directionDeg: 287, speedKt: 3),
            .init(pressureHPa: 925, heightFt: 2750, directionDeg: 302, speedKt: 9),
        ])
        XCTAssertEqual(WindsAloftService.nearestLevel(in: forecast, toAltitudeFt: 100)?.pressureHPa, 925)
    }

    // MARK: - Cache key

    /// Must agree with the worker's own 0.25° grid, or the two caches disagree about what "the same
    /// request" means and the client re-fetches cells the worker already has.
    func testCacheKeySnapsToTheSameGridAsTheWorker() {
        let a = WindsAloftService.cacheKey(lat: 47.48, lon: 7.00, now: Date(timeIntervalSince1970: 0))
        let b = WindsAloftService.cacheKey(lat: 47.52, lon: 6.99, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(a, b, "coordinates in the same cell must share a key")

        let far = WindsAloftService.cacheKey(lat: 46.20, lon: 6.10, now: Date(timeIntervalSince1970: 0))
        XCTAssertNotEqual(a, far)
    }

    func testCacheKeyChangesWithTheHour() {
        let coord = (lat: 47.5, lon: 7.0)
        let h18 = WindsAloftService.cacheKey(lat: coord.lat, lon: coord.lon,
                                             now: Date(timeIntervalSince1970: 18 * 3600))
        let h19 = WindsAloftService.cacheKey(lat: coord.lat, lon: coord.lon,
                                             now: Date(timeIntervalSince1970: 19 * 3600))
        XCTAssertNotEqual(h18, h19)
    }

    // MARK: - The wind a leg was planned with (6.1)

    private let departure = Date(timeIntervalSince1970: 1_789_999_200)   // 21.09.2026 14:00 UTC

    /// Three legs due east from the Jura at 5,000 ft, at 100 kt, departing at `departure`.
    private func route(departing: Date? = nil) -> FlightPlan {
        var plan = FlightPlan(name: "East", plannedDepartureTime: departing, fuelFlow: 20)
        plan.waypoints = (0..<4).map { i in
            FlightPlanWaypoint(name: "P\(i)", coordinate: .init(latitude: 47.2, longitude: 7.0 + Double(i) * 0.3),
                               altitude: 5000, plannedGroundSpeed: 100)
        }
        return plan
    }

    private func legTimes(_ plan: FlightPlan) -> [TimeInterval?] { plan.waypoints.map(\.estimatedElapsedTime) }

    func testTheWindALegIsComputedWithIsStoredOnIt() {
        let validAt = departure
        FlightPlan.windsAloftProvider = { _, _, _ in
            FlightPlan.WindAloft(directionDegTrue: 240, speedKt: 15, validAt: validAt)
        }
        var plan = route(departing: departure)
        plan.calculateRouteData()

        for i in 0..<3 {
            XCTAssertEqual(plan.waypoints[i].planningWind,
                           .init(directionDegTrue: 240, speedKt: 15, source: .forecast, validAt: validAt))
        }
        XCTAssertNil(plan.waypoints[3].planningWind, "the destination carries no leg")
    }

    func testAPilotWindIsStoredAsThePilots() {
        FlightPlan.windsAloftProvider = { _, _, _ in self.wind(90, 40) }
        var plan = route(departing: departure)
        plan.waypoints[1].windDirection = 270
        plan.waypoints[1].windSpeed = 10
        plan.calculateRouteData()

        XCTAssertEqual(plan.waypoints[1].planningWind, .init(directionDegTrue: 270, speedKt: 10, source: .pilot))
        XCTAssertEqual(plan.waypoints[0].planningWind?.source, .forecast)
    }

    /// The 23 Sep plan: planned with forecast winds, recomputed in flight when the cache (keyed by the
    /// hour, in memory) had nothing, and every leg came back at zero wind.
    func testARecomputeThatFindsNoForecastKeepsTheWindTheLegWasPlannedWith() {
        FlightPlan.windsAloftProvider = { _, _, _ in self.wind(90, 25) }
        var plan = route(departing: departure)
        plan.calculateRouteData()
        let planned = legTimes(plan)
        let winds = plan.waypoints.map(\.planningWind)

        FlightPlan.windsAloftProvider = { _, _, _ in nil }           // the cache is empty
        plan.plannedDepartureTime = departure.addingTimeInterval(3_600)
        plan.calculateRouteData()

        XCTAssertEqual(legTimes(plan), planned, "still timed against the headwind, not at 100 kt")
        XCTAssertEqual(plan.waypoints.map(\.planningWind), winds)
        XCTAssertEqual(plan.waypoints[0].estimatedElapsedTime ?? 0,
                       plan.waypoints[0].distance! / 75 * 3600, accuracy: 1)
    }

    func testAForecastThatCanBeHadReplacesTheStoredOne() {
        FlightPlan.windsAloftProvider = { _, _, _ in self.wind(90, 25) }
        var plan = route(departing: departure)
        plan.calculateRouteData()

        FlightPlan.windsAloftProvider = { _, _, _ in self.wind(270, 25) }
        plan.calculateRouteData()

        XCTAssertEqual(plan.waypoints[0].planningWind?.directionDegTrue, 270)
        XCTAssertEqual(plan.waypoints[0].estimatedElapsedTime ?? 0,
                       plan.waypoints[0].distance! / 125 * 3600, accuracy: 1)
    }

    /// A pilot's wind is kept on the waypoint itself; once it is taken off, the one stored from it is
    /// not reused behind the pilot's back.
    func testAPilotWindTakenOffIsNotReused() {
        FlightPlan.windsAloftProvider = nil
        var plan = route(departing: departure)
        plan.waypoints[0].windDirection = 90
        plan.waypoints[0].windSpeed = 25
        plan.calculateRouteData()
        XCTAssertEqual(plan.waypoints[0].planningWind?.source, .pilot)

        plan.waypoints[0].windDirection = nil
        plan.waypoints[0].windSpeed = nil
        plan.calculateRouteData()

        XCTAssertNil(plan.waypoints[0].planningWind)
        XCTAssertEqual(plan.waypoints[0].estimatedElapsedTime ?? 0,
                       plan.waypoints[0].distance! / 100 * 3600, accuracy: 1)
    }

    func testThePlanningWindSurvivesSavingAndLoading() throws {
        let validAt = departure
        FlightPlan.windsAloftProvider = { _, _, _ in
            FlightPlan.WindAloft(directionDegTrue: 250, speedKt: 18, validAt: validAt)
        }
        var plan = route(departing: departure)
        plan.calculateRouteData()

        let decoded = try JSONDecoder().decode(FlightPlan.self, from: try JSONEncoder().encode(plan))
        XCTAssertEqual(decoded.waypoints.map(\.planningWind), plan.waypoints.map(\.planningWind))
    }

    /// A plan saved before 6.1 has none of the keys: it decodes, with no planning wind.
    func testAnOlderPlanFileDecodesWithoutAPlanningWind() throws {
        var plan = route(departing: departure)
        plan.calculateRouteData()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(plan)) as? [String: Any])
        let waypoints = try XCTUnwrap(json["waypoints"] as? [[String: Any]])
        json["waypoints"] = waypoints.map { waypoint in
            waypoint.filter { !$0.key.hasPrefix("planningWind") }
        }
        json["etoAnchor"] = nil

        let decoded = try JSONDecoder().decode(FlightPlan.self, from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.waypoints.count, 4)
        XCTAssertTrue(decoded.waypoints.allSatisfy { $0.planningWind == nil })
        XCTAssertNil(decoded.etoAnchor)
    }

    /// A source a newer build adds does not cost the whole plan.
    func testAnUnknownWindSourceReadsAsAForecast() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"","latitude":47,"longitude":7,"remarks":"",
         "planningWindDirection":240,"planningWindSpeed":12,"planningWindSource":"lidar"}
        """
        let waypoint = try JSONDecoder().decode(FlightPlanWaypoint.self, from: Data(json.utf8))
        XCTAssertEqual(waypoint.planningWind?.source, .forecast)
        XCTAssertEqual(waypoint.planningWind?.speedKt, 12)
    }

    // MARK: - The forecast hour (6.1)

    /// Each leg asks for the time the aircraft is halfway along it: the departure plus everything
    /// before the leg (the +5 departure allowance included), plus half the leg at the planned airspeed.
    func testEachLegAsksForTheTimeItIsFlown() {
        var asked: [Date?] = []
        FlightPlan.windsAloftProvider = { _, _, flownAt in asked.append(flownAt); return nil }
        var plan = route(departing: departure)
        plan.calculateRouteData()

        let leg = plan.waypoints.map { $0.estimatedElapsedTime ?? 0 }   // at 100 kt: no wind
        let expected = [departure.addingTimeInterval(leg[0] / 2),
                        departure.addingTimeInterval(leg[0] + 300 + leg[1] / 2),
                        departure.addingTimeInterval(leg[0] + 300 + leg[1] + leg[2] / 2)]
        XCTAssertEqual(asked.count, 3, "level legs: one level each")
        for (a, e) in zip(asked, expected) { XCTAssertEqual(a?.timeIntervalSince(e) ?? .nan, 0, accuracy: 0.01) }
    }

    /// Once the flight has a take-off, the legs are flown from it.
    func testALegRecomputedInFlightAsksForTheHourFromTheTakeoff() {
        var asked: [Date?] = []
        FlightPlan.windsAloftProvider = { _, _, flownAt in asked.append(flownAt); return nil }
        var plan = route(departing: departure)
        let takeoff = departure.addingTimeInterval(1_000)
        plan.etoAnchor = takeoff
        plan.calculateRouteData()

        let halfway = plan.waypoints[0].estimatedElapsedTime! / 2
        XCTAssertEqual(asked.first??.timeIntervalSince(takeoff) ?? .nan, halfway, accuracy: 0.01)
    }

    func testARouteWithNoDateAsksForNoHour() {
        var asked: [Date?] = []
        FlightPlan.windsAloftProvider = { _, _, flownAt in asked.append(flownAt); return nil }
        var plan = route()
        plan.calculateRouteData()

        XCTAssertEqual(asked.count, 3)
        XCTAssertTrue(asked.allSatisfy { $0 == nil })
    }

    func testTheForecastHourIsTheLegsWhenItComesLater() {
        let now = departure.addingTimeInterval(20 * 60)                 // 20 past the hour
        let later = departure.addingTimeInterval(2 * 3600 + 30 * 60)    // two and a half hours on
        let candidates = WindsAloftService.forecastCandidates(lat: 47.2, lon: 7, flownAt: later, now: now)
        XCTAssertEqual(candidates.map(\.hour), [departure.addingTimeInterval(2 * 3600), departure],
                       "that hour when cached, else the forecast for now, as before")

        let sameHour = WindsAloftService.forecastCandidates(lat: 47.2, lon: 7,
                                                            flownAt: departure.addingTimeInterval(50 * 60), now: now)
        XCTAssertEqual(sameHour.map(\.hour), [departure])
        XCTAssertEqual(WindsAloftService.forecastCandidates(lat: 47.2, lon: 7, flownAt: nil, now: now).map(\.hour),
                       [departure], "no date: the current hour")
    }

    /// A leg flown in an hour already past reads that hour's forecast or none: the forecast for now
    /// describes other weather, and the wind it was planned with is the better answer.
    func testALegFlownInAnHourAlreadyPastDoesNotTakeTodaysForecast() {
        let now = departure.addingTimeInterval(3 * 3600 + 60)
        let candidates = WindsAloftService.forecastCandidates(lat: 47.2, lon: 7, flownAt: departure, now: now)
        XCTAssertEqual(candidates.map(\.hour), [departure])
    }

    @MainActor
    func testTheServiceReadsTheForecastForTheHourTheLegIsFlown() {
        let service = WindsAloftService()
        let here = CLLocationCoordinate2D(latitude: 47.2, longitude: 7.0)
        func forecast(_ direction: Double, validAt: String) -> WindsAloftService.Forecast {
            .init(lat: 47.25, lon: 7, validAt: validAt, levels: [
                .init(pressureHPa: 850, heightFt: 5000, directionDeg: direction, speedKt: 20),
            ])
        }
        let now = departure.addingTimeInterval(10 * 60)
        let legHour = departure.addingTimeInterval(2 * 3600)
        service.seed(forecast(200, validAt: "x"), at: here, hour: now)
        service.seed(forecast(300, validAt: "2026-09-21T16:00Z"), at: here, hour: legHour)

        let flownLater = service.wind(at: here, altitudeFt: 5000, flownAt: legHour.addingTimeInterval(900), now: now)
        XCTAssertEqual(flownLater?.directionDegTrue, 300, "the leg's own hour")
        XCTAssertEqual(flownLater?.validAt, WindsAloftService.validDate(forecast(300, validAt: "2026-09-21T16:00Z")))

        let flownNow = service.wind(at: here, altitudeFt: 5000, flownAt: now, now: now)
        XCTAssertEqual(flownNow?.directionDegTrue, 200)
        XCTAssertEqual(flownNow?.validAt, departure, "an unreadable valid-at falls back to the hour it was fetched in")

        let flownInThreeHours = service.wind(at: here, altitudeFt: 5000,
                                             flownAt: departure.addingTimeInterval(3 * 3600), now: now)
        XCTAssertEqual(flownInThreeHours?.directionDegTrue, 200, "no forecast for that hour: the current one, as before")
    }

    // MARK: - The level a leg is flown at (6.1)

    /// A leg's wind is read where it is flown: at its midpoint, at its level.
    func testALevelLegTakesTheWindAtItsLevelAtItsMidpoint() {
        var asked: [(CLLocationCoordinate2D, Double)] = []
        FlightPlan.windsAloftProvider = { coordinate, altitude, _ in
            asked.append((coordinate, altitude)); return self.wind(240, 15)
        }
        var plan = route(departing: departure)
        plan.calculateRouteData()

        XCTAssertEqual(asked.count, 3, "one level, one lookup per leg")
        XCTAssertEqual(asked[0].0.longitude, 7.15, accuracy: 0.001, "halfway between 7.0 and 7.3")
        XCTAssertEqual(asked[0].1, 5000)
        XCTAssertEqual(plan.waypoints[0].planningWind?.directionDegTrue, 240)
    }

    /// Climbing from the departure at field elevation to 5,000 ft: the vector average of the winds at
    /// both, not the surface wind of the first waypoint's altitude. The stored planning wind is that
    /// average.
    func testALegBetweenTwoLevelsTakesTheVectorAverageOfTheirWinds() throws {
        var asked: [Double] = []
        FlightPlan.windsAloftProvider = { _, altitude, _ in
            asked.append(altitude)
            return altitude < 3000 ? self.wind(180, 10) : self.wind(270, 30)
        }
        var plan = route(departing: departure)
        plan.waypoints[0].altitude = 1400
        plan.calculateRouteData()

        XCTAssertEqual(Array(asked.prefix(2)), [1400, 5000])
        let stored = try XCTUnwrap(plan.waypoints[0].planningWind)
        let mean = FlightPlan.vectorMean(wind(180, 10), wind(270, 30))
        XCTAssertEqual(stored.directionDegTrue, mean.directionDegTrue, accuracy: 0.001)
        XCTAssertEqual(stored.speedKt, mean.speedKt, accuracy: 0.001)
        // Southerly 10 and westerly 30: from 252°, 15.8 kt.
        XCTAssertEqual(mean.directionDegTrue, 251.57, accuracy: 0.1)
        XCTAssertEqual(mean.speedKt, hypot(5, 15), accuracy: 0.01)
        XCTAssertEqual(plan.waypoints[1].planningWind?.directionDegTrue, 270, "the next leg is level again")
    }

    func testWindsAreAveragedAsVectorsNotAsDirections() {
        let north = FlightPlan.vectorMean(wind(350, 20), wind(10, 20))
        XCTAssertEqual(north.directionDegTrue.truncatingRemainder(dividingBy: 360), 0, accuracy: 0.001,
                       "the mean of 350 and 010 is north, not south")
        XCTAssertEqual(north.speedKt, 20 * cos(10 * .pi / 180), accuracy: 0.001)
        XCTAssertEqual(FlightPlan.vectorMean(wind(90, 20), wind(270, 20)).speedKt, 0, accuracy: 0.001,
                       "opposite winds cancel")
    }

    func testAPilotWindStillOutranksTheLegsForecast() {
        FlightPlan.windsAloftProvider = { _, _, _ in self.wind(90, 40) }
        var plan = route(departing: departure)
        plan.waypoints[1].altitude = 7000
        plan.waypoints[0].windDirection = 300
        plan.waypoints[0].windSpeed = 12
        plan.calculateRouteData()
        XCTAssertEqual(plan.waypoints[0].planningWind, .init(directionDegTrue: 300, speedKt: 12, source: .pilot))
    }

    /// A waypoint with no altitude: the leg is flown at the other end's.
    func testAnEndWithoutAnAltitudeTakesTheOthersLevel() {
        var asked: [Double] = []
        FlightPlan.windsAloftProvider = { _, altitude, _ in asked.append(altitude); return nil }
        var plan = route(departing: departure)
        plan.waypoints[0].altitude = nil
        plan.calculateRouteData()
        XCTAssertEqual(asked.first, 5000)
    }

    func testTheMidpointIsHalfwayAlongTheGreatCircle() {
        let mid = FlightPlan.midpoint(.init(latitude: 47, longitude: 7), .init(latitude: 47, longitude: 9))
        XCTAssertEqual(mid.longitude, 8, accuracy: 1e-9)
        XCTAssertGreaterThan(mid.latitude, 47, "a great circle bows towards the pole")
        let across = FlightPlan.midpoint(.init(latitude: 0, longitude: 179), .init(latitude: 0, longitude: -179))
        XCTAssertEqual(abs(across.longitude), 180, accuracy: 1e-9, "across the antimeridian, not through Greenwich")
    }
}
