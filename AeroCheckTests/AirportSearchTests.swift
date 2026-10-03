import XCTest
import CoreLocation
@testable import AeroCheck

/// The aerodrome search every planning screen shares (Add a stop, Plan new flight's stops and "Land
/// somewhere else", the home aerodrome field, the builder's airfield search): `AirportSearchIndex`
/// and `AirportDataService.search`. (6.1)
///
/// The author's report, on LSZQ → LSGC: "LSGE" and "Geneve" found nothing. The fixture is the real
/// OurAirports rows for the fields involved (2026-10-02), read through the app's own parser, plus
/// two made-up ones marked as such.
final class AirportSearchTests: XCTestCase {

    private static let csv = """
    "id","ident","type","name","latitude_deg","longitude_deg","elevation_ft","continent","iso_country","iso_region","municipality","scheduled_service","icao_code","iata_code","gps_code","local_code","home_link","wikipedia_link","keywords"
    300136,"LSZQ","small_airport","Bressaucourt Airfield",47.392408,7.028956,1866,"EU","CH","CH-JU","Bressaucourt","no","LSZQ",,"LSZQ",,"https://aerojura.ch/",,
    4489,"LSGC","medium_airport","Les Eplatures Airport",47.083900451699996,6.792840003970001,3368,"EU","CH","CH-NE","La Chaux-de-Fonds","no","LSGC",,"LSGC",,,,
    29495,"LSGE","small_airport","Ecuvillens Airfield",46.755279,7.075746,2293,"EU","CH","CH-FR","Ecuvillens","no","LSGE",,"LSGE",,,,
    4490,"LSGG","large_airport","Geneva International Airport",46.238098,6.10895,1411,"EU","CH","CH-GE","Geneva","yes","LSGG","GVA","LSGG",,,,"Cointrin Airport"
    315959,"FR-0332","small_airport","Fournet ULM",47.177389,6.812911,2874,"EU","FR","FR-BFC","Fournet-Blancheroche","no",,,,"LF2553",,,"Club ULM Haut Doubs, ULM Fournet"
    29497,"LSGN","small_airport","Neuchâtel Airfield",46.957371,6.864574,1427,"EU","CH","CH-NE","Boudry","no","LSGN",,"LSGN",,,,
    4505,"LSZH","large_airport","Zürich Airport",47.458056,8.548056,1417,"EU","CH","CH-ZH","Zurich","yes","LSZH","ZRH","LSZH",,,,
    4494,"LSMD","medium_airport","Dübendorf Air Base",47.398602,8.64823,1470,"EU","CH","CH-ZH","Zurich","no","LSMD",,"LSMD",,,,
    4503,"LSZB","medium_airport","Bern Airport",46.912736,7.498819,1671,"EU","CH","CH-BE","Bern","yes","LSZB","BRN","LSZB",,,,"LSZB, Belp, Bern-Belp"
    4504,"LSZG","medium_airport","Grenchen Airfield",47.181599,7.41719,1411,"EU","CH","CH-SO","Grenchen","no","LSZG",,"LSZG",,,,
    29521,"LSZJ","small_airport","Courtelary Airfield",47.183374,7.09085,2247,"EU","CH","CH-BE","Courtelary","no","LSZJ",,"LSZJ",,,,
    30085,"LDLO","small_airport","Lošinj Airport",44.566985,14.393883,151,"EU","HR","HR-08","Mali Lošinj","no","LDLO","LSZ","LDLO",,,,"Lussinpiccolo"
    18640,"K33J","small_airport","Geneva Municipal Airport",31.052579,-85.868715,101,"NA","US","US-AL","Geneva","no",,,"K33J","33J",,,
    316432,"CH-0002","small_airport","Croix de Coeur Altiport",46.123348,7.234131,7087,"EU","CH","CH-VS","Riddes","no","LSYQ",,,,,,"Altiport de Croix de Coeur, Altiport de Verbier"
    900001,"CH-9001","heliport","Geneva Hospital Heliport",46.19,6.15,,"EU","CH","CH-GE","Geneva","no",,,,,,,
    900002,"CH-9002","small_airport","LSGC Fan Club Strip",47.39,7.03,1800,"EU","CH","CH-JU","Bressaucourt","no",,,,,,,
    """

    private lazy var airports = AirportDataService.parseAirportsCSV(Self.csv)
    private lazy var index = AirportSearchIndex(airports)

    /// LSZQ, the departure of the author's trip: what Add a stop sorts by.
    private let lszq = CLLocationCoordinate2D(latitude: 47.392408, longitude: 7.028956)

    private func search(_ query: String, limit: Int = 8, near: CLLocationCoordinate2D? = nil,
                        types: Set<AirportType>? = AirportType.fixedWing) -> [String] {
        AirportDataService.search(airports, index: index, query: query, limit: limit, near: near, types: types)
            .map(\.ident)
    }

    // MARK: - The report

