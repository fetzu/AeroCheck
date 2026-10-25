import Foundation
import ImageIO
import MapKit
import os

// MARK: - The app's own tile renderer (6.4.2)

// MapKit's `MKTileOverlayRenderer` dropped some of the tiles handed to it after `loadTile` returned, and asked for them
// again only when it redrew by itself: a still map kept its holes (Plan › Map after a relaunch, the route builder).
// Six releases of workarounds (`LateTileRedraw`, 6.1.0 to 6.4.2, gone since) each traded one symptom for another:
// holes, a blank frame, flashing, a wait of 8 to 15 s. It also chose the zoom alone, from the screen's scale and the
// view's size, and asked for nothing past the overlay's `maximumZ`: the ICAO chart drew blank at its closest zoom on
// the iPad, where it wanted zoom 13 of a chart that stops at 12 (the map tile review, 19 Oct 2026). This renderer draws
// the tiles itself, from `ChartTileLoader`'s caches:
// - it draws what it has: the tile, else the nearest zoom out it has, enlarged, else the four zoom in, reduced;
// - a tile that comes redraws its own rectangle, at the zoom that wanted it (MapKit's documented path for content that
//   comes late), and nothing else;
// - it picks the zoom itself, as sharp as MapKit's renderer, and past a layer's last zoom it enlarges that one;
// - on a map with nothing loaded it asks first for the chart two zooms out, a dozen tiles at most for a screen, there
//   after one round trip, and the sharp tiles replace it as they come (the author's answers, q1 A and q4 A).

/// A tile of the Web Mercator grid: zoom, column, row.
struct ChartTile: Hashable, Sendable, CustomStringConvertible {
    let z: Int
    let x: Int
    let y: Int

    var description: String { "z\(z)/\(x)/\(y)" }

    /// The tile `levels` zooms out that holds this one.
    func ancestor(_ levels: Int) -> ChartTile {
        ChartTile(z: z - levels, x: x >> levels, y: y >> levels)
    }

    /// The four tiles one zoom in.
    var children: [ChartTile] {
        [(0, 0), (1, 0), (0, 1), (1, 1)].map { ChartTile(z: z + 1, x: x * 2 + $0.0, y: y * 2 + $0.1) }
    }

    /// Where it lies on the map.
    var mapRect: MKMapRect {
        let side = MKMapSize.world.width / Double(1 << z)
        return MKMapRect(x: Double(x) * side, y: Double(y) * side, width: side, height: side)
    }

    /// The tiles of zoom `z` that `mapRect` touches.
    static func covering(_ mapRect: MKMapRect, z: Int) -> [ChartTile] {
        guard z >= 0, z <= 24, !mapRect.isNull, !mapRect.isEmpty else { return [] }
        let count = 1 << z
        let side = MKMapSize.world.width / Double(count)
        let x0 = max(0, Int((mapRect.minX / side).rounded(.down)))
        let y0 = max(0, Int((mapRect.minY / side).rounded(.down)))
        // A rectangle ending on a tile's edge doesn't touch the next one.
        let x1 = min(count - 1, Int((mapRect.maxX / side).rounded(.up)) - 1)
        let y1 = min(count - 1, Int((mapRect.maxY / side).rounded(.up)) - 1)
        guard x0 <= x1, y0 <= y1 else { return [] }
        var tiles: [ChartTile] = []
        tiles.reserveCapacity((x1 - x0 + 1) * (y1 - y0 + 1))
        for y in y0...y1 { for x in x0...x1 { tiles.append(ChartTile(z: z, x: x, y: y)) } }
        return tiles
    }

    /// The zoom whose 256-pixel tiles cover 256 points at `zoomScale` (screen points per map point), as MapKit's tile
    /// renderer chose: as sharp as the charts always were, each tile enlarged twice on a Retina screen. Measured on the
    /// iPad: zoom 13 at a camera of 28.9 km. (6.4.2)
    static func zoom(for zoomScale: MKZoomScale) -> Int {
        let scale = Double(zoomScale)
        guard scale > 0, scale.isFinite else { return 0 }
        // A tile of zoom z spans 2^(28 - z) map points: 256 points of it at z = 20 + log2(zoomScale).
        return Int((20 + log2(scale)).rounded())
    }
}

