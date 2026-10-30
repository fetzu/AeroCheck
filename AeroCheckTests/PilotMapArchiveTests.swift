import XCTest
@testable import AeroCheck

/// The pilot's map archives (6.8.0): the PMTiles format, a downloaded region's file, a remote archive read by
/// ranges. The archives are written by the test itself (`PMTilesFixture`).
final class PilotMapArchiveTests: XCTestCase {

    private let tiles: [PMTilesFixture.Tile] = {
        var list: [PMTilesFixture.Tile] = [.init(z: 0, x: 0, y: 0, bytes: PMTilesFixture.content(0, 0, 0))]
        for x in 0..<2 { for y in 0..<2 { list.append(.init(z: 1, x: x, y: y, bytes: PMTilesFixture.content(1, x, y))) } }
        for x in 4250..<4254 { for y in 2876..<2879 { list.append(.init(z: 13, x: x, y: y, bytes: PMTilesFixture.content(13, x, y))) } }
        return list
    }()

    private func write(_ data: Data) throws -> URL {
        let url = makeTestDirectory().appendingPathComponent("fixture.pmtiles")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    // MARK: Format

    func testTileIDsFollowTheSpec() {
        // Values from the reference implementation (pmtiles 3, Python).
        XCTAssertEqual(PMTiles.tileID(z: 0, x: 0, y: 0), 0)
        XCTAssertEqual(PMTiles.tileID(z: 1, x: 0, y: 0), 1)
        XCTAssertEqual(PMTiles.tileID(z: 1, x: 0, y: 1), 2)
        XCTAssertEqual(PMTiles.tileID(z: 1, x: 1, y: 1), 3)
        XCTAssertEqual(PMTiles.tileID(z: 1, x: 1, y: 0), 4)
        XCTAssertEqual(PMTiles.tileID(z: 2, x: 0, y: 0), 5)
        XCTAssertEqual(PMTiles.tileID(z: 12, x: 3423, y: 1763), 19_078_479)
        XCTAssertEqual(PMTiles.tileID(z: 13, x: 4251, y: 2877), 79_372_683)
    }

    func testDirectoryRoundTrip() throws {
        let entries = [PMTiles.Entry(tileID: 3, offset: 0, length: 10, runLength: 1),
                       PMTiles.Entry(tileID: 4, offset: 10, length: 5, runLength: 2),
                       PMTiles.Entry(tileID: 900, offset: 400, length: 7, runLength: 1)]
        XCTAssertEqual(try PMTiles.directory(PMTilesFixture.serialize(entries)), entries)
    }

    func testCorruptDirectoryIsRefused() {
        XCTAssertThrowsError(try PMTiles.directory(Data([0xff, 0xff, 0xff])))
        XCTAssertThrowsError(try PMTiles.directory(Data([200, 1])))   // claims 200 entries in two bytes
    }

    func testGunzipRoundTripAndGarbage() throws {
        let text = Data(String(repeating: "pilot's map ", count: 200).utf8)
        XCTAssertEqual(try PMTiles.gunzip(PMTilesFixture.gzip(text)), text)
        XCTAssertThrowsError(try PMTiles.gunzip(Data("not gzip at all, not even close".utf8)))
        XCTAssertEqual(PMTiles.plain(text), text, "plain bytes pass through")
        XCTAssertEqual(PMTiles.plain(PMTilesFixture.gzip(text)), text)
    }

    func testNotAnArchiveIsRefused() throws {
        let url = try write(Data(repeating: 7, count: 400))
        XCTAssertThrowsError(try PMTilesArchive(url: url))
    }

    // MARK: Local archive

    func testReadsEveryTileGzipDirectories() throws {
        let archive = try PMTilesArchive(url: write(PMTilesFixture.archive(tiles)))
        XCTAssertEqual(archive.header.minZoom, 0)
        XCTAssertEqual(archive.header.maxZoom, 13)
        XCTAssertTrue(archive.header.tilesAreGzip)
        for tile in tiles {
            let stored = try XCTUnwrap(archive.tile(z: tile.z, x: tile.x, y: tile.y), "\(tile.z)/\(tile.x)/\(tile.y)")
            XCTAssertEqual(PMTiles.plain(stored), tile.bytes)
        }
    }

    func testReadsPlainDirectoriesAndPlainTiles() throws {
        let archive = try PMTilesArchive(url: write(PMTilesFixture.archive(tiles, gzipTiles: false, gzipDirectories: false)))
        XCTAssertFalse(archive.header.tilesAreGzip)
        XCTAssertEqual(archive.tile(z: 13, x: 4251, y: 2877), PMTilesFixture.content(13, 4251, 2877))
    }

    func testReadsThroughLeafDirectories() throws {
        let archive = try PMTilesArchive(url: write(PMTilesFixture.archive(tiles, leafSize: 3)))
        for tile in tiles {
            XCTAssertEqual(archive.tile(z: tile.z, x: tile.x, y: tile.y).flatMap(PMTiles.plain), tile.bytes)
        }
    }

    func testRunLengthEntriesShareBytes() throws {
        // Two neighbours on the curve with the same content (open water) stored once.
        let same = Data("sea".utf8)
        let run = [PMTilesFixture.Tile(z: 1, x: 0, y: 0, bytes: same), PMTilesFixture.Tile(z: 1, x: 0, y: 1, bytes: same),
                   PMTilesFixture.Tile(z: 1, x: 1, y: 1, bytes: Data("land".utf8))]
        let archive = try PMTilesArchive(url: write(PMTilesFixture.archive(run, shareRuns: true)))
        XCTAssertEqual(archive.tile(z: 1, x: 0, y: 0).flatMap(PMTiles.plain), same)
        XCTAssertEqual(archive.tile(z: 1, x: 0, y: 1).flatMap(PMTiles.plain), same)
        XCTAssertEqual(archive.tile(z: 1, x: 1, y: 1).flatMap(PMTiles.plain), Data("land".utf8))
        XCTAssertNil(archive.tile(z: 1, x: 1, y: 0))
    }

    func testMissingTilesAndZoomsAreNil() throws {
        let archive = try PMTilesArchive(url: write(PMTilesFixture.archive(tiles, leafSize: 4)))
        XCTAssertNil(archive.tile(z: 13, x: 0, y: 0))
        XCTAssertNil(archive.tile(z: 14, x: 8502, y: 5754), "past the archive's last zoom")
        XCTAssertNil(archive.tile(z: 5, x: 16, y: 11), "a zoom the archive skips")
    }

    // MARK: Remote archive

    private func remote(_ server: PMTilesFixture.Server, cache: URL? = nil) -> PMTilesRemoteArchive {
        PMTilesRemoteArchive(url: URL(string: "https://tiles.aerocheck.app/v1/ch/map.pmtiles")!,
                             cacheDirectory: cache ?? makeTestDirectory(), headers: ["X-Test": "1"], fetch: server.fetch)
    }

    func testRemoteReadsDirectoriesThenOneRangePerTile() async throws {
        let server = PMTilesFixture.Server()
        server.put("/v1/ch/map.pmtiles", PMTilesFixture.archive(tiles, leafSize: 4))
        let archive = remote(server)
        let location = try await archive.locate(z: 13, x: 4252, y: 2878)
        let found = try XCTUnwrap(location)
        let directoryReads = server.count
        XCTAssertGreaterThanOrEqual(directoryReads, 2, "the first 16 KiB, then a leaf")
        let stored = try await archive.read(found)
        XCTAssertEqual(PMTiles.plain(stored), PMTilesFixture.content(13, 4252, 2878))
        XCTAssertEqual(server.count, directoryReads + 1, "one read for the tile")
        XCTAssertEqual(server.requests.last?.value(forHTTPHeaderField: "X-Test"), "1")
        XCTAssertEqual(server.requests.first?.value(forHTTPHeaderField: "Range"), "bytes=0-16383")
    }

    func testRemoteMissingTileCostsNoTileRead() async throws {
        let server = PMTilesFixture.Server()
        server.put("/v1/ch/map.pmtiles", PMTilesFixture.archive(tiles))
        let missing = try await remote(server).locate(z: 13, x: 1, y: 1)
        XCTAssertNil(missing)
        XCTAssertEqual(server.count, 1, "the header read only")
    }

    func testRemoteDirectoriesAreKeptOnDisk() async throws {
        let server = PMTilesFixture.Server()
        server.put("/v1/ch/map.pmtiles", PMTilesFixture.archive(tiles, leafSize: 4))
        let cache = makeTestDirectory()
        _ = try await remote(server, cache: cache).locate(z: 13, x: 4250, y: 2876)
        let first = server.count
        // A new reader (the next launch) on the same cache asks the server for nothing but tiles.
        let again = remote(server, cache: cache)
        let location = try await again.locate(z: 13, x: 4250, y: 2876)
        XCTAssertNotNil(location)
        XCTAssertEqual(server.count, first)
    }

    func testRemoteFileReplacedMidwayDiscardsTheCache() async throws {
        let server = PMTilesFixture.Server()
        server.put("/v1/ch/map.pmtiles", PMTilesFixture.archive(tiles), etag: "\"old\"")
        let cache = makeTestDirectory()
        let archive = remote(server, cache: cache)
        let locationFound = try await archive.locate(z: 1, x: 1, y: 1)
        let location = try XCTUnwrap(locationFound)
        // The monthly build lands: same address, other bytes, other ETag.
        server.put("/v1/ch/map.pmtiles", PMTilesFixture.archive(tiles, leafSize: 2), etag: "\"new\"")
        do {
            _ = try await archive.read(location)
            XCTFail("a read across two builds must fail")
        } catch {
            XCTAssertEqual(error as? PMTilesRemoteArchive.Failure, .changed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("first.bin").path))
        // The next read starts over on the new build.
        let freshFound = try await archive.locate(z: 1, x: 1, y: 1)
        let fresh = try XCTUnwrap(freshFound)
        let stored = try await archive.read(fresh)
        XCTAssertEqual(PMTiles.plain(stored), PMTilesFixture.content(1, 1, 1))
    }

    func testRemoteServerIgnoringRangeStillWorks() async throws {
        let server = PMTilesFixture.Server()
        server.ignoresRange = true
        server.put("/v1/ch/map.pmtiles", PMTilesFixture.archive(tiles))
        let archive = remote(server)
        let locationFound = try await archive.locate(z: 0, x: 0, y: 0)
        let location = try XCTUnwrap(locationFound)
        let stored = try await archive.read(location)
        XCTAssertEqual(PMTiles.plain(stored), PMTilesFixture.content(0, 0, 0))
    }

    func testRemoteHTTPErrorThrows() async {
        let server = PMTilesFixture.Server()   // nothing published: 404
        do {
            _ = try await remote(server).locate(z: 0, x: 0, y: 0)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? PMTilesRemoteArchive.Failure, .http(404))
        }
    }
}
