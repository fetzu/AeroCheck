import XCTest
import CloudKit
import CoreLocation
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

    // MARK: - Local-load salvage (RES-02)
    //
    // Local flight files are the only copy of a recorded flight, so they get a salvaging loader
    // rather than the all-or-nothing ingest gate the untrusted paths use. A pilot can see a small
    // gap in a track; they cannot see an absent flight.

    func testSalvageKeepsFlightAndDropsOnlyTheBadPoints() throws {
        let f = flight(modifiedAt: Date(),
                       track: [point(47, 8), point(.nan, 8), point(47.1, 8.1), point(95, 8), point(47.2, 8.2)])

        // Precondition: the ingest validator throws the whole flight away for exactly this input.
        XCTAssertNil(f.validatedForIngest())

        let salvaged = try XCTUnwrap(f.sanitizedForLocalLoad(),
                                     "A salvageable flight must survive local load")
        XCTAssertEqual(salvaged.id, f.id)
        XCTAssertEqual(salvaged.gpsTrack.count, 3, "Only the two invalid points should be dropped")
        XCTAssertTrue(salvaged.gpsTrack.allSatisfy {
            GeoValidation.isValidLatLon($0.latitude, $0.longitude)
        })
    }

    func testSalvageStillRejectsANewerSchema() {
        var f = flight(modifiedAt: Date(), track: [point(47, 8)])
        f.schemaVersion = Flight.currentSchemaVersion + 1
        XCTAssertNil(f.sanitizedForLocalLoad(),
                     "A record written by a newer build cannot be interpreted and must not be rewritten")
    }

    func testSalvageClampsAFutureModifiedAtInsteadOfDiscardingTheFlight() throws {
        let future = Date().addingTimeInterval(FlightDataLimits.maxClockSkew + 86_400)
        let f = flight(modifiedAt: future, track: [point(47, 8)])

        XCTAssertNil(f.validatedForIngest(), "Precondition: ingest rejects an implausible timestamp")

        let salvaged = try XCTUnwrap(f.sanitizedForLocalLoad())
        XCTAssertLessThanOrEqual(salvaged.modifiedAt, Date().addingTimeInterval(FlightDataLimits.maxClockSkew))
        XCTAssertEqual(salvaged.gpsTrack.count, 1, "Clamping the timestamp must not cost the track")
    }

    func testSalvageLeavesACleanFlightUntouched() throws {
        let f = flight(modifiedAt: Date(), track: [point(47, 8), point(47.1, 8.1)])
        let salvaged = try XCTUnwrap(f.sanitizedForLocalLoad())
        XCTAssertEqual(salvaged.gpsTrack.count, 2)
        XCTAssertEqual(salvaged.modifiedAt, f.modifiedAt)
    }

    // MARK: - The numbers a flight carries (S9-10, S9-16)
    //
    // `Int(_:)` traps past ±9.2e18. JSON cannot carry NaN or 1e400 (the decoder refuses both), but
    // 1e300 decodes to a finite Double: an imported or synced flight carrying it crashed the Logbook
    // on every device the pilot owns.

    /// Every number out of range, as a crafted file or record carries them.
    private func poisonedFlight() -> Flight {
        var f = flight(modifiedAt: Date(),
                       track: [GPSPoint(latitude: 47, longitude: 8, altitude: 1000, speed: 1e300, course: 1e300),
                               GPSPoint(latitude: 47.1, longitude: 8.1, altitude: 1e300),
                               GPSPoint(latitude: 47.2, longitude: 8.2, altitude: 1200)],
                       goAround: -5, touchAndGo: Int.max, fullStop: Int.max)
        f.cachedDistanceKm = 1e300
        f.cachedMaxAltitudeMeters = 1e300
        f.cachedDurationSeconds = -1
        f.engineHourStart = 1e300
        f.engineHourEnd = -3
        var overrides = LogbookOverrides()
        overrides.nightMinutes = Int.max
        overrides.ifrMinutes = -10
        overrides.landingsNight = Int.min
        f.logbook = overrides
        return f
    }

    private func assertBounded(_ f: Flight, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(f.cachedDistanceKm, "recomputed from the track on demand", file: file, line: line)
        XCTAssertNil(f.cachedMaxAltitudeMeters, file: file, line: line)
        XCTAssertNil(f.cachedDurationSeconds, file: file, line: line)
        XCTAssertNil(f.engineHourStart, "reads as not logged", file: file, line: line)
        XCTAssertNil(f.engineHourEnd, file: file, line: line)
        XCTAssertEqual(f.gpsTrack.map(\.altitude), [1000, 1200], "only the point at 1e300 m goes", file: file, line: line)
        XCTAssertEqual(f.gpsTrack.first?.speed, -1, "CoreLocation's own 'not known'", file: file, line: line)
        XCTAssertEqual(f.gpsTrack.first?.course, -1, file: file, line: line)
        XCTAssertEqual(f.goAroundCount, 0, file: file, line: line)
        XCTAssertEqual(f.touchAndGoCount, FlightDataLimits.maxLandingsPerFlight, file: file, line: line)
        XCTAssertEqual(f.fullStopCount, FlightDataLimits.maxLandingsPerFlight, file: file, line: line)
        XCTAssertEqual(f.logbook?.nightMinutes, FlightDataLimits.maxLoggedMinutesPerFlight, file: file, line: line)
        XCTAssertEqual(f.logbook?.ifrMinutes, 0, file: file, line: line)
        XCTAssertEqual(f.logbook?.landingsNight, 0, file: file, line: line)
    }

    func testIngestBoundsEveryNumberRatherThanRejectingTheFlight() throws {
        // Rejecting would stop a legitimate old record from syncing over one bad value (RES-02).
        let bounded = try XCTUnwrap(poisonedFlight().validatedForIngest())
        assertBounded(bounded)
    }

    func testLocalLoadRepairsAFlightStoredBeforeTheBounds() throws {
        let repaired = try XCTUnwrap(poisonedFlight().sanitizedForLocalLoad())
        assertBounded(repaired)
    }

    /// The flight file an import wrote before this fix: it must still load, repaired.
    func testAFlightFileCarrying1e300StillLoadsAndIsRepaired() throws {
        let directory = makeTestDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let file = try encoder.encode(poisonedFlight())
        XCTAssertTrue(String(decoding: file, as: UTF8.self).contains("e+300"), "precondition: 1e300 is on disk")
        try file.write(to: directory.appendingPathComponent("poisoned.json"))

        let loaded = DataPersistenceManager.decodeFlights(in: directory)

        XCTAssertEqual(loaded.count, 1, "an existing flight never fails to load")
        assertBounded(try XCTUnwrap(loaded.first))
    }

    func testACloudKitRecordCarrying1e300IsBoundedOnArrival() throws {
        let payload = try SyncManager.flightRecordPayload(poisonedFlight())
        let received = try XCTUnwrap(SyncManager.flightFromPayload(inline: payload.inline, asset: payload.asset))
        assertBounded(received)
    }

    func testPlausibleNumbersPassThroughUntouched() throws {
        var f = flight(modifiedAt: Date(),
                       track: [GPSPoint(latitude: 47, longitude: 8, altitude: 450, speed: -1, course: -1),
                               GPSPoint(latitude: 47.1, longitude: 8.1, altitude: 2400, speed: 55, course: 245)],
                       goAround: 1, touchAndGo: 6, fullStop: 1)
        f.cachedDistanceKm = 13.4
        f.cachedMaxAltitudeMeters = 2400
        f.cachedDurationSeconds = 3600
        f.engineHourStart = 1234.5
        f.engineHourEnd = 1235.6
        var overrides = LogbookOverrides()
        overrides.nightMinutes = 35
        f.logbook = overrides

        let validated = try XCTUnwrap(f.validatedForIngest())

        XCTAssertEqual(validated.cachedDistanceKm, 13.4)
        XCTAssertEqual(validated.cachedMaxAltitudeMeters, 2400)
        XCTAssertEqual(validated.cachedDurationSeconds, 3600)
        XCTAssertEqual(validated.engineHourStart, 1234.5)
        XCTAssertEqual(validated.engineHourEnd, 1235.6)
        XCTAssertEqual(validated.gpsTrack.map(\.speed), [-1, 55])
        XCTAssertEqual(validated.gpsTrack.map(\.course), [-1, 245])
        XCTAssertEqual(validated.gpsTrack.map(\.id), f.gpsTrack.map(\.id))
        XCTAssertEqual(validated.totalLandings, 7)
        XCTAssertEqual(validated.logbook, overrides)
    }

    /// The plan a flight carries is shown in the Logbook (plan against actual, the nav log), so it
    /// is bounded with the flight. A waypoint at an impossible position is dropped, not the plan.
    func testTheFlightPlanAFlightCarriesIsBoundedWithIt() throws {
        var plan = FlightPlan(name: "Carried")
        plan.waypoints = [
            FlightPlanWaypoint(name: "A", coordinate: CLLocationCoordinate2D(latitude: 47, longitude: 7),
                               magneticCourse: 1e19, distance: 1e300, plannedGroundSpeed: Int.max,
                               estimatedElapsedTime: 1e300, cumulativeEET: 1e300),
            FlightPlanWaypoint(name: "X", coordinate: CLLocationCoordinate2D(latitude: 1e300, longitude: 7)),
            FlightPlanWaypoint(name: "B", coordinate: CLLocationCoordinate2D(latitude: 47.5, longitude: 7.5)),
        ]
        var f = flight(modifiedAt: Date(), track: [point(47, 8)])
        f.flightPlan = plan

        let ingested = try XCTUnwrap(f.validatedForIngest())
        let loaded = try XCTUnwrap(f.sanitizedForLocalLoad())
        for bounded in [ingested, loaded] {
            let carried = try XCTUnwrap(bounded.flightPlan, "the flight keeps its nav log")
            XCTAssertEqual(carried.waypoints.map(\.name), ["A", "B"])
            XCTAssertNil(carried.waypoints[0].magneticCourse)
            XCTAssertNil(carried.waypoints[0].distance)
            XCTAssertNil(carried.waypoints[0].plannedGroundSpeed)
            XCTAssertNil(carried.waypoints[0].estimatedElapsedTime)
            XCTAssertNil(carried.waypoints[0].cumulativeEET)
        }
    }

    // MARK: - CloudKit record payload (PERF-13: large-track CKAsset offload)

    func testSmallFlightStaysInlineWithNoAsset() throws {
        let f = flight(modifiedAt: Date(), track: [point(47, 8), point(47.1, 8.1)])
        let payload = try SyncManager.flightRecordPayload(f)

        XCTAssertNil(payload.asset, "A small flight needs no asset and stays fully inline")
        let decoded = SyncManager.flightFromPayload(inline: payload.inline, asset: nil)
        XCTAssertEqual(decoded?.gpsTrack.count, 2, "The inline blob round-trips the full track")
    }

    func testLargeFlightOffloadsTrackToAssetAndStripsInline() throws {
        // A track large enough to push the encoded flight past the inline budget.
        let longTrack = (0..<60_000).map { point(47.0 + Double($0) * 0.00001, 8.0) }
        let f = flight(modifiedAt: Date(), track: longTrack)
        let payload = try SyncManager.flightRecordPayload(f)

        XCTAssertNotNil(payload.asset, "An oversized flight must be offloaded to an asset")
        XCTAssertLessThanOrEqual(payload.inline.count, SyncManager.maxInlineFlightBytes,
                                 "The inline blob stays under the CloudKit inline cap")

        // The inline copy is track-stripped; only the asset carries the full track.
        let inlineOnly = SyncManager.flightFromPayload(inline: payload.inline, asset: nil)
        XCTAssertEqual(inlineOnly?.gpsTrack.count, 0, "Inline copy is track-stripped")

        // The asset is authoritative and is preferred when both are present.
        let full = SyncManager.flightFromPayload(inline: payload.inline, asset: payload.asset)
        XCTAssertEqual(full?.gpsTrack.count, longTrack.count,
                       "The asset payload restores the complete GPS track")
    }

    func testPayloadRejectsCorruptAndMissingBlobs() {
        XCTAssertNil(SyncManager.flightFromPayload(inline: nil, asset: nil), "No payload → nil")
        XCTAssertNil(SyncManager.flightFromPayload(inline: Data("not json".utf8), asset: nil),
                     "Undecodable payload → nil, never a partial flight")
    }

    // MARK: - Payload compression (sync optimization)

    func testPayloadIsCompressedAndRoundTrips() throws {
        let track = (0..<2_000).map { point(47.0 + Double($0) * 0.0001, 8.0) }
        let f = flight(modifiedAt: Date(), track: track)
        let payload = try SyncManager.flightRecordPayload(f)

        XCTAssertEqual(payload.inline.first, 0x01, "The inline blob is tagged compressed")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let rawJSON = try encoder.encode(f)
        XCTAssertLessThan(payload.inline.count, rawJSON.count / 2,
                          "Compression meaningfully shrinks a GPS-track payload on the wire")
        XCTAssertEqual(SyncManager.flightFromPayload(inline: payload.inline, asset: nil)?.gpsTrack.count, 2_000,
                       "The compressed blob round-trips the full track")
    }

    func testLegacyUncompressedPayloadStillDecodes() throws {
        // A record written before compression existed: raw JSON, no 0x01 marker.
        let f = flight(modifiedAt: Date(timeIntervalSince1970: 300), name: "Legacy", track: [point(47, 8)])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let rawJSON = try encoder.encode(f)
        XCTAssertNotEqual(rawJSON.first, 0x01, "Legacy blob is raw JSON, not marked compressed")

        let decoded = SyncManager.flightFromPayload(inline: rawJSON, asset: nil)
        XCTAssertEqual(decoded?.name, "Legacy")
        XCTAssertEqual(decoded?.gpsTrack.count, 1, "A pre-compression record still decodes (backward compatible)")
    }

    // MARK: - Split metadata / track records (sync optimization)

    func testTrackRecordNameRoundTrips() {
        let id = UUID()
        let name = SyncManager.trackRecordName(id)
        XCTAssertTrue(name.hasPrefix("track-"))
        XCTAssertEqual(SyncManager.flightId(fromTrackRecordName: name), id)
        XCTAssertNil(SyncManager.flightId(fromTrackRecordName: id.uuidString),
                     "A plain flight id is not a track-record name")
    }

    func testSplitRecordsRoundTripToFullFlight() throws {
        let track = [point(47, 8), point(47.1, 8.1), point(47.2, 8.2)]
        let f = flight(modifiedAt: Date(timeIntervalSince1970: 500), name: "Split", notes: "n",
                       track: track, fullStop: 1)

        let metaRecord = try XCTUnwrap(SyncManager.buildFlightRecord(
            f, recordID: CKRecord.ID(recordName: f.id.uuidString)))
        let trackRecord = try XCTUnwrap(SyncManager.buildFlightTrackRecord(
            f, recordID: CKRecord.ID(recordName: SyncManager.trackRecordName(f.id))))

        XCTAssertEqual(metaRecord.recordType, "Flight")
        XCTAssertEqual(trackRecord.recordType, "FlightTrack")
        XCTAssertEqual(trackRecord["trackCount"] as? Int, 3, "Track record carries its point-count fingerprint")

        let metaFlight = try XCTUnwrap(SyncManager.flightFromPayload(inline: metaRecord["data"] as? Data, asset: nil))
        XCTAssertEqual(metaFlight.gpsTrack.count, 0, "Metadata record is track-stripped")
        XCTAssertEqual(metaFlight.name, "Split", "Metadata record keeps the editable fields")

        let trackFlight = try XCTUnwrap(SyncManager.flightFromPayload(inline: trackRecord["data"] as? Data, asset: nil))
        XCTAssertEqual(trackFlight.gpsTrack.count, 3, "Track record carries the full track")

        // The two records fold back into the complete flight.
        let merged = Flight.merge(metaFlight, trackFlight)
        XCTAssertEqual(merged.gpsTrack.count, 3)
        XCTAssertEqual(merged.name, "Split")
        XCTAssertEqual(merged.fullStopCount, 1)
    }

    func testInboundMetadataEditDoesNotDropLocalTrack() throws {
        let id = UUID()
        let track = (0..<10).map { point(47.0 + Double($0) * 0.01, 8.0) }
        // Local flight already holds the track (from a previously-synced track record).
        let local = flight(id: id, modifiedAt: Date(timeIntervalSince1970: 100), name: "Local", track: track)
        // Inbound: a renamed, track-stripped metadata record from another device (newer).
        let renamed = flight(id: id, modifiedAt: Date(timeIntervalSince1970: 200), name: "Renamed", track: [])
        let metaRecord = try XCTUnwrap(SyncManager.buildFlightRecord(
            renamed, recordID: CKRecord.ID(recordName: id.uuidString)))
        let inbound = try XCTUnwrap(SyncManager.flightFromPayload(inline: metaRecord["data"] as? Data, asset: nil))

        let merged = Flight.merge(local, inbound)
        XCTAssertEqual(merged.name, "Renamed", "The metadata edit is applied")
        XCTAssertEqual(merged.gpsTrack.count, 10,
                       "A track-stripped metadata record never drops the local track")
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

    /// The waypoint-proximity radius lost its slider in 6.0.1 (waypoints are marked from the track),
    /// but a 6.0 device still reads it from the synced record: it is decoded and written back as is.
    func testTheRetiredProximityRadiusStillDecodesAndSyncs() throws {
        let saved = #"{"waypointProximityThreshold":800,"gpsRecordingInterval":10,"schemaVersion":5}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(saved.utf8))
        XCTAssertEqual(settings.waypointProximityThreshold, 800)
        XCTAssertEqual(settings.gpsRecordingInterval, 10, "the rest of the file with it")

        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        XCTAssertEqual(written?["waypointProximityThreshold"] as? Double, 800)
        XCTAssertEqual(AppSettings().waypointProximityThreshold, 500, "a new install writes the old default")
    }

    // MARK: - Theme preference persistence (UX-09 / v4 UI/UX Revamp)

    func testThemePreferenceDefaultsMigratesAndRoundTrips() throws {
        // Absent preference (and absent legacy keys) defaults to day.
        let absent = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"keepScreenOn":true}"#.utf8))
        XCTAssertEqual(absent.themePreference, .day, "Absent theme preference defaults to day")

        // Legacy `nightMode` Bool migrates: true → night, false → day.
        let legacyOn = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"nightMode":true}"#.utf8))
        XCTAssertEqual(legacyOn.themePreference, .night)
        let legacyOff = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"nightMode":false}"#.utf8))
        XCTAssertEqual(legacyOff.themePreference, .day)

        // Phase-3.1 `nightModePreference` string migrates: off→day, on→night, system→auto.
        let prefOff = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"nightModePreference":"off"}"#.utf8))
        XCTAssertEqual(prefOff.themePreference, .day)
        let prefOn = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"nightModePreference":"on"}"#.utf8))
        XCTAssertEqual(prefOn.themePreference, .night)
        let prefSystem = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"nightModePreference":"system"}"#.utf8))
        XCTAssertEqual(prefSystem.themePreference, .auto)

        // The preference round-trips.
        var s = AppSettings()
        s.themePreference = .night
        let roundTripped = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(roundTripped.themePreference, .night)

        // `.sunlight` deliberately does NOT round-trip any more: it stopped being a picker choice in
        // v5.x and became the `sunlightBoost` toggle, so a save still holding it is migrated rather
        // than preserved. Covered in full by InstrumentAccessibilityTests.
        let legacySunlight = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"themePreference":"sunlight"}"#.utf8))
        XCTAssertEqual(legacySunlight.themePreference, .day)
        XCTAssertTrue(legacySunlight.sunlightBoost)
    }
}

