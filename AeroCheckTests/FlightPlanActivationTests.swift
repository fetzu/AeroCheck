import XCTest
import CoreLocation
@testable import AeroCheck

/// Activation lifetime (v4.4.0).
///
/// Activating a plan used to be discarded on every `scenePhase == .active` when no flight was
/// running — so activating in the clubhouse and then glancing at another app silently threw the plan
/// away, taking the nav map's route with it. The condition was wrong in principle too: activating
/// before engine start is the normal order of work, not a stale leftover.
///
/// Staleness is now a question of AGE, checked once at launch. These tests pin both halves: a recent
/// activation survives, an abandoned one does not, and an activation with no recorded age is kept
/// (unknown is not evidence of stale).
@MainActor
final class FlightPlanActivationTests: XCTestCase {

    private func plan(named name: String = "LSZQ → LSZB") -> FlightPlan {
        FlightPlan(
            name: name,
            waypoints: [
                FlightPlanWaypoint(name: "LSZQ", coordinate: .init(latitude: 47.392, longitude: 7.030)),
                FlightPlanWaypoint(name: "LSZB", coordinate: .init(latitude: 46.914, longitude: 7.497)),
            ]
        )
    }

    /// A manager on its OWN defaults suite. The test host shares the app's bundle id, so building one
    /// against `.standard` wrote a synthetic route into the real app's active-plan slot — a test
    /// artifact that then showed up as ACTIVE in the app on that simulator.
    private var suiteName = ""

    private func manager() -> FlightPlanManager {
        suiteName = "FlightPlanActivationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return FlightPlanManager(defaults: defaults)
    }

    override func tearDown() {
        if !suiteName.isEmpty { UserDefaults().removePersistentDomain(forName: suiteName) }
        suiteName = ""
        super.tearDown()
    }

    func testActivationStampsTheTime() {
        let manager = manager()
        manager.activateFlightPlan(plan())
        XCTAssertNotNil(manager.activeFlightPlan?.activatedAt,
                        "activation must be dated, or it can never be expired")
    }

    /// The bug. A plan activated moments ago must still be active — this is the pilot who activated
    /// in the clubhouse and then checked the weather app.
    func testRecentActivationSurvivesTheLaunchCheck() {
        let manager = manager()
        manager.activateFlightPlan(plan())

        XCTAssertFalse(manager.expireStaleActivation(), "a fresh activation must not be expired")
        XCTAssertNotNil(manager.activeFlightPlan)
    }

    /// Still active a day later — Friday-evening planning for a Saturday flight.
    func testActivationSurvivesADay() {
        let manager = manager()
        manager.activateFlightPlan(plan())

        let tomorrow = Date().addingTimeInterval(24 * 60 * 60)
        XCTAssertFalse(manager.expireStaleActivation(now: tomorrow))
        XCTAssertNotNil(manager.activeFlightPlan)
    }

    /// But not indefinitely: an activation nobody flew stops framing the nav map eventually.
    func testAbandonedActivationExpires() {
        let manager = manager()
        manager.activateFlightPlan(plan())

        let wellPast = Date().addingTimeInterval(FlightPlanManager.activationLifetime + 60)
        XCTAssertTrue(manager.expireStaleActivation(now: wellPast))
        XCTAssertNil(manager.activeFlightPlan)
    }

    /// The boundary belongs to the pilot: exactly at the lifetime, the plan is still theirs.
    func testExpiryIsExclusiveAtTheBoundary() throws {
        let manager = manager()
        manager.activateFlightPlan(plan())

        // Measured from the stamp the manager actually wrote, not from `Date()` here — the few
        // microseconds between the two would otherwise push this just past the boundary.
        let activatedAt = try XCTUnwrap(manager.activeFlightPlan?.activatedAt)
        let exactly = activatedAt.addingTimeInterval(FlightPlanManager.activationLifetime)
        XCTAssertFalse(manager.expireStaleActivation(now: exactly))
        XCTAssertNotNil(manager.activeFlightPlan)
    }

