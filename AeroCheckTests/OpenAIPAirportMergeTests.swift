import XCTest
import CoreLocation
@testable import AeroCheck

/// Unit tests for the v4.1.0 increment-9 OpenAIP-primary airport merge: parsing the OpenAIP airport
/// GeoJSON export and the (flag-gated) `AirportDataMergeEngine` that folds it into the OurAirports
/// backbone — OpenAIP wins on an ICAO match within tolerance, OurAirports gap-fills, no-ICAO records
/// are skipped, and far-apart same-ICAO fields are kept distinct. Runways (6.2.0): one runway per
/// physical strip, whatever each source calls it, and the hand-set `RunwayDesignatorOverrides`.
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

    func testParseSkipsMalformedAirportFeatureWithoutAbortingRest() throws {
        // One feature missing a REQUIRED property (here `_id`) must be skipped, not abort the whole
        // country decode (OpenAIP is the primary airport provider). (v4.1.0 pre-tag fix)
        let json = """
        { "type": "FeatureCollection", "features": [
          { "type": "Feature", "properties": { "_id": "ok1", "name": "ALPHA", "icaoCode": "LSZA", "type": 3, "country": "CH" },
            "geometry": { "type": "Point", "coordinates": [8.0, 46.0] } },
          { "type": "Feature", "properties": { "name": "NO ID", "icaoCode": "LSZB", "type": 3, "country": "CH" },
            "geometry": { "type": "Point", "coordinates": [7.5, 46.9] } },
          { "type": "Feature", "properties": { "_id": "ok2", "name": "BRAVO", "icaoCode": "LSGG", "type": 3, "country": "CH" },
            "geometry": { "type": "Point", "coordinates": [6.1, 46.2] } }
        ] }
        """.data(using: .utf8)!
        XCTAssertEqual(try OpenAIPAirport.parse(geoJSON: json).map(\.id), ["ok1", "ok2"])   // middle skipped, rest survive
    }

    func testMergeDropsInvalidCoordinateAirport() throws {
        // A finite-but-out-of-range coordinate magnitude (here longitude 1e30). If it reached the spatial
        // grid, the `Int(...)` conversion would TRAP (overflow) and crash every user at load. The merge
        // must drop it. (v4.1.0 pre-tag hardening — blocker #2)
        let badGeoJSON = """
        { "type": "FeatureCollection", "features": [
          { "type": "Feature",
            "properties": { "_id": "bad", "name": "OUT OF RANGE", "icaoCode": "LSXX", "type": 3, "country": "CH" },
            "geometry": { "type": "Point", "coordinates": [1e30, 46.5] } }
        ] }
        """.data(using: .utf8)!
        let oaip = try OpenAIPAirport.parse(geoJSON: badGeoJSON)
        XCTAssertEqual(oaip.count, 1)
        XCTAssertFalse(CLLocationCoordinate2DIsValid(oaip[0].coordinate))   // sanity: parse produced an invalid coord
        let merged = AirportDataMergeEngine.merge(ourAirports: [], openAIP: oaip)
        XCTAssertTrue(merged.isEmpty)                                        // dropped at merge, not appended/crashed
    }

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
        // OpenAIP's 10/28 (with PCN) merges with OurAirports' 10/28; OurAirports' 02/20 is kept; OpenAIP
        // 16L/34R + 07 added. The matched 10/28 carries OpenAIP's PCN.
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

    /// OpenAIP exports a single-digit designator ("9"); OurAirports zero-pads ("09"). They are the SAME
    /// physical runway, so unionRunways must dedupe them via the normalised key, not list it twice.
    func testRunwayUnionNormalizesZeroPaddedDesignators() {
        let mk = { (id: Int, le: String, he: String, pcn: String?) -> Runway in
            Runway(id: id, airportRef: 1, airportIdent: "LSZX", lengthFt: 2000, widthFt: 80,
                   surface: "ASP", lighted: false, closed: false,
                   leIdent: le, leLatitude: nil, leLongitude: nil, leElevationFt: nil,
                   leHeadingDegT: nil, leDisplacedThresholdFt: nil,
                   heIdent: he, heLatitude: nil, heLongitude: nil, heElevationFt: nil,
                   heHeadingDegT: nil, heDisplacedThresholdFt: nil,
                   pcn: pcn, leToraFt: nil, leLdaFt: nil, heToraFt: nil, heLdaFt: nil)
        }
        let our = [mk(1, "09", "27", nil)]
        let openAIP = [mk(-1, "9", "27", "30/F/A/X/T")]
        let merged = AirportDataMergeEngine.unionRunways(our: our, openAIP: openAIP)
        XCTAssertEqual(merged.count, 1, "Single-digit and zero-padded forms must dedupe to one runway")
        XCTAssertEqual(merged.first?.pcn, "30/F/A/X/T", "OpenAIP wins on the normalised match")
    }

    // MARK: - One runway per strip (6.2.0)
    //
    // Fixtures are the published data, trimmed to the fields the merge reads: OurAirports `runways.csv` and
    // OpenAIP's keyless `ch_apt.geojson` export, both fetched on 2026-10-01. In Switzerland the two disagree
    // on the designators at 12 of the 56 fields both list runways for.

    /// OurAirports rows, verbatim (header included).
    private let ourAirportsRunwaysCSV = """
    "id","airport_ref","airport_ident","length_ft","width_ft","surface","lighted","closed","le_ident","le_latitude_deg","le_longitude_deg","le_elevation_ft","le_heading_degT","le_displaced_threshold_ft","he_ident","he_latitude_deg","he_longitude_deg","he_elevation_ft","he_heading_degT","he_displaced_threshold_ft"
    239133,4489,"LSGC",3707,89,"ASP",1,0,"05",47.081001,6.78702,3368,54,230,"23",47.086899,6.79909,3343,234,328
    256698,29495,"LSGE",2625,75,"ASPH",1,0,"09",46.755596,7.070533,2281,95,,"27",46.754967,7.080964,2294,275,
    250742,29497,"LSGN",2295,66,"CONCRETE",0,0,"05",,,1434,,,"23",,,1424,,
    260324,4492,"LSGS",6562,131,"ASPH",1,0,"07",46.216698,7.314575,1575,73,164,"25",46.221981,7.339386,1582,253,164
    239113,4492,"LSGS",1837,98,"GRS",0,0,"07G",46.218498,7.32107,1574,73,,"25G",46.220001,7.32795,1577,253,328
    239112,4492,"LSGS",140,140,"GRASS",0,1,"HEL",46.215922,7.3174,,,,,,,,,
    251513,29500,"LSGY",2861,59,"ASPH",1,0,"04",46.759216,6.609075,1421,,,"22",46.764591,6.617386,1421,,
    263458,29500,"LSGY",2379,66,"GRASS",0,0,"05R",,,,,,"23L",,,,,
    239104,4500,"LSPM",4060,131,"concrete",0,0,"11",46.51369,8.685685,3241,,405,"29",46.511032,8.701393,3241,,405
    253066,29515,"LSTO",1857,98,"GRASS",0,0,"05",,,,,,"23",,,,,
    342534,29524,"LSZN",2297,59,"ASPH",0,0,"09",,,,91,328,"27",,,,271,328
    257431,29524,"LSZN",2297,98,"GRASS",0,0,"09L",47.238992,8.510973,,91,322,"27R",47.238866,8.5202,,271,644
    """

    /// OpenAIP's records for the same fields (runways as exported, elevation and frequencies left out).
    private let openAIPSwissFieldsGeoJSON = """
    { "type": "FeatureCollection", "features": [
      { "type": "Feature", "properties": { "_id": "6261519e0e8346dfd925198a", "name": "LES EPLATURES", "icaoCode": "LSGC", "type": 9, "country": "CH",
          "runways": [
            {"designator": "06", "trueHeading": 54, "mainRunway": true, "surface": {"mainComposite": 0, "pcn": "020/F/C/Y/T"}, "dimension": {"length": {"value": 1090, "unit": 0}, "width": {"value": 27, "unit": 0}}, "declaredDistance": {"tora": {"value": 1059, "unit": 0}, "lda": {"value": 1054, "unit": 0}}},
            {"designator": "24", "trueHeading": 234, "mainRunway": true, "surface": {"mainComposite": 0, "pcn": "020/F/C/Y/T"}, "dimension": {"length": {"value": 1090, "unit": 0}, "width": {"value": 27, "unit": 0}}, "declaredDistance": {"tora": {"value": 1054, "unit": 0}, "lda": {"value": 1059, "unit": 0}}}
          ] },
        "geometry": { "type": "Point", "coordinates": [6.79361, 47.08417] } },
      { "type": "Feature", "properties": { "_id": "6261519a5e9ded5710452f24", "name": "ECUVILLENS", "icaoCode": "LSGE", "type": 2, "country": "CH",
          "runways": [
            {"designator": "09", "trueHeading": 93, "mainRunway": true, "surface": {"mainComposite": 0, "pcn": "15/F/C/Y/T"}, "dimension": {"length": {"value": 800, "unit": 0}, "width": {"value": 23, "unit": 0}}, "declaredDistance": {"tora": {"value": 800, "unit": 0}, "lda": {"value": 800, "unit": 0}}},
            {"designator": "27", "trueHeading": 273, "mainRunway": true, "surface": {"mainComposite": 0, "pcn": "15/F/C/Y/T"}, "dimension": {"length": {"value": 800, "unit": 0}, "width": {"value": 23, "unit": 0}}, "declaredDistance": {"tora": {"value": 800, "unit": 0}, "lda": {"value": 800, "unit": 0}}}
          ] },
        "geometry": { "type": "Point", "coordinates": [7.07583, 46.75528] } },
      { "type": "Feature", "properties": { "_id": "626151a05e9ded571045315a", "name": "NEUCHATEL", "icaoCode": "LSGN", "type": 2, "country": "CH",
          "runways": [
            {"designator": "05", "trueHeading": 52, "mainRunway": true, "surface": {"mainComposite": 1}, "dimension": {"length": {"value": 700, "unit": 0}, "width": {"value": 20, "unit": 0}}, "declaredDistance": {"tora": {"value": 700, "unit": 0}, "lda": {"value": 670, "unit": 0}}},
            {"designator": "23", "trueHeading": 232, "mainRunway": true, "surface": {"mainComposite": 1}, "dimension": {"length": {"value": 700, "unit": 0}, "width": {"value": 20, "unit": 0}}, "declaredDistance": {"tora": {"value": 670, "unit": 0}, "lda": {"value": 700, "unit": 0}}},
            {"designator": "05R", "trueHeading": 52, "mainRunway": false, "surface": {"mainComposite": 2}, "dimension": {"length": {"value": 550, "unit": 0}, "width": {"value": 30, "unit": 0}}, "declaredDistance": {"tora": {"value": 550, "unit": 0}, "lda": {"value": 550, "unit": 0}}},
            {"designator": "23L", "trueHeading": 232, "mainRunway": false, "surface": {"mainComposite": 2}, "dimension": {"length": {"value": 550, "unit": 0}, "width": {"value": 30, "unit": 0}}, "declaredDistance": {"tora": {"value": 550, "unit": 0}, "lda": {"value": 550, "unit": 0}}}
          ] },
        "geometry": { "type": "Point", "coordinates": [6.8647, 46.9575] } },
      { "type": "Feature", "properties": { "_id": "626151a25e9ded5710453204", "name": "SION", "icaoCode": "LSGS", "type": 0, "country": "CH",
          "runways": [
            {"designator": "07", "trueHeading": 73, "mainRunway": true, "surface": {"mainComposite": 0, "pcn": "040/F/B/X/T"}, "dimension": {"length": {"value": 2000, "unit": 0}, "width": {"value": 40, "unit": 0}}, "declaredDistance": {"tora": {"value": 1940, "unit": 0}, "lda": {"value": 1935, "unit": 0}}},
            {"designator": "25", "trueHeading": 253, "mainRunway": true, "surface": {"mainComposite": 0, "pcn": "040/F/B/X/T"}, "dimension": {"length": {"value": 2000, "unit": 0}, "width": {"value": 40, "unit": 0}}, "declaredDistance": {"tora": {"value": 1935, "unit": 0}, "lda": {"value": 1940, "unit": 0}}},
            {"designator": "07L", "trueHeading": 73, "mainRunway": false, "surface": {"mainComposite": 2}, "dimension": {"length": {"value": 660, "unit": 0}, "width": {"value": 30, "unit": 0}}, "declaredDistance": {"tora": {"value": 660, "unit": 0}, "lda": {"value": 660, "unit": 0}}},
            {"designator": "25R", "trueHeading": 253, "mainRunway": false, "surface": {"mainComposite": 2}, "dimension": {"length": {"value": 660, "unit": 0}, "width": {"value": 30, "unit": 0}}, "declaredDistance": {"tora": {"value": 560, "unit": 0}, "lda": {"value": 560, "unit": 0}}}
          ] },
        "geometry": { "type": "Point", "coordinates": [7.32694, 46.21917] } },
      { "type": "Feature", "properties": { "_id": "626151a75e9ded5710453370", "name": "YVERDON-LES-BAINS", "icaoCode": "LSGY", "type": 2, "country": "CH",
          "runways": [
            {"designator": "04", "trueHeading": 47, "mainRunway": true, "surface": {"mainComposite": 0}, "dimension": {"length": {"value": 872, "unit": 0}, "width": {"value": 18, "unit": 0}}, "declaredDistance": {"tora": {"value": 872, "unit": 0}, "lda": {"value": 872, "unit": 0}}},
            {"designator": "22", "trueHeading": 227, "mainRunway": true, "surface": {"mainComposite": 0}, "dimension": {"length": {"value": 872, "unit": 0}, "width": {"value": 18, "unit": 0}}, "declaredDistance": {"tora": {"value": 872, "unit": 0}, "lda": {"value": 872, "unit": 0}}},
            {"designator": "04R", "trueHeading": 47, "mainRunway": false, "surface": {"mainComposite": 2}, "dimension": {"length": {"value": 725, "unit": 0}, "width": {"value": 20, "unit": 0}}, "declaredDistance": {"tora": {"value": 725, "unit": 0}, "lda": {"value": 725, "unit": 0}}},
            {"designator": "22L", "trueHeading": 227, "mainRunway": false, "surface": {"mainComposite": 2}, "dimension": {"length": {"value": 725, "unit": 0}, "width": {"value": 20, "unit": 0}}, "declaredDistance": {"tora": {"value": 725, "unit": 0}, "lda": {"value": 725, "unit": 0}}}
          ] },
        "geometry": { "type": "Point", "coordinates": [6.6133, 46.7619] } },
      { "type": "Feature", "properties": { "_id": "626151970e8346dfd925183a", "name": "AMBRI", "icaoCode": "LSPM", "type": 2, "country": "CH",
          "runways": [
            {"designator": "10", "trueHeading": 104, "mainRunway": true, "surface": {"mainComposite": 0, "pcn": "35/F/B/X/T"}, "dimension": {"length": {"value": 1245, "unit": 0}, "width": {"value": 40, "unit": 0}}, "declaredDistance": {"tora": {"value": 1120, "unit": 0}, "lda": {"value": 1120, "unit": 0}}},
            {"designator": "27", "trueHeading": 284, "mainRunway": true, "surface": {"mainComposite": 0, "pcn": "35/F/B/X/T"}, "dimension": {"length": {"value": 1245, "unit": 0}, "width": {"value": 40, "unit": 0}}, "declaredDistance": {"tora": {"value": 1120, "unit": 0}, "lda": {"value": 1120, "unit": 0}}}
          ] },
        "geometry": { "type": "Point", "coordinates": [8.69391, 46.51228] } },
      { "type": "Feature", "properties": { "_id": "626151a05e9ded571045312c", "name": "MOTIERS", "icaoCode": "LSTO", "type": 2, "country": "CH",
          "runways": [
            {"designator": "04", "trueHeading": 44, "mainRunway": true, "surface": {"mainComposite": 2}, "dimension": {"length": {"value": 566, "unit": 0}, "width": {"value": 30, "unit": 0}}, "declaredDistance": {"tora": {"value": 506, "unit": 0}, "lda": {"value": 508, "unit": 0}}},
            {"designator": "22", "trueHeading": 224, "mainRunway": true, "surface": {"mainComposite": 2}, "dimension": {"length": {"value": 566, "unit": 0}, "width": {"value": 30, "unit": 0}}, "declaredDistance": {"tora": {"value": 506, "unit": 0}, "lda": {"value": 506, "unit": 0}}}
          ] },
        "geometry": { "type": "Point", "coordinates": [6.615, 46.9167] } },
      { "type": "Feature", "properties": { "_id": "6261519c0e8346dfd9251911", "name": "HAUSEN AM ALBIS R", "icaoCode": "LSZN", "type": 2, "country": "CH",
          "runways": [
            {"designator": "09", "trueHeading": 91, "mainRunway": true, "surface": {"mainComposite": 0}, "dimension": {"length": {"value": 700, "unit": 0}, "width": {"value": 18, "unit": 0}}, "declaredDistance": {"tora": {"value": 600, "unit": 0}, "lda": {"value": 600, "unit": 0}}},
            {"designator": "27", "trueHeading": 271, "mainRunway": true, "surface": {"mainComposite": 0}, "dimension": {"length": {"value": 700, "unit": 0}, "width": {"value": 18, "unit": 0}}, "declaredDistance": {"tora": {"value": 600, "unit": 0}, "lda": {"value": 600, "unit": 0}}},
            {"designator": "09", "trueHeading": 91, "mainRunway": false, "surface": {"mainComposite": 2}, "dimension": {"length": {"value": 700, "unit": 0}, "width": {"value": 30, "unit": 0}}, "declaredDistance": {"tora": {"value": 500, "unit": 0}, "lda": {"value": 600, "unit": 0}}},
            {"designator": "27", "trueHeading": 271, "mainRunway": false, "surface": {"mainComposite": 2}, "dimension": {"length": {"value": 700, "unit": 0}, "width": {"value": 30, "unit": 0}}, "declaredDistance": {"tora": {"value": 600, "unit": 0}, "lda": {"value": 470, "unit": 0}}}
          ] },
        "geometry": { "type": "Point", "coordinates": [8.5156, 47.2386] } }
    ] }
    """.data(using: .utf8)!

    private func ourRunways(_ icao: String) -> [Runway] {
        AirportDataService.parseRunwaysCSV(ourAirportsRunwaysCSV).filter { $0.airportIdent == icao }
    }

    private func openAIPField(_ icao: String) throws -> OpenAIPAirport {
        try XCTUnwrap(try OpenAIPAirport.parse(geoJSON: openAIPSwissFieldsGeoJSON).first { $0.icaoCode == icao })
    }

    private func openAIPRunways(_ icao: String) throws -> [Runway] {
        AirportDataMergeEngine.openAIPRunways(from: [try openAIPField(icao)])
    }

    /// The field's runways as the app ends up with them: both sources merged, then the overrides.
    private func merged(_ icao: String) throws -> [Runway] {
        let field = try openAIPField(icao)
        let byIdent = AirportDataMergeEngine.mergedRunways(
            ourRunwaysByIdent: [icao: ourRunways(icao)], openAIP: [field], foldedOpenAIPIds: [field.id])
        return try XCTUnwrap(byIdent[icao])
    }

    private func feet(_ metres: Double) -> Int { Int((metres * 3.28084).rounded()) }

    /// A bare runway for the cases the Swiss data doesn't cover.
    private func runway(_ icao: String, _ le: String, _ he: String?, heading: Double? = nil, closed: Bool = false,
                        leLatitude: Double? = nil, leTora: Int? = nil, heTora: Int? = nil) -> Runway {
        Runway(id: 1, airportRef: 1, airportIdent: icao, lengthFt: 2000, widthFt: 80, surface: "ASP",
               lighted: false, closed: closed,
               leIdent: le, leLatitude: leLatitude, leLongitude: nil, leElevationFt: nil,
               leHeadingDegT: heading, leDisplacedThresholdFt: nil,
               heIdent: he, heLatitude: nil, heLongitude: nil, heElevationFt: nil,
               heHeadingDegT: heading.map { ($0 + 180).truncatingRemainder(dividingBy: 360) },
               heDisplacedThresholdFt: nil,
               pcn: nil, leToraFt: leTora, leLdaFt: nil, heToraFt: heTora, heLdaFt: nil)
    }

    /// LSGC: OurAirports 05/23, OpenAIP 06/24, one strip (054°T both). It used to show twice; now it is one
    /// runway under OurAirports' designators (the tie-break, and the override the author confirmed), with
    /// OurAirports' thresholds and OpenAIP's PCN and declared distances on the right ends.
    func testLSGCIsOneRunwayUnderOurAirportsDesignators() throws {
        let runways = try merged("LSGC")
        XCTAssertEqual(runways.map(\.identifier), ["05/23"])
        let rwy = runways[0]
        // OurAirports' geometry, end by end.
        XCTAssertEqual(rwy.leLatitude, 47.081001)
        XCTAssertEqual(rwy.leLongitude, 6.78702)
        XCTAssertEqual(rwy.leElevationFt, 3368)
        XCTAssertEqual(rwy.leDisplacedThresholdFt, 230)
        XCTAssertEqual(rwy.heLatitude, 47.086899)
        XCTAssertEqual(rwy.heElevationFt, 3343)
        XCTAssertEqual(rwy.heDisplacedThresholdFt, 328)
        // OpenAIP's data: its "06" end lies under "05", so 06's TORA/LDA are 05's.
        XCTAssertEqual(rwy.pcn, "020/F/C/Y/T")
        XCTAssertEqual(rwy.leToraFt, feet(1059))
        XCTAssertEqual(rwy.leLdaFt, feet(1054))
        XCTAssertEqual(rwy.heToraFt, feet(1054))
        XCTAssertEqual(rwy.heLdaFt, feet(1059))
        XCTAssertEqual(rwy.leHeadingDegT, 54)
        XCTAssertEqual(rwy.heHeadingDegT, 234)
        XCTAssertEqual(rwy.lengthFt, feet(1090))
        XCTAssertEqual(rwy.widthFt, feet(27))
        XCTAssertEqual(rwy.surface, "Asphalt")
        // OpenAIP's stable id; OurAirports' airport reference (the merged airport keeps its id).
        XCTAssertEqual(rwy.id, try openAIPRunways("LSGC").first?.id)
        XCTAssertEqual(rwy.airportRef, 4489)
        // Without the override, the tie goes to OurAirports all the same.
        XCTAssertEqual(AirportDataMergeEngine.unionRunways(our: ourRunways("LSGC"), openAIP: try openAIPRunways("LSGC"))
                        .map(\.identifier), ["05/23"])
    }

    /// LSGE: both sources say 09/27. The match by key used to drop OurAirports' runway whole, thresholds
    /// and elevations with it; now they stay.
    func testLSGESameDesignatorsKeepOurAirportsThresholds() throws {
        let runways = try merged("LSGE")
        XCTAssertEqual(runways.map(\.identifier), ["09/27"])
        let rwy = runways[0]
        XCTAssertEqual(rwy.leLatitude, 46.755596)
        XCTAssertEqual(rwy.leLongitude, 7.070533)
        XCTAssertEqual(rwy.leElevationFt, 2281)
        XCTAssertEqual(rwy.heLongitude, 7.080964)
        XCTAssertEqual(rwy.heElevationFt, 2294)
        XCTAssertEqual(rwy.leHeadingDegT, 93, "OpenAIP's heading wins when it has one")
        XCTAssertEqual(rwy.pcn, "15/F/C/Y/T")
        XCTAssertEqual(rwy.lengthFt, feet(800))
    }

    /// LSGN: OpenAIP has the concrete 05/23 and a parallel grass 05R/23L; OurAirports only the concrete.
    /// The grass stays its own runway (its R can't meet the plain 05).
    func testLSGNParallelGrassStaysASeparateRunway() throws {
        let runways = try merged("LSGN")
        XCTAssertEqual(runways.map(\.identifier), ["05/23", "05R/23L"])
        XCTAssertEqual(runways[0].surface, "Concrete")
        XCTAssertEqual(runways[0].leElevationFt, 1434)      // OurAirports' elevations kept
        XCTAssertEqual(runways[0].heElevationFt, 1424)
        XCTAssertEqual(runways[0].leLdaFt, feet(670))
        XCTAssertEqual(runways[1].surface, "Grass")
        XCTAssertNil(runways[1].leElevationFt)              // OpenAIP-only: nothing to borrow
    }

    /// LSGY: OurAirports 04/22 + grass 05R/23L, OpenAIP 04/22 + grass 04R/22L. The grass strip is one
    /// runway, not a third: OurAirports gives it no heading, so it is matched by its R and a number one
    /// off, never onto the asphalt. The designators differ, so OurAirports' 05R/23L (which aip.aero lists).
    func testLSGYGrassParallelIsMatchedBySuffixNotOntoTheAsphalt() throws {
        let runways = try merged("LSGY")
        XCTAssertEqual(runways.map(\.identifier), ["04/22", "05R/23L"])
        let asphalt = runways[0], grass = runways[1]
        XCTAssertEqual(asphalt.surface, "Asphalt")
        XCTAssertEqual(asphalt.lengthFt, feet(872))
        XCTAssertEqual(asphalt.leLatitude, 46.759216)
        XCTAssertEqual(asphalt.heLongitude, 6.617386)
        XCTAssertEqual(grass.surface, "Grass")
        XCTAssertEqual(grass.lengthFt, feet(725))
        XCTAssertEqual(grass.leHeadingDegT, 47, "OpenAIP's heading fills OurAirports' gap")
        XCTAssertEqual(grass.leToraFt, feet(725))
    }

    /// LSTO: OurAirports 05/23 (no headings), OpenAIP 04/22 (044°T). A number one off with no heading to
    /// compare is the same strip; OurAirports' 05/23 is the one aip.aero and Wikidata list, and the
    /// magnetic heading (041°M) would have said 04: designators don't follow it.
    func testLSTODisagreementTakesOurAirportsDesignators() throws {
        let runways = try merged("LSTO")
        XCTAssertEqual(runways.map(\.identifier), ["05/23"])
        XCTAssertEqual(runways[0].leHeadingDegT, 44)
        XCTAssertEqual(runways[0].leToraFt, feet(506))
        XCTAssertEqual(runways[0].surface, "Grass")
    }

    /// Without headings, numbers one apart match round the compass (36 meets 01), either end first; two
    /// apart is another runway.
    func testMissingHeadingsMatchByAdjacentDesignator() {
        let openAIP = [runway("LSZX", "01", "19", leTora: 1000, heTora: 1900)]

        let straight = AirportDataMergeEngine.unionRunways(our: [runway("LSZX", "36", "18", leLatitude: 47.1)], openAIP: openAIP)
        XCTAssertEqual(straight.map(\.identifier), ["36/18"])
        XCTAssertEqual(straight[0].leToraFt, 1000, "OpenAIP's 01 lies under OurAirports' 36")
        XCTAssertEqual(straight[0].leLatitude, 47.1)

        let crossed = AirportDataMergeEngine.unionRunways(our: [runway("LSZX", "18", "36", leLatitude: 47.1)], openAIP: openAIP)
        XCTAssertEqual(crossed.map(\.identifier), ["18/36"])
        XCTAssertEqual(crossed[0].leToraFt, 1900, "OpenAIP's 19 lies under OurAirports' 18")
        XCTAssertEqual(crossed[0].leLatitude, 47.1)

        let twoOff = AirportDataMergeEngine.unionRunways(our: [runway("LSZX", "03", "21")], openAIP: openAIP)
        XCTAssertEqual(twoOff.map(\.identifier), ["01/19", "03/21"])
    }

    /// Parallels: L never meets R, even on the same heading; no suffix and C are the same thing.
    func testSuffixesKeepParallelsApart() {
        let leftRight = AirportDataMergeEngine.unionRunways(
            our: [runway("LSZX", "16L", "34R", heading: 160)], openAIP: [runway("LSZX", "16R", "34L", heading: 160)])
        XCTAssertEqual(leftRight.count, 2)

        let centre = AirportDataMergeEngine.unionRunways(
            our: [runway("LSZX", "16C", "34C", heading: 160)], openAIP: [runway("LSZX", "16", "34", heading: 161)])
        XCTAssertEqual(centre.map(\.identifier), ["16C/34C"])

        // Headings 20° apart are two runways, numbers one apart or not: a heading outranks the number.
        let apart = AirportDataMergeEngine.unionRunways(
            our: [runway("LSZX", "16", "34", heading: 160)], openAIP: [runway("LSZX", "15", "33", heading: 140)])
        XCTAssertEqual(apart.map(\.identifier), ["15/33", "16/34"])
    }

    /// LSGS: OurAirports marks its grass strip "07G/25G" (G for grass, not an ICAO suffix), OpenAIP
    /// "07L/25R". The G meets any suffix once the asphalt has its exact match, so the grass is one
    /// runway, and it takes OpenAIP's ICAO name over the G whatever the tie-break; the closed helipad
    /// stays as it was.
    func testLSGSOurAirportsGrassMarkerMeetsOpenAIPParallel() throws {
        let runways = try merged("LSGS")
        XCTAssertEqual(runways.map(\.identifier), ["07/25", "07L/25R", "HEL/?"])
        let grass = runways[1]
        XCTAssertEqual(grass.surface, "Grass")
        XCTAssertEqual(grass.lengthFt, feet(660))
        XCTAssertEqual(grass.leLatitude, 46.218498)
        XCTAssertEqual(grass.heDisplacedThresholdFt, 328)
        XCTAssertEqual(grass.heToraFt, feet(560))
        XCTAssertTrue(runways[2].closed)
    }

    /// LSZN: OurAirports has a grass 09L/27R that OpenAIP doesn't (OpenAIP's second "09"/"27" pair, the
    /// grass, gives way to the main one). The lone OurAirports runway is kept beside the merged asphalt.
    func testLoneOurAirportsRunwayIsKept() throws {
        let runways = try merged("LSZN")
        XCTAssertEqual(runways.map(\.identifier), ["09/27", "09L/27R"])
        XCTAssertEqual(runways[0].surface, "Asphalt")
        XCTAssertEqual(runways[0].leDisplacedThresholdFt, 328)
        XCTAssertEqual(runways[0].lengthFt, feet(700))
        XCTAssertEqual(runways[1].surface, "GRASS")
        XCTAssertEqual(runways[1].leLatitude, 47.238992)
        XCTAssertEqual(runways[1].heDisplacedThresholdFt, 644)
        XCTAssertNil(runways[1].pcn)
    }

    /// LSZG: OpenAIP lists "06"/"24" twice, the 700 m grass strip (its 06R/24L again) before the 1000 m
    /// main asphalt. The main entry is kept, whatever the order, so Grenchen's main runway is no longer
    /// the grass strip; with neither marked main, the longer one is.
    func testRepeatedOpenAIPDesignatorKeepsTheMainRunway() throws {
        let grass06 = #"{"designator": "06", "trueHeading": 64, "mainRunway": false, "surface": {"mainComposite": 2}, "dimension": {"length": {"value": 700, "unit": 0}, "width": {"value": 30, "unit": 0}}, "declaredDistance": {"tora": {"value": 618, "unit": 0}, "lda": {"value": 618, "unit": 0}}}"#
        let grass24 = #"{"designator": "24", "trueHeading": 244, "mainRunway": false, "surface": {"mainComposite": 2}, "dimension": {"length": {"value": 700, "unit": 0}, "width": {"value": 30, "unit": 0}}, "declaredDistance": {"tora": {"value": 618, "unit": 0}, "lda": {"value": 618, "unit": 0}}}"#
        let main06 = #"{"designator": "06", "trueHeading": 64, "mainRunway": true, "surface": {"mainComposite": 0, "pcn": "44/F/C/X/T"}, "dimension": {"length": {"value": 1000, "unit": 0}, "width": {"value": 23, "unit": 0}}, "declaredDistance": {"tora": {"value": 865, "unit": 0}, "lda": {"value": 865, "unit": 0}}}"#
        let main24 = #"{"designator": "24", "trueHeading": 244, "mainRunway": true, "surface": {"mainComposite": 0, "pcn": "44/F/C/X/T"}, "dimension": {"length": {"value": 1000, "unit": 0}, "width": {"value": 23, "unit": 0}}, "declaredDistance": {"tora": {"value": 865, "unit": 0}, "lda": {"value": 865, "unit": 0}}}"#
        let grenchen = { (runways: [String]) throws -> OpenAIPAirport in
            let json = """
            { "type": "FeatureCollection", "features": [ { "type": "Feature",
              "properties": { "_id": "6261519b5e9ded5710452fa2", "name": "GRENCHEN", "icaoCode": "LSZG", "type": 0, "country": "CH",
                "runways": [ \(runways.joined(separator: ", ")) ] },
              "geometry": { "type": "Point", "coordinates": [7.4172, 47.18163] } } ] }
            """
            return try XCTUnwrap(try OpenAIPAirport.parse(geoJSON: Data(json.utf8)).first)
        }

        // The export's order: the grass first.
        let field = try grenchen([grass06, grass24, main06, main24])
        let openAIP = AirportDataMergeEngine.openAIPRunways(from: [field])
        XCTAssertEqual(openAIP.map(\.identifier), ["06/24"])
        XCTAssertEqual(openAIP.first?.lengthFt, feet(1000))
        XCTAssertEqual(openAIP.first?.surface, "Asphalt")
        XCTAssertEqual(openAIP.first?.pcn, "44/F/C/X/T")
        XCTAssertEqual(openAIP.first?.leToraFt, feet(865))

        // Merged with OurAirports' asphalt 06/24: its thresholds on the main runway's data.
        let ourCSV = """
        "id","airport_ref","airport_ident","length_ft","width_ft","surface","lighted","closed","le_ident","le_latitude_deg","le_longitude_deg","le_elevation_ft","le_heading_degT","le_displaced_threshold_ft","he_ident","he_latitude_deg","he_longitude_deg","he_elevation_ft","he_heading_degT","he_displaced_threshold_ft"
        239130,4504,"LSZG",3281,75,"ASP",1,0,"06",47.179846,7.411427,1407,64,370,"24",47.183485,7.423203,1405,244,
        """
        let merged = AirportDataMergeEngine.unionRunways(our: AirportDataService.parseRunwaysCSV(ourCSV), openAIP: openAIP)
        XCTAssertEqual(merged.map(\.identifier), ["06/24"])
        XCTAssertEqual(merged.first?.lengthFt, feet(1000))
        XCTAssertEqual(merged.first?.surface, "Asphalt")
        XCTAssertEqual(merged.first?.leDisplacedThresholdFt, 370)

        // The main entry wins in either order; with no main entry, the longer one does.
        XCTAssertEqual(AirportDataMergeEngine.openAIPRunways(from: [try grenchen([main06, main24, grass06, grass24])])
                        .first?.lengthFt, feet(1000))
        let unmarked = [main06, main24].map { $0.replacingOccurrences(of: #""mainRunway": true"#, with: #""mainRunway": false"#) }
        XCTAssertEqual(AirportDataMergeEngine.openAIPRunways(from: [try grenchen([grass06, grass24] + unmarked)])
                        .first?.lengthFt, feet(1000))
    }

    /// LSPM: OpenAIP lists "10" and "27", not 18 apart, so they don't pair by designator; their true
    /// headings (104/284) are reciprocal, so they pair by heading. Against OurAirports' 11/29 that pair
    /// gets no vote, and the override (NOTAM B1662/26: RWY 10/28) has the last word.
    func testLSPMNonReciprocalOpenAIPPairIsOneRunwayViaTheOverride() throws {
        XCTAssertEqual(try openAIPRunways("LSPM").map(\.identifier), ["10/27"])
        XCTAssertEqual(AirportDataMergeEngine.unionRunways(our: ourRunways("LSPM"), openAIP: try openAIPRunways("LSPM"))
                        .map(\.identifier), ["11/29"])

        let runways = try merged("LSPM")
        XCTAssertEqual(runways.map(\.identifier), ["10/28"])
        XCTAssertEqual(runways[0].leLatitude, 46.51369)     // OurAirports' 11 end, now 10
        XCTAssertEqual(runways[0].heDisplacedThresholdFt, 405)
        XCTAssertEqual(runways[0].pcn, "35/F/B/X/T")
        XCTAssertEqual(runways[0].leToraFt, feet(1120))
    }

    /// Same ICAO, more than 1 NM apart: two fields. The OpenAIP one's runways must not land on OurAirports'
    /// (they were unioned by ident before). An appended OpenAIP-only field keeps its runways.
    func testAirportsFarApartDoNotShareRunways() throws {
        let field = { (lon: Double, lat: Double, le: String, he: String, heading: Int) -> Data in
            """
            {"type":"FeatureCollection","features":[{"type":"Feature",
              "properties":{"_id":"oaip-lszb","name":"BERN-BELP","icaoCode":"LSZB","type":3,"country":"CH",
                "runways":[{"designator":"\(le)","trueHeading":\(heading),"mainRunway":true},
                           {"designator":"\(he)","trueHeading":\(heading + 180),"mainRunway":true}]},
              "geometry":{"type":"Point","coordinates":[\(lon),\(lat)]}}]}
            """.data(using: .utf8)!
        }
        let ourBern = [ourAirport(id: 100, ident: "LSZB", lat: 46.914, lon: 7.497, name: "Bern Belp")]
        let ourBernRunways = ["LSZB": [runway("LSZB", "14", "32", heading: 140, leLatitude: 46.91931)]]

        // ~150 NM away: kept apart, so nothing of it reaches Bern.
        let far = try OpenAIPAirport.parse(geoJSON: field(9.5, 48.5, "08", "26", 80))
        let farOutcome = AirportDataMergeEngine.mergeOutcome(ourAirports: ourBern, openAIP: far)
        XCTAssertTrue(farOutcome.foldedOpenAIPIds.isEmpty)
        XCTAssertNil(AirportDataMergeEngine.mergedRunways(
            ourRunwaysByIdent: ourBernRunways, openAIP: far, foldedOpenAIPIds: farOutcome.foldedOpenAIPIds)["LSZB"])

        // The real Bern: matched, so its runway merges into one.
        let near = try OpenAIPAirport.parse(geoJSON: field(7.4971, 46.9141, "14", "32", 140))
        let nearOutcome = AirportDataMergeEngine.mergeOutcome(ourAirports: ourBern, openAIP: near)
        XCTAssertEqual(nearOutcome.foldedOpenAIPIds, ["oaip-lszb"])
        let nearRunways = AirportDataMergeEngine.mergedRunways(
            ourRunwaysByIdent: ourBernRunways, openAIP: near, foldedOpenAIPIds: nearOutcome.foldedOpenAIPIds)["LSZB"]
        XCTAssertEqual(nearRunways?.map(\.identifier), ["14/32"])
        XCTAssertEqual(nearRunways?.first?.leLatitude, 46.91931)

        // No OurAirports field under that ident: the OpenAIP one is appended, with its runways.
        let alone = AirportDataMergeEngine.mergeOutcome(ourAirports: [], openAIP: far)
        XCTAssertEqual(AirportDataMergeEngine.mergedRunways(
            ourRunwaysByIdent: [:], openAIP: far, foldedOpenAIPIds: alone.foldedOpenAIPIds)["LSZB"]?.map(\.identifier),
                       ["08/26"])
    }

    /// The frequencies follow the airports: a same-ICAO OpenAIP field more than 1 NM away keeps its
    /// frequencies to itself (they were joined by ident before); a matched one is unioned, OpenAIP winning
    /// a type both list; an appended one brings its own.
    func testAirportsFarApartDoNotShareFrequencies() throws {
        let field = { (lon: Double, lat: Double) -> [OpenAIPAirport] in
            try OpenAIPAirport.parse(geoJSON: Data("""
            {"type":"FeatureCollection","features":[{"type":"Feature",
              "properties":{"_id":"oaip-lszb","name":"BERN-BELP","icaoCode":"LSZB","type":3,"country":"CH",
                "frequencies":[{"name":"BERN TOWER","value":"121.030","type":14}]},
              "geometry":{"type":"Point","coordinates":[\(lon),\(lat)]}}]}
            """.utf8))
        }
        let ourBern = [ourAirport(id: 100, ident: "LSZB", lat: 46.914, lon: 7.497, name: "Bern Belp")]
        let ourFreqs = ["LSZB": [
            AirportFrequency(id: 1, airportRef: 100, airportIdent: "LSZB", type: "TWR", description: "BERN TOWER", frequencyMhz: 121.025),
            AirportFrequency(id: 2, airportRef: 100, airportIdent: "LSZB", type: "GND", description: "BERN GROUND", frequencyMhz: 121.755),
        ]]

        let far = try field(9.5, 48.5)
        let farOutcome = AirportDataMergeEngine.mergeOutcome(ourAirports: ourBern, openAIP: far)
        XCTAssertNil(AirportDataMergeEngine.mergedFrequencies(
            ourFrequenciesByIdent: ourFreqs, openAIP: far, foldedOpenAIPIds: farOutcome.foldedOpenAIPIds)["LSZB"])

        let near = try field(7.4971, 46.9141)
        let nearOutcome = AirportDataMergeEngine.mergeOutcome(ourAirports: ourBern, openAIP: near)
        let merged = try XCTUnwrap(AirportDataMergeEngine.mergedFrequencies(
            ourFrequenciesByIdent: ourFreqs, openAIP: near, foldedOpenAIPIds: nearOutcome.foldedOpenAIPIds)["LSZB"])
        XCTAssertEqual(merged.map(\.type), ["TWR", "GND"])
        XCTAssertEqual(merged[0].frequencyMhz, 121.030, accuracy: 0.0005, "OpenAIP wins the TWR")

        let alone = AirportDataMergeEngine.mergeOutcome(ourAirports: [], openAIP: far)
        XCTAssertEqual(AirportDataMergeEngine.mergedFrequencies(
            ourFrequenciesByIdent: [:], openAIP: far, foldedOpenAIPIds: alone.foldedOpenAIPIds)["LSZB"]?.map(\.type),
                       ["TWR"])
    }

    /// The readers see one LSGC runway: the wind pick, the planning summary and the editor's runway ends
    /// (which offered 05, 06, 23 and 24 before).
    func testSuggestRunwayAndSummarySeeOneLSGCRunway() throws {
        let runways = try merged("LSGC")
        XCTAssertEqual(AirportDataService.suggestRunway(among: runways, windDirection: 240)?.identifier, "05/23")
        XCTAssertEqual(AirportDataService.suggestRunway(among: runways, windDirection: nil)?.identifier, "05/23")
        let summary = try XCTUnwrap(AirportDataService.runwaySummary(of: runways))
        XCTAssertTrue(summary.hasPrefix("05/23 · "), summary)
        XCTAssertTrue(summary.hasSuffix(" · Asphalt"), summary)
        XCTAssertEqual(Set(runways.flatMap { [$0.leIdent, $0.heIdent] }.compactMap { $0 }), ["05", "23"])
    }

    /// The vote, with the third source (open flightmaps, a later 6.2.0 PR) already counted: two that agree
    /// win; all different goes to OurAirports, then OpenAIP; "9/27", "09/27" and "27/09" agree; a pair
    /// that isn't reciprocal only votes when nothing else does.
    func testMajorityDesignatorsWithThreeVotes() {
        typealias Vote = AirportDataMergeEngine.RunwayDesignatorVote
        let pick = { (votes: [Vote]) in AirportDataMergeEngine.majorityDesignators(votes) }
        let our = { (le: String?, he: String?) in Vote(source: .ourAirports, leIdent: le, heIdent: he) }
        let openAIP = { (le: String?, he: String?) in Vote(source: .openAIP, leIdent: le, heIdent: he) }
        let ofm = { (le: String?, he: String?) in Vote(source: .openFlightmaps, leIdent: le, heIdent: he) }

        XCTAssertEqual(pick([our("11", "29"), openAIP("10", "28"), ofm("10", "28")]), openAIP("10", "28"))
        XCTAssertEqual(pick([our("05", "23"), openAIP("06", "24"), ofm("04", "22")]), our("05", "23"))
        XCTAssertEqual(pick([openAIP("06", "24"), ofm("04", "22")]), openAIP("06", "24"))
        XCTAssertEqual(pick([our("05", "23"), openAIP("06", "24")]), our("05", "23"))     // two sources: a tie
        XCTAssertEqual(pick([ofm("28", "10"), openAIP("9", "27"), our("09", "27")]), our("09", "27"))
        XCTAssertEqual(pick([our("07", nil), openAIP("07", "25"), ofm("08", "26")]), our("07", nil))
        XCTAssertEqual(pick([our("11", "29"), openAIP("10", "27"), ofm("10", "27")]), our("11", "29"))
        XCTAssertEqual(pick([openAIP("10", "27")]), openAIP("10", "27"))
        // A suffix ICAO doesn't have (OurAirports' G for grass) loses to an ICAO form, even outnumbering it.
        XCTAssertEqual(pick([our("07G", "25G"), openAIP("07L", "25R")]), openAIP("07L", "25R"))
        XCTAssertEqual(pick([our("07G", "25G"), openAIP("07L", "25R"), ofm("07G", "25G")]), openAIP("07L", "25R"))
        XCTAssertEqual(pick([our("07G", "25G")]), our("07G", "25G"))
        XCTAssertNil(pick([]))
    }

    /// Override entry LSGC (the author): OpenAIP alone says 06/24; the override renames that runway 05/23
    /// and its ends keep their data.
    func testOverrideLSGCRenamesOpenAIPsRunway() throws {
        let openAIPOnly = AirportDataMergeEngine.mergedRunways(
            ourRunwaysByIdent: [:], openAIP: [try openAIPField("LSGC")], foldedOpenAIPIds: [try openAIPField("LSGC").id])
        let rwy = try XCTUnwrap(openAIPOnly["LSGC"]?.first)
        XCTAssertEqual(rwy.identifier, "05/23")
        XCTAssertEqual(rwy.leToraFt, feet(1059))   // was 06's
        XCTAssertEqual(rwy.leHeadingDegT, 54)
    }

    /// Override entry LSPM (NOTAM B1662/26): OurAirports alone, as loaded without OpenAIP, says 11/29 and
    /// has no headings; the override finds it by number and renames it 10/28. A runway listed the other
    /// way round is turned round first; a closed one is left alone.
    func testOverrideLSPMRenamesOurAirportsRunway() {
        let fixed = RunwayDesignatorOverrides.apply(to: ourRunways("LSPM"), ident: "LSPM")
        XCTAssertEqual(fixed.map(\.identifier), ["10/28"])
        XCTAssertEqual(fixed[0].leLatitude, 46.51369)

        let reversed = RunwayDesignatorOverrides.apply(
            to: [runway("LSPM", "28", "10", heading: 284, leLatitude: 46.511032, leTora: 900)], ident: "LSPM")
        XCTAssertEqual(reversed.map(\.identifier), ["10/28"])
        XCTAssertEqual(reversed[0].heLatitude, 46.511032)
        XCTAssertEqual(reversed[0].heToraFt, 900)

        let closed = [runway("LSPM", "11", "29", closed: true)]
        XCTAssertEqual(RunwayDesignatorOverrides.apply(to: closed, ident: "LSPM"), closed)
    }

    /// Every entry is usable and documented (it is checked each quarter), and the table leaves every other
    /// airport alone.
    func testOverrideEntriesAreWellFormed() {
        XCTAssertFalse(RunwayDesignatorOverrides.entries.isEmpty)
        for entry in RunwayDesignatorOverrides.entries {
            XCTAssertEqual(entry.icao.count, 4, entry.icao)
            let le = AirportDataMergeEngine.parseDesignator(entry.leIdent)
            let he = AirportDataMergeEngine.parseDesignator(entry.heIdent)
            XCTAssertEqual((le?.number).map { ($0 + 17) % 36 + 1 }, he?.number, "\(entry.icao): ends must be reciprocal")
            XCTAssertTrue((0.0..<360.0).contains(entry.leTrueHeading), entry.icao)
            XCTAssertFalse(entry.source.isEmpty, entry.icao)
            XCTAssertNotNil(entry.checked.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression), entry.icao)
        }
        XCTAssertEqual(RunwayDesignatorOverrides.idents, ["LSGC", "LSPM"])
        let lsge = ourRunways("LSGE")
        XCTAssertEqual(RunwayDesignatorOverrides.apply(to: lsge, ident: "LSGE"), lsge)
    }
}

