import XCTest
import CoreLocation
import MapKit
@testable import AeroCheck

/// The map under the open legs-and-frequencies panel (6.1, option C): the chrome that goes, the band
/// that frames the aircraft and the next waypoint, and the map put back when the panel closes.
final class LegsPanelMapTests: XCTestCase {

    // An iPad in portrait with the panel open: the chart 820 x 280 pt, the card's foot at 96 pt.
    private let viewSize = CGSize(width: 820, height: 280)
    private let band = CGRect(x: 0, y: 96, width: 820, height: 184)
    /// The pilot's zoom: map points per screen point (about 30 m a point in Switzerland).
    private let scale = 200.0
    private let aircraft = MKMapPoint(CLLocationCoordinate2D(latitude: 47.35, longitude: 6.98))

    /// A point `east` and `south` screen points from the aircraft at the pilot's zoom, north up.
    private func offset(east: Double, south: Double) -> MKMapPoint {
        MKMapPoint(x: aircraft.x + east * scale, y: aircraft.y + south * scale)
    }

    private func onScreen(_ point: MKMapPoint, _ placement: LegsPanelMap.Placement,
                          heading: CLLocationDirection = 0) -> CGPoint {
        LegsPanelMap.screenPoint(of: point, center: placement.center, scale: scale * placement.zoomOut,
                                 heading: heading, viewSize: viewSize)
    }

    private func assertInside(_ point: CGPoint, _ rect: CGRect, _ message: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(rect.insetBy(dx: -0.5, dy: -0.5).contains(point), "\(message): \(point) not in \(rect)",
                      file: file, line: line)
    }

    private var innerBand: CGRect { band.insetBy(dx: LegsPanelMap.margin, dy: LegsPanelMap.margin) }

    // MARK: - Chrome

    func testClosedPanelLeavesTheMapItsChrome() {
        let chrome = LegsPanelMap.Chrome.forPanel(open: false)
        XCTAssertTrue(chrome.showsMapControls)
        XCTAssertTrue(chrome.showsMapStatus)
        XCTAssertTrue(chrome.showsRouteOffScreenPill)
        XCTAssertTrue(chrome.showsNextWaypoint)
        XCTAssertTrue(chrome.showsUndoToast)
        XCTAssertFalse(chrome.bandClosesPanel, "closed, the chart is a map to work in")
    }

    func testOpenPanelHidesTheMapsControlsAndKeepsTheCard() {
        let chrome = LegsPanelMap.Chrome.forPanel(open: true)
        XCTAssertFalse(chrome.showsMapControls, "Map, North up / Track up, Centre, − and +")
        XCTAssertFalse(chrome.showsMapStatus, "CACHED and the scale bar")
        XCTAssertFalse(chrome.showsRouteOffScreenPill, "Show would move the camera, as Centre does")
        XCTAssertTrue(chrome.showsNextWaypoint, "the card stays where it is")
        XCTAssertTrue(chrome.showsUndoToast, "a MARK can still be taken back")
        XCTAssertTrue(chrome.bandClosesPanel, "the band is a view: a tap closes the panel")
    }

    // MARK: - The band, measured

    func testThePortraitBandRunsFromTheCardToThePanel() {
        let rect = LegsPanelMap.bandRect(chartSize: CGSize(width: 820, height: 280), chromeBottom: 96,
                                         mapFrame: CGRect(x: 0, y: 0, width: 820, height: 280), panelInset: 0)
        XCTAssertEqual(rect, CGRect(x: 0, y: 96, width: 820, height: 184))
    }

    func testTheLandscapeBandStopsAtThePanelOverTheChartsFoot() {
        // The map runs 20 pt under the home indicator; the panel covers the chart's lower 193 pt.
        let rect = LegsPanelMap.bandRect(chartSize: CGSize(width: 760, height: 459), chromeBottom: 96,
                                         mapFrame: CGRect(x: 0, y: 0, width: 760, height: 479), panelInset: 193)
        XCTAssertEqual(rect, CGRect(x: 0, y: 96, width: 760, height: 170))
    }

    func testTheBandIsInTheMapViewsPointsWhereTheMapRunsUnderASafeArea() {
        // A map view starting 20 pt above the chart and 44 pt left of it: the band moves with it.
        let rect = LegsPanelMap.bandRect(chartSize: CGSize(width: 400, height: 300), chromeBottom: 60,
                                         mapFrame: CGRect(x: -44, y: -20, width: 444, height: 320), panelInset: 0)
        XCTAssertEqual(rect, CGRect(x: 44, y: 80, width: 400, height: 240))
    }

