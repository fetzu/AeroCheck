import XCTest
import CoreLocation
@testable import AeroCheck

/// Tests the shared `FlightLauncher` guard sequence. The pure `evaluate(...)` decision is
/// exercised for every branch (the guard order is the spec), and the two fast early-return
/// guards — an already-active flight (UX-06) and an unowned premium aircraft (UX-07) — are
/// verified end-to-end against a real `AppState` so we know `begin()` actually refuses the start
/// and records the right follow-up intent.
@MainActor
final class FlightLauncherTests: XCTestCase {

    // MARK: - Helpers

    private func metadata(id: String, registration: String, hasAccess: Bool, isFree: Bool = false) -> RemoteAircraftMetadata {
        RemoteAircraftMetadata(
            id: id, aircraftType: "PA28", registration: registration,
            modelName: "Piper Archer II", shortModelName: "PA-28-181", aeroclub: nil,
            version: "1.0", lastUpdated: "2026-01-01", isFree: isFree,
            stallSpeed: 50, pageCount: 4, hasAccess: hasAccess, availableLanguages: ["en"]
        )
    }

    private func makeLauncher(appState: AppState, aircraftDataService: AircraftDataService? = nil) -> FlightLauncher {
        let acs = aircraftDataService ?? AircraftDataService(subscriptionManager: SubscriptionManager())
        return FlightLauncher(
            appState: appState,
            locationManager: LocationManager(),
            aircraftDataService: acs,
            airportDataService: AirportDataService(),
            flightEventDetector: FlightEventDetector(),
            flightPlanManager: FlightPlanManager()
        )
    }

    // MARK: - Pure guard evaluation (order = which block wins)

    func testEvaluateActiveFlightWinsFirst() {
        XCTAssertEqual(
            FlightLauncher.evaluate(isFlightActive: true, isOwned: false, isChecklistResolved: false, authorization: .denied),
            .blockedActiveFlight)
    }

    func testEvaluateUnownedBeatsChecklistAndLocation() {
        XCTAssertEqual(
            FlightLauncher.evaluate(isFlightActive: false, isOwned: false, isChecklistResolved: false, authorization: .denied),
            .blockedUnowned)
    }

    func testEvaluateUnresolvedChecklistBlocks() {
        XCTAssertEqual(
            FlightLauncher.evaluate(isFlightActive: false, isOwned: true, isChecklistResolved: false, authorization: .authorizedWhenInUse),
            .blockedChecklistUnresolved)
    }

    func testEvaluateLocationDeniedBlocks() {
        XCTAssertEqual(
            FlightLauncher.evaluate(isFlightActive: false, isOwned: true, isChecklistResolved: true, authorization: .denied),
            .blockedLocationDenied)
    }

    func testEvaluateLocationRestrictedBlocks() {
        XCTAssertEqual(
            FlightLauncher.evaluate(isFlightActive: false, isOwned: true, isChecklistResolved: true, authorization: .restricted),
            .blockedLocationDenied)
    }

    func testEvaluateAllClearStarts() {
        for auth: CLAuthorizationStatus in [.authorizedWhenInUse, .authorizedAlways, .notDetermined] {
            XCTAssertEqual(
                FlightLauncher.evaluate(isFlightActive: false, isOwned: true, isChecklistResolved: true, authorization: auth),
                .started, "authorization \(auth.rawValue) should be allowed through")
        }
    }

    // MARK: - Shared-GPS fix requirement (option b)

    func testEvaluateAuthorizedButNoFixBlocksAcquiringGPS() {
        // Permission granted but no fix has locked yet — block (transient) rather than start blind.
        XCTAssertEqual(
            FlightLauncher.evaluate(isFlightActive: false, isOwned: true, isChecklistResolved: true,
                                    authorization: .authorizedWhenInUse, hasOwnFix: false, hasPeerFix: false),
            .blockedAcquiringGPS)
    }

    func testEvaluateNotDeterminedWithoutFixDefersToStart() {
        // The prompt hasn't been answered, so a fix can't exist yet — defer to startTracking.
        XCTAssertEqual(
            FlightLauncher.evaluate(isFlightActive: false, isOwned: true, isChecklistResolved: true,
                                    authorization: .notDetermined, hasOwnFix: false, hasPeerFix: false),
            .started)
    }

    func testEvaluateCompanionFixStartsWhenOwnGPSDenied() {
        // A GPS-less device (e.g. a Wi-Fi iPad) launches off the companion's borrowed GPS.
        XCTAssertEqual(
            FlightLauncher.evaluate(isFlightActive: false, isOwned: true, isChecklistResolved: true,
                                    authorization: .denied, hasOwnFix: false, hasPeerFix: true),
            .started)
    }

    func testEvaluateCompanionFixStartsWhenOwnGPSMissing() {
        // Permission granted but no own lock — a companion fix alone is enough to start.
        XCTAssertEqual(
            FlightLauncher.evaluate(isFlightActive: false, isOwned: true, isChecklistResolved: true,
                                    authorization: .authorizedWhenInUse, hasOwnFix: false, hasPeerFix: true),
            .started)
    }

    func testEvaluateOwnFixStartsWithoutCompanion() {
        XCTAssertEqual(
            FlightLauncher.evaluate(isFlightActive: false, isOwned: true, isChecklistResolved: true,
                                    authorization: .authorizedAlways, hasOwnFix: true, hasPeerFix: false),
            .started)
    }

    // MARK: - begin() integration for the early-return guards

    func testBeginDoesNotOverwriteRunningFlight() async {
        let appState = AppState()
        appState.currentFlight = Flight(airplane: "SENTINEL", startTime: Date())
        appState.isFlightActive = true
        let sentinelId = appState.currentFlight?.id

        let outcome = await makeLauncher(appState: appState).begin(circuitMode: false)

        XCTAssertEqual(outcome, .blockedActiveFlight)
        XCTAssertEqual(appState.currentFlight?.id, sentinelId, "A running flight must never be overwritten")
        appState.isFlightActive = false
    }

    func testBeginRefusesUnownedPremiumAndRequestsPaywall() async {
        let appState = AppState()
        appState.isFlightActive = false
        appState.currentFlight = nil
        appState.flightStartPaywallRequest = false
        appState.settings.selectedRemoteAircraftId = "pa28-181"

        let acs = AircraftDataService(subscriptionManager: SubscriptionManager())
        acs.availableAircraft = [metadata(id: "pa28-181", registration: "HB-PFA", hasAccess: false)]

        let outcome = await makeLauncher(appState: appState, aircraftDataService: acs).begin(circuitMode: false)

        XCTAssertEqual(outcome, .blockedUnowned)
        XCTAssertTrue(appState.flightStartPaywallRequest, "An unowned premium aircraft must request the paywall")
        XCTAssertFalse(appState.isFlightActive, "No flight may start for an unowned aircraft")
    }
}
