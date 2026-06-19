import XCTest
import CoreLocation
@testable import AeroCheck

/// Unit tests for the v4.1.0 increment-9 OpenAIP-primary airport merge: parsing the OpenAIP airport
/// GeoJSON export and the (flag-gated) `AirportDataMergeEngine` that folds it into the OurAirports
/// backbone — OpenAIP wins on an ICAO match within tolerance, OurAirports gap-fills, no-ICAO records
/// are skipped, and far-apart same-ICAO fields are kept distinct.
final class OpenAIPAirportMergeTests: XCTestCase {

    private let sampleGeoJSON = """
    { "type": "FeatureCollection", "features": [
      { "type": "Feature",
        "properties": { "_id": "a1", "name": "BERN-BELP", "icaoCode": "LSZB", "type": 3, "country": "CH",
          "magneticDeclination": 3, "elevation": { "value": 510, "unit": 0, "referenceDatum": 1 },
          "frequencies": [ { "name": "BERN TOWER", "value": "121.030", "type": 14 },
                           { "name": "BERN ATIS", "value": "125.130", "type": 15 } ] },
        "geometry": { "type": "Point", "coordinates": [7.4971, 46.9141] } },
      { "type": "Feature",
        "properties": { "_id": "a2", "name": "GENEVA", "icaoCode": "LSGG", "type": 3, "country": "CH",
          "elevation": { "value": 1411, "unit": 0 } },
        "geometry": { "type": "Point", "coordinates": [6.1089, 46.2381] } },
      { "type": "Feature",
        "properties": { "_id": "a3", "name": "PRIVATE STRIP", "type": 2, "country": "CH" },
        "geometry": { "type": "Point", "coordinates": [7.0, 46.5] } }
    ] }
    """.data(using: .utf8)!

    private func ourAirport(id: Int, ident: String, lat: Double, lon: Double, name: String,
                            iata: String? = nil) -> Airport {
        Airport(id: id, ident: ident, type: .smallAirport, name: name, latitude: lat, longitude: lon,
                elevation: 500, continent: "EU", isoCountry: "CH", isoRegion: "CH-BE",
                municipality: "Bern", scheduledService: false, gpsCode: ident, iataCode: iata, localCode: nil)
    }

    // MARK: - Parse

    func testParseAirportGeoJSON() throws {
        let airports = try OpenAIPAirport.parse(geoJSON: sampleGeoJSON)
        XCTAssertEqual(airports.count, 3)
        let bern = airports[0]
        XCTAssertEqual(bern.icaoCode, "LSZB")
        XCTAssertEqual(bern.name, "BERN-BELP")
        XCTAssertEqual(bern.typeRaw, 3)
        XCTAssertEqual(bern.airportType, .largeAirport)
        XCTAssertEqual(bern.country, "CH")
        XCTAssertEqual(bern.elevationFeetMSL, Int((510.0 * 3.28084).rounded()))
        XCTAssertEqual(bern.latitude, 46.9141, accuracy: 0.0001)
        XCTAssertEqual(bern.longitude, 7.4971, accuracy: 0.0001)   // [lon, lat] honoured
        XCTAssertNil(airports[2].icaoCode)                          // strip has no ICAO
    }

    // MARK: - Merge

    func testMergeOpenAIPWinsOnIcaoMatchPreservingIATA() throws {
        let our = [ourAirport(id: 100, ident: "LSZB", lat: 46.914, lon: 7.497, name: "Bern Belp", iata: "BRN")]
        let merged = AirportDataMergeEngine.merge(ourAirports: our, openAIP: try OpenAIPAirport.parse(geoJSON: sampleGeoJSON))
        // LSZB matched (kept single); LSGG appended; no-ICAO strip skipped → 2 total.
        XCTAssertEqual(merged.count, 2)
        let lszb = merged.first { $0.ident == "LSZB" }!
        XCTAssertEqual(lszb.id, 100)              // OurAirports id preserved (stable references)
        XCTAssertEqual(lszb.name, "BERN-BELP")    // OpenAIP name wins
        XCTAssertEqual(lszb.iataCode, "BRN")      // OurAirports IATA preserved (OpenAIP lacks it)
        XCTAssertEqual(lszb.type, .largeAirport)  // OpenAIP type wins
    }