    func testTheFixtureParsed() {
        XCTAssertEqual(airports.count, 16)
        XCTAssertEqual(airports.first { $0.ident == "LSGG" }?.keywords, "Cointrin Airport")
        XCTAssertEqual(airports.first { $0.ident == "CH-0002" }?.keywords,
                       "Altiport de Croix de Coeur, Altiport de Verbier, LSYQ",
                       "the ICAO code the ident isn't is searchable")
        XCTAssertNil(airports.first { $0.ident == "LSGE" }?.keywords)
    }

    func testLSGEIsFoundByItsIdent() {
        XCTAssertEqual(search("LSGE", near: lszq), ["LSGE"])
        XCTAssertEqual(search("lsge", near: lszq), ["LSGE"])
    }

    func testGenevaIsFoundByEveryNameAPilotTypes() {
        for name in ["Geneve", "Genève", "genève", "GENEVE", "Genf", "Geneva", "Ginevra", "GVA", "Cointrin"] {
            XCTAssertEqual(search(name, near: lszq).first, "LSGG", name)
        }
        XCTAssertEqual(search("Genf"), ["LSGG"], "Genf is Geneva in Switzerland only, not in Alabama")
        XCTAssertEqual(search("Geneva", limit: 5), ["LSGG", "K33J"], "the airport before the Alabama strip")
    }

    // MARK: - Ranking

    func testAnExactIdentAlwaysComesFirst() {
        XCTAssertEqual(search("LSGC", near: lszq), ["LSGC", "CH-9002"],
                       "the field itself before a nearer one with the code in its name")
        XCTAssertEqual(search("LSZQ", near: lszq).first, "LSZQ")
    }

    /// "LSZ" is also Lošinj's IATA code: same rank as an ident starting so, and the distance decides.
    func testAnIdentStartAndAnotherCodeShareTheirRank() {
        XCTAssertEqual(search("LSZ", near: lszq), ["LSZQ", "LSZJ", "LSZG", "LSZB", "LSZH", "LDLO"])
        XCTAssertEqual(search("GVA", near: lszq), ["LSGG"])
    }

    func testAWordStartBeatsAWordMiddle() {
        // "bern" starts Bern Airport's words; nothing else holds it
        XCTAssertEqual(search("Bern", near: lszq).first, "LSZB")
        XCTAssertEqual(search("Berne", near: lszq), ["LSZB"], "its French name")
    }

    // MARK: - Folding

    func testNamesMatchWhateverTheCaseAndTheAccents() {
        XCTAssertEqual(search("Neuchatel"), ["LSGN"])
        XCTAssertEqual(search("NEUCHÂTEL"), ["LSGN"])
        XCTAssertEqual(search("Zürich", near: lszq), ["LSZH", "LSMD"])
        XCTAssertEqual(search("Zuerich", near: lszq), ["LSZH", "LSMD"])
        XCTAssertEqual(search("dubendorf"), ["LSMD"])
        XCTAssertEqual(search("losinj"), ["LDLO"])
    }

    func testWordsMatchInAnyOrderWhereverTheHyphensAre() {
        XCTAssertEqual(search("chaux de fonds"), ["LSGC"])
        XCTAssertEqual(search("La Chaux-de-Fonds"), ["LSGC"])
        XCTAssertEqual(search("fonds chaux"), ["LSGC"])
        XCTAssertEqual(search("Eplatures"), ["LSGC"])
    }

    func testKeywordsAndOtherCodesAreSearched() {
        XCTAssertEqual(search("Belp"), ["LSZB"])
        XCTAssertEqual(search("Verbier"), ["CH-0002"])
        XCTAssertEqual(search("LSYQ"), ["CH-0002"])
        XCTAssertEqual(search("LF2553"), ["FR-0332"], "a local code")
        XCTAssertEqual(search("Fournet"), ["FR-0332"])
    }

    func testFoldingSpellsOutTheLettersFoundationLeavesAlone() {
        XCTAssertEqual(AirportSearchText.folded("Ærøskøbing Łódź"), "aeroskobing lodz")
        XCTAssertEqual(AirportSearchText.folded("St. Gallen-Altenrhein"), "st gallen altenrhein")
        XCTAssertEqual(AirportSearchText.folded("Straße"), "strasse")
        XCTAssertEqual(AirportSearchText.folded("Gene\u{301}ve"), "geneve", "an accent written apart")
        XCTAssertEqual(AirportSearchText.folded("  -- "), "")
    }

    // MARK: - Filters and edges

    func testTheTypeFilterLeavesHeliportsOut() {
        XCTAssertFalse(search("Geneva", limit: 20).contains("CH-9001"))
        XCTAssertTrue(search("Geneva", limit: 20, types: nil).contains("CH-9001"))
    }

    func testNothingTypedFindsNothing() {
        XCTAssertEqual(search(""), [])
        XCTAssertEqual(search(" - "), [])
        XCTAssertEqual(search("zzzz"), [])
    }

    func testAnIndexBuiltFromOtherAirportsFindsNothing() {
        let stale = AirportSearchIndex(Array(airports.prefix(3)))
        XCTAssertEqual(AirportDataService.search(airports, index: stale, query: "LSGE"), [])
    }

    // MARK: - Data written before 6.1