/// Tests the CloudKit send-failure classification extracted from `handleSentRecordZoneChanges`. (CQ-04)
///
/// This is the logic that decides whether a pilot's edit survives a sync race — settings conflict vs
/// flight conflict, merge-and-requeue vs keep-the-cloud-version, permanently-too-large vs
/// leave-it-pending-for-retry. Before the extraction it was inline, interleaved with side effects,
/// and had no coverage at all: only the pure `Flight.merge` / `validatedForIngest` helpers it calls
/// were tested, not the branch selection that decides which of them runs.
final class SyncSendFailureClassificationTests: XCTestCase {

    private func classify(
        code: Int,
        serverErrorCode: Int? = nil,
        recordName: String,
        hasServerRecord: Bool = false
    ) -> SyncManager.SendFailure {
        SyncManager.classifySendFailure(
            errorCode: code,
            serverErrorCode: serverErrorCode,
            recordName: recordName,
            hasServerRecord: hasServerRecord
        )
    }

    private let conflict = CKError.serverRecordChanged.rawValue

    // MARK: - Settings conflicts

    func testSettingsConflictWithServerRecordRequeues() {
        XCTAssertEqual(classify(code: conflict, recordName: "settings", hasServerRecord: true),
                       .settingsConflict(hasServerRecord: true))
    }