/// How to get one tile of a layer: the key it is kept under, a downloaded copy, the network.
struct ChartTileSpec: @unchecked Sendable {
    /// The cache key: the tile's URL for swisstopo.
    let key: String
    /// A downloaded copy (the offline charts), read before anything else when it exists.
    var disk: URL?
    /// The network request; nil when the map is offline.
    var fetch: (@Sendable () async throws -> (Data, HTTPURLResponse))?
    /// A plain white tile is no tile (`SwisstopoTiles.isBlank`): the National Map's outside Switzerland.
    var dropsBlank = false
    /// Done to the decoded image before it is kept (OpenAIP strips its fills).
    var process: (@Sendable (CGImage) -> CGImage?)? = nil
}

/// A tile overlay that `ChartTileRenderer` draws: it says, per tile within its `minimumZ...maximumZ`, where the tile
/// comes from; nil when there is none.
protocol ChartTileSource: MKTileOverlay {
    func spec(for tile: ChartTile) -> ChartTileSpec?
    /// How many zooms past `maximumZ` its last zoom is drawn enlarged; nothing further in.
    var enlargesPastLastZoom: Int { get }
}

extension ChartTileSource {
    /// The charts: as far in as the camera goes (the glider chart at the ICAO layer's closest zoom, q3 B).
    var enlargesPastLastZoom: Int { 6 }
}

// MARK: - Loader and caches

/// A tile as kept: its image, or none (a tile past a layer's edge, a blank one).
final class ChartTileImage: @unchecked Sendable {
    let image: CGImage?
    init(_ image: CGImage?) { self.image = image }
}

/// What a tile's cache holds now.
enum ChartTileLookup {
    case image(CGImage)
    /// No tile there, for good.
    case empty
    /// Not here yet: on the network, or failed a moment ago.
    case missing
}

/// What came back for a tile.
enum ChartTileOutcome: Sendable {
    case image
    case empty
    case failed
    /// Not fetched: no map wanted it by its turn.
    case passedBy
}

/// Every chart tile the maps draw comes through here: decoded once and kept in memory, the downloaded charts read
/// from disk, the rest fetched `limit` at a time, the most urgent first (`ChartTileRenderer.urgency(of:coarse:)`), one
/// request per tile however many maps want it. A tile no map wants any more by its turn isn't fetched, a closed map's
/// included. Thread-safe. (6.4.2)
final class ChartTileLoader: @unchecked Sendable {
    static let shared = ChartTileLoader(limit: 8)

    let limit: Int

