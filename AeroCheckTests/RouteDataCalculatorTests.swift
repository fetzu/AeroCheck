import XCTest
import CoreLocation
@testable import AeroCheck

/// Unit tests for the trip-aware prefetch route geometry: mapping a route to the countries it crosses
/// and densifying legs into samples.
///
/// The country test was a bounding-box match until v4.4.0, which meant Switzerland's box also covered
/// slabs of France, Germany, Italy and Austria — a Jura circuit proposed downloading Germany's ~30 000
/// obstacle records. It now runs against simplified national borders with a deliberate 10 nm inclusion
/// buffer, so the tests below assert BOTH directions: the neighbour that must no longer appear, and
/// the neighbour that still must.
@MainActor
final class RouteDataCalculatorTests: XCTestCase {

    func testSingleWaypointReturnsItsCountry() {
        // Bern, Switzerland
        let countries = RouteDataCalculator.countries(crossing: [
            CLLocationCoordinate2D(latitude: 46.95, longitude: 7.44)
        ])
        XCTAssertTrue(countries.contains("CH"))
    }

    func testRouteCrossingTwoCountriesReturnsBoth() {
        // Bern (CH) → Lyon (FR)
        let countries = RouteDataCalculator.countries(crossing: [
            CLLocationCoordinate2D(latitude: 46.95, longitude: 7.44),
            CLLocationCoordinate2D(latitude: 45.76, longitude: 4.84)
        ])
        XCTAssertTrue(countries.contains("CH"))
        XCTAssertTrue(countries.contains("FR"))
    }

    func testEmptyWaypointsReturnsEmpty() {
        XCTAssertTrue(RouteDataCalculator.countries(crossing: []).isEmpty)
    }

    func testRemoteOceanMatchesNoCountry() {
        // Mid-Pacific — nowhere near any OpenAIP country.
        XCTAssertTrue(RouteDataCalculator.countries(crossing: [
            CLLocationCoordinate2D(latitude: 0, longitude: -150)
        ]).isEmpty)
    }

    func testSampledPointsDensifiesLongLeg() {
        // ~60 NM leg → interpolated to more than its two endpoints.
        let pts = RouteDataCalculator.sampledPoints(for: [
            CLLocationCoordinate2D(latitude: 46.0, longitude: 7.0),
            CLLocationCoordinate2D(latitude: 47.0, longitude: 7.0)
        ])
        XCTAssertGreaterThan(pts.count, 2)
    }

    // MARK: - Border test (v4.4.0)

    /// The regression this replaced. An inland Swiss route — Bern, Grenchen, Emmen, Buochs, none of
    /// them within 40 nm of the German border — used to return Germany, Italy, Austria and France
    /// because they all share Switzerland's bounding box. Germany alone is ~30 000 obstacle records.
    func testInlandSwissRouteNoLongerProposesDistantNeighbours() {
        let countries = RouteDataCalculator.countries(crossing: [
            CLLocationCoordinate2D(latitude: 46.914, longitude: 7.497),   // LSZB Bern-Belp
            CLLocationCoordinate2D(latitude: 47.182, longitude: 7.417),   // LSZG Grenchen
            CLLocationCoordinate2D(latitude: 47.092, longitude: 8.305),   // LSME Emmen
            CLLocationCoordinate2D(latitude: 46.975, longitude: 8.397),   // LSZC Buochs
        ])
        XCTAssertEqual(countries, ["CH"],
                       "an inland Swiss route needs Swiss data and nothing else")
    }

    /// The inclusion bias, which must survive the fix. Bressaucourt sits about 3 nm from the French
    /// border: flying there without French airspace, obstacles and reporting points is the failure
    /// mode worth protecting against, so France stays in even though the route never leaves
    /// Switzerland.
    func testRouteHuggingABorderStillIncludesTheNeighbour() {
        let countries = RouteDataCalculator.countries(crossing: [
            CLLocationCoordinate2D(latitude: 47.392, longitude: 7.030),   // LSZQ Bressaucourt
            CLLocationCoordinate2D(latitude: 47.320, longitude: 7.100),
        ])
        XCTAssertTrue(countries.contains("CH"))
        XCTAssertTrue(countries.contains("FR"),
                      "a route within 10 nm of France must still offer French data")
    }

