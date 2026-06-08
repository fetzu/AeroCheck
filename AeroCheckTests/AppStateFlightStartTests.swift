import XCTest
@testable import AeroCheck

/// Tests the flight-start safety guard: a flight must never begin for a premium aircraft
/// whose checklist hasn't resolved (ARCH-01). This is the single choke point that protects
/// every entry point (HomeView, deep link, widget), and a prerequisite test net for the
/// larger flight-start refactor.
@MainActor
final class AppStateFlightStartTests: XCTestCase {

    override func tearDown() {
        // Reset shared checklist state so suites don't contaminate each other.
        ChecklistData.expectsRemoteChecklist = false
        ChecklistData.currentRemoteChecklist = nil
        super.tearDown()
    }

    func testStartBlockedWhenPremiumChecklistUnresolved() {
        let appState = AppState()
        // A premium aircraft is selected but its checklist failed to load.
        ChecklistData.expectsRemoteChecklist = true
        ChecklistData.currentRemoteChecklist = nil
        appState.flightStartError = nil

        appState.startFlight(
            withAircraft: "HB-PFA", aircraftRegistration: "HB-PFA",
            aircraftType: "PA28", checklistVersion: nil, flightPlanId: nil, circuitMode: false
        )

        XCTAssertFalse(appState.isFlightActive, "Flight must not start with an unresolved premium checklist")
        XCTAssertNotNil(appState.flightStartError, "A blocked start must surface an explicit error")
    }

    func testStartSucceedsWhenChecklistResolved() {
        let appState = AppState()
        // Free aircraft / no premium checklist expected.
        ChecklistData.expectsRemoteChecklist = false
        ChecklistData.currentRemoteChecklist = nil
        appState.flightStartError = nil

        appState.startFlight(
            withAircraft: "F-HVXA", aircraftRegistration: "F-HVXA",
            aircraftType: "WT9", checklistVersion: nil, flightPlanId: nil, circuitMode: false
        )

        XCTAssertTrue(appState.isFlightActive, "A resolved-checklist flight should start")
        XCTAssertNil(appState.flightStartError)
        appState.isFlightActive = false
    }
}
