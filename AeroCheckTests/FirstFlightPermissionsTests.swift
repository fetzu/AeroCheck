import CoreLocation
import CoreMotion
import UserNotifications
import XCTest
@testable import AeroCheck

/// What the first flight's page lists, and when it shows (the author's q1, 5 Nov 2026).
final class FirstFlightPermissionsTests: XCTestCase {
    private func items(notifications: UNAuthorizationStatus = .notDetermined, location: CLAuthorizationStatus = .authorizedWhenInUse,
                       motion: CMAuthorizationStatus = .notDetermined, barometer: Bool = true,
                       flown: Bool = false) -> [FirstFlightPermissions.Item] {
        FirstFlightPermissions.items(notifications: notifications, location: location, motion: motion,
                                     hasBarometer: barometer, hasFlown: flown)
    }

    func testANewPilotIsAskedAllThreeInOrder() {
        XCTAssertEqual(items(), [.reminders, .locationAlways, .motion])
    }

    func testWhatIsAlreadyAnsweredIsLeftOut() {
        XCTAssertEqual(items(notifications: .authorized), [.locationAlways, .motion])
        XCTAssertEqual(items(notifications: .denied, location: .authorizedAlways, motion: .denied), [])
    }

    func testARefusedLocationIsNotAskedAgain() {
        XCTAssertEqual(items(location: .denied), [.reminders, .motion])
    }

    func testAPilotWhoHasFlownWasAskedForAlwaysAtTheirFirstStart() {
        XCTAssertEqual(items(flown: true), [.reminders, .motion])
    }

    func testNoBarometerNoMotionLine() {
        XCTAssertEqual(items(barometer: false), [.reminders, .locationAlways])
    }

    func testThePageShowsOnceAndNeverInAFlightOrADryRun() {
        XCTAssertTrue(FirstFlightPermissions.showsPage(items: [.motion], alreadyShown: false, quiet: false))
        XCTAssertFalse(FirstFlightPermissions.showsPage(items: [.motion], alreadyShown: true, quiet: false))
        XCTAssertFalse(FirstFlightPermissions.showsPage(items: [.motion], alreadyShown: false, quiet: true))
        XCTAssertFalse(FirstFlightPermissions.showsPage(items: [], alreadyShown: false, quiet: false))
    }
}
