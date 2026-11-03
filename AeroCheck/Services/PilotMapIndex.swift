import Foundation

/// The pilot's map: our own map, built monthly in the private AeroCheck-maps repository from OpenStreetMap (via the
/// Protomaps daily build) and Mapterhorn's relief, and served as PMTiles archives from R2 behind tiles.aerocheck.app.
/// Never through the API's Worker: the account's 100,000 Worker requests a day are shared, and past them every
/// Worker answers error 1027 until midnight UTC, subscription checks included. (6.8.0)
enum PilotMapConfig {
    static let host = "tiles.aerocheck.app"
    static let baseURL = URL(string: "https://\(host)/v1/")!
    static let indexURL = baseURL.appendingPathComponent("index.json")

    /// A list's address for this hour. Cloudflare keeps what tiles.aerocheck.app serves for a day, and the cache
    /// rule can't tell the lists from the archives: under its bare name, the index a monthly build replaces would
    /// still come back for up to a day, naming files the cleanup removes. A query string is a key of its own, so a
    /// new hour asks R2 again and every device in that hour shares the answer.
    static func listURL(_ url: URL, now: Date) -> URL {
        url.appending(queryItems: [URLQueryItem(name: "h", value: String(Int(now.timeIntervalSince1970 / 3600)))])
    }

    /// What MapLibre asks for, all answered by `PilotTileURLProtocol`: the map's vector tiles, the relief's
    /// elevation tiles and the B612 glyphs. The style names these.
    static let mapTileTemplate = "https://\(host)/v1/map/{z}/{x}/{y}?\(cacheGeneration)"
    static let reliefTileTemplate = "https://\(host)/v1/relief/{z}/{x}/{y}?\(cacheGeneration)"
    /// MapLibre keeps a tile under its address. A new query is a new address, so what an earlier build kept is never
    /// drawn again; the protocol reads only the path. g=2: the builds before 29 Oct 2026 kept half a border's tile for
    /// a month (Switzerland's half, from before the other regions). g=3: they kept "nothing there" for a day where a
    /// region's relief stops before the style's zoom 11 (every region but Switzerland's). g=4: MapLibre keeps no Atlas
    /// tile since 30 Oct 2026; the ones it kept before must not draw offline (question 9).
    static let cacheGeneration = "g=4"
    static let glyphsTemplate = "https://\(host)/v1/glyphs/{fontstack}/{range}.pbf"
    /// The world outline, from the app's bundle (`PilotMapOutline`).
    static let outlineTileTemplate = "https://\(host)/local/outline/{z}/{x}/{y}"

    /// A region's archive on R2, under the name the index gives it (a new build is a new name, so no cache serves an
    /// old file under a new index).
    static func archiveURL(region: PilotMapRegion, kind: PilotMapKind) -> URL {
        baseURL.appendingPathComponent(region.id).appendingPathComponent(region.file(of: kind))
    }

    /// The index is a few kilobytes; anything past this is not ours.
    static let maxIndexBytes = 1 << 20

    /// Every request to tiles.aerocheck.app carries the API's client value: Cloudflare's WAF rule refuses the rest.
    /// The same speed bump as the API's `/data` (`APIConfig.appClientSecret`), and the same value.
    static var requestHeaders: [String: String] {
        var headers = ["User-Agent": userAgent]
        if let secret = APIConfig.appClientSecret { headers["X-AeroCheck-Client"] = secret }
        return headers
    }

    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return "AeroCheck/\(version) (iOS; https://aerocheck.app)"
    }()

    /// The session the remote reads go through: no URL cache (the directories are kept on disk by the reader, the
    /// tiles by MapLibre), and never `PilotTileURLProtocol`, which is registered on MapLibre's session only.
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 6
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// A range read of an archive. It carries today's day value (the Atlas gate, `AtlasAccess`), and a 403 asks for
    /// a fresh value once before giving up: the rule turned over to a new day, or the server's secret changed.
    static let fetch: PMTilesRemoteArchive.Fetch = { request in
        try await fetch(request, dayValue: { await AtlasAccess.shared.dayValue() },
                    refresh: { await AtlasAccess.shared.refreshDayValue() }, send: send)
    }

    static let send: PMTilesRemoteArchive.Fetch = { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// `fetch`, with its parts passed in for the tests.
    static func fetch(_ request: URLRequest, dayValue: @Sendable () async -> String?,
                      refresh: @Sendable () async -> String?,
                      send: PMTilesRemoteArchive.Fetch) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.pathExtension == "pmtiles" else { return try await send(request) }
        var request = request
        if let value = await dayValue() { request.setValue(value, forHTTPHeaderField: AtlasAccess.dayHeader) }
        let answer = try await send(request)
        guard answer.1.statusCode == 403, let fresh = await refresh(),
              fresh != request.value(forHTTPHeaderField: AtlasAccess.dayHeader) else { return answer }
        request.setValue(fresh, forHTTPHeaderField: AtlasAccess.dayHeader)
        return try await send(request)
    }
}

