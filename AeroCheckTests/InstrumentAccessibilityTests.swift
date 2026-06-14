import XCTest
import SwiftUI
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

    // MARK: - Cockpit theme engine (Phase 3.0)

    func testCockpitThemeResolvesEachMode() {
        XCTAssertEqual(CockpitTheme.resolve(.day).mode, .day)
        XCTAssertEqual(CockpitTheme.resolve(.sunlight).mode, .sunlight)
        XCTAssertEqual(CockpitTheme.resolve(.night).mode, .night)
    }

    func testCockpitThemePalettesAreDistinct() {
        XCTAssertNotEqual(CockpitTheme.day, CockpitTheme.night)
        XCTAssertNotEqual(CockpitTheme.day, CockpitTheme.sunlight)
        XCTAssertNotEqual(CockpitTheme.night, CockpitTheme.sunlight)
        // Day keeps the existing tokens (current look unchanged); night reuses the red-shift
        // night-mode state colors (dim-amber/dark-red, no bright emitters).
        XCTAssertEqual(CockpitTheme.day.action, .aviationGold)
        XCTAssertEqual(CockpitTheme.night.onTarget, .nightOnTarget)
        XCTAssertEqual(CockpitTheme.night.danger, .nightStall)
    }

    func testThemePreferenceResolvesEffectiveModeAndTheme() {
        var s = AppSettings()
        s.themePreference = .night
        XCTAssertTrue(s.effectiveNightMode(systemIsDark: false))
        XCTAssertEqual(s.cockpitThemeMode(systemIsDark: false), .night)

        s.themePreference = .day
        XCTAssertFalse(s.effectiveNightMode(systemIsDark: true))
        XCTAssertEqual(s.cockpitThemeMode(systemIsDark: true), .day)

        // .sunlight is a forced bright palette and is NOT night, regardless of the device flag.
        s.themePreference = .sunlight
        XCTAssertFalse(s.effectiveNightMode(systemIsDark: true))
        XCTAssertEqual(s.cockpitThemeMode(systemIsDark: true), .sunlight)
        XCTAssertEqual(s.cockpitThemeMode(systemIsDark: false), .sunlight)

        // .auto follows the device dark-mode flag (dark → night, light → day).
        s.themePreference = .auto
        XCTAssertTrue(s.effectiveNightMode(systemIsDark: true))
        XCTAssertFalse(s.effectiveNightMode(systemIsDark: false))
        XCTAssertEqual(s.cockpitThemeMode(systemIsDark: true), .night)
        XCTAssertEqual(s.cockpitThemeMode(systemIsDark: false), .day)
    }

    func testInstrumentTargetStateBarColorMapsToTheme() {
        let day = CockpitTheme.day
        XCTAssertEqual(InstrumentTargetState.onTarget.barColor(in: day), day.onTarget)
        XCTAssertEqual(InstrumentTargetState.caution.barColor(in: day), day.warning)
        XCTAssertEqual(InstrumentTargetState.stall.barColor(in: day), day.danger)
        XCTAssertEqual(InstrumentTargetState.neutral.barColor(in: day), day.textDim)
        // Same states re-theme under night (red-shift).
        XCTAssertEqual(InstrumentTargetState.stall.barColor(in: .night), CockpitTheme.night.danger)
    }

    // MARK: - On-target proximity bar (Phase 3.1)

    func testBarStateMapsSpeedStateToColorBlindSafeState() {
        // The bar's state must never disagree with the readout's annunciated speed state.
        XCTAssertEqual(SpeedIndicatorView.barState(for: .onTarget), .onTarget)
        XCTAssertEqual(SpeedIndicatorView.barState(for: .offTarget), .caution)
        XCTAssertEqual(SpeedIndicatorView.barState(for: .stall), .stall)
    }

    func testTargetBarFractionIsFullAtTargetAndShrinksWithDeviation() {
        // On target → full bar.
        XCTAssertEqual(SpeedIndicatorView.targetBarFraction(displaySpeed: 76, targetSpeed: 76), 1.0, accuracy: 0.0001)
        // 15 kt off → half (30 kt full-scale).
        XCTAssertEqual(SpeedIndicatorView.targetBarFraction(displaySpeed: 61, targetSpeed: 76), 0.5, accuracy: 0.0001)
        // Symmetric above/below target.
        XCTAssertEqual(SpeedIndicatorView.targetBarFraction(displaySpeed: 86, targetSpeed: 76),
                       SpeedIndicatorView.targetBarFraction(displaySpeed: 66, targetSpeed: 76), accuracy: 0.0001)
    }

    func testTargetBarFractionIsFlooredSoTheBarNeverVanishes() {
        // Far off-target floors at 0.12 (a thin nub still reads "far off" via color), never 0.
        XCTAssertEqual(SpeedIndicatorView.targetBarFraction(displaySpeed: 0, targetSpeed: 76), 0.12, accuracy: 0.0001)
        XCTAssertGreaterThan(SpeedIndicatorView.targetBarFraction(displaySpeed: 200, targetSpeed: 76), 0.0)
    }
}
