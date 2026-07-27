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
        FlightPlan.windsAloftProvider = { _, _ in self.wind(90, 50) }
        var waypoint = FlightPlanWaypoint(coordinate: CLLocationCoordinate2D(latitude: 47, longitude: 7))
        waypoint.windDirection = 270
        waypoint.windSpeed = 15
        let used = FlightPlan.legWind(for: waypoint, at: waypoint.coordinate)
        XCTAssertEqual(used, wind(270, 15))
    }

    func testForecastUsedWhenNoPilotWind() {
        FlightPlan.windsAloftProvider = { _, _ in self.wind(180, 12) }
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

        func eet(withWind provider: ((CLLocationCoordinate2D, Double) -> FlightPlan.WindAloft?)?) -> TimeInterval {
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
        let headwind = eet(withWind: { _, _ in self.wind(90, 25) })   // from the east, flying east
        let tailwind = eet(withWind: { _, _ in self.wind(270, 25) })  // from the west, flying east

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
}
