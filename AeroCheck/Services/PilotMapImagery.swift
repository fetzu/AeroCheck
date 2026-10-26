import CoreGraphics
import Foundation
import ImageIO

/// The aerial imagery on the pilot's map (6.8.0, decided 25 Oct: open government orthophotos only). Each device fetches
/// them from the government's own service, as the screen asks for them, and keeps them in MapLibre's cache: nothing is
/// hosted, bundled or downloaded ahead, and there is no imagery where no source is cleared.
///
/// The sources and the area each may cover come from AeroCheck-maps (`imagery/sources.json`, built from the licence
/// register into tiles.aerocheck.app/v1/imagery.json), so a source can be switched off or moved without a release; the
/// app ships a copy for its first launch. A tile spanning a border is composed from every source in it, each clipped to
/// its own area, and every source on screen is credited.
struct ImagerySource: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let enabled: Bool
    /// "wmts" ({z}/{x}/{y}, Google tiling) or "wms" ({bbox} in EPSG:3857 metres).
    let kind: String
    let template: String
    let tileSize: Int
    let minZoom: Int
    let maxZoom: Int
    /// Added to the zoom in the address: North Rhine-Westphalia's tile matrix starts at zoom 5 (matrix 0).
    let zoomOffset: Int
    let headers: [String: String]?
    /// The name of a key the source needs, from the untracked Secrets.xcconfig; without it the source is off.
    let secret: String?
    let secretHeader: String?
    /// The provider's own wording, never translated; "{year}" is the current year.
    let credit: String
    let creditLink: String?
    let licence: String
    let licenceLink: String?
    /// The provider's licence counts our clipping at the border as a change to mark on the credits page.
    let changeNote: Bool
    let area: Area

    struct Area: Codable, Equatable, Sendable {
        let codes: [String]
        /// West, south, east, north.
        let bbox: [Double]
        /// Polygons, each an outer ring and its holes, as [lon, lat] pairs.
        let polygons: [[[[Double]]]]
    }

    enum CodingKeys: String, CodingKey {
        case id, enabled, kind, template, headers, secret, credit, licence, area
        case tileSize = "tile_size", minZoom = "min_zoom", maxZoom = "max_zoom", secretHeader = "secret_header"
        case zoomOffset = "zoom_offset"
        case creditLink = "credit_link", licenceLink = "licence_link", changeNote = "change_note"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        kind = try c.decode(String.self, forKey: .kind)
        template = try c.decode(String.self, forKey: .template)
        tileSize = try c.decodeIfPresent(Int.self, forKey: .tileSize) ?? 256
        minZoom = try c.decodeIfPresent(Int.self, forKey: .minZoom) ?? 0
        maxZoom = try c.decodeIfPresent(Int.self, forKey: .maxZoom) ?? 19
        zoomOffset = try c.decodeIfPresent(Int.self, forKey: .zoomOffset) ?? 0
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers)
        secret = try c.decodeIfPresent(String.self, forKey: .secret)
        secretHeader = try c.decodeIfPresent(String.self, forKey: .secretHeader)
        credit = try c.decode(String.self, forKey: .credit)
        creditLink = try c.decodeIfPresent(String.self, forKey: .creditLink)
        licence = try c.decode(String.self, forKey: .licence)
        licenceLink = try c.decodeIfPresent(String.self, forKey: .licenceLink)
        changeNote = try c.decodeIfPresent(Bool.self, forKey: .changeNote) ?? false
        area = try c.decode(Area.self, forKey: .area)
    }

    /// The credit as shown: "{year}" filled with the current year.
    func creditLine(year: Int = Calendar(identifier: .gregorian).component(.year, from: Date())) -> String {
        credit.replacingOccurrences(of: "{year}", with: String(year))
    }

    /// The address of one tile, nil for a template that isn't ours to use (not https, no placeholder).
    func url(z: Int, x: Int, y: Int) -> URL? {
        var address = template
        if kind == "wms" {
            let box = ImageryGeometry.mercatorBox(z: z, x: x, y: y)
            address = address.replacingOccurrences(of: "{bbox}", with: box.map { String(format: "%.3f", $0) }.joined(separator: ","))
        } else {
            address = address.replacingOccurrences(of: "{z}", with: String(z + zoomOffset))
                .replacingOccurrences(of: "{x}", with: String(x)).replacingOccurrences(of: "{y}", with: String(y))
        }
        guard let url = URL(string: address), url.scheme == "https", url.host != nil, !address.contains("{") else { return nil }
        return url
    }
}

