import MapKit
import MapLibre
import XCTest
@testable import AeroCheck

/// The camera on MapLibre (6.8.0, PR 8): its zoom as a scale, the legs panel's band, a search's jump, the route
/// builder's hit-testing.
@MainActor
final class PilotMapCameraTests: XCTestCase {
    func testZoomIsAScale() {
        XCTAssertEqual(PilotMapZoom.scale(atZoom: 19), 1, accuracy: 1e-12)
        XCTAssertEqual(PilotMapZoom.scale(atZoom: 10), 512, accuracy: 1e-9)
        for z in [3.0, 8.4, 12.25, 17] {
            XCTAssertEqual(PilotMapZoom.zoom(forScale: PilotMapZoom.scale(atZoom: z)), z, accuracy: 1e-9)
        }
    }

    /// MapLibre's zoom on a real view says the same: a view at zoom z shows 2^(19-z) map points per screen point.
    func testTheScaleMatchesAMapView() {
        let view = MLNMapView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        view.setCenter(CLLocationCoordinate2D(latitude: 47, longitude: 7.5), zoomLevel: 11, animated: false)
        let a = MKMapPoint(view.convert(CGPoint(x: 150, y: 300), toCoordinateFrom: view))
        let b = MKMapPoint(view.convert(CGPoint(x: 250, y: 300), toCoordinateFrom: view))
        XCTAssertEqual(hypot(b.x - a.x, b.y - a.y) / 100, PilotMapZoom.scale(atZoom: 11), accuracy: 1)
    }

    func testASearchFramesEightMilesAcross() {
        let view = MLNMapView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        view.minimumZoomLevel = 0
        view.maximumZoomLevel = 22
        let lszq = Airport(id: 1, ident: "LSZQ", type: .smallAirport, name: "Bressaucourt", latitude: 47.3924,
                           longitude: 7.0290, elevation: 1860, continent: "EU", isoCountry: "CH", isoRegion: "CH-JU",
                           municipality: nil, scheduledService: false, gpsCode: nil, iataCode: nil, localCode: nil)
        XCTAssertTrue(PendingCameraMove(to: lszq).apply(to: view))
        XCTAssertEqual(view.centerCoordinate.latitude, 47.3924, accuracy: 1e-4)
        let left = CLLocation(latitude: 47.3924, longitude: view.convert(CGPoint(x: 0, y: 300), toCoordinateFrom: view).longitude)
        let right = CLLocation(latitude: 47.3924, longitude: view.convert(CGPoint(x: 400, y: 300), toCoordinateFrom: view).longitude)
        XCTAssertEqual(left.distance(from: right) / 1852, AirfieldSearch.spanNM, accuracy: 0.1, "the narrower side")
        XCTAssertFalse(PendingCameraMove(to: lszq).apply(to: MLNMapView(frame: .zero)), "no size: left pending")
    }

    func testTheBandMovesOnlyForAVisibleChange() {
        let a = (center: CLLocationCoordinate2D(latitude: 47, longitude: 7), zoom: 11.0, heading: 10.0)
        XCTAssertTrue(PilotLegsBand.isSame(a, a, scale: PilotMapZoom.scale(atZoom: 11)))
        var b = a
        b.zoom += 0.01
        XCTAssertFalse(PilotLegsBand.isSame(a, b, scale: PilotMapZoom.scale(atZoom: 11)))
        b = a
        b.heading = 10.4
        XCTAssertTrue(PilotLegsBand.isSame(a, b, scale: PilotMapZoom.scale(atZoom: 11)))
    }

    func testTheBuildersHitTesting() {
        let points = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 300, y: 300)]
        XCTAssertEqual(PlannedRouteLayer.waypointIndex(near: CGPoint(x: 302, y: 86), points: points, maxPointDistance: 34), 1,
                       "the balloon above the tip")
        XCTAssertNil(PlannedRouteLayer.waypointIndex(near: CGPoint(x: 200, y: 200), points: points, maxPointDistance: 34))
        XCTAssertEqual(PlannedRouteLayer.closestSegment(to: CGPoint(x: 200, y: 110), points: points, maxPointDistance: 22), 0)
        XCTAssertEqual(PlannedRouteLayer.closestSegment(to: CGPoint(x: 290, y: 200), points: points, maxPointDistance: 22), 1)
        XCTAssertNil(PlannedRouteLayer.closestSegment(to: CGPoint(x: 150, y: 250), points: points, maxPointDistance: 22))
    }
}