    func testSettingsConflictWithoutServerRecordDropsPending() {
        XCTAssertEqual(classify(code: conflict, recordName: "settings", hasServerRecord: false),
                       .settingsConflict(hasServerRecord: false))
    }

    // MARK: - Flight conflicts

    func testFlightConflictCarriesTheFlightIdAndServerRecordAvailability() {
        let id = UUID()
        XCTAssertEqual(classify(code: conflict, recordName: id.uuidString, hasServerRecord: true),
                       .flightConflict(flightId: id, hasServerRecord: true))
        XCTAssertEqual(classify(code: conflict, recordName: id.uuidString, hasServerRecord: false),
                       .flightConflict(flightId: id, hasServerRecord: false))
    }

    /// CloudKit sometimes reports the conflict only in `CKErrorServerErrorCode`, leaving the
    /// top-level code something else. Both spellings must be treated as the same conflict.
    func testConflictSignalledOnlyByServerErrorCode2004() {
        let id = UUID()
        XCTAssertEqual(classify(code: CKError.internalError.rawValue,
                                serverErrorCode: 2004,
                                recordName: id.uuidString,
                                hasServerRecord: true),
                       .flightConflict(flightId: id, hasServerRecord: true))
    }

    /// A conflict on the separate track record has no dedicated handling — its name is not a bare
    /// UUID, so it must fall through rather than being mistaken for a flight conflict.
    func testConflictOnATrackRecordFallsThrough() {
        let name = SyncManager.trackRecordName(UUID())
        XCTAssertEqual(classify(code: conflict, recordName: name, hasServerRecord: true), .leavePending)
    }

