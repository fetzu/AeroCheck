import XCTest
import CoreLocation
@testable import AeroCheck

/// Tests for estimated-airspeed wind handling: staleness fall-back and geofencing.
/// (UX-04 stale wind is ignored; estimation only inside Switzerland.)
final class WindDataServiceTests: XCTestCase {

    private let swissCoord = CLLocationCoordinate2D(latitude: 47.0, longitude: 8.0)

    private func wind(ageMinutes: Double, speedKmh: Double = 20, dir: Double = 0) -> WindData {
        WindData(
            stationName: "TEST",
            speedKmh: speedKmh,
            directionDegrees: dir,
            timestamp: Date().addingTimeInterval(-ageMinutes * 60),
            stationCoordinate: swissCoord,
            distanceMeters: 1000
        )
    }

    func testFreshWindProducesEstimate() {
        let service = WindDataService()
        service.currentWindData = wind(ageMinutes: 1)
        let est = service.calculateEstimatedAirspeed(groundSpeedKnots: 80, trackDegrees: 0, coordinate: swissCoord)
        XCTAssertNotNil(est, "Fresh wind should yield an estimate")
    }

    func testStaleWindFallsBackToGroundSpeed() {
        let service = WindDataService()
        service.currentWindData = wind(ageMinutes: 30) // older than the 20-min max age
        let est = service.calculateEstimatedAirspeed(groundSpeedKnots: 80, trackDegrees: 0, coordinate: swissCoord)
        XCTAssertNil(est, "Stale wind (>20 min) must not drive airspeed; caller falls back to GND SPD")
    }

    func testOutsideSwitzerlandReturnsNil() {
        let service = WindDataService()
        service.currentWindData = wind(ageMinutes: 1)
        let outside = CLLocationCoordinate2D(latitude: 40.0, longitude: 8.0)
        XCTAssertNil(service.calculateEstimatedAirspeed(groundSpeedKnots: 80, trackDegrees: 0, coordinate: outside))
    }

    func testNoWindDataReturnsNil() {
        let service = WindDataService()
        service.currentWindData = nil
        XCTAssertNil(service.calculateEstimatedAirspeed(groundSpeedKnots: 80, trackDegrees: 0, coordinate: swissCoord))
    }

    func testHeadwindIncreasesAirspeed() {
        let service = WindDataService()
        // Wind FROM 360° (north) at 20 km/h; flying track 360° → pure headwind → IAS > GND.
        service.currentWindData = wind(ageMinutes: 1, speedKmh: 37.04 /* ~20 kt */, dir: 360)
        let est = service.calculateEstimatedAirspeed(groundSpeedKnots: 80, trackDegrees: 360, coordinate: swissCoord)
        XCTAssertNotNil(est)
        XCTAssertGreaterThan(est ?? 0, 80)
    }
}
