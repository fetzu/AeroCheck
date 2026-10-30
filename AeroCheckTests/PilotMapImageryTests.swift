import CoreGraphics
import ImageIO
import XCTest
@testable import AeroCheck

/// The aerial imagery on the pilot's map (6.8.0): the sources list, the source chosen per tile, a tile composed across
/// a border with each source clipped to its area, the credits of what is on screen, a source switched off.
final class PilotMapImageryTests: XCTestCase {

    /// Two made-up sources meeting at 7.5° E: "west" (red) and "east" (blue), between 46° and 48° N.
    private func indexJSON(eastEnabled: Bool = true, eastSecret: Bool = false, westMaxZoom: Int = 19) -> Data {
        func source(_ id: String, _ w: Double, _ e: Double, enabled: Bool, secret: Bool, maxZoom: Int) -> [String: Any] {
            var s: [String: Any] = [
                "id": id, "enabled": enabled, "kind": "wmts", "template": "https://\(id).example/{z}/{x}/{y}.png",
                "tile_size": 256, "min_zoom": 6, "max_zoom": maxZoom, "credit": "© \(id) {year}",
                "credit_link": "https://\(id).example/about", "licence": "CC BY 4.0",
                "licence_link": "https://creativecommons.org/licenses/by/4.0/", "change_note": true,
                "area": ["codes": [id.uppercased()], "bbox": [w, 46, e, 48],
                         "polygons": [[[[w, 46], [e, 46], [e, 48], [w, 48], [w, 46]]]]],
            ]
            if secret { s["secret"] = "TEST_TOKEN"; s["secret_header"] = "token" }
            return s
        }
        let body: [String: Any] = ["version": 1, "sources": [
            source("west", 6.0, 7.5, enabled: true, secret: false, maxZoom: westMaxZoom),
            source("east", 7.5, 9.0, enabled: eastEnabled, secret: eastSecret, maxZoom: 19),
        ]]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func store(_ json: Data, secrets: [String: String] = [:]) throws -> ImageryStore {
        let dir = makeTestDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bundled = dir.appendingPathComponent("bundled.json")
        try json.write(to: bundled)
        return ImageryStore(directory: dir.appendingPathComponent("kept"), bundled: bundled,
                            fetch: { _ in throw URLError(.notConnectedToInternet) }, secrets: { secrets[$0] })
    }

    /// The tile of `z` holding (lat, lon).
    private func tile(_ z: Int, lat: Double, lon: Double) -> (Int, Int) {
        let p = ImageryGeometry.mercator(lon: lon, lat: lat), n = Double(1 << z)
        return (Int(p.x * n), Int(p.y * n))
    }

    /// A fetch answering each source's host with a solid PNG of its colour, recording the URLs asked.
    private final class Painter: @unchecked Sendable {
        let lock = NSLock()
        var asked: [URL] = []
        var fetch: ImageryTiles.Fetch {
            { [unowned self] request in
                let url = request.url!
                self.lock.withLock { self.asked.append(url) }
                let colour: (UInt8, UInt8, UInt8) = url.host == "west.example" ? (255, 0, 0) : (0, 0, 255)
                let image = PilotMapChartTests.image(width: 256, height: 256) { _, _ in (colour.0, colour.1, colour.2, 255) }
                return (PilotMapCharts.png(image)!, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                                    headerFields: ["Content-Type": "image/png"])!)
            }
        }
    }

    private func pixel(_ data: Data, x: Int, y: Int) throws -> (UInt8, UInt8, UInt8, UInt8) {
        let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        var p = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &p, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // The pixel (x, y) from the top left, drawn into a 1 × 1 context.
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (p[0], p[1], p[2], p[3])
    }

    // MARK: The list

    func testListDecodesAndKeepsOnlyUsableSources() throws {
        XCTAssertEqual(try store(indexJSON()).sources.map(\.source.id), ["west", "east"])
        XCTAssertEqual(try store(indexJSON(eastEnabled: false)).sources.map(\.source.id), ["west"], "switched off")
        XCTAssertEqual(try store(indexJSON(eastSecret: true)).sources.map(\.source.id), ["west"], "its key missing")
        XCTAssertEqual(try store(indexJSON(eastSecret: true), secrets: ["TEST_TOKEN": "k"]).sources.map(\.source.id), ["west", "east"])
    }

