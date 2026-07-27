import XCTest
import CoreLocation
@testable import AeroCheck

/// Tests for the MeteoSwiss wind feed: freshness, geofencing, and unit conversion.
///
/// Wind is a BRIEFING input, not an instrument input. It is a surface observation (10 m above ground
/// at the station's own elevation), which is the right instrument for a departure or approach
/// briefing — both happen at the surface, near an airfield — and the wrong one for reasoning about
/// air at altitude. The former `calculateEstimatedAirspeed` was removed for that reason; see
/// `SpeedIndicatorTests` for the annunciation side.
///
/// @MainActor because WindDataService is main-actor isolated like every other service. (CQ-07)
@MainActor
final class WindDataServiceTests: XCTestCase {

    private let swissCoord = CLLocationCoordinate2D(latitude: 47.0, longitude: 8.0)

    private func wind(ageMinutes: Double,
                      speedKmh: Double = 20,
                      dir: Double = 0,
                      stationAltitude: Double = 500) -> WindData {
        WindData(
            stationName: "TEST",
            speedKmh: speedKmh,
            directionDegrees: dir,
            timestamp: Date().addingTimeInterval(-ageMinutes * 60),
            stationCoordinate: swissCoord,
            distanceMeters: 1000,
            stationAltitudeMeters: stationAltitude
        )
    }

    // MARK: - Freshness (UX-04)

    func testFreshWindIsUsable() {
        let service = WindDataService()
        service.currentWindData = wind(ageMinutes: 1)
        XCTAssertTrue(service.hasFreshWind)
        XCTAssertFalse(service.isWindDataStale)
    }

    /// A reading past the 20-minute window must not be briefed as current.
    func testStaleWindIsNotFresh() {
        let service = WindDataService()
        service.currentWindData = wind(ageMinutes: 45)
        XCTAssertFalse(service.hasFreshWind)
        XCTAssertTrue(service.isWindDataStale)
    }

    func testNoWindDataIsNeitherFreshNorStale() {
        let service = WindDataService()
        service.currentWindData = nil
        XCTAssertFalse(service.hasFreshWind)
        XCTAssertFalse(service.isWindDataStale, "absent wind is not the same as stale wind")
        XCTAssertNil(service.windDataAgeSeconds)
    }

    func testAgeIsReported() {
        let service = WindDataService()
        service.currentWindData = wind(ageMinutes: 5)
        guard let age = service.windDataAgeSeconds else { return XCTFail("age must be reported") }
        XCTAssertEqual(age, 300, accuracy: 5)
    }

    // MARK: - Geofence

    func testInsideSwitzerland() {
        XCTAssertTrue(WindDataService().isInSwitzerland(swissCoord))
    }

    func testOutsideSwitzerland() {
        let service = WindDataService()
        XCTAssertFalse(service.isInSwitzerland(CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35)))
        XCTAssertFalse(service.isInSwitzerland(nil))
    }

    // MARK: - Units

    /// The feed reports km/h; briefings and aviation everywhere else in the app use knots.
    func testSpeedConvertsToKnots() {
        XCTAssertEqual(wind(ageMinutes: 0, speedKmh: 100).speedKnots, 53.9957, accuracy: 0.001)
        XCTAssertEqual(wind(ageMinutes: 0, speedKmh: 0).speedKnots, 0, accuracy: 0.001)
    }

    /// Station provenance must survive onto the model — it is what lets a pilot judge whether the
    /// reading is representative, and it is how the service filters candidates.
    func testStationProvenanceIsCarried() {
        let w = wind(ageMinutes: 1, stationAltitude: 1888)
        XCTAssertEqual(w.stationAltitudeMeters, 1888)
        XCTAssertEqual(w.distanceMeters, 1000)
        XCTAssertEqual(w.stationName, "TEST")
    }
}
