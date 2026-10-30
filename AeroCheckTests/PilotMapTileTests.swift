import XCTest
@testable import AeroCheck

/// Where the pilot's map's tiles come from (6.8.0): the regions index, the downloaded regions, the tile source
/// (downloaded first, the first region at a border, online counted against the allowance, else nothing) and the
/// URLProtocol MapLibre asks.
final class PilotMapTileTests: XCTestCase {

    private static let ch = PilotMapRegion(id: "ch", name: "Switzerland and Liechtenstein",
                                           bounds: [5.64, 45.6, 10.78, 48.0], built: "20261025",
                                           mapBytes: 92_236_294, reliefBytes: 81_808_941)
    private static let fr = PilotMapRegion(id: "fr-est", name: "France, east", bounds: [4.0, 45.0, 8.3, 49.5],
                                           built: "20261101", mapBytes: 300_000_000, reliefBytes: 0)

    /// Tiles near Neuchâtel, inside both regions.
    private let border = (z: 13, x: 4251, y: 2877)

    private func tiles(_ tag: String) -> [PMTilesFixture.Tile] {
        var list = [PMTilesFixture.Tile(z: 0, x: 0, y: 0, bytes: PMTilesFixture.content(0, 0, 0, tag))]
        for x in 4250..<4253 { for y in 2876..<2879 { list.append(.init(z: 13, x: x, y: y, bytes: PMTilesFixture.content(13, x, y, tag))) } }
        return list
    }