    func testMergeAppendsOpenAIPOnlyAirportWithStableNegativeID() throws {
        let our = [ourAirport(id: 100, ident: "LSZB", lat: 46.914, lon: 7.497, name: "Bern")]
        let merged = AirportDataMergeEngine.merge(ourAirports: our, openAIP: try OpenAIPAirport.parse(geoJSON: sampleGeoJSON))
        let geneva = merged.first { $0.ident == "LSGG" }
        XCTAssertNotNil(geneva)
        XCTAssertLessThan(geneva!.id, 0)          // synthetic id never collides with OurAirports' positive ids
        XCTAssertEqual(geneva!.isoCountry, "CH")  // from OpenAIP `country`
    }

    func testMergeKeepsBothWhenSameIcaoFarApart() throws {
        // OurAirports LSZB at one spot; OpenAIP LSZB ~150 NM away (beyond tolerance) → don't overwrite.
        let far = """
        {"type":"FeatureCollection","features":[{"type":"Feature",
          "properties":{"_id":"x","name":"WRONG","icaoCode":"LSZB","type":3,"country":"CH"},
          "geometry":{"type":"Point","coordinates":[9.5,48.5]}}]}
        """.data(using: .utf8)!
        let our = [ourAirport(id: 100, ident: "LSZB", lat: 46.914, lon: 7.497, name: "Bern Belp")]
        let merged = AirportDataMergeEngine.merge(ourAirports: our, openAIP: try OpenAIPAirport.parse(geoJSON: far))
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].name, "Bern Belp")        // OurAirports kept; far OpenAIP record ignored
        XCTAssertEqual(merged[0].latitude, 46.914, accuracy: 0.0001)
    }

    func testOpenAIPFrequencyConversion() throws {
        let airports = try OpenAIPAirport.parse(geoJSON: sampleGeoJSON)
        let freqs = AirportDataMergeEngine.openAIPFrequencies(from: airports)
        // Only LSZB has frequencies; GENEVA has none and the no-ICAO strip is skipped.
        XCTAssertTrue(freqs.allSatisfy { $0.airportIdent == "LSZB" })
        XCTAssertEqual(freqs.count, 2)
        let twr = freqs.first { $0.type == "TWR" }
        XCTAssertEqual(twr?.frequencyMhz ?? 0, 121.030, accuracy: 0.001)
        XCTAssertEqual(twr?.description, "BERN TOWER")
        XCTAssertNotNil(freqs.first { $0.type == "ATIS" })
    }

    func testMergeUppercasesOpenAIPOnlyIdent() throws {
        // A lowercase OpenAIP icaoCode must be uppercased on the appended Airport so airportsByIdent /
        // findAirport(byIdent:) (which uppercases the query) can find it. (review #6)
        let lower = """
        {"type":"FeatureCollection","features":[{"type":"Feature",
          "properties":{"_id":"lc","name":"LOWER","icaoCode":"lszx","type":2,"country":"CH"},
          "geometry":{"type":"Point","coordinates":[7.5,46.5]}}]}
        """.data(using: .utf8)!
        let merged = AirportDataMergeEngine.merge(ourAirports: [], openAIP: try OpenAIPAirport.parse(geoJSON: lower))
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].ident, "LSZX")
    }

    func testStableNegativeIDIsDeterministicAndNegative() {
        XCTAssertEqual(AirportDataMergeEngine.stableNegativeID("626151975e9ded5710452de5"),
                       AirportDataMergeEngine.stableNegativeID("626151975e9ded5710452de5"))
        XCTAssertLessThan(AirportDataMergeEngine.stableNegativeID("anything"), 0)
        XCTAssertNotEqual(AirportDataMergeEngine.stableNegativeID("a"),
                          AirportDataMergeEngine.stableNegativeID("b"))
    }
}
