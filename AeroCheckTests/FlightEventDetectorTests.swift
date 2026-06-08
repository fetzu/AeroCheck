import XCTest
@testable import AeroCheck

/// Tests that flight-event detection thresholds scale with the GPS recording interval
/// rather than assuming the legacy 5 s cadence (PERF-05).
@MainActor
final class FlightEventDetectorTests: XCTestCase {

    func testThresholdsAtDefaultIntervalMatchLegacyConstants() {
        let detector = FlightEventDetector()
        detector.configure(speeds: [], stallSpeed: 50, recordingInterval: 5)
        // 40 s full-stop dwell, 15 s touchdown/smoothing at a 5 s cadence → 8 / 3 / 3.
        XCTAssertEqual(detector.requiredTaxiSpeedReadings, 8)
        XCTAssertEqual(detector.minTouchdownReadings, 3)
        XCTAssertEqual(detector.speedSmoothingReadings, 3)
    }

    func testThresholdsScaleUpAtFastInterval() {
        let detector = FlightEventDetector()
        detector.configure(speeds: [], stallSpeed: 50, recordingInterval: 1)
        // At 1 s, a full stop needs ~40 readings (not 8) so it isn't declared after ~8 s.
        XCTAssertEqual(detector.requiredTaxiSpeedReadings, 40)
        XCTAssertEqual(detector.minTouchdownReadings, 15)
        XCTAssertEqual(detector.speedSmoothingReadings, 15)
    }

    func testThresholdsClampAtSlowInterval() {
        let detector = FlightEventDetector()
        detector.configure(speeds: [], stallSpeed: 50, recordingInterval: 30)
        // ceil(40/30)=2, ceil(15/30)=1 clamped to the minimum of 2 (a single noisy sample
        // must never trigger a transition).
        XCTAssertEqual(detector.requiredTaxiSpeedReadings, 2)
        XCTAssertEqual(detector.minTouchdownReadings, 2)
        XCTAssertGreaterThanOrEqual(detector.speedSmoothingReadings, 2)
    }

    func testInvalidIntervalFallsBackToDefault() {
        let detector = FlightEventDetector()
        detector.configure(speeds: [], stallSpeed: 50, recordingInterval: 0)
        // A non-positive interval is treated as the 5 s default.
        XCTAssertEqual(detector.requiredTaxiSpeedReadings, 8)
    }
}
