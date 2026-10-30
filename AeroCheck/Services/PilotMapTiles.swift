import Foundation
import MapLibre

/// The pilot's map regions downloaded on this device: `<root>/<region>/map.pmtiles`, `relief.pmtiles` and
/// `region.json` (the index entry they were downloaded from). Kept out of device backups: they come back from
/// tiles.aerocheck.app. (6.8.0)
final class PilotMapStorage: @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var regions: [PilotMapRegion] = []
    private var archives: [String: PMTilesArchive] = [:]

    init(root: URL) {
        self.root = root
        reload()
    }

    /// The downloaded regions, oldest download first.
    var downloaded: [PilotMapRegion] { lock.withLock { regions } }

    func isDownloaded(_ id: String) -> Bool { downloaded.contains { $0.id == id } }

    func directory(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    func fileURL(region id: String, kind: PilotMapKind) -> URL {
        directory(for: id).appendingPathComponent("\(kind.rawValue).pmtiles")
    }

    /// The region's archive of that kind, opened once.
    func archive(region id: String, kind: PilotMapKind) -> PMTilesArchive? {
        let key = "\(id)/\(kind.rawValue)"
        return lock.withLock {
            if let open = archives[key] { return open }
            guard regions.contains(where: { $0.id == id }),
                  let opened = try? PMTilesArchive(url: fileURL(region: id, kind: kind)) else { return nil }
            archives[key] = opened
            return opened
        }
    }

    /// Moves downloaded archives into place (replacing an older download of the region) and records the entry.
    /// Each file must open as a PMTiles archive. A kind not given keeps the file already there (a month that
    /// rebuilt the map only updates the map).
    func install(_ region: PilotMapRegion, files: [PilotMapKind: URL]) throws {
        for (_, file) in files { _ = try PMTilesArchive(url: file) }
        let fm = FileManager.default
        let staging = root.appendingPathComponent(".staging-\(region.id)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for kind in PilotMapKind.allCases {
            let staged = staging.appendingPathComponent("\(kind.rawValue).pmtiles")
            if let file = files[kind] {
                try fm.moveItem(at: file, to: staged)
            } else if fm.fileExists(atPath: fileURL(region: region.id, kind: kind).path) {
                // A hard link: the old file stays whole until the swap below.
                try fm.linkItem(at: fileURL(region: region.id, kind: kind), to: staged)
            }
        }
        try JSONEncoder().encode(region).write(to: staging.appendingPathComponent("region.json"))
        lock.withLock {
            archives = archives.filter { !$0.key.hasPrefix("\(region.id)/") }
        }
        let target = directory(for: region.id)
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: target)
        }
        excludeFromBackup(root)
        reload()
    }

    func remove(_ id: String) {
        lock.withLock {
            archives = archives.filter { !$0.key.hasPrefix("\(id)/") }
        }
        try? FileManager.default.removeItem(at: directory(for: id))
        reload()
    }

    /// Bytes on disk, every region.
    var bytesOnDisk: Int64 {
        let fm = FileManager.default
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    func reload() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let found: [(PilotMapRegion, Date)] = folders.compactMap { folder in
            guard !folder.lastPathComponent.hasPrefix("."),
                  let data = try? Data(contentsOf: folder.appendingPathComponent("region.json")),
                  let region = try? JSONDecoder().decode(PilotMapRegion.self, from: data),
                  region.isValid, region.id == folder.lastPathComponent,
                  fm.fileExists(atPath: folder.appendingPathComponent("\(PilotMapKind.map.rawValue).pmtiles").path)
            else { return nil }
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return (region, created)
        }
        lock.withLock { regions = found.sorted { $0.1 < $1.1 }.map(\.0) }
    }

    private func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }
}

/// Where each of MapLibre's tiles comes from (the plan's "one tile address for everything"): (6.8.0)
/// 1. a downloaded region's archive when one has the tile (regions overlap at borders: the first in the index wins);
/// 2. else, online, a range read of that region's archive on tiles.aerocheck.app, counted against the allowance;
/// 3. else (no region there, the allowance used up, offline) nothing, and MapLibre draws what it has.
final class PilotTileSource: @unchecked Sendable {
    enum Origin: Equatable, Sendable {
        case downloaded(String)
        case online(String)
    }