    func testAChromeTallerThanTheChartLeavesNoBandRatherThanANegativeOne() {
        let rect = LegsPanelMap.bandRect(chartSize: CGSize(width: 400, height: 100), chromeBottom: 140,
                                         mapFrame: CGRect(x: 0, y: 0, width: 400, height: 100), panelInset: 30)
        XCTAssertEqual(rect.height, 0)
    }

    // MARK: - Framing

    func testWithNoRouteTheAircraftSitsInTheMiddleOfTheBandNotOfTheView() {
        let placement = LegsPanelMap.place(aircraft: aircraft, waypoint: nil, heading: 0, band: band,
                                           viewSize: viewSize, scale: scale, previous: nil)
        XCTAssertEqual(placement.framing, .aircraftAlone)
        XCTAssertEqual(placement.zoomOut, 1)
        let point = onScreen(aircraft, placement)
        XCTAssertEqual(point.x, band.midX, accuracy: 0.01)
        XCTAssertEqual(point.y, band.midY, accuracy: 0.01, "centred under the card, not behind it")
        XCTAssertNotEqual(point.y, viewSize.height / 2, accuracy: 1)
    }

    func testTheBandIsFramedAroundWhereMapKitPutsTheCameraNotTheViewsMiddle() {
        // MapKit centres the camera in the map's safe area: a map view running 32 pt under a bar at its
        // top has its camera point 16 pt lower. The aircraft still lands in the band's middle.
        let cameraPoint = CGPoint(x: viewSize.width / 2, y: 32 + (viewSize.height - 32) / 2)
        let placement = LegsPanelMap.place(aircraft: aircraft, waypoint: nil, heading: 0, band: band,
                                           viewSize: viewSize, cameraPoint: cameraPoint, scale: scale,
                                           previous: nil)
        let point = LegsPanelMap.screenPoint(of: aircraft, center: placement.center, scale: scale, heading: 0,
                                             viewSize: viewSize, cameraPoint: cameraPoint)
        XCTAssertEqual(point.x, band.midX, accuracy: 0.01)
        XCTAssertEqual(point.y, band.midY, accuracy: 0.01)
        // Framed as if MapKit used the view's middle, it would sit 16 pt low.
        let naive = LegsPanelMap.place(aircraft: aircraft, waypoint: nil, heading: 0, band: band,
                                       viewSize: viewSize, scale: scale, previous: nil)
        let off = LegsPanelMap.screenPoint(of: aircraft, center: naive.center, scale: scale, heading: 0,
                                           viewSize: viewSize, cameraPoint: cameraPoint)
        XCTAssertEqual(off.y - band.midY, 16, accuracy: 0.01)
    }

    func testAWaypointThatFitsKeepsThePilotsZoom() {
        let waypoint = offset(east: 300, south: -60)
        let placement = LegsPanelMap.place(aircraft: aircraft, waypoint: waypoint, heading: 0, band: band,
                                           viewSize: viewSize, scale: scale, previous: nil)
        XCTAssertEqual(placement.framing, .aircraftAndWaypoint)
        XCTAssertEqual(placement.zoomOut, 1, "no zooming when both fit")
        let a = onScreen(aircraft, placement), w = onScreen(waypoint, placement)
        assertInside(a, innerBand, "the aircraft")
        assertInside(w, innerBand, "the waypoint")
        XCTAssertEqual((a.x + w.x) / 2, band.midX, accuracy: 0.01, "the two centred in the band")
        XCTAssertEqual((a.y + w.y) / 2, band.midY, accuracy: 0.01)
        XCTAssertEqual(w.x - a.x, 300, accuracy: 0.01, "at the pilot's zoom")
    }