    // MARK: - Permanent failures

    func testLimitExceededOnAFlightDropsThatFlight() {
        let id = UUID()
        XCTAssertEqual(classify(code: CKError.limitExceeded.rawValue, recordName: id.uuidString),
                       .tooLarge(flightId: id))
    }

    /// Same permanent failure on a track record: still surfaced, but there is no flight id to clear.
    func testLimitExceededOnATrackRecordHasNoFlightIdToClear() {
        XCTAssertEqual(classify(code: CKError.limitExceeded.rawValue,
                                recordName: SyncManager.trackRecordName(UUID())),
                       .tooLarge(flightId: nil))
    }

    func testQuotaExceededIsSurfaced() {
        XCTAssertEqual(classify(code: CKError.quotaExceeded.rawValue, recordName: UUID().uuidString),
                       .quotaExceeded)
    }

    // MARK: - Transient failures

    /// The important negative case: a transient error must NOT drop the pending change, or the
    /// edit is lost instead of being retried by CKSyncEngine.
    func testTransientErrorsLeaveTheChangePending() {
        for code in [CKError.networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy] {
            XCTAssertEqual(classify(code: code.rawValue, recordName: UUID().uuidString), .leavePending,
                           "\(code) must leave the change pending for retry")
        }
    }

    func testUnknownErrorCodeLeavesTheChangePending() {
        XCTAssertEqual(classify(code: 999_999, recordName: UUID().uuidString), .leavePending)
    }
}

