import XCTest
import MapKit
import UIKit
@testable import AeroCheck

/// The Swiss charts as the maps draw them: the ICAO chart giving way to the glider chart, the route builder's
/// chart going on to the National Map, and Apple's map where swisstopo has nothing. The author's device checks
/// of 19 Oct 2026: the glider chart never showed, and outside Switzerland the charts drew black. (6.4.2)
@MainActor
final class SwissChartLayerTests: XCTestCase {

    private func layer(of overlay: MKTileOverlay, z: Int) -> String {
        let url = overlay.url(forTilePath: MKTileOverlayPath(x: 2151 >> (12 - min(z, 12)), y: 1435 >> (12 - min(z, 12)),
                                                             z: z, contentScaleFactor: 2))
        return url.pathComponents[2] + "." + url.pathExtension
    }

    // MARK: - ICAO, glider, National Map

    func testTheGliderChartFromZoomEleven() {
        let overlay = ICAOSegelflugkarteTileOverlay()
        XCTAssertEqual(layer(of: overlay, z: 10), "ch.bazl.luftfahrtkarten-icao.png")
        XCTAssertEqual(layer(of: overlay, z: 11), "ch.bazl.segelflugkarte.png")
        XCTAssertEqual(layer(of: overlay, z: 12), "ch.bazl.segelflugkarte.png")
        XCTAssertEqual(overlay.maximumZ, 12)
        // Forced, the ICAO chart to its last zoom.
        let forced = ICAOSegelflugkarteTileOverlay(forceICAO: true)
        XCTAssertEqual(layer(of: forced, z: 11), "ch.bazl.luftfahrtkarten-icao.png")
        XCTAssertEqual(forced.maximumZ, 11)
    }

    /// The route builder's chart: past the glider chart's z12, the National Map to z18. Never offline or forced,
    /// where the cache has only the charts.
    func testTheBuildersChartGoesOnToTheNationalMap() {
        let overlay = ICAOSegelflugkarteTileOverlay(continuesToNationalMap: true)
        XCTAssertEqual(layer(of: overlay, z: 12), "ch.bazl.segelflugkarte.png")
        XCTAssertEqual(layer(of: overlay, z: 13), "ch.swisstopo.pixelkarte-farbe.jpeg")
        XCTAssertEqual(layer(of: overlay, z: 17), "ch.swisstopo.pixelkarte-farbe.jpeg")
        XCTAssertEqual(overlay.maximumZ, 18)
        XCTAssertFalse(ICAOSegelflugkarteTileOverlay(isStrictOfflineMode: true, hasSegelflugCache: true,
                                                     continuesToNationalMap: true).continuesToNationalMap)
        XCTAssertFalse(ICAOSegelflugkarteTileOverlay(forceICAO: true, continuesToNationalMap: true).continuesToNationalMap)
    }

    // MARK: - Outside Switzerland

    /// The National Map's tile at z12 over Lyon as swisstopo serves it (668 bytes, 19 Oct 2026): plain white.
    static let blankNationalMapTile = Data(base64Encoded: [
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAQDAwMDAgQDAwMEBAQFBgoGBgUFBgwICQcKDgwPDg4MDQ0PERYTDxAVEQ0NExoTFRcY",
        "GRkZDxIbHRsYHRYYGRj/2wBDAQQEBAYFBgsGBgsYEA0QGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgYGBgY",
        "GBgYGBgYGBj/wAARCAEAAQADASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAj/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QA",
        "FAEBAAAAAAAAAAAAAAAAAAAAAP/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/AL+AAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB//9k=",
    ].joined())!

