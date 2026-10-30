import CoreLocation
import XCTest
@testable import AeroCheck

/// The pilot's map's downloads (6.8.0): what a download fetches, a route's regions, the install and its failures,
/// the monthly update's gate.
@MainActor
final class PilotMapDownloadTests: XCTestCase {

    private static func region(_ id: String, _ bounds: [Double], built: String = "20261025", relief: Bool = true,
                               reliefBuilt: String? = nil, mapBytes: Int = 0, reliefBytes: Int = 0) -> PilotMapRegion {
        PilotMapRegion(id: id, name: id.uppercased(), bounds: bounds, built: built, mapBytes: max(mapBytes, 1),
                       reliefBytes: relief ? max(reliefBytes, 1) : 0, reliefBuilt: reliefBuilt)
    }

    private static let chBounds = [5.64, 45.6, 10.78, 48.0]
    private static let frBounds = [4.0, 45.0, 8.3, 49.5]

    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func add(_ url: URL) { lock.withLock { urls.append(url) } }
        var all: [URL] { lock.withLock { urls } }
    }

    /// Archives the fake server hands out, by path.
    private func archives(_ tag: String) -> [String: Data] {
        let map = PMTilesFixture.archive([.init(z: 0, x: 0, y: 0, bytes: PMTilesFixture.content(0, 0, 0, tag))])
        let relief = PMTilesFixture.archive([.init(z: 0, x: 0, y: 0, bytes: Data("dem \(tag)".utf8))], gzipTiles: false)
        return ["map": map, "relief": relief]
    }

    private struct Rig {
        let downloads: PilotMapDownloads
        let requests: Requests
    }

    /// `root` shared by two rigs is one device across two months' indexes.
    private func rig(_ regions: [PilotMapRegion], files: [String: Data], status: Int = 200,
                     freeSpace: Int64? = nil, root: URL? = nil) async throws -> Rig {
        let root = root ?? makeTestDirectory()
        let index = try JSONSerialization.data(withJSONObject: [
            "version": 1, "regions": try regions.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) },
        ])
        let store = PilotMapIndexStore(directory: root.appendingPathComponent("index"), fetch: { request in
            (index, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
        })
        await store.refresh(maxAge: 0)
        let source = PilotTileSource(index: store, storage: PilotMapStorage(root: root.appendingPathComponent("regions")),
                                     allowance: PilotMapAllowance(defaults: makeTestDefaults()),
                                     cacheDirectory: root.appendingPathComponent("directories"), headers: { [:] },
                                     fetch: { _ in throw URLError(.notConnectedToInternet) })
        let requests = Requests()
        let temp = makeTestDirectory()
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let downloads = PilotMapDownloads(source: source, transfer: { request, progress in
            requests.add(request.url!)
            guard status == 200 else { throw PilotMapDownloads.Failure.http(status) }
            let kind = request.url!.deletingPathExtension().lastPathComponent
            let file = temp.appendingPathComponent(UUID().uuidString)
            try (files[kind] ?? Data()).write(to: file)
            progress(1)
            return file
        }, freeSpace: { freeSpace })
        return Rig(downloads: downloads, requests: requests)
    }

    // MARK: What a download fetches

    func testKindsToFetch() {
        let listed = Self.region("ch", Self.chBounds, built: "20261102", reliefBuilt: "20261025")
        XCTAssertEqual(PilotMapDownloads.kindsToFetch(listed: listed, installed: nil, filesPresent: []), [.map, .relief])
        let installed = Self.region("ch", Self.chBounds, built: "20261025")
        XCTAssertEqual(PilotMapDownloads.kindsToFetch(listed: listed, installed: installed, filesPresent: [.map, .relief]),
                       [.map], "a month that rebuilt the map only")
        XCTAssertEqual(PilotMapDownloads.kindsToFetch(listed: installed, installed: installed, filesPresent: [.map]),
                       [.relief], "a relief file gone missing")
        XCTAssertEqual(PilotMapDownloads.kindsToFetch(listed: installed, installed: installed, filesPresent: [.map, .relief]), [])
        let noRelief = Self.region("at", [9.5, 46.3, 17.2, 49.1], relief: false)
        XCTAssertEqual(PilotMapDownloads.kindsToFetch(listed: noRelief, installed: nil, filesPresent: []), [.map])
    }

    // MARK: A route's regions

    func testRouteRegionsTakeTheFirstAtABorder() {
        let ch = Self.region("ch", Self.chBounds), fr = Self.region("fr-est", Self.frBounds)
        // Bressaucourt to Grenchen: both boxes all the way; Switzerland comes first in the index.
        let jura = [CLLocationCoordinate2D(latitude: 47.392, longitude: 7.028),
                    CLLocationCoordinate2D(latitude: 47.182, longitude: 7.417)]
        XCTAssertEqual(PilotMapDownloads.regions(along: jura, in: [ch, fr]).map(\.id), ["ch"])
        XCTAssertEqual(PilotMapDownloads.regions(along: jura, in: [fr, ch]).map(\.id), ["fr-est"])
        // Grenchen to Dijon leaves Switzerland's box on the way.
        let dijon = [CLLocationCoordinate2D(latitude: 47.182, longitude: 7.417),
                     CLLocationCoordinate2D(latitude: 47.268, longitude: 5.090)]
        XCTAssertEqual(PilotMapDownloads.regions(along: dijon, in: [ch, fr]).map(\.id), ["ch", "fr-est"])
        // Nowhere listed: nothing to offer.
        let atlantic = [CLLocationCoordinate2D(latitude: 40, longitude: -30), CLLocationCoordinate2D(latitude: 41, longitude: -31)]
        XCTAssertEqual(PilotMapDownloads.regions(along: atlantic, in: [ch, fr]), [])
    }

    func testMissingRegionsLeaveOutTheDownloadedOnes() async throws {
        let files = archives("a")
        let ch = Self.region("ch", Self.chBounds, mapBytes: files["map"]!.count, reliefBytes: files["relief"]!.count)
        let rig = try await rig([ch, Self.region("fr-est", Self.frBounds)], files: files)
        let route = [CLLocationCoordinate2D(latitude: 47.182, longitude: 7.417),
                     CLLocationCoordinate2D(latitude: 47.268, longitude: 5.090)]
        XCTAssertEqual(rig.downloads.missingRegions(along: route).map(\.id), ["ch", "fr-est"])
        await rig.downloads.downloadNow(ch)
        XCTAssertEqual(rig.downloads.missingRegions(along: route).map(\.id), ["fr-est"])
        XCTAssertEqual(rig.downloads.missingRegions(along: [route[0]]), [], "one point is no route")
    }

    // MARK: Install

    func testDownloadInstallsBothArchives() async throws {
        let files = archives("first")
        let ch = Self.region("ch", Self.chBounds, mapBytes: files["map"]!.count, reliefBytes: files["relief"]!.count)
        let rig = try await rig([ch], files: files)
        XCTAssertEqual(rig.downloads.state(of: "ch"), .notDownloaded)
        let ok = await rig.downloads.downloadNow(ch)
        XCTAssertTrue(ok)
        XCTAssertEqual(rig.downloads.state(of: "ch"), .downloaded)
        XCTAssertEqual(rig.requests.all.map(\.lastPathComponent).sorted(), ["map.pmtiles", "relief.pmtiles"])
        XCTAssertEqual(rig.requests.all.first?.host, "tiles.aerocheck.app")
        let tile = await rig.downloads.source.tile(.map, z: 0, x: 0, y: 0)
        XCTAssertEqual(tile?.origin, .downloaded("ch"))
        XCTAssertNil(rig.downloads.progress["ch"])
    }

    func testUpdateFetchesTheMapAndKeepsTheRelief() async throws {
        let device = makeTestDirectory()
        let first = archives("first")
        let old = Self.region("ch", Self.chBounds, mapBytes: first["map"]!.count, reliefBytes: first["relief"]!.count)
        let october = try await rig([old], files: first, root: device)
        await october.downloads.downloadNow(old)

        // November's index: the map rebuilt, the relief as it was.
        let next = archives("november")
        let new = Self.region("ch", Self.chBounds, built: "20261102", reliefBuilt: "20261025",
                              mapBytes: next["map"]!.count, reliefBytes: first["relief"]!.count)
        let november = try await rig([new], files: next, root: device)
        XCTAssertEqual(november.downloads.state(of: "ch"), .updateAvailable)
        XCTAssertEqual(november.downloads.bytesToFetch(new), next["map"]!.count)
        let ok = await november.downloads.downloadNow(new)
        XCTAssertTrue(ok)
        XCTAssertEqual(november.requests.all.map(\.lastPathComponent), ["map.pmtiles"])
        XCTAssertEqual(november.downloads.state(of: "ch"), .downloaded)
        let storage = november.downloads.source.storage
        XCTAssertEqual(storage.archive(region: "ch", kind: .map)?.tile(z: 0, x: 0, y: 0).flatMap(PMTiles.plain),
                       PMTilesFixture.content(0, 0, 0, "november"))
        XCTAssertEqual(storage.archive(region: "ch", kind: .relief)?.tile(z: 0, x: 0, y: 0), Data("dem first".utf8),
                       "the relief kept through the update")
    }

    func testWrongSizeFailsAndInstallsNothing() async throws {
        let files = archives("a")
        let ch = Self.region("ch", Self.chBounds, mapBytes: files["map"]!.count + 1, reliefBytes: files["relief"]!.count)
        let rig = try await rig([ch], files: files)
        let ok = await rig.downloads.downloadNow(ch)
        XCTAssertFalse(ok)
        XCTAssertEqual(rig.downloads.state(of: "ch"), .failed)
        XCTAssertEqual(rig.downloads.downloaded, [])
    }

    func testRefusedRequestFails() async throws {
        let ch = Self.region("ch", Self.chBounds)
        let rig = try await rig([ch], files: [:], status: 403)
        let ok = await rig.downloads.downloadNow(ch)
        XCTAssertFalse(ok)
        XCTAssertEqual(rig.downloads.state(of: "ch"), .failed)
    }

    func testNotEnoughSpaceAsksNothing() async throws {
        let ch = Self.region("ch", Self.chBounds, mapBytes: 92_000_000, reliefBytes: 82_000_000)
        let rig = try await rig([ch], files: archives("a"), freeSpace: 150_000_000)
        let ok = await rig.downloads.downloadNow(ch)
        XCTAssertFalse(ok)
        XCTAssertEqual(rig.requests.all, [])
        XCTAssertEqual(rig.downloads.state(of: "ch"), .failed)
    }

    func testDeleteRemovesTheRegion() async throws {
        let files = archives("a")
        let ch = Self.region("ch", Self.chBounds, mapBytes: files["map"]!.count, reliefBytes: files["relief"]!.count)
        let rig = try await rig([ch], files: files)
        await rig.downloads.downloadNow(ch)
        rig.downloads.delete("ch")
        XCTAssertEqual(rig.downloads.state(of: "ch"), .notDownloaded)
        XCTAssertEqual(rig.downloads.bytesOnDisk, 0)
    }

    // MARK: The monthly update

    func testSilentDownloadsOnlyOnAnUnmeteredNetwork() {
        let wifi = NetworkConditions(isConnected: true, isWiFi: true, isExpensive: false, isConstrained: false)
        XCTAssertTrue(PilotMapDownloads.allowsSilentDownload(wifi))
        XCTAssertFalse(PilotMapDownloads.allowsSilentDownload(.init(isConnected: true, isWiFi: false, isExpensive: true, isConstrained: false)))
        XCTAssertFalse(PilotMapDownloads.allowsSilentDownload(.init(isConnected: true, isWiFi: true, isExpensive: false, isConstrained: true)))
        XCTAssertFalse(PilotMapDownloads.allowsSilentDownload(.disconnected))
    }

    func testNoUpdateInFlight() async throws {
        let files = archives("a")
        let ch = Self.region("ch", Self.chBounds, mapBytes: files["map"]!.count, reliefBytes: files["relief"]!.count)
        let rig = try await rig([ch], files: files)
        let wifi = NetworkConditions(isConnected: true, isWiFi: true, isExpensive: false, isConstrained: false)
        await rig.downloads.updateDownloaded(conditions: wifi, inFlight: true)
        await rig.downloads.updateDownloaded(conditions: wifi, inFlight: false)
        XCTAssertEqual(rig.requests.all, [], "nothing downloaded is nothing to update")
    }

    func testPlanFollowsTheEntitlement() async throws {
        let rig = try await rig([], files: [:])
        XCTAssertEqual(rig.downloads.allowanceLimit, PilotMapAllowance.freeReads)
        rig.downloads.setPro(true)
        XCTAssertEqual(rig.downloads.allowanceLimit, PilotMapAllowance.proReads)
    }
}
