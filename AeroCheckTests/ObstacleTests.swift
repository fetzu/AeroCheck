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
}
