import XCTest
@testable import AeroCheck

/// Tests the VoiceOver value composition for the flight instruments. The wording must state the
/// value and state in words (never colour alone) and must never mis-state a safety reading. (UX-10)
final class InstrumentAccessibilityTests: XCTestCase {

    func testSpeedValueStatesValueAndStateInWords() {
        let value = SpeedIndicatorView.accessibilityValue(
            displaySpeed: 45, targetSpeed: 76, state: .offTarget, estimated: false, gpsLost: false)
        XCTAssertEqual(value, "45 knots ground speed, off target. Target 76 knots")
    }

    func testSpeedValueOnTarget() {
        let value = SpeedIndicatorView.accessibilityValue(
            displaySpeed: 74, targetSpeed: 76, state: .onTarget, estimated: false, gpsLost: false)
        XCTAssertTrue(value.contains("on target"))
    }

    func testStallIsSpokenAsBelowStallSpeedAndEstimatedAsApproximate() {
        let value = SpeedIndicatorView.accessibilityValue(
            displaySpeed: 40, targetSpeed: 70, state: .stall, estimated: true, gpsLost: false)
        XCTAssertTrue(value.contains("below stall speed"))
        XCTAssertTrue(value.contains("approximately"), "An estimated value is spoken as approximate")
        XCTAssertTrue(value.contains("estimated airspeed"))
    }

    func testGpsLostOverridesTheReading() {
        let value = SpeedIndicatorView.accessibilityValue(
            displaySpeed: 50, targetSpeed: 70, state: .onTarget, estimated: false, gpsLost: true)
        XCTAssertEqual(value, "GPS signal lost", "A lost signal must not read a stale on-target speed")
    }

    func testAltitudeValue() {
        XCTAssertEqual(AltimeterView.accessibilityValue(altitudeFeet: 3500, gpsLost: false), "3500 feet M S L")
        XCTAssertEqual(AltimeterView.accessibilityValue(altitudeFeet: 3500, gpsLost: true), "GPS signal lost")
    }

    func testStatusAccessibilityText() {
        XCTAssertEqual(StatusIndicator.Status.active.accessibilityText, "active")
        XCTAssertEqual(StatusIndicator.Status.inactive.accessibilityText, "inactive")
        XCTAssertEqual(StatusIndicator.Status.warning.accessibilityText, "warning")
        XCTAssertEqual(StatusIndicator.Status.error.accessibilityText, "error")
    }
}