    /// Decoded tiles, by key, costed by their pixels: about 380 tiles of 256 pixels, five screens of an iPad.
    let images: NSCache<NSString, ChartTileImage> = {
        let cache = NSCache<NSString, ChartTileImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    /// The tiles' files as they came, by key: about 400 chart tiles at their median, 1,500 of the National Map.
    /// Decoded again in a millisecond or two when `images` let one go.
    let files: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private struct Job {
        let spec: ChartTileSpec
        /// The order asked in: of two as urgent, the newest goes first.
        let order: Int
    }

    private struct Waiting {
        var urgency: [@Sendable () -> Double?]
        var done: [@Sendable (ChartTileOutcome) -> Void]
    }

    private struct State {
        var running = 0
        var queue: [Job] = []
        var asked = 0
        var waiting: [String: Waiting] = [:]
        var failures: [String: (count: Int, at: Date)] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(limit: Int) {
        self.limit = limit
    }

    // MARK: Local

    /// What the memory caches hold for `spec`, without reading the disk.
    func cached(_ spec: ChartTileSpec) -> ChartTileLookup {
        let key = spec.key as NSString
        if let kept = images.object(forKey: key) { return kept.image.map { .image($0) } ?? .empty }
        if let file = files.object(forKey: key) {
            return keep(decode(file as Data, spec: spec), for: spec.key)
        }
        return .missing
    }

    /// What the caches and the disk hold for `spec`: the downloaded copy read and decoded now. For the renderer's
    /// draw, off the main thread.
    func local(_ spec: ChartTileSpec) -> ChartTileLookup {
        let found = cached(spec)
        guard case .missing = found, let disk = spec.disk, let data = try? Data(contentsOf: disk) else { return found }
        guard let image = decode(data, spec: spec) else { return .missing }
        return keep(image, for: spec.key)
    }

    /// Whether `spec` can be drawn now, from memory or disk, or is settled without a tile: kept as none, or failed a
    /// moment ago (drawn without it, asked again later).
    func isReady(_ spec: ChartTileSpec) -> Bool {
        let key = spec.key as NSString
        if images.object(forKey: key) != nil || files.object(forKey: key) != nil { return true }
        if let disk = spec.disk, FileManager.default.fileExists(atPath: disk.path) { return true }
        return spec.fetch == nil || retryDelay(for: spec.key) != nil
    }

    /// How long until a tile that failed is asked again; nil when it didn't fail lately.
    func retryDelay(for key: String, now: Date = Date()) -> TimeInterval? {
        guard let failure = state.withLock({ $0.failures[key] }) else { return nil }
        let wait = Self.backoff(after: failure.count) - now.timeIntervalSince(failure.at)
        return wait > 0 ? wait : nil
    }

    /// 2, 5, 15, 30 s, then every minute.
    static func backoff(after failures: Int) -> TimeInterval {
        [2, 5, 15, 30, 60][min(max(failures, 1), 5) - 1]
    }

    // MARK: Network

    /// Fetches `spec` unless it is on its way already; `done` once it has come (on the loader's thread). `urgency` is
    /// asked each time a place frees: the lowest goes first, infinity waits (asked again when a map moves,
    /// `reconsider()`); nil from every map that asked, and the tile isn't fetched (`passedBy`).
    func load(_ spec: ChartTileSpec, urgency: @escaping @Sendable () -> Double?,
              done: @escaping @Sendable (ChartTileOutcome) -> Void) {
        guard spec.fetch != nil else {
            done(.empty)
            return
        }
        state.withLock { state in
            if var waiting = state.waiting[spec.key] {
                waiting.urgency.append(urgency)
                waiting.done.append(done)
                state.waiting[spec.key] = waiting
                return
            }
            state.waiting[spec.key] = Waiting(urgency: [urgency], done: [done])
            state.asked += 1
            state.queue.append(Job(spec: spec, order: state.asked))
        }
        pump()
    }

    /// The order to look at again: the map moved.
    func reconsider() { pump() }

    /// For the tests: requests waiting their turn.
    var queuedCount: Int { state.withLock { $0.queue.count } }

    /// Starts the most urgent jobs while places are free; the ones no map wants any more are let go unfetched.
    private func pump() {
        while true {
            let queued = state.withLock { state -> [(Job, [@Sendable () -> Double?])] in
                guard state.running < limit else { return [] }
                return state.queue.map { ($0, state.waiting[$0.spec.key]?.urgency ?? []) }
            }
            guard !queued.isEmpty else { return }
            // Asked outside the lock: a renderer's own lock is taken there.
            var best: (job: Job, rank: Double)?
            var unwanted: [Job] = []
            for (job, urgencies) in queued {
                guard let urgency = urgencies.compactMap({ $0() }).min() else {
                    unwanted.append(job)
                    continue
                }
                guard urgency.isFinite else { continue }
                let rank = urgency - Double(job.order) * 1e-9
                if best == nil || rank < best!.rank { best = (job, rank) }
            }
            if !unwanted.isEmpty {
                let orders = Set(unwanted.map(\.order))
                state.withLock { $0.queue.removeAll { orders.contains($0.order) } }
                for job in unwanted { finish(job.spec.key, .passedBy) }
            }
            guard let job = best?.job else { return }
            let started = state.withLock { state -> Bool in
                guard state.running < limit, let at = state.queue.firstIndex(where: { $0.order == job.order }) else {
                    return false
                }
                state.queue.remove(at: at)
                state.running += 1
                return true
            }
            guard started else { continue }
            Task.detached(priority: .userInitiated) { [self] in
                let outcome = await fetch(job.spec)
                state.withLock { $0.running -= 1 }
                finish(job.spec.key, outcome)
                pump()
            }
        }
    }

    private func finish(_ key: String, _ outcome: ChartTileOutcome) {
        let done = state.withLock { state -> [@Sendable (ChartTileOutcome) -> Void] in
            switch outcome {
            case .failed:
                let count = (state.failures[key]?.count ?? 0) + 1
                state.failures[key] = (count, Date())
            case .image, .empty:
                state.failures[key] = nil
            case .passedBy:
                break
            }
            return state.waiting.removeValue(forKey: key)?.done ?? []
        }
        for callback in done { callback(outcome) }
    }

    private func fetch(_ spec: ChartTileSpec) async -> ChartTileOutcome {
        guard let fetch = spec.fetch else { return .empty }
        #if DEBUG
        if TileLog.delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: TileLog.delayNanoseconds) }
        #endif
        do {
            let (data, response) = try await fetch()
            switch response.statusCode {
            case 200:
                if spec.dropsBlank && SwisstopoTiles.isBlank(data) {
                    remember(nil, file: nil, for: spec.key)
                    return .empty
                }
                guard let image = decode(data, spec: spec) else { return .failed }
                remember(image, file: data, for: spec.key)
                return .image
            case 400..<500:
                // For good: a tile past the layer's edge.
                remember(nil, file: nil, for: spec.key)
                return .empty
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    // MARK: Decoding

    /// Largest tile edge accepted: 256 is the standard, 2,048 headroom that makes an out-of-memory decode impossible.
    /// (SEC-C34)
    static let maxTileDimension = 2_048

    private func decode(_ data: Data, spec: ChartTileSpec) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= Self.maxTileDimension, height <= Self.maxTileDimension,
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                                                          [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        if let process = spec.process { return process(image) }
        return image
    }

    private func keep(_ image: CGImage?, for key: String) -> ChartTileLookup {
        guard let image else { return .missing }
        images.setObject(ChartTileImage(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
        return .image(image)
    }

    private func remember(_ image: CGImage?, file: Data?, for key: String) {
        let cost = image.map { $0.bytesPerRow * $0.height } ?? 64
        images.setObject(ChartTileImage(image), forKey: key as NSString, cost: cost)
        if let file { files.setObject(file as NSData, forKey: key as NSString, cost: file.count) }
    }

    /// For the tests: everything kept forgotten.
    func removeAll() {
        images.removeAllObjects()
        files.removeAllObjects()
        state.withLock { $0.failures.removeAll() }
    }
}

// MARK: - The renderer

/// Draws a `ChartTileSource`'s tiles (see the top of this file). Every map delegate makes its tile renderers through
/// `ChartTileRenderer.renderer(for:on:)`.
///
/// Sendable, as MapKit already uses it: `canDraw` and `draw` come on MapKit's drawing threads and the tiles arrive
/// on the main thread, so what they share is behind `state`; `source` and `loader` never change, and `mapView` is
/// set and read on the main thread only. The loader's callbacks, `@Sendable`, hold it weakly to hop to the main
/// thread; without the conformance Xcode warned at each build (6.4.3).
class ChartTileRenderer: MKOverlayRenderer, @unchecked Sendable {
    let source: ChartTileSource
    let loader: ChartTileLoader

    /// How far out a stand-in may come from: six zooms, a tile 64 times enlarged.
    static let standInLevels = 6
    /// The coarse chart asked first: two zooms out.
    static let coarseLevels = 2

    private struct State {
        /// The tiles this renderer asked for, each with the zoom scales MapKit wanted it at.
        var wanted: [ChartTile: Set<MKZoomScale>] = [:]
        /// The zoom MapKit drew at last.
        var zoom = -1
        /// The map's rectangle in view, from the main thread.
        var visible: MKMapRect?
        var visibleRefreshPending = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The map it draws on, for the rectangle in view (`urgency(of:coarse:)`).
    weak var mapView: MKMapView?

    init(source: ChartTileSource, loader: ChartTileLoader = .shared) {
        self.source = source
        self.loader = loader
        super.init(overlay: source)
    }

    /// The renderer for a tile overlay on `mapView`: this one for the app's sources, MapKit's for any other.
    @MainActor
    static func renderer(for overlay: MKTileOverlay, on mapView: MKMapView?) -> MKOverlayRenderer {
        if let source = overlay as? ChartTileSource {
            let renderer = ChartTileRenderer(source: source)
            renderer.mapView = mapView
            #if DEBUG
            MapSettle.watch(renderer)
            #endif
            return renderer
        }
        return MKTileOverlayRenderer(tileOverlay: overlay)
    }

    /// The zoom drawn at `zoomScale`: the screen's, within the layer's zooms.
    func zooms(at zoomScale: MKZoomScale) -> (wanted: Int, drawn: Int) {
        let wanted = ChartTile.zoom(for: zoomScale)
        return (wanted, min(max(wanted, source.minimumZ), source.maximumZ))
    }

    /// Two zooms or more under the layer's first, too many tiles to draw, or further in than the layer enlarges:
    /// nothing (Apple's map, or the grid).
    private func draws(_ zooms: (wanted: Int, drawn: Int)) -> Bool {
        zooms.drawn - zooms.wanted < 2 && zooms.wanted - zooms.drawn <= source.enlargesPastLastZoom
    }

    // MARK: MapKit

    override func canDraw(_ mapRect: MKMapRect, zoomScale: MKZoomScale) -> Bool {
        let zooms = zooms(at: zoomScale)
        state.withLock { $0.zoom = zooms.wanted }
        noteVisibleSoon()
        guard draws(zooms) else { return true }
        var ready = true
        for tile in ChartTile.covering(mapRect, z: zooms.drawn) {
            guard let spec = source.spec(for: tile), !loader.isReady(spec) else { continue }
            request(tile, spec: spec, zoomScale: zoomScale, coarse: false)
            guard !hasStandIn(for: tile) else { continue }
            // Nothing to draw there yet: MapKit keeps what it showed until the tile, or the coarse one, comes.
            ready = false
            let levels = min(Self.coarseLevels, tile.z - source.minimumZ)
            if levels > 0 {
                let coarse = tile.ancestor(levels)
                if let coarseSpec = source.spec(for: coarse), !loader.isReady(coarseSpec) {
                    request(coarse, spec: coarseSpec, zoomScale: zoomScale, coarse: true)
                }
            }
        }
        #if DEBUG
        TileLog.line("canDraw z\(zooms.wanted)→\(zooms.drawn) scale=\(zoomScale) \(ready ? "ready" : "waits") "
                     + "main=\(Thread.isMainThread) r\(ObjectIdentifier(self).hashValue & 0xfff) "
                     + "rect=\(Int(mapRect.minX)),\(Int(mapRect.minY)) \(Int(mapRect.width * zoomScale))pt")
        #endif
        return ready
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let zooms = zooms(at: zoomScale)
        guard draws(zooms) else { return }
        context.interpolationQuality = .high
        context.setAllowsAntialiasing(false)
        for tile in ChartTile.covering(mapRect, z: zooms.drawn) {
            guard let spec = source.spec(for: tile) else { continue }
            let area = tile.mapRect.intersection(mapRect)
            switch loader.local(spec) {
            case .image(let image):
                draw(image, of: tile, clippedTo: area, in: context)
            case .empty:
                continue
            case .missing:
                drawStandIn(for: tile, clippedTo: area, in: context)
            }
        }
    }

    // MARK: Stand-ins

    /// The nearest zoom out kept in memory, else the four zoom in.
    private func standIn(for tile: ChartTile) -> [(ChartTile, CGImage)] {
        let deepest = max(source.minimumZ, tile.z - Self.standInLevels)
        if tile.z - 1 >= deepest {
            for z in stride(from: tile.z - 1, through: deepest, by: -1) {
                let ancestor = tile.ancestor(tile.z - z)
                if let spec = source.spec(for: ancestor), case .image(let image) = loader.cached(spec) {
                    return [(ancestor, image)]
                }
            }
        }
        guard tile.z + 1 <= source.maximumZ else { return [] }
        return tile.children.compactMap { child in
            guard let spec = source.spec(for: child), case .image(let image) = loader.cached(spec) else { return nil }
            return (child, image)
        }
    }

    private func hasStandIn(for tile: ChartTile) -> Bool { !standIn(for: tile).isEmpty }

    private func drawStandIn(for tile: ChartTile, clippedTo area: MKMapRect, in context: CGContext) {
        for (standIn, image) in standIn(for: tile) {
            draw(image, of: standIn, clippedTo: area.intersection(standIn.mapRect), in: context)
        }
    }

    /// `image`, the tile `tile`, drawn where it lies, only within `area`. The context is the map's way up (y down):
    /// the image is flipped to it.
    private func draw(_ image: CGImage, of tile: ChartTile, clippedTo area: MKMapRect, in context: CGContext) {
        guard !area.isNull, !area.isEmpty else { return }
        let rect = rect(for: tile.mapRect)
        context.saveGState()
        context.clip(to: self.rect(for: area))
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    // MARK: Tiles on their way

    /// Asks the loader for `tile`, once for all the zoom scales that want it.
    private func request(_ tile: ChartTile, spec: ChartTileSpec, zoomScale: MKZoomScale, coarse: Bool) {
        let first = state.withLock { state -> Bool in
            let asked = state.wanted[tile] != nil
            state.wanted[tile, default: []].insert(zoomScale)
            return !asked
        }
        guard first else { return }
        #if DEBUG
        TileLog.line("ask \(tile)\(coarse ? " coarse" : "") "
                     + spec.key.split(separator: "/").suffix(5).joined(separator: "/"))
        #endif
        loader.load(spec, urgency: { [weak self] in self?.urgency(of: tile, coarse: coarse) }) { [weak self] outcome in
            DispatchQueue.main.async { self?.arrived(tile, outcome) }
        }
    }

    /// Whether a zoom MapKit draws at, or the next one, still wants `tile`.
    func wants(_ tile: ChartTile) -> Bool {
        state.withLock { state in
            guard let scales = state.wanted[tile] else { return false }
            return scales.contains { abs(ChartTile.zoom(for: $0) - state.zoom) <= 1 }
        }
    }

    /// How soon `tile` is wanted (lower sooner), nil when no longer, infinity for later. MapKit asks for about three
    /// screens' width around the one in view: on screen first, the coarse before the sharp, nearest the middle first;
    /// then the tiles within a quarter of a screen of it, which a pan or the aircraft moving on brings in; the rest
    /// waits until the map comes near it (about two thirds of what MapKit asks for, never fetched on a map that stays).
    /// A tile of the zoom next to the one in view (MapKit passing through it, the camera settling) comes after all of
    /// it.
    func urgency(of tile: ChartTile, coarse: Bool) -> Double? {
        let (wanted, visible) = state.withLock { state -> (Int?, MKMapRect?) in
            let away = state.wanted[tile]?.map { abs(ChartTile.zoom(for: $0) - state.zoom) }.min()
            return (away, state.visible)
        }
        guard let away = wanted, away <= 1 else { return nil }
        let other: Double = away == 0 ? 0 : 100
        guard let visible, !visible.isEmpty else { return other + (coarse ? 0 : 1) }
        return other + Self.urgency(of: tile.mapRect, coarse: coarse, visible: visible)
    }

    /// How far off the screen tiles are fetched before the map comes near them: a quarter of its size.
    static let marginShare = 0.25

    nonisolated static func urgency(of rect: MKMapRect, coarse: Bool, visible: MKMapRect) -> Double {
        let size = max(visible.width, visible.height)
        let gap = hypot(max(0, max(visible.minX - rect.maxX, rect.minX - visible.maxX)),
                        max(0, max(visible.minY - rect.maxY, rect.minY - visible.maxY))) / size
        guard gap <= marginShare else { return .infinity }
        let centre = hypot(rect.midX - visible.midX, rect.midY - visible.midY) / size
        return (gap > 0 ? 10 + gap * 10 : 0) + (coarse ? 0 : 1) + centre * 0.1
    }

    /// The map's rectangle in view, kept for the loader's order: read on the main thread, asked for from MapKit's.
    private func noteVisibleSoon() {
        let schedule = state.withLock { state -> Bool in
            guard !state.visibleRefreshPending else { return false }
            state.visibleRefreshPending = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in self?.noteVisible() }
    }

    private func noteVisible() {
        let visible = mapView?.visibleMapRect
        state.withLock { state in
            state.visible = visible
            state.visibleRefreshPending = false
        }
        loader.reconsider()
    }

    /// The tile came (or failed, or wasn't fetched): its rectangle redrawn at the zoom scales that wanted it. A failed
    /// tile is drawn around (a stand-in, or nothing) and asked again after its backoff, while still wanted.
    func arrived(_ tile: ChartTile, _ outcome: ChartTileOutcome) {
        #if DEBUG
        TileLog.line("got \(tile) \(outcome)")
        #endif
        switch outcome {
        case .passedBy:
            state.withLock { _ = $0.wanted.removeValue(forKey: tile) }
        case .image, .empty:
            let scales = state.withLock { $0.wanted.removeValue(forKey: tile) } ?? []
            for scale in scales { invalidate(tile.mapRect, zoomScale: scale) }
        case .failed:
            let scales = state.withLock { $0.wanted[tile] } ?? []
            for scale in scales { invalidate(tile.mapRect, zoomScale: scale) }
            guard let spec = source.spec(for: tile) else { return }
            let wait = loader.retryDelay(for: spec.key) ?? ChartTileLoader.backoff(after: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.retry(tile) }
        }
    }

    private func retry(_ tile: ChartTile) {
        guard wants(tile), let spec = source.spec(for: tile),
              let scales = state.withLock({ $0.wanted.removeValue(forKey: tile) }) else { return }
        for scale in scales { request(tile, spec: spec, zoomScale: scale, coarse: false) }
    }

    /// Redraws `mapRect` at `zoomScale`. A seam for the tests.
    func invalidate(_ mapRect: MKMapRect, zoomScale: MKZoomScale) {
        setNeedsDisplay(mapRect, zoomScale: zoomScale)
    }
}

#if DEBUG
// MARK: - The map settled (DEBUG)

extension ChartTileRenderer {
    /// Whether a tile of the zoom drawn, on screen, is still to come: asked, on its way, or failed and asked again.
    var awaitsTilesInView: Bool {
        state.withLock { state in
            guard let visible = state.visible else { return false }
            return state.wanted.contains { tile, scales in
                tile.mapRect.intersects(visible) && scales.contains { ChartTile.zoom(for: $0) == state.zoom }
            }
        }
    }
}

/// The screenshot run's "map settled" signal (`AEROCHECK_MAP_SETTLE=1`): a Darwin notification every half second
/// while each chart map in a window has kept its camera for 1.5 s and has every tile in view, none while one moves
/// or waits. The tour's `mapSettled` step waits for it instead of a fixed time. Inert without the key. (6.6.0)
@MainActor
enum MapSettle {
    static let signal = "com.fetzu.aerocheck.debug.mapSettled"
    static let isOn = ProcessInfo.processInfo.environment["AEROCHECK_MAP_SETTLE"] == "1"

    private static let renderers = NSHashTable<ChartTileRenderer>.weakObjects()
    private static var watching = false

    /// What a map shows: its rectangle and heading, the same within a thousandth of the rectangle.
    private struct View {
        let rect: MKMapRect
        let heading: Double

        func isClose(to other: View) -> Bool {
            let tolerance = max(rect.width, rect.height) * 0.001
            return abs(rect.minX - other.rect.minX) <= tolerance && abs(rect.minY - other.rect.minY) <= tolerance
                && abs(rect.width - other.rect.width) <= tolerance && abs(heading - other.heading) < 0.5
        }
    }

    static func watch(_ renderer: ChartTileRenderer) {
        guard isOn else { return }
        renderers.add(renderer)
        guard !watching else { return }
        watching = true
        Task { @MainActor in
            var last: [ObjectIdentifier: View] = [:]
            var calm = 0
            while true {
                try? await Task.sleep(for: .milliseconds(500))
                let shown = renderers.allObjects.filter { $0.mapView?.window != nil }
                var views: [ObjectIdentifier: View] = [:]
                for renderer in shown {
                    guard let map = renderer.mapView else { continue }
                    views[ObjectIdentifier(map)] = View(rect: map.visibleMapRect, heading: map.camera.heading)
                }
                let still = !views.isEmpty && views.count == last.count
                    && views.allSatisfy { key, view in last[key].map(view.isClose) ?? false }
                calm = still && !shown.contains(where: \.awaitsTilesInView) ? calm + 1 : 0
                last = views
                if calm >= 3 {
                    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                         CFNotificationName(signal as CFString), nil, nil, true)
                }
            }
        }
    }
}

// MARK: - The tile log (DEBUG)

/// The tiles the renderers ask for and get, and what MapKit asks them, as notices (`AEROCHECK_TILE_LOG=1`); and an
/// artificial network delay per tile (`AEROCHECK_TILE_DELAY_MS`), a phone's connection on the simulator. For the map
/// runs (CLAUDE/review/2026-10-19-map-tiles); inert without them. (6.4.2)
enum TileLog {
    static let isOn = ProcessInfo.processInfo.environment["AEROCHECK_TILE_LOG"] == "1"
    static let delayNanoseconds = UInt64(ProcessInfo.processInfo.environment["AEROCHECK_TILE_DELAY_MS"]
        .flatMap(Int.init) ?? 0) * 1_000_000
    private static let start = Date()

    static func line(_ text: @autoclosure () -> String) {
        guard isOn else { return }
        AppLog.general.publicNotice(String(format: "TILE %.3f ", Date().timeIntervalSince(start)) + text())
    }
}
#endif
