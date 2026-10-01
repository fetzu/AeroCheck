import XCTest
import SwiftUI
@testable import AeroCheck

/// B612, the app's typeface since 6.0: the bundled fonts register, and SwiftUI's weights map onto the
/// family's two. A font name that fails to resolve falls back to the system font without a word, so
/// this is the only place a broken bundle or a renamed file would show.
final class TypographyTests: XCTestCase {

    func testEveryBundledFaceRegisters() {
        for name in [AeroTypeface.regular, AeroTypeface.bold, AeroTypeface.monoRegular, AeroTypeface.monoBold] {
            XCTAssertNotNil(UIFont(name: name, size: 12), "\(name) is not registered (UIAppFonts / bundle)")
        }
    }

    func testWeightsMapOntoRegularAndBold() {
        for weight in [Font.Weight.ultraLight, .thin, .light, .regular, .medium] {
            XCTAssertFalse(AeroTypeface.isBold(weight))
        }
        for weight in [Font.Weight.semibold, .bold, .heavy, .black] {
            XCTAssertTrue(AeroTypeface.isBold(weight))
        }
        XCTAssertFalse(AeroTypeface.isBold(nil))
    }

    func testMonospacedMapsToB612Mono() {
        XCTAssertEqual(AeroTypeface.name(bold: false, monospaced: true), "B612Mono-Regular")
        XCTAssertEqual(AeroTypeface.name(bold: true, monospaced: true), "B612Mono-Bold")
        XCTAssertEqual(AeroTypeface.name(bold: true, monospaced: false), "B612-Bold")
    }

    func testUIKitFontsAreB612() {
        XCTAssertEqual(UIFont.aero(size: 14).fontName, "B612-Regular")
        XCTAssertEqual(UIFont.aero(size: 14, weight: .semibold).fontName, "B612-Bold")
        XCTAssertEqual(UIFont.aero(size: 14, monospaced: true).fontName, "B612Mono-Regular")
    }

    // MARK: - B612 Mono punctuation (6.1)

    /// What numbers are written with: time and frequency separators, decimals, the Swiss grouping
    /// mark (iOS writes "1'860" with the plain apostrophe; the typographic ’ too), and the middle dot
    /// between two values.
    private let monoPunctuation: [Character] = [":", ";", ".", ",", "'", "·", "’"]

    /// Upstream B612 Mono draws its punctuation at the left of the cell, 27 % of the advance off
    /// centre ("00: 44", "122. 050"); the bundled files are patched to centre it
    /// (`scripts/center-b612-mono-punctuation.py`). Read with CoreText's own glyph bounds, so an
    /// unpatched font coming back in an update fails here rather than in a pilot's Cockpit.
    func testMonoPunctuationIsCentredInItsCell() throws {
        for name in [AeroTypeface.monoRegular, AeroTypeface.monoBold] {
            let font = try XCTUnwrap(UIFont(name: name, size: 100)) as CTFont
            for character in monoPunctuation {
                let (advance, ink) = metrics(of: character, in: font)
                let offset = ink.midX - advance / 2
                XCTAssertLessThan(abs(offset), advance * 0.02,
                                  "\(name) '\(character)': ink centred \(offset) pt off its \(advance) pt cell")
            }
        }
    }

    /// The patch moves ink, never the advance: punctuation and digits keep one width, so a number
    /// that changes ("9:59" to "10:00", "122.050") keeps its columns and never jitters.
    func testMonoPunctuationKeepsTheDigitWidth() throws {
        for name in [AeroTypeface.monoRegular, AeroTypeface.monoBold] {
            let font = try XCTUnwrap(UIFont(name: name, size: 100)) as CTFont
            let digitAdvance = metrics(of: "0", in: font).advance
            for character in monoPunctuation + Array("123456789") {
                XCTAssertEqual(metrics(of: character, in: font).advance, digitAdvance, accuracy: 0.001,
                               "\(name) '\(character)' is not as wide as a digit")
            }
        }
    }

    /// The advance and the ink bounds of one character's glyph, in points.
    private func metrics(of character: Character, in font: CTFont) -> (advance: CGFloat, ink: CGRect) {
        let units = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count),
                      "\(CTFontCopyPostScriptName(font)) has no glyph for '\(character)'")
        var ink = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, &ink, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advance, 1)
        XCTAssertFalse(ink.isEmpty, "'\(character)' has no ink")
        return (advance.width, ink)
    }
}
