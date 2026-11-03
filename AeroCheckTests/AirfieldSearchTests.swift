import XCTest
import MapKit
import CoreLocation
@testable import AeroCheck

/// Plan › Map's aerodrome search (6.2.0): what the magnifying glass left of Map lists for a code or a
/// name (`AirfieldSearch.results`, the planning screens' `AirportSearchIndex` with the map's own
/// aerodromes and its centre), and where the map goes for the one chosen.
///
/// The author, testing: some aerodromes he didn't know were hard to find on the map. The fixture is
/// real OurAirports rows (2026-10-02, as in `AirportSearchTests`), plus three made-up ones marked so.
final class AirfieldSearchTests: XCTestCase {

    private static let csv = """
    "id","ident","type","name","latitude_deg","longitude_deg","elevation_ft","continent","iso_country","iso_region","municipality","scheduled_service","icao_code","iata_code","gps_code","local_code","home_link","wikipedia_link","keywords"
    300136,"LSZQ","small_airport","Bressaucourt Airfield",47.392408,7.028956,1866,"EU","CH","CH-JU","Bressaucourt","no","LSZQ",,"LSZQ",,"https://aerojura.ch/",,
    4489,"LSGC","medium_airport","Les Eplatures Airport",47.083900451699996,6.792840003970001,3368,"EU","CH","CH-NE","La Chaux-de-Fonds","no","LSGC",,"LSGC",,,,
    29495,"LSGE","small_airport","Ecuvillens Airfield",46.755279,7.075746,2293,"EU","CH","CH-FR","Ecuvillens","no","LSGE",,"LSGE",,,,
    4490,"LSGG","large_airport","Geneva International Airport",46.238098,6.10895,1411,"EU","CH","CH-GE","Geneva","yes","LSGG","GVA","LSGG",,,,"Cointrin Airport"
    29497,"LSGN","small_airport","Neuchâtel Airfield",46.957371,6.864574,1427,"EU","CH","CH-NE","Boudry","no","LSGN",,"LSGN",,,,
    4503,"LSZB","medium_airport","Bern Airport",46.912736,7.498819,1671,"EU","CH","CH-BE","Bern","yes","LSZB","BRN","LSZB",,,,"LSZB, Belp, Bern-Belp"
    18640,"K33J","small_airport","Geneva Municipal Airport",31.052579,-85.868715,101,"NA","US","US-AL","Geneva","no",,,"K33J","33J",,,
    900001,"CH-9001","heliport","Neuchâtel Hospital Heliport",46.99,6.93,,"EU","CH","CH-NE","Neuchâtel","no",,,,,,,
    900002,"CH-9002","small_airport","LSGC Fan Club Strip",47.39,7.03,1800,"EU","CH","CH-JU","Bressaucourt","no",,,,,,,
    900003,"CH-9003","closed","Old Neuchâtel Strip",46.98,6.90,1400,"EU","CH","CH-NE","Colombier","no",,,,,,,
    """

    private lazy var airports = AirportDataService.parseAirportsCSV(Self.csv)
    private lazy var index = AirportSearchIndex(airports)

    /// The map's centre over Bressaucourt, the author's field.
    private let overLSZQ = CLLocationCoordinate2D(latitude: 47.392408, longitude: 7.028956)

    private func search(_ query: String, near: CLLocationCoordinate2D? = nil) -> [String] {
        AirfieldSearch.results(for: query, airports: airports, index: index, near: near ?? overLSZQ).map(\.ident)
    }

    func testTheFixtureParsed() {
        XCTAssertEqual(airports.count, 10)
    }

    // MARK: - What it finds

    /// The ICAO code first, whole, even when a field nearer the map's centre has it in its name.
    func testAnICAOCodeFindsItsAerodromeFirst() {
        XCTAssertEqual(search("LSGC").first, "LSGC")
        XCTAssertEqual(search("lsgc").first, "LSGC")
        XCTAssertEqual(search("LSGC"), ["LSGC", "CH-9002"], "the made-up strip is named after it, and nearer")
    }

    /// The start of a code lists the fields it begins, the nearest first, before any name.
    func testTheStartOfACodeListsItsFieldsNearestFirst() {
        XCTAssertEqual(search("LSG"), ["LSGC", "LSGN", "LSGE", "LSGG", "CH-9002"])
    }

    /// The report's case: an aerodrome the pilot doesn't know the code of, by a piece of its name or
    /// its town, whatever the case and the accents.
    func testANameOrATownFindsItWhateverTheCaseAndTheAccents() {
        XCTAssertEqual(search("neuch"), ["LSGN"])
        XCTAssertEqual(search("Neuchatel"), ["LSGN"])
        XCTAssertEqual(search("NEUCHÂTEL"), ["LSGN"])
        XCTAssertEqual(search("eplatures"), ["LSGC"])
        XCTAssertEqual(search("chaux"), ["LSGC"], "La Chaux-de-Fonds, its town")
        XCTAssertEqual(search("Boudry"), ["LSGN"], "Neuchâtel's field is at Boudry")
        XCTAssertEqual(search("belp"), ["LSZB"], "another name it goes by")
    }

