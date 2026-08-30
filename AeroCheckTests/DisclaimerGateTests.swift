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
    private var saved: Any?

    override func setUp() {
        super.setUp()
        // AppState reads this key in init, and these tests write it, so preserve whatever the
        // simulator's defaults held and restore it afterwards.
        saved = UserDefaults.standard.object(forKey: key)
    }

    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    // MARK: - Gating

    func testFreshInstallIsGated() {
        UserDefaults.standard.removeObject(forKey: key)
        let appState = AppState()

        XCTAssertEqual(appState.acceptedDisclaimerVersion, 0,
                       "No stored key must read as 'never acknowledged', not as accepted")
        XCTAssertTrue(appState.needsDisclaimerAcceptance,
                      "A fresh install must be shown the safety notice")
    }

    func testAcceptingClearsTheGateAndPersists() {
        UserDefaults.standard.removeObject(forKey: key)
        let appState = AppState()
        appState.acceptDisclaimer()

        XCTAssertFalse(appState.needsDisclaimerAcceptance)
        XCTAssertEqual(appState.acceptedDisclaimerVersion, AppState.currentDisclaimerVersion)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: key), AppState.currentDisclaimerVersion,
                       "Acceptance must survive a relaunch")

        // A second AppState (i.e. the next launch) reads it back and does not re-gate.
        XCTAssertFalse(AppState().needsDisclaimerAcceptance)
    }

    func testAcknowledgingAnOlderVersionStillGates() {
        // The re-consent path: the notice changed materially, currentDisclaimerVersion was bumped,
        // and a device carrying the previous acknowledgement must be asked again.
        UserDefaults.standard.set(AppState.currentDisclaimerVersion - 1, forKey: key)
        let appState = AppState()

        XCTAssertTrue(appState.needsDisclaimerAcceptance,
                      "A stale acknowledgement must not satisfy a newer notice")
    }

    func testAcknowledgingANewerVersionDoesNotGate() {
        // Downgrade / TestFlight rollback: don't nag someone who has accepted something later.
        UserDefaults.standard.set(AppState.currentDisclaimerVersion + 1, forKey: key)
        XCTAssertFalse(AppState().needsDisclaimerAcceptance)
    }

    /// The upgrade case, and the one most likely to be got wrong: an existing user has
    /// `hasCompletedOnboarding == true`, so anything keyed on onboarding would let them straight
    /// past a notice they have never actually been shown.
    func testCompletedOnboardingDoesNotSatisfyTheGate() {
        UserDefaults.standard.removeObject(forKey: key)
        let appState = AppState()
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
