import XCTest
@testable import AeroCheck

/// Tests the precomputed-at-save flight summary stats and the lightweight haversine fallback, so the
/// flight-log list never recomputes an O(n) `CLLocation.distance` per row on every render. (PERF-22)
final class FlightSummaryStatsTests: XCTestCase {

    private func point(_ lat: Double, _ lon: Double, alt: Double = 0) -> GPSPoint {
        GPSPoint(latitude: lat, longitude: lon, altitude: alt)
    }

    func testHaversineApproximatesAKnownDistance() {
        // Great-circle distance between two Swiss points ≈ 230 km (spherical haversine).
        let km = Flight.haversineMeters(47.45, 8.55, 46.23, 6.11) / 1000
        XCTAssertEqual(km, 230, accuracy: 6)
    }

    func testComputeDistanceKmIsZeroForAStationaryTrack() {
        XCTAssertEqual(Flight.computeDistanceKm([point(47, 8), point(47, 8)]), 0, accuracy: 0.0001)
    }

    func testCachedDistanceIsUsedWhenPresent() {
        var flight = Flight(gpsTrack: [point(47.0, 8.0), point(47.1, 8.1)])
        XCTAssertGreaterThan(flight.distanceKilometers, 0, "Lazily computed when no cache")

        flight.cachedDistanceKm = 999
        XCTAssertEqual(flight.distanceKilometers, 999, "The cached value is used when present")
    }

    func testComputeSummaryStatsPopulatesTheCache() {
        let start = Date(timeIntervalSince1970: 0)
        var flight = Flight(
            startTime: start, stopTime: start.addingTimeInterval(3600),
            gpsTrack: [point(47.0, 8.0, alt: 500), point(47.1, 8.1, alt: 1200)]
        )
        XCTAssertNil(flight.cachedDistanceKm)

        flight.computeSummaryStats()

        XCTAssertNotNil(flight.cachedDistanceKm)
        XCTAssertEqual(flight.cachedMaxAltitudeMeters, 1200)
        XCTAssertEqual(flight.cachedDurationSeconds ?? -1, 3600, accuracy: 0.0001)
    }

    func testCachedStatsSurviveCodableRoundTrip() throws {
        var flight = Flight(gpsTrack: [point(47.0, 8.0, alt: 100), point(47.2, 8.2, alt: 300)])
        flight.computeSummaryStats()

        let decoded = try JSONDecoder().decode(Flight.self, from: JSONEncoder().encode(flight))

        XCTAssertEqual(decoded.cachedMaxAltitudeMeters, 300)
        XCTAssertEqual(decoded.cachedDistanceKm, flight.cachedDistanceKm)
    }
}