    /// The cache an earlier build wrote (`airports.json`) has no `keywords`: it still loads, and the
    /// names in other languages work from it, until the next download brings the keywords.
    func testACacheWrittenBeforeKeywordsStillLoadsAndSearches() throws {
        let previous = """
        [{"id":4490,"ident":"LSGG","type":"large_airport","name":"Geneva International Airport",
          "latitude":46.238098,"longitude":6.10895,"elevation":1411,"continent":"EU","isoCountry":"CH",
          "isoRegion":"CH-GE","municipality":"Geneva","scheduledService":true,"gpsCode":"LSGG","iataCode":"GVA"},
         {"id":29495,"ident":"LSGE","type":"small_airport","name":"Ecuvillens Airfield","latitude":46.755279,
          "longitude":7.075746,"elevation":2293,"continent":"EU","isoCountry":"CH","isoRegion":"CH-FR",
          "municipality":"Ecuvillens","scheduledService":false,"gpsCode":"LSGE"}]
        """
        let cached = try JSONDecoder().decode([Airport].self, from: Data(previous.utf8))
        XCTAssertEqual(cached.map(\.ident), ["LSGG", "LSGE"])
        XCTAssertNil(cached[0].keywords)
        let index = AirportSearchIndex(cached)
        let find = { (query: String) in AirportDataService.search(cached, index: index, query: query).map(\.ident) }
        XCTAssertEqual(find("Genève"), ["LSGG"])
        XCTAssertEqual(find("Genf"), ["LSGG"])
        XCTAssertEqual(find("LSGE"), ["LSGE"])
        XCTAssertEqual(find("Cointrin"), [], "a keyword, which only the next download brings")

        // And what this build writes, the next one reads back.
        let written = try JSONEncoder().encode(airports)
        XCTAssertEqual(try JSONDecoder().decode([Airport].self, from: written), airports)
    }

    /// OpenAIP's name replaces OurAirports' on a merge ("ZUERICH"): the one it replaced still finds the
    /// field, and so do the keywords.
    func testAMergedAirportIsStillFoundByItsOurAirportsName() throws {
        let geoJSON = Data("""
        { "type": "FeatureCollection", "features": [
          { "type": "Feature",
            "properties": { "_id": "z1", "name": "ZUERICH", "icaoCode": "LSZH", "type": 3, "country": "CH" },
            "geometry": { "type": "Point", "coordinates": [8.548056, 47.458056] } },
          { "type": "Feature",
            "properties": { "_id": "g1", "name": "GENEVA", "icaoCode": "LSGG", "type": 3, "country": "CH" },
            "geometry": { "type": "Point", "coordinates": [6.10895, 46.238098] } }
        ] }
        """.utf8)
        let merged = AirportDataMergeEngine.merge(ourAirports: airports, openAIP: try OpenAIPAirport.parse(geoJSON: geoJSON))
        XCTAssertEqual(merged.first { $0.ident == "LSZH" }?.name, "ZUERICH")
        XCTAssertEqual(merged.first { $0.ident == "LSZH" }?.keywords, "Zürich Airport")
        XCTAssertEqual(merged.first { $0.ident == "LSGG" }?.keywords, "Geneva International Airport, Cointrin Airport")
        let index = AirportSearchIndex(merged)
        let find = { (query: String) in
            AirportDataService.search(merged, index: index, query: query, near: self.lszq).map(\.ident)
        }
        XCTAssertEqual(find("Zürich Airport"), ["LSZH"])
        XCTAssertEqual(find("Cointrin").first, "LSGG")
        XCTAssertEqual(find("Genf").first, "LSGG")
    }

    // MARK: - The screens that share the search

    /// Plan new flight's stops and the home aerodrome field take a name for a code when it names one
    /// aerodrome, or one exactly (`AirportDataService.aerodrome(named:among:)`), with five fixed-wing
    /// hits and no reference point.
    func testATypedNameBecomesItsCodeWhenItNamesOneAerodrome() {
        func resolved(_ typed: String) -> String? {
            let hits = AirportDataService.search(airports, index: index, query: typed, limit: 5,
                                                 types: AirportType.fixedWing)
            return AirportDataService.aerodrome(named: typed, among: hits)?.ident
        }
        XCTAssertEqual(resolved("Genève"), "LSGG")
        XCTAssertEqual(resolved("Genf"), "LSGG")
        XCTAssertEqual(resolved("Ecuvillens"), "LSGE")
        XCTAssertEqual(resolved("les eplatures airport"), "LSGC")
        XCTAssertNil(resolved("Geneva"), "two fields named so: the pilot picks")
        XCTAssertNil(resolved("Zurich"), "Zürich and Dübendorf")
    }

    /// The builder's airfield search: twelve fixed-wing hits around the map, nearest first in a rank.
    func testTheBuildersSearchOrdersByDistanceWithinARank() {
        let bern = CLLocationCoordinate2D(latitude: 46.9127, longitude: 7.4988)
        XCTAssertEqual(search("LSZ", limit: 12, near: bern).prefix(3), ["LSZB", "LSZG", "LSZJ"])
    }
}
