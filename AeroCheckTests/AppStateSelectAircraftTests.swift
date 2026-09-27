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
        let appState = makeTestAppState()
        appState.settings.selectedRemoteAircraftId = "pa28-181" // pretend a remote was selected

        XCTAssertTrue(appState.selectAircraft(id: "WT9", available: []))

        XCTAssertNil(appState.settings.selectedRemoteAircraftId, "Selecting a bundled aircraft must clear the remote selection")
        XCTAssertEqual(appState.settings.selectedAircraft, .wt9Dynamic)
    }

    func testSelectBundledByRegistration() {
        let appState = makeTestAppState()
        appState.settings.selectedRemoteAircraftId = "pa28-181"

        XCTAssertTrue(appState.selectAircraft(id: "F-HVXA", available: []))

        XCTAssertNil(appState.settings.selectedRemoteAircraftId)
        XCTAssertEqual(appState.settings.selectedAircraft, .wt9Dynamic)
    }

    func testSelectRemoteById() {
        let appState = makeTestAppState()
        let meta = metadata(id: "pa28-181", registration: "HB-PFA")

        XCTAssertTrue(appState.selectAircraft(id: "pa28-181", available: [meta]))

        XCTAssertEqual(appState.settings.selectedRemoteAircraftId, "pa28-181")
    }

    func testSelectRemoteByRegistration() {
        let appState = makeTestAppState()
        let meta = metadata(id: "pa28-181", registration: "HB-PFA")

        XCTAssertTrue(appState.selectAircraft(id: "HB-PFA", available: [meta]))

        XCTAssertEqual(appState.settings.selectedRemoteAircraftId, "pa28-181",
                       "A registration token must resolve to the matching remote aircraft id")
    }

    func testSelectUnknownReturnsFalseAndLeavesSelectionUntouched() {
        let appState = makeTestAppState()
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
        let appState = makeTestAppState()
        let bundledDuplicate = metadata(id: "wt9-dynamic", registration: "F-HVXA", isFree: true)

        XCTAssertTrue(appState.selectAircraft(id: "wt9-dynamic", available: [bundledDuplicate]))

        XCTAssertNil(appState.settings.selectedRemoteAircraftId, "wt9-dynamic must select the bundled aircraft")
        XCTAssertEqual(appState.settings.selectedAircraft, .wt9Dynamic)
    }

    /// A bundled token must win even when remote metadata is supplied, so the free aircraft is
    /// never shadowed by a remote record that happens to share a registration.
    func testBundledMatchTakesPrecedenceOverRemote() {
        let appState = makeTestAppState()
        let collidingRemote = metadata(id: "wt9-clone", registration: "F-HVXA")

        XCTAssertTrue(appState.selectAircraft(id: "F-HVXA", available: [collidingRemote]))

        XCTAssertNil(appState.settings.selectedRemoteAircraftId)
        XCTAssertEqual(appState.settings.selectedAircraft, .wt9Dynamic)
    }

    // MARK: - FlightTiming facade (Phase 4 — AppState decomposition: state extraction)

    func testTimingAccessorsForwardToFlightTimingValue() {
        let appState = makeTestAppState()
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
        let appState = makeTestAppState()

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

    // MARK: - The flyable list (Today's aircraft menu, the Aircraft tab — on-device review #1, G-06)

    func testFlyableListsBundledThenAccessiblePremium() {
        var locked = metadata(id: "pa28-236", registration: "HB-PMP")
        locked.hasAccess = false
        let open = metadata(id: "pa28-181", registration: "HB-PFA")

        let options = AircraftOption.flyable(remote: [locked, open], settings: AppSettings())

        XCTAssertEqual(options.map(\.registration), AircraftType.allCases.map(\.registration) + ["HB-PFA"],
                       "bundled first, then the premium aircraft the pilot can fly; the locked one isn't offered")
    }

    /// The lists use `AircraftDataService.canFly`: an aircraft the server still lists as accessible
    /// isn't offered once this device says Pro lapsed. (on-device review #4, point 1)
    func testFlyableUsesTheCanFlyRule() {
        let open = metadata(id: "pa28-181", registration: "HB-PFA")
        let options = AircraftOption.flyable(remote: [open], settings: AppSettings(), canFly: { _ in false })
        XCTAssertEqual(options.map(\.registration), AircraftType.allCases.map(\.registration))
    }

    /// A selected premium aircraft that can't be flown stays selected, and is reported locked, so
    /// Today and the Aircraft tab can say why instead of swapping in the WT9 without a word.
    func testALapsedSelectionIsKeptAndReportedLocked() {
        let archer = metadata(id: "pa28-181", registration: "HB-PFA")
        var settings = AppSettings()
        settings.selectedRemoteAircraftId = "pa28-181"

        XCTAssertEqual(AircraftOption.lockedSelection(remote: [archer], settings: settings, canFly: { _ in false })?.id,
                       "pa28-181")
        XCTAssertNil(AircraftOption.lockedSelection(remote: [archer], settings: settings, canFly: { _ in true }),
                     "a flyable selection isn't locked")

        settings.hiddenAircraftIds = ["pa28-181"]
        XCTAssertNil(AircraftOption.lockedSelection(remote: [archer], settings: settings, canFly: { _ in false }),
                     "hidden is the pilot's choice: the selection moves, as before")

        settings.hiddenAircraftIds = []
        settings.selectedRemoteAircraftId = nil
        XCTAssertNil(AircraftOption.lockedSelection(remote: [archer], settings: settings, canFly: { _ in false }),
                     "the WT9 is never locked")
    }

    func testFlyableFollowsTheVisibilityFilter() {
        var settings = AppSettings()
        settings.hiddenAircraftIds = ["pa28-181"]
        let options = AircraftOption.flyable(remote: [metadata(id: "pa28-181", registration: "HB-PFA")],
                                             settings: settings)
        XCTAssertFalse(options.contains { $0.registration == "HB-PFA" })
    }

    func testExactlyTheSelectedAircraftIsTicked() {
        let remote = metadata(id: "pa28-181", registration: "HB-PFA")
        var settings = AppSettings()
        let options = AircraftOption.flyable(remote: [remote], settings: settings)
        XCTAssertEqual(options.filter { $0.isSelected(in: settings) }.map(\.registration), ["F-HVXA"])

        settings.selectedRemoteAircraftId = "pa28-181"
        XCTAssertEqual(options.filter { $0.isSelected(in: settings) }.map(\.registration), ["HB-PFA"])
    }

    func testEveryFlyableOptionSelectsThroughAppState() {
        let appState = makeTestAppState()
        let remote = metadata(id: "pa28-181", registration: "HB-PFA")
        for option in AircraftOption.flyable(remote: [remote], settings: appState.settings) {
            XCTAssertTrue(appState.selectAircraft(id: option.selectionToken, available: [remote]))
            XCTAssertTrue(option.isSelected(in: appState.settings), option.registration)
        }
    }
}
