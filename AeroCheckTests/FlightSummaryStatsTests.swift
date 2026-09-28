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

    // MARK: - Stats from a file (S9-10, S9-16)

    /// The review's case: a flight file whose cached distance, maximum altitude and engine hours are
    /// 1e300. It must import, and the Logbook row and header must draw it. `Int(_:)` trapped on it.
    @MainActor
    func testA1e300FlightImportsAndItsStatsRenderWithoutTrapping() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var crafted = Flight(startTime: start, stopTime: start.addingTimeInterval(1800),
                             gpsTrack: [point(47.0, 8.0, alt: 500), point(47.1, 8.1, alt: 1200)])
        crafted.cachedDistanceKm = 1e300
        crafted.cachedMaxAltitudeMeters = 1e300
        crafted.engineHourStart = 1e300
        crafted.engineHourEnd = 1e300
        let file = try XCTUnwrap(crafted.toJSON())
        XCTAssertTrue(String(decoding: file, as: UTF8.self).contains("e+300"), "precondition: the file carries 1e300")

        let appState = makeTestAppState()
        XCTAssertTrue(appState.importFlight(from: file), "the flight imports")
        let imported = try XCTUnwrap(appState.flights.first)

        let trackKm = Flight.computeDistanceKm(imported.gpsTrack)
        XCTAssertEqual(imported.cachedDistanceKm ?? -1, trackKm, accuracy: 0.0001, "the distance comes from the track")
        XCTAssertEqual(imported.cachedMaxAltitudeMeters, 1200, "so does the maximum altitude")
        XCTAssertEqual(imported.cachedDurationSeconds ?? -1, 1800, accuracy: 0.0001)
        XCTAssertNil(imported.engineHoursFlownFormatted, "impossible readings read as not logged")

        XCTAssertEqual(FlightRowView.statsLine(for: imported, nauticalMiles: false),
                       "wt9-dynamic · \(Int(trackKm.rounded())) km")
        XCTAssertEqual(FlightDetailView.distanceText(for: imported, nauticalMiles: false),
                       "\(Int(trackKm.rounded())) km")
        XCTAssertEqual(FlightDetailView.maxAltitudeText(for: imported), "3937 ft")
    }

    /// A file's cached figures are a claim, the track is the evidence: a plausible but wrong distance
    /// must not reach the Logbook's totals either.
    func testAnImportedFlightTakesItsStatsFromItsTrackNotFromTheFile() throws {
        var crafted = Flight(gpsTrack: [point(47.0, 8.0, alt: 500), point(47.1, 8.1, alt: 900)])
        crafted.cachedDistanceKm = 4_000
        crafted.cachedMaxAltitudeMeters = 3_000
        let imported = try Flight.fromJSON(XCTUnwrap(crafted.toJSON()))

        XCTAssertEqual(imported.cachedDistanceKm ?? -1, Flight.computeDistanceKm(imported.gpsTrack), accuracy: 0.0001)
        XCTAssertEqual(imported.cachedMaxAltitudeMeters, 900)
    }

    /// Defence in depth: the row, the header and the hour formatter stay safe for a flight that never
    /// went through ingest.
    func testTheLogbookTextIsSafeForNumbersThatBypassedIngest() {
        var raw = Flight(gpsTrack: [point(47.0, 8.0, alt: 500)])
        raw.cachedDistanceKm = 1e300
        raw.cachedMaxAltitudeMeters = -1e300
        raw.touchAndGoCount = Int.max
        raw.fullStopCount = 1

        XCTAssertEqual(raw.totalLandings, Int.max, "saturates instead of trapping on overflow")
        XCTAssertEqual(FlightRowView.statsLine(for: raw, nauticalMiles: true), "wt9-dynamic · \(Int.max) ldg")
        XCTAssertEqual(FlightDetailView.distanceText(for: raw, nauticalMiles: false), "—")
        XCTAssertEqual(FlightDetailView.maxAltitudeText(for: raw), "—")
        XCTAssertEqual(Flight.formatHoursTime(1e300), "--:--")
        XCTAssertEqual(Flight.formatHoursTime(.nan), "--:--")
        XCTAssertEqual(Flight.formatHoursTime(-.infinity), "--:--")
        XCTAssertEqual(Flight.formatHoursTime(1.5), "1:30", "an ordinary reading is unchanged")
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
