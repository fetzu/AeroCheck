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

    // MARK: - Nearest-point scrub lookup (PR-26)

    private func timedTrack() -> [GPSPoint] {
        // Points at t = 0, 10, 20, 30, 40 s.
        (0..<5).map { i in
            GPSPoint(latitude: 47.0 + Double(i) * 0.01, longitude: 8.0,
                     altitude: Double(i) * 100,
                     timestamp: Date(timeIntervalSince1970: Double(i) * 10))
        }
    }

    func testClosestByTimestampReturnsNilForEmptyTrack() {
        XCTAssertNil([GPSPoint]().closestByTimestamp(to: Date()))
    }

    func testClosestByTimestampFindsExactAndNearest() {
        let track = timedTrack()
        // Exact hit at t=20 → the third point (altitude 200).
        XCTAssertEqual(track.closestByTimestamp(to: Date(timeIntervalSince1970: 20))?.altitude, 200)
        // t=23 is nearer to t=20 than t=30.
        XCTAssertEqual(track.closestByTimestamp(to: Date(timeIntervalSince1970: 23))?.altitude, 200)
        // t=27 is nearer to t=30.
        XCTAssertEqual(track.closestByTimestamp(to: Date(timeIntervalSince1970: 27))?.altitude, 300)
    }

    func testClosestByTimestampClampsBeyondTrackBounds() {
        let track = timedTrack()
        // Before the first point → first point (altitude 0).
        XCTAssertEqual(track.closestByTimestamp(to: Date(timeIntervalSince1970: -100))?.altitude, 0)
        // After the last point → last point (altitude 400).
        XCTAssertEqual(track.closestByTimestamp(to: Date(timeIntervalSince1970: 9999))?.altitude, 400)
    }
}

/// Tests the flight-clock formatting extracted from AppState. (Phase 4 — AppState decomposition)
final class FlightClockTests: XCTestCase {

    func testFormattedDurationIsHHMMSS() {
        XCTAssertEqual(FlightClock.formattedDuration(seconds: 0), "00:00:00")
        XCTAssertEqual(FlightClock.formattedDuration(seconds: 59), "00:00:59")
        XCTAssertEqual(FlightClock.formattedDuration(seconds: 3661), "01:01:01")
        XCTAssertEqual(FlightClock.formattedDuration(seconds: 3600 * 25 + 1), "25:00:01")
    }

    func testNegativeDurationClampsToZero() {
        // Clock skew (start in the future) must not render "-1:-1:..".
        XCTAssertEqual(FlightClock.formattedDuration(seconds: -5), "00:00:00")
    }

    func testTimeOfDayAddsUTCSuffixOnlyWhenForced() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(FlightClock.formattedTimeOfDay(date, useUTC: true).contains("(UTC)"))
        XCTAssertFalse(FlightClock.formattedTimeOfDay(date, useUTC: false).contains("(UTC)"))
        XCTAssertFalse(FlightClock.formattedTimeOfDay(date, useUTC: false).isEmpty)
    }
}