    /// Plans saved before v4.4.0 carry no `activatedAt`. An unknown age must not be read as an old
    /// one — that would silently deactivate every existing user's plan on upgrade.
    func testActivationWithoutATimestampIsKept() {
        let manager = manager()
        manager.activateFlightPlan(plan())
        manager.activeFlightPlan?.activatedAt = nil

        let wellPast = Date().addingTimeInterval(FlightPlanManager.activationLifetime * 10)
        XCTAssertFalse(manager.expireStaleActivation(now: wellPast))
        XCTAssertNotNil(manager.activeFlightPlan)
    }

    // MARK: - Deactivate confirmation (P2) and the expiry notice (P5)

    /// Nothing recorded yet — the pre-flight case. Deactivating costs nothing, so the UI must not
    /// stop and ask.
    func testFreshlyArmedPlanHasNoProgressToLose() {
        let manager = manager()
        manager.activateFlightPlan(plan())
        XCTAssertFalse(manager.activePlanHasRecordedProgress)
    }

    /// A logged waypoint time is exactly what a deactivate → re-activate round trip destroys, so it
    /// must count as progress.
    func testARecordedWaypointTimeCountsAsProgress() {
        let manager = manager()
        manager.activateFlightPlan(plan())
        manager.activeFlightPlan?.waypoints[0].actualTimeOver = Date()
        XCTAssertTrue(manager.activePlanHasRecordedProgress)
    }

    func testAdvancingPastTheFirstWaypointCountsAsProgress() {
        let manager = manager()
        manager.activateFlightPlan(plan())
        manager.activeFlightPlan?.currentWaypointIndex = 1
        XCTAssertTrue(manager.activePlanHasRecordedProgress)
    }

    /// A running leg timer is progress too — deactivating resets it.
    func testARunningChronometerCountsAsProgress() {
        let manager = manager()
        manager.activateFlightPlan(plan())
        manager.activeFlightPlan?.chronometerStartTime = Date()
        XCTAssertTrue(manager.activePlanHasRecordedProgress)
    }

    /// An expiry must leave enough behind to explain itself and to be undone — the whole point of the
    /// notice is that the app no longer changes this state silently.
    func testExpiryRecordsWhatItRetired() throws {
        let manager = manager()
        manager.activateFlightPlan(plan())
        let wellPast = Date().addingTimeInterval(FlightPlanManager.activationLifetime + 60)

        XCTAssertTrue(manager.expireStaleActivation(now: wellPast))
        let expired = try XCTUnwrap(manager.expiredActivation)
        XCTAssertEqual(expired.routeLabel, "LSZQ → LSZB", "the notice names the route, as the plan list does")
    }

    /// …and re-arming from the notice actually re-arms, rather than just clearing the banner.
    func testRearmingRestoresTheActivation() throws {
        let manager = manager()
        let subject = plan()
        manager.flightPlans = [subject]
        manager.activateFlightPlan(subject)
        _ = manager.expireStaleActivation(now: Date().addingTimeInterval(FlightPlanManager.activationLifetime + 60))
        XCTAssertNil(manager.activeFlightPlan)

        manager.rearmExpiredActivation()

        XCTAssertEqual(manager.activeFlightPlan?.id, subject.id)
        XCTAssertNil(manager.expiredActivation, "the notice clears once acted on")
    }

    /// If the plan was deleted while the notice was up, re-arming clears the notice instead of
    /// resurrecting something that no longer exists.
    func testRearmingADeletedPlanJustClearsTheNotice() {
        let manager = manager()
        manager.activateFlightPlan(plan())          // never added to `flightPlans`
        _ = manager.expireStaleActivation(now: Date().addingTimeInterval(FlightPlanManager.activationLifetime + 60))

        manager.rearmExpiredActivation()

        XCTAssertNil(manager.activeFlightPlan)
        XCTAssertNil(manager.expiredActivation)
    }

    func testNoActivePlanIsNotAnExpiry() {
        XCTAssertFalse(manager().expireStaleActivation())
    }

    /// `activatedAt` must round-trip, or the expiry check reads nil on every launch and the plan
    /// becomes immortal.
    func testActivatedAtSurvivesCodableRoundTrip() throws {
        var subject = plan()
        subject.activatedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FlightPlan.self, from: try encoder.encode(subject))

        XCTAssertEqual(decoded.activatedAt?.timeIntervalSince1970 ?? 0,
                       1_800_000_000, accuracy: 1)
    }
}