struct ImageryIndex: Codable, Equatable, Sendable {
    let version: Int
    let generated: String?
    let sources: [ImagerySource]

    static func decode(_ data: Data) throws -> ImageryIndex {
        let index = try JSONDecoder().decode(ImageryIndex.self, from: data)
        guard index.version == 1 else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "imagery version")) }
        return index
    }
}

/// Web mercator in [0, 1] (x east, y south), and the polygons of a source's area in it, for masks.
enum ImageryGeometry {
    static func mercator(lon: Double, lat: Double) -> CGPoint {
        let clamped = max(min(lat, 85.0511), -85.0511) * .pi / 180
        return CGPoint(x: (lon + 180) / 360, y: (1 - asinh(tan(clamped)) / .pi) / 2)
    }

    /// A tile's box in EPSG:3857 metres: minx, miny, maxx, maxy.
    static func mercatorBox(z: Int, x: Int, y: Int) -> [Double] {
        let half = 20_037_508.342789244, n = Double(1 << z), size = 2 * half / n
        return [-half + Double(x) * size, half - Double(y + 1) * size, -half + Double(x + 1) * size, half - Double(y) * size]
    }

    /// A source's polygons as mercator rings.
    static func rings(_ area: ImagerySource.Area) -> [[[CGPoint]]] {
        area.polygons.map { polygon in polygon.map { ring in ring.compactMap { $0.count >= 2 ? mercator(lon: $0[0], lat: $0[1]) : nil } } }
    }

    /// A path of the rings in the pixels of a view onto `rect` (mercator) of `size` pixels, y up as CoreGraphics draws;
    /// filled even-odd, holes stay out.
    static func path(_ rings: [[[CGPoint]]], rect: CGRect, size: CGSize) -> CGPath {
        let path = CGMutablePath()
        for polygon in rings {
            for ring in polygon where ring.count > 2 {
                path.addLines(between: ring.map { pixel($0, rect: rect, size: size) })
                path.closeSubpath()
            }
        }
        return path
    }

    /// A mercator point in those pixels.
    static func pixel(_ point: CGPoint, rect: CGRect, size: CGSize) -> CGPoint {
        CGPoint(x: (point.x - rect.minX) * size.width / rect.width,
                y: size.height - (point.y - rect.minY) * size.height / rect.height)
    }

    /// How much of `rect` the rings cover, from a 32 × 32 mask: 0 none, 1 all.
    static func coverage(_ rings: [[[CGPoint]]], rect: CGRect) -> Double {
        let side = 32
        var mask = [UInt8](repeating: 0, count: side * side)
        let filled = mask.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.addPath(path(rings, rect: rect, size: CGSize(width: side, height: side)))
            context.setFillColor(gray: 1, alpha: 1)
            context.fillPath(using: .evenOdd)
            return true
        }
        guard filled else { return 0 }
        return Double(mask.filter { $0 > 127 }.count) / Double(mask.count)
    }

    static func tileRect(z: Int, x: Int, y: Int) -> CGRect {
        let n = Double(1 << z)
        return CGRect(x: Double(x) / n, y: Double(y) / n, width: 1 / n, height: 1 / n)
    }
}

/// The sources, as the app last had them: tiles.aerocheck.app/v1/imagery.json, else the copy kept on disk, else the
/// one the app ships. (6.8.0)
final class ImageryStore: @unchecked Sendable {
    typealias Fetch = PilotMapIndexStore.Fetch

    struct Prepared: Sendable {
        let source: ImagerySource
        let rings: [[[CGPoint]]]
        /// The area's box in mercator.
        let box: CGRect
    }

    static let indexURL = PilotMapConfig.baseURL.appendingPathComponent("imagery.json")

