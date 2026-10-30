import XCTest
@testable import AeroCheck

/// Where the pilot's map's tiles come from (6.8.0): the regions index, the downloaded regions, the tile source
/// (every region's part joined, online counted against the allowance, the overview online at low zooms, else
/// nothing) and the URLProtocol MapLibre asks.
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

    private static let overview = PilotMapRegion(id: "overview", name: "Overview", bounds: [-180, -60, 180, 80],
                                                 built: "20261102", mapBytes: 9_000_000, reliefBytes: 0)

    private func indexJSON(_ regions: [PilotMapRegion], overview: PilotMapRegion? = nil) throws -> Data {
        var body: [String: Any] = ["version": 1, "generated": "2026-10-26T07:32:40Z",
                                   "regions": try regions.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }]
        if let overview { body["overview"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(overview)) }
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
    private func rig(_ regions: [PilotMapRegion], overview: PilotMapRegion? = nil, online: Bool = true) async throws -> Rig {
        let root = makeTestDirectory()
        let server = PMTilesFixture.Server()
        let index = try indexJSON(regions, overview: overview)
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

    private func download(_ region: PilotMapRegion, _ data: Data, into storage: PilotMapStorage,
                          kind: PilotMapKind = .map) throws {
        let file = makeTestDirectory().appendingPathComponent("\(kind.rawValue).pmtiles")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        try storage.install(region, files: [kind: file])
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

    func testRegionFileNames() {
        let named = PilotMapRegion(id: "ch", name: "CH", bounds: [5.9, 45.8, 10.5, 47.8], built: "20261026", mapBytes: 1,
                                   reliefBytes: 1, mapFile: "map-1da3495153e271df.pmtiles")
        XCTAssertTrue(named.isValid)
        XCTAssertEqual(named.file(of: .map), "map-1da3495153e271df.pmtiles")
        XCTAssertEqual(named.file(of: .relief), "relief.pmtiles", "an entry without a name: the old file")
        XCTAssertEqual(PilotMapConfig.archiveURL(region: named, kind: .map).absoluteString,
                       "https://tiles.aerocheck.app/v1/ch/map-1da3495153e271df.pmtiles")
        for bad in ["../index.json", "map.json", "a/b.pmtiles", ".pmtiles", "map%2F.pmtiles"] {
            let region = PilotMapRegion(id: "ch", name: "CH", bounds: [5.9, 45.8, 10.5, 47.8], built: "20261026",
                                        mapBytes: 1, reliefBytes: 1, mapFile: bad)
            XCTAssertFalse(region.isValid, bad)
        }
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
        XCTAssertEqual(asked.requests.first?.url?.path, PilotMapConfig.indexURL.path)
        XCTAssertEqual(asked.requests.first?.url?.query?.hasPrefix("h="), true, "the hour's key, past the edge cache")
        XCTAssertNotNil(asked.requests.first?.value(forHTTPHeaderField: "User-Agent"))
    }

    /// The lists are asked under the hour's key: the edge cache keeps a bare name for a day, and a monthly build's new
    /// index must not wait that long behind the one it replaced. (6.8.0)
    func testAListIsAskedUnderTheHoursKey() {
        let at = Date(timeIntervalSince1970: 1_792_998_100)
        let url = PilotMapConfig.listURL(PilotMapConfig.indexURL, now: at)
        XCTAssertEqual(url.absoluteString, "https://tiles.aerocheck.app/v1/index.json?h=498055")
        XCTAssertEqual(PilotMapConfig.listURL(PilotMapConfig.indexURL, now: at.addingTimeInterval(1_800)), url,
                       "every device in the hour shares the cached answer")
        XCTAssertNotEqual(PilotMapConfig.listURL(PilotMapConfig.indexURL, now: at.addingTimeInterval(3_600)), url)
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

    func testBothRegionsJoinAtABorder() async throws {
        let rig = try await rig([Self.ch, Self.fr])
        try download(Self.fr, PMTilesFixture.archive(tiles("fr")), into: rig.storage)
        try download(Self.ch, PMTilesFixture.archive(tiles("ch")), into: rig.storage)
        let tile = await rig.source.tile(.map, z: border.z, x: border.x, y: border.y)
        XCTAssertEqual(tile?.origin, .merged([.downloaded("ch"), .downloaded("fr-est")]), "in the index's order")
        XCTAssertEqual(tile?.whole, true)
        XCTAssertEqual(rig.server.count, 0)
    }

    func testADownloadedPartAndAnOnlinePartJoin() async throws {
        let rig = try await rig([Self.ch, Self.fr])
        try download(Self.ch, PMTilesFixture.archive(tiles("ch")), into: rig.storage)
        rig.server.put("/v1/fr-est/map.pmtiles", PMTilesFixture.archive(tiles("fr")))
        let tile = await rig.source.tile(.map, z: border.z, x: border.x, y: border.y)
        XCTAssertEqual(tile?.origin, .merged([.downloaded("ch"), .online("fr-est")]))
        XCTAssertEqual(tile?.whole, true)
        XCTAssertEqual(rig.allowance.used, 1, "only the online part counts")
    }

    func testOfflineTheDownloadedPartsAreAllThereIs() async throws {
        let rig = try await rig([Self.ch, Self.fr], online: false)
        try download(Self.ch, PMTilesFixture.archive(tiles("ch")), into: rig.storage)
        let tile = await rig.source.tile(.map, z: border.z, x: border.x, y: border.y)
        XCTAssertEqual(tile?.origin, .downloaded("ch"))
        XCTAssertEqual(tile?.whole, false, "France's half comes once online: never kept")
    }

    func testPastTheAllowanceTheDownloadedHalfIsNotKept() async throws {
        let rig = try await rig([Self.ch, Self.fr])
        try download(Self.ch, PMTilesFixture.archive(tiles("ch")), into: rig.storage)
        rig.server.put("/v1/fr-est/map.pmtiles", PMTilesFixture.archive(tiles("fr")))
        for _ in 0..<PilotMapAllowance.freeReads { _ = rig.allowance.reserve() }
        let tile = await rig.source.tile(.map, z: border.z, x: border.x, y: border.y)
        XCTAssertEqual(tile?.origin, .downloaded("ch"))
        XCTAssertEqual(tile?.whole, false)
    }

    func testARegionThatCantBeAskedLeavesTheDownloadedHalfNotKept() async throws {
        let rig = try await rig([Self.ch, Self.fr])   // France not published: its header read fails
        try download(Self.ch, PMTilesFixture.archive(tiles("ch")), into: rig.storage)
        let tile = await rig.source.tile(.map, z: border.z, x: border.x, y: border.y)
        XCTAssertEqual(tile?.origin, .downloaded("ch"))
        XCTAssertEqual(tile?.whole, false)
    }

    func testOnlineTheOverviewAnswersLowZooms() async throws {
        let rig = try await rig([Self.ch, Self.fr], overview: Self.overview)
        rig.server.put("/v1/overview/map.pmtiles", PMTilesFixture.archive(tiles("overview")))
        rig.server.put("/v1/ch/map.pmtiles", PMTilesFixture.archive(tiles("ch")))
        let low = await rig.source.tile(.map, z: 0, x: 0, y: 0)
        XCTAssertEqual(low?.origin, .online("overview"))
        XCTAssertEqual(rig.server.count(path: "/v1/ch/map.pmtiles"), 0, "no region asked at zoom 0")
        let high = await rig.source.tile(.map, z: border.z, x: border.x, y: border.y)
        XCTAssertEqual(high?.origin, .online("ch"), "the regions from zoom 8")
    }

    func testOfflineALowZoomJoinsTheDownloadedRegions() async throws {
        let rig = try await rig([Self.ch, Self.fr], overview: Self.overview, online: false)
        try download(Self.ch, PMTilesFixture.archive(tiles("ch")), into: rig.storage)
        try download(Self.fr, PMTilesFixture.archive(tiles("fr")), into: rig.storage)
        let tile = await rig.source.tile(.map, z: 0, x: 0, y: 0)
        XCTAssertEqual(tile?.origin, .merged([.downloaded("ch"), .downloaded("fr-est")]))
        XCTAssertEqual(tile?.whole, false, "online, the overview has the rest of the world")
    }

    // MARK: Relief past a region's depth

    /// A relief archive as most regions have it: its deepest tile at zoom 10, over Neuchâtel, a uniform `metres`.
    private func reliefToTen(metres: Double) -> Data {
        let v = metres + 32768
        var bytes: [UInt8] = []
        for _ in 0..<16 { bytes += [UInt8(Int(v) / 256), UInt8(Int(v) % 256), 0, 255] }
        let png = PilotTileMerge.png(PilotTileMerge.Pixels(width: 4, height: 4, bytes: bytes))!
        return PMTilesFixture.archive([.init(z: 10, x: border.x >> 3, y: border.y >> 3, bytes: png)], gzipTiles: false)
    }

    func testReliefPastARegionsDepthIsTheTileAboveEnlarged() async throws {
        let rig = try await rig([Self.ch])
        try download(Self.ch, PMTilesFixture.archive(tiles("ch")), into: rig.storage)
        try download(Self.ch, reliefToTen(metres: 430), into: rig.storage, kind: .relief)
        let enlarged = await rig.source.tile(.relief, z: 11, x: border.x >> 2, y: border.y >> 2)
        let tile = try XCTUnwrap(enlarged)
        XCTAssertEqual(tile.origin, .downloaded("ch"))
        let pixels = try XCTUnwrap(PilotTileMerge.pixels(tile.data))
        XCTAssertEqual(pixels.width, 4)
        XCTAssertEqual(Array(pixels.bytes[0..<3]), [129, 174, 0], "430 m, enlarged from zoom 10")
        let atTen = await rig.source.tile(.relief, z: 10, x: border.x >> 3, y: border.y >> 3)
        let own = try XCTUnwrap(atTen)
        XCTAssertEqual(own.data, try XCTUnwrap(rig.storage.archive(region: "ch", kind: .relief)?.tile(z: 10, x: border.x >> 3, y: border.y >> 3)),
                       "at its own depth, the tile as it is")
    }

    func testOnlineAnEnlargedTilesFourSiblingsCostOneRead() async throws {
        let rig = try await rig([Self.ch])
        rig.server.put("/v1/ch/relief.pmtiles", reliefToTen(metres: 430))
        let (px, py) = (border.x >> 3, border.y >> 3)
        for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
            let tile = await rig.source.tile(.relief, z: 11, x: px * 2 + dx, y: py * 2 + dy)
            XCTAssertEqual(tile?.origin, .online("ch"))
        }
        XCTAssertEqual(rig.allowance.used, 1, "the zoom-10 tile read once for its four quarters")
    }

    func testTheMapIsNeverEnlarged() {
        XCTAssertEqual(PilotTileSource.depth(.map, z: 13, deepest: 10), 0)
        XCTAssertEqual(PilotTileSource.depth(.relief, z: 11, deepest: 8), 3, "Greenland")
        XCTAssertEqual(PilotTileSource.depth(.relief, z: 11, deepest: 11), 0, "Switzerland")
    }

    private static func tile(latitude: Double, longitude: Double, z: Int) -> (x: Int, y: Int) {
        let n = Double(1 << z)
        let y = (1 - asinh(tan(latitude * .pi / 180)) / .pi) / 2 * n
        return (Int((longitude + 180) / 360 * n), Int(y))
    }

    func testARegionAcross180TouchesOnlyItsBoxes() {
        let alaska = PilotMapRegion(id: "us-ak", name: "Alaska", bounds: [-180, 51.2, 180, 71.6], built: "20261102",
                                    mapBytes: 1, reliefBytes: 1,
                                    boxes: [[-180, 51.2, -129.9, 71.6], [172.4, 51.3, 180, 53.1]])
        XCTAssertTrue(alaska.isValid)
        let anchorage = Self.tile(latitude: 61.2, longitude: -149.9, z: 8)
        XCTAssertTrue(alaska.touches(z: 8, x: anchorage.x, y: anchorage.y))
        let bern = Self.tile(latitude: 46.95, longitude: 7.44, z: 8)
        XCTAssertFalse(alaska.touches(z: 8, x: bern.x, y: bern.y), "the box over the whole world isn't used")
        XCTAssertFalse(alaska.contains(latitude: 46.95, longitude: 7.44))
    }

    func testANameInTheAppsLanguage() {
        let region = PilotMapRegion(id: "fr-bre", name: "Brittany", bounds: [-5.2, 47.2, -1.0, 48.9], built: "20261102",
                                    mapBytes: 1, reliefBytes: 0, names: ["en": "Brittany", "fr": "Bretagne", "de": "Bretagne"],
                                    country: "FR")
        XCTAssertTrue(["Brittany", "Bretagne"].contains(region.displayName))
        let old = PilotMapRegion(id: "ch", name: "Switzerland and Liechtenstein", bounds: [5.64, 45.6, 10.78, 48.0],
                                 built: "20261025", mapBytes: 1, reliefBytes: 1)
        XCTAssertEqual(old.displayName, "Switzerland and Liechtenstein", "an index from before the names")
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

    /// MapLibre keeps a "none" and retries a "not now": a tile missing offline, or past the allowance, must come
    /// back once online or downloaded.
    /// A first launch, before the index has come: no tile is "nothing there", which MapLibre would keep a day.
    func testBeforeTheFirstIndexNothingIsKeptAsNone() async throws {
        let root = makeTestDirectory()
        let store = PilotMapIndexStore(directory: root.appendingPathComponent("index"),
                                       fetch: { _ in throw URLError(.notConnectedToInternet) })
        XCTAssertFalse(store.hasIndex)
        let source = PilotTileSource(index: store, storage: PilotMapStorage(root: root.appendingPathComponent("regions")),
                                     allowance: PilotMapAllowance(defaults: makeTestDefaults()),
                                     cacheDirectory: root.appendingPathComponent("directories"),
                                     headers: { [:] }, fetch: PMTilesFixture.Server().fetch, isOnline: { true })
        guard case .unavailable = await source.lookup(.map, z: border.z, x: border.x, y: border.y) else {
            return XCTFail("before the index: not now")
        }
        let indexed = try await rig([Self.ch])
        guard case .none = await indexed.source.lookup(.map, z: 13, x: 100, y: 100) else {
            return XCTFail("with the index, far from every region: nothing there")
        }
    }

    func testNoneOnlyWhereNothingCanCome() async throws {
        func kind(_ lookup: PilotTileSource.Lookup) -> String {
            switch lookup { case .tile: return "tile"; case .none: return "none"; case .unavailable: return "unavailable" }
        }
        let offline = try await rig([Self.ch], online: false)
        let atBorderOffline = await offline.source.lookup(.map, z: border.z, x: border.x, y: border.y)
        XCTAssertEqual(kind(atBorderOffline), "unavailable")
        let nowhere = await offline.source.lookup(.map, z: 13, x: 100, y: 100)
        XCTAssertEqual(kind(nowhere), "none", "no region there at all")

        let exhausted = try await rig([Self.ch])
        exhausted.server.put("/v1/ch/map.pmtiles", PMTilesFixture.archive(tiles("online")))
        for _ in 0..<PilotMapAllowance.freeReads { _ = exhausted.allowance.reserve() }
        let spent = await exhausted.source.lookup(.map, z: border.z, x: border.x, y: border.y)
        XCTAssertEqual(kind(spent), "unavailable")

        let down = try await rig([Self.ch])   // nothing published: the header read fails
        let unreachable = await down.source.lookup(.map, z: border.z, x: border.x, y: border.y)
        XCTAssertEqual(kind(unreachable), "unavailable")

        let missing = try await rig([Self.ch])
        missing.server.put("/v1/ch/map.pmtiles", PMTilesFixture.archive(tiles("online")))
        let notInArchive = await missing.source.lookup(.map, z: 13, x: 4260, y: 2877)
        XCTAssertEqual(kind(notInArchive), "none", "the archive has no tile there")
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
        XCTAssertEqual(parse("https://tiles.aerocheck.app/v1/map/13/4251/2877?\(PilotMapConfig.cacheGeneration)"),
                       .tile(.map, z: 13, x: 4251, y: 2877), "the cache's query isn't part of the tile")
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

    /// The world outline comes from the bundle, to tile zoom 6, offline or not.
    func testBundledOutlineAnswersItsTiles() async throws {
        XCTAssertEqual(PilotTileURLProtocol.parse(URL(string: "https://tiles.aerocheck.app/local/outline/5/16/11")),
                       .outline(z: 5, x: 16, y: 11))
        XCTAssertNotNil(PilotMap.outline)
        guard case let .body(data, type) = await PilotTileURLProtocol.answer(.outline(z: 5, x: 16, y: 11)) else {
            return XCTFail("Switzerland's zoom-5 tile")
        }
        XCTAssertEqual(type, "application/x-protobuf")
        XCTAssertFalse(PMTiles.isGzip(data), "MapLibre gets the tile unzipped")
        guard case .none = await PilotTileURLProtocol.answer(.outline(z: 7, x: 66, y: 45)) else {
            return XCTFail("nothing past zoom 6: MapLibre draws zoom 6 enlarged")
        }
    }

    /// The style as MapLibre loads it: every address filled in, the outline's names in the app's language.
    func testStyleIsFilledIn() throws {
        let url = try XCTUnwrap(PilotMapStyle.url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("{{"), "a placeholder left")
        XCTAssertTrue(text.contains(PilotMapConfig.outlineTileTemplate))
        XCTAssertTrue(text.contains(PilotMapConfig.mapTileTemplate))
        XCTAssertTrue(text.contains(PilotMapConfig.reliefTileTemplate))
        XCTAssertTrue(text.contains("\"label:\(PilotMapStyle.outlineLanguage)\""))
        XCTAssertTrue(["en", "fr", "de"].contains(PilotMapStyle.outlineLanguage))
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
        XCTAssertEqual((tileResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control"), "max-age=2592000")
        XCTAssertEqual(tile, PMTilesFixture.content(13, border.x, border.y, "local"))

        let (_, missing) = try await session.data(from: URL(string: "https://tiles.aerocheck.app/v1/map/13/10/10")!)
        XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 404, "no region there: nothing, kept a day")

        let (glyph, _) = try await session.data(from: URL(string: "https://tiles.aerocheck.app/v1/glyphs/B612%20Bold,B612%20Regular/0-255.pbf")!)
        XCTAssertEqual(glyph, Data("glyph range".utf8), "the first font of the stack that exists")

        let (_, other) = try await session.data(from: URL(string: "https://tiles.aerocheck.app/v1/index.json")!)
        XCTAssertEqual((other as? HTTPURLResponse)?.statusCode, 404, "MapLibre is never handed anything else on the host")
    }

    /// Half a border's tile, offline: drawn, but stale at once, so MapLibre asks again and gets the whole tile online.
    /// (The builds before 29 Oct kept Switzerland's half for a month.)
    func testHalfABordersTileIsDrawnButNotKept() async throws {
        let rig = try await rig([Self.ch, Self.fr], online: false)
        try download(Self.ch, PMTilesFixture.archive(tiles("ch")), into: rig.storage)
        let previousSource = PilotTileURLProtocol.source
        PilotTileURLProtocol.source = rig.source
        defer { PilotTileURLProtocol.source = previousSource }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PilotTileURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let url = URL(string: "https://tiles.aerocheck.app/v1/map/13/\(border.x)/\(border.y)?\(PilotMapConfig.cacheGeneration)")!
        let (tile, response) = try await session.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(tile, PMTilesFixture.content(13, border.x, border.y, "ch"))
        let cacheControl = try XCTUnwrap(http.value(forHTTPHeaderField: "Cache-Control"))
        XCTAssertTrue(cacheControl.contains("max-age=0"), cacheControl)
    }
}
