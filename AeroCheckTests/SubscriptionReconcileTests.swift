import XCTest
@testable import AeroCheck

/// Tests the down-reconciliation: a confirmed "no active subscription" (e.g. from a manual restore)
/// closes the offline grace window so a lapsed subscription can't keep premium content alive
/// offline on the strength of a stale prior verification. (ARCH-11)
@MainActor
final class SubscriptionReconcileTests: XCTestCase {

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
}