/// Change-tag preservation for flight records. (CloudKit "record to insert already exists")
///
/// `buildFlightRecord` used to mint a fresh `CKRecord` on every send. A record with no
/// `recordChangeTag` is an INSERT to CloudKit, so re-sending an existing flight failed with
/// `serverRecordChanged` / "record to insert already exists" — and the conflict handler then merged
/// and re-queued *another* tag-less record, so it could never converge. The GPS track record failed
/// alongside it with "Atomic failure", since the two share an atomic batch. A flight that needed
/// re-sending therefore never reached iCloud at all.
final class FlightRecordSystemFieldsTests: XCTestCase {

    private let zoneID = CKRecordZone.ID(zoneName: "AeroCheckZone", ownerName: CKCurrentUserDefaultName)

    private func flightRecordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }

    func testSystemFieldsRoundTripPreservesRecordIdentity() throws {
        let id = UUID()
        let recordID = flightRecordID(id)
        let original = CKRecord(recordType: SyncRecordType.flight.rawValue, recordID: recordID)

        let restored = SyncManager.baseRecord(
            recordType: SyncRecordType.flight.rawValue,
            recordID: recordID,
            systemFields: SyncManager.encodedSystemFields(of: original)
        )

        XCTAssertEqual(restored.recordID, recordID)
        XCTAssertEqual(restored.recordType, SyncRecordType.flight.rawValue)
    }

    /// System fields carry identity and change tag ONLY — never the payload. If data leaked through,
    /// a rebuilt record could resurrect stale fields the local flight no longer has.
    func testSystemFieldsCarryNoDataFields() throws {
        let recordID = flightRecordID(UUID())
        let original = CKRecord(recordType: SyncRecordType.flight.rawValue, recordID: recordID)
        original["data"] = Data([0x01, 0x02]) as CKRecordValue
        original["airplane"] = "HB-XYZ" as CKRecordValue

        let restored = SyncManager.baseRecord(
            recordType: SyncRecordType.flight.rawValue,
            recordID: recordID,
            systemFields: SyncManager.encodedSystemFields(of: original)
        )

        XCTAssertNil(restored["data"], "system fields must not carry the payload")
        XCTAssertNil(restored["airplane"])
    }

    func testNoStoredFieldsYieldsAFreshRecord() {
        let recordID = flightRecordID(UUID())
        let record = SyncManager.baseRecord(
            recordType: SyncRecordType.flight.rawValue, recordID: recordID, systemFields: nil)

        XCTAssertEqual(record.recordID, recordID)
        XCTAssertNil(record.recordChangeTag, "a genuinely new flight must still be an insert")
    }

    /// Stored fields describing a DIFFERENT record must never be adopted — that would send one
    /// flight's payload under another flight's identity.
    func testMismatchedStoredFieldsAreIgnored() throws {
        let other = CKRecord(recordType: SyncRecordType.flight.rawValue, recordID: flightRecordID(UUID()))
        let wantedID = flightRecordID(UUID())

        let record = SyncManager.baseRecord(
            recordType: SyncRecordType.flight.rawValue,
            recordID: wantedID,
            systemFields: SyncManager.encodedSystemFields(of: other)
        )

        XCTAssertEqual(record.recordID, wantedID, "must fall back to the requested identity")
    }

    /// A track record's fields must not be adopted for a metadata record, or vice versa.
    func testMismatchedRecordTypeIsIgnored() throws {
        let recordID = flightRecordID(UUID())
        let track = CKRecord(recordType: SyncRecordType.flightTrack.rawValue, recordID: recordID)

        let record = SyncManager.baseRecord(
            recordType: SyncRecordType.flight.rawValue,
            recordID: recordID,
            systemFields: SyncManager.encodedSystemFields(of: track)
        )

        XCTAssertEqual(record.recordType, SyncRecordType.flight.rawValue)
    }

    func testCorruptStoredFieldsFallBackInsteadOfCrashing() {
        let recordID = flightRecordID(UUID())
        let record = SyncManager.baseRecord(
            recordType: SyncRecordType.flight.rawValue,
            recordID: recordID,
            systemFields: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )

        XCTAssertEqual(record.recordID, recordID)
    }

    /// The built record must still carry its payload — preserving system fields must not cost data.
    func testBuiltFlightRecordStillCarriesItsPayload() throws {
        let id = UUID()
        let recordID = flightRecordID(id)
        let flight = Flight(id: id, name: "T", gpsTrack: [], notes: "", modifiedAt: Date())
        let seed = CKRecord(recordType: SyncRecordType.flight.rawValue, recordID: recordID)

        let record = try XCTUnwrap(SyncManager.buildFlightRecord(
            flight, recordID: recordID, systemFields: SyncManager.encodedSystemFields(of: seed)))

        XCTAssertEqual(record.recordID, recordID)
        XCTAssertNotNil(record["data"], "the flight payload must still be attached")
        XCTAssertEqual(record["flightId"] as? String, id.uuidString)
    }
}

