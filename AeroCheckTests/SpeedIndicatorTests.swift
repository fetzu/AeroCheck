import XCTest
@testable import AeroCheck

/// Tests for the shared speed-indicator target annunciation used by both the iPad
/// `SpeedIndicatorView` / `CockpitInstrumentStrip` and the iPhone `CompactSpeedView`.
///
/// There is deliberately no stall annunciation any more. It used to fire from a wind-derived
/// airspeed estimate; that estimate was ground speed corrected by a MeteoSwiss SURFACE station
/// wind, which cannot describe the air at altitude — bidirectionally wrong by up to ~18 kt against
/// a Vs→Vapp margin of 23 kt on the WT9. The estimate and the annunciation were both removed.
/// `testStallStateNoLongerExists` is the regression guard: it fails to compile, by design, if a
/// `.stall` case is reintroduced without a real airspeed source behind it.
final class SpeedIndicatorTests: XCTestCase {

    // MARK: - annunciationState

    func testOnTargetWithinFiveKnots() {
        let s = SpeedIndicatorView.annunciationState(
            displaySpeed: 56, targetSpeed: 55, gpsSignalStatus: .good)
        guard case .onTarget = s else { return XCTFail("within 5 kt of target must be on-target") }
    }

    func testOffTargetOutsideFiveKnots() {
        let s = SpeedIndicatorView.annunciationState(
            displaySpeed: 70, targetSpeed: 55, gpsSignalStatus: .good)
        guard case .offTarget = s else { return XCTFail("outside 5 kt of target must be off-target") }
    }

    /// A speed below Vs must NOT be treated as special: the displayed value is GPS ground speed, and
    /// a headwind can make a perfectly safe 55 KIAS final read 40 kt over the ground. This is the
    /// case that used to be a stall warning.
    func testLowGroundSpeedIsMerelyOffTarget() {
        let s = SpeedIndicatorView.annunciationState(
            displaySpeed: 40, targetSpeed: 55, gpsSignalStatus: .good)
        guard case .offTarget = s else { return XCTFail("low ground speed is off-target, not a stall") }
    }

    /// Degraded/lost GPS still annunciates against the target band — the failure flag communicates
    /// the GPS problem separately — but must never invent a state from an unreliable fix.
    func testDegradedGPSStillAnnunciatesAgainstTarget() {
        let onTarget = SpeedIndicatorView.annunciationState(
            displaySpeed: 55, targetSpeed: 55, gpsSignalStatus: .degraded)
        guard case .onTarget = onTarget else { return XCTFail("degraded GPS within band is on-target") }

        let offTarget = SpeedIndicatorView.annunciationState(
            displaySpeed: 20, targetSpeed: 55, gpsSignalStatus: .lost)
        guard case .offTarget = offTarget else { return XCTFail("lost GPS outside band is off-target") }
    }

    func testNonFiniteSpeedDoesNotTrap() {
        let s = SpeedIndicatorView.annunciationState(
            displaySpeed: .nan, targetSpeed: 55, gpsSignalStatus: .good)
        guard case .offTarget = s else { return XCTFail("NaN must degrade to off-target, not trap") }
    }

    /// Compile-time regression guard: `SpeedState` must remain exhaustive over exactly these two
    /// cases. If someone adds `.stall` back, this switch stops compiling and they have to read the
    /// comment at the top of this file first.
    func testStallStateNoLongerExists() {
        let states: [SpeedIndicatorView.SpeedState] = [.onTarget, .offTarget]
        for state in states {
            switch state {
            case .onTarget, .offTarget: continue
            }
        }
        XCTAssertEqual(states.count, 2)
    }

    // MARK: - accessibilityValue

    func testAccessibilityValueStatesGroundSpeedAndTarget() {
        let v = SpeedIndicatorView.accessibilityValue(
            displaySpeed: 55, targetSpeed: 55, state: .onTarget, gpsLost: false)
        XCTAssertEqual(v, "55 knots ground speed, on target. Target 55 knots")
    }

    /// State must be conveyed in WORDS, never colour alone (UX-10).
    func testAccessibilityValueConveysOffTargetInWords() {
        let v = SpeedIndicatorView.accessibilityValue(
            displaySpeed: 20, targetSpeed: 55, state: .offTarget, gpsLost: false)
        XCTAssertTrue(v.contains("off target"), "state must be spoken, not just coloured")
    }

    func testAccessibilityValueReportsGPSLoss() {
        let v = SpeedIndicatorView.accessibilityValue(
            displaySpeed: 0, targetSpeed: 55, state: .offTarget, gpsLost: true)
        XCTAssertEqual(v, "GPS signal lost")
    }

    /// The readout must never claim to be airspeed — the app has no pitot or AoA source.
    func testAccessibilityValueNeverClaimsAirspeed() {
        let v = SpeedIndicatorView.accessibilityValue(
            displaySpeed: 55, targetSpeed: 55, state: .onTarget, gpsLost: false)
        XCTAssertFalse(v.lowercased().contains("airspeed"))
        XCTAssertFalse(v.lowercased().contains("ias"))
    }
}
