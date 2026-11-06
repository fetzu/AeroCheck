import XCTest
@testable import AeroCheck

/// Today's Getting started card (6.8.0, the author's answer 7 A, 31 Oct 2026): up to six rows that tick themselves
/// off, the Pro row only for a Pro aircraft chosen without Pro, gone once all are done or hidden, and only after the
/// new onboarding.
final class GettingStartedTests: XCTestCase {

    func testTheRowsInOrderTheProOnlyWhenOnboardingNamedOne() {
        var status = GettingStarted.Status()
        XCTAssertEqual(GettingStarted.items(status).map(\.item), [.base, .offline, .firstFlight, .route, .dryRun])
        status.proAircraft = "HB-KFD"
        XCTAssertEqual(GettingStarted.items(status).map(\.item), [.base, .offline, .firstFlight, .pro, .route, .dryRun])
        XCTAssertEqual(GettingStarted.items(status).filter(\.done).count, 0)
        status.hasPro = true
        status.hasHome = true
        XCTAssertEqual(GettingStarted.items(status).filter(\.done).map(\.item), [.base, .pro])
    }

    func testShownAfterOnboardingUntilAllDoneOrHidden() {
        var status = GettingStarted.Status()
        XCTAssertFalse(GettingStarted.isShown(offered: false, hidden: false, status: status), "set up before 6.8.0")
        XCTAssertTrue(GettingStarted.isShown(offered: true, hidden: false, status: status))
        XCTAssertFalse(GettingStarted.isShown(offered: true, hidden: true, status: status))
        status = GettingStarted.Status(hasHome: true, offlineDone: true, firstFlightFlown: true, hasRoute: true,
                                       dryRunFlown: true)
        XCTAssertFalse(GettingStarted.isShown(offered: true, hidden: false, status: status), "all done")
        status.proAircraft = "HB-KFD"
        XCTAssertTrue(GettingStarted.isShown(offered: true, hidden: false, status: status), "Pro still to try")
    }

    func testOnboardingsEndOffersItAndTheDryRunCardStepsAside() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "GettingStartedTests"))
        defaults.removePersistentDomain(forName: "GettingStartedTests")
        GettingStarted.begin(proAircraft: "HB-KFD", defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: GettingStarted.offeredKey))
        XCTAssertEqual(defaults.string(forKey: GettingStarted.proAircraftKey), "HB-KFD")
        GettingStarted.begin(proAircraft: nil, defaults: defaults)
        XCTAssertNil(defaults.string(forKey: GettingStarted.proAircraftKey))
        defaults.removePersistentDomain(forName: "GettingStartedTests")
    }

    func testATickedRowStaysTicked() {
        // The last route deleted, a country removed: the row stays done and the card stays gone.
        let done = GettingStarted.Status(hasHome: true, offlineDone: true, firstFlightFlown: true, hasRoute: true, dryRunFlown: true)
        XCTAssertFalse(GettingStarted.isShown(offered: true, hidden: false, status: done))
        let stored = GettingStarted.ticks(GettingStarted.items(done))
        var later = done
        later.hasRoute = false
        later.offlineDone = false
        XCTAssertTrue(GettingStarted.isShown(offered: true, hidden: false, status: later), "without the memory it came back")
        XCTAssertFalse(GettingStarted.isShown(offered: true, hidden: false, status: later, ticked: GettingStarted.ticked(from: stored)))
    }

    func testTheTicksReadBackAndIgnoreARowThatIsGone() {
        XCTAssertEqual(GettingStarted.ticked(from: "base,route,gone"), [.base, .route])
        XCTAssertEqual(GettingStarted.ticked(from: ""), [])
    }

    func testARealFlightRetiresTheCardForGood() {
        let defaults = UserDefaults(suiteName: "GettingStartedRetire")!
        GettingStarted.retire(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: GettingStarted.hiddenKey))
        defaults.removePersistentDomain(forName: "GettingStartedRetire")
    }

    /// The one-time tips (the author's answer 8 A): never in flight past the line-up, never in a dry run.
    func testTheTipsKeepQuietInFlightPastTheLineUpAndInADryRun() {
        XCTAssertFalse(AeroTips.isQuiet(flightActive: false, phase: .cruise, dryRunRunning: false), "on the ground")
        XCTAssertFalse(AeroTips.isQuiet(flightActive: true, phase: .taxi, dryRunRunning: false))
        XCTAssertFalse(AeroTips.isQuiet(flightActive: true, phase: .lineUp, dryRunRunning: false))
        XCTAssertTrue(AeroTips.isQuiet(flightActive: true, phase: .climb, dryRunRunning: false))
        XCTAssertTrue(AeroTips.isQuiet(flightActive: true, phase: .hangar, dryRunRunning: false))
        XCTAssertTrue(AeroTips.isQuiet(flightActive: false, phase: .preflight, dryRunRunning: true))
    }
}