    func testAddressesAndCredits() throws {
        let west = try XCTUnwrap(store(indexJSON()).sources.first?.source)
        XCTAssertEqual(west.url(z: 12, x: 2134, y: 1442)?.absoluteString, "https://west.example/12/2134/1442.png")
        XCTAssertEqual(west.creditLine(year: 2026), "© west 2026")
        let wms = try JSONDecoder().decode(ImagerySource.self, from: Data("""
        {"id": "w", "kind": "wms", "template": "https://w.example/wms?BBOX={bbox}&WIDTH=256", "credit": "w", "licence": "x",
         "area": {"codes": [], "bbox": [0, 0, 1, 1], "polygons": []}}
        """.utf8))
        XCTAssertEqual(wms.url(z: 1, x: 1, y: 0)?.absoluteString,
                       "https://w.example/wms?BBOX=0.000,0.000,20037508.343,20037508.343&WIDTH=256")
        let plain = try JSONDecoder().decode(ImagerySource.self, from: Data("""
        {"id": "p", "kind": "wmts", "template": "http://p.example/{z}/{x}/{y}", "credit": "p", "licence": "x",
         "area": {"codes": [], "bbox": [0, 0, 1, 1], "polygons": []}}
        """.utf8))
        XCTAssertNil(plain.url(z: 1, x: 0, y: 0), "https only")
        let offset = try JSONDecoder().decode(ImagerySource.self, from: Data("""
        {"id": "o", "kind": "wmts", "template": "https://o.example/{z}/{x}/{y}", "zoom_offset": -5, "credit": "o",
         "licence": "x", "area": {"codes": [], "bbox": [0, 0, 1, 1], "polygons": []}}
        """.utf8))
        XCTAssertEqual(offset.url(z: 12, x: 1, y: 2)?.absoluteString, "https://o.example/7/1/2", "a matrix starting at zoom 5")
    }

    // MARK: Tiles

    func testSourceChosenPerTile() async throws {
        let store = try store(indexJSON())
        let painter = Painter()
        // Inside the west: its tile as it comes.
        let (wx, wy) = tile(12, lat: 47.0, lon: 6.8)
        let west = await ImageryTiles.tile(z: 12, x: wx, y: wy, store: store, offline: false, fetch: painter.fetch)
        XCTAssertEqual(try pixel(XCTUnwrap(west.data), x: 128, y: 128).0, 255)
        XCTAssertEqual(painter.asked.map(\.host), ["west.example"])
        // Where no source is cleared: nothing, and nothing asked.
        let (ox, oy) = tile(12, lat: 50.0, lon: 6.8)
        let outside = await ImageryTiles.tile(z: 12, x: ox, y: oy, store: store, offline: false, fetch: painter.fetch)
        XCTAssertEqual(outside, .none, "kept by MapLibre: nothing will ever be there")
        // Below a source's first zoom, and offline: nothing.
        let (lx, ly) = tile(4, lat: 47, lon: 6.8)
        let low = await ImageryTiles.tile(z: 4, x: lx, y: ly, store: store, offline: false, fetch: painter.fetch)
        XCTAssertEqual(low, .none)
        let offline = await ImageryTiles.tile(z: 12, x: wx, y: wy, store: store, offline: true, fetch: painter.fetch)
        XCTAssertEqual(offline, .unavailable, "not kept: there will be imagery once online")
        XCTAssertEqual(painter.asked.count, 1)
    }

    func testTileAcrossTheBorderIsClippedPerSource() async throws {
        let store = try store(indexJSON())
        let painter = Painter()
        let (x, y) = tile(10, lat: 47.0, lon: 7.5)
        let answer = await ImageryTiles.tile(z: 10, x: x, y: y, store: store, offline: false, fetch: painter.fetch)
        let composed = try XCTUnwrap(answer.data)
        XCTAssertEqual(Set(painter.asked.compactMap(\.host)), ["west.example", "east.example"])
        // Where 7.5° E falls in this tile, in its 512 pixels.
        let rect = ImageryGeometry.tileRect(z: 10, x: x, y: y)
        let border = Int((ImageryGeometry.mercator(lon: 7.5, lat: 47).x - rect.minX) / rect.width * 512)
        let left = try pixel(composed, x: border - 20, y: 256), right = try pixel(composed, x: border + 20, y: 256)
        XCTAssertEqual(left.0, 255, "west of the border: the west's imagery")
        XCTAssertEqual(left.2, 0)
        XCTAssertEqual(right.2, 255, "east of it: the east's")
        XCTAssertEqual(right.0, 0)
    }

    func testTileHalfOutsideEveryAreaIsTransparentThere() async throws {
        let store = try store(indexJSON(eastEnabled: false))
        let painter = Painter()
        let (x, y) = tile(10, lat: 47.0, lon: 7.5)
        let answer = await ImageryTiles.tile(z: 10, x: x, y: y, store: store, offline: false, fetch: painter.fetch)
        let composed = try XCTUnwrap(answer.data)
        let rect = ImageryGeometry.tileRect(z: 10, x: x, y: y)
        let border = Int((ImageryGeometry.mercator(lon: 7.5, lat: 47).x - rect.minX) / rect.width * 512)
        XCTAssertEqual(try pixel(composed, x: border + 20, y: 256).3, 0, "the switched-off source's side shows the map")
        XCTAssertEqual(painter.asked.map(\.host), ["west.example"])
    }

