import XCTest
import CoreLocation
@testable import AeroCheck

/// Unit tests for the v4.1.0 VFR reporting-point layer: parsing OpenAIP's keyless GeoJSON export into
/// `[ReportingPoint]` (a `compulsory` flag, an elevation measure, remarks; tolerant of missing optionals)
/// + the region query used for the nav-map markers.
final class ReportingPointTests: XCTestCase {

    private let sampleGeoJSON = """
    { "type": "FeatureCollection", "features": [
      { "type": "Feature",
        "properties": { "_id": "rp1", "name": "SIERRA", "compulsory": true, "country": "CH",
          "airports": ["abc"], "elevation": { "value": 727, "unit": 0, "referenceDatum": 1 },
          "remarks": "Les Eplatures VRP - S {SLESE}" },
        "geometry": { "type": "Point", "coordinates": [6.706, 46.956] } },
      { "type": "Feature",
        "properties": { "_id": "rp2", "name": "WHISKEY", "country": "CH" },
        "geometry": { "type": "Point", "coordinates": [7.0, 46.5] } }
    ] }
    """.data(using: .utf8)!

    func testParseReportingPointGeoJSON() throws {
        let points = try ReportingPoint.parse(geoJSON: sampleGeoJSON)
        XCTAssertEqual(points.count, 2)
        let s = points[0]
        XCTAssertEqual(s.id, "rp1")
        XCTAssertEqual(s.name, "SIERRA")
        XCTAssertTrue(s.compulsory)
        XCTAssertEqual(s.remarks, "Les Eplatures VRP - S {SLESE}")
        XCTAssertEqual(s.elevationFeetMSL, Int((727.0 * 3.28084).rounded()))   // meters → feet
        XCTAssertEqual(s.latitude, 46.956, accuracy: 0.00001)
        XCTAssertEqual(s.longitude, 6.706, accuracy: 0.00001)   // [lon, lat] order honoured
    }

    func testParseDefaultsCompulsoryFalseAndOptionals() throws {
        let w = try ReportingPoint.parse(geoJSON: sampleGeoJSON)[1]
        XCTAssertFalse(w.compulsory)        // absent → false
        XCTAssertNil(w.elevationFeetMSL)
        XCTAssertNil(w.remarks)
    }

    func testParseSkipsMalformedGeometry() throws {
        let json = """
        {"type":"FeatureCollection","features":[{"type":"Feature",
          "properties":{"_id":"z","name":"X"},
          "geometry":{"type":"Point","coordinates":[7]}}]}
        """.data(using: .utf8)!
        XCTAssertTrue(try ReportingPoint.parse(geoJSON: json).isEmpty)   // single coordinate → skipped
    }

    @MainActor
    func testReportingPointsInRegion() throws {
        let service = OpenAIPReportingPointDataService()
        service.seedForTesting(try ReportingPoint.parse(geoJSON: sampleGeoJSON))

        let inBox = service.reportingPointsInRegion(latRange: 46.9...47.0, lonRange: 6.7...6.8)
        XCTAssertEqual(inBox.count, 1)
        XCTAssertEqual(inBox.first?.id, "rp1")

        XCTAssertTrue(service.reportingPointsInRegion(latRange: 0...1, lonRange: 0...1).isEmpty)
    }
}
