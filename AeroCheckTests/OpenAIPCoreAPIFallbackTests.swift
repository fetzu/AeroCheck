import XCTest
@testable import AeroCheck

/// The core-API fallback added in v4.4.0, after OpenAIP switched its public GeoJSON export bucket to
/// Google Cloud Storage "Requester Pays" (~21 Jul 2026) and every anonymous read started returning
/// HTTP 400. Navaids, obstacles, reporting points and OpenAIP airports all come from that bucket, so
/// all four went silently dark while airspace — alone in using the authenticated REST API — kept
/// working. That asymmetry is exactly what the trip-prefetch banner exposed.
///
/// The fallback deliberately adds no new parsers: a core-API item is a GeoJSON feature turned inside
/// out (same property keys at the top level, `geometry` beside them instead of wrapping them), so it
/// is re-nested and handed to each layer's existing decoder. These tests pin that equivalence with
/// payloads copied from live `api.core.openaip.net` responses — if the shapes ever diverge, the
/// re-nesting is where it breaks, and it breaks here first.
final class OpenAIPCoreAPIFallbackTests: XCTestCase {

    private func items(_ json: String) throws -> [Any] {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return (object as? [String: Any])?["items"] as? [Any] ?? []
    }

    // MARK: - Navaids

    /// A live `/api/navaids?country=CH` item survives the re-nesting with every field the export
    /// carried: id, identifier, string frequency, channel, metres→feet elevation, and a fractional
    /// magnetic declination (the declination source for the flight-plan builder).
    func testCoreAPINavaidItemParsesLikeTheExport() throws {
        let payload = """
        {"limit":1,"totalCount":13,"totalPages":13,"page":1,"items":[
          {"_id":"62616d44abdcc7f0ccbbfd7a","name":"HOCHWALD","identifier":"HOC","type":0,
           "country":"CH","channel":"79X","frequency":{"value":"113.200","unit":2},
           "geometry":{"type":"Point","coordinates":[7.665,47.466666666667]},
           "elevation":{"value":727,"unit":0,"referenceDatum":1},
           "magneticDeclination":2.83140246823641,"__v":1}
        ]}
        """
        let data = try OpenAIPLayerCache<Navaid>.featureCollectionData(fromCoreAPIItems: items(payload))
        let navaids = try Navaid.parse(geoJSON: data)

        XCTAssertEqual(navaids.count, 1)
        let hoc = try XCTUnwrap(navaids.first)
        XCTAssertEqual(hoc.id, "62616d44abdcc7f0ccbbfd7a")
        XCTAssertEqual(hoc.identifier, "HOC")
        XCTAssertEqual(hoc.name, "HOCHWALD")
        XCTAssertEqual(hoc.frequencyValue, "113.200")
        XCTAssertEqual(hoc.channel, "79X")
        XCTAssertEqual(hoc.elevationFeet, Int((727.0 * 3.28084).rounded()))
        XCTAssertEqual(hoc.magneticDeclination ?? 0, 2.83140246823641, accuracy: 0.000001)
        // [lon, lat] order survives the re-nesting — swapping it would put every navaid in the sea.
        XCTAssertEqual(hoc.latitude, 47.466666666667, accuracy: 0.000001)
        XCTAssertEqual(hoc.longitude, 7.665, accuracy: 0.000001)
    }

    // MARK: - Obstacles

    /// Obstacles are the layer where the two sources differ most: the core API omits `height` (AGL)
    /// on many records where the export had it. `elevation` (the top, MSL) is what the route-profile
    /// clearance check actually reads, so a missing `height` must degrade to nil rather than drop the
    /// obstacle — losing a 456 m mast from the profile is the failure that matters.
    func testCoreAPIObstacleParsesWithoutHeight() throws {
        let payload = """
        {"limit":1,"totalCount":143,"totalPages":143,"page":1,"items":[
          {"_id":"6a6ea87b9c253f5a692dc807","name":"Adonis","type":15,"country":"CH",
           "elevation":{"value":456,"unit":0,"referenceDatum":1},
           "geometry":{"type":"Point","coordinates":[7.1454076,46.1311387]}}
        ]}
        """
        let data = try OpenAIPLayerCache<Obstacle>.featureCollectionData(fromCoreAPIItems: items(payload))
        let obstacles = try Obstacle.parse(geoJSON: data)

        XCTAssertEqual(obstacles.count, 1)
        let mast = try XCTUnwrap(obstacles.first)
        XCTAssertEqual(mast.id, "6a6ea87b9c253f5a692dc807")
        XCTAssertEqual(mast.name, "Adonis")
        XCTAssertEqual(mast.elevationFeetMSL, Int((456.0 * 3.28084).rounded()))
        XCTAssertEqual(mast.latitude, 46.1311387, accuracy: 0.000001)
    }