// MARK: - The switch and the CloudKit engine

/// Stands in for CloudKit's own mark of a `CKSyncEngine` delegate callback, a task-local that every
/// task started inside the callback inherits. iOS 27 traps an engine fetch or send awaited with it set.
enum SyncEngineCallbackContext {
    @TaskLocal static var isInside = false
}

/// Stands in for `CKSyncEngine`: records what it is asked to queue, fetch and send.
final class StubSyncEngine: SyncEngineDriving, @unchecked Sendable {
    private(set) var queued: [CKSyncEngine.PendingRecordZoneChange] = []
    private(set) var unqueued: [CKSyncEngine.PendingRecordZoneChange] = []
    private(set) var queuedDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] = []
    private(set) var fetches = 0
    private(set) var sends = 0
    /// Fetches and sends awaited from inside a delegate callback: each one a crash on iOS 27.
    private(set) var callsFromInsideACallback = 0
    var fetchError: Error?

    func queue(_ changes: [CKSyncEngine.PendingRecordZoneChange]) { queued += changes }
    func unqueue(_ changes: [CKSyncEngine.PendingRecordZoneChange]) { unqueued += changes }
    func queue(_ changes: [CKSyncEngine.PendingDatabaseChange]) { queuedDatabaseChanges += changes }
    func fetch() async throws {
        fetches += 1
        if SyncEngineCallbackContext.isInside { callsFromInsideACallback += 1 }
        if let fetchError { throw fetchError }
    }
    func send() async throws {
        sends += 1
        if SyncEngineCallbackContext.isInside { callsFromInsideACallback += 1 }
    }

    /// Record names queued for saving.
    var saves: Set<String> {
        Set(queued.compactMap { if case .saveRecord(let id) = $0 { return id.recordName } else { return nil } })
    }

    /// Record names queued for deleting.
    var deletes: Set<String> {
        Set(queued.compactMap { if case .deleteRecord(let id) = $0 { return id.recordName } else { return nil } })
    }
}

/// Stands in for the CloudKit container. `holdsAccountCheck` parks the start on the account check
/// until `release()`.
@MainActor
final class StubSyncBackend: SyncBackend {
    var status: CKAccountStatus = .available
    var fetchError: Error?
    var holdsAccountCheck = false
    private(set) var isHoldingAccountCheck = false
    private var held: CheckedContinuation<Void, Never>?
    private(set) var engines: [StubSyncEngine] = []

    func accountStatus() async throws -> CKAccountStatus {
        if holdsAccountCheck {
            isHoldingAccountCheck = true
            await withCheckedContinuation { held = $0 }
        }
        return status
    }

    func release() {
        held?.resume()
        held = nil
    }

    func makeEngine(state: CKSyncEngine.State.Serialization?, delegate: SyncEngineDelegate) -> SyncEngineDriving {
        let engine = StubSyncEngine()
        engine.fetchError = fetchError
        engines.append(engine)
        return engine
    }
}

/// "Sync to iCloud" turned on mid-session started CloudKit only at the next launch: the container
/// was resolved at launch, and only with the switch already on. Nothing queued the flights recorded
/// while it was off either, and a delete made before the engine was up was dropped.
///
/// A `SyncManager` on its own defaults suite and a stand-in engine: `.standard` holds the simulator
/// app's real change tokens and fingerprints.
@MainActor
final class SyncSwitchCloudKitTests: XCTestCase {

    private var defaults: UserDefaults!
    private var backend: StubSyncBackend!

    override func setUpWithError() throws {
        defaults = makeTestDefaults()
        backend = StubSyncBackend()
    }

    /// A manager built with the switch as given (the key AppState and the datastore share).
    private func manager(on: Bool) -> SyncManager {
        defaults.set(on, forKey: DataPersistenceManager.syncPreferenceKey)
        return SyncManager(defaults: defaults, backend: backend)
    }

    private func flight(_ minutesAgo: Double = 60) -> Flight {
        Flight(airplane: "wt9-dynamic", startTime: Date(timeIntervalSinceNow: -minutesAgo * 60))
    }

    private func records(of flight: Flight) -> Set<String> {
        [flight.id.uuidString, SyncManager.trackRecordName(flight.id)]
    }

    private func started(_ manager: SyncManager) async throws -> StubSyncEngine {
        await manager.engineStartTask?.value
        return try XCTUnwrap(backend.engines.last, "no engine was started")
    }

    // MARK: - On

