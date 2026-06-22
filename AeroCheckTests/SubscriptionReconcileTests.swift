import XCTest
@testable import AeroCheck

/// Tests the down-reconciliation: a confirmed "no active subscription" (e.g. from a manual restore)
/// closes the offline grace window so a lapsed subscription can't keep premium content alive
/// offline on the strength of a stale prior verification. (ARCH-11)
@MainActor
final class SubscriptionReconcileTests: XCTestCase {

    /// These tests drive grace/verification state through UserDefaults.standard (startGracePeriod,
    /// confirmNoActiveSubscription). Clear those keys before AND after each test so state can't leak
    /// between tests here or into any other suite that reads the same keys.
    private func clearSubscriptionDefaults() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "subscriptionLastVerificationDate")
        d.removeObject(forKey: "subscriptionGracePeriodStart")
    }

    override func setUp() {
        super.setUp()
        clearSubscriptionDefaults()
    }

    override func tearDown() {
        clearSubscriptionDefaults()
        super.tearDown()
    }

    func testConfirmNoActiveSubscriptionClosesGraceWindow() {
        // The init's async work is queued on the main actor; this fully-synchronous test body runs
        // before it can fire, so the assertions are deterministic.
        let sm = SubscriptionManager(deferLoadProducts: true)

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
        let sm = SubscriptionManager(deferLoadProducts: true)
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
}