/// OpenAIP must be usable as a STANDALONE dataset, not only as an enrichment of OurAirports.
///
/// Reported from device testing: with OurAirports not downloaded but OpenAIP present for the
/// pilot's country, the app showed no airports and no frequencies at all. Two independent blockers
/// treated OurAirports as mandatory — `applyOpenAIPMergeIfAvailable` early-returned on an empty
/// backbone so the merge never ran, and `isDataAvailable` (which every frequency/airport surface
/// gates on) was only ever set by OurAirports. The merge engine itself was always capable of it.
final class OpenAIPStandaloneMergeTests: XCTestCase {

    private let openAIPJSON = """
    { "type": "FeatureCollection", "features": [
      { "type": "Feature",
        "properties": { "_id": "s1", "name": "BERN-BELP", "icaoCode": "LSZB", "type": 3, "country": "CH",
          "frequencies": [ { "name": "BERN TOWER", "value": "121.030", "type": 14 } ] },
        "geometry": { "type": "Point", "coordinates": [7.4971, 46.9141] } },
      { "type": "Feature",
        "properties": { "_id": "s2", "name": "GENEVA", "icaoCode": "LSGG", "type": 3, "country": "CH" },
        "geometry": { "type": "Point", "coordinates": [6.1089, 46.2381] } }
    ] }
    """.data(using: .utf8)!

