import XCTest
import CloudKit
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

        // The new preference round-trips (sunlight survives encode/decode).
        var s = AppSettings()
        s.themePreference = .sunlight
        let roundTripped = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(roundTripped.themePreference, .sunlight)
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
