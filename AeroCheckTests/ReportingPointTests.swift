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

    func testParseSkipsFeatureMissingRequiredPropertyWithoutAbortingRest() throws {
        // A feature missing the REQUIRED `_id` must be skipped, not abort the whole FeatureCollection
        // decode. (v4.1.0 pre-tag fix — M1)
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","properties":{"_id":"ok1","name":"ALPHA"},"geometry":{"type":"Point","coordinates":[7.0,46.8]}},
          {"type":"Feature","properties":{"name":"NO ID"},"geometry":{"type":"Point","coordinates":[7.1,46.9]}},
          {"type":"Feature","properties":{"_id":"ok2","name":"BRAVO"},"geometry":{"type":"Point","coordinates":[6.1,46.4]}}
        ]}
        """.data(using: .utf8)!
        XCTAssertEqual(try ReportingPoint.parse(geoJSON: json).map(\.id), ["ok1", "ok2"])   // middle skipped, rest survive
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

    /// The 1° spatial grid added for the perf review (30-performance.md #9) must gather region-query
    /// candidates from every overlapping cell and still apply the exact range check — asserted against
    /// an independently reimplemented brute-force filter over a dataset straddling the (lat 45, lon 9)
    /// cell corner: one point per surrounding cell, a same-cell false positive outside the query range,
    /// and a far-away point in an untouched cell.
    @MainActor
    func testReportingPointsInRegionMatchesBruteForceAcrossGridBoundary() throws {
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","properties":{"_id":"P1"},"geometry":{"type":"Point","coordinates":[8.95,44.95]}},
          {"type":"Feature","properties":{"_id":"P2"},"geometry":{"type":"Point","coordinates":[8.95,45.05]}},
          {"type":"Feature","properties":{"_id":"P3"},"geometry":{"type":"Point","coordinates":[9.05,44.95]}},
          {"type":"Feature","properties":{"_id":"P4"},"geometry":{"type":"Point","coordinates":[9.05,45.05]}},
          {"type":"Feature","properties":{"_id":"P5"},"geometry":{"type":"Point","coordinates":[8.80,44.95]}},
          {"type":"Feature","properties":{"_id":"P6"},"geometry":{"type":"Point","coordinates":[10.0,10.0]}}
        ]}
        """.data(using: .utf8)!
        let all = try ReportingPoint.parse(geoJSON: json)

        let latRange = 44.9...45.1
        let lonRange = 8.9...9.1
        let bruteForce = all.filter { latRange.contains($0.latitude) && lonRange.contains($0.longitude) }

        let service = OpenAIPReportingPointDataService()
        service.seedForTesting(all)
        let gridResult = service.reportingPointsInRegion(latRange: latRange, lonRange: lonRange)

        XCTAssertEqual(Set(gridResult.map(\.id)), Set(bruteForce.map(\.id)))
        XCTAssertEqual(Set(gridResult.map(\.id)), ["P1", "P2", "P3", "P4"])
    }

    /// `reportingPointsNear`'s ring-widening grid walk must find the nearest point even when it sits in
    /// an adjacent grid cell to the query coordinate — a naive "only check the query's own cell"
    /// implementation would miss it and could return the wrong (same-cell but farther) point instead.
    @MainActor
    func testReportingPointsNearFindsNearestAcrossGridBoundary() throws {
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","properties":{"_id":"near","name":"NEAR"},"geometry":{"type":"Point","coordinates":[9.001,45.001]}},
          {"type":"Feature","properties":{"_id":"far","name":"FAR"},"geometry":{"type":"Point","coordinates":[8.5,44.5]}}
        ]}
        """.data(using: .utf8)!
        let all = try ReportingPoint.parse(geoJSON: json)

        let service = OpenAIPReportingPointDataService()
        service.seedForTesting(all)

        // Query coordinate sits just inside cell (44, 8); "near" sits just across the corner in the
        // diagonally adjacent cell (45, 9), about 0.15 NM away. "far" shares the query's own cell but is
        // ~35 NM away.
        let coord = CLLocationCoordinate2D(latitude: 44.999, longitude: 8.999)
        let nearest = service.reportingPointsNear(to: coord, maxDistanceNm: 50, limit: 1)

        XCTAssertEqual(nearest.map(\.id), ["near"])

        // Both must be found (equal to the brute-force filter+sort) when the limit allows it.
        let both = service.reportingPointsNear(to: coord, maxDistanceNm: 50, limit: 2)
        let bruteForce = all
            .compactMap { p -> (ReportingPoint, Double)? in
                let d = p.distanceNM(from: coord)
                return d <= 50 ? (p, d) : nil
            }
            .sorted { ($0.1, $0.0.compulsory ? 0 : 1) < ($1.1, $1.0.compulsory ? 0 : 1) }
            .map { $0.0.id }
        XCTAssertEqual(both.map(\.id), bruteForce)
    }
}
