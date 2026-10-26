import CoreGraphics
import ImageIO
import XCTest
@testable import AeroCheck

/// The swisstopo charts and OpenAIP's tiles on the MapLibre map (6.8.0): which rasters a layer choice draws and at
/// which zooms, the local addresses MapLibre asks, how a tile is answered.
final class PilotMapChartTests: XCTestCase {

    func testZoomConversionIsOneLevel() {
        XCTAssertEqual(MapZoom.mapLibre(fromMapKit: 13), 12)
        XCTAssertEqual(MapZoom.mapKit(fromMapLibre: 12), 13)
    }

    func testICAOLayerGoesFromICAOToGliderToNationalMap() {
        let rasters = PilotMapCharts.rasters(for: .icao, policy: ChartPolicy())
        XCTAssertEqual(rasters.map(\.id), ["chart-icao", "chart-glider", "chart-national"])
        XCTAssertEqual(rasters[0].maxZoom, 10, "the glider chart from MapKit zoom 11, MapLibre's 10")
        XCTAssertEqual(rasters[1].minZoom, 10)
        XCTAssertEqual(rasters[1].maxZoom, 12, "the National Map from MapKit zoom 13")
        XCTAssertEqual(rasters[2].minZoom, 12)
        XCTAssertEqual(rasters[0].maxTileZoom, 10)
        XCTAssertEqual(rasters[1].minTileZoom, 11)
        XCTAssertEqual(rasters[1].maxTileZoom, 12)
        XCTAssertTrue(rasters[0].template.contains("/local/chart/ch.bazl.luftfahrtkarten-icao/{z}/{x}/{y}?offline=0"))
    }

    func testForcedICAOChartIsAloneAndEnlarged() {
        let rasters = PilotMapCharts.rasters(for: .icao, policy: ChartPolicy(forceICAO: true))
        XCTAssertEqual(rasters.map(\.id), ["chart-icao"])
        XCTAssertEqual(rasters[0].maxTileZoom, 11)
        XCTAssertNil(rasters[0].maxZoom, "shown at every zoom, its last tiles enlarged")
    }

    func testOfflineDrawsTheDownloadedChartsOnly() {
        let both = PilotMapCharts.rasters(for: .landeskarten, policy: ChartPolicy(strictOffline: true, segelflugCache: true))
        XCTAssertEqual(both.map(\.id), ["chart-icao", "chart-glider"], "offline, any layer is the ICAO chart")
        XCTAssertNil(both[1].maxZoom, "no National Map after the glider chart")
        XCTAssertTrue(both.allSatisfy { $0.template.hasSuffix("?offline=1") })
        let icaoOnly = PilotMapCharts.rasters(for: .icao, policy: ChartPolicy(strictOffline: true))
        XCTAssertEqual(icaoOnly.map(\.id), ["chart-icao"])
    }

    func testOtherLayers() {
        XCTAssertEqual(PilotMapCharts.rasters(for: .standard, policy: ChartPolicy()), [], "the pilot's map alone")
        XCTAssertEqual(PilotMapCharts.rasters(for: .landeskarten, policy: ChartPolicy()).map(\.id), ["chart-national"])
        XCTAssertEqual(PilotMapCharts.rasters(for: .swissimage, policy: ChartPolicy()).map(\.id), ["chart-swissimage"])
        XCTAssertEqual(PilotMapCharts.rasters(for: .satellite, policy: ChartPolicy()).map(\.id), ["imagery"])
    }

    func testLocalAddressesParse() {
        func parse(_ s: String) -> PilotTileURLProtocol.Request { PilotTileURLProtocol.parse(URL(string: s)) }
        XCTAssertEqual(parse("https://tiles.aerocheck.app/local/chart/ch.bazl.segelflugkarte/12/2138/1438?offline=1"),
                       .chart(layer: "ch.bazl.segelflugkarte", z: 12, x: 2138, y: 1438, offline: true))
        XCTAssertEqual(parse("https://tiles.aerocheck.app/local/openaip/9/267/179?offline=0"),
                       .openAIP(z: 9, x: 267, y: 179, offline: false))
        XCTAssertEqual(parse("https://tiles.aerocheck.app/local/chart/ch.other.layer/9/267/179?offline=0"), .unknown,
                       "only the layers the app draws")
        XCTAssertEqual(parse("https://tiles.aerocheck.app/local/chart/ch.bazl.segelflugkarte/2/9/9"), .unknown)
    }