/// The two archives of a region.
enum PilotMapKind: String, CaseIterable, Codable, Sendable {
    /// The map's vector tiles, gzip, to tile zoom 13 (MapKit's 14).
    case map
    /// Mapterhorn's elevation tiles (Terrarium WebP) to tile zoom 11, for the relief bands and the hillshade.
    case relief
}

/// A downloadable region of the pilot's map, as `index.json` lists it: a country, or a first-level division of a large
/// one (a US state, a German Land), cut at its outline. A tile at a border belongs to both regions, each with its part
/// (`PilotTileSource` joins them). (6.8.0)
struct PilotMapRegion: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    /// West, south, east, north, in degrees.
    let bounds: [Double]
    /// The map's build date, `yyyyMMdd`.
    let built: String
    let mapBytes: Int
    /// 0 when the region has no relief.
    let reliefBytes: Int
    /// The relief's own build date (it is rebuilt rarely); the map's when the index doesn't say.
    let reliefBuilt: String?
    /// A hash of each archive's tiles: the same hash, the same tiles, whatever the date. Indexes before 6.8.0's
    /// border cut have none.
    let mapHash: String?
    let reliefHash: String?
    /// Each archive's name on R2 (`map-<hash>.pmtiles`); indexes before the names have none: `map.pmtiles`.
    let mapFile: String?
    let reliefFile: String?
    /// The region's boxes, west, south, east, north: two for one across 180° (Alaska), where `bounds` spans the whole
    /// world. Indexes before the worldwide regions (28 Oct 2026) have none: `bounds` is the box.
    let boxes: [[Double]]?
    /// The name in English, French and German, from Overture; `name` is the English one.
    let names: [String: String]?
    /// ISO 3166-1 code of the region's country ("FR" for Brittany), for grouping.
    let country: String?

    enum CodingKeys: String, CodingKey {
        case id, name, bounds, built
        case mapBytes = "map_bytes"
        case reliefBytes = "relief_bytes"
        case reliefBuilt = "relief_built"
        case mapHash = "map_hash"
        case reliefHash = "relief_hash"
        case mapFile = "map_file"
        case reliefFile = "relief_file"
        case boxes, names, country
    }

    init(id: String, name: String, bounds: [Double], built: String, mapBytes: Int, reliefBytes: Int,
         reliefBuilt: String? = nil, mapHash: String? = nil, reliefHash: String? = nil, mapFile: String? = nil,
         reliefFile: String? = nil, boxes: [[Double]]? = nil, names: [String: String]? = nil, country: String? = nil) {
        self.id = id; self.name = name; self.bounds = bounds; self.built = built
        self.mapBytes = mapBytes; self.reliefBytes = reliefBytes; self.reliefBuilt = reliefBuilt
        self.mapHash = mapHash; self.reliefHash = reliefHash
        self.mapFile = mapFile; self.reliefFile = reliefFile
        self.boxes = boxes; self.names = names; self.country = country
    }

    /// The index's overview, downloaded as a region of this id, its map only. (6.8.0, question 10)
    static let overviewID = "overview"

    /// This entry with its map only: what the overview downloads (its relief stays online), named for the list.
    func mapOnly(named label: String) -> PilotMapRegion {
        PilotMapRegion(id: id, name: label, bounds: bounds, built: built, mapBytes: mapBytes, reliefBytes: 0,
                       mapHash: mapHash, mapFile: mapFile, boxes: boxes, country: country)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        bounds = try c.decode([Double].self, forKey: .bounds)
        built = try c.decode(String.self, forKey: .built)
        mapBytes = try c.decodeIfPresent(Int.self, forKey: .mapBytes) ?? 0
        reliefBytes = try c.decodeIfPresent(Int.self, forKey: .reliefBytes) ?? 0
        reliefBuilt = try c.decodeIfPresent(String.self, forKey: .reliefBuilt)
        mapHash = try c.decodeIfPresent(String.self, forKey: .mapHash)
        reliefHash = try c.decodeIfPresent(String.self, forKey: .reliefHash)
        mapFile = try c.decodeIfPresent(String.self, forKey: .mapFile)
        reliefFile = try c.decodeIfPresent(String.self, forKey: .reliefFile)
        boxes = try c.decodeIfPresent([[Double]].self, forKey: .boxes)
        names = try c.decodeIfPresent([String: String].self, forKey: .names)
        country = try c.decodeIfPresent(String.self, forKey: .country)
    }

    /// An id is a path segment, on R2 and on disk: lowercase letters, digits and hyphens only.
    var isValid: Bool {
        !id.isEmpty && id.count <= 32
            && id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
            && bounds.count == 4 && bounds[0] < bounds[2] && bounds[1] < bounds[3]
            && bounds[1] >= -90 && bounds[3] <= 90
            && built.count == 8 && built.allSatisfy(\.isNumber)
            && [mapFile, reliefFile].allSatisfy { $0.map(Self.isFileName) ?? true }
            && (boxes ?? []).allSatisfy(Self.isBox)
    }

    static func isBox(_ box: [Double]) -> Bool {
        box.count == 4 && box[0] < box[2] && box[1] < box[3] && box[1] >= -90 && box[3] <= 90
            && box[0] >= -180 && box[2] <= 180
    }

    /// The name in the app's language (English, French or German), else the index's.
    var displayName: String {
        let language = Bundle.main.preferredLocalizations.first.map { String($0.prefix(2)) } ?? "en"
        return names?[language] ?? name
    }

    func has(_ kind: PilotMapKind) -> Bool { kind == .map ? mapBytes > 0 : reliefBytes > 0 }

    /// The build an archive comes from: its cache and its download are keyed by it.
    func build(of kind: PilotMapKind) -> String { kind == .relief ? reliefBuilt ?? built : built }

    func hash(of kind: PilotMapKind) -> String? { kind == .relief ? reliefHash : mapHash }

    /// The archive's name on R2.
    func file(of kind: PilotMapKind) -> String {
        (kind == .relief ? reliefFile : mapFile) ?? "\(kind.rawValue).pmtiles"
    }

    /// A file name is one path segment: letters, digits, hyphens, and the .pmtiles extension.
    static func isFileName(_ name: String) -> Bool {
        name.hasSuffix(".pmtiles") && name.count <= 64 && name.dropLast(8).allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")
        } && name.count > 8
    }

    var downloadBytes: Int { mapBytes + reliefBytes }

    /// Whether one of the region's boxes touches the tile (web mercator, `z`/`x`/`y` as in the tile URLs).
    func touches(z: Int, x: Int, y: Int) -> Bool {
        let tile = PilotMapTileMath.bounds(z: z, x: x, y: y)
        return (boxes ?? [bounds]).contains { box in
            tile.west < box[2] && tile.east > box[0] && tile.south < box[3] && tile.north > box[1]
        }
    }

    /// Whether one of the region's boxes holds the point.
    func contains(latitude: Double, longitude: Double) -> Bool {
        (boxes ?? [bounds]).contains { $0[0] <= longitude && longitude <= $0[2] && $0[1] <= latitude && latitude <= $0[3] }
    }
}

