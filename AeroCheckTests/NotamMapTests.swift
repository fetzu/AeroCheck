import CoreLocation
import XCTest
@testable import AeroCheck

/// The NOTAM areas layer: what it draws, what a tap reads, its tag and its switch.
final class NotamMapTests: NotamTestCase {

    func testTheLayerDrawsAirspaceCirclesAndObstaclesOfItsWindow() {
        var area = notam("1", lat: 47, lon: 7, radius: 3, kind: .airspace)
        area.start = noon
        let region = notam("2", lat: 47, lon: 7, radius: 51, kind: .airspace)
        let whole = notam("3", lat: 47, lon: 7, radius: 999, kind: .airspace)
        let mast = notam("4", lat: 47, lon: 7, kind: .obstacle)
        let runway = notam("5", lat: 47, lon: 7, radius: 3, kind: .aerodrome)
        let old = notam("6", lat: 47, lon: 7, radius: 3, end: noon.addingTimeInterval(-1), kind: .airspace)
        let noPoint = notam("7", radius: 3, kind: .airspace)
        let items = [area, region, whole, mast, runway, old, noPoint].compactMap { NotamMapContent.item($0, from: noon, to: noon) }
        XCTAssertEqual(items.map(\.id), ["1", "4"])
        XCTAssertEqual(items.map(\.shape), [.area(radiusNm: 3), .obstacle])
        XCTAssertNotNil(NotamMapContent.item(notam("8", lat: 47, lon: 7, radius: 50, kind: .airspace), from: noon, to: noon), "50 NM is in")
    }

    func testTheLayerKeepsToTheMapsNeighbourhoodNearestFirst() {
        let far = notam("1", lat: 40, lon: 7, radius: 3, kind: .airspace)
        let near = notam("2", lat: 47.1, lon: 7, radius: 3, kind: .airspace)
        let nearest = notam("3", lat: 47, lon: 7, radius: 3, kind: .airspace)
        let items = NotamMapContent.items([far, near, nearest], from: noon, to: noon, centre: .init(latitude: 47, longitude: 7), latSpan: 1, lonSpan: 1)
        XCTAssertEqual(items.map(\.id), ["3", "2"])
    }

    func testARingIsClosedAtItsRadius() throws {
        let centre = CLLocationCoordinate2D(latitude: 47, longitude: 7)
        let ring = NotamMapContent.ring(centre: centre, radiusNm: 10)
        let (first, last) = (try XCTUnwrap(ring.first), try XCTUnwrap(ring.last))
        XCTAssertEqual(first.latitude, last.latitude, accuracy: 1e-9)
        for point in ring { XCTAssertEqual(NotamGeometry.distanceNm(centre, point), 10, accuracy: 0.05) }
    }

    func testATapOnTheEdgeOrInside() throws {
        let item = try XCTUnwrap(NotamMapContent.item(notam("1", lat: 47, lon: 7, radius: 6, kind: .airspace), from: noon, to: noon))
        let edge = CLLocationCoordinate2D(latitude: 47.1, longitude: 7)
        let inside = CLLocationCoordinate2D(latitude: 47.03, longitude: 7)
        XCTAssertEqual(NotamMapContent.hits([item], at: edge, toleranceNm: 0.5, insideToo: false).map(\.id), ["1"])
        XCTAssertTrue(NotamMapContent.hits([item], at: inside, toleranceNm: 0.5, insideToo: false).isEmpty)
        XCTAssertEqual(NotamMapContent.hits([item], at: inside, toleranceNm: 0.5, insideToo: true).map(\.id), ["1"])
    }

    func testARepeatedNotamIsOneCircle() {
        let a = notam("1", at: "LFBB", lat: 47, lon: 7, radius: 3, kind: .airspace, number: "A0001/26")
        var b = notam("2", at: "LFEE", lat: 47, lon: 7, radius: 3, kind: .airspace, number: "A0001/26")
        b.text = a.text
        let items = NotamMapContent.items([a, b], from: noon, to: noon, centre: CLLocationCoordinate2D(latitude: 47, longitude: 7), latSpan: 1, lonSpan: 1)
        XCTAssertEqual(items.count, 1)
    }

    func testAnAreasTagIsTheChartsBoxInViolet() {
        var n = notam("1", lat: 47, lon: 7, radius: 3, kind: .airspace)
        n.upperFl = 95
        let tag = AirspaceTagContent(notam: n)
        XCTAssertEqual(tag.shape, .full)
        XCTAssertEqual(tag.upper, "FL 095")
        XCTAssertEqual(tag.lower, "SFC")
        XCTAssertEqual(tag.kind, .notam)
        XCTAssertEqual(tag.notamId, "1")
    }

    /// A small circle's tag goes beside it, on the first side that's free, and stays on its side.
    func testATagAroundACircleTakesTheFirstFreeSideAndKeepsIt() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 600)
        let size = CGSize(width: 136, height: 78)
        let north = CGPoint(x: 300, y: 60), east = CGPoint(x: 460, y: 200), south = CGPoint(x: 300, y: 360)
        let request = AirspaceTagPlacer.Request(id: "n", ring: [], size: size, around: [north, east, south])
        XCTAssertEqual(AirspaceTagPlacer.place([request], in: bounds, keepOut: [])["n"], north)
        let blocked = [CGRect(x: 260, y: 0, width: 80, height: 80)]
        XCTAssertEqual(AirspaceTagPlacer.place([request], in: bounds, keepOut: blocked)["n"], east, "the chrome has the north")
        var kept = request
        kept.previous = CGPoint(x: 301, y: 359)
        XCTAssertEqual(AirspaceTagPlacer.place([kept], in: bounds, keepOut: [])["n"], south, "it doesn't jump")
        let offTop = AirspaceTagPlacer.Request(id: "n", ring: [], size: size, around: [CGPoint(x: 300, y: 10)])
        XCTAssertNil(AirspaceTagPlacer.place([offTop], in: bounds, keepOut: [])["n"], "off the chart: no tag, the circle stays")
    }

    func testTheLayerIsOffByDefaultAndNoPresetTouchesIt() throws {
        XCTAssertFalse(AppSettings().showNotamAreasOnMap)
        var settings = AppSettings()
        settings.showNotamAreasOnMap = true
        MapPreset.everything.apply(to: &settings)
        XCTAssertTrue(settings.showNotamAreasOnMap)
        MapPreset.cruise.apply(to: &settings)
        XCTAssertTrue(settings.showNotamAreasOnMap)
        XCTAssertTrue(MapPreset.cruise.matches(settings))
    }

    func testAnOlderSettingsFileReadsTheLayerAsOff() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.showNotamAreasOnMap)
    }

    func testTheLayerShowsOnPlanMapAndMAPOnly() {
        XCTAssertTrue(MapFeatures.navigation.contains(.notamAreas))
        XCTAssertTrue(MapFeatures.cockpit.contains(.notamAreas))
        XCTAssertFalse(MapFeatures.dryRun.contains(.notamAreas))
        XCTAssertFalse(MapFeatures.builder.contains(.notamAreas))
    }
}