    private let file: URL
    private let fetch: Fetch
    private let secrets: (String) -> String?
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var prepared: [Prepared] = []
    private var fetchedAt: Date?

    init(directory: URL, bundled: URL? = Bundle.main.url(forResource: "imagery", withExtension: "json", subdirectory: "PilotMapImagery"),
         fetch: @escaping Fetch = PilotMapConfig.fetch, secrets: @escaping (String) -> String? = ImageryStore.bundleSecret,
         now: @escaping @Sendable () -> Date = { Date() }) {
        file = directory.appendingPathComponent("imagery.json")
        self.fetch = fetch
        self.secrets = secrets
        self.now = now
        if let data = try? Data(contentsOf: file), let index = try? ImageryIndex.decode(data) {
            apply(index)
            fetchedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        } else if let bundled, let data = try? Data(contentsOf: bundled), let index = try? ImageryIndex.decode(data) {
            apply(index)
        }
    }

    /// The sources in use: switched on, and holding their key when they need one.
    var sources: [Prepared] { lock.withLock { prepared } }

    func secret(for source: ImagerySource) -> String? { source.secret.flatMap(secrets) }

    private func apply(_ index: ImageryIndex) {
        let usable = index.sources.filter { source in
            source.enabled && source.area.bbox.count == 4 && (source.secret == nil || secrets(source.secret!) != nil)
        }
        let list = usable.map { source -> Prepared in
            let b = source.area.bbox
            let nw = ImageryGeometry.mercator(lon: b[0], lat: b[3]), se = ImageryGeometry.mercator(lon: b[2], lat: b[1])
            return Prepared(source: source, rings: ImageryGeometry.rings(source.area),
                            box: CGRect(x: nw.x, y: nw.y, width: se.x - nw.x, height: se.y - nw.y))
        }
        lock.withLock { prepared = list }
    }

    /// The list from tiles.aerocheck.app, at most every six hours; the old one stays on any failure.
    @discardableResult
    func refresh(maxAge: TimeInterval = 6 * 3600) async -> Bool {
        if let fetchedAt = lock.withLock({ fetchedAt }), now().timeIntervalSince(fetchedAt) < maxAge { return false }
        var request = URLRequest(url: Self.indexURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        for (field, value) in PilotMapConfig.requestHeaders { request.setValue(value, forHTTPHeaderField: field) }
        guard let (data, response) = try? await fetch(request), response.statusCode == 200,
              data.count <= 4 << 20, let index = try? ImageryIndex.decode(data) else { return false }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        apply(index)
        lock.withLock { fetchedAt = now() }
        return true
    }

    /// The sources whose area covers part of `rect` (mercator), with how much: the tile composer's and the credits'
    /// question.
    func sources(in rect: CGRect) -> [(Prepared, Double)] {
        sources.compactMap { item in
            guard item.box.intersects(rect) else { return nil }
            let share = ImageryGeometry.coverage(item.rings, rect: rect)
            return share > 0 ? (item, share) : nil
        }
    }

    /// A key from the app's Info.plist (written from Secrets.xcconfig), nil when empty or unexpanded.
    static func bundleSecret(_ name: String) -> String? {
        let key = "ImagerySecret_" + name
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("$") ? nil : trimmed
    }
}

/// One imagery tile for MapLibre: from a source covering the whole tile, its bytes as they come; across a border, each
/// source's image clipped to its area and drawn into one PNG, transparent where no source is cleared. (6.8.0)
enum ImageryTiles {
    typealias Fetch = PMTilesRemoteArchive.Fetch

