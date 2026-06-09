import XCTest
@testable import AeroCheck

/// Tests the CloudKit conflict-merge and ingest-validation logic that protect the pilot's logbook
/// from silent loss / corruption when synced records arrive. (ARCH-02, SEC-17)
final class FlightMergeValidationTests: XCTestCase {

    private func point(_ lat: Double, _ lon: Double) -> GPSPoint {
        GPSPoint(latitude: lat, longitude: lon, altitude: 1000)
    }

    private func flight(
        id: UUID = UUID(), modifiedAt: Date, name: String = "", notes: String = "",
        track: [GPSPoint] = [], goAround: Int = 0, touchAndGo: Int = 0, fullStop: Int = 0
    ) -> Flight {
        Flight(
            id: id, name: name, gpsTrack: track, notes: notes,
            goAroundCount: goAround, touchAndGoCount: touchAndGo, fullStopCount: fullStop,
            modifiedAt: modifiedAt
        )
    }

    // MARK: - Merge

    func testNewerMetadataWins() {
        let id = UUID()
        let older = flight(id: id, modifiedAt: Date(timeIntervalSince1970: 100), name: "Old", notes: "old")
        let newer = flight(id: id, modifiedAt: Date(timeIntervalSince1970: 200), name: "New", notes: "new")

        let merged = Flight.merge(older, newer)

        XCTAssertEqual(merged.name, "New")
        XCTAssertEqual(merged.notes, "new")
        XCTAssertEqual(merged.modifiedAt, Date(timeIntervalSince1970: 200))
    }

    func testLongerTrackAndHigherCountsSurviveEvenWhenMetadataIsOlder() {
        let id = UUID()
        // The device holding the LONGER track / higher landing count made the OLDER metadata edit.
        let longTrack = (0..<50).map { point(47.0 + Double($0) * 0.001, 8.0) }
        let recorder = flight(id: id, modifiedAt: Date(timeIntervalSince1970: 100),
                              name: "Recorder", track: longTrack, fullStop: 3)
        let editor = flight(id: id, modifiedAt: Date(timeIntervalSince1970: 200),
                            name: "Editor", track: [], fullStop: 0)

        let merged = Flight.merge(recorder, editor)

        XCTAssertEqual(merged.name, "Editor", "Newer metadata still wins")
        XCTAssertEqual(merged.gpsTrack.count, 50, "A longer recorded track is never dropped")
        XCTAssertEqual(merged.fullStopCount, 3, "A higher landing count is kept (max)")
    }

    func testLandingCountsAndTimesTakeTheRicherSide() {
        let id = UUID()
        let a = flight(id: id, modifiedAt: Date(timeIntervalSince1970: 100),
                       goAround: 2, touchAndGo: 5, fullStop: 1)
        let b = flight(id: id, modifiedAt: Date(timeIntervalSince1970: 200),
                       goAround: 1, touchAndGo: 7, fullStop: 0)

        let merged = Flight.merge(a, b)

        XCTAssertEqual(merged.goAroundCount, 2)
        XCTAssertEqual(merged.touchAndGoCount, 7)
        XCTAssertEqual(merged.fullStopCount, 1)
    }

    func testMergePreservesAppendOnlyDataRegardlessOfArgumentOrder() {
        let id = UUID()
        let a = flight(id: id, modifiedAt: Date(timeIntervalSince1970: 100),
                       name: "A", track: [point(47, 8), point(47.1, 8.1)], fullStop: 2)
        let b = flight(id: id, modifiedAt: Date(timeIntervalSince1970: 200),
                       name: "B", track: [point(47, 8)], fullStop: 1)

        let ab = Flight.merge(a, b)
        let ba = Flight.merge(b, a)

        XCTAssertEqual(ab.gpsTrack.count, 2)
        XCTAssertEqual(ba.gpsTrack.count, 2)
        XCTAssertEqual(ab.fullStopCount, 2)
        XCTAssertEqual(ba.fullStopCount, 2)
        XCTAssertEqual(ab.name, "B") // both keep the newer metadata
        XCTAssertEqual(ba.name, "B")
    }

    // MARK: - Ingest validation

    func testValidFlightPassesIngest() {
        let f = flight(modifiedAt: Date(), track: [point(47, 8)])
        XCTAssertNotNil(f.validatedForIngest())
    }

    func testRejectsRecordFromNewerSchema() {
        var f = flight(modifiedAt: Date())
        f.schemaVersion = Flight.currentSchemaVersion + 1
        XCTAssertNil(f.validatedForIngest(), "A record from a newer app build must be rejected")
    }

    func testRejectsNonFiniteOrOutOfRangeCoordinate() {
        XCTAssertNil(flight(modifiedAt: Date(), track: [point(.nan, 8)]).validatedForIngest())
        XCTAssertNil(flight(modifiedAt: Date(), track: [point(.infinity, 8)]).validatedForIngest())
        XCTAssertNil(flight(modifiedAt: Date(), track: [point(95, 8)]).validatedForIngest(), "lat > 90")
        XCTAssertNil(flight(modifiedAt: Date(), track: [point(47, 200)]).validatedForIngest(), "lon > 180")
    }

    // MARK: - Settings clamping

    func testSettingsClampsOutOfRangeNumerics() {
        var s = AppSettings()
        s.gpsRecordingInterval = 99999
        s.waypointProximityThreshold = -5

        let clamped = s.clampedForIngest()

        XCTAssertEqual(clamped.gpsRecordingInterval, 300)
        XCTAssertEqual(clamped.waypointProximityThreshold, 10)
    }

    func testSettingsLeavesValidNumericsUnchanged() {
        var s = AppSettings()
        s.gpsRecordingInterval = 5
        s.waypointProximityThreshold = 500

        let clamped = s.clampedForIngest()

        XCTAssertEqual(clamped.gpsRecordingInterval, 5)
        XCTAssertEqual(clamped.waypointProximityThreshold, 500)
    }

    // MARK: - Night mode persistence (UX-09)

    func testNightModeDefaultsOffAndRoundTrips() throws {
        // Backward compatibility: settings saved before nightMode existed (key absent) decode to off.
        let legacy = Data(#"{"keepScreenOn":true}"#.utf8)
        let decodedLegacy = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertFalse(decodedLegacy.nightMode, "Absent nightMode defaults to off")

        var s = AppSettings()
        s.nightMode = true
        let roundTripped = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertTrue(roundTripped.nightMode)
    }
}