    struct Tile: Sendable {
        /// Plain bytes, as MapLibre wants them: the map's tiles un-gzipped.
        let data: Data
        let origin: Origin
    }

    let index: PilotMapIndexStore
    let storage: PilotMapStorage
    let allowance: PilotMapAllowance
    /// The remote archives' directories, one folder per region, kind and build.
    let cacheDirectory: URL
    private let fetch: PMTilesRemoteArchive.Fetch
    private let headers: () -> [String: String]
    private let isOnline: @Sendable () -> Bool
    private let lock = NSLock()
    private var remotes: [String: PMTilesRemoteArchive] = [:]

    init(index: PilotMapIndexStore, storage: PilotMapStorage, allowance: PilotMapAllowance, cacheDirectory: URL,
         headers: @escaping () -> [String: String] = { PilotMapConfig.requestHeaders },
         fetch: @escaping PMTilesRemoteArchive.Fetch = PilotMapConfig.fetch,
         isOnline: @escaping @Sendable () -> Bool = { true }) {
        self.index = index
        self.storage = storage
        self.allowance = allowance
        self.cacheDirectory = cacheDirectory
        self.headers = headers
        self.fetch = fetch
        self.isOnline = isOnline
    }

    /// The regions that may hold the tile, in the order they are asked: the index's, then a downloaded region the
    /// index no longer lists.
    func candidates(z: Int, x: Int, y: Int) -> [PilotMapRegion] {
        let listed = index.regions
        let ids = Set(listed.map(\.id))
        let orphans = storage.downloaded.filter { !ids.contains($0.id) }
        return (listed + orphans).filter { $0.touches(z: z, x: x, y: y) }
    }

    func tile(_ kind: PilotMapKind, z: Int, x: Int, y: Int) async -> Tile? {
        guard PilotMapTileMath.isValid(z: z, x: x, y: y) else { return nil }
        let regions = candidates(z: z, x: x, y: y).filter { $0.has(kind) }
        let downloaded = Set(storage.downloaded.map(\.id))

        for region in regions where downloaded.contains(region.id) {
            if let stored = storage.archive(region: region.id, kind: kind)?.tile(z: z, x: x, y: y),
               let plain = PMTiles.plain(stored) {
                return Tile(data: plain, origin: .downloaded(region.id))
            }
        }

        guard isOnline() else { return nil }
        for region in regions where !downloaded.contains(region.id) {
            if Task.isCancelled { return nil }
            let remote = remoteArchive(region, kind)
            guard let location = try? await remote.locate(z: z, x: x, y: y) else { continue }
            guard allowance.reserve() else { return nil }
            do {
                let stored = try await remote.read(location)
                guard let plain = PMTiles.plain(stored) else { return nil }
                return Tile(data: plain, origin: .online(region.id))
            } catch {
                allowance.refund()
                return nil
            }
        }
        return nil
    }

    private func remoteArchive(_ region: PilotMapRegion, _ kind: PilotMapKind) -> PMTilesRemoteArchive {
        let key = "\(region.id)-\(kind.rawValue)-\(region.build(of: kind))"
        return lock.withLock {
            if let open = remotes[key] { return open }
            let remote = PMTilesRemoteArchive(url: PilotMapConfig.archiveURL(region: region.id, kind: kind),
                                              cacheDirectory: cacheDirectory.appendingPathComponent(key, isDirectory: true),
                                              headers: headers(), fetch: fetch)
            remotes[key] = remote
            return remote
        }
    }

    /// Removes the cached directories of builds the index no longer lists.
    func pruneDirectoryCache() {
        let live = Set(index.regions.flatMap { region in
            PilotMapKind.allCases.map { "\(region.id)-\($0.rawValue)-\(region.build(of: $0))" }
        })
        let folders = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !live.contains(folder.lastPathComponent) {
            try? FileManager.default.removeItem(at: folder)
        }
        lock.withLock { remotes = remotes.filter { live.contains($0.key) } }
    }
}

