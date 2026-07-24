import XCTest
import CoreLocation
@testable import AeroCheck

/// Unit tests for the v4.1.0 obstacle layer: parsing OpenAIP's keyless GeoJSON export into `[Obstacle]`
/// (integer type codes, a top-elevation MSL measure, an optional AGL height) + the region query used
/// for the nav-map markers.
final class ObstacleTests: XCTestCase {

    private let sampleGeoJSON = """
    { "type": "FeatureCollection", "features": [
      { "type": "Feature",
        "properties": { "_id": "obs1", "country": "CH", "name": "Feldmoos", "type": 0,
          "elevation": { "value": 1021, "unit": 0, "referenceDatum": 1 },
          "height": { "value": 150, "unit": 0 } },
        "geometry": { "type": "Point", "coordinates": [8.0866938, 46.9900026] } },
      { "type": "Feature",
        "properties": { "_id": "obs2", "country": "CH", "type": 2 },
        "geometry": { "type": "Point", "coordinates": [7.0, 46.5] } }
    ] }
    """.data(using: .utf8)!

    func testParseObstacleGeoJSON() throws {
        let obstacles = try Obstacle.parse(geoJSON: sampleGeoJSON)
        XCTAssertEqual(obstacles.count, 2)
        let feld = obstacles[0]
        XCTAssertEqual(feld.id, "obs1")
        XCTAssertEqual(feld.name, "Feldmoos")
        XCTAssertEqual(feld.typeRaw, 0)
        XCTAssertEqual(feld.elevationFeetMSL, Int((1021.0 * 3.28084).rounded()))   // meters → feet
        XCTAssertEqual(feld.heightFeetAGL, Int((150.0 * 3.28084).rounded()))
        XCTAssertEqual(feld.latitude, 46.9900026, accuracy: 0.00001)
        XCTAssertEqual(feld.longitude, 8.0866938, accuracy: 0.00001)   // [lon, lat] order honoured
    }

    func testParseHandlesMissingOptionals() throws {
        let obs = try Obstacle.parse(geoJSON: sampleGeoJSON)[1]
        XCTAssertNil(obs.name)
        XCTAssertNil(obs.elevationFeetMSL)
        XCTAssertNil(obs.heightFeetAGL)
        XCTAssertEqual(obs.typeRaw, 2)
    }

    func testParseSkipsMalformedGeometry() throws {
        let json = """
        {"type":"FeatureCollection","features":[{"type":"Feature",
          "properties":{"_id":"z","type":0},
          "geometry":{"type":"Point","coordinates":[7]}}]}
        """.data(using: .utf8)!
        XCTAssertTrue(try Obstacle.parse(geoJSON: json).isEmpty)   // single coordinate → skipped, not fatal
    }

    func testParseSkipsFeatureMissingRequiredPropertyWithoutAbortingRest() throws {
        // A feature missing a REQUIRED property (here `_id`) must be skipped, not abort the whole
        // FeatureCollection decode. (v4.1.0 pre-tag fix — M1)
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","properties":{"_id":"ok1","type":0},"geometry":{"type":"Point","coordinates":[7.0,46.8]}},
          {"type":"Feature","properties":{"type":0},"geometry":{"type":"Point","coordinates":[7.1,46.9]}},
          {"type":"Feature","properties":{"_id":"ok2","type":2},"geometry":{"type":"Point","coordinates":[6.1,46.4]}}
        ]}
        """.data(using: .utf8)!
        XCTAssertEqual(try Obstacle.parse(geoJSON: json).map(\.id), ["ok1", "ok2"])   // middle skipped, rest survive
    }

    @MainActor
    func testObstaclesInRegion() throws {
        let service = OpenAIPObstacleDataService()
        service.seedForTesting(try Obstacle.parse(geoJSON: sampleGeoJSON))

        let inBox = service.obstaclesInRegion(latRange: 46.9...47.0, lonRange: 8.0...8.1)
        XCTAssertEqual(inBox.count, 1)
        XCTAssertEqual(inBox.first?.id, "obs1")

        let empty = service.obstaclesInRegion(latRange: 0...1, lonRange: 0...1)
        XCTAssertTrue(empty.isEmpty)
    }

    /// The 1° spatial grid added for the perf review (30-performance.md #7) must gather candidates from
    /// every cell the query bounds overlap and still apply the exact range check — asserted against an
    /// independently reimplemented brute-force filter over a dataset that straddles the (lat 45, lon 9)
    /// cell corner: one obstacle per surrounding cell, a same-cell false positive outside the query
    /// range, and a far-away obstacle in an untouched cell.
    @MainActor
    func testObstaclesInRegionMatchesBruteForceAcrossGridBoundary() throws {
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","properties":{"_id":"P1","type":0},"geometry":{"type":"Point","coordinates":[8.95,44.95]}},
          {"type":"Feature","properties":{"_id":"P2","type":0},"geometry":{"type":"Point","coordinates":[8.95,45.05]}},
          {"type":"Feature","properties":{"_id":"P3","type":0},"geometry":{"type":"Point","coordinates":[9.05,44.95]}},
          {"type":"Feature","properties":{"_id":"P4","type":0},"geometry":{"type":"Point","coordinates":[9.05,45.05]}},
          {"type":"Feature","properties":{"_id":"P5","type":0},"geometry":{"type":"Point","coordinates":[8.80,44.95]}},
          {"type":"Feature","properties":{"_id":"P6","type":0},"geometry":{"type":"Point","coordinates":[10.0,10.0]}}
        ]}
        """.data(using: .utf8)!
        let all = try Obstacle.parse(geoJSON: json)

        let latRange = 44.9...45.1
        let lonRange = 8.9...9.1
        let bruteForce = all.filter { latRange.contains($0.latitude) && lonRange.contains($0.longitude) }

        let service = OpenAIPObstacleDataService()
        service.seedForTesting(all)
        let gridResult = service.obstaclesInRegion(latRange: latRange, lonRange: lonRange)

        XCTAssertEqual(Set(gridResult.map(\.id)), Set(bruteForce.map(\.id)))
        XCTAssertEqual(Set(gridResult.map(\.id)), ["P1", "P2", "P3", "P4"])
    }
}
