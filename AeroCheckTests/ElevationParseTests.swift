import XCTest
@testable import AeroCheck

/// Guards the safety property that a failed or malformed Open-Meteo elevation response yields nil
/// (never a zero-filled flat band, which would falsely imply huge ground clearance under the
/// altitude trace). (PERF-15 / SEC-14)
final class ElevationParseTests: XCTestCase {

    func testParsesValidElevations() {
        let data = Data(#"{"elevation":[412.0,500.5,1203.0]}"#.utf8)
        XCTAssertEqual(
            ElevationService.parseOpenMeteoElevations(data, expectedCount: 3),
            [412.0, 500.5, 1203.0]
        )
    }

    func testRejectsCountMismatchInsteadOfPadding() {
        let data = Data(#"{"elevation":[412.0,500.5]}"#.utf8)
        XCTAssertNil(
            ElevationService.parseOpenMeteoElevations(data, expectedCount: 3),
            "A short response must be rejected, never padded with zeros"
        )
    }

    func testRejectsMissingElevationField() {
        let data = Data(#"{"latitude":[47.0]}"#.utf8)
        XCTAssertNil(ElevationService.parseOpenMeteoElevations(data, expectedCount: 1))
    }

    func testRejectsMalformedOrEmptyJSON() {
        XCTAssertNil(ElevationService.parseOpenMeteoElevations(Data("not json".utf8), expectedCount: 1))
        XCTAssertNil(ElevationService.parseOpenMeteoElevations(Data(), expectedCount: 1))
    }

    func testRejectsNonNumericElevations() {
        let data = Data(#"{"elevation":["high","low"]}"#.utf8)
        XCTAssertNil(ElevationService.parseOpenMeteoElevations(data, expectedCount: 2))
    }
}
