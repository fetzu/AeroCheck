import XCTest
import CoreLocation
@testable import AeroCheck

/// Unit tests for the v4.1.0 navaid layer: parsing OpenAIP's keyless GeoJSON export into `[Navaid]`
/// (the schema has String frequencies, fractional declinations, and integer type codes) + the
/// nearest-navaid query used by the builder snap and the declination fix.
final class NavaidTests: XCTestCase {

    private let sampleGeoJSON = """
    { "type": "FeatureCollection", "features": [
      { "type": "Feature",
        "properties": { "_id": "62616c96abdcc7f0ccbbe519", "name": "CORVATSCH", "identifier": "CVA",
          "type": 0, "channel": "57Y", "frequency": { "value": "112.050", "unit": 2 },
          "elevation": { "value": 3279, "unit": 0, "referenceDatum": 1 }, "magneticDeclination": 4 },
        "geometry": { "type": "Point", "coordinates": [9.82158, 46.41811] } },
      { "type": "Feature",
        "properties": { "_id": "x2", "name": "LA DOLE", "identifier": "DOL", "type": 7,
          "frequency": { "value": "115.350", "unit": 2 }, "magneticDeclination": 2.8314 },
        "geometry": { "type": "Point", "coordinates": [6.0997, 46.4247] } }
    ] }
    """.data(using: .utf8)!

    func testParseNavaidGeoJSON() throws {
        let navaids = try Navaid.parse(geoJSON: sampleGeoJSON)
        XCTAssertEqual(navaids.count, 2)
        let cva = navaids[0]
        XCTAssertEqual(cva.id, "62616c96abdcc7f0ccbbe519")
        XCTAssertEqual(cva.identifier, "CVA")
        XCTAssertEqual(cva.name, "CORVATSCH")
        XCTAssertEqual(cva.frequencyValue, "112.050")
        XCTAssertEqual(cva.channel, "57Y")
        XCTAssertEqual(cva.magneticDeclination, 4)
        XCTAssertEqual(cva.latitude, 46.41811, accuracy: 0.00001)
        XCTAssertEqual(cva.longitude, 9.82158, accuracy: 0.00001)   // [lon, lat] order honoured
        XCTAssertEqual(cva.elevationFeet, Int((3279.0 * 3.28084).rounded()))   // meters → feet
    }

    func testParseHandlesFractionalDeclinationAndMissingOptionals() throws {
        let dol = try Navaid.parse(geoJSON: sampleGeoJSON)[1]
        XCTAssertEqual(dol.magneticDeclination ?? 0, 2.8314, accuracy: 0.00001)   // fractional Double
        XCTAssertNil(dol.channel)        // optional absent
        XCTAssertNil(dol.elevationFeet)  // no elevation object
    }

    func testParseHandlesFractionalElevation() throws {
        // OpenAIP serves fractional measured values — a fractional elevation must NOT abort the
        // whole-country decode (regression: Elevation.value was Int). (review #1)
        let json = """
        {"type":"FeatureCollection","features":[{"type":"Feature",
          "properties":{"_id":"z","name":"X","identifier":"X","type":0,
            "elevation":{"value":412.5,"unit":0,"referenceDatum":1}},
          "geometry":{"type":"Point","coordinates":[7,46]}}]}
        """.data(using: .utf8)!
        let navaids = try Navaid.parse(geoJSON: json)
        XCTAssertEqual(navaids.count, 1)
        XCTAssertEqual(navaids[0].elevationFeet, Int((412.5 * 3.28084).rounded()))
    }

    func testUnknownTypeCodeFallsBackToUnknown() throws {
        let json = """
        {"type":"FeatureCollection","features":[{"type":"Feature",
          "properties":{"_id":"z","name":"X","identifier":"X","type":99},
          "geometry":{"type":"Point","coordinates":[7,46]}}]}
        """.data(using: .utf8)!
        let navaid = try Navaid.parse(geoJSON: json).first
        XCTAssertEqual(navaid?.type, .unknown)
        XCTAssertEqual(navaid?.type.shortLabel, "NAVAID")
    }

    func testParseSkipsMalformedGeometry() throws {
        let json = """
        {"type":"FeatureCollection","features":[{"type":"Feature",
          "properties":{"_id":"z","name":"X","identifier":"X","type":0},
          "geometry":{"type":"Point","coordinates":[7]}}]}
        """.data(using: .utf8)!
        XCTAssertTrue(try Navaid.parse(geoJSON: json).isEmpty)   // single coordinate → skipped, not fatal
    }

    @MainActor
    func testNearestNavaidWithinRadius() throws {
        let service = OpenAIPNavaidDataService()
        service.seedForTesting(try Navaid.parse(geoJSON: sampleGeoJSON))

        let nearCorvatsch = service.nearestNavaid(to: CLLocationCoordinate2D(latitude: 46.42, longitude: 9.82),
                                                  maxDistanceNm: 50)
        XCTAssertEqual(nearCorvatsch?.identifier, "CVA")

        // Mid-Atlantic — nothing within 50 NM.
        let none = service.nearestNavaid(to: CLLocationCoordinate2D(latitude: 30, longitude: -30), maxDistanceNm: 50)
        XCTAssertNil(none)
    }
}
