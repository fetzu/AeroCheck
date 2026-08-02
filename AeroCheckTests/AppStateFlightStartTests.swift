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
        // Cancel (not just isFlightActive = false): tears down the flight AND clears any
        // checkpoint, so nothing leaks into the shared simulator container (test-host trap).
        appState.cancelFlight()
    }

    // MARK: - Cruise check (manual-start countdown, 3.5)

    /// The countdown is MANUAL: until the pilot starts it (cruiseCheckStartTime == nil) it never goes
    /// due, even long past the interval, and the button shows the full interval.
    func testCruiseCheckIdleUntilStarted() {
        let appState = AppState()
        appState.currentPhase = .cruise
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(appState.cruiseCheckRemaining(now: t0), AppState.cruiseCheckInterval, accuracy: 0.001)
        appState.evaluateCruiseCheck(now: t0.addingTimeInterval(AppState.cruiseCheckInterval + 100))
        XCTAssertFalse(appState.cruiseCheckDue, "An un-started countdown must never become due")
        XCTAssertNil(appState.cruiseCheckStartTime)
    }

    /// Once started, it becomes due at the interval and re-arms the Cruise checklist.
    func testCruiseCheckDueAfterIntervalOnceStarted() {
        let appState = AppState()
        appState.currentPhase = .cruise
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        appState.cruiseCheckStartTime = start
        appState.evaluateCruiseCheck(now: start.addingTimeInterval(AppState.cruiseCheckInterval - 5))
        XCTAssertFalse(appState.cruiseCheckDue)
        XCTAssertEqual(appState.cruiseCheckRemaining(now: start.addingTimeInterval(AppState.cruiseCheckInterval - 5)), 5, accuracy: 0.001)
        appState.evaluateCruiseCheck(now: start.addingTimeInterval(AppState.cruiseCheckInterval))
        XCTAssertTrue(appState.cruiseCheckDue)
        XCTAssertEqual(appState.currentHighlightedItem[.cruise], 0, "Due must re-arm the Cruise checklist highlight")
        XCTAssertNil(appState.phaseCompletionStatus[.cruise], "Due must clear Cruise completion")
    }

    /// Arming (tap-to-start / acknowledge / hold-to-reset) clears due and restarts the countdown.
    func testArmCruiseCheckClearsDueAndResetsCountdown() {
        let appState = AppState()
        appState.currentPhase = .cruise
        appState.cruiseCheckDue = true
        appState.armCruiseCheck()
        XCTAssertFalse(appState.cruiseCheckDue)
        let start = try! XCTUnwrap(appState.cruiseCheckStartTime)
        XCTAssertEqual(appState.cruiseCheckRemaining(now: start), AppState.cruiseCheckInterval, accuracy: 0.5)
    }

    /// Leaving cruise clears the reminder and idles the countdown.
    func testLeavingCruiseClearsTimer() {
        let appState = AppState()
        appState.currentPhase = .cruise
        appState.cruiseCheckStartTime = Date()
        appState.cruiseCheckDue = true
        appState.currentPhase = .descent
        appState.evaluateCruiseCheck()
        XCTAssertFalse(appState.cruiseCheckDue, "Leaving cruise clears the reminder")
        XCTAssertNil(appState.cruiseCheckStartTime, "Leaving cruise idles the countdown")
    }
}