    /// A route that genuinely crosses a border returns both sides, and only those two — the old test
    /// would also have returned Austria, Italy and Switzerland here.
    func testCrossBorderRouteReturnsExactlyBothSides() {
        let countries = RouteDataCalculator.countries(crossing: [
            CLLocationCoordinate2D(latitude: 48.354, longitude: 11.786),  // EDDM Munich (DE)
            CLLocationCoordinate2D(latitude: 48.110, longitude: 16.570),  // LOWW Vienna (AT)
        ])
        XCTAssertEqual(Set(countries), ["DE", "AT"])
    }
}

/// The bundled boundary geometry itself: containment, the buffer, and the bbox fallback for the one
/// country Natural Earth files under another (Réunion).
@MainActor
final class CountryBoundariesTests: XCTestCase {

    /// Airports whose country is unambiguous, including two that a bbox gets wrong: Basel-Mulhouse is
    /// French soil inside Switzerland's box, and Geneva is Swiss soil deep inside France's.
    func testKnownAirportsResolveToTheirCountry() {
        let cases: [(String, CLLocationCoordinate2D, String)] = [
            ("LSZQ Bressaucourt", .init(latitude: 47.392, longitude: 7.030), "CH"),
            ("LSGG Geneva",       .init(latitude: 46.238, longitude: 6.109), "CH"),
            ("LFSB Basel-Mulhouse", .init(latitude: 47.590, longitude: 7.529), "FR"),
            ("EDDM Munich",       .init(latitude: 48.354, longitude: 11.786), "DE"),
            ("LIMC Milan",        .init(latitude: 45.630, longitude: 8.723), "IT"),
            ("LOWW Vienna",       .init(latitude: 48.110, longitude: 16.570), "AT"),
            ("EGLL Heathrow",     .init(latitude: 51.470, longitude: -0.454), "GB"),
        ]
        for (name, coordinate, expected) in cases {
            let found = CountryBoundaries.shared.countries(near: coordinate, bufferNm: 0)
            XCTAssertTrue(found.contains(expected), "\(name) should resolve to \(expected), got \(found.sorted())")
        }
    }

    /// With no buffer, an inland point belongs to exactly one country. This is the assertion the bbox
    /// test could never satisfy.
    func testInlandPointBelongsToExactlyOneCountry() {
        // Interlaken — central Switzerland, far from any frontier.
        let found = CountryBoundaries.shared.countries(
            near: CLLocationCoordinate2D(latitude: 46.676, longitude: 7.869), bufferNm: 0)
        XCTAssertEqual(found, ["CH"])
    }

    /// Open water well outside territorial limits matches nothing, so a route there proposes no
    /// download at all rather than a boxful of countries.
    func testOpenWaterMatchesNothing() {
        XCTAssertTrue(CountryBoundaries.shared.countries(
            near: CLLocationCoordinate2D(latitude: 0, longitude: -150), bufferNm: 10).isEmpty)
    }

    /// The buffer is what keeps the test safe near a frontier: the same point picks up the neighbour
    /// once you allow for 10 nm, and doesn't without it.
    func testBufferAddsTheNeighbourNearAFrontier() {
        let nearFrance = CLLocationCoordinate2D(latitude: 47.392, longitude: 7.030)   // ~3 nm from FR
        XCTAssertFalse(CountryBoundaries.shared.countries(near: nearFrance, bufferNm: 0).contains("FR"))
        XCTAssertTrue(CountryBoundaries.shared.countries(near: nearFrance, bufferNm: 10).contains("FR"))
    }

    /// Geometry check against a synthetic square, so the distance maths is pinned independently of
    /// whatever the shipped borders happen to look like. One degree of latitude is 60 nm, so a point
    /// half a degree outside the square is 30 nm from it: inside a 40 nm buffer, outside a 20 nm one.
    func testDistanceBufferUsesNauticalMiles() {
        // A 1° square centred on the equator at 0°E, as a flat [lon, lat, …] ring, on its own
        // instance so the shared world is untouched.
        let boundaries = CountryBoundaries.makeForTesting(
            rings: ["XX": [[-0.5, -0.5, 0.5, -0.5, 0.5, 0.5, -0.5, 0.5, -0.5, -0.5]]])

        let inside = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let thirtyNmNorth = CLLocationCoordinate2D(latitude: 1.0, longitude: 0)   // 0.5° past the edge

        XCTAssertEqual(boundaries.countries(near: inside, bufferNm: 0), ["XX"])
        XCTAssertTrue(boundaries.countries(near: thirtyNmNorth, bufferNm: 40).contains("XX"))
        XCTAssertFalse(boundaries.countries(near: thirtyNmNorth, bufferNm: 20).contains("XX"))
    }