    private func indexJSON(_ regions: [PilotMapRegion]) throws -> Data {
        let body: [String: Any] = ["version": 1, "generated": "2026-10-26T07:32:40Z",
                                   "regions": try regions.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func reply(_ url: URL, _ status: Int, _ body: Data) -> (Data, HTTPURLResponse) {
        (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }

    private struct Rig {
        let source: PilotTileSource
        let server: PMTilesFixture.Server
        let storage: PilotMapStorage
        let allowance: PilotMapAllowance
    }

    /// A source on its own directories, defaults and fake server, with `regions` in its index.
    private func rig(_ regions: [PilotMapRegion], online: Bool = true) async throws -> Rig {
        let root = makeTestDirectory()
        let server = PMTilesFixture.Server()
        let index = try indexJSON(regions)
        let fetchIndex: PilotMapIndexStore.Fetch = { request in (index, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!) }
        let store = PilotMapIndexStore(directory: root.appendingPathComponent("index"), fetch: fetchIndex)
        await store.refresh()
        let storage = PilotMapStorage(root: root.appendingPathComponent("regions"))
        let allowance = PilotMapAllowance(defaults: makeTestDefaults())
        let source = PilotTileSource(index: store, storage: storage, allowance: allowance,
                                     cacheDirectory: root.appendingPathComponent("directories"),
                                     headers: { [:] }, fetch: server.fetch, isOnline: { online })
        return Rig(source: source, server: server, storage: storage, allowance: allowance)
    }

    private func download(_ region: PilotMapRegion, _ data: Data, into storage: PilotMapStorage) throws {
        let file = makeTestDirectory().appendingPathComponent("map.pmtiles")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        try storage.install(region, files: [.map: file])
    }

    // MARK: Index

    func testIndexDecodesTheBuildsFormat() throws {
        let json = Data("""
        {"version": 1, "generated": "2026-10-26T07:32:40Z", "regions": [
          {"id": "ch", "name": "Switzerland and Liechtenstein", "bounds": [5.64, 45.6, 10.78, 48.0],
           "built": "20261025", "map_bytes": 92236294, "relief_bytes": 81808941, "something_new": true}]}
        """.utf8)
        let index = try PilotMapIndex.decode(json)
        XCTAssertEqual(index.regions, [Self.ch])
        XCTAssertEqual(index.regions[0].build(of: .relief), "20261025", "the map's date when the relief has none")
    }

    func testIndexDropsInvalidAndDuplicateRegions() throws {
        let json = Data("""
        {"version": 1, "regions": [
          {"id": "../etc", "name": "x", "bounds": [0, 0, 1, 1], "built": "20261025"},
          {"id": "ch", "name": "x", "bounds": [5, 45, 4, 48], "built": "20261025"},
          {"id": "de-nord", "name": "x", "bounds": [5, 50, 15, 55], "built": "2026"},
          {"id": "at", "name": "Austria", "bounds": [9.5, 46.3, 17.2, 49.1], "built": "20261025", "map_bytes": 1},
          {"id": "at", "name": "Austria again", "bounds": [9.5, 46.3, 17.2, 49.1], "built": "20261025"}]}
        """.utf8)
        XCTAssertEqual(try PilotMapIndex.decode(json).regions.map(\.name), ["Austria"])
        XCTAssertThrowsError(try PilotMapIndex.decode(Data(#"{"version": 2, "regions": []}"#.utf8)))
    }

    func testIndexStoreKeepsTheLastGoodIndex() async throws {
        let dir = makeTestDirectory()
        let good = try indexJSON([Self.ch])
        let ok = PilotMapIndexStore(directory: dir, fetch: { [self] in reply($0.url!, 200, good) })
        let changed = await ok.refresh()
        XCTAssertTrue(changed)
        XCTAssertEqual(ok.regions, [Self.ch])
        XCTAssertEqual(ok.regions.first?.id, "ch")

        // The next launch, offline, then a broken answer: the kept index stays.
        let offline = PilotMapIndexStore(directory: dir, fetch: { _ in throw URLError(.notConnectedToInternet) })
        XCTAssertEqual(offline.regions, [Self.ch])
        await offline.refresh(maxAge: 0)
        XCTAssertEqual(offline.regions, [Self.ch])
        let broken = PilotMapIndexStore(directory: dir, fetch: { [self] in reply($0.url!, 403, Data("<html>".utf8)) })
        await broken.refresh(maxAge: 0)
        XCTAssertEqual(broken.regions, [Self.ch])
    }

    func testIndexStoreAsksWithTheClientHeaderAndNotTooOften() async throws {
        let dir = makeTestDirectory()
        let body = try indexJSON([Self.ch])
        let asked = PMTilesFixture.Server()
        asked.put("/v1/index.json", body)
        let store = PilotMapIndexStore(directory: dir, fetch: asked.fetch)
        await store.refresh()
        await store.refresh()
        XCTAssertEqual(asked.count, 1, "a second refresh within six hours asks nothing")
        XCTAssertEqual(asked.requests.first?.url, PilotMapConfig.indexURL)
        XCTAssertNotNil(asked.requests.first?.value(forHTTPHeaderField: "User-Agent"))
    }

    // MARK: Regions and tiles

    func testTileTouchesRegion() {
        XCTAssertTrue(Self.ch.touches(z: border.z, x: border.x, y: border.y))
        XCTAssertTrue(Self.ch.touches(z: 0, x: 0, y: 0))
        XCTAssertFalse(Self.ch.touches(z: 13, x: 100, y: 100))
        let box = PilotMapTileMath.bounds(z: 1, x: 1, y: 0)
        XCTAssertEqual(box.west, 0, accuracy: 1e-9)
        XCTAssertEqual(box.south, 0, accuracy: 1e-9)
        XCTAssertEqual(box.north, 85.0511, accuracy: 1e-4)
        XCTAssertFalse(PilotMapTileMath.isValid(z: 2, x: 4, y: 0))
    }

    func testStorageInstallsReplacesAndRemoves() throws {
        let storage = PilotMapStorage(root: makeTestDirectory())
        try download(Self.ch, PMTilesFixture.archive(tiles("old")), into: storage)
        XCTAssertEqual(storage.downloaded, [Self.ch])
        XCTAssertEqual(storage.archive(region: "ch", kind: .map)?.tile(z: 0, x: 0, y: 0).flatMap(PMTiles.plain),
                       PMTilesFixture.content(0, 0, 0, "old"))
        try download(Self.ch, PMTilesFixture.archive(tiles("new")), into: storage)
        XCTAssertEqual(storage.archive(region: "ch", kind: .map)?.tile(z: 0, x: 0, y: 0).flatMap(PMTiles.plain),
                       PMTilesFixture.content(0, 0, 0, "new"), "the update replaces the old file, not a cached open")
        XCTAssertGreaterThan(storage.bytesOnDisk, 0)
        // A relaunch finds it again.
        XCTAssertEqual(PilotMapStorage(root: storage.root).downloaded, [Self.ch])
        storage.remove("ch")
        XCTAssertEqual(storage.downloaded, [])
        XCTAssertNil(storage.archive(region: "ch", kind: .map))
    }

    func testStorageRefusesAFileThatIsNoArchive() throws {
        let storage = PilotMapStorage(root: makeTestDirectory())
        XCTAssertThrowsError(try download(Self.ch, Data("<html>403</html>".utf8), into: storage))
        XCTAssertEqual(storage.downloaded, [])
    }

    func testDownloadedRegionFirstAndNeverCounted() async throws {
        let rig = try await rig([Self.ch])
        try download(Self.ch, PMTilesFixture.archive(tiles("local")), into: rig.storage)
        rig.server.put("/v1/ch/map.pmtiles", PMTilesFixture.archive(tiles("online")))
        let tile = await rig.source.tile(.map, z: border.z, x: border.x, y: border.y)
        XCTAssertEqual(tile?.origin, .downloaded("ch"))
        XCTAssertEqual(tile?.data, PMTilesFixture.content(13, border.x, border.y, "local"), "un-gzipped for MapLibre")
        XCTAssertEqual(rig.server.count, 0)
        XCTAssertEqual(rig.allowance.used, 0)
    }

    func testFirstRegionWinsAtABorder() async throws {
        let rig = try await rig([Self.ch, Self.fr])
        try download(Self.fr, PMTilesFixture.archive(tiles("fr")), into: rig.storage)
        try download(Self.ch, PMTilesFixture.archive(tiles("ch")), into: rig.storage)
        let tile = await rig.source.tile(.map, z: border.z, x: border.x, y: border.y)
        XCTAssertEqual(tile?.origin, .downloaded("ch"), "the index's order, not the download's")
    }

    func testOnlineReadIsCountedOnce() async throws {
        let rig = try await rig([Self.ch])
        rig.server.put("/v1/ch/map.pmtiles", PMTilesFixture.archive(tiles("online")))
        let tile = await rig.source.tile(.map, z: border.z, x: border.x, y: border.y)
        XCTAssertEqual(tile?.origin, .online("ch"))
        XCTAssertEqual(tile?.data, PMTilesFixture.content(13, border.x, border.y, "online"))
        XCTAssertEqual(rig.allowance.used, 1, "the tile, not the directories")
        let missing = await rig.source.tile(.map, z: 13, x: 4260, y: 2877)
        XCTAssertNil(missing)
        XCTAssertEqual(rig.allowance.used, 1, "a tile the archive lacks costs nothing")
    }

    func testOnlineFallsThroughToTheNextRegion() async throws {
        let rig = try await rig([Self.fr, Self.ch])
        rig.server.put("/v1/fr-est/map.pmtiles", PMTilesFixture.archive([.init(z: 0, x: 0, y: 0, bytes: Data("fr".utf8))]))
        rig.server.put("/v1/ch/map.pmtiles", PMTilesFixture.archive(tiles("ch")))
        let tile = await rig.source.tile(.map, z: border.z, x: border.x, y: border.y)
        XCTAssertEqual(tile?.origin, .online("ch"))
    }

    func testExhaustedAllowanceStopsOnlineTilesNotDownloadedOnes() async throws {
        let rig = try await rig([Self.ch, Self.fr])
        rig.server.put("/v1/ch/map.pmtiles", PMTilesFixture.archive(tiles("online")))
        for _ in 0..<PilotMapAllowance.freeReads { XCTAssertTrue(rig.allowance.reserve()) }
        let none = await rig.source.tile(.map, z: border.z, x: border.x, y: border.y)
        XCTAssertNil(none)
        XCTAssertEqual(rig.server.count(path: "/v1/ch/map.pmtiles"), 1, "the header, never the tile")
        try download(Self.fr, PMTilesFixture.archive(tiles("fr")), into: rig.storage)
        let local = await rig.source.tile(.map, z: border.z, x: border.x, y: border.y)
        XCTAssertEqual(local?.origin, .downloaded("fr-est"))
    }

    func testOfflineAsksNothing() async throws {
        let rig = try await rig([Self.ch], online: false)
        rig.server.put("/v1/ch/map.pmtiles", PMTilesFixture.archive(tiles("online")))
        let tile = await rig.source.tile(.map, z: border.z, x: border.x, y: border.y)
        XCTAssertNil(tile)
        XCTAssertEqual(rig.server.count, 0)
    }

    func testFailedReadIsRefunded() async throws {
        let rig = try await rig([Self.ch])
        let archive = PMTilesFixture.archive(tiles("online"))
        // The archive is cut short: the directories read, the last tile's range comes back incomplete.
        rig.server.put("/v1/ch/map.pmtiles", archive.prefix(archive.count - 40))
        let last = try XCTUnwrap(tiles("online").max { PMTiles.tileID(z: $0.z, x: $0.x, y: $0.y) < PMTiles.tileID(z: $1.z, x: $1.x, y: $1.y) })
        let tile = await rig.source.tile(.map, z: last.z, x: last.x, y: last.y)
        XCTAssertNil(tile)
        XCTAssertEqual(rig.allowance.used, 0)
    }

    func testReliefOnlyFromRegionsThatHaveIt() async throws {
        let rig = try await rig([Self.fr, Self.ch])
        rig.server.put("/v1/ch/relief.pmtiles", PMTilesFixture.archive(tiles("dem"), gzipTiles: false))
        let tile = await rig.source.tile(.relief, z: border.z, x: border.x, y: border.y)
        XCTAssertEqual(tile?.origin, .online("ch"), "France east has no relief in this index")
        XCTAssertEqual(tile?.data, PMTilesFixture.content(13, border.x, border.y, "dem"), "WebP passes as stored")
        XCTAssertEqual(rig.server.count(path: "/v1/fr-est/relief.pmtiles"), 0)
    }

    func testDownloadedRegionTheIndexDroppedStillServes() async throws {
        let rig = try await rig([])
        try download(Self.ch, PMTilesFixture.archive(tiles("kept")), into: rig.storage)
        let tile = await rig.source.tile(.map, z: border.z, x: border.x, y: border.y)
        XCTAssertEqual(tile?.origin, .downloaded("ch"))
    }

    func testPruneDropsDirectoriesOfOldBuilds() async throws {
        let rig = try await rig([Self.ch])
        rig.server.put("/v1/ch/map.pmtiles", PMTilesFixture.archive(tiles("online")))
        _ = await rig.source.tile(.map, z: 0, x: 0, y: 0)
        let live = rig.source.cacheDirectory.appendingPathComponent("ch-map-20261025")
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        let stale = rig.source.cacheDirectory.appendingPathComponent("ch-map-20260901")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        rig.source.pruneDirectoryCache()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
    }

    // MARK: URLProtocol

    func testRequestsParse() {
        func parse(_ s: String) -> PilotTileURLProtocol.Request { PilotTileURLProtocol.parse(URL(string: s)) }
        XCTAssertEqual(parse("https://tiles.aerocheck.app/v1/map/13/4251/2877"), .tile(.map, z: 13, x: 4251, y: 2877))
        XCTAssertEqual(parse("https://tiles.aerocheck.app/v1/relief/11/1062/719"), .tile(.relief, z: 11, x: 1062, y: 719))
        XCTAssertEqual(parse("https://tiles.aerocheck.app/v1/glyphs/B612%20Bold,B612%20Regular/0-255.pbf"),
                       .glyphs(fonts: ["B612 Bold", "B612 Regular"], range: "0-255.pbf"))
        XCTAssertEqual(parse("https://tiles.aerocheck.app/v1/glyphs/..%2F..%2Fsecret/0-255.pbf"), .unknown)
        XCTAssertEqual(parse("https://tiles.aerocheck.app/v1/glyphs/B612%20Bold/x.pbf"), .unknown)
        XCTAssertEqual(parse("https://tiles.aerocheck.app/v1/ch/map.pmtiles"), .unknown)
        XCTAssertEqual(parse("https://example.com/v1/map/1/0/0"), .unknown)
        XCTAssertTrue(PilotTileURLProtocol.canInit(with: URLRequest(url: URL(string: "https://tiles.aerocheck.app/v1/map/0/0/0")!)))
        XCTAssertFalse(PilotTileURLProtocol.canInit(with: URLRequest(url: URL(string: "https://api.aerocheck.app/v1/map/0/0/0")!)))
    }

    func testBundledGlyphsCoverTheStylesFonts() throws {
        let folder = try XCTUnwrap(Bundle.main.url(forResource: "PilotMapGlyphs", withExtension: nil))
        for font in ["B612 Regular", "B612 Bold", "B612 Italic", "B612 Bold Italic"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(font).appendingPathComponent("0-255.pbf").path), font)
        }
    }

    /// MapLibre's session, as `registerWithMapLibre` sets it up, without MapLibre: a session with the protocol.
    func testURLProtocolAnswersMapLibresRequests() async throws {
        let rig = try await rig([Self.ch])
        try download(Self.ch, PMTilesFixture.archive(tiles("local")), into: rig.storage)
        let glyphs = makeTestDirectory()
        try FileManager.default.createDirectory(at: glyphs.appendingPathComponent("B612 Regular"), withIntermediateDirectories: true)
        try Data("glyph range".utf8).write(to: glyphs.appendingPathComponent("B612 Regular/0-255.pbf"))

        let previousSource = PilotTileURLProtocol.source, previousGlyphs = PilotTileURLProtocol.glyphsDirectory
        PilotTileURLProtocol.source = rig.source
        PilotTileURLProtocol.glyphsDirectory = glyphs
        defer { PilotTileURLProtocol.source = previousSource; PilotTileURLProtocol.glyphsDirectory = previousGlyphs }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PilotTileURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (tile, tileResponse) = try await session.data(from: URL(string: "https://tiles.aerocheck.app/v1/map/13/\(border.x)/\(border.y)")!)
        XCTAssertEqual((tileResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(tile, PMTilesFixture.content(13, border.x, border.y, "local"))

        let (_, missing) = try await session.data(from: URL(string: "https://tiles.aerocheck.app/v1/map/13/10/10")!)
        XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertEqual((missing as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control"), "no-store")

        let (glyph, _) = try await session.data(from: URL(string: "https://tiles.aerocheck.app/v1/glyphs/B612%20Bold,B612%20Regular/0-255.pbf")!)
        XCTAssertEqual(glyph, Data("glyph range".utf8), "the first font of the stack that exists")

        let (_, other) = try await session.data(from: URL(string: "https://tiles.aerocheck.app/v1/index.json")!)
        XCTAssertEqual((other as? HTTPURLResponse)?.statusCode, 404, "MapLibre is never handed anything else on the host")
    }
}
