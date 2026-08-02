import XCTest
@testable import AeroCheck

/// Crash-recovery / durable-checkpoint tests for the active flight session. (PERF-02, PERF-13, ARCH-08)
///
/// These cover the safety-critical promise that a foreground crash/OOM mid-flight cannot lose the
/// recorded GPS track, that the type-safe snapshot round-trips every phase/status without loss, and
/// that a restored premium flight never silently falls back to the bundled WT9 content.
@MainActor
final class ActiveFlightStatePersistenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Ensure no checkpoint leaks in from a prior test (shared on-device file).
        AppState().clearActiveFlightState()
    }

    override func tearDown() {
        AppState().clearActiveFlightState()
        super.tearDown()
    }

    private func makePoint(_ lat: Double, _ lon: Double, speed: Double = 50) -> GPSPoint {
        GPSPoint(latitude: lat, longitude: lon, altitude: 1500, speed: speed, course: 90)
    }

    private func startWT9Flight(on appState: AppState) {
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.startFlight(
            withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA", aircraftType: "WT9"
        )
    }

    /// A checkpoint write queued just before the clear must never resurrect the file.
    ///
    /// `persistActiveFlightState` writes on a background serial queue (PR-12);
    /// `clearActiveFlightState` used to delete the file immediately, so a write queued
    /// moments earlier landed AFTER the delete and brought the checkpoint back. In
    /// production that resurrects a CANCELLED flight as a phantom "Flight Restored" on
    /// next launch (RES-12 only guards flights that reached endFlight()); in the test
    /// host it leaked phantom checkpoints into the shared simulator container — observed
    /// live 2026-08-02 as a restored 1970-epoch flight from BlockTimeBackdatingTests,
    /// which does call cancelFlight() and still leaked. The clear now flushes the queue
    /// first, making it a strict barrier.
    func testClearWinsOverQueuedCheckpointWrite() {
        let appState = AppState()
        startWT9Flight(on: appState)
        appState.recordEngineStart()          // checkpointActiveFlight(force:) → ASYNC write queued
        appState.cancelFlight()               // clear must flush the queue before deleting
        appState.flushPendingCheckpoint()     // drain anything that could still be in flight
        XCTAssertFalse(appState.hasActiveFlightState,
                       "a queued checkpoint write must never resurrect a cleared checkpoint")
    }

    /// Encode → decode → restore preserves the flight, phase, and the typed status/highlight maps.
    func testSnapshotRoundTripPreservesState() throws {
        let source = AppState()
        startWT9Flight(on: source)
        source.currentPhase = .cruise
        source.highestCompletedPhase = .climb
        source.phaseCompletionStatus = [
            .preflight: .completed, .taxi: .skipped, .runup: .missingAction,
        ]
        source.currentHighlightedItem = [.cruise: 3]
        source.currentFlight?.gpsTrack = [makePoint(47.0, 8.0), makePoint(47.1, 8.1)]

        let flight = try XCTUnwrap(source.currentFlight)
        let snapshot = ActiveFlightState(flight: flight, from: source)

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ActiveFlightState.self, from: encoder.encode(snapshot))

        let restored = AppState()
        decoded.restore(to: restored)

        XCTAssertTrue(restored.isFlightActive)
        XCTAssertEqual(restored.currentFlight?.id, flight.id)
        XCTAssertEqual(restored.currentFlight?.gpsTrack.count, 2)
        XCTAssertEqual(restored.currentPhase, .cruise)
        XCTAssertEqual(restored.highestCompletedPhase, .climb)
        XCTAssertEqual(restored.phaseCompletionStatus[.preflight], .completed)
        XCTAssertEqual(restored.phaseCompletionStatus[.taxi], .skipped)
        XCTAssertEqual(restored.phaseCompletionStatus[.runup], .missingAction)
        XCTAssertEqual(restored.currentHighlightedItem[.cruise], 3)

        restored.clearActiveFlightState()
        restored.isFlightActive = false
        source.isFlightActive = false
    }

    /// Every `PhaseCompletionStatus` case survives the typed-map round trip. Because the snapshot
    /// stores the enums directly, a newly-added case is a compile error here rather than a silent
    /// drop — this test documents that contract. (ARCH-08)
    func testAllCompletionStatusesRoundTrip() throws {
        let all: [ChecklistPhase: PhaseCompletionStatus] = [
            .preflight: .notStarted, .taxi: .completed, .runup: .skipped, .climb: .missingAction,
        ]
        let data = try JSONEncoder().encode(all)
        let decoded = try JSONDecoder().decode([ChecklistPhase: PhaseCompletionStatus].self, from: data)
        XCTAssertEqual(decoded, all)
        // Guard: exercise all four known cases so adding one without updating callers is visible.
        for status in [PhaseCompletionStatus.notStarted, .completed, .skipped, .missingAction] {
            XCTAssertEqual(PhaseCompletionStatus(rawValue: status.rawValue), status)
        }
    }

    /// Simulated foreground crash: a flight records points and is checkpointed; a brand-new
    /// AppState (the "relaunch") restores the full track from the durable file. (PERF-02)
    func testCrashRecoveryRestoresTrackFromFile() throws {
        let source = AppState()
        startWT9Flight(on: source)
        for i in 0..<30 {
            source.addGPSPoint(makePoint(47.0 + Double(i) * 0.001, 8.0))
        }
        // Final synchronous checkpoint so the file reflects all 30 points before "relaunch".
        source.saveActiveFlightState()

        let expectedCount = try XCTUnwrap(source.currentFlight?.gpsTrack.count)
        let flightId = source.currentFlight?.id
        XCTAssertEqual(expectedCount, 30)

        // A new AppState restores from disk in its initializer.
        let relaunched = AppState()
        XCTAssertTrue(relaunched.isFlightActive, "A crashed flight should be restored on relaunch")
        XCTAssertEqual(relaunched.currentFlight?.id, flightId)
        XCTAssertEqual(relaunched.currentFlight?.gpsTrack.count, expectedCount,
                       "The full recorded track must survive a crash")

        relaunched.clearActiveFlightState()
        relaunched.isFlightActive = false
        source.isFlightActive = false
    }

    /// A throttled checkpoint is written during flight without an explicit save (independent of
    /// scenePhase), so a crash before any background transition still recovers the track. (PERF-02)
    func testCheckpointWrittenDuringFlightWithoutExplicitSave() throws {
        let source = AppState()
        startWT9Flight(on: source)
        XCTAssertFalse(source.hasActiveFlightState, "No checkpoint before any points")

        // Enough points to cross the throttle threshold (20) at least once.
        for i in 0..<25 {
            source.addGPSPoint(makePoint(47.0 + Double(i) * 0.001, 8.0))
        }
        // The throttled checkpoint write now runs off the main actor (PR-12); wait for it to land.
        source.flushPendingCheckpoint()
        XCTAssertTrue(source.hasActiveFlightState,
                      "A checkpoint should exist mid-flight without any scenePhase/explicit save")

        source.clearActiveFlightState()
        source.isFlightActive = false
    }

    /// PERF-29: the snapshot is slim (no inline track) and the track delta file only grows —
    /// per-checkpoint work is O(new points), not O(whole track).
    func testIncrementalCheckpointKeepsSnapshotSlimAndDeltaAppendOnly() throws {
        let source = AppState()
        startWT9Flight(on: source)
        for i in 0..<25 { source.addGPSPoint(makePoint(47.0 + Double(i) * 0.001, 8.0)) }
        source.saveActiveFlightState()
        source.flushPendingCheckpoint()

        let deltaURL = DataPersistenceManager.shared.activeFlightTrackDeltaURL
        let sizeAfterFirst = (try? Data(contentsOf: deltaURL))?.count ?? 0
        XCTAssertGreaterThan(sizeAfterFirst, 0, "Delta file should exist after a checkpoint")

        for i in 25..<50 { source.addGPSPoint(makePoint(47.0 + Double(i) * 0.001, 8.0)) }
        source.saveActiveFlightState()
        source.flushPendingCheckpoint()

        let sizeAfterSecond = (try? Data(contentsOf: deltaURL))?.count ?? 0
        XCTAssertGreaterThan(sizeAfterSecond, sizeAfterFirst, "Delta file must grow, never rewrite")

        // The snapshot itself must be slim: no inline GPS track.
        let snapshotData = try XCTUnwrap(DataPersistenceManager.shared.loadActiveFlightStateData())
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(ActiveFlightState.self, from: snapshotData)
        XCTAssertEqual(snapshot.schemaVersion, ActiveFlightState.currentSchemaVersion)
        XCTAssertTrue(snapshot.flight.gpsTrack.isEmpty, "v3 snapshots must not carry the track inline")

        // Recovery merges the delta (deduped by id) back into the flight.
        let relaunched = AppState()
        XCTAssertTrue(relaunched.isFlightActive)
        XCTAssertEqual(relaunched.currentFlight?.gpsTrack.count, 50,
                       "The full track must be rebuilt from the delta file")

        relaunched.clearActiveFlightState()
        relaunched.isFlightActive = false
        source.isFlightActive = false
    }

    /// PERF-29: a crash can tear the last delta line mid-append; recovery must skip the torn tail
    /// and keep every complete point rather than failing.
    func testTornDeltaTailIsTolerated() throws {
        let source = AppState()
        startWT9Flight(on: source)
        for i in 0..<30 { source.addGPSPoint(makePoint(46.0 + Double(i) * 0.001, 7.0)) }
        source.saveActiveFlightState()
        source.flushPendingCheckpoint()

        // Simulate a torn write: garbage partial JSON with no trailing newline.
        let deltaURL = DataPersistenceManager.shared.activeFlightTrackDeltaURL
        let handle = try FileHandle(forWritingTo: deltaURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"latitude\":46.5,\"longi".utf8))
        try handle.close()

        let relaunched = AppState()
        XCTAssertTrue(relaunched.isFlightActive)
        XCTAssertEqual(relaunched.currentFlight?.gpsTrack.count, 30,
                       "A torn tail line must be skipped, not fail the whole recovery")

        relaunched.clearActiveFlightState()
        relaunched.isFlightActive = false
        source.isFlightActive = false
    }

    /// PERF-29: a legacy v2 checkpoint (full track inline, written by an older build) still restores.
    func testLegacyV2FullSnapshotRestores() throws {
        let source = AppState()
        startWT9Flight(on: source)
        source.currentFlight?.gpsTrack = (0..<12).map { makePoint(45.0 + Double($0) * 0.001, 6.0) }
        let flight = try XCTUnwrap(source.currentFlight)
        var snapshot = ActiveFlightState(flight: flight, from: source)
        snapshot.schemaVersion = ActiveFlightState.legacyFullTrackSchemaVersion

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try DataPersistenceManager.writeActiveFlightStateData(
            try encoder.encode(snapshot), to: DataPersistenceManager.shared.activeFlightStateURL
        )

        let relaunched = AppState()
        XCTAssertTrue(relaunched.isFlightActive)
        XCTAssertEqual(relaunched.currentFlight?.gpsTrack.count, 12,
                       "A v2 snapshot's inline track must restore unchanged")

        relaunched.clearActiveFlightState()
        relaunched.isFlightActive = false
        source.isFlightActive = false
    }

    /// A restored *premium* flight reports its checklist as unresolved — never the silent WT9
    /// fallback. (ARCH-01 / ARCH-08)
    func testRestoredPremiumFlightDoesNotFallBackToWT9() throws {
        let source = AppState()
        startWT9Flight(on: source)
        let flight = try XCTUnwrap(source.currentFlight)
        // Mark the snapshot as a premium aircraft selection (no resolved checklist).
        source.settings.selectedRemoteAircraftId = "pa28-181"
        let snapshot = ActiveFlightState(flight: flight, from: source)

        let restored = AppState()
        snapshot.restore(to: restored)

        XCTAssertEqual(restored.settings.selectedRemoteAircraftId, "pa28-181")
        XCTAssertFalse(restored.isPremiumChecklistResolved,
                       "Restored premium flight must be unresolved, not silently WT9")
        XCTAssertFalse(restored.activeChecklist.isResolved)

        restored.clearActiveFlightState()
        restored.isFlightActive = false
        source.isFlightActive = false
    }

    /// An unreadable / wrong-schema snapshot is discarded, not crashed on. (ARCH-08)
    func testCorruptSnapshotIsDiscardedSafely() throws {
        let url = DataPersistenceManager.shared.activeFlightStateURL
        try Data("{ not valid json".utf8).write(to: url, options: .atomic)

        let relaunched = AppState()
        XCTAssertFalse(relaunched.isFlightActive, "A corrupt checkpoint must not start a phantom flight")
        XCTAssertFalse(relaunched.hasActiveFlightState, "A corrupt checkpoint must be cleared")
    }
}