    func testTurningTheSwitchOnStartsTheEngineRightAway() async throws {
        let manager = manager(on: false)
        XCTAssertFalse(manager.isEngineRunning)

        manager.isSyncEnabled = true
        let engine = try await started(manager)

        XCTAssertTrue(manager.isEngineRunning)
        XCTAssertEqual(backend.engines.count, 1)
        XCTAssertEqual(engine.fetches, 1, "the first fetch, as at launch")
        XCTAssertEqual(engine.queuedDatabaseChanges.count, 1, "the zone")
    }

    /// Flights recorded while the switch was off go out; one CloudKit already has as it is doesn't.
    func testTurningItOnQueuesTheFlightsCloudKitLacks() async throws {
        let manager = manager(on: false)
        let known = flight(120)
        let recordedWhileOff = flight(30)
        manager.markFlightSynced(known.id, modifiedAt: known.modifiedAt)
        manager.markFlightTrackSynced(known.id, count: known.gpsTrack.count)
        manager.localSnapshot = { ([known, recordedWhileOff], AppSettings()) }

        manager.isSyncEnabled = true
        let engine = try await started(manager)

        XCTAssertEqual(engine.saves, records(of: recordedWhileOff), "sent once, and nothing CloudKit already has")
    }

    /// The same catch-up runs when CloudKit comes up at launch, for a flight whose queued save was
    /// lost with the app (the flight to send lives in memory).
    func testAtLaunchTheFlightsCloudKitLacksAreQueuedToo() async throws {
        let unsent = flight()
        let manager = manager(on: true)
        manager.localSnapshot = { ([unsent], AppSettings()) }

        let engine = try await started(manager)

        XCTAssertEqual(engine.saves, records(of: unsent))
    }

    /// Turning the switch on saves the settings before the engine is up: they go once it is, as
    /// they are then.
    func testSettingsSavedBeforeTheEngineIsUpGoOutOnceItIs() async throws {
        let manager = manager(on: false)
        var current = AppSettings()
        current.gpsRecordingInterval = 3
        manager.localSnapshot = { ([], current) }

        manager.isSyncEnabled = true
        manager.syncSettings(AppSettings())
        XCTAssertTrue(manager.settingsOwed)
        let engine = try await started(manager)

        XCTAssertTrue(engine.saves.contains("settings"))
        XCTAssertEqual(manager.getPendingSettings(), current, "the settings as they are when it goes out")
        manager.clearPendingSettings()
        XCTAssertFalse(manager.settingsOwed, "confirmed: nothing owed")
    }

    /// Without a first fetch the catch-up would send records CloudKit already holds. It waits for a
    /// fetch that succeeds (Sync Now, or the next start).
    func testWhenTheFirstFetchFailsTheCatchUpWaitsForOneThatSucceeds() async throws {
        let manager = manager(on: false)
        let recordedWhileOff = flight()
        manager.localSnapshot = { ([recordedWhileOff], AppSettings()) }
        backend.fetchError = CKError(.networkUnavailable)

        manager.isSyncEnabled = true
        let engine = try await started(manager)
        XCTAssertTrue(engine.saves.isEmpty)

        engine.fetchError = nil
        await manager.syncNow()

        XCTAssertEqual(engine.saves, records(of: recordedWhileOff))
    }

    func testNoEngineWithoutAnICloudAccount() async throws {
        backend.status = .noAccount
        let manager = manager(on: false)

        manager.isSyncEnabled = true
        await manager.engineStartTask?.value

        XCTAssertTrue(backend.engines.isEmpty)
        XCTAssertFalse(manager.isEngineRunning)
    }

    /// AppState saves the settings on every change and sets the switch each time: only a change
    /// starts anything.
    func testSettingTheSameValueAgainStartsNothingMore() async throws {
        let manager = manager(on: false)
        manager.isSyncEnabled = true
        _ = try await started(manager)

        manager.isSyncEnabled = true
        await manager.engineStartTask?.value

        XCTAssertEqual(backend.engines.count, 1)
    }

    // MARK: - Delegate callbacks (iOS 27)

    /// 6.1.1 crashed at launch in App Review (iOS 27.0): "BUG IN CLIENT OF CLOUDKIT: Cannot await a
    /// call into CKSyncEngine from within a delegate callback". On a fresh install the engine's first
    /// event is `.signIn`, its handler restarts the engine, and the new engine's first fetch ran in a
    /// task that had inherited the callback's context.
    func testAnEngineRestartedFromADelegateCallbackFetchesOutsideIt() async throws {
        let manager = manager(on: true)
        _ = try await started(manager)

        SyncEngineCallbackContext.$isInside.withValue(true) {
            manager.restartSyncForAccountChange(clearState: false)
        }
        let restarted = try await started(manager)

        XCTAssertEqual(backend.engines.count, 2)
        XCTAssertEqual(restarted.fetches, 1, "the first fetch, as at launch")
        XCTAssertEqual(restarted.callsFromInsideACallback, 0, "a trap on iOS 27")
    }

    /// The same for Sync Now, which a settings change fires: one applied from a fetched record runs
    /// on behalf of a delegate callback.
    func testSyncNowFromADelegateCallbackFetchesAndSendsOutsideIt() async throws {
        let manager = manager(on: true)
        let engine = try await started(manager)

        await SyncEngineCallbackContext.$isInside.withValue(true) {
            await manager.syncNow()
        }

        XCTAssertEqual(engine.fetches, 2, "the first fetch, then Sync Now's")
        XCTAssertEqual(engine.sends, 1)
        XCTAssertEqual(engine.callsFromInsideACallback, 0, "a trap on iOS 27")
    }