    func testAWaypointOutOfTheBandZoomsOutJustEnough() {
        // 1'200 pt east: the band holds 764 between its margins.
        let waypoint = offset(east: 1_200, south: 0)
        let placement = LegsPanelMap.place(aircraft: aircraft, waypoint: waypoint, heading: 0, band: band,
                                           viewSize: viewSize, scale: scale, previous: nil)
        XCTAssertEqual(placement.framing, .aircraftAndWaypoint)
        XCTAssertEqual(placement.zoomOut, 1_200 / innerBand.width, accuracy: 0.0001)
        let a = onScreen(aircraft, placement), w = onScreen(waypoint, placement)
        XCTAssertEqual(a.x, innerBand.minX, accuracy: 0.01, "just enough: the two at the band's edges")
        XCTAssertEqual(w.x, innerBand.maxX, accuracy: 0.01)
        assertInside(a, innerBand, "the aircraft")
        assertInside(w, innerBand, "the waypoint")
    }

    func testTheBandsHeightIsWhatLimitsAWaypointNorthOfTheAircraft() {
        // 300 pt north: 128 pt of band height between the margins, so 2.3 times out, under the 3.
        let waypoint = offset(east: 0, south: -300)
        let placement = LegsPanelMap.place(aircraft: aircraft, waypoint: waypoint, heading: 0, band: band,
                                           viewSize: viewSize, scale: scale, previous: nil)
        XCTAssertEqual(placement.framing, .aircraftAndWaypoint)
        XCTAssertEqual(placement.zoomOut, 300 / innerBand.height, accuracy: 0.0001)
        assertInside(onScreen(aircraft, placement), innerBand, "the aircraft")
        assertInside(onScreen(waypoint, placement), innerBand, "the waypoint")
    }

    func testAFarWaypointKeepsTheZoomWithTheAircraftLowAndTheRouteAhead() {
        // 600 pt north, about 4.7 bands: not worth zooming out for.
        let waypoint = offset(east: 0, south: -600)
        let placement = LegsPanelMap.place(aircraft: aircraft, waypoint: waypoint, heading: 0, band: band,
                                           viewSize: viewSize, scale: scale, previous: nil)
        XCTAssertEqual(placement.framing, .routeAhead)
        XCTAssertEqual(placement.zoomOut, 1, "the pilot's zoom")
        let a = onScreen(aircraft, placement), w = onScreen(waypoint, placement)
        XCTAssertEqual(a.x, band.midX, accuracy: 0.01)
        XCTAssertEqual(a.y, innerBand.maxY, accuracy: 0.01, "low in the band")
        XCTAssertEqual(w.x, a.x, accuracy: 0.01, "the route runs straight up the band from it")
        XCTAssertLessThan(w.y, band.minY, "the waypoint itself beyond the card")
    }

    func testAFarWaypointEastPutsTheAircraftOnTheBandsWestSideInNorthUp() {
        let waypoint = offset(east: 4_000, south: 0)
        let placement = LegsPanelMap.place(aircraft: aircraft, waypoint: waypoint, heading: 0, band: band,
                                           viewSize: viewSize, scale: scale, previous: nil)
        XCTAssertEqual(placement.framing, .routeAhead)
        let a = onScreen(aircraft, placement)
        XCTAssertEqual(a.x, innerBand.minX, accuracy: 0.01, "the band's length of route ahead of it")
        XCTAssertEqual(a.y, band.midY, accuracy: 0.01)
    }

    func testTrackUpTurnsTheBandToTheTrack() {
        // Tracking east, the waypoint 100 pt east: on screen, straight ahead of the aircraft, i.e. above.
        let near = offset(east: 100, south: 0)
        let placement = LegsPanelMap.place(aircraft: aircraft, waypoint: near, heading: 90, band: band,
                                           viewSize: viewSize, scale: scale, previous: nil)
        let a = onScreen(aircraft, placement, heading: 90), w = onScreen(near, placement, heading: 90)
        XCTAssertEqual(w.x, a.x, accuracy: 0.01)
        XCTAssertEqual(a.y - w.y, 100, accuracy: 0.01, "ahead is up")
        assertInside(a, innerBand, "the aircraft")
        assertInside(w, innerBand, "the waypoint")

        // Far ahead, the aircraft goes low in the band, as in North up on a northbound leg.
        let far = offset(east: 2_000, south: 0)
        let farPlacement = LegsPanelMap.place(aircraft: aircraft, waypoint: far, heading: 90, band: band,
                                              viewSize: viewSize, scale: scale, previous: nil)
        XCTAssertEqual(farPlacement.framing, .routeAhead)
        let low = onScreen(aircraft, farPlacement, heading: 90)
        XCTAssertEqual(low.x, band.midX, accuracy: 0.01)
        XCTAssertEqual(low.y, innerBand.maxY, accuracy: 0.01)
    }

