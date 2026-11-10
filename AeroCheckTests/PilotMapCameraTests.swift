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

    /// The follow's glide (6.10.0, device check f-1): as long as since the last fix, so the map arrives as the next one
    /// is due; never with Reduce Motion, after a gap, for a jump of a third of the map or more, or with the aircraft
    /// off the centre to start from.
    func testTheFollowGlidesAsLongAsSinceTheLastFix() {
        typealias C = PilotMapView.Coordinator
        let size = CGSize(width: 820, height: 600)
        XCTAssertEqual(C.glidePace(since: 1.0, jump: 5, mapSize: size, onCentre: true, reduceMotion: false), 1.0)
        XCTAssertEqual(C.glidePace(since: 0.01, jump: 1, mapSize: size, onCentre: true, reduceMotion: false), 0.02,
                       "two fixes in a moment: 20 ms at the least")
        XCTAssertNil(C.glidePace(since: 1.0, jump: 5, mapSize: size, onCentre: true, reduceMotion: true))
        XCTAssertNil(C.glidePace(since: C.glideGap, jump: 5, mapSize: size, onCentre: true, reduceMotion: false), "a gap")
        XCTAssertNil(C.glidePace(since: 1.0, jump: 200, mapSize: size, onCentre: true, reduceMotion: false), "a long jump")
        XCTAssertNil(C.glidePace(since: 1.0, jump: 5, mapSize: size, onCentre: false, reduceMotion: false),
                     "the pilot just asked to follow again")
        // About a point a frame, a rate that divides 60: 10 at the least (cruise at 1x), 30 at the most (30x).
        XCTAssertEqual(C.glideFrames(pointsPerSecond: 5), 10)
        XCTAssertEqual(C.glideFrames(pointsPerSecond: 14), 15)
        XCTAssertEqual(C.glideFrames(pointsPerSecond: 20), 20)
        XCTAssertEqual(C.glideFrames(pointsPerSecond: 160), 30)
    }

    /// One fix, then two in the same 50 ms (a dry run at 30x), or one late: each is shown a fixed delay after its own
    /// time, so the map covers them at the aircraft's pace, never one speed then twice it, never waiting (the author's
    /// g-2, round 6: smooth a few frames, then a hitch).
    func testTheGlideShowsEachFixAFixedDelayAfterItsTime() {
        typealias C = PilotMapView.Coordinator
        let size = CGSize(width: 820, height: 600)
        let delay = C.glideDelay(interval: 1.0 / 30)
        XCTAssertEqual(delay, 1.0 / 30 + 0.1, accuracy: 1e-9)
        XCTAssertEqual(C.glideDelay(interval: 1.0), 1.1, accuracy: 1e-9, "in flight: 1.1 s")
        // Taken 10 ms ago, or 40 ms ago (late): the glide ends at the same moment after each fix's own time.
        let fresh = C.glidePace(since: 0.05, jump: 5, mapSize: size, onCentre: true, reduceMotion: false, age: 0.01, delay: delay)!
        let late = C.glidePace(since: 0.05, jump: 5, mapSize: size, onCentre: true, reduceMotion: false, age: 0.04, delay: delay)!
        XCTAssertEqual(fresh - late, 0.03, accuracy: 1e-9)
        XCTAssertEqual(C.glidePace(since: 0.8, jump: 5, mapSize: size, onCentre: true, reduceMotion: false), 0.8,
                       "no time on the fix: as long as since the last one")
    }

    /// The drive's place at a moment: between the two fixes around it, on along the last leg a little past the last
    /// fix (one late never stops the map), then held; the heading turns the short way.
    func testTheDriveFindsTheAircraftBetweenTwoFixes() {
        typealias C = PilotMapView.Coordinator
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let fixes = [C.GlideFix(time: t0, coordinate: .init(latitude: 47, longitude: 7), heading: 350),
                     C.GlideFix(time: t0 + 1, coordinate: .init(latitude: 47.001, longitude: 7), heading: 10),
                     C.GlideFix(time: t0 + 2, coordinate: .init(latitude: 47.002, longitude: 7), heading: 10)]
        let half = C.glidePosition(fixes, at: t0 + 0.5, reach: 1)!
        XCTAssertEqual(half.coordinate.latitude, 47.0005, accuracy: 1e-9)
        XCTAssertEqual(half.heading, 0, accuracy: 1e-9, "350 to 10: through north")
        XCTAssertEqual(C.glidePosition(fixes, at: t0 + 2.5, reach: 1)!.coordinate.latitude, 47.0025, accuracy: 1e-9,
                       "a fix late: on along the last leg")
        XCTAssertEqual(C.glidePosition(fixes, at: t0 + 9, reach: 1)!.coordinate.latitude, 47.003, accuracy: 1e-9,
                       "then held one leg on")
        XCTAssertEqual(C.glidePosition(fixes, at: t0 - 1, reach: 1)!.coordinate.latitude, 47, accuracy: 1e-9)
        XCTAssertNil(C.glidePosition([], at: t0, reach: 1))
    }
}