    static let maxTileBytes = 4 << 20
    /// The size composed tiles are drawn at: MapLibre asks 256-point tiles, drawn sharp on the iPad's screen.
    static let composedSize = 512

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    static let fetch: Fetch = { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// The tile; none where no source is cleared; "not now" offline or when a source in it fails, so a tile is never
    /// kept with a hole where a provider was slow.
    static func tile(z: Int, x: Int, y: Int, store: ImageryStore, offline: Bool,
                     fetch: @escaping Fetch = ImageryTiles.fetch) async -> LocalTile {
        guard PilotMapTileMath.isValid(z: z, x: x, y: y) else { return .none }
        let rect = ImageryGeometry.tileRect(z: z, x: x, y: y)
        let covering = store.sources(in: rect).filter { z >= $0.0.source.minZoom }
        guard !covering.isEmpty else { return .none }
        guard !offline else { return .unavailable }
        // One source over the whole tile at a zoom it has: its bytes, untouched.
        if covering.count == 1, covering[0].1 >= 0.999, z <= covering[0].0.source.maxZoom {
            return await image(covering[0].0, z: z, x: x, y: y, store: store, fetch: fetch)
        }
        // Otherwise each one clipped to its area, all fetched side by side.
        let fetched = await withTaskGroup(of: (Int, LocalTile).self) { group -> [Int: LocalTile] in
            for (i, (item, _)) in covering.enumerated() {
                let depth = max(0, z - item.source.maxZoom)
                group.addTask { (i, await image(item, z: z - depth, x: x >> depth, y: y >> depth, store: store, fetch: fetch)) }
            }
            var out: [Int: LocalTile] = [:]
            for await (i, answer) in group { out[i] = answer }
            return out
        }
        if fetched.values.contains(.unavailable) { return .unavailable }
        let size = composedSize
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .unavailable }
        let pixels = CGSize(width: size, height: size)
        var drawn = false
        for (i, (item, _)) in covering.enumerated() {
            // Past a source's last zoom, its last tile enlarged: the part of the ancestor this tile is.
            let depth = max(0, z - item.source.maxZoom)
            guard let bytes = fetched[i]?.data,
                  let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let ancestor = ImageryGeometry.tileRect(z: z - depth, x: x >> depth, y: y >> depth)
            let topLeft = ImageryGeometry.pixel(ancestor.origin, rect: rect, size: pixels)
            let side = ancestor.width * pixels.width / rect.width
            context.saveGState()
            context.addPath(ImageryGeometry.path(item.rings, rect: rect, size: pixels))
            context.clip(using: .evenOdd)
            context.interpolationQuality = .high
            context.draw(picture, in: CGRect(x: topLeft.x, y: topLeft.y - side, width: side, height: side))
            context.restoreGState()
            drawn = true
        }
        guard drawn, let image = context.makeImage(), let png = PilotMapCharts.png(image) else { return .none }
        return .data(png)
    }

    private static func image(_ item: ImageryStore.Prepared, z: Int, x: Int, y: Int, store: ImageryStore,
                              fetch: Fetch) async -> LocalTile {
        let source = item.source
        guard let url = source.url(z: z, x: x, y: y) else { return .none }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(PilotMapConfig.userAgent, forHTTPHeaderField: "User-Agent")
        for (field, value) in source.headers ?? [:] { request.setValue(value, forHTTPHeaderField: field) }
        if let header = source.secretHeader, let key = store.secret(for: source) { request.setValue(key, forHTTPHeaderField: header) }
        let result: (Data, HTTPURLResponse)
        do { result = try await fetch(request) } catch {
            AppLog.general.publicLine("Imagery \(source.id): not reached (\(type(of: error)))")
            return .unavailable
        }
        let (data, response) = result
        switch response.statusCode {
        case 200:
            guard !data.isEmpty, data.count <= maxTileBytes,
                  (response.value(forHTTPHeaderField: "Content-Type") ?? "image").hasPrefix("image") else {
                AppLog.general.publicLine("Imagery \(source.id): not an image (\(data.count) bytes)")
                return .unavailable
            }
            return .data(data)
        case 204, 400, 404:
            return .none
        default:
            AppLog.general.publicLine("Imagery \(source.id): HTTP \(response.statusCode)")
            return .unavailable
        }
    }

    /// The sources on screen, for the credits: those covering any of the view (mercator rect), in the list's order.
    static func credited(in rect: CGRect, zoom: Double, store: ImageryStore) -> [ImagerySource] {
        store.sources(in: rect).map(\.0.source).filter { Double($0.minZoom) <= zoom + 1 }
    }
}