    // MARK: - Off

    func testTurningTheSwitchOffStopsTheEngine() async throws {
        let manager = manager(on: true)
        let engine = try await started(manager)
        let before = engine.queued.count

        manager.isSyncEnabled = false
        manager.syncFlight(flight(), allFlights: [])
        manager.syncSettings(AppSettings())

        XCTAssertFalse(manager.isEngineRunning)
        XCTAssertEqual(engine.queued.count, before, "nothing reaches the stopped engine")
        XCTAssertFalse(defaults.bool(forKey: DataPersistenceManager.syncPreferenceKey))
    }

    /// Off while the start is still checking the account: no engine comes up afterwards.
    func testTurnedOffDuringTheStartNoEngineComesUp() async throws {
        backend.holdsAccountCheck = true
        let manager = manager(on: false)
        manager.isSyncEnabled = true
        let start = try XCTUnwrap(manager.engineStartTask)
        while !backend.isHoldingAccountCheck { await Task.yield() }

        manager.isSyncEnabled = false
        backend.release()
        await start.value

        XCTAssertTrue(backend.engines.isEmpty)
        XCTAssertFalse(manager.isEngineRunning)
    }

    func testOffThenOnAgainStartsAFreshEngineAndCatchesUp() async throws {
        let manager = manager(on: true)
        _ = try await started(manager)
        manager.isSyncEnabled = false
        let recordedWhileOff = flight()
        manager.localSnapshot = { ([recordedWhileOff], AppSettings()) }

        manager.isSyncEnabled = true
        let second = try await started(manager)

        XCTAssertEqual(backend.engines.count, 2)
        XCTAssertEqual(second.saves, records(of: recordedWhileOff))
    }

    // MARK: - Deletes owed to CloudKit

    /// A delete made while no engine ran (CloudKit not up yet) used to be dropped: the flight stayed
    /// in CloudKit and on every other device. It is kept, and sent when the engine comes up.
    func testADeleteMadeBeforeTheEngineIsUpIsSentWhenItStarts() async throws {
        backend.status = .noAccount
        let first = manager(on: true)
        await first.engineStartTask?.value
        let deleted = UUID()

        first.deleteFlight(deleted)
        XCTAssertEqual(first.owedFlightDeletions, [deleted])

        backend.status = .available
        let relaunched = SyncManager(defaults: defaults, backend: backend)
        let engine = try await started(relaunched)

        XCTAssertEqual(engine.deletes, [deleted.uuidString, SyncManager.trackRecordName(deleted)])
    }

    func testADeleteWithTheEngineUpIsSentAndCancelsItsQueuedSave() async throws {
        let manager = manager(on: true)
        let engine = try await started(manager)
        let doomed = flight()
        manager.syncFlight(doomed, allFlights: [doomed])

        manager.deleteFlight(doomed.id)

        XCTAssertEqual(engine.deletes, records(of: doomed))
        XCTAssertEqual(Set(engine.unqueued.compactMap { change -> String? in
            if case .saveRecord(let id) = change { return id.recordName } else { return nil }
        }), records(of: doomed))
        XCTAssertNil(manager.getPendingFlight(for: doomed.id))
    }

    func testAConfirmedDeleteIsNotSentAgain() async throws {
        let manager = manager(on: true)
        _ = try await started(manager)
        let deleted = UUID()
        manager.deleteFlight(deleted)

        manager.clearPendingFlightDeletion(deleted)

        let relaunched = SyncManager(defaults: defaults, backend: backend)
        let engine = try await started(relaunched)
        XCTAssertTrue(engine.deletes.isEmpty)
    }

    /// With the switch off, AppState sends no delete, and nothing is kept here: the deletion record
    /// stands for it, and becomes an owed delete when CloudKit comes up, after its first fetch
    /// (`CloudKitDeletionRecordsTests`).
    func testWithTheSwitchOffNoDeleteIsKept() {
        let manager = manager(on: false)

        manager.deleteFlight(UUID())

        XCTAssertTrue(manager.owedFlightDeletions.isEmpty)
    }

    // MARK: - Through AppState

    /// The whole path: flights recorded with the switch off, then the switch turned on in Settings.
    /// The datastore moves to iCloud Drive, CloudKit starts at once, and the flights go out.
    func testTurningTheSwitchOnInSettingsSendsTheFlightsRecordedWhileOff() async throws {
        let base = makeTestDirectory()
        let local = base.appendingPathComponent("AppSupport", isDirectory: true)
        let cloud = base.appendingPathComponent("Container/Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        defaults.set(false, forKey: DataPersistenceManager.syncPreferenceKey)
        let store = DataPersistenceManager(rootDirectory: local, iCloudDocumentsDirectory: cloud, preferences: defaults)
        let manager = SyncManager(defaults: defaults, backend: backend)
        let appState = makeTestAppState(datastore: store, syncManager: manager)
        let recordedWhileOff = flight()
        XCTAssertTrue(store.saveFlight(recordedWhileOff))
        XCTAssertTrue(backend.engines.isEmpty)

        appState.settings.iCloudSyncEnabled = true
        appState.saveSettings()
        let engine = try await started(manager)

        XCTAssertTrue(store.isUsingICloudDrive)
        XCTAssertTrue(manager.isEngineRunning)
        XCTAssertTrue(engine.saves.isSuperset(of: records(of: recordedWhileOff)), "\(engine.saves)")
        XCTAssertTrue(engine.saves.contains("settings"))

        appState.settings.iCloudSyncEnabled = false
        appState.saveSettings()

        XCTAssertFalse(manager.isEngineRunning)
        XCTAssertFalse(store.isUsingICloudDrive)
    }
}
