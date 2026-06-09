import XCTest
@testable import AeroCheck

/// Tests the shared aircraft-selection API (`AppState.selectAircraft`). This is the single
/// resolver every entry point (carousel, deep link, widget) delegates to, so it must match by
/// id **or** registration for both bundled and remote aircraft, and refuse unknown tokens so a
/// caller can decline to start a flight rather than launch the wrong/empty aircraft. (UX-11)
@MainActor
final class AppStateSelectAircraftTests: XCTestCase {

    /// Builds a minimal remote metadata record for selection tests.
    private func metadata(id: String, registration: String, isFree: Bool = false) -> RemoteAircraftMetadata {
        RemoteAircraftMetadata(
            id: id,
            aircraftType: "PA28",
            registration: registration,
            modelName: "Piper Archer II",
            shortModelName: "PA-28-181",
            aeroclub: nil,
            version: "1.0",
            lastUpdated: "2026-01-01",
            isFree: isFree,
            stallSpeed: 50,
            pageCount: 4,
            hasAccess: true,
            availableLanguages: ["en"]
        )
    }

    func testSelectBundledById() {
        let appState = AppState()
        appState.settings.selectedRemoteAircraftId = "pa28-181" // pretend a remote was selected

        XCTAssertTrue(appState.selectAircraft(id: "WT9", available: []))

        XCTAssertNil(appState.settings.selectedRemoteAircraftId, "Selecting a bundled aircraft must clear the remote selection")
        XCTAssertEqual(appState.settings.selectedAircraft, .wt9Dynamic)
    }

    func testSelectBundledByRegistration() {
        let appState = AppState()
        appState.settings.selectedRemoteAircraftId = "pa28-181"

        XCTAssertTrue(appState.selectAircraft(id: "F-HVXA", available: []))

        XCTAssertNil(appState.settings.selectedRemoteAircraftId)
        XCTAssertEqual(appState.settings.selectedAircraft, .wt9Dynamic)
    }

    func testSelectRemoteById() {
        let appState = AppState()
        let meta = metadata(id: "pa28-181", registration: "HB-PFA")

        XCTAssertTrue(appState.selectAircraft(id: "pa28-181", available: [meta]))

        XCTAssertEqual(appState.settings.selectedRemoteAircraftId, "pa28-181")
    }

    func testSelectRemoteByRegistration() {
        let appState = AppState()
        let meta = metadata(id: "pa28-181", registration: "HB-PFA")

        XCTAssertTrue(appState.selectAircraft(id: "HB-PFA", available: [meta]))

        XCTAssertEqual(appState.settings.selectedRemoteAircraftId, "pa28-181",
                       "A registration token must resolve to the matching remote aircraft id")
    }

    func testSelectUnknownReturnsFalseAndLeavesSelectionUntouched() {
        let appState = AppState()
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        let meta = metadata(id: "pa28-181", registration: "HB-PFA")

        XCTAssertFalse(appState.selectAircraft(id: "B737-NG", available: [meta]),
                       "An unknown token must be refused so the caller can decline to start")

        XCTAssertNil(appState.settings.selectedRemoteAircraftId)
        XCTAssertEqual(appState.settings.selectedAircraft, .wt9Dynamic)
    }

    /// The server-style id for a bundled aircraft (e.g. the `wt9-dynamic` token a widget or deep
    /// link passes) must resolve to the bundled aircraft, not its remote duplicate.
    func testSelectBundledByServerId() {
        let appState = AppState()
        let bundledDuplicate = metadata(id: "wt9-dynamic", registration: "F-HVXA", isFree: true)

        XCTAssertTrue(appState.selectAircraft(id: "wt9-dynamic", available: [bundledDuplicate]))

        XCTAssertNil(appState.settings.selectedRemoteAircraftId, "wt9-dynamic must select the bundled aircraft")
        XCTAssertEqual(appState.settings.selectedAircraft, .wt9Dynamic)
    }

    /// A bundled token must win even when remote metadata is supplied, so the free aircraft is
    /// never shadowed by a remote record that happens to share a registration.
    func testBundledMatchTakesPrecedenceOverRemote() {
        let appState = AppState()
        let collidingRemote = metadata(id: "wt9-clone", registration: "F-HVXA")

        XCTAssertTrue(appState.selectAircraft(id: "F-HVXA", available: [collidingRemote]))

        XCTAssertNil(appState.settings.selectedRemoteAircraftId)
        XCTAssertEqual(appState.settings.selectedAircraft, .wt9Dynamic)
    }

    // MARK: - FlightTiming facade (Phase 4 — AppState decomposition: state extraction)

    func testTimingAccessorsForwardToFlightTimingValue() {
        let appState = AppState()
        let t = Date(timeIntervalSince1970: 1000)

        // Writing through the legacy accessor mutates the cohesive FlightTiming value…
        appState.engineStartTime = t
        XCTAssertEqual(appState.flightTiming.engineStartTime, t)

        // …and writing the value is visible through the legacy accessor (both directions).
        appState.flightTiming.lineUpTime = t.addingTimeInterval(60)
        XCTAssertEqual(appState.lineUpTime, t.addingTimeInterval(60))

        // The four milestones are independent.
        XCTAssertNil(appState.landingTime)
        XCTAssertNil(appState.engineShutdownTime)
    }

    // MARK: - ChecklistProgress facade (Phase 4 — AppState decomposition: state extraction)

    func testChecklistProgressAccessorsForward() {
        let appState = AppState()

        // Scalar accessor forwards both directions.
        appState.currentPhase = .climb
        XCTAssertEqual(appState.checklistProgress.currentPhase, .climb)
        appState.checklistProgress.highestCompletedPhase = .cruise
        XCTAssertEqual(appState.highestCompletedPhase, .cruise)

        // Dictionary subscript mutation through the computed property must round-trip into the value
        // and stay reactive (read-modify-write via the forwarding setter).
        appState.phaseCompletionStatus[.taxi] = .completed
        XCTAssertEqual(appState.checklistProgress.phaseCompletionStatus[.taxi], .completed)

        appState.currentHighlightedItem[.climb] = 2
        XCTAssertEqual(appState.checklistProgress.currentHighlightedItem[.climb], 2)
    }
}