/// Answers MapLibre's requests for https://tiles.aerocheck.app/v1/{map,relief}/{z}/{x}/{y} and
/// /v1/glyphs/{fontstack}/{range}.pbf, registered on MapLibre's own session only (`registerWithMapLibre`): the tiles
/// from `PilotTileSource`, the glyphs from the app's bundle. Anything else on that host, and a tile nobody has,
/// gets a 404. (6.8.0)
final class PilotTileURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installedSource: PilotTileSource?
    nonisolated(unsafe) private static var installedGlyphs: URL? = Bundle.main.url(forResource: "PilotMapGlyphs", withExtension: nil)

    static var source: PilotTileSource? {
        get { lock.withLock { installedSource } }
        set { lock.withLock { installedSource = newValue } }
    }

    /// The B612 glyph ranges (AeroCheck-maps' `glyphs/`, OFL): `<folder>/<font>/<start>-<end>.pbf`.
    static var glyphsDirectory: URL? {
        get { lock.withLock { installedGlyphs } }
        set { lock.withLock { installedGlyphs = newValue } }
    }

    /// Before the first map view: MapLibre takes its session configuration once.
    static func registerWithMapLibre(source: PilotTileSource) {
        self.source = source
        let config = MLNNetworkConfiguration.sharedManager.sessionConfiguration ?? URLSessionConfiguration.default
        if !(config.protocolClasses ?? []).contains(where: { $0 == PilotTileURLProtocol.self }) {
            config.protocolClasses = [PilotTileURLProtocol.self] + (config.protocolClasses ?? [])
        }
        MLNNetworkConfiguration.sharedManager.sessionConfiguration = config
    }

    /// What a request asks for.
    enum Request: Equatable {
        case tile(PilotMapKind, z: Int, x: Int, y: Int)
        case glyphs(fonts: [String], range: String)
        /// A swisstopo chart's tile, answered here (`PilotMapCharts`).
        case chart(layer: String, z: Int, x: Int, y: Int, offline: Bool)
        /// An OpenAIP tile, answered here.
        case openAIP(z: Int, x: Int, y: Int, offline: Bool)
        case unknown
    }

    static func parse(_ url: URL?) -> Request {
        guard let url, url.host == PilotMapConfig.host else { return .unknown }
        let parts = url.pathComponents   // ["/", "v1", "map", z, x, y]
        if parts.count >= 2, parts[1] == PilotMapCharts.localPrefix { return parseLocal(url, parts) }
        guard parts.count >= 3, parts[1] == "v1" else { return .unknown }
        if parts.count == 6, let kind = PilotMapKind(rawValue: parts[2]),
           let z = Int(parts[3]), let x = Int(parts[4]), let y = Int(parts[5]) {
            return .tile(kind, z: z, x: x, y: y)
        }
        if parts.count == 5, parts[2] == "glyphs" {
            let fonts = parts[3].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let fontOK = { (font: String) in
                !font.isEmpty && font.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" }
            }
            let range = parts[4]
            let rangeOK = range.hasSuffix(".pbf") && range.dropLast(4).split(separator: "-").count == 2
                && range.dropLast(4).allSatisfy { $0.isNumber || $0 == "-" }
            guard !fonts.isEmpty, fonts.allSatisfy(fontOK), rangeOK else { return .unknown }
            return .glyphs(fonts: fonts, range: range)
        }
        return .unknown
    }

    /// /local/chart/<layer>/z/x/y and /local/openaip/z/x/y, `offline=1` for the downloaded tiles only.
    private static func parseLocal(_ url: URL, _ parts: [String]) -> Request {
        let offline = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "offline" }?.value == "1"
        func zxy(_ from: Int) -> (Int, Int, Int)? {
            guard parts.count == from + 3, let z = Int(parts[from]), let x = Int(parts[from + 1]), let y = Int(parts[from + 2]),
                  PilotMapTileMath.isValid(z: z, x: x, y: y) else { return nil }
            return (z, x, y)
        }
        if parts.count == 7, parts[2] == "chart", PilotMapCharts.swisstopoLayers[parts[3]] != nil, let (z, x, y) = zxy(4) {
            return .chart(layer: parts[3], z: z, x: x, y: y, offline: offline)
        }
        if parts.count == 6, parts[2] == "openaip", let (z, x, y) = zxy(3) {
            return .openAIP(z: z, x: x, y: y, offline: offline)
        }
        return .unknown
    }

    /// The answer's body and type; nil for a 404.
    static func answer(_ request: Request) async -> (Data, String)? {
        switch request {
        case let .tile(kind, z, x, y):
            guard let tile = await source?.tile(kind, z: z, x: x, y: y) else { return nil }
            return (tile.data, kind == .map ? "application/x-protobuf" : "image/webp")
        case let .glyphs(fonts, range):
            guard let folder = glyphsDirectory else { return nil }
            for font in fonts {
                if let data = try? Data(contentsOf: folder.appendingPathComponent(font).appendingPathComponent(range)) {
                    return (data, "application/x-protobuf")
                }
            }
            return nil
        case let .chart(layer, z, x, y, offline):
            guard let spec = PilotMapCharts.chartSpec(layer: layer, z: z, x: x, y: y, offline: offline),
                  let data = await PilotMapCharts.bytes(for: spec) else { return nil }
            return (data, PilotMapCharts.swisstopoLayers[layer] == "jpeg" ? "image/jpeg" : "image/png")
        case let .openAIP(z, x, y, offline):
            guard let spec = PilotMapCharts.openAIPSpec(z: z, x: x, y: y, offline: offline),
                  let data = await PilotMapCharts.bytes(for: spec) else { return nil }
            return (data, "image/png")
        case .unknown:
            return nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == PilotMapConfig.host && request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var loading: Task<Void, Never>?
    private var clientThread: Thread?
    private var modes: [String] = [RunLoop.Mode.default.rawValue]
    private var stopped = false

    override func startLoading() {
        clientThread = Thread.current
        if let mode = RunLoop.current.currentMode, mode != .default { modes = [mode.rawValue, RunLoop.Mode.default.rawValue] }
        let asked = Self.parse(request.url)
        loading = Task { [weak self] in
            let answer = await Self.answer(asked)
            self?.deliver(answer)
        }
    }

    override func stopLoading() {
        stopped = true
        loading?.cancel()
    }

    private final class Answer: NSObject {
        let body: (Data, String)?
        init(_ body: (Data, String)?) { self.body = body }
    }

    /// The client is called on the thread that started the load, as URLProtocol asks.
    private func deliver(_ body: (Data, String)?) {
        guard let thread = clientThread else { return }
        perform(#selector(finish(_:)), on: thread, with: Answer(body), waitUntilDone: false, modes: modes)
    }

    @objc private func finish(_ answer: Answer) {
        guard !stopped, let url = request.url else { return }
        let headers: [String: String]
        if let (_, type) = answer.body {
            // A month in MapLibre's cache: a tile read online is never read (or counted) twice.
            headers = ["Content-Type": type, "Cache-Control": "max-age=2592000"]
        } else {
            // Not kept: a tile missing now (offline, the allowance used up) may come with a download.
            headers = ["Cache-Control": "no-store"]
        }
        let response = HTTPURLResponse(url: url, statusCode: answer.body == nil ? 404 : 200, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let (data, _) = answer.body { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// The app's own pilot's map: the index and downloads in Application Support, the remote directories in Caches,
/// the allowance in the standard defaults. Tests build their own. (6.8.0)
enum PilotMap {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var online = true

    /// Off in the app's strict offline mode: no tile is read from tiles.aerocheck.app, the downloaded regions only.
    static var onlineAllowed: Bool {
        get { lock.withLock { online } }
        set { lock.withLock { online = newValue } }
    }

    static let shared: PilotTileSource = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let root = support.appendingPathComponent("PilotMap", isDirectory: true)
        return PilotTileSource(index: PilotMapIndexStore(directory: root),
                               storage: PilotMapStorage(root: root.appendingPathComponent("Regions", isDirectory: true)),
                               allowance: PilotMapAllowance(defaults: .standard),
                               cacheDirectory: caches.appendingPathComponent("PilotMap/Directories", isDirectory: true),
                               isOnline: { PilotMap.onlineAllowed })
    }()
}
