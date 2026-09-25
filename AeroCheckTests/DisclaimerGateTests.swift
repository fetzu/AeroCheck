import XCTest
@testable import AeroCheck

/// The first-run safety-notice gate.
///
/// The gate is the whole point of the feature: an acknowledgement a pilot can skip is not an
/// acknowledgement. These tests pin the three ways it could silently stop gating — a fresh install
/// that isn't asked, an upgrade that isn't asked, and a version bump that doesn't re-ask — plus the
/// dead-link regression the paywall already shipped once.
@MainActor
final class DisclaimerGateTests: XCTestCase {

    private let key = "acceptedDisclaimerVersion"
    /// This test's own device: AppState reads the key in init and these tests write it. Saving and
    /// restoring the simulator's real value still wrote it for the length of the test, and a run
    /// that died mid-test left it behind.
    private var defaults: UserDefaults!
    private var datastore: DataPersistenceManager!

    override func setUp() {
        super.setUp()
        defaults = makeTestDefaults()
        datastore = makeTestDatastore()
    }

    /// A launch on this test's device.
    private func launch() -> AppState {
        makeTestAppState(datastore: datastore, defaults: defaults)
    }

    // MARK: - Gating

    func testFreshInstallIsGated() {
        defaults.removeObject(forKey: key)
        let appState = launch()

        XCTAssertEqual(appState.acceptedDisclaimerVersion, 0,
                       "No stored key must read as 'never acknowledged', not as accepted")
        XCTAssertTrue(appState.needsDisclaimerAcceptance,
                      "A fresh install must be shown the safety notice")
    }

    func testAcceptingClearsTheGateAndPersists() {
        defaults.removeObject(forKey: key)
        let appState = launch()
        appState.acceptDisclaimer()

        XCTAssertFalse(appState.needsDisclaimerAcceptance)
        XCTAssertEqual(appState.acceptedDisclaimerVersion, AppState.currentDisclaimerVersion)
        XCTAssertEqual(defaults.integer(forKey: key), AppState.currentDisclaimerVersion,
                       "Acceptance must survive a relaunch")

        // A second AppState (i.e. the next launch) reads it back and does not re-gate.
        XCTAssertFalse(launch().needsDisclaimerAcceptance)
    }

    func testAcknowledgingAnOlderVersionStillGates() {
        // The re-consent path: the notice changed materially, currentDisclaimerVersion was bumped,
        // and a device carrying the previous acknowledgement must be asked again.
        defaults.set(AppState.currentDisclaimerVersion - 1, forKey: key)
        let appState = launch()

        XCTAssertTrue(appState.needsDisclaimerAcceptance,
                      "A stale acknowledgement must not satisfy a newer notice")
    }

    func testAcknowledgingANewerVersionDoesNotGate() {
        // Downgrade / TestFlight rollback: don't nag someone who has accepted something later.
        defaults.set(AppState.currentDisclaimerVersion + 1, forKey: key)
        XCTAssertFalse(launch().needsDisclaimerAcceptance)
    }

    /// The upgrade case, and the one most likely to be got wrong: an existing user has
    /// `hasCompletedOnboarding == true`, so anything keyed on onboarding would let them straight
    /// past a notice they have never actually been shown.
    func testCompletedOnboardingDoesNotSatisfyTheGate() {
        defaults.removeObject(forKey: key)
        let appState = launch()
        appState.settings.hasCompletedOnboarding = true
        appState.hasSeenOnboarding = true

        XCTAssertTrue(appState.needsDisclaimerAcceptance,
                      "Having finished onboarding is not consent to the safety notice")
    }

    // MARK: - Terms link

    /// SubscriptionView shipped a Terms link to a path that had never existed and 404'd. The URL is
    /// now defined once, on DisclaimerView, and used by the paywall, the About screen and the gate.
    func testTermsURLIsTheCanonicalPublishedPath() {
        XCTAssertEqual(DisclaimerView.termsURL.absoluteString, "https://aerocheck.app/terms")
        XCTAssertEqual(DisclaimerView.termsURL.scheme, "https")
    }

    // MARK: - Notice version

    func testDisclaimerVersionIsPositive() {
        // 0 is the "never acknowledged" sentinel, so the current version can never be 0 — that would
        // make every device look accepted and disable the gate entirely.
        XCTAssertGreaterThan(AppState.currentDisclaimerVersion, 0)
    }
}
