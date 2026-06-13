import XCTest
@testable import AeroCheck

/// Tests for the shared speed-indicator stall/target annunciation logic used by both the iPad
/// `SpeedIndicatorView` and the iPhone `CompactSpeedView`.
final class SpeedIndicatorTests: XCTestCase {

    // MARK: - annunciationState — stall only from a reliable airspeed estimate (UX-02)

    func testStallSuppressedOnRawGroundSpeed() {
        // 40 kt ground speed below Vs 42, but no airspeed estimate → must NOT annunciate stall
        // (a headwind can make a safe 55 KIAS final read 40 kt over the ground).
        let s = SpeedIndicatorView.annunciationState(
            displaySpeed: 40, targetSpeed: 55, stallSpeed: 42,
            showingEstimatedAirspeed: false, gpsSignalStatus: .good)
        if case .stall = s { XCTFail("ground speed below stall must not annunciate STALL") }
    }

    func testStallAnnunciatedFromEstimatedAirspeed() {
        let s = SpeedIndicatorView.annunciationState(
            displaySpeed: 40, targetSpeed: 55, stallSpeed: 42,
            showingEstimatedAirspeed: true, gpsSignalStatus: .good)
        guard case .stall = s else { return XCTFail("estimated airspeed below stall must annunciate STALL") }
    }

    func testStallNeverAnnunciatedOnUnreliableGPS() {
        // Even with an estimate, an unreliable GPS fix must not drive a stall warning — the
        // instrument failure flag already communicates the GPS problem.
        let s = SpeedIndicatorView.annunciationState(
            displaySpeed: 20, targetSpeed: 55, stallSpeed: 42,
            showingEstimatedAirspeed: true, gpsSignalStatus: .lost)
        if case .stall = s { XCTFail("unreliable GPS must not annunciate STALL") }
    }

    func testOnTargetWithinFiveKnots() {
        let s = SpeedIndicatorView.annunciationState(
            displaySpeed: 56, targetSpeed: 55, stallSpeed: 42,
            showingEstimatedAirspeed: false, gpsSignalStatus: .good)
        guard case .onTarget = s else { return XCTFail("within 5 kt of target must be on-target") }
    }
}
