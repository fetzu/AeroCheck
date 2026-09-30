import XCTest
#if canImport(ActivityKit)
import ActivityKit
#endif
@testable import AeroCheck

/// Tests the flight-start safety guard: a flight must never begin for a premium aircraft
/// whose checklist hasn't resolved (ARCH-01). This is the single choke point that protects
/// every entry point (HomeView, deep link, widget). The unresolved state is now modelled by the
/// owned `AppState.activeChecklist` (premium selected + no resolved checklist) rather than the
/// former global `ChecklistData` statics.
@MainActor
final class AppStateFlightStartTests: XCTestCase {

    func testStartBlockedWhenPremiumChecklistUnresolved() {
        let appState = makeTestAppState()
        // A premium aircraft is selected but its checklist failed to load (resolvedRemoteChecklist nil).
        appState.settings.selectedRemoteAircraftId = "pa28-181"
        appState.flightStartError = nil
        XCTAssertFalse(appState.isPremiumChecklistResolved, "Premium checklist should be unresolved")

        appState.startFlight(
            withAircraft: "HB-PFA", aircraftRegistration: "HB-PFA",
            aircraftType: "PA28", checklistVersion: nil, flightPlanId: nil, circuitMode: false
        )

        XCTAssertFalse(appState.isFlightActive, "Flight must not start with an unresolved premium checklist")
        XCTAssertNotNil(appState.flightStartError, "A blocked start must surface an explicit error")
    }

    func testStartSucceedsWhenChecklistResolved() {
        let appState = makeTestAppState()
        // Free aircraft / no premium checklist expected.
        appState.settings.selectedRemoteAircraftId = nil
        appState.settings.selectedAircraft = .wt9Dynamic
        appState.flightStartError = nil
        XCTAssertTrue(appState.isPremiumChecklistResolved)

        appState.startFlight(
            withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA",
            aircraftType: "WT9", checklistVersion: nil, flightPlanId: nil, circuitMode: false
        )

        XCTAssertTrue(appState.isFlightActive, "A resolved-checklist flight should start")
        XCTAssertNil(appState.flightStartError)
        // Cancel (not just isFlightActive = false): tears down the flight AND clears any
        // checkpoint, so nothing leaks into the shared simulator container (test-host trap).
        appState.cancelFlight()
    }

    /// An AppState built by a test is not the app's, so it must leave the device's Live Activities
    /// alone. On the shared controller, every test flight started a real activity on the simulator,
    /// and because the controller adopts whatever activity is already running, a test flight could
    /// also overwrite the real flight's with its own content, or end it.
    func testATestFlightLeavesTheDevicesLiveActivitiesAlone() throws {
        #if canImport(ActivityKit)
        try XCTSkipUnless(ActivityAuthorizationInfo().areActivitiesEnabled, "Live Activities are off on this device")
        let before = Set(Activity<FlightActivityAttributes>.activities.map(\.id))

        let appState = makeTestAppState()
        appState.startFlight(
            withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA",
            aircraftType: "WT9", checklistVersion: nil, flightPlanId: nil, circuitMode: false
        )
        XCTAssertTrue(appState.isFlightActive, "precondition: the flight started")
        appState.checkpointActiveFlight(force: true)
        appState.cancelFlight()

        // New ids only: the app's own AppState may legitimately end activities meanwhile.
        let appeared = Set(Activity<FlightActivityAttributes>.activities.map(\.id)).subtracting(before)
        XCTAssertTrue(appeared.isEmpty, "a test flight started \(appeared.count) Live Activit(ies) on the device")
        #else
        throw XCTSkip("ActivityKit is not available")
        #endif
    }

    // MARK: - Live Activities: one, the current flight's (6.0)

    func testWithNoFlightEveryActivityEnds() {
        let items: [LiveActivityTriage.Item] = [.init(flightId: UUID(), isLive: true), .init(flightId: nil, isLive: true)]
        let decision = LiveActivityTriage.decide(items, currentFlightId: nil)
        XCTAssertNil(decision.keep)
        XCTAssertEqual(decision.end, [0, 1], "a quit flight's activity doesn't outlive a launch without it")
    }

    func testTheFlightKeepsItsOwnActivityAndNothingElse() {
        let flight = UUID()
        let items: [LiveActivityTriage.Item] = [
            .init(flightId: UUID(), isLive: false),   // the last flight's, ended but still on screen
            .init(flightId: flight, isLive: true),     // this flight's
            .init(flightId: flight, isLive: true),     // a duplicate of it
            .init(flightId: nil, isLive: true),        // one from an older build
        ]
        let decision = LiveActivityTriage.decide(items, currentFlightId: flight)
        XCTAssertEqual(decision.keep, 1)
        XCTAssertEqual(decision.end, [0, 2, 3])
    }

    func testAnEndedActivityOfTheFlightIsNotAdopted() {
        let flight = UUID()
        let decision = LiveActivityTriage.decide([.init(flightId: flight, isLive: false)], currentFlightId: flight)
        XCTAssertNil(decision.keep, "an ended activity can't be updated: the flight gets a new one")
        XCTAssertEqual(decision.end, [0])
    }
}

