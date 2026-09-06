import XCTest
import SwiftUI
@testable import AeroCheck

/// Tests the VoiceOver value composition for the flight instruments. The wording must state the
/// value and state in words (never colour alone) and must never mis-state a safety reading. (UX-10)
final class InstrumentAccessibilityTests: XCTestCase {

    func testSpeedValueStatesValueAndStateInWords() {
        let value = SpeedIndicatorView.accessibilityValue(
            displaySpeed: 45, targetSpeed: 76, state: .offTarget, gpsLost: false)
        XCTAssertEqual(value, "45 knots ground speed, off target. Target 76 knots")
    }

    func testSpeedValueOnTarget() {
        let value = SpeedIndicatorView.accessibilityValue(
            displaySpeed: 74, targetSpeed: 76, state: .onTarget, gpsLost: false)
        XCTAssertTrue(value.contains("on target"))
    }

    /// The readout is GPS ground speed and must say so. It must never speak "airspeed": the app has
    /// no pitot or AoA source, and the wind-derived estimate that once justified that wording was
    /// removed along with the stall annunciation it drove.
    func testSpeedIsAlwaysSpokenAsGroundSpeed() {
        let value = SpeedIndicatorView.accessibilityValue(
            displaySpeed: 40, targetSpeed: 70, state: .offTarget, gpsLost: false)
        XCTAssertTrue(value.contains("ground speed"))
        XCTAssertFalse(value.lowercased().contains("airspeed"))
        XCTAssertFalse(value.lowercased().contains("approximately"))
        XCTAssertFalse(value.lowercased().contains("stall"))
    }

    func testGpsLostOverridesTheReading() {
        let value = SpeedIndicatorView.accessibilityValue(
            displaySpeed: 50, targetSpeed: 70, state: .onTarget, gpsLost: true)
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

    // MARK: - Cockpit theme engine (v4 UI/UX Revamp)

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

    // MARK: - Sunlight boost (v5.x)

    /// The boost is what makes the sunlight palette automatic. It reads screen brightness because iOS
    /// exposes no ambient light, and it may only ever brighten a DAY palette.
    func testSunlightBoostEscalatesOnlyABrightDayScreen() {
        var s = AppSettings()
        s.themePreference = .day

        // Off by default: brightness alone changes nothing.
        XCTAssertEqual(s.cockpitThemeMode(systemIsDark: false, screenBrightness: 1.0), .day)

        s.sunlightBoost = true
        XCTAssertEqual(s.cockpitThemeMode(systemIsDark: false, screenBrightness: 1.0), .sunlight)
        XCTAssertEqual(s.cockpitThemeMode(systemIsDark: false, screenBrightness: 0.5), .day)
        // Exactly at the threshold counts as bright.
        XCTAssertEqual(
            s.cockpitThemeMode(systemIsDark: false,
                               screenBrightness: AppSettings.sunlightBrightnessThreshold),
            .sunlight)

        // Night protects dark adaptation: a screen turned up must never blow it away.
        s.themePreference = .night
        XCTAssertEqual(s.cockpitThemeMode(systemIsDark: false, screenBrightness: 1.0), .night)

        // `.auto` on a dark device resolves to night first, so it is protected for the same reason.
        s.themePreference = .auto
        XCTAssertEqual(s.cockpitThemeMode(systemIsDark: true, screenBrightness: 1.0), .night)
        XCTAssertEqual(s.cockpitThemeMode(systemIsDark: false, screenBrightness: 1.0), .sunlight)
    }

    /// A save from before the split still holds `.sunlight`, which no picker offers any more. It has
    /// to become "day + boost on", or the picker shows nothing selected and the palette stays pinned.
    func testLegacySunlightPreferenceMigratesToDayPlusBoost() throws {
        let json = Data(#"{"themePreference":"sunlight"}"#.utf8)
        let migrated = try JSONDecoder().decode(AppSettings.self, from: json)

        XCTAssertEqual(migrated.themePreference, .day)
        XCTAssertTrue(migrated.sunlightBoost)
        XCTAssertEqual(migrated.cockpitThemeMode(systemIsDark: false, screenBrightness: 1.0), .sunlight)
        XCTAssertEqual(migrated.cockpitThemeMode(systemIsDark: false, screenBrightness: 0.3), .day)
    }

    /// Everyone else keeps the palette they had, with the boost off.
    func testNonSunlightSavesDoNotGainTheBoost() throws {
        let json = Data(#"{"themePreference":"night"}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)

        XCTAssertEqual(decoded.themePreference, .night)
        XCTAssertFalse(decoded.sunlightBoost)
    }

    func testInstrumentTargetStateBarColorMapsToTheme() {
        let day = CockpitTheme.day
        XCTAssertEqual(InstrumentTargetState.onTarget.barColor(in: day), day.onTarget)
        XCTAssertEqual(InstrumentTargetState.caution.barColor(in: day), day.warning)
        XCTAssertEqual(InstrumentTargetState.neutral.barColor(in: day), day.textDim)
        // Same states re-theme under night (red-shift).
        XCTAssertEqual(InstrumentTargetState.caution.barColor(in: CockpitTheme.night), CockpitTheme.night.warning)
    }

    // MARK: - On-target proximity bar (v4 UI/UX Revamp)

    func testBarStateMapsSpeedStateToColorBlindSafeState() {
        // The bar's state must never disagree with the readout's annunciated speed state.
        XCTAssertEqual(SpeedIndicatorView.barState(for: .onTarget), .onTarget)
        XCTAssertEqual(SpeedIndicatorView.barState(for: .offTarget), .caution)
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
