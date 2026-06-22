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

    // MARK: - Runways (v4.1.0 runway merge)

    /// LSZT: a paired "10"/"28" with PCN + per-direction declared distances (metres), a paired grass
    /// "16L"/"34R", and an unpaired "07" whose length is already in feet (unit 1).
    private let runwayGeoJSON = """
    { "type": "FeatureCollection", "features": [
      { "type": "Feature",
        "properties": { "_id": "r1", "name": "TEST", "icaoCode": "LSZT", "type": 3, "country": "CH",
          "runways": [
            { "designator": "10", "trueHeading": 104, "mainRunway": true,
              "surface": { "mainComposite": 0, "pcn": "35/F/B/X/T" },
              "dimension": { "length": { "value": 1245, "unit": 0 }, "width": { "value": 40, "unit": 0 } },
              "declaredDistance": { "tora": { "value": 1120, "unit": 0 }, "lda": { "value": 1120, "unit": 0 } },
              "pilotCtrlLighting": true },
            { "designator": "28", "trueHeading": 284, "mainRunway": false,
              "surface": { "mainComposite": 0, "pcn": "35/F/B/X/T" },
              "dimension": { "length": { "value": 1245, "unit": 0 }, "width": { "value": 40, "unit": 0 } },
              "declaredDistance": { "tora": { "value": 1245, "unit": 0 }, "lda": { "value": 1100, "unit": 0 } } },
            { "designator": "16L", "trueHeading": 160, "surface": { "mainComposite": 2 },
              "dimension": { "length": { "value": 800, "unit": 0 } } },
            { "designator": "34R", "trueHeading": 340, "surface": { "mainComposite": 2 },
              "dimension": { "length": { "value": 800, "unit": 0 } } },
            { "designator": "07", "trueHeading": 70, "surface": { "mainComposite": 0 },
              "dimension": { "length": { "value": 600, "unit": 1 } } }
          ] },
        "geometry": { "type": "Point", "coordinates": [7.5, 47.0] } }
    ] }
    """.data(using: .utf8)!

    func testParseRunwaysFromGeoJSON() throws {
        let apt = try OpenAIPAirport.parse(geoJSON: runwayGeoJSON)[0]
        XCTAssertEqual(apt.runways.count, 5)
        let r10 = apt.runways.first { $0.designator == "10" }!
        XCTAssertEqual(r10.trueHeading, 104)
        XCTAssertTrue(r10.mainRunway)
        XCTAssertEqual(r10.surfaceLabel, "Asphalt")          // mainComposite 0
        XCTAssertEqual(r10.pcn, "35/F/B/X/T")
        XCTAssertEqual(r10.lengthFeet, Int((1245.0 * 3.28084).rounded()))   // metres → feet
        XCTAssertEqual(r10.toraFeet, Int((1120.0 * 3.28084).rounded()))
        XCTAssertTrue(r10.lighted)
        // "07" length is unit 1 (already feet) → used as-is.
        XCTAssertEqual(apt.runways.first { $0.designator == "07" }!.lengthFeet, 600)
        XCTAssertEqual(apt.runways.first { $0.designator == "16L" }!.surfaceLabel, "Grass") // mainComposite 2
    }

    func testRunwayPairing() throws {
        let runways = AirportDataMergeEngine.openAIPRunways(from: try OpenAIPAirport.parse(geoJSON: runwayGeoJSON))
        // 5 directions → 3 runways: 10/28, 16L/34R, and the unpaired 07.
        XCTAssertEqual(runways.count, 3)
        let ids = Set(runways.map { $0.identifier })
        XCTAssertTrue(ids.contains("10/28"))
        XCTAssertTrue(ids.contains("16L/34R"))

        let main = runways.first { $0.identifier == "10/28" }!
        XCTAssertEqual(main.leIdent, "10")
        XCTAssertEqual(main.heIdent, "28")
        XCTAssertEqual(main.leHeadingDegT, 104)
        XCTAssertEqual(main.heHeadingDegT, 284)
        XCTAssertEqual(main.pcn, "35/F/B/X/T")
        XCTAssertTrue(main.lighted)
        // Declared distances kept PER DIRECTION (10's LDA 1120 m ≠ 28's LDA 1100 m).
        XCTAssertEqual(main.leLdaFt, Int((1120.0 * 3.28084).rounded()))
        XCTAssertEqual(main.heLdaFt, Int((1100.0 * 3.28084).rounded()))
        XCTAssertNotEqual(main.leLdaFt, main.heLdaFt)

        // "07" had no opposite ("25") present → LE-only runway.
        let single = runways.first { $0.leIdent == "07" }!
        XCTAssertNil(single.heIdent)
        XCTAssertEqual(single.identifier, "07/?")
    }

    func testRunwayUnionOpenAIPWinsKeepingOurAirportsOnly() {
        // OurAirports has a basic "10/28" + an "02/20" OpenAIP lacks.
        let ourRwy = { (le: String, he: String) in
            Runway(id: 1, airportRef: 1, airportIdent: "LSZT", lengthFt: 3000, widthFt: 100,
                   surface: "ASP", lighted: false, closed: false,
                   leIdent: le, leLatitude: nil, leLongitude: nil, leElevationFt: nil,
                   leHeadingDegT: nil, leDisplacedThresholdFt: nil,
                   heIdent: he, heLatitude: nil, heLongitude: nil, heElevationFt: nil,
                   heHeadingDegT: nil, heDisplacedThresholdFt: nil,
                   pcn: nil, leToraFt: nil, leLdaFt: nil, heToraFt: nil, heLdaFt: nil)
        }
        let our = [ourRwy("10", "28"), ourRwy("02", "20")]
        let openAIP = AirportDataMergeEngine.openAIPRunways(from: try! OpenAIPAirport.parse(geoJSON: runwayGeoJSON))
        let merged = AirportDataMergeEngine.unionRunways(our: our, openAIP: openAIP)
        // OpenAIP's 10/28 (with PCN) replaces OurAirports' 10/28; OurAirports' 02/20 is kept; OpenAIP
        // 16L/34R + 07 added. The matched 10/28 is the OpenAIP one (has PCN).
        XCTAssertEqual(merged.first { $0.identifier == "10/28" }?.pcn, "35/F/B/X/T")
        XCTAssertNotNil(merged.first { $0.identifier == "02/20" })          // OurAirports-only kept
        XCTAssertEqual(merged.filter { $0.identifier == "10/28" }.count, 1) // no duplicate
        XCTAssertTrue(Set(merged.map { $0.identifier }).isSuperset(of: ["10/28", "02/20", "16L/34R"]))
    }

    func testDesignatorParsing() {
        XCTAssertEqual(AirportDataMergeEngine.parseDesignator("10")?.number, 10)
        XCTAssertEqual(AirportDataMergeEngine.parseDesignator("16L")?.suffix, "L")
        XCTAssertEqual(AirportDataMergeEngine.parseDesignator("07")?.number, 7)
        XCTAssertNil(AirportDataMergeEngine.parseDesignator("XYZ"))
        XCTAssertNil(AirportDataMergeEngine.parseDesignator("99"))   // out of 1...36
    }
}