    // MARK: - Reporting points

    func testCoreAPIReportingPointParses() throws {
        let payload = """
        {"limit":1,"totalCount":104,"totalPages":104,"page":1,"items":[
          {"_id":"629ccdbdf4b4089a578e6a92","name":"ABMAN","compulsory":true,"country":"CH",
           "elevation":{"value":1500,"unit":1,"referenceDatum":1},
           "geometry":{"type":"Point","coordinates":[7.049722222222222,46.870555555555555]}}
        ]}
        """
        let data = try OpenAIPLayerCache<ReportingPoint>.featureCollectionData(fromCoreAPIItems: items(payload))
        let points = try ReportingPoint.parse(geoJSON: data)

        XCTAssertEqual(points.count, 1)
        let abman = try XCTUnwrap(points.first)
        XCTAssertEqual(abman.name, "ABMAN")
        XCTAssertTrue(abman.compulsory)
        XCTAssertEqual(abman.elevationFeetMSL, 1500)   // unit 1 = already feet
    }

    // MARK: - Airports

    /// The airport layer is the primary airport source since v4.1.0, and the one whose payload is
    /// deepest — nested frequencies and runways must survive the re-nesting, or the FREQ panel and the
    /// briefing runway table quietly empty out.
    func testCoreAPIAirportKeepsFrequenciesAndRunways() throws {
        let payload = """
        {"limit":1,"totalCount":162,"totalPages":162,"page":1,"items":[
          {"_id":"626151975e9ded5710452de5","name":"BRESSAUCOURT","icaoCode":"LSZQ","type":2,
           "country":"CH","magneticDeclination":2.5,
           "elevation":{"value":515,"unit":0,"referenceDatum":1},
           "frequencies":[{"name":"AFIS","value":"122.050","type":4}],
           "runways":[{"designator":"05","trueHeading":48,"mainRunway":true,
                       "dimension":{"length":{"value":800,"unit":0},"width":{"value":18,"unit":0}}}],
           "geometry":{"type":"Point","coordinates":[7.029552,47.39225]}}
        ]}
        """
        let data = try OpenAIPLayerCache<OpenAIPAirport>.featureCollectionData(fromCoreAPIItems: items(payload))
        let airports = try OpenAIPAirport.parse(geoJSON: data)

        XCTAssertEqual(airports.count, 1)
        let lszq = try XCTUnwrap(airports.first)
        XCTAssertEqual(lszq.icaoCode, "LSZQ")
        XCTAssertEqual(lszq.frequencies.count, 1)
        XCTAssertEqual(lszq.frequencies.first?.value, "122.050")
        XCTAssertEqual(lszq.runways.count, 1)
        XCTAssertEqual(lszq.runways.first?.designator, "05")
    }

    // MARK: - Robustness

    /// A page can contain a record with no geometry (OpenAIP has a few). It is dropped, and the rest
    /// of the page still lands — the same lossy contract the export path already had, so one bad
    /// record cannot zero out a country.
    func testItemWithoutGeometryIsDroppedWithoutLosingThePage() throws {
        let payload = """
        {"items":[
          {"_id":"no-geometry","name":"GHOST","identifier":"GHO","type":0},
          {"_id":"ok","name":"LA DOLE","identifier":"DOL","type":7,
           "geometry":{"type":"Point","coordinates":[6.0997,46.4247]}}
        ]}
        """
        let data = try OpenAIPLayerCache<Navaid>.featureCollectionData(fromCoreAPIItems: items(payload))
        let navaids = try Navaid.parse(geoJSON: data)

        XCTAssertEqual(navaids.count, 1)
        XCTAssertEqual(navaids.first?.identifier, "DOL")
    }

    /// An empty page yields an empty FeatureCollection, not a throw — a country OpenAIP genuinely has
    /// no records for must still be recorded as downloaded, or the trip banner re-offers it forever.
    func testEmptyPageProducesEmptyCollection() throws {
        let data = try OpenAIPLayerCache<Navaid>.featureCollectionData(fromCoreAPIItems: [])
        XCTAssertEqual(try Navaid.parse(geoJSON: data).count, 0)
    }
}