    /// The case that was broken: an EMPTY OurAirports backbone must still yield every OpenAIP field.
    func testMergeWithEmptyBackboneYieldsTheOpenAIPAirports() throws {
        let openAIP = try OpenAIPAirport.parse(geoJSON: openAIPJSON)

        let merged = AirportDataMergeEngine.merge(ourAirports: [], openAIP: openAIP)

        XCTAssertEqual(merged.count, 2, "OpenAIP alone must produce a usable airport set")
        XCTAssertEqual(Set(merged.map(\.ident)), ["LSZB", "LSGG"])
    }

    /// Frequencies are the reason this mattered in the field — the FREQ panel had nothing to show.
    func testFrequenciesSurviveAMergeWithNoBackbone() throws {
        let openAIP = try OpenAIPAirport.parse(geoJSON: openAIPJSON)

        let freqs = AirportDataMergeEngine.openAIPFrequencies(from: openAIP)

        let bern = freqs.filter { $0.airportIdent == "LSZB" }
        XCTAssertFalse(bern.isEmpty, "OpenAIP frequencies must be available without OurAirports")
        XCTAssertTrue(bern.contains { abs($0.frequencyMhz - 121.030) < 0.0005 })
    }

    /// Guards the honest limitation: OpenAIP records with no ICAO code are skipped by the merge, so
    /// an OpenAIP-only dataset covers ICAO-coded fields only. Documented, not accidental.
    func testOpenAIPRecordsWithoutIcaoAreStillSkipped() throws {
        let noIcao = """
        { "type": "FeatureCollection", "features": [
          { "type": "Feature", "properties": { "_id": "n1", "name": "STRIP", "type": 2, "country": "CH" },
            "geometry": { "type": "Point", "coordinates": [7.0, 46.5] } }
        ] }
        """.data(using: .utf8)!

        let merged = AirportDataMergeEngine.merge(
            ourAirports: [], openAIP: try OpenAIPAirport.parse(geoJSON: noIcao))

        XCTAssertTrue(merged.isEmpty, "no ICAO code means no merge key — a known limitation")
    }
}

