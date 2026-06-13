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
}
