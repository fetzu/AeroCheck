import Foundation

/// The pilot's map: our own map, built monthly in the private AeroCheck-maps repository from OpenStreetMap (via the
/// Protomaps daily build) and Mapterhorn's relief, and served as PMTiles archives from R2 behind tiles.aerocheck.app.
/// Never through the API's Worker: the account's 100,000 Worker requests a day are shared, and past them every
/// Worker answers error 1027 until midnight UTC, subscription checks included. (6.8.0)
enum PilotMapConfig {
    static let host = "tiles.aerocheck.app"
    static let baseURL = URL(string: "https://\(host)/v1/")!
    static let indexURL = baseURL.appendingPathComponent("index.json")

    /// What MapLibre asks for, all answered by `PilotTileURLProtocol`: the map's vector tiles, the relief's
    /// elevation tiles and the B612 glyphs. The style names these.
    static let mapTileTemplate = "https://\(host)/v1/map/{z}/{x}/{y}"
    static let reliefTileTemplate = "https://\(host)/v1/relief/{z}/{x}/{y}"
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

    static let fetch: PMTilesRemoteArchive.Fetch = { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// The two archives of a region.
enum PilotMapKind: String, CaseIterable, Codable, Sendable {
    /// The map's vector tiles, gzip, to tile zoom 13 (MapKit's 14).
    case map
    /// Mapterhorn's elevation tiles (Terrarium WebP) to tile zoom 11, for the relief bands and the hillshade.
    case relief
}

/// A downloadable region of the pilot's map, as `index.json` lists it. Regions overlap at borders (each country
/// carries a margin): where they do, the first in the index wins, so nothing is drawn twice. (6.8.0)
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

    enum CodingKeys: String, CodingKey {
        case id, name, bounds, built
        case mapBytes = "map_bytes"
        case reliefBytes = "relief_bytes"
        case reliefBuilt = "relief_built"
        case mapHash = "map_hash"
        case reliefHash = "relief_hash"
        case mapFile = "map_file"
        case reliefFile = "relief_file"
    }

    init(id: String, name: String, bounds: [Double], built: String, mapBytes: Int, reliefBytes: Int,
         reliefBuilt: String? = nil, mapHash: String? = nil, reliefHash: String? = nil, mapFile: String? = nil,
         reliefFile: String? = nil) {
        self.id = id; self.name = name; self.bounds = bounds; self.built = built
        self.mapBytes = mapBytes; self.reliefBytes = reliefBytes; self.reliefBuilt = reliefBuilt
        self.mapHash = mapHash; self.reliefHash = reliefHash
        self.mapFile = mapFile; self.reliefFile = reliefFile
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
    }

    /// An id is a path segment, on R2 and on disk: lowercase letters, digits and hyphens only.
    var isValid: Bool {
        !id.isEmpty && id.count <= 32
            && id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
            && bounds.count == 4 && bounds[0] < bounds[2] && bounds[1] < bounds[3]
            && bounds[1] >= -90 && bounds[3] <= 90
            && built.count == 8 && built.allSatisfy(\.isNumber)
            && [mapFile, reliefFile].allSatisfy { $0.map(Self.isFileName) ?? true }
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

    /// Whether the region's box touches the tile (web mercator, `z`/`x`/`y` as in the tile URLs).
    func touches(z: Int, x: Int, y: Int) -> Bool {
        let tile = PilotMapTileMath.bounds(z: z, x: x, y: y)
        return tile.west < bounds[2] && tile.east > bounds[0] && tile.south < bounds[3] && tile.north > bounds[1]
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

    /// What the app keeps: version 1, the regions it can use (an invalid one is dropped, not the index).
    static func decode(_ data: Data) throws -> PilotMapIndex {
        let raw = try JSONDecoder().decode(PilotMapIndex.self, from: data)
        guard raw.version == 1 else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "index version \(raw.version)")) }
        var seen = Set<String>()
        let kept = raw.regions.filter { $0.isValid && seen.insert($0.id).inserted }
        return PilotMapIndex(version: raw.version, generated: raw.generated, regions: kept)
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

    /// Fetches the index unless the one kept is younger than `maxAge`. Keeps the old one on any failure.
    @discardableResult
    func refresh(maxAge: TimeInterval = 6 * 3600) async -> Bool {
        if let fetchedAt = lock.withLock({ fetchedAt }), now().timeIntervalSince(fetchedAt) < maxAge { return false }
        var request = URLRequest(url: PilotMapConfig.indexURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
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