/// An OpenAIP aerodrome download reaches the merged airport store at once, whichever screen started
/// it, and a delete takes the aerodromes out again. Both used to wait for the next launch, the only
/// time the merge ran. The store's load, merge and download passes run one at a time. (6.2.0)
@MainActor
final class OpenAIPAirportDownloadMergeTests: XCTestCase {

    /// What the fake OpenAIP export serves; changed between downloads.
    private final class Export {
        var features: [String: [String]] = [:]   // country → features
        var failing: Set<String> = []
        private(set) var fetches = 0

        func fetch(_ country: String) throws -> [OpenAIPAirport] {
            fetches += 1
            if failing.contains(country) { throw URLError(.notConnectedToInternet) }
            let json = #"{ "type": "FeatureCollection", "features": [\#((features[country] ?? []).joined(separator: ","))] }"#
            return try OpenAIPAirport.parse(geoJSON: Data(json.utf8))
        }
    }

    private func feature(_ id: String, _ icao: String, _ name: String, lon: Double, lat: Double,
                         tower: String) -> String {
        """
        { "type": "Feature",
          "properties": { "_id": "\(id)", "name": "\(name)", "icaoCode": "\(icao)", "type": 3, "country": "CH",
            "frequencies": [ { "name": "\(name) TOWER", "value": "\(tower)", "type": 14 } ] },
          "geometry": { "type": "Point", "coordinates": [\(lon), \(lat)] } }
        """
    }