enum PilotMapTileMath {
    /// A web-mercator tile's box in degrees.
    static func bounds(z: Int, x: Int, y: Int) -> (west: Double, south: Double, east: Double, north: Double) {
        let n = Double(1 << z)
        func lon(_ x: Double) -> Double { x / n * 360 - 180 }
        func lat(_ y: Double) -> Double { atan(sinh(.pi * (1 - 2 * y / n))) * 180 / .pi }
        return (lon(Double(x)), lat(Double(y + 1)), lon(Double(x + 1)), lat(Double(y)))
    }

    static func isValid(z: Int, x: Int, y: Int) -> Bool {
        z >= 0 && z <= 22 && x >= 0 && y >= 0 && x < (1 << z) && y < (1 << z)
    }
}

/// `index.json` on tiles.aerocheck.app: the regions, their bounds, sizes and build dates. Additive within v1: a
/// field the app doesn't know is ignored.
struct PilotMapIndex: Codable, Equatable, Sendable {
    let version: Int
    let generated: String?
    let regions: [PilotMapRegion]
    /// Zooms 0 to 7 over every region at once (since 28 Oct 2026): online, a low-zoom tile spanning dozens of regions
    /// is read from it alone. Not a region to download.
    var overview: PilotMapRegion? = nil

    /// What the app keeps: version 1, the regions it can use (an invalid one is dropped, not the index).
    static func decode(_ data: Data) throws -> PilotMapIndex {
        let raw = try JSONDecoder().decode(PilotMapIndex.self, from: data)
        guard raw.version == 1 else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "index version \(raw.version)")) }
        var seen = Set<String>()
        let kept = raw.regions.filter { $0.isValid && seen.insert($0.id).inserted }
        return PilotMapIndex(version: raw.version, generated: raw.generated, regions: kept,
                             overview: raw.overview.flatMap { $0.isValid && $0.id == "overview" ? $0 : nil })
    }
}

