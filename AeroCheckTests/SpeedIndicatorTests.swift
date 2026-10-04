import XCTest
import SwiftUI
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

/// The strip holds still: no live value changes its size. The vertical speed appearing at ±50 fpm
/// grew it by a line, and everything under it (the tabs, the map) moved down and back up in flight.
/// (6.1.0, seen in the ground replays)
@MainActor
final class InstrumentStripLayoutTests: XCTestCase {

    private func size(kneeboard: Bool, gps: GPSSignalStatus = .good, verticalSpeed: Double? = nil,
                      target: Int? = 70, next: String? = "LSGC") -> CGSize {
        let strip = CockpitInstrumentStrip(speedKnots: 104, targetSpeed: target, gpsSignalStatus: gps,
                                           altitudeFeet: 3_499, headingDegrees: 211,
                                           verticalSpeedFPM: verticalSpeed, kneeboard: kneeboard,
                                           next: next.map { NextFigures(ident: $0) })
        return UIHostingController(rootView: strip).sizeThatFits(in: CGSize(width: 800, height: 1_000))
    }

    func testTheVerticalSpeedNeverChangesTheStripsSize() {
        for kneeboard in [true, false] {
            let level = size(kneeboard: kneeboard, verticalSpeed: 0)
            for vs: Double? in [nil, 30, -49, 50, 480, -300, 1_850] {
                XCTAssertEqual(size(kneeboard: kneeboard, verticalSpeed: vs), level,
                               "kneeboard \(kneeboard), \(String(describing: vs)) fpm")
            }
        }
    }

    func testATargetSpeedComingOrGoingDoesNotResizeIt() {
        for kneeboard in [true, false] {
            XCTAssertEqual(size(kneeboard: kneeboard, target: nil), size(kneeboard: kneeboard, target: 70),
                           "a phase without a target speed, kneeboard \(kneeboard)")
        }
    }

    /// The red pixels of the lost-GPS flags, as rows, in each of the first two cells (GS, ALT).
    @MainActor
    private func flagRows(width: CGFloat) -> [ClosedRange<Int>] {
        let strip = CockpitInstrumentStrip(speedKnots: 0, targetSpeed: nil, gpsSignalStatus: .lost,
                                           altitudeFeet: 4_060, headingDegrees: nil, verticalSpeedFPM: nil,
                                           kneeboard: true, next: nil)
            .frame(width: width)
        let renderer = ImageRenderer(content: strip)
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return [] }
        let perRow = image.bytesPerRow, perPixel = image.bitsPerPixel / 8
        let isBGR = image.bitmapInfo.contains(.byteOrder32Little)
        return [0, 1].compactMap { cell in
            let columns = (Int(width) * cell / 3 + 8)..<(Int(width) * (cell + 1) / 3 - 8)
            var rows: [Int] = []
            for y in 0..<image.height {
                let isRed = columns.contains { x in
                    let p = bytes + y * perRow + x * perPixel
                    let (r, g, b) = isBGR ? (p[2], p[1], p[0]) : (p[0], p[1], p[2])
                    return r > 150 && g < 90 && b < 90
                }
                if isRed { rows.append(y) }
            }
            guard let top = rows.first, let bottom = rows.last else { return nil }
            return top...bottom
        }
    }

    /// The GS and ALT flags at the same height: centred on the whole cell, ALT's sat lower, under the
    /// line its cell keeps for the vertical speed. (6.1.0 device check)
    @MainActor
    func testTheGPSFlagsLineUp() {
        let rows = flagRows(width: 660)
        XCTAssertEqual(rows.count, 2, "a red flag over GS and over ALT")
        guard rows.count == 2 else { return }
        XCTAssertEqual(rows[0], rows[1], "GS flag rows \(rows[0]), ALT flag rows \(rows[1])")
    }

    func testTheGPSFailureFlagDoesNotResizeIt() {
        for kneeboard in [true, false] {
            let good = size(kneeboard: kneeboard, verticalSpeed: 480)
            XCTAssertEqual(size(kneeboard: kneeboard, gps: .degraded, verticalSpeed: 480), good)
            XCTAssertEqual(size(kneeboard: kneeboard, gps: .lost, verticalSpeed: 480), good,
                           "the values keep their room under the flag, kneeboard \(kneeboard)")
        }
    }
}
