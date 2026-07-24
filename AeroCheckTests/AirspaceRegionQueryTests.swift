import XCTest
import CoreLocation
import MapKit
@testable import AeroCheck

/// Unit tests for `OpenAIPDataService.airspacesInBounds`'s 1° spatial grid (perf review 30-performance.md
/// #7/#9): airspaces are polygons, so each one is inserted into EVERY cell its bounding box overlaps, and
/// a query gathers only the cells its own bounds overlap before applying the pre-existing exact
/// vertex/bbox/containsPoint check. These tests assert the grid-backed result is identical to an
/// independently reimplemented brute-force filter over a synthetic dataset that straddles integer-degree
/// cell boundaries (the case a naive per-cell lookup, without the "insert into every overlapping cell"
/// rule, would get wrong).
@MainActor
final class AirspaceRegionQueryTests: XCTestCase {

    // MARK: - Fixtures

    private func rectAirspace(id: String, minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) -> Airspace {
        let ring: [[Double]] = [
            [minLon, minLat], [minLon, maxLat], [maxLon, maxLat], [maxLon, minLat], [minLon, minLat],
        ]
        return Airspace(
            id: id, name: id, type: 4, icaoClass: nil, country: "CH",
            upperCeiling: AltitudeLimit(value: 5000, unit: 1, referenceDatum: 1),
            lowerCeiling: AltitudeLimit(value: 0, unit: 1, referenceDatum: 0),
            geometry: AirspaceGeometry(type: "Polygon", coordinates: [ring]),
            activity: nil, frequencies: nil)
    }

    /// Independent reimplementation of the pre-grid linear-scan algorithm (not calling into the
    /// service's private grid path) — the oracle the grid-backed result must match exactly.
    private func bruteForceAirspacesInBounds(_ airspaces: [Airspace], region: MKCoordinateRegion) -> [Airspace] {
        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2

        return airspaces.filter { airspace in
            if let box = airspace.boundingBox,
               !box.intersects(latRange: minLat...maxLat, lonRange: minLon...maxLon) {
                return false
            }
            let coords = airspace.polygonCoordinates
            guard !coords.isEmpty else { return false }
            let vertexInBounds = coords.contains { coord in
                coord.latitude >= minLat && coord.latitude <= maxLat &&
                coord.longitude >= minLon && coord.longitude <= maxLon
            }
            if vertexInBounds { return true }
            return airspace.containsPoint(region.center)
        }
    }

    // MARK: - Tests

    func testAirspacesInBoundsMatchesBruteForceAcrossGridBoundary() {
        // A1-A4 sit one in each of the four 1° cells around the (lat 45, lon 9) corner, all inside the
        // query bounds. A5 shares A1's cell but sits outside the query's lon range (same-bucket false
        // positive the exact filter must still reject). A6 is far away in an untouched cell. A7's own
        // bounding box spans all four cells around the corner — it must be inserted into every one of
        // them and still appear exactly ONCE in the result (dedup by id).
        let a1 = rectAirspace(id: "A1", minLat: 44.93, maxLat: 44.97, minLon: 8.93, maxLon: 8.97)
        let a2 = rectAirspace(id: "A2", minLat: 45.03, maxLat: 45.07, minLon: 8.93, maxLon: 8.97)
        let a3 = rectAirspace(id: "A3", minLat: 44.93, maxLat: 44.97, minLon: 9.03, maxLon: 9.07)
        let a4 = rectAirspace(id: "A4", minLat: 45.03, maxLat: 45.07, minLon: 9.03, maxLon: 9.07)
        let a5 = rectAirspace(id: "A5", minLat: 44.93, maxLat: 44.97, minLon: 8.78, maxLon: 8.82)
        let a6 = rectAirspace(id: "A6", minLat: 9.98, maxLat: 10.02, minLon: 9.98, maxLon: 10.02)
        let a7 = rectAirspace(id: "A7", minLat: 44.99, maxLat: 45.5, minLon: 8.99, maxLon: 9.5)
        let all = [a1, a2, a3, a4, a5, a6, a7]

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 45.0, longitude: 9.0),
            span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2))

        let service = OpenAIPDataService()
        service.seedForTesting(all)

        let gridResult = service.airspacesInBounds(region)
        let bruteResult = bruteForceAirspacesInBounds(all, region: region)

        XCTAssertEqual(Set(gridResult.map(\.id)), Set(bruteResult.map(\.id)))
        XCTAssertEqual(Set(gridResult.map(\.id)), ["A1", "A2", "A3", "A4", "A7"])
        XCTAssertEqual(gridResult.map(\.id).count, Set(gridResult.map(\.id)).count)   // A7 not duplicated
    }

    func testAirspacesInBoundsHandlesNegativeCoordinatesAcrossEquatorAndPrimeMeridian() {
        // Regression for the grid key's `.rounded(.down)` floor on negative degrees: a query straddling
        // 0°/0° must still match the brute-force oracle exactly.
        let southWest = rectAirspace(id: "SW", minLat: -0.05, maxLat: -0.02, minLon: -0.05, maxLon: -0.02)
        let northEast = rectAirspace(id: "NE", minLat: 0.02, maxLat: 0.05, minLon: 0.02, maxLon: 0.05)
        let farAway = rectAirspace(id: "FAR", minLat: 30, maxLat: 30.1, minLon: 30, maxLon: 30.1)
        let all = [southWest, northEast, farAway]

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2))

        let service = OpenAIPDataService()
        service.seedForTesting(all)

        let gridResult = service.airspacesInBounds(region)
        let bruteResult = bruteForceAirspacesInBounds(all, region: region)

        XCTAssertEqual(Set(gridResult.map(\.id)), Set(bruteResult.map(\.id)))
        XCTAssertEqual(Set(gridResult.map(\.id)), ["SW", "NE"])
    }
}
