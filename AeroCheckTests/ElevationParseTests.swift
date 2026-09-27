import CoreLocation
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

    // MARK: - What leaves the device (SEC-C39 / S9-13)

    /// The route (planning) and track paths both build their Open-Meteo request here, to about
    /// 100 m. The route path sent 4 decimals.
    func testOpenMeteoRequestCarriesThreeDecimalsOnly() throws {
        let url = try XCTUnwrap(ElevationService.openMeteoElevationURL(for: [
            CLLocationCoordinate2D(latitude: 46.912345678, longitude: 7.499876543),
            CLLocationCoordinate2D(latitude: -33.94651, longitude: 151.17739),
        ]))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

        XCTAssertEqual(url.host, "api.open-meteo.com")
        XCTAssertEqual(items.first { $0.name == "latitude" }?.value, "46.912,-33.947")
        XCTAssertEqual(items.first { $0.name == "longitude" }?.value, "7.500,151.177")
    }

    /// Every geometry sent to swisstopo, planned leg or recorded track, is in whole LV95 metres.
    /// The planned-leg path sent the unrounded conversion.
    func testSwisstopoGeometryIsInWholeMetres() {
        let geometry = ElevationService.lv95LineString([
            (easting: 2_600_072.37, northing: 1_200_147.07),
            (easting: 2_683_000.5, northing: 1_247_999.49),
        ])

        XCTAssertEqual(geometry, #"{"type":"LineString","coordinates":[[2600072,1200147],[2683001,1247999]]}"#)
    }

    func testWholeMetresRoundsToTheNearestMetre() {
        let point = ElevationService.wholeMetres((easting: 2_600_000.49, northing: 1_200_000.51))
        XCTAssertEqual(point.easting, 2_600_000)
        XCTAssertEqual(point.northing, 1_200_001)
    }
}
