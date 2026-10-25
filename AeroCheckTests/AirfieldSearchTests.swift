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

    // MARK: - Where the map goes

    /// 8 NM across the map's narrower side, whatever its shape: the camera's distance from the
    /// proportion the map sees now. A fixed 13 km showed 3.5 NM across a phone (simulator, 11 Oct).
    func testTheCameraDistanceShowsEightNMAcrossTheNarrowerSide() throws {
        XCTAssertEqual(AirfieldSearch.spanNM, 8)
        // A map that sees 0.1° north to south from 10 km.
        let seen = 0.1, at = 10_000.0
        func across(_ size: CGSize) throws -> (width: Double, height: Double) {
            let distance = try XCTUnwrap(PendingCameraMove.distance(across: 8, viewSize: size,
                                                                    seenLatitudeDelta: seen, at: at))
            let heightNM = seen * 60 * distance / at
            return (heightNM * size.width / size.height, heightNM)
        }
        let kneeboard = try across(CGSize(width: 820, height: 1_180))    // an iPad in portrait
        XCTAssertEqual(kneeboard.width, 8, accuracy: 0.01, "portrait: the width has the 8 NM")
        let side = try across(CGSize(width: 1_180, height: 700))         // an iPad on its side
        XCTAssertEqual(side.height, 8, accuracy: 0.01, "landscape: the height has them")
        let phone = try across(CGSize(width: 402, height: 600))
        XCTAssertEqual(phone.width, 8, accuracy: 0.01)
        XCTAssertNil(PendingCameraMove.distance(across: 8, viewSize: CGSize(width: 820, height: 1_180),
                                                seenLatitudeDelta: 0, at: at), "nothing measured yet")
        XCTAssertNil(PendingCameraMove.distance(across: 8, viewSize: .zero, seenLatitudeDelta: seen, at: at))
    }

    /// Within the chart's zoom range: the ICAO chart and its glider chart stop at 65 km
    /// (`AeroMapView.cameraZoomRange`), further out than 8 NM; the national map comes closer.
    func testTheDistanceIsHeldWithinTheChartsRange() {
        let icao = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 65_000, maxCenterCoordinateDistance: 600_000)
        let national = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 1_500, maxCenterCoordinateDistance: 600_000)
        XCTAssertEqual(PendingCameraMove.held(30_000, within: icao), 65_000)
        XCTAssertEqual(PendingCameraMove.held(30_000, within: national), 30_000)
        XCTAssertEqual(PendingCameraMove.held(30_000, within: nil), 30_000)
        XCTAssertEqual(PendingCameraMove.held(30_000, within: MKMapView().cameraZoomRange), 30_000,
                       "a map's own range has no upper bound: 0, which held the camera at 56 m")
    }

    /// On a map: centred on the aerodrome, not down at the street.
    @MainActor
    func testTheCameraGoesToTheAerodrome() throws {
        let lsgc = try XCTUnwrap(airports.first { $0.ident == "LSGC" })
        let move = PendingCameraMove(to: lsgc)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 820, height: 1_180))
        window.isHidden = false
        addTeardownBlock { @MainActor in window.isHidden = true }
        let map = MKMapView(frame: window.bounds)
        window.addSubview(map)
        map.layoutIfNeeded()

        XCTAssertTrue(move.apply(to: map))
        XCTAssertEqual(map.camera.centerCoordinate.latitude, lsgc.latitude, accuracy: 1e-4)
        XCTAssertEqual(map.camera.centerCoordinate.longitude, lsgc.longitude, accuracy: 1e-4)
        XCTAssertGreaterThan(map.camera.centerCoordinateDistance, 5_000, "not the street")
        XCTAssertFalse(move.apply(to: MKMapView()), "no size yet: left pending, as a fit is")
    }

    /// Its callout opens when the airport layer draws its marker; otherwise the map only goes there.
    func testTheCalloutIsAskedForOnlyWhereTheMapDrawsAMarker() throws {
        let lsgc = try XCTUnwrap(airports.first { $0.ident == "LSGC" })
        let heliport = try XCTUnwrap(airports.first { $0.ident == "CH-9001" })
        XCTAssertTrue(AirfieldSearch.hasMarker(lsgc, airportsLayerOn: true))
        XCTAssertFalse(AirfieldSearch.hasMarker(lsgc, airportsLayerOn: false))
        XCTAssertFalse(AirfieldSearch.hasMarker(heliport, airportsLayerOn: true))
    }

    /// The callout waits for the camera and the marker, which comes with the map's next recompute,
    /// then opens as a tap would; one whose marker never came is given up.
    @MainActor
    func testThePendingCalloutOpensOnItsMarkerOnceThereOrIsGivenUp() throws {
        let lsgc = try XCTUnwrap(airports.first { $0.ident == "LSGC" })
        let lszq = try XCTUnwrap(airports.first { $0.ident == "LSZQ" })
        let lsgn = try XCTUnwrap(airports.first { $0.ident == "LSGN" })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 820, height: 1_180))
        window.isHidden = false
        addTeardownBlock { @MainActor in window.isHidden = true }
        let map = MKMapView(frame: window.bounds)
        window.addSubview(map)
        func show(_ airport: Airport, meters: Double) {
            map.setRegion(MKCoordinateRegion(center: airport.coordinate, latitudinalMeters: meters,
                                             longitudinalMeters: meters), animated: false)
            map.layoutIfNeeded()
        }
        let state = SharedMapState()
        let now = Date()
        let marker = AirportAnnotation(airport: lsgc)

        // The camera still where the pilot was, LSGC's marker on screen at the edge: it waits.
        show(lszq, meters: 80_000)
        map.addAnnotation(marker)
        state.pendingCallout = PendingCallout(lsgc, until: now.addingTimeInterval(AirfieldSearch.calloutWait))
        AirfieldSearch.openPendingCallout(on: map, mapState: state, now: now)
        XCTAssertNotNil(state.pendingCallout, "the camera isn't there yet: it waits")
        XCTAssertTrue(map.selectedAnnotations.isEmpty)

        // There, without its marker yet: it waits.
        map.removeAnnotation(marker)
        show(lsgc, meters: 15_000)
        AirfieldSearch.openPendingCallout(on: map, mapState: state, now: now.addingTimeInterval(1))
        XCTAssertNotNil(state.pendingCallout, "no marker yet: it waits")

        map.addAnnotation(marker)
        AirfieldSearch.openPendingCallout(on: map, mapState: state, now: now.addingTimeInterval(2))
        XCTAssertNil(state.pendingCallout, "the camera there, its marker came: done")
        XCTAssertTrue(map.selectedAnnotations.contains { $0 === marker }, "selected, as a tap would")

        map.deselectAnnotation(marker, animated: false)
        state.pendingCallout = PendingCallout(lsgn, until: now.addingTimeInterval(AirfieldSearch.calloutWait))
        AirfieldSearch.openPendingCallout(on: map, mapState: state, now: now.addingTimeInterval(AirfieldSearch.calloutWait + 1))
        XCTAssertNil(state.pendingCallout, "the marker never came (the layer switched off): given up")
        XCTAssertTrue(map.selectedAnnotations.isEmpty)
    }
}
