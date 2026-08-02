import XCTest
import CoreLocation
import MapKit
@testable import AeroCheck

/// The "your route is off screen" test behind the nav-map pill (v4.4.0).
///
/// The nav map opens on the aircraft, so until you have flown to the route the route is somewhere
/// else — and an armed plan could be entirely invisible, with the only trace a "WPT 1/5" label in the
/// bottom bar. These pin the two ways that can go wrong: claiming the route is off screen when it is
/// drawn across the middle of the map (nagging), and claiming it is on screen when it isn't (the
/// original bug, silently).
final class RouteVisibilityTests: XCTestCase {

    private func region(lat: Double, lon: Double, span: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(center: .init(latitude: lat, longitude: lon),
                           span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
    }

    /// LSGG → LSZS, roughly. Used as "a real route somewhere in Switzerland".
    private let swissRoute = [
        CLLocationCoordinate2D(latitude: 46.238, longitude: 6.109),
        CLLocationCoordinate2D(latitude: 46.534, longitude: 9.884),
    ]

    // MARK: - On screen → no hint

    func testRouteInsideTheRegionGivesNoHint() {
        let hint = RouteVisibility.offScreenHint(
            route: swissRoute, region: region(lat: 46.4, lon: 8.0, span: 6))
        XCTAssertNil(hint, "the whole route is visible — nothing to point at")
    }

    func testWaypointInsideTheRegionGivesNoHint() {
        // Zoomed in on Geneva: the first waypoint is on screen, the rest is not.
        let hint = RouteVisibility.offScreenHint(
            route: swissRoute, region: region(lat: 46.24, lon: 6.11, span: 0.2))
        XCTAssertNil(hint)
    }

    /// The reason this tests SEGMENTS and not sampled points. Zoomed onto a patch of the leg with no
    /// waypoint anywhere near it: the line crosses the viewport, so there must be no pill. A
    /// point-sampling implementation at 10 NM spacing steps straight over a window this small.
    func testRegionStraddledByALegWithNoWaypointInItGivesNoHint() {
        let midpoint = CLLocationCoordinate2D(latitude: 46.386, longitude: 7.997)
        let hint = RouteVisibility.offScreenHint(
            route: swissRoute, region: region(lat: midpoint.latitude, lon: midpoint.longitude, span: 0.08))
        XCTAssertNil(hint, "the leg is drawn across this viewport even though no waypoint is in it")
    }

    // MARK: - Off screen → hint

    /// The reported situation: aircraft near Meiringen, route ~90 NM west, nothing on screen.
    func testRouteWellAwayGivesDistanceAndBearing() throws {
        let meiringen = region(lat: 46.73, lon: 8.18, span: 0.3)
        let route = [
            CLLocationCoordinate2D(latitude: 46.238, longitude: 6.109),   // LSGG
            CLLocationCoordinate2D(latitude: 46.30, longitude: 6.25),
        ]
        let hint = try XCTUnwrap(RouteVisibility.offScreenHint(route: route, region: meiringen))

        XCTAssertGreaterThan(hint.distanceNm, 60)
        XCTAssertLessThan(hint.distanceNm, 120)
        // Geneva is west-south-west of Meiringen.
        XCTAssertGreaterThan(hint.bearingDegrees, 225)
        XCTAssertLessThan(hint.bearingDegrees, 275)
    }

    /// The distance is to the nearest point ON THE LINE, not to the nearest waypoint — on a long leg
    /// the closest part of the route is usually somewhere in the middle of it, and pointing at an
    /// endpoint would overstate how far away the route is.
    func testDistanceMeasuresToTheLineNotTheNearestWaypoint() throws {
        // A leg running due east well north of the viewer; the perpendicular foot is much closer than
        // either end.
        let route = [
            CLLocationCoordinate2D(latitude: 47.0, longitude: 5.0),
            CLLocationCoordinate2D(latitude: 47.0, longitude: 11.0),
        ]
        let below = region(lat: 46.0, lon: 8.0, span: 0.2)
        let hint = try XCTUnwrap(RouteVisibility.offScreenHint(route: route, region: below))

        // 1° of latitude = 60 NM, so the perpendicular distance is ~60 NM…
        XCTAssertEqual(hint.distanceNm, 60, accuracy: 4)
        // …and due north, not toward either endpoint.
        XCTAssertEqual(hint.bearingDegrees, 0, accuracy: 6)
    }

    func testBearingIsAlwaysInRange() throws {
        let centre = region(lat: 46.5, lon: 8.0, span: 0.2)
        for (lat, lon) in [(48.0, 8.0), (45.0, 8.0), (46.5, 12.0), (46.5, 4.0), (48.0, 4.0)] {
            let route = [CLLocationCoordinate2D(latitude: lat, longitude: lon),
                         CLLocationCoordinate2D(latitude: lat + 0.05, longitude: lon + 0.05)]
            let hint = try XCTUnwrap(RouteVisibility.offScreenHint(route: route, region: centre))
            XCTAssertGreaterThanOrEqual(hint.bearingDegrees, 0)
            XCTAssertLessThan(hint.bearingDegrees, 360)
        }
    }

    func testBearingLabelIsThreeDigits() {
        let hint = RouteVisibility.OffScreenHint(distanceNm: 96, bearingDegrees: 7.4)
        XCTAssertEqual(hint.bearingLabel, "007")
    }

    // MARK: - Degenerate input

    /// A one-point plan has no line to miss, and an empty one has nothing at all. Neither may produce
    /// a pill pointing at a route that doesn't exist.
    func testFewerThanTwoPointsGivesNoHint() {
        let far = region(lat: 0, lon: 0, span: 1)
        XCTAssertNil(RouteVisibility.offScreenHint(route: [], region: far))
        XCTAssertNil(RouteVisibility.offScreenHint(
            route: [CLLocationCoordinate2D(latitude: 46.2, longitude: 6.1)], region: far))
    }

    /// A waypoint with invalid coordinates is dropped rather than poisoning the geometry — the same
    /// tolerance the rest of the route code applies to imported plans.
    func testInvalidCoordinatesAreIgnored() {
        let route = [
            CLLocationCoordinate2D(latitude: .nan, longitude: .nan),
            CLLocationCoordinate2D(latitude: 46.238, longitude: 6.109),
        ]
        // Only one valid point remains → no line, no hint, no crash.
        XCTAssertNil(RouteVisibility.offScreenHint(route: route, region: region(lat: 46.7, lon: 8.2, span: 0.3)))
    }

    func testZeroSpanRegionGivesNoHint() {
        let degenerate = MKCoordinateRegion(center: .init(latitude: 46.5, longitude: 8.0),
                                            span: MKCoordinateSpan(latitudeDelta: 0, longitudeDelta: 0))
        XCTAssertNil(RouteVisibility.offScreenHint(route: swissRoute, region: degenerate))
    }
}