    /// The map's airport layer draws no heliport and no closed field, nor does the search list one.
    func testOnlyTheAerodromesTheMapDrawsAreListed() {
        XCTAssertFalse(search("neuch").contains("CH-9001"), "the heliport")
        XCTAssertFalse(search("neuch").contains("CH-9003"), "the closed strip")
        XCTAssertEqual(AirfieldSearch.types, AirportType.fixedWing)
    }

    /// Two Genevas: the one nearer the map's centre first.
    func testOfTwoFieldsOfOneNameTheOneNearerTheMapsCentreComesFirst() {
        XCTAssertEqual(search("Geneva"), ["LSGG", "K33J"])
        let alabama = CLLocationCoordinate2D(latitude: 31.2, longitude: -85.4)
        XCTAssertEqual(search("Geneva", near: alabama), ["K33J", "LSGG"])
    }

    func testTooShortFindsNothingAndSpacesAreTrimmed() {
        XCTAssertEqual(search(""), [])
        XCTAssertEqual(search("  "), [])
        XCTAssertEqual(search("L"), [])
        XCTAssertNil(AirfieldSearch.term(" l "))
        XCTAssertEqual(search("  LSGN  "), ["LSGN"])
    }

    func testTheListIsCapped() {
        let rows = (1...20).map { n in
            "\(990_000 + n),\"ZZ\(String(format: "%02d", n))\",\"small_airport\",\"Test Strip \(n)\",46.\(n),7.0,1500,\"EU\",\"CH\",\"CH-BE\",\"Testwil\",\"no\",,,,,,,"
        }
        let many = AirportDataService.parseAirportsCSV(([Self.csv.components(separatedBy: "\n")[0]] + rows).joined(separator: "\n"))
        XCTAssertEqual(many.count, 20)
        let found = AirfieldSearch.results(for: "test strip", airports: many, index: AirportSearchIndex(many), near: overLSZQ)
        XCTAssertEqual(found.count, AirfieldSearch.limit)
    }

    // MARK: - The callout

    /// Its card opens for every kind the airport layer draws, the layer on or off; with it off, the map draws that
    /// aerodrome's marker alone for its card (device check pm-10). A heliport has no card.
    func testTheCardOpensWithTheAirportLayerOnOrOff() throws {
        let lsgc = try XCTUnwrap(airports.first { $0.ident == "LSGC" })
        let heliport = try XCTUnwrap(airports.first { $0.ident == "CH-9001" })
        XCTAssertTrue(AirfieldSearch.opensCard(lsgc))
        XCTAssertFalse(AirfieldSearch.needsItsOwnMarker(lsgc, airportsLayerOn: true))
        XCTAssertTrue(AirfieldSearch.needsItsOwnMarker(lsgc, airportsLayerOn: false))
        XCTAssertFalse(AirfieldSearch.opensCard(heliport))
        XCTAssertFalse(AirfieldSearch.needsItsOwnMarker(heliport, airportsLayerOn: false))
    }

    /// The callout waits for the camera: the map's centre within a tenth of its span of the aerodrome. A marker on
    /// screen at the edge of where the map was isn't enough (`PilotMapMarkers.openPendingCallout`).
    func testTheCalloutWaitsForTheCameraToArrive() throws {
        let lsgc = try XCTUnwrap(airports.first { $0.ident == "LSGC" })
        let lszq = try XCTUnwrap(airports.first { $0.ident == "LSZQ" })
        let pending = PendingCallout(lsgc, until: Date().addingTimeInterval(AirfieldSearch.calloutWait))
        let span = MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.3)
        XCTAssertTrue(AirfieldSearch.hasArrived(at: pending, center: lsgc.coordinate, span: span))
        let near = CLLocationCoordinate2D(latitude: lsgc.latitude + 0.019, longitude: lsgc.longitude - 0.029)
        XCTAssertTrue(AirfieldSearch.hasArrived(at: pending, center: near, span: span), "within a tenth of the span")
        XCTAssertFalse(AirfieldSearch.hasArrived(at: pending, center: lszq.coordinate, span: span),
                       "the camera still where the pilot was: it waits")
        XCTAssertFalse(AirfieldSearch.hasArrived(
            at: pending, center: CLLocationCoordinate2D(latitude: lsgc.latitude + 0.021, longitude: lsgc.longitude), span: span))
    }
}
