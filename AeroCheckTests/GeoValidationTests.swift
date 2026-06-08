import XCTest
@testable import AeroCheck

/// Tests for the import coordinate-validation helpers (SEC-08).
/// Part of the minimal Phase 2 app test foundation.
final class GeoValidationTests: XCTestCase {

    func testValidCoordinatesAccepted() {
        XCTAssertTrue(GeoValidation.isValidLatLon(47.0, 8.0))
        XCTAssertTrue(GeoValidation.isValidLatLon(-90.0, -180.0))
        XCTAssertTrue(GeoValidation.isValidLatLon(90.0, 180.0))
    }

    func testNonFiniteRejected() {
        XCTAssertFalse(GeoValidation.isValidLatLon(.nan, 8.0))
        XCTAssertFalse(GeoValidation.isValidLatLon(47.0, .infinity))
        XCTAssertFalse(GeoValidation.isValidLatLon(.infinity, .nan))
    }

    func testOutOfRangeRejected() {
        XCTAssertFalse(GeoValidation.isValidLatLon(90.1, 8.0))
        XCTAssertFalse(GeoValidation.isValidLatLon(-90.1, 8.0))
        XCTAssertFalse(GeoValidation.isValidLatLon(47.0, 180.1))
        XCTAssertFalse(GeoValidation.isValidLatLon(47.0, -180.1))
    }

    func testValidLatitudeHelper() {
        XCTAssertEqual(GeoValidation.validLatitude(47.0), 47.0)
        XCTAssertNil(GeoValidation.validLatitude(.nan))
        XCTAssertNil(GeoValidation.validLatitude(91.0))
        XCTAssertNil(GeoValidation.validLatitude(nil))
    }

    func testValidLongitudeHelper() {
        XCTAssertEqual(GeoValidation.validLongitude(8.0), 8.0)
        XCTAssertNil(GeoValidation.validLongitude(.infinity))
        XCTAssertNil(GeoValidation.validLongitude(181.0))
    }

    func testFiniteHelper() {
        XCTAssertEqual(GeoValidation.finite(123.0), 123.0)
        XCTAssertNil(GeoValidation.finite(.nan))
        XCTAssertNil(GeoValidation.finite(.infinity))
        XCTAssertNil(GeoValidation.finite(nil))
    }
}
