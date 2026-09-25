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
}
