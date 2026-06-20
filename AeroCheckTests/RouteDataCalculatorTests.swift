import XCTest
import CoreLocation
@testable import AeroCheck

/// Unit tests for the v4.1.0 trip-aware prefetch route geometry: mapping a route to the countries it
/// crosses (coarse bbox test) and densifying legs into samples.
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
        // Mid-Pacific — outside every OpenAIP country bbox.
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
}