    /// Every country OpenAIP serves must be answerable — by polygon, or by the bbox fallback for the
    /// handful Natural Earth files under a parent state. A code that resolved to neither would be
    /// silently unreachable by trip prefetch forever.
    func testEveryOpenAIPCountryIsReachable() {
        CountryBoundaries.shared.loadIfNeeded()
        for code in CountryBoundaries.shared.countriesWithoutPolygons {
            XCTAssertNotNil(OpenAIPConfig.countryBounds[code],
                            "\(code) has neither a polygon nor a bounding box")
        }
        // Réunion is the known case: Natural Earth files it under France.
        XCTAssertTrue(CountryBoundaries.shared.countriesWithoutPolygons.isSubset(of: ["RE"]),
                      "unexpected countries fell back to bounding boxes: \(CountryBoundaries.shared.countriesWithoutPolygons.sorted())")
    }

    /// The fallback has to actually work, not just exist.
    func testBoundingBoxFallbackStillMatches() {
        CountryBoundaries.shared.loadIfNeeded()
        guard CountryBoundaries.shared.countriesWithoutPolygons.contains("RE") else {
            return   // a future asset that includes Réunion makes this moot
        }
        let saintDenis = CLLocationCoordinate2D(latitude: -20.887, longitude: 55.516)
        XCTAssertTrue(CountryBoundaries.shared.countries(near: saintDenis, bufferNm: 10).contains("RE"))
    }
}

/// The size estimate offered alongside the download button.
final class TripDataSizeEstimatorTests: XCTestCase {

    /// Obstacles are the layer that makes the estimate worth showing at all, so the per-record
    /// constants must stay ordered the way the measurements were: an airspace record is an order of
    /// magnitude heavier than an obstacle, and a navaid several times heavier.
    func testPerRecordCostsKeepTheirMeasuredOrdering() {
        XCTAssertGreaterThan(TripDataSizeEstimator.Layer.airspace.bytesPerRecord,
                             TripDataSizeEstimator.Layer.navaids.bytesPerRecord)
        XCTAssertGreaterThan(TripDataSizeEstimator.Layer.navaids.bytesPerRecord,
                             TripDataSizeEstimator.Layer.reportingPoints.bytesPerRecord)
        XCTAssertGreaterThan(TripDataSizeEstimator.Layer.reportingPoints.bytesPerRecord,
                             TripDataSizeEstimator.Layer.obstacles.bytesPerRecord)
    }

    /// Nothing to download → nothing to display. The banner must not show "≈ Zero KB".
    func testEmptyEstimateHasNoDisplayString() {
        let empty = TripDataSizeEstimator.Estimate(bytes: 0, recordsByLayer: [:], isPartial: false)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(TripDataSizeEstimator.displayString(empty))
    }

    /// A complete estimate reads as an approximation; an incomplete one reads as a floor. Presenting
    /// a partial sum as "≈" would understate the download by however many counts failed to load.
    func testPartialEstimateIsMarkedAsAFloor() {
        let complete = TripDataSizeEstimator.Estimate(bytes: 12_000_000, recordsByLayer: ["obstacles": 30_000], isPartial: false)
        let partial = TripDataSizeEstimator.Estimate(bytes: 12_000_000, recordsByLayer: ["obstacles": 30_000], isPartial: true)

        XCTAssertEqual(TripDataSizeEstimator.displayString(complete)?.first, "≈")
        XCTAssertEqual(TripDataSizeEstimator.displayString(partial)?.first, "≥")
    }

    /// A country with no missing layers costs nothing and makes no requests — the estimator must not
    /// price data the device already holds.
    func testNoMissingLayersCostsNothing() async {
        let estimate = await TripDataSizeEstimator.estimate(countriesByLayer: [:])
        XCTAssertTrue(estimate.isEmpty)
        XCTAssertFalse(estimate.isPartial)
    }
}