    func testTheRouteAheadHoldsUntilTheWaypointFitsAtThePilotsZoom() {
        // Closing in on a far waypoint: 2 bands out, it would zoom out by 2 from scratch, but the band
        // keeps the pilot's zoom rather than jump out as the aircraft closes in.
        let closer = offset(east: 0, south: -256)
        let held = LegsPanelMap.place(aircraft: aircraft, waypoint: closer, heading: 0, band: band,
                                      viewSize: viewSize, scale: scale, previous: .routeAhead)
        XCTAssertEqual(held.framing, .routeAhead)
        XCTAssertEqual(held.zoomOut, 1)
        let fresh = LegsPanelMap.place(aircraft: aircraft, waypoint: closer, heading: 0, band: band,
                                       viewSize: viewSize, scale: scale, previous: nil)
        XCTAssertEqual(fresh.framing, .aircraftAndWaypoint)
        XCTAssertEqual(fresh.zoomOut, 2, accuracy: 0.0001)

        // Once it fits, the two are framed together, the aircraft where the route ahead had it.
        let inReach = offset(east: 0, south: -120)
        let fits = LegsPanelMap.place(aircraft: aircraft, waypoint: inReach, heading: 0, band: band,
                                      viewSize: viewSize, scale: scale, previous: .routeAhead)
        XCTAssertEqual(fits.framing, .aircraftAndWaypoint)
        XCTAssertEqual(fits.zoomOut, 1)
    }

    func testATooSmallBandFramesInTheWholeView() {
        let placement = LegsPanelMap.place(aircraft: aircraft, waypoint: nil, heading: 0,
                                           band: CGRect(x: 0, y: 280, width: 820, height: 0),
                                           viewSize: viewSize, scale: scale, previous: nil)
        let point = onScreen(aircraft, placement)
        XCTAssertEqual(point.x, viewSize.width / 2, accuracy: 0.01)
        XCTAssertEqual(point.y, viewSize.height / 2, accuracy: 0.01)
    }

    // MARK: - Closing

    private let saved = LegsPanelMap.SavedCamera(
        center: CLLocationCoordinate2D(latitude: 47.0, longitude: 7.5),
        span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.3),
        distance: 42_000, heading: 12, following: false)

    func testAPannedMapComesBackExactly() {
        let restored = LegsPanelMap.restored(saved, aircraft: CLLocationCoordinate2D(latitude: 47.35, longitude: 6.98),
                                             trackUpCourse: nil)
        XCTAssertEqual(restored, saved, "centre, zoom and heading as the pilot left them, not following")
    }

    func testAPannedMapInTrackUpKeepsItsOwnHeadingToo() {
        let restored = LegsPanelMap.restored(saved, aircraft: CLLocationCoordinate2D(latitude: 47.35, longitude: 6.98),
                                             trackUpCourse: 211)
        XCTAssertEqual(restored, saved)
    }

    func testAFollowingMapKeepsFollowingAtItsZoom() {
        var following = saved
        following.following = true
        following.heading = 0
        let now = CLLocationCoordinate2D(latitude: 47.35, longitude: 6.98)
        let restored = LegsPanelMap.restored(following, aircraft: now, trackUpCourse: nil)
        XCTAssertTrue(restored.following)
        XCTAssertEqual(restored.center.latitude, now.latitude)
        XCTAssertEqual(restored.center.longitude, now.longitude, "on the aircraft where it is now")
        XCTAssertEqual(restored.distance, 42_000, "at the zoom it had, not the band's")
        XCTAssertEqual(restored.span.latitudeDelta, 0.2)
        XCTAssertEqual(restored.heading, 0, "North up")
    }

    func testAFollowingMapInTrackUpTakesTheTrackNow() {
        var following = saved
        following.following = true
        let restored = LegsPanelMap.restored(following, aircraft: CLLocationCoordinate2D(latitude: 47.35, longitude: 6.98),
                                             trackUpCourse: 211)
        XCTAssertEqual(restored.heading, 211)
        XCTAssertTrue(restored.following)
    }

    func testAFollowingMapWithNoFixGoesBackAsItWas() {
        var following = saved
        following.following = true
        XCTAssertEqual(LegsPanelMap.restored(following, aircraft: nil, trackUpCourse: 211), following)
    }
}