    func testChartSpecs() throws {
        let icao = try XCTUnwrap(PilotMapCharts.chartSpec(layer: "ch.bazl.luftfahrtkarten-icao", z: 9, x: 267, y: 179, offline: false))
        XCTAssertEqual(icao.disk, OfflineMapManager.tileFileURL(z: 9, x: 267, y: 179, layer: .icao), "the download first")
        XCTAssertNotNil(icao.fetch)
        XCTAssertFalse(icao.dropsBlank)
        let offline = try XCTUnwrap(PilotMapCharts.chartSpec(layer: "ch.bazl.segelflugkarte", z: 12, x: 2138, y: 1438, offline: true))
        XCTAssertNil(offline.fetch, "offline: nothing from the network")
        let national = try XCTUnwrap(PilotMapCharts.chartSpec(layer: "ch.swisstopo.pixelkarte-farbe", z: 14, x: 8530, y: 5760, offline: false))
        XCTAssertNil(national.disk)
        XCTAssertTrue(national.dropsBlank)
        XCTAssertNil(PilotMapCharts.chartSpec(layer: "ch.unknown", z: 9, x: 1, y: 1, offline: false))
        XCTAssertNil(PilotMapCharts.openAIPSpec(z: 3, x: 1, y: 1, offline: false), "below OpenAIP's first zoom")
    }

    func testTileBytesAsServed() async throws {
        let dir = makeTestDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tile = dir.appendingPathComponent("tile.png")
        let image = Self.image(width: 8, height: 8) { _, _ in (10, 20, 30, 255) }
        try XCTUnwrap(PilotMapCharts.png(image)).write(to: tile)

        // As stored.
        var spec = ChartTileSpec(key: "k", disk: tile)
        let stored = await PilotMapCharts.bytes(for: spec)
        XCTAssertEqual(stored, .data(try Data(contentsOf: tile)))

        // Processed, then PNG again.
        spec.process = { _ in Self.image(width: 8, height: 8) { _, _ in (0, 0, 0, 0) } }
        let processedBytes = await PilotMapCharts.bytes(for: spec)
        let processed = try XCTUnwrap(processedBytes.data)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(processed as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(decoded.width, 8)

        // A white tile from the National Map's host is none.
        let white = dir.appendingPathComponent("white.jpg")
        try XCTUnwrap(Self.jpeg(Self.image(width: 64, height: 64) { _, _ in (255, 255, 255, 255) })).write(to: white)
        let blank = await PilotMapCharts.bytes(for: ChartTileSpec(key: "w", disk: white, dropsBlank: true))
        XCTAssertEqual(blank, .none)

        // Nothing on disk and offline: not now (a download may bring it), never kept as none.
        let missing = await PilotMapCharts.bytes(for: ChartTileSpec(key: "m", disk: dir.appendingPathComponent("none.png")))
        XCTAssertEqual(missing, .unavailable)

        // The host: 404 is none, a failure or a 500 is not now.
        var online = ChartTileSpec(key: "o")
        online.fetch = { (Data(), HTTPURLResponse(url: URL(string: "https://x.example")!, statusCode: 404, httpVersion: nil, headerFields: [:])!) }
        let gone = await PilotMapCharts.bytes(for: online)
        XCTAssertEqual(gone, .none)
        online.fetch = { (Data(), HTTPURLResponse(url: URL(string: "https://x.example")!, statusCode: 500, httpVersion: nil, headerFields: [:])!) }
        let failing = await PilotMapCharts.bytes(for: online)
        XCTAssertEqual(failing, .unavailable)
        online.fetch = { throw URLError(.notConnectedToInternet) }
        let unreachable = await PilotMapCharts.bytes(for: online)
        XCTAssertEqual(unreachable, .unavailable)
    }

    // MARK: Helpers

    static func image(width: Int, height: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let (r, g, b, a) = pixel(x, y)
            bytes.replaceSubrange((y * width + x) * 4..<(y * width + x) * 4 + 4, with: [r, g, b, a])
        } }
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.3] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
