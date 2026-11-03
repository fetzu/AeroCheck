import CoreLocation
import XCTest
@testable import AeroCheck

/// The pilot's map's downloads (6.8.0): what a download fetches, a route's regions, the install and its failures,
/// the update every three months, and the same tiles never fetched twice.
@MainActor
final class PilotMapDownloadTests: XCTestCase {

    private static func region(_ id: String, _ bounds: [Double], built: String = "20261025", relief: Bool = true,
                               reliefBuilt: String? = nil, mapBytes: Int = 0, reliefBytes: Int = 0,
                               mapHash: String? = nil) -> PilotMapRegion {
        PilotMapRegion(id: id, name: id.uppercased(), bounds: bounds, built: built, mapBytes: max(mapBytes, 1),
                       reliefBytes: relief ? max(reliefBytes, 1) : 0, reliefBuilt: reliefBuilt, mapHash: mapHash)
    }

    private static let chBounds = [5.64, 45.6, 10.78, 48.0]
    private static let frBounds = [4.0, 45.0, 8.3, 49.5]

    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        func add(_ request: URLRequest) { lock.withLock { requests.append(request) } }
        var all: [URL] { lock.withLock { requests.compactMap(\.url) } }
        var ifNoneMatch: [String?] { lock.withLock { requests.map { $0.value(forHTTPHeaderField: "If-None-Match") } } }
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