    private func jpeg(_ color: UIColor, side: CGFloat) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }()).jpegData(withCompressionQuality: 0.75) { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    /// The National Map's plain white tile outside Switzerland is none. Small and plain but not white, it is a
    /// tile; the plainest real tiles, a lake's, weigh 2.3 KB and more (its hatching), so above 2 KB is always one.
    func testAPlainWhiteTileIsNone() {
        XCTAssertEqual(Self.blankNationalMapTile.count, 668)
        XCTAssertTrue(SwisstopoTiles.isBlank(Self.blankNationalMapTile))
        let blue = jpeg(UIColor(red: 0.6, green: 0.8, blue: 1, alpha: 1), side: 16)
        XCTAssertLessThanOrEqual(blue.count, SwisstopoTiles.blankTileMaxBytes)
        XCTAssertFalse(SwisstopoTiles.isBlank(blue))
        XCTAssertFalse(SwisstopoTiles.isBlank(jpeg(.white, side: 256)), "a white tile that large is drawn")
        XCTAssertFalse(SwisstopoTiles.isBlank(Data("not an image".utf8)))
    }

    /// Every Swiss layer of the builder and the waypoint picker leaves Apple's map under it, its imagery under
    /// SWISSIMAGE, so where swisstopo has nothing Apple's map shows rather than black; the charts and the
    /// National Map go down to the streets.
    /// Plan › Map and the Cockpit: Apple's map under the chart, as the route builder since 6.4.2, so nothing past
    /// the chart's edge is black; the chart alone in strict offline mode, which Apple's map would not respect.
    /// (6.7.0, the author's m1 A and m2 A)
    func testPlanMapAndTheCockpitLeaveApplesMapUnderTheChart() {
        for layer in MapLayerType.allCases {
            let online = SwissMapView.chartOverlay(for: layer, forceICAO: false, strictOffline: false, segelflugCache: false)
            let offline = SwissMapView.chartOverlay(for: layer, forceICAO: false, strictOffline: true, segelflugCache: true)
            if layer == .standard || layer == .satellite {
                XCTAssertNil(online, "\(layer): Apple's own map, no chart")
                XCTAssertNil(offline, "\(layer)")
            } else {
                XCTAssertEqual(online?.canReplaceMapContent, false, "\(layer): Apple's map under the chart")
                XCTAssertEqual(offline?.canReplaceMapContent, true, "\(layer): strict offline, the chart alone")
            }
            XCTAssertEqual(SwissMapView.mapType(for: layer),
                           layer == .swissimage || layer == .satellite ? .satellite : .standard, "\(layer)")
        }
        let national = SwissMapView.chartOverlay(for: .landeskarten, forceICAO: false, strictOffline: false,
                                                 segelflugCache: false)
        XCTAssertEqual((national as? SwisstopoTileOverlay)?.dropsBlankTiles, true,
                       "the National Map's white tiles outside Switzerland are no tile, so Apple's map shows")
    }

    func testTheBuildersLayersLeaveApplesMapUnderneath() {
        for layer in WaypointPickerMapLayer.allCases {
            let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
            layer.apply(to: map)
            let tiles = map.overlays.compactMap { $0 as? MKTileOverlay }
            let apple = layer == .apple || layer == .appleSatellite
            XCTAssertEqual(tiles.count, apple ? 0 : 1, "\(layer)")
            XCTAssertTrue(tiles.allSatisfy { !$0.canReplaceMapContent }, "\(layer)")
            XCTAssertEqual(map.mapType, layer == .swissimage || layer == .appleSatellite ? .satellite : .standard, "\(layer)")
            XCTAssertFalse(layer.title.isEmpty)
            if !apple {
                XCTAssertEqual(layer.cameraZoomRange?.minCenterCoordinateDistance, 1_500, "\(layer)")
            }
            // Switching layers leaves one overlay.
            layer.apply(to: map)
            XCTAssertLessThanOrEqual(map.overlays.compactMap { $0 as? MKTileOverlay }.count, 1)
        }
        let national = MKMapView()
        WaypointPickerMapLayer.nationalMap.apply(to: national)
        XCTAssertEqual((national.overlays.first as? SwisstopoTileOverlay)?.dropsBlankTiles, true)
        let chart = MKMapView()
        WaypointPickerMapLayer.icao.apply(to: chart)
        XCTAssertEqual((chart.overlays.first as? ICAOSegelflugkarteTileOverlay)?.continuesToNationalMap, true)
    }

    /// Plan › Map and the Cockpit's MAP come close enough for the glider chart: 30 km, where 65 km stopped about
    /// z10 to z11.
    func testTheNavMapComesCloseEnoughForTheGliderChart() {
        XCTAssertLessThanOrEqual(SwissMapView.icaoGliderClosestDistance, 30_000)
    }

    /// One chart for every map (the author's device check, 23 Oct 2026): the builder's names map onto Plan › Map's
    /// both ways, and where the Swiss charts have nothing, Apple's map, its satellite view for SWISSIMAGE. (6.5.0)
    func testOneChartForEveryMapAndApplesWhereTheChartsEnd() {
        for layer in MapLayerType.allCases {
            XCTAssertEqual(WaypointPickerMapLayer(layer).mapLayerType, layer)
        }
        for layer in WaypointPickerMapLayer.allCases {
            XCTAssertEqual(WaypointPickerMapLayer(layer.mapLayerType), layer)
        }
        let bern = MKCoordinateRegion(center: .init(latitude: 46.95, longitude: 7.45),
                                      span: .init(latitudeDelta: 0.5, longitudeDelta: 0.5))
        let paloAlto = MKCoordinateRegion(center: .init(latitude: 37.46, longitude: -122.11),
                                          span: .init(latitudeDelta: 0.3, longitudeDelta: 0.3))
        let mulhouse = MKCoordinateRegion(center: .init(latitude: 47.75, longitude: 7.10),
                                          span: .init(latitudeDelta: 0.4, longitudeDelta: 0.4))
        let lyon = MKCoordinateRegion(center: .init(latitude: 45.73, longitude: 4.83),
                                      span: .init(latitudeDelta: 0.4, longitudeDelta: 0.4))
        XCTAssertEqual(MapLayerType.icao.shown(over: bern), .icao)
        XCTAssertEqual(MapLayerType.icao.shown(over: mulhouse), .icao, "over the border, the chart's margin")
        XCTAssertEqual(MapLayerType.icao.shown(over: paloAlto), .standard)
        XCTAssertEqual(MapLayerType.landeskarten.shown(over: lyon), .standard)
        XCTAssertEqual(MapLayerType.swissimage.shown(over: paloAlto), .satellite)
        XCTAssertEqual(MapLayerType.satellite.shown(over: bern), .satellite, "Apple's maps are everywhere")
        XCTAssertEqual(WaypointPickerMapLayer.shown(for: .icao, over: paloAlto), .apple)
        XCTAssertFalse(L10n.MapLayer.switzerlandOnly("ICAO chart", "Apple Maps").isEmpty)
    }
}
