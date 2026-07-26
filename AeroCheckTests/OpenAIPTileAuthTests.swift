import XCTest
@testable import AeroCheck

/// SA-11: the OpenAIP key must never appear in a tile URL.
///
/// A key in a query string lands in every URL-level log along the path — the device's on-disk
/// `URLCache` entries, any enterprise/MDM TLS-inspecting proxy, and OpenAIP's own access logs.
/// The REST path (`OpenAIPDataService`) always sent it as a header; the tile path did not, which
/// was an internal inconsistency rather than a platform constraint. If the key leaks, an attacker
/// burns the operator's quota until it is throttled and the airspace overlay silently stops
/// rendering for every user.
///
/// (The residual "a client-embedded key is extractable from the binary" half is inherent to
/// calling a keyed third-party API directly from the app — see L5 in the audit. These tests cover
/// the fixable half.)
final class OpenAIPTileAuthTests: XCTestCase {

    func testTileURLCarriesNoQueryParameters() throws {
        let url = try XCTUnwrap(OpenAIPConfig.tileURL(subdomain: "a", z: 10, x: 530, y: 355))

        XCTAssertNil(url.query, "tile URLs must have no query string at all")
        XCTAssertFalse(url.absoluteString.lowercased().contains("apikey"),
                       "no apiKey parameter may appear in a tile URL")
        XCTAssertEqual(url.path, "/api/data/openaip/10/530/355.png")
    }

    func testTileRequestSendsTheKeyAsAHeader() throws {
        let request = try XCTUnwrap(OpenAIPConfig.tileRequest(subdomain: "b", z: 8, x: 1, y: 2))

        XCTAssertEqual(request.value(forHTTPHeaderField: OpenAIPConfig.apiKeyHeader),
                       OpenAIPConfig.apiKey)
        XCTAssertEqual(OpenAIPConfig.apiKeyHeader, "x-openaip-api-key",
                       "must match the header the REST path already uses")
    }

    func testTileRequestURLDoesNotLeakTheKey() throws {
        let request = try XCTUnwrap(OpenAIPConfig.tileRequest(subdomain: "c", z: 12, x: 3, y: 4))
        let urlString = try XCTUnwrap(request.url?.absoluteString)

        XCTAssertNil(request.url?.query)
        // Only meaningful when a key is actually configured (it is absent in a fresh checkout and
        // in CI without the secret), but it is the assertion that matters when one IS present.
        if !OpenAIPConfig.apiKey.isEmpty {
            XCTAssertFalse(urlString.contains(OpenAIPConfig.apiKey),
                           "the key must not appear anywhere in the request URL")
        }
    }

    func testEveryTileSubdomainProducesAKeylessURL() throws {
        for subdomain in OpenAIPConfig.tileSubdomains {
            let url = try XCTUnwrap(OpenAIPConfig.tileURL(subdomain: subdomain, z: 9, x: 5, y: 6))
            XCTAssertNil(url.query, "subdomain \(subdomain) leaked a query string")
        }
    }
}

/// The OpenAIP raster tile cache was the only one of six layers with NO eviction: tiles are keyed
/// `{z}/{x}/{y}.png` with no country namespace, so deselecting a country left its tiles on disk
/// permanently — nothing outside the new bounding box is ever revisited. The cache only ever grew,
/// with the Settings size readout as the only clue and a full delete as the only remedy. (APP-10)
@MainActor
final class OpenAIPTilePruneTests: XCTestCase {

    private var tileRoot: URL {
        DataPersistenceManager.shared.mapTilesDirectory
            .appendingPathComponent("OpenAIP", isDirectory: true)
    }

    private func writeTile(z: Int, x: Int, y: Int) throws {
        let dir = tileRoot
            .appendingPathComponent("\(z)", isDirectory: true)
            .appendingPathComponent("\(x)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: dir.appendingPathComponent("\(y).png"))
    }

    private func tileExists(z: Int, x: Int, y: Int) -> Bool {
        FileManager.default.fileExists(atPath: tileRoot
            .appendingPathComponent("\(z)")
            .appendingPathComponent("\(x)")
            .appendingPathComponent("\(y).png").path)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tileRoot)
        super.tearDown()
    }

    /// A tile far outside any plausible Swiss bounding box must be reclaimed, while the cache root
    /// itself survives. Zoom 7 x=0 y=0 is the Atlantic near (0°, 85°N) — never inside CH.
    func testPruneRemovesTilesOutsideTheSelection() async throws {
        try writeTile(z: 7, x: 0, y: 0)
        XCTAssertTrue(tileExists(z: 7, x: 0, y: 0), "precondition: the stray tile is on disk")

        let manager = OpenAIPCacheManager()
        let deleted = await manager.pruneTilesOutside(countries: ["CH"])

        XCTAssertEqual(deleted, 1)
        XCTAssertFalse(tileExists(z: 7, x: 0, y: 0), "a tile outside the selection must be reclaimed")
    }

    /// An empty selection also occurs transiently while the Settings list is being edited, so it
    /// must never be treated as "delete everything" — that is what `deleteCache()` is for.
    func testPruneRefusesToRunForAnEmptySelection() async throws {
        try writeTile(z: 7, x: 0, y: 0)

        let manager = OpenAIPCacheManager()
        let deleted = await manager.pruneTilesOutside(countries: [])

        XCTAssertEqual(deleted, 0, "an empty selection must not wipe the cache")
        XCTAssertTrue(tileExists(z: 7, x: 0, y: 0))
    }

    /// Tiles the current selection still wants must survive — the prune is a reconcile, not a purge.
    func testPruneKeepsTilesInsideTheSelection() async throws {
        let manager = OpenAIPCacheManager()
        // Ask the manager itself which tiles CH wants, so the test cannot drift from the projection.
        let wanted = await manager.tilesForCountriesForTesting(["CH"])
        let keep = try XCTUnwrap(wanted.first, "CH must project to at least one tile")
        try writeTile(z: keep.z, x: keep.x, y: keep.y)

        let deleted = await manager.pruneTilesOutside(countries: ["CH"])

        XCTAssertEqual(deleted, 0)
        XCTAssertTrue(tileExists(z: keep.z, x: keep.x, y: keep.y),
                      "a tile the current selection still covers must be kept")
    }
}
