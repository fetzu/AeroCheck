import XCTest
@testable import AeroCheck

/// Tests the flight-start safety guard: a flight must never begin for a premium aircraft
/// whose checklist hasn't resolved (ARCH-01). This is the single choke point that protects
/// every entry point (HomeView, deep link, widget). The unresolved state is now modelled by the
/// owned `AppState.activeChecklist` (premium selected + no resolved checklist) rather than the
/// former global `ChecklistData` statics.
@MainActor
final class AppStateFlightStartTests: XCTestCase {

    func testStartBlockedWhenPremiumChecklistUnresolved() {
        let appState = AppState()
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
        let appState = AppState()
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
        appState.isFlightActive = false
    }
}
