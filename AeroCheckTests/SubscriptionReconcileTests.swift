import XCTest
@testable import AeroCheck

/// Tests the down-reconciliation: a confirmed "no active subscription" (e.g. from a manual restore)
/// closes the offline grace window so a lapsed subscription can't keep premium content alive
/// offline on the strength of a stale prior verification. (ARCH-11)
@MainActor
final class SubscriptionReconcileTests: XCTestCase {

    /// These tests drive grace/verification state (startGracePeriod, confirmNoActiveSubscription), so
    /// each manager gets a defaults suite (and Keychain service) of its own. They used to run on
    /// `.standard` and clear both keys before and after every test, which reset the real app's grace
    /// window on the simulator.
    private func manager() -> SubscriptionManager {
        makeTestSubscriptionManager(deferLoadProducts: true)
    }

    func testConfirmNoActiveSubscriptionClosesGraceWindow() {
        // The init's async work is queued on the main actor; this fully-synchronous test body runs
        // before it can fire, so the assertions are deterministic.
        let sm = manager()

        // Clean slate (this also downgrades to .notSubscribed), then simulate a transient-failure
        // grace window that is currently keeping premium content available.
        sm.confirmNoActiveSubscription()
        sm.startGracePeriod()
        XCTAssertTrue(sm.shouldAllowPremiumAccess(), "An active grace window keeps premium alive")

        // A definitive "no subscription" must close that window immediately.
        sm.confirmNoActiveSubscription()
        XCTAssertFalse(
            sm.shouldAllowPremiumAccess(),
            "A confirmed no-subscription must close the grace window and deny premium"
        )
    }

    /// Lifetime is a one-time, permanent entitlement: it grants premium with no grace window and is
    /// never gated on the offline re-verification window or "definitively denied".
    func testLifetimeStatusGrantsPermanentPremium() {
        let sm = manager()
        sm.confirmNoActiveSubscription()                 // clean slate: notSubscribed, no grace
        XCTAssertFalse(sm.shouldAllowPremiumAccess())

        sm.subscriptionStatus = .lifetime
        XCTAssertTrue(sm.subscriptionStatus.isSubscribed, "Lifetime counts as entitled")
        XCTAssertTrue(sm.subscriptionStatus.isLifetime)
        XCTAssertEqual(sm.subscriptionStatus.productID, "aerocheck.pro.lifetime")
        XCTAssertTrue(sm.shouldAllowPremiumAccess(), "Lifetime is permanent — never gated on the offline window")
        XCTAssertFalse(sm.isPremiumAccessDefinitivelyDenied(), "Lifetime is never definitively denied")
    }

    /// The entitlement flags must distinguish subscriptions from lifetime correctly.
    func testSubscriptionStatusEntitlementFlags() {
        let future = Date().addingTimeInterval(1000)
        XCTAssertFalse(SubscriptionStatus.unknown.isSubscribed)
        XCTAssertFalse(SubscriptionStatus.notSubscribed.isSubscribed)

        let sub = SubscriptionStatus.subscribed(expiresAt: future, productID: "aerocheck.pro.yearly")
        XCTAssertTrue(sub.isSubscribed)
        XCTAssertFalse(sub.isLifetime)

        XCTAssertTrue(SubscriptionStatus.lifetime.isSubscribed)
        XCTAssertTrue(SubscriptionStatus.lifetime.isLifetime)
    }

    // MARK: - Session token storage (SEC-C3)

    /// Every installed token lives under this service: renaming it would orphan them all and send
    /// every subscriber through a fresh verification.
    func testTheAppKeepsItsKeychainService() {
        XCTAssertEqual(KeychainStore.app.service, "app.aerocheck.credentials")
    }

    /// A store sees only the items under its own service. That is what keeps a test's token apart
    /// from the app's: the test host shares the app's Keychain.
    func testAKeychainStoreOnlySeesItsOwnService() {
        let mine = makeTestKeychain(), other = makeTestKeychain()
        XCTAssertTrue(mine.set("token-1", for: .apiSessionToken))
        XCTAssertEqual(mine.get(.apiSessionToken), "token-1")
        XCTAssertNil(other.get(.apiSessionToken), "another service must not see it")

        other.remove(.apiSessionToken)
        XCTAssertEqual(mine.get(.apiSessionToken), "token-1", "nor remove it")
        mine.remove(.apiSessionToken)
        XCTAssertNil(mine.get(.apiSessionToken))
    }

    /// The Bearer credential comes from the store the manager was given, not from the app's.
    func testTheSessionTokenIsReadFromTheInjectedKeychain() async {
        let keychain = makeTestKeychain()
        keychain.set("minted-token", for: .apiSessionToken)
        let sm = SubscriptionManager(defaults: makeTestDefaults(), keychain: keychain, deferLoadProducts: true)

        let credential = await sm.getAuthCredential()
        XCTAssertEqual(credential, "minted-token")
    }
}
