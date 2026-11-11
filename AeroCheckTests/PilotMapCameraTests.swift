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

    /// The follow's frames (6.10.0, device check f-1): about a point a frame, a rate that divides 60: 10 at the least
    /// (cruise at 1x), 30 at the most (30x). And each fix is shown a fixed delay after its own time: one interval and a
    /// margin (the author's g-2, round 6: smooth a few frames, then a hitch).
    func testTheGlidesFramesAndDelay() {
        typealias C = PilotMapView.Coordinator
        XCTAssertEqual(C.glideFrames(pointsPerSecond: 5), 10)
        XCTAssertEqual(C.glideFrames(pointsPerSecond: 14), 15)
        XCTAssertEqual(C.glideFrames(pointsPerSecond: 20), 20)
        XCTAssertEqual(C.glideFrames(pointsPerSecond: 160), 30)
        XCTAssertEqual(C.glideDelay(interval: 1.0 / 30), 1.0 / 30 + 0.1, accuracy: 1e-9)
        XCTAssertEqual(C.glideDelay(interval: 1.0), 1.1, accuracy: 1e-9, "in flight: 1.1 s")
    }

    /// The follow is the pilot's flag and the shared state's centre on the aircraft, whatever the zoom (the author,
    /// 11 Nov: after a pan and Centre the map went step by step, for good when zoomed in, where a second's flight was
    /// further on screen than the old rule allowed): the latest fix, the one before (the state is a turn late), or the
    /// fix the camera is gliding to.
    func testTheFollowIsTheStatesCentreOnTheAircraft() {
        typealias C = PilotMapView.Coordinator
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let fixes = (0..<5).map { C.GlideFix(time: t0 + Double($0), coordinate: .init(latitude: 47 + Double($0) / 1000, longitude: 7), heading: 0) }
        XCTAssertTrue(C.follows(.init(latitude: 47.004, longitude: 7), fixes: fixes, target: nil), "the latest fix")
        XCTAssertTrue(C.follows(.init(latitude: 47.003, longitude: 7), fixes: fixes, target: nil), "the fix before")
        XCTAssertFalse(C.follows(.init(latitude: 47.0005, longitude: 7.01), fixes: fixes, target: nil), "panned away")
        XCTAssertFalse(C.follows(.init(latitude: 47, longitude: 7), fixes: fixes, target: nil), "a fix long passed")
        XCTAssertTrue(C.follows(.init(latitude: 46.5, longitude: 7), fixes: fixes, target: .init(latitude: 46.5, longitude: 7)))
        XCTAssertFalse(C.follows(.init(latitude: 47, longitude: 7), fixes: [], target: nil))
    }

    /// The aircraft's last fixes are kept whether the map follows or not, with how fast they come, so the drive can
    /// take the camera the moment the pilot asks (11 Nov). After a gap the glide to the first fix starts an interval
    /// before it, from where the aircraft is drawn: no hop, no wait.
    func testTheFixHistoryKeepsTheFixesPaceAndBridgesAGap() {
        typealias C = PilotMapView.Coordinator
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func fix(_ t: Double, _ lat: Double, heading: Double = 0) -> C.GlideFix {
            C.GlideFix(time: t0 + t, coordinate: .init(latitude: lat, longitude: 7), heading: heading)
        }
        var history = C.GlideHistory()
        history.note(fix(0, 47), rate: 1)
        XCTAssertNil(history.interval)
        XCTAssertEqual(history.metresPerSecond, 0)
        history.note(fix(1, 47.0005), rate: 1)
        XCTAssertEqual(history.interval ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(history.metresPerSecond, 55.6, accuracy: 0.5, "0.0005° of latitude in a second")
        history.note(fix(1, 47.0005, heading: 90), rate: 1)
        XCTAssertEqual(history.fixes.count, 2, "the same fix again: in place")
        XCTAssertEqual(history.fixes.last?.heading, 90)
        history.note(fix(0.5, 47.1), rate: 1)
        XCTAssertEqual(history.fixes.count, 2, "an older fix: left out")
        for i in 2..<10 { history.note(fix(Double(i), 47 + Double(i) * 0.0005), rate: 1) }
        XCTAssertEqual(history.fixes.count, 6)
        // A gap, the camera resting a little past the last fix: one interval before the new fix, from there.
        let resting = CLLocationCoordinate2D(latitude: 47.0046, longitude: 7)
        history.note(fix(60, 47.005), rate: 1, restingAt: resting)
        XCTAssertEqual(history.fixes.count, 2)
        XCTAssertEqual(history.fixes[0].time, t0 + 59)
        XCTAssertEqual(history.fixes[0].coordinate.latitude, 47.0046, accuracy: 1e-9)
        XCTAssertEqual(history.interval ?? 0, 1, accuracy: 1e-9, "the pace from before the gap")
        // A dry run at 30x: fixes a flight second apart come 33 ms apart, and a gap is 2.5 s of the wall clock.
        var fast = C.GlideHistory()
        fast.note(fix(0, 47), rate: 30)
        fast.note(fix(1, 47.0005), rate: 30)
        XCTAssertEqual(fast.interval ?? 0, 1.0 / 30, accuracy: 1e-9)
        fast.note(fix(31, 47.01), rate: 30)
        XCTAssertEqual(fast.fixes.count, 3, "31 flight seconds at 30x is one second: no gap")
        // The drive starts: stale fixes say nothing of the way on, and the headings are the camera's now.
        var parked = C.GlideHistory()
        parked.note(fix(0, 47, heading: 10), rate: 1)
        parked.note(fix(1, 47.0001, heading: 20), rate: 1)
        parked.start(now: t0 + 1.5, rate: 1, heading: 0)
        XCTAssertEqual(parked.fixes.map(\.heading), [0, 0])
        parked.start(now: t0 + 30, rate: 1, heading: 0)
        XCTAssertEqual(parked.fixes.count, 1)
        XCTAssertEqual(parked.fixes[0].coordinate.latitude, 47.0001, accuracy: 1e-9)
    }

    /// Asked to follow again, the camera and the marker ease onto the aircraft's place in a third of a second, quick
    /// first, exactly there at the end.
    func testTheDriveEasesOntoTheAircraft() {
        typealias C = PilotMapView.Coordinator
        XCTAssertEqual(C.glideEntryDuration, 0.35)
        XCTAssertEqual(C.entryLeft(progress: 0), 1)
        XCTAssertEqual(C.entryLeft(progress: 1), 0)
        XCTAssertEqual(C.entryLeft(progress: 4), 0)
        XCTAssertEqual(C.entryLeft(progress: -1), 1)
        XCTAssertLessThan(C.entryLeft(progress: 0.5), 0.2, "most of the way at half the time")
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

    /// The zoom buttons stop at the chart's own limits, and say so: + greyed at the closest, − at the farthest
    /// (device check h-4, round 7: at the limit the scale changed and the map didn't).
    func testTheZoomButtonsStopAtTheChartsLimits() {
        let state = SharedMapState()
        XCTAssertTrue(state.canZoom(in: true), "no limits yet: both buttons")
        state.zoomLimits = 1_000...100_000
        state.cameraDistance = 1_000
        XCTAssertFalse(state.canZoom(in: true))
        XCTAssertTrue(state.canZoom(in: false))
        state.cameraDistance = 100_000
        XCTAssertTrue(state.canZoom(in: true))
        XCTAssertFalse(state.canZoom(in: false))
    }

    /// Gliding, the drive does a zoom tap's move itself, in a fifth of a second: from where it was to the new distance,
    /// in the scale's terms, quick first, exactly there at the end (device check h-4, round 7: a MapLibre zoom under
    /// the drive stuttered).
    func testTheDriveZoomsInAFifthOfASecond() {
        typealias C = PilotMapView.Coordinator
        XCTAssertEqual(C.glideZoomDuration, 0.2)
        XCTAssertEqual(C.zoomedAltitude(from: 10_000, to: 5_000, progress: 0), 10_000, accuracy: 1e-6)
        XCTAssertEqual(C.zoomedAltitude(from: 10_000, to: 5_000, progress: 1), 5_000)
        XCTAssertEqual(C.zoomedAltitude(from: 10_000, to: 5_000, progress: 3), 5_000, "past the end: there")
        let half = C.zoomedAltitude(from: 10_000, to: 5_000, progress: 0.5)
        XCTAssertLessThan(half, 10_000 / 2.squareRoot(), "past halfway on the scale at half the time")
        XCTAssertGreaterThan(half, 5_000)
    }

    /// The drive moves the camera by whole screen pixels (the author, 11 Nov: zoomed out, the terrain shading wobbled,
    /// a picture moved by a fraction of a pixel blended sharp and blurred in turn).
    func testTheDriveMovesByWholePixels() {
        typealias C = PilotMapView.Coordinator
        XCTAssertEqual(C.pixelStep(CGPoint(x: 0.2, y: -0.2), scale: 2), .zero, "under half a pixel: no move")
        XCTAssertEqual(C.pixelStep(CGPoint(x: 0.3, y: 0.76), scale: 2), CGPoint(x: 0.5, y: 1.0))
        XCTAssertEqual(C.pixelStep(CGPoint(x: -1.26, y: 3.1), scale: 3), CGPoint(x: -4.0 / 3, y: 3))
        XCTAssertEqual(C.pixelStep(CGPoint(x: 0.6, y: 0.4), scale: 1), CGPoint(x: 1, y: 0))
    }
}