    /// `root` shared by two rigs is one device across two months' indexes. `etags`: the ETag the server gives each
    /// kind's file; a request whose If-None-Match matches it gets a 304.
    private func rig(_ regions: [PilotMapRegion], files: [String: Data], status: Int = 200, etags: [String: String] = [:],
                     freeSpace: Int64? = nil, root: URL? = nil,
                     links: @escaping PilotMapDownloads.Links = { _ in .unavailable }) async throws -> Rig {
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
            requests.add(request)
            guard status == 200 else { throw PilotMapDownloads.Failure.http(status) }
            // map.pmtiles, or a named file: map-<hash>.pmtiles
            let kind = String(request.url!.deletingPathExtension().lastPathComponent.split(separator: "-")[0])
            if let etag = etags[kind], request.value(forHTTPHeaderField: "If-None-Match") == etag { return .unchanged }
            let file = temp.appendingPathComponent(UUID().uuidString)
            try (files[kind] ?? Data()).write(to: file)
            progress(1)
            return .file(file, etag: etags[kind])
        }, links: links, freeSpace: { freeSpace })
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

    func testTheSameTilesUnderAnotherDateNeedNothing() {
        let installed = Self.region("ch", Self.chBounds, built: "20261025", reliefBuilt: "20261025", mapHash: "a1")
        let rerun = Self.region("ch", Self.chBounds, built: "20261102", reliefBuilt: "20261025", mapHash: "a1")
        XCTAssertEqual(PilotMapDownloads.kindsToFetch(listed: rerun, installed: installed, filesPresent: [.map, .relief]), [])
        let changed = Self.region("ch", Self.chBounds, built: "20261102", reliefBuilt: "20261025", mapHash: "b2")
        XCTAssertEqual(PilotMapDownloads.kindsToFetch(listed: changed, installed: installed, filesPresent: [.map, .relief]), [.map])
        let older = Self.region("ch", Self.chBounds, built: "20261025", reliefBuilt: "20261025")
        XCTAssertEqual(PilotMapDownloads.kindsToFetch(listed: rerun, installed: older, filesPresent: [.map, .relief]), [.map],
                       "a copy from before the hashes goes by its date")
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

    /// The allowance line offers the region under the chart, until it is on the device. (6.8.0)
    func testTheRegionUnderTheChartUntilItIsDownloaded() async throws {
        let files = archives("a")
        let ch = Self.region("ch", Self.chBounds, mapBytes: files["map"]!.count, reliefBytes: files["relief"]!.count)
        let rig = try await rig([ch, Self.region("fr-est", Self.frBounds)], files: files)
        let bern = CLLocationCoordinate2D(latitude: 46.95, longitude: 7.44)
        XCTAssertEqual(rig.downloads.missingRegion(at: bern)?.id, "ch")
        await rig.downloads.downloadNow(ch)
        XCTAssertNil(rig.downloads.missingRegion(at: bern), "downloaded: nothing to offer")
        XCTAssertNil(rig.downloads.missingRegion(at: CLLocationCoordinate2D(latitude: 40, longitude: -30)), "no region there")
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

    // MARK: The Atlas gate's links

    func testADownloadUsesTheGatesLinksWithoutTheClientValue() async throws {
        let files = archives("first")
        let ch = Self.region("ch", Self.chBounds, mapBytes: files["map"]!.count, reliefBytes: files["relief"]!.count)
        let asked = Requests()
        let rig = try await rig([ch], files: files, links: { names in
            for name in names { asked.add(URLRequest(url: URL(string: "https://names.invalid/\(name)")!)) }
            return .links(Dictionary(uniqueKeysWithValues: names.map { name in
                (name, URL(string: "https://acct.r2.cloudflarestorage.com/aerocheck-maps/v1/\(name)?X-Amz-Signature=x")!)
            }))
        })
        let ok = await rig.downloads.downloadNow(ch)
        XCTAssertTrue(ok)
        XCTAssertEqual(asked.all.map(\.path), ["/ch/map.pmtiles", "/ch/relief.pmtiles"])
        XCTAssertEqual(Set(rig.requests.all.map(\.host)), ["acct.r2.cloudflarestorage.com"])
        XCTAssertEqual(rig.downloads.state(of: "ch"), .downloaded)
        XCTAssertNil(rig.downloads.ceiling)
    }

    func testTheCeilingStopsADownloadAndSaysWhy() async throws {
        let ch = Self.region("ch", Self.chBounds)
        let reset = Date(timeIntervalSince1970: 1_793_491_200) // 1 Nov 2026
        let rig = try await rig([ch], files: [:], links: { _ in .ceiling(limit: 40, resetsAt: reset) })
        let ok = await rig.downloads.downloadNow(ch)
        XCTAssertFalse(ok)
        XCTAssertEqual(rig.downloads.state(of: "ch"), .failed)
        XCTAssertEqual(rig.requests.all, [], "nothing asked of the storage")
        XCTAssertEqual(rig.downloads.ceiling, PilotMapDownloads.Ceiling(limit: 40, resetsAt: reset))
        XCTAssertNotNil(rig.downloads.ceilingMessage)
    }

    func testWithoutTheGateTheFilesComeFromTheTilesHostAsBefore() async throws {
        let files = archives("first")
        let ch = Self.region("ch", Self.chBounds, mapBytes: files["map"]!.count, reliefBytes: files["relief"]!.count)
        let rig = try await rig([ch], files: files)
        let ok = await rig.downloads.downloadNow(ch)
        XCTAssertTrue(ok)
        XCTAssertEqual(Set(rig.requests.all.map(\.host)), ["tiles.aerocheck.app"])
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

    func testAFileTheServerStillHasIsNotDownloadedAgain() async throws {
        let device = makeTestDirectory()
        let first = archives("first")
        let tags = ["map": "\"m-first\"", "relief": "\"r-first\""]
        let old = Self.region("ch", Self.chBounds, mapBytes: first["map"]!.count, reliefBytes: first["relief"]!.count)
        let october = try await rig([old], files: first, etags: tags, root: device)
        await october.downloads.downloadNow(old)
        XCTAssertEqual(october.requests.ifNoneMatch, [nil, nil], "a first download has nothing to compare")

        // An index with a new date, the file on R2 the same: R2 answers 304 and nothing is fetched.
        let new = Self.region("ch", Self.chBounds, built: "20261102", reliefBuilt: "20261025",
                              mapBytes: first["map"]!.count, reliefBytes: first["relief"]!.count)
        let november = try await rig([new], files: [:], etags: tags, root: device)
        XCTAssertEqual(november.downloads.state(of: "ch"), .updateAvailable)
        let ok = await november.downloads.downloadNow(new)
        XCTAssertTrue(ok)
        XCTAssertEqual(november.requests.ifNoneMatch, ["\"m-first\""])
        XCTAssertEqual(november.downloads.state(of: "ch"), .downloaded, "the entry follows the index")
        let storage = november.downloads.source.storage
        XCTAssertEqual(storage.archive(region: "ch", kind: .map)?.tile(z: 0, x: 0, y: 0).flatMap(PMTiles.plain),
                       PMTilesFixture.content(0, 0, 0, "first"))
        XCTAssertEqual(storage.etag(region: "ch", kind: .map), "\"m-first\"", "the ETag kept with the file")
    }

    func testANamedFileIsDownloadedUnderItsName() async throws {
        let files = archives("named")
        let ch = PilotMapRegion(id: "ch", name: "CH", bounds: Self.chBounds, built: "20261026",
                                mapBytes: files["map"]!.count, reliefBytes: files["relief"]!.count,
                                mapFile: "map-1da3495153e271df.pmtiles", reliefFile: "relief-5b67c770f8c31da5.pmtiles")
        let rig = try await rig([ch], files: files)
        let ok = await rig.downloads.downloadNow(ch)
        XCTAssertTrue(ok)
        XCTAssertEqual(rig.requests.all.map(\.path).sorted(),
                       ["/v1/ch/map-1da3495153e271df.pmtiles", "/v1/ch/relief-5b67c770f8c31da5.pmtiles"])
    }

    // MARK: The update every three months

    func testTheUpdateIsDueWhenTheCopyIsThreeMonthsOld() throws {
        let installed = Self.region("ch", Self.chBounds, built: "20261025", reliefBuilt: "20261025")
        let listed = Self.region("ch", Self.chBounds, built: "20261102", reliefBuilt: "20261025")
        let utc = { (text: String) -> Date in
            let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; return f.date(from: text)!
        }
        let both: Set<PilotMapKind> = [.map, .relief]
        XCTAssertFalse(PilotMapDownloads.autoUpdateDue(listed: listed, installed: installed, filesPresent: both, now: utc("2026-12-15")))
        XCTAssertFalse(PilotMapDownloads.autoUpdateDue(listed: listed, installed: installed, filesPresent: both, now: utc("2027-01-24")))
        XCTAssertTrue(PilotMapDownloads.autoUpdateDue(listed: listed, installed: installed, filesPresent: both, now: utc("2027-01-25")))
        XCTAssertTrue(PilotMapDownloads.autoUpdateDue(listed: installed, installed: installed, filesPresent: [.map], now: utc("2026-10-26")),
                      "a missing file is due at once")
        XCTAssertFalse(PilotMapDownloads.autoUpdateDue(listed: installed, installed: installed, filesPresent: both, now: utc("2028-01-01")),
                       "nothing new is never due")
    }

    func testTheForegroundUpdateWaitsForThreeMonths() async throws {
        let device = makeTestDirectory()
        let first = archives("first")
        let old = Self.region("ch", Self.chBounds, mapBytes: first["map"]!.count, reliefBytes: first["relief"]!.count)
        let october = try await rig([old], files: first, root: device)
        await october.downloads.downloadNow(old)
        let next = archives("november")
        let new = Self.region("ch", Self.chBounds, built: "20261102", reliefBuilt: "20261025",
                              mapBytes: next["map"]!.count, reliefBytes: first["relief"]!.count)
        let later = try await rig([new], files: next, root: device)
        let wifi = NetworkConditions(isConnected: true, isWiFi: true, isExpensive: false, isConstrained: false)
        await later.downloads.updateDownloaded(conditions: wifi, inFlight: false, now: Date(timeIntervalSince1970: 1_796_000_000))
        XCTAssertEqual(later.requests.all, [], "30 November: the copy is a month old")
        await later.downloads.updateDownloaded(conditions: wifi, inFlight: false, now: Date(timeIntervalSince1970: 1_801_000_000))
        XCTAssertEqual(later.requests.all.map(\.lastPathComponent), ["map.pmtiles"], "26 January: three months on")
    }

    // MARK: Unmetered networks, never in flight

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
