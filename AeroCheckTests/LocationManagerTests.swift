import XCTest
import CoreLocation
@testable import AeroCheck

/// Tests for LocationManager's GPS signal-status policy — the logic behind the cockpit GPS
/// indicator. Pins the 10 / 20 / 45 s boundaries so the constants can't drift from intent (PR-35).
final class LocationManagerTests: XCTestCase {

    private func status(_ t: TimeInterval, accuracy: CLLocationAccuracy,
                        current: GPSSignalStatus = .good) -> GPSSignalStatus {
        LocationManager.signalStatus(timeSinceLastUpdate: t, lastKnownAccuracy: accuracy, current: current)
    }

    func testFreshGoodFixStaysGood() {
        XCTAssertEqual(status(2, accuracy: 10), .good)
        XCTAssertEqual(status(19, accuracy: 10), .good) // <20 s with a good last fix
    }

    func testGoodSignalDegradesAtTwentySeconds() {
        XCTAssertEqual(status(20, accuracy: 10, current: .good), .degraded)
        XCTAssertEqual(status(30, accuracy: 10, current: .good), .degraded)
    }

    func testTrulyLostAtFortyFiveSeconds() {
        XCTAssertEqual(status(45, accuracy: 10), .lost)  // a good last accuracy doesn't save it
        XCTAssertEqual(status(60, accuracy: -1), .lost)
    }

    func testPoorAccuracyDegradesAtTenSeconds() {
        XCTAssertEqual(status(5, accuracy: 200, current: .good), .good)     // <10 s: unchanged
        XCTAssertEqual(status(10, accuracy: 200, current: .good), .degraded)
        XCTAssertEqual(status(12, accuracy: -1, current: .good), .degraded) // negative accuracy = unknown/poor
    }

    func testEscalationsOnlyFireFromGood() {
        // A non-good status is preserved (not re-escalated) in the 10–45 s band.
        XCTAssertEqual(status(25, accuracy: 10, current: .degraded), .degraded)
        XCTAssertEqual(status(25, accuracy: 10, current: .lost), .lost)
    }

    func testThresholdBoundaries() {
        XCTAssertEqual(status(19.99, accuracy: 10, current: .good), .good)
        XCTAssertEqual(status(20.0, accuracy: 10, current: .good), .degraded)
        XCTAssertEqual(status(44.99, accuracy: 10, current: .good), .degraded)
        XCTAssertEqual(status(45.0, accuracy: 10, current: .good), .lost)
    }

    // MARK: - Companion shared GPS: borrowed-fix injection (v4.1)

    private func fix(lat: Double = 47, lon: Double = 8, accuracy: CLLocationAccuracy = 10,
                     ageSeconds: TimeInterval = 0) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                   altitude: 500, horizontalAccuracy: accuracy, verticalAccuracy: 10,
                   course: 90, speed: 30, timestamp: Date(timeIntervalSinceNow: -ageSeconds))
    }

    @MainActor
    func testBorrowedFixIsAdoptedWhenNoOwnFix() {
        let lm = LocationManager()
        XCTAssertFalse(lm.ownFixIsLive, "no own fix yet")
        lm.injectCompanionLocation(fix(lat: 46.5, lon: 6.6))
        XCTAssertEqual(lm.currentLocation?.coordinate.latitude ?? 0, 46.5, accuracy: 1e-6,
                       "a borrowed peer fix becomes the current location when the device has no own GPS")
    }

    @MainActor
    func testOwnFixWinsOverBorrowedFix() {
        let lm = LocationManager()
        lm.processLocation(fix(lat: 47.0, lon: 8.0), isOwnFix: true)
        XCTAssertTrue(lm.ownFixIsLive, "a real device fix marks own GPS live")
        lm.injectCompanionLocation(fix(lat: 46.5, lon: 6.6))
        XCTAssertEqual(lm.currentLocation?.coordinate.latitude ?? 0, 47.0, accuracy: 1e-6,
                       "a live own fix is preserved; the borrowed fix is ignored")
    }

    @MainActor
    func testBorrowingNeverMarksOwnGPSLive() {
        let lm = LocationManager()
        lm.injectCompanionLocation(fix())
        XCTAssertFalse(lm.ownFixIsLive,
                       "borrowing must not report own GPS as live — that would flap the master/viewer feed")
    }

    @MainActor
    func testCompanionInjectionIsInertDuringMarketingMode() {
        let lm = LocationManager()
        lm.overrideGPSStatus(.good)   // activates marketing mode
        lm.injectCompanionLocation(fix(lat: 45.0, lon: 7.0))
        XCTAssertNil(lm.currentLocation, "marketing mode is authoritative — companion injection is ignored")
    }
}