    func testPastASourcesLastZoomItsLastTileIsEnlarged() async throws {
        let store = try store(indexJSON(westMaxZoom: 10))
        let painter = Painter()
        let (x, y) = tile(12, lat: 47.0, lon: 6.8)
        let tile = await ImageryTiles.tile(z: 12, x: x, y: y, store: store, offline: false, fetch: painter.fetch)
        XCTAssertNotNil(tile.data)
        XCTAssertEqual(painter.asked.first?.absoluteString, "https://west.example/10/\(x >> 2)/\(y >> 2).png")
    }

    func testASourceFailingIsNotNowNeverAHole() async throws {
        let store = try store(indexJSON())
        let (x, y) = tile(10, lat: 47.0, lon: 7.5)
        let failing: ImageryTiles.Fetch = { request in
            let url = request.url!
            if url.host == "east.example" { throw URLError(.timedOut) }
            let image = PilotMapChartTests.image(width: 256, height: 256) { _, _ in (255, 0, 0, 255) }
            return (PilotMapCharts.png(image)!, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                                headerFields: ["Content-Type": "image/png"])!)
        }
        let answer = await ImageryTiles.tile(z: 10, x: x, y: y, store: store, offline: false, fetch: failing)
        XCTAssertEqual(answer, .unavailable, "half a tile would be kept for a month")
        let refused: ImageryTiles.Fetch = { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: [:])!)
        }
        let (wx, wy) = tile(12, lat: 47.0, lon: 6.8)
        let server = await ImageryTiles.tile(z: 12, x: wx, y: wy, store: store, offline: false, fetch: refused)
        XCTAssertEqual(server, .unavailable)
        let absent: ImageryTiles.Fetch = { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!)
        }
        let missing = await ImageryTiles.tile(z: 12, x: wx, y: wy, store: store, offline: false, fetch: absent)
        XCTAssertEqual(missing, .none, "the provider has no tile there")
    }

    // MARK: Credits

    func testCreditsAtABorderNameEverySourceInView() throws {
        let store = try store(indexJSON())
        let view = CGRect(origin: ImageryGeometry.mercator(lon: 7.3, lat: 47.2), size: .zero)
            .union(CGRect(origin: ImageryGeometry.mercator(lon: 7.7, lat: 46.8), size: .zero))
        XCTAssertEqual(ImageryTiles.credited(in: view, zoom: 10, store: store).map(\.id), ["west", "east"])
        let westOnly = CGRect(origin: ImageryGeometry.mercator(lon: 6.5, lat: 47.2), size: .zero)
            .union(CGRect(origin: ImageryGeometry.mercator(lon: 7.0, lat: 46.8), size: .zero))
        XCTAssertEqual(ImageryTiles.credited(in: westOnly, zoom: 10, store: store).map(\.id), ["west"])
        let off = try self.store(indexJSON(eastEnabled: false))
        XCTAssertEqual(ImageryTiles.credited(in: view, zoom: 10, store: off).map(\.id), ["west"], "a source off is never credited")
    }

    /// The copy the app ships: every source decodes, has an https address and an area, and none is Denmark's
    /// third-party address.
    func testBundledSourcesAreUsable() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "imagery", withExtension: "json", subdirectory: "PilotMapImagery"))
        let index = try ImageryIndex.decode(Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(index.sources.count, 20)
        for source in index.sources {
            XCTAssertNotNil(source.url(z: 12, x: 2134, y: 1442), source.id)
            XCTAssertFalse(source.area.polygons.isEmpty, source.id)
            XCTAssertGreaterThanOrEqual(source.minZoom, ImageryTiles.minimumZoom, source.id)
            XCTAssertFalse(source.template.contains("_DAF"), source.id)
        }
        XCTAssertEqual(Set(index.sources.map(\.id)).count, index.sources.count)
    }

    func testImageryLayerIsOnlineOnly() {
        XCTAssertEqual(PilotMapCharts.rasters(for: .satellite, policy: ChartPolicy()).map(\.id), ["imagery"])
        XCTAssertEqual(PilotMapCharts.rasters(for: .satellite, policy: ChartPolicy()).first?.minZoom, 7,
                       "hidden further out than any source starts (tile zoom 8), so no closer tile lingers")
        XCTAssertEqual(PilotMapCharts.rasters(for: .satellite, policy: ChartPolicy(strictOffline: true)).map(\.id),
                       ["chart-icao"], "offline the downloaded chart, as on MapKit")
        XCTAssertEqual(PilotTileURLProtocol.parse(URL(string: "https://tiles.aerocheck.app/local/imagery/12/2134/1442")),
                       .imagery(z: 12, x: 2134, y: 1442))
    }
}
