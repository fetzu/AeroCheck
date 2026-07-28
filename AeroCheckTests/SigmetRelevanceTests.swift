import XCTest
import CoreLocation
@testable import AeroCheck

/// Geometry behind "how close is that hazard, really".
///
/// The proxy answers with the nearest polygon VERTEX, frozen at fetch time. Both approximations are
/// visible to a pilot — a long thin area's nearest corner can be far further than its nearest edge,
/// and a frozen figure stops counting down. These tests pin the corrections.
final class SigmetRelevanceTests: XCTestCase {

    private func coord(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        .init(latitude: lat, longitude: lon)
    }

    /// A square roughly 1° on a side around 46.5N — about 60 nm tall.
    private var square: [CLLocationCoordinate2D] {
        [coord(46, 6), coord(46, 7), coord(47, 7), coord(47, 6)]
    }

    // MARK: - Containment

    func testInsideIsZero() {
        XCTAssertEqual(SigmetRelevance.distanceNm(from: coord(46.5, 6.5), toPolygon: square), 0)
        XCTAssertTrue(SigmetRelevance.contains(coord(46.5, 6.5), square))
    }

    func testOutsideIsNotZero() {
        let d = SigmetRelevance.distanceNm(from: coord(48, 6.5), toPolygon: square)
        XCTAssertNotNil(d)
        XCTAssertGreaterThan(d ?? 0, 30)
    }

    func testDegeneratePolygonIsRejected() {
        XCTAssertNil(SigmetRelevance.distanceNm(from: coord(46.5, 6.5), toPolygon: []))
        XCTAssertNil(SigmetRelevance.distanceNm(from: coord(46.5, 6.5), toPolygon: [coord(46, 6), coord(47, 7)]))
    }

    // MARK: - Edge vs vertex — the correction that matters

    /// THE POINT. Standing off the middle of a long edge, the nearest VERTEX is far away while the
    /// nearest EDGE is close. The proxy would report the corner; a pilot cares about the boundary.
    func testEdgeDistanceBeatsVertexDistanceOnALongThinArea() {
        // A wide, shallow band — corners 2° of longitude apart, edges only 0.1° of latitude away.
        let band = [coord(46.0, 5.0), coord(46.0, 9.0), coord(46.1, 9.0), coord(46.1, 5.0)]
        let abeamTheMiddle = coord(46.3, 7.0)

        let edge = SigmetRelevance.distanceNm(from: abeamTheMiddle, toPolygon: band) ?? .infinity
        let nearestVertex = band
            .map { SigmetRelevance.haversineNm(abeamTheMiddle, $0) }
            .min() ?? .infinity

        XCTAssertLessThan(edge, nearestVertex,
                          "edge distance must be shorter than the nearest corner")
        XCTAssertEqual(edge, 12, accuracy: 2, "0.2° of latitude is about 12 nm")
        XCTAssertGreaterThan(nearestVertex, 50, "the corners really are far away")
    }

    /// Longitude degrees shrink with latitude; ignoring that overstates east-west distance by ~32%
    /// at 47°N. The projection in `distanceNm(from:toSegment:)` is what prevents that.
    func testLongitudeIsScaledByLatitude() {
        let northSouth = SigmetRelevance.haversineNm(coord(47, 7), coord(47.1, 7))
        let eastWest = SigmetRelevance.haversineNm(coord(47, 7), coord(47, 7.1))
        XCTAssertLessThan(eastWest, northSouth * 0.75,
                          "0.1° of longitude at 47N is much shorter than 0.1° of latitude")
    }

    func testDegenerateSegmentFallsBackToTheEndpoint() {
        let p = coord(46.5, 6.5), a = coord(47, 7)
        XCTAssertEqual(SigmetRelevance.distanceNm(from: p, toSegment: a, a),
                       SigmetRelevance.haversineNm(p, a), accuracy: 0.01)
    }

    // MARK: - Route awareness

    func testRouteCrossingIsDetectedEvenWhenBothWaypointsAreOutside() {
        // The case endpoint-only testing misses: a leg passing clean through the area with both
        // ends well clear of it.
        let route = [coord(46.5, 4.0), coord(46.5, 9.0)]
        let assessment = SigmetRelevance.assess(polygon: square, aircraft: coord(46.5, 4.0), route: route)
        XCTAssertTrue(assessment?.intersectsRoute ?? false)
        XCTAssertFalse(assessment?.containsAircraft ?? true, "the aircraft is still outside")
    }

    func testRouteThatMissesTheAreaIsNotFlagged() {
        let route = [coord(49.0, 4.0), coord(49.0, 9.0)]
        let assessment = SigmetRelevance.assess(polygon: square, aircraft: coord(49.0, 4.0), route: route)
        XCTAssertFalse(assessment?.intersectsRoute ?? true)
    }

    func testNoRouteMeansNoRouteClaim() {
        let assessment = SigmetRelevance.assess(polygon: square, aircraft: coord(48, 6.5))
        XCTAssertFalse(assessment?.intersectsRoute ?? true)
        XCTAssertNil(assessment?.routeDistanceNm)
    }

    // MARK: - Ranking

    /// A hazard over the destination outranks a nearer one that will never be reached.
    func testOnRouteOutranksMerelyNearby() {
        let onRoute = SigmetRelevance.Assessment(
            distanceNm: 90, containsAircraft: false, intersectsRoute: true, routeDistanceNm: 0)
        let nearby = SigmetRelevance.Assessment(
            distanceNm: 30, containsAircraft: false, intersectsRoute: false, routeDistanceNm: nil)
        XCTAssertLessThan(onRoute.severityRank, nearby.severityRank)
    }

    func testContainmentOutranksEverything() {
        let inside = SigmetRelevance.Assessment(
            distanceNm: 0, containsAircraft: true, intersectsRoute: false, routeDistanceNm: nil)
        let onRoute = SigmetRelevance.Assessment(
            distanceNm: 5, containsAircraft: false, intersectsRoute: true, routeDistanceNm: 0)
        XCTAssertLessThan(inside.severityRank, onRoute.severityRank)
    }

    // MARK: - Sampling

    func testLegSamplingIncludesBothEndpoints() {
        let a = coord(46, 6), b = coord(47, 7)
        let samples = SigmetRelevance.sampleLeg(from: a, to: b)
        XCTAssertEqual(samples.first?.latitude, a.latitude)
        XCTAssertEqual(samples.last?.latitude, b.latitude)
    }

    /// This runs while a view is being built, so a 3000 nm leg must not produce 300 samples.
    func testLegSamplingIsBounded() {
        let samples = SigmetRelevance.sampleLeg(from: coord(0, 0), to: coord(60, 0))
        XCTAssertLessThanOrEqual(samples.count, SigmetRelevance.maxSamplesPerLeg + 1)
    }

    func testShortLegStillProducesEndpoints() {
        let samples = SigmetRelevance.sampleLeg(from: coord(46.500, 6.500), to: coord(46.501, 6.501))
        XCTAssertGreaterThanOrEqual(samples.count, 2)
    }
}