    private func bern(tower: String) -> String {
        feature("b", "LSZB", "BERN-BELP", lon: 7.4971, lat: 46.9141, tower: tower)
    }

    private let eplatures = #"{ "type": "Feature", "properties": { "_id": "j", "name": "LES EPLATURES", "icaoCode": "LSGC", "type": 2, "country": "CH" }, "geometry": { "type": "Point", "coordinates": [6.7929, 47.0839] } }"#

    private func layer(_ export: Export) -> OpenAIPAirportDataService {
        makeTestOpenAIPAirportLayer { try export.fetch($0) }
    }

    /// OurAirports on disk, as a download leaves it: Bern and Grenchen, no frequencies.
    private func writeOurAirports(into root: URL) throws {
        func airport(_ id: Int, _ ident: String, _ name: String, lat: Double, lon: Double) -> Airport {
            Airport(id: id, ident: ident, type: .mediumAirport, name: name, latitude: lat, longitude: lon,
                    elevation: 1500, continent: "EU", isoCountry: "CH", isoRegion: "CH-BE", municipality: nil,
                    scheduledService: false, gpsCode: ident, iataCode: nil, localCode: nil)
        }
        let directory = root.appendingPathComponent("AirportData", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([airport(1, "LSZB", "Bern Airport", lat: 46.9141, lon: 7.4971),
                                  airport(2, "LSZG", "Grenchen Airport", lat: 47.1816, lon: 7.4172)])
            .write(to: directory.appendingPathComponent("airports.json"))
    }

    private func frequencies(_ store: AirportDataService, _ ident: String) -> [String] {
        store.getFrequencies(for: ident).map { String(format: "%.3f", $0.frequencyMhz) }.sorted()
    }

    func testADownloadReachesTheLoadedStoreAndADeleteTakesItOut() async throws {
        let export = Export()
        export.features["CH"] = [bern(tower: "121.030"), eplatures]
        let openAIP = layer(export)
        let root = makeTestDirectory()
        try writeOurAirports(into: root)
        let store = makeTestAirportStore(openAIPAirports: openAIP, root: root)
        store.followOpenAIPAirports()
        await store.ensureLoaded()
        XCTAssertEqual(store.findAirport(byIdent: "LSZB")?.name, "Bern Airport", "OurAirports alone, before any OpenAIP download")
        XCTAssertNil(store.findAirport(byIdent: "LSGC"))

        // The download page calls the service itself.
        await openAIP.downloadData(for: ["CH"])
        await store.waitForPendingPasses()
        XCTAssertEqual(store.findAirport(byIdent: "LSZB")?.name, "BERN-BELP", "OpenAIP wins, without a relaunch")
        XCTAssertEqual(frequencies(store, "LSZB"), ["121.030"])
        XCTAssertEqual(store.findAirport(byIdent: "LSGC")?.name, "LES EPLATURES", "a field only OpenAIP has")
        XCTAssertEqual(store.findAirport(byIdent: "LSZG")?.name, "Grenchen Airport", "OurAirports fills the gaps")
        XCTAssertFalse(openAIP.isLoaded, "the merge consumed and released the OpenAIP array")

        // Data & Storage and the foreground refresh go through the provider. The tower moved, and
        // OpenAIP dropped Les Eplatures: rebuilt from the backbone, the store drops it too.
        export.features["CH"] = [bern(tower: "121.035")]
        await OpenAIPAirportProvider(service: openAIP).refresh()
        await store.waitForPendingPasses()
        XCTAssertEqual(frequencies(store, "LSZB"), ["121.035"])
        XCTAssertNil(store.findAirport(byIdent: "LSGC"), "not merged on top of the last merge")
        XCTAssertEqual(store.airportCount, 2)

        // A delete takes OpenAIP's fields and frequencies out, OurAirports stays.
        openAIP.deleteData()
        await store.waitForPendingPasses()
        XCTAssertEqual(store.findAirport(byIdent: "LSZB")?.name, "Bern Airport")
        XCTAssertEqual(frequencies(store, "LSZB"), [])
        XCTAssertEqual(store.findAirport(byIdent: "LSZG")?.name, "Grenchen Airport")
        XCTAssertTrue(store.isDataAvailable)
    }

    /// Before the store is loaded (it loads lazily), a download fills it with OpenAIP's fields alone,
    /// as the launch merge does; the load then brings OurAirports in under them.
    func testADownloadBeforeTheLoadFillsTheLazyStore() async throws {
        let export = Export()
        export.features["CH"] = [bern(tower: "121.030")]
        let openAIP = layer(export)
        let root = makeTestDirectory()
        try writeOurAirports(into: root)
        let store = makeTestAirportStore(openAIPAirports: openAIP, root: root)
        store.followOpenAIPAirports()

        await openAIP.downloadData(for: ["CH"])
        await store.waitForPendingPasses()
        XCTAssertEqual(store.findAirport(byIdent: "LSZB")?.name, "BERN-BELP")
        XCTAssertNil(store.findAirport(byIdent: "LSZG"), "OurAirports is not loaded yet")

        await store.ensureLoaded()
        XCTAssertEqual(store.findAirport(byIdent: "LSZB")?.name, "BERN-BELP")
        XCTAssertEqual(store.findAirport(byIdent: "LSZG")?.name, "Grenchen Airport")
        XCTAssertEqual(frequencies(store, "LSZB"), ["121.030"])
    }

    /// A download that updated nothing doesn't reload the airport database, and says which countries
    /// failed until a download serves them.
    func testOnlyADownloadThatUpdatedSomethingReloadsTheStore() async {
        let export = Export()
        export.failing = ["CH"]
        let openAIP = layer(export)
        var changes = 0
        openAIP.onAirportsChanged = { changes += 1 }

        await openAIP.downloadData(for: ["CH"])
        XCTAssertEqual(openAIP.failedCountries, ["CH"])
        XCTAssertEqual(changes, 0)

        export.failing = []
        export.features["CH"] = [bern(tower: "121.030")]
        await openAIP.downloadData(for: ["CH"])
        XCTAssertEqual(openAIP.failedCountries, [])
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(openAIP.pprIcaoCodes, [])
        XCTAssertTrue(openAIP.hasPPRData)

        openAIP.deleteData()
        XCTAssertEqual(changes, 2, "a delete changes them too")
        XCTAssertFalse(openAIP.hasPPRData, "no PPR answer survives the data it came from")
    }

    /// Two passes never interleave: the second starts once the first has finished, across its
    /// suspension points.
    func testStorePassesRunOneAtATime() async {
        let store = makeTestAirportStore(openAIPAirports: layer(Export()))
        var log: [String] = []
        let first = store.enqueuePass {
            log.append("first starts")
            try? await Task.sleep(nanoseconds: 50_000_000)
            log.append("first ends")
        }
        let second = store.enqueuePass { log.append("second") }
        await second.value
        await first.value
        XCTAssertEqual(log, ["first starts", "first ends", "second"])
    }

    /// Loads, merges and a download started together leave one consistent store.
    func testConcurrentLoadsMergesAndADownloadAgree() async throws {
        let export = Export()
        export.features["CH"] = [bern(tower: "121.030"), eplatures]
        let openAIP = layer(export)
        let root = makeTestDirectory()
        try writeOurAirports(into: root)
        let store = makeTestAirportStore(openAIPAirports: openAIP, root: root)
        store.followOpenAIPAirports()

        async let load: Void = store.ensureLoaded()
        async let merge: Void = store.applyOpenAIPMergeIfAvailable()
        async let download: Void = openAIP.downloadData(for: ["CH"])
        async let secondLoad: Void = store.ensureLoaded()
        _ = await (load, merge, download, secondLoad)
        await store.waitForPendingPasses()

        XCTAssertEqual(store.airportCount, 3)
        XCTAssertEqual(store.findAirport(byIdent: "LSZB")?.name, "BERN-BELP")
        XCTAssertEqual(store.findAirport(byIdent: "LSZG")?.name, "Grenchen Airport")
        XCTAssertEqual(frequencies(store, "LSZB"), ["121.030"])
        XCTAssertEqual(store.findNearestAirports(to: CLLocationCoordinate2D(latitude: 46.9141, longitude: 7.4971),
                                                 limit: 5).filter { $0.ident == "LSZB" }.count, 1,
                       "one Bern in the spatial index")
    }
}
