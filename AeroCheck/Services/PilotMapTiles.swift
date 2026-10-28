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

    /// The ETag R2 gave a downloaded archive, sent back as If-None-Match: an unchanged file isn't sent again.
    func etag(region id: String, kind: PilotMapKind) -> String? {
        etags(in: directory(for: id))[kind.rawValue]
    }

    private func etags(in folder: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("etags.json")) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// Moves downloaded archives into place (replacing an older download of the region) and records the entry.
    /// Each file must open as a PMTiles archive. A kind not given keeps the file already there, and its ETag (a
    /// month that rebuilt the map only updates the map; a file R2 answered "not modified" for stays).
    func install(_ region: PilotMapRegion, files: [PilotMapKind: URL], etags new: [PilotMapKind: String] = [:]) throws {
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
        var tags = etags(in: directory(for: region.id)).filter { key, _ in
            PilotMapKind(rawValue: key).map { files[$0] == nil } ?? false
        }
        for (kind, tag) in new where files[kind] != nil { tags[kind.rawValue] = tag }
        try JSONEncoder().encode(tags).write(to: staging.appendingPathComponent("etags.json"))
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
/// 1. every downloaded region that has the tile (each is cut at its own outline: at a border, or at a low zoom, several
///    hold a part of it), joined into one tile;
/// 2. online, the regions not downloaded, by range reads of their archives on tiles.aerocheck.app, counted against the
///    allowance, joined to the rest; up to zoom 7 the overview instead, which holds every region in one archive;
/// 3. else (no region there, the allowance used up, offline) what the downloaded regions have, or nothing. That tile
///    may be half a border's: it is drawn but never kept, so the other half comes once the device is back online.
final class PilotTileSource: @unchecked Sendable {
    indirect enum Origin: Equatable, Sendable {
        case downloaded(String)
        case online(String)
        /// Several regions' parts joined into one tile.
        case merged([Origin])
    }

    struct Tile: Sendable {
        /// Plain bytes, as MapLibre wants them: the map's tiles un-gzipped.
        let data: Data
        let origin: Origin
        /// False when a region that holds part of the tile couldn't be asked (offline, the allowance used up, a read
        /// that failed): what's there is drawn, but MapLibre mustn't keep it for a month.
        var whole = true
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

    /// A tile, nothing there, or nothing now: offline, the allowance used up, a read that failed. MapLibre keeps a
    /// "nothing there" and retries a "nothing now", so the two must not be confused: a tile missing in flight would
    /// otherwise stay missing after the region's download.
    enum Lookup {
        case tile(Tile)
        case none
        case unavailable
    }

    func tile(_ kind: PilotMapKind, z: Int, x: Int, y: Int) async -> Tile? {
        if case let .tile(tile) = await lookup(kind, z: z, x: x, y: y) { return tile }
        return nil
    }

    /// Up to this tile zoom, online, the overview alone answers: a tile there spans many regions, and one archive is
    /// one read where the regions would be dozens. (6.8.0, the worldwide regions)
    static let overviewMaxZoom = 7

    func lookup(_ kind: PilotMapKind, z: Int, x: Int, y: Int) async -> Lookup {
        guard PilotMapTileMath.isValid(z: z, x: x, y: y) else { return .none }
        let regions = candidates(z: z, x: x, y: y).filter { $0.has(kind) }
        let downloaded = Set(storage.downloaded.map(\.id))

        // Every downloaded region's part: each is cut at its own outline, so at a border, or at a low zoom, a tile
        // holds a part in each.
        var parts: [(data: Data, origin: Origin)] = []
        for region in regions where downloaded.contains(region.id) {
            if let stored = storage.archive(region: region.id, kind: kind)?.tile(z: z, x: x, y: y),
               let plain = PMTiles.plain(stored) {
                parts.append((plain, .downloaded(region.id)))
            }
        }

        // Online: the overview at low zooms (it holds every region, downloaded or not), else each region not
        // downloaded. Offline or out of allowance, the downloaded parts are all there is.
        let overview = z <= Self.overviewMaxZoom ? index.overview.flatMap { $0.has(kind) ? $0 : nil } : nil
        let online = overview.map { [$0] } ?? regions.filter { !downloaded.contains($0.id) }
        guard !online.isEmpty, isOnline() else {
            return merged(parts, kind, whole: online.isEmpty) ?? (online.isEmpty ? .none : .unavailable)
        }
        var fetched: [(data: Data, origin: Origin)] = []
        var failed = false
        for region in online {
            if Task.isCancelled { return .unavailable }
            let remote = remoteArchive(region, kind)
            let location: PMTilesRemoteArchive.Location?
            do { location = try await remote.locate(z: z, x: x, y: y) } catch { failed = true; continue }
            guard let location else { continue }
            guard allowance.reserve() else { return merged(parts, kind, whole: false) ?? .unavailable }
            do {
                let stored = try await remote.read(location)
                if let plain = PMTiles.plain(stored) { fetched.append((plain, .online(region.id))) }
            } catch {
                allowance.refund()
                return merged(parts, kind, whole: false) ?? .unavailable
            }
        }
        // The overview answered: it holds the downloaded regions too.
        if overview != nil, !fetched.isEmpty { return merged(fetched, kind) ?? .none }
        // A region that couldn't be asked: what the others have, or "nothing now" so MapLibre asks again.
        return merged(parts + fetched, kind, whole: !failed) ?? (failed ? .unavailable : .none)
    }

    /// One tile from the parts found: the only one as it is, several joined (`PilotTileMerge`), none nil.
    private func merged(_ parts: [(data: Data, origin: Origin)], _ kind: PilotMapKind, whole: Bool = true) -> Lookup? {
        guard let first = parts.first else { return nil }
        guard parts.count > 1 else { return .tile(Tile(data: first.data, origin: first.origin, whole: whole)) }
        let data = kind == .map ? PilotTileMerge.vector(parts.map(\.data)) : PilotTileMerge.relief(parts.map(\.data))
        return .tile(Tile(data: data ?? first.data, origin: .merged(parts.map(\.origin)), whole: whole))
    }

    private func remoteArchive(_ region: PilotMapRegion, _ kind: PilotMapKind) -> PMTilesRemoteArchive {
        let key = Self.remoteKey(region, kind)
        return lock.withLock {
            if let open = remotes[key] { return open }
            let remote = PMTilesRemoteArchive(url: PilotMapConfig.archiveURL(region: region, kind: kind),
                                              cacheDirectory: cacheDirectory.appendingPathComponent(key, isDirectory: true),
                                              headers: headers(), fetch: fetch)
            remotes[key] = remote
            return remote
        }
    }

    /// A remote archive's directories are cached per file and build: "ch-map-20261025", "ch-map-1da3…-20261102".
    private static func remoteKey(_ region: PilotMapRegion, _ kind: PilotMapKind) -> String {
        "\(region.id)-\(region.file(of: kind).dropLast(8))-\(region.build(of: kind))"
    }

    /// Removes the cached directories of builds the index no longer lists.
    func pruneDirectoryCache() {
        let live = Set(index.regions.flatMap { region in PilotMapKind.allCases.map { Self.remoteKey(region, $0) } })
        let folders = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !live.contains(folder.lastPathComponent) {
            try? FileManager.default.removeItem(at: folder)
        }
        lock.withLock { remotes = remotes.filter { live.contains($0.key) } }
    }
}

/// Answers MapLibre's requests for https://tiles.aerocheck.app/v1/{map,relief}/{z}/{x}/{y} and
/// /v1/glyphs/{fontstack}/{range}.pbf, registered on MapLibre's own session only (`registerWithMapLibre`): the tiles
/// from `PilotTileSource`, the glyphs and the world outline (/local/outline/{z}/{x}/{y}) from the app's bundle. Anything else on that host, and a tile nobody has,
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
        /// An aerial imagery tile, composed here from the sources in it (`ImageryTiles`).
        case imagery(z: Int, x: Int, y: Int)
        /// A tile of the world outline, from the bundle.
        case outline(z: Int, x: Int, y: Int)
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
        if parts.count == 6, parts[2] == "imagery", let (z, x, y) = zxy(3) {
            return .imagery(z: z, x: x, y: y)
        }
        if parts.count == 6, parts[2] == "outline", let (z, x, y) = zxy(3) {
            return .outline(z: z, x: x, y: y)
        }
        return .unknown
    }

    /// What a request gets: a body and its type, a 404 MapLibre keeps, or an error it retries.
    enum Answer {
        case body(Data, String)
        /// A body MapLibre draws but doesn't keep: half a border's tile, the other half to come once online.
        case passing(Data, String)
        case none
        case unavailable
    }

    static func answer(_ request: Request) async -> Answer {
        switch request {
        case let .tile(kind, z, x, y):
            guard let source else { return .none }
            switch await source.lookup(kind, z: z, x: x, y: y) {
            case let .tile(tile):
                let type = kind == .map ? "application/x-protobuf" : "image/webp"
                return tile.whole ? .body(tile.data, type) : .passing(tile.data, type)
            case .none: return .none
            case .unavailable: return .unavailable
            }
        case let .glyphs(fonts, range):
            guard let folder = glyphsDirectory else { return .none }
            for font in fonts {
                if let data = try? Data(contentsOf: folder.appendingPathComponent(font).appendingPathComponent(range)) {
                    return .body(data, "application/x-protobuf")
                }
            }
            return .none
        case let .chart(layer, z, x, y, offline):
            guard let spec = PilotMapCharts.chartSpec(layer: layer, z: z, x: x, y: y, offline: offline) else { return .none }
            return await PilotMapCharts.bytes(for: spec)
                .answer(type: PilotMapCharts.swisstopoLayers[layer] == "jpeg" ? "image/jpeg" : "image/png")
        case let .openAIP(z, x, y, offline):
            guard let spec = PilotMapCharts.openAIPSpec(z: z, x: x, y: y, offline: offline) else { return .none }
            return await PilotMapCharts.bytes(for: spec).answer(type: "image/png")
        case let .imagery(z, x, y):
            let tile = await ImageryTiles.tile(z: z, x: x, y: y, store: PilotMap.imagery, offline: !PilotMap.onlineAllowed)
            if case let .data(data) = tile { return .body(data, data.starts(with: [0xFF, 0xD8]) ? "image/jpeg" : "image/png") }
            return tile.answer(type: "image/png")
        case let .outline(z, x, y):
            // The outline stops at tile zoom 6; MapLibre draws it enlarged beyond and asks no further.
            guard let stored = PilotMap.outline?.tile(z: z, x: x, y: y), let plain = PMTiles.plain(stored) else { return .none }
            return .body(plain, "application/x-protobuf")
        case .unknown:
            return .none
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

    private final class Boxed: NSObject {
        let answer: Answer
        init(_ answer: Answer) { self.answer = answer }
    }

    /// The client is called on the thread that started the load, as URLProtocol asks.
    private func deliver(_ answer: Answer) {
        guard let thread = clientThread else { return }
        perform(#selector(finish(_:)), on: thread, with: Boxed(answer), waitUntilDone: false, modes: modes)
    }

    @objc private func finish(_ boxed: Boxed) {
        guard !stopped, let url = request.url else { return }
        let status: Int
        var headers: [String: String]
        var body: Data?
        switch boxed.answer {
        case let .body(data, type):
            // A month in MapLibre's cache: a tile read online is never read (or counted) twice.
            status = 200
            headers = ["Content-Type": type, "Cache-Control": "max-age=2592000"]
            body = data
        case let .passing(data, type):
            // Stale at once: MapLibre asks again the next time it needs the tile (it reads max-age, not no-store).
            status = 200
            headers = ["Content-Type": type, "Cache-Control": "no-store, max-age=0, must-revalidate"]
            body = data
        case .none:
            // Nothing there: MapLibre keeps it, and asks again only when its entry expires (a day).
            status = 404
            headers = ["Cache-Control": "max-age=86400"]
        case .unavailable:
            // Nothing now: a server error, which MapLibre retries later and never keeps.
            status = 503
            headers = ["Cache-Control": "no-store", "Retry-After": "30"]
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body { client?.urlProtocol(self, didLoad: body) }
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

    /// The world outline (AeroCheck-maps `build/outline.py`, decided 26 Oct 2026): land and sea, borders, country
    /// names, capitals, major rivers and lakes, to tile zoom 6. Bundled, so the map is never blank where no region is
    /// downloaded, offline or not.
    static let outline: PMTilesArchive? = Bundle.main.url(forResource: "outline", withExtension: "pmtiles",
                                                          subdirectory: "PilotMapOutline")
        .flatMap { try? PMTilesArchive(url: $0) }

    /// The aerial imagery's sources (`ImageryStore`), beside the index.
    static let imagery: ImageryStore = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return ImageryStore(directory: support.appendingPathComponent("PilotMap", isDirectory: true))
    }()

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
