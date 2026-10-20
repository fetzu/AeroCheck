import XCTest
import MapKit
import UIKit
@testable import AeroCheck

/// The app's own tile renderer and its loader (6.4.2, the map tile review): the tile maths, the caches, the order the
/// network tiles go in, what the renderer draws while they come and what it redraws when they have.
@MainActor
final class ChartTileTests: XCTestCase {

    // MARK: - Fixtures

    /// A 256-pixel PNG, `top` over its upper half and `bottom` under it.
    private nonisolated static func png(top: UIColor, bottom: UIColor = .white) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).pngData { context in
            bottom.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            top.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
        }
    }

    private nonisolated static let tilePNG = png(top: .red, bottom: .blue)

    private nonisolated static func ok(_ data: Data = tilePNG) -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: URL(string: "https://wmts.geo.admin.ch/t")!, statusCode: 200, httpVersion: nil,
                               headerFields: nil)!)
    }

    private nonisolated static func status(_ code: Int) -> (Data, HTTPURLResponse) {
        (Data(), HTTPURLResponse(url: URL(string: "https://wmts.geo.admin.ch/t")!, statusCode: code, httpVersion: nil,
                                 headerFields: nil)!)
    }

    /// The network as the tests see it: every fetch recorded in order, answered at once or held until released.
    final class Network: @unchecked Sendable {
        private let lock = NSLock()
        private var _fetched: [String] = []
        private var held: [String: CheckedContinuation<Void, Never>] = [:]
        var holding: Set<String> = []
        var answers: [String: (Data, HTTPURLResponse)] = [:]

        var fetched: [String] { lock.withLock { _fetched } }

        func spec(_ key: String, disk: URL? = nil, dropsBlank: Bool = false) -> ChartTileSpec {
            ChartTileSpec(key: key, disk: disk, fetch: { [self] in try await self.fetch(key) }, dropsBlank: dropsBlank)
        }

        func fetch(_ key: String) async throws -> (Data, HTTPURLResponse) {
            let hold = lock.withLock { () -> Bool in
                _fetched.append(key)
                return holding.contains(key)
            }
            if hold { await withCheckedContinuation { continuation in lock.withLock { held[key] = continuation } } }
            guard let answer = lock.withLock({ answers[key] }) else { throw URLError(.notConnectedToInternet) }
            return answer
        }

        func release(_ key: String) {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                holding.remove(key)
                return held.removeValue(forKey: key)
            }
            continuation?.resume()
        }

        func isHeld(_ key: String) -> Bool { lock.withLock { held[key] != nil } }
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Polls until `condition` holds (10 ms steps).
    private func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { await wait(0.01) }
    }

    private final class Outcomes: @unchecked Sendable {
        private let lock = NSLock()
        private var _list: [ChartTileOutcome] = []
        var list: [ChartTileOutcome] { lock.withLock { _list } }
        func add(_ outcome: ChartTileOutcome) { lock.withLock { _list.append(outcome) } }
    }

    private func load(_ loader: ChartTileLoader, _ spec: ChartTileSpec, coarse: Bool = false,
                      wanted: @escaping @Sendable () -> Bool = { true }) async -> ChartTileOutcome {
        await withCheckedContinuation { continuation in
            loader.load(spec, urgency: { wanted() ? (coarse ? 0 : 1) : nil }) { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Tile maths

    func testATilesRectangleCoversExactlyThatTile() {
        let tile = ChartTile(z: 12, x: 2151, y: 1435)
        XCTAssertEqual(ChartTile.covering(tile.mapRect, z: 12), [tile], "its edges touch no neighbour")
        let across = MKMapRect(x: tile.mapRect.midX, y: tile.mapRect.midY, width: tile.mapRect.width,
                               height: tile.mapRect.height)
        XCTAssertEqual(Set(ChartTile.covering(across, z: 12)),
                       [tile, ChartTile(z: 12, x: 2152, y: 1435), ChartTile(z: 12, x: 2151, y: 1436),
                        ChartTile(z: 12, x: 2152, y: 1436)])
        XCTAssertEqual(ChartTile.covering(tile.mapRect, z: 11), [tile.ancestor(1)])
        XCTAssertEqual(ChartTile.covering(tile.mapRect, z: 13).count, 4)
        XCTAssertEqual(Set(tile.children), Set(ChartTile.covering(tile.mapRect, z: 13)))
        XCTAssertTrue(tile.children.allSatisfy { $0.ancestor(1) == tile })
    }

    /// The zoom MapKit's renderer chose: a 256-pixel tile on 256 points. Measured on the iPad: zoom 13 at a camera of
    /// 28.9 km, where MapKit draws at a point per 128 map points.
    func testTheZoomIsMapKits() {
        XCTAssertEqual(ChartTile.zoom(for: MKZoomScale(pow(2.0, -7.0))), 13)
        XCTAssertEqual(ChartTile.zoom(for: MKZoomScale(pow(2.0, -5.0))), 15)
        XCTAssertEqual(ChartTile.zoom(for: 0), 0)
    }

    /// On screen first, the coarse before the sharp, nearest the middle first; then the rest of what MapKit asks for
    /// around it, nearest first.
    func testTheTilesInViewGoFirst() {
        let visible = ChartTile(z: 12, x: 2151, y: 1435).mapRect
        let middle = ChartTile(z: 14, x: 8605, y: 5741).mapRect
        let edge = ChartTile(z: 14, x: 8604, y: 5740).mapRect
        let beside = ChartTile(z: 14, x: 8608, y: 5741).mapRect
        let further = ChartTile(z: 14, x: 8612, y: 5741).mapRect
        let coarse = ChartTile(z: 12, x: 2151, y: 1435).mapRect
        let rank = { ChartTileRenderer.urgency(of: $0, coarse: $1, visible: visible) }
        XCTAssertLessThan(rank(coarse, true), rank(middle, false))
        XCTAssertLessThan(rank(middle, false), rank(edge, false))
        XCTAssertLessThan(rank(edge, false), rank(beside, false))
        XCTAssertLessThan(rank(beside, false), rank(further, false))
        XCTAssertLessThan(rank(beside, true), rank(beside, false))
        XCTAssertEqual(rank(further, false), .infinity, "a screen away: not before the map comes near")
    }

    /// A tile wanted later stays queued, unfetched, until a map wants it sooner.
    func testATileWantedLaterWaits() async {
        let loader = ChartTileLoader(limit: 8)
        let network = Network()
        network.answers["far"] = Self.ok()
        final class Rank: @unchecked Sendable { var value = Double.infinity }
        let rank = Rank()
        let outcomes = Outcomes()
        loader.load(network.spec("far"), urgency: { rank.value }) { outcomes.add($0) }
        await wait(0.1)
        XCTAssertEqual(network.fetched, [])
        XCTAssertEqual(loader.queuedCount, 1)
        rank.value = 1   // the map came near
        loader.reconsider()
        await waitUntil { outcomes.list.count == 1 }
        XCTAssertEqual(network.fetched, ["far"])
    }

    // MARK: - Loader

    func testATileFetchedIsKeptAndDrawnWithoutTheNetwork() async {
        let loader = ChartTileLoader(limit: 8)
        let network = Network()
        network.answers["a"] = Self.ok()
        let spec = network.spec("a")
        XCTAssertFalse(loader.isReady(spec))
        guard case .missing = loader.cached(spec) else { return XCTFail("nothing kept yet") }

        let outcome = await load(loader, spec)

        XCTAssertEqual("\(outcome)", "image")
        XCTAssertTrue(loader.isReady(spec))
        guard case .image(let image) = loader.local(spec) else { return XCTFail("kept decoded") }
        XCTAssertEqual(image.width, 256)
        // Decoded again from its file when the decoded tiles were let go.
        loader.images.removeAllObjects()
        guard case .image = loader.cached(spec) else { return XCTFail("decoded from the kept file") }
        XCTAssertEqual(network.fetched, ["a"])
    }

    /// A 4xx is a tile past the layer's edge, for good; a plain white tile with `dropsBlank` is none; a 5xx, an error
    /// or a body that isn't an image failed, and is asked again after its backoff.
    func testWhatEachAnswerLeaves() async {
        let loader = ChartTileLoader(limit: 8)
        let network = Network()
        network.answers["edge"] = Self.status(400)
        network.answers["server"] = Self.status(503)
        network.answers["garbage"] = Self.ok(Data("not an image".utf8))
        // The National Map's plain white tile over Lyon, as swisstopo serves it.
        let white = SwissChartLayerTests.blankNationalMapTile
        network.answers["white"] = Self.ok(white)

        let edge = await load(loader, network.spec("edge"))
        XCTAssertEqual("\(edge)", "empty")
        guard case .empty = loader.cached(network.spec("edge")) else { return XCTFail("kept as none") }
        let blank = await load(loader, network.spec("white", dropsBlank: true))
        XCTAssertEqual("\(blank)", "empty")

        for key in ["server", "garbage", "offline"] {
            let failed = await load(loader, network.spec(key))
            XCTAssertEqual("\(failed)", "failed", key)
            XCTAssertNotNil(loader.retryDelay(for: key), key)
            XCTAssertTrue(loader.isReady(network.spec(key)), "drawn around for now: \(key)")
            guard case .missing = loader.cached(network.spec(key)) else { return XCTFail("nothing kept for \(key)") }
        }
        XCTAssertEqual(ChartTileLoader.backoff(after: 1), 2)
        XCTAssertEqual(ChartTileLoader.backoff(after: 9), 60)
        XCTAssertNil(loader.retryDelay(for: "server", now: Date().addingTimeInterval(3)), "asked again after 2 s")
    }

    /// One request per tile however many maps want it, all of them told.
    func testATileWantedTwiceIsFetchedOnce() async {
        let loader = ChartTileLoader(limit: 8)
        let network = Network()
        network.answers["a"] = Self.ok()
        network.holding = ["a"]
        let outcomes = Outcomes()
        loader.load(network.spec("a"), urgency: { 1 }) { outcomes.add($0) }
        await waitUntil { network.isHeld("a") }
        loader.load(network.spec("a"), urgency: { 1 }) { outcomes.add($0) }
        network.release("a")
        await waitUntil { outcomes.list.count == 2 }
        XCTAssertEqual(outcomes.list.map { "\($0)" }, ["image", "image"])
        XCTAssertEqual(network.fetched, ["a"])
    }

    /// The coarse tiles first, then the newest: the zoom a pinch ended at before the ones it passed.
    func testTheCoarseGoFirstThenTheNewest() async {
        let loader = ChartTileLoader(limit: 1)
        let network = Network()
        for key in ["busy", "s1", "s2", "s3", "c1"] { network.answers[key] = Self.ok() }
        network.holding = ["busy"]
        let outcomes = Outcomes()
        loader.load(network.spec("busy"), urgency: { 1 }) { outcomes.add($0) }
        await waitUntil { network.isHeld("busy") }
        for key in ["s1", "s2", "s3"] { loader.load(network.spec(key), urgency: { 1 }) { outcomes.add($0) } }
        loader.load(network.spec("c1"), urgency: { 0 }) { outcomes.add($0) }
        XCTAssertEqual(loader.queuedCount, 4)
        network.release("busy")
        await waitUntil { outcomes.list.count == 5 }
        XCTAssertEqual(network.fetched, ["busy", "c1", "s3", "s2", "s1"])
    }

    /// A tile no map wants any more by its turn isn't fetched.
    func testATileNoLongerWantedIsNotFetched() async {
        let loader = ChartTileLoader(limit: 1)
        let network = Network()
        network.answers["busy"] = Self.ok()
        network.answers["passed"] = Self.ok()
        network.holding = ["busy"]
        let outcomes = Outcomes()
        loader.load(network.spec("busy"), urgency: { 1 }) { outcomes.add($0) }
        await waitUntil { network.isHeld("busy") }
        final class Flag: @unchecked Sendable { var on = true }
        let wanted = Flag()
        loader.load(network.spec("passed"), urgency: { wanted.on ? 1 : nil }) { outcomes.add($0) }
        wanted.on = false   // the pinch went on
        network.release("busy")
        await waitUntil { outcomes.list.count == 2 }
        XCTAssertEqual(outcomes.list.map { "\($0)" }, ["image", "passedBy"])
        XCTAssertEqual(network.fetched, ["busy"])
        XCTAssertFalse(loader.isReady(network.spec("passed")), "asked again when a map wants it again")
    }

    /// A downloaded chart is read from disk, never fetched; offline, a tile not downloaded is none.
    func testTheDownloadedChartsComeFromDisk() async throws {
        let loader = ChartTileLoader(limit: 8)
        let network = Network()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("chart-tile-\(UUID()).png")
        try Self.tilePNG.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let spec = network.spec("d", disk: file)
        XCTAssertTrue(loader.isReady(spec))
        guard case .image = loader.local(spec) else { return XCTFail("read from disk") }
        XCTAssertEqual(network.fetched, [])

        let offline = ChartTileSpec(key: "o", fetch: nil)
        XCTAssertTrue(loader.isReady(offline), "nothing to wait for")
        let outcome = await load(loader, offline)
        XCTAssertEqual("\(outcome)", "empty")
    }

    // MARK: - Renderer

    /// A chart of zooms 7 to 12 on the test network, keyed "z/x/y".
    final class TestChart: MKTileOverlay, ChartTileSource {
        let network: Network
        init(network: Network, maximumZ: Int = 12) {
            self.network = network
            super.init(urlTemplate: nil)
            minimumZ = 7
            self.maximumZ = maximumZ
        }
        func spec(for tile: ChartTile) -> ChartTileSpec? { network.spec("\(tile.z)/\(tile.x)/\(tile.y)") }
    }

    /// The renderer, its redraws recorded (behind its own lock: the renderer's Sendable conformance holds).
    final class RecordingRenderer: ChartTileRenderer, @unchecked Sendable {
        private let lock = NSLock()
        private var _redrawn: [(MKMapRect, MKZoomScale)] = []
        var redrawn: [(MKMapRect, MKZoomScale)] { lock.withLock { _redrawn } }
        override func invalidate(_ mapRect: MKMapRect, zoomScale: MKZoomScale) {
            lock.withLock { _redrawn.append((mapRect, zoomScale)) }
        }
    }

    /// The zoom scale at which `renderer` draws tiles of zoom `z`.
    private func zoomScale(drawing z: Int, on renderer: ChartTileRenderer) -> MKZoomScale {
        MKZoomScale(pow(2.0, Double(z - 20)))
    }

    private func key(_ tile: ChartTile) -> String { "\(tile.z)/\(tile.x)/\(tile.y)" }

    /// Nothing loaded: MapKit waits (it keeps what it showed), the sharp tile and the coarse one two zooms out are both
    /// asked for, and each redraws its own rectangle when it comes, the coarse one its whole (drawn enlarged until the
    /// sharp ones come).
    func testACoarseTileStandsInUntilTheSharpOneComes() async {
        let network = Network()
        let chart = TestChart(network: network)
        let renderer = RecordingRenderer(source: chart, loader: ChartTileLoader(limit: 1))
        let tile = ChartTile(z: 12, x: 2151, y: 1435)
        let coarse = tile.ancestor(2)
        network.answers[key(tile)] = Self.ok()
        network.answers[key(coarse)] = Self.ok()
        network.holding = [key(tile), key(coarse)]
        let scale = zoomScale(drawing: 12, on: renderer)
        XCTAssertEqual(renderer.zooms(at: scale).drawn, 12)

        XCTAssertFalse(renderer.canDraw(tile.mapRect, zoomScale: scale), "nothing to draw yet")
        await waitUntil { network.isHeld(key(tile)) }
        XCTAssertEqual(network.fetched, [key(tile)], "the sharp one asked first took the only place")
        network.release(key(tile))
        await waitUntil { renderer.redrawn.count == 1 }
        XCTAssertTrue((renderer.redrawn.first?.0).map { MKMapRectEqualToRect($0, tile.mapRect) } ?? false)
        XCTAssertEqual(renderer.redrawn.first?.1, scale)
        XCTAssertTrue(renderer.canDraw(tile.mapRect, zoomScale: scale))
        XCTAssertEqual(network.fetched.first, key(tile))
        // The coarse one was asked for too, and came after.
        network.release(key(coarse))
        await waitUntil { renderer.redrawn.count == 2 }
        XCTAssertTrue((renderer.redrawn.last?.0).map { MKMapRectEqualToRect($0, coarse.mapRect) } ?? false,
                      "its whole rectangle")
    }

    /// With the coarse tile in hand, a missing sharp tile is drawn from it: MapKit draws at once.
    func testAKeptZoomOutIsDrawnAtOnce() async {
        let network = Network()
        let chart = TestChart(network: network)
        let loader = ChartTileLoader(limit: 8)
        let renderer = RecordingRenderer(source: chart, loader: loader)
        let tile = ChartTile(z: 12, x: 2151, y: 1435)
        network.answers[key(tile.ancestor(3))] = Self.ok()
        _ = await load(loader, network.spec(key(tile.ancestor(3))))
        network.holding = [key(tile)]
        network.answers[key(tile)] = Self.ok()

        XCTAssertTrue(renderer.canDraw(tile.mapRect, zoomScale: zoomScale(drawing: 12, on: renderer)),
                      "the zoom 9 tile, enlarged, until the sharp one comes")
        await waitUntil { network.isHeld(key(tile)) }
        XCTAssertEqual(network.fetched.last, key(tile), "and the sharp one is on its way")
        network.release(key(tile))
    }

    /// Past the chart's last zoom, that zoom enlarged: the ICAO chart at the iPad's closest zoom, where MapKit's
    /// renderer drew nothing (the review's F2). Two zooms or more under its first, nothing.
    func testPastTheLastZoomItIsEnlarged() async {
        let network = Network()
        let renderer = RecordingRenderer(source: TestChart(network: network), loader: ChartTileLoader(limit: 8))
        let zooms = renderer.zooms(at: zoomScale(drawing: 14, on: renderer))
        XCTAssertEqual(zooms.wanted, 14)
        XCTAssertEqual(zooms.drawn, 12)
        let tile = ChartTile(z: 14, x: 8604, y: 5740)
        network.answers[key(tile.ancestor(2))] = Self.ok()
        _ = renderer.canDraw(tile.mapRect, zoomScale: zoomScale(drawing: 14, on: renderer))
        await waitUntil { network.fetched.count == 2 }
        XCTAssertEqual(Set(network.fetched), [key(tile.ancestor(2)), key(tile.ancestor(4))],
                       "the zoom 12 tile holding it, and its coarse one")

        let far = zoomScale(drawing: 5, on: renderer)
        XCTAssertTrue(renderer.canDraw(ChartTile(z: 5, x: 16, y: 11).mapRect, zoomScale: far))
        await wait(0.1)
        XCTAssertEqual(network.fetched.count, 2, "too far out: nothing asked")
    }

    /// The tile drawn where it lies, its top up: MapKit's context runs with y down.
    func testATileIsDrawnTheRightWayUp() async {
        let network = Network()
        let loader = ChartTileLoader(limit: 8)
        let renderer = ChartTileRenderer(source: TestChart(network: network), loader: loader)
        let tile = ChartTile(z: 12, x: 2151, y: 1435)
        network.answers[key(tile)] = Self.ok()
        _ = await load(loader, network.spec(key(tile)))

        // A 64-pixel bitmap standing for the tile's rectangle, set up as MapKit sets its own: map points, y down.
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                    bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let rect = renderer.rect(for: tile.mapRect)
            context.translateBy(x: 0, y: CGFloat(side))
            context.scaleBy(x: CGFloat(side) / rect.width, y: -CGFloat(side) / rect.height)
            context.translateBy(x: -rect.minX, y: -rect.minY)
            renderer.draw(tile.mapRect, zoomScale: zoomScale(drawing: 12, on: renderer), in: context)
        }
        // The bitmap's memory starts at its top row.
        let top = Array(pixels[(4 * side + side / 2) * 4 ..< (4 * side + side / 2) * 4 + 3])
        let bottom = Array(pixels[((side - 4) * side + side / 2) * 4 ..< ((side - 4) * side + side / 2) * 4 + 3])
        XCTAssertEqual(top, [255, 0, 0], "red at the top")
        XCTAssertEqual(bottom, [0, 0, 255], "blue at the bottom")
    }

    /// A tile that failed is drawn around at once (MapKit waits for nothing) and asked again after its backoff.
    func testAFailedTileIsDrawnAroundAndAskedAgain() async {
        let network = Network()
        let renderer = RecordingRenderer(source: TestChart(network: network), loader: ChartTileLoader(limit: 8))
        let tile = ChartTile(z: 7, x: 67, y: 44)   // the chart's first zoom: no coarse one
        let scale = zoomScale(drawing: 7, on: renderer)

        XCTAssertFalse(renderer.canDraw(tile.mapRect, zoomScale: scale))
        await waitUntil { renderer.redrawn.count == 1 }
        XCTAssertTrue(renderer.canDraw(tile.mapRect, zoomScale: scale), "failed: drawn without it for now")
        network.answers[key(tile)] = Self.ok()
        await waitUntil(timeout: 4) { network.fetched.count == 2 }
        XCTAssertEqual(network.fetched, [key(tile), key(tile)], "asked again after 2 s")
        await waitUntil { renderer.redrawn.count == 2 }
        XCTAssertTrue((renderer.redrawn.last?.0).map { MKMapRectEqualToRect($0, tile.mapRect) } ?? false)
    }

    // MARK: - OpenAIP

    /// OpenAIP's tiles drawn by the renderer as the charts are: the downloaded copy first, the key in a header, never
    /// a request offline, its fills stripped, and none of its labels enlarged past its last zoom. (the review's F8)
    func testOpenAIPsTilesComeThroughTheRenderer() throws {
        let overlay = OpenAIPTileOverlay()
        XCTAssertTrue(ChartTileRenderer.renderer(for: overlay, on: nil) is ChartTileRenderer)
        XCTAssertEqual(overlay.enlargesPastLastZoom, 0)
        XCTAssertEqual(ICAOSegelflugkarteTileOverlay().enlargesPastLastZoom, 6)
        let tile = ChartTile(z: 9, x: 268, y: 179)
        let spec = try XCTUnwrap(overlay.spec(for: tile))
        XCTAssertEqual(spec.key, "openaip/9/268/179", "one key whatever the subdomain")
        XCTAssertEqual(spec.disk?.path.hasSuffix("MapData/OpenAIP/9/268/179.png"), true)
        XCTAssertNotNil(spec.fetch)
        XCTAssertNil(OpenAIPTileOverlay(isStrictOfflineMode: true).spec(for: tile)?.fetch, "offline: no request")
        let renderer = ChartTileRenderer(source: overlay, loader: ChartTileLoader(limit: 1))
        XCTAssertTrue(renderer.canDraw(ChartTile(z: 16, x: 34330, y: 22960).mapRect,
                                       zoomScale: MKZoomScale(pow(2.0, -4.0))), "past z14: nothing to wait for")
    }

    /// The fills (alpha under 64) go, the labels and lines stay, and the image stays decoded.
    func testOpenAIPsFillsAreStripped() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).image { context in
            UIColor(red: 1, green: 0, blue: 0, alpha: 0.1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            UIColor.black.setFill()
            context.fill(CGRect(x: 96, y: 96, width: 64, height: 64))
        }
        let stripped = try XCTUnwrap(OpenAIPTileOverlay.strippingFills(of: try XCTUnwrap(image.cgImage)))
        let data = try XCTUnwrap(stripped.dataProvider?.data as Data?)
        let alpha = { (x: Int, y: Int) in data[y * stripped.bytesPerRow + x * 4 + 3] }
        XCTAssertEqual(alpha(10, 10), 0, "the fill is gone")
        XCTAssertEqual(alpha(128, 128), 255, "the label stays")
    }
}