/// The regions index, fetched from tiles.aerocheck.app and kept on disk for offline launches. (6.8.0)
final class PilotMapIndexStore: @unchecked Sendable {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let file: URL
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var current: PilotMapIndex?
    private var fetchedAt: Date?

    init(directory: URL, fetch: @escaping Fetch = PilotMapConfig.fetch, now: @escaping @Sendable () -> Date = { Date() }) {
        file = directory.appendingPathComponent("index.json")
        self.fetch = fetch
        self.now = now
        if let data = try? Data(contentsOf: file), let index = try? PilotMapIndex.decode(data) {
            current = index
            fetchedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }

    /// The regions, in the index's order; empty before the first fetch.
    var regions: [PilotMapRegion] { lock.withLock { current?.regions ?? [] } }

    func region(id: String) -> PilotMapRegion? { regions.first { $0.id == id } }

    /// Whether an index was ever read or fetched: until then no tile can be said to have nothing there.
    var hasIndex: Bool { lock.withLock { current != nil } }

    /// The low-zoom archive over every region, when the index has one.
    var overview: PilotMapRegion? { lock.withLock { current?.overview } }

    /// Fetches the index unless the one kept is younger than `maxAge`. Keeps the old one on any failure.
    @discardableResult
    func refresh(maxAge: TimeInterval = 6 * 3600) async -> Bool {
        if let fetchedAt = lock.withLock({ fetchedAt }), now().timeIntervalSince(fetchedAt) < maxAge { return false }
        var request = URLRequest(url: PilotMapConfig.listURL(PilotMapConfig.indexURL, now: now()),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        for (field, value) in PilotMapConfig.requestHeaders { request.setValue(value, forHTTPHeaderField: field) }
        do {
            let (data, response) = try await fetch(request)
            guard response.statusCode == 200, data.count <= PilotMapConfig.maxIndexBytes else {
                AppLog.general.publicLine("Pilot's map index: HTTP \(response.statusCode), \(data.count) bytes")
                return false
            }
            let index = try PilotMapIndex.decode(data)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            let changed = lock.withLock { () -> Bool in
                defer { current = index; fetchedAt = now() }
                return current != index
            }
            if changed { AppLog.general.publicLine("Pilot's map index: \(index.regions.count) regions") }
            return changed
        } catch {
            AppLog.general.publicLine("Pilot's map index not fetched: \(type(of: error))")
            return false
        }
    }
}
