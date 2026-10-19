import Foundation
import ImageIO
import MapKit
import os

// MARK: - Swisstopo / swisstopo WMTS tile overlays (shared)

// The single source of truth for the app's swisstopo WMTS tile overlays. Previously duplicated as
// `WaypointPickerICAOTileOverlay`/`WaypointPickerSwisstopoTileOverlay` in FlightPlanEditorView; all
// map consumers (NavigationView, the flight mini-map, the flight-plan editor + map builder) now use
// these. Use default args for a simple online overlay; pass an `OfflineMapManager` for the cache-first
// behavior the main navigation map needs. (v4 UI/UX Revamp design-system consolidation)

// MARK: - The swisstopo tile endpoint

/// Every swisstopo WMTS tile the app downloads goes through here: the two overlays below (both nav
/// map representables, the planning editor and the route builder), the share card's map and the
/// offline chart download. One host, one ceiling, all through `ExternalRequest`: its 15 s timeout,
/// its streaming size cap and its host allow-list. The on-screen tiles used a bare
/// `URLSession.shared` (the ICAO overlay) or MapKit's own loader (the other layers), neither with
/// a size cap. (6.1)
enum SwisstopoTiles {
    /// The only host a tile is fetched from, and the whole of its allow-list.
    static let host = "wmts.geo.admin.ch"

    /// Response ceiling for one tile, every layer.
    ///
    /// Measured 1 Oct 2026 over the Swiss bounding box, 2,062 tiles at z8 to z13 (every tile to z10,
    /// a regular sample above), plus z7 and spot checks to z18; every response had a Content-Length,
    /// none was redirected. The aviation charts are the heavy ones (PNG): largest 206,997 bytes for
    /// the glider chart (z9) and 206,375 for the ICAO chart (z8), medians 95 to 185 KB. The national
    /// map peaks at 42,694 bytes and SWISSIMAGE at 33,881 (JPEG). 512 KiB leaves 2.5 times the
    /// largest chart tile for a denser edition (a refused tile is a hole in the chart, in flight),
    /// and 12 times the largest JPEG.
    static let maxTileBytes = 512 * 1024

    /// The EPSG:3857 tile URL of `layer`.
    static func url(layer: String, z: Int, x: Int, y: Int, fileExtension: String) -> URL? {
        URL(string: "https://\(host)/1.0.0/\(layer)/default/current/3857/\(z)/\(x)/\(y).\(fileExtension)")
    }

    /// One tile through `ExternalRequest`: capped at `maxTileBytes` (a declared length over it is
    /// refused before the body), refused outright off `host` or on a redirect away from it.
    /// `session` is the shared one unless a caller has its own (the offline download's bulk session);
    /// `maxRetries` 0 leaves the retries to the caller.
    static func fetch(_ url: URL, session: URLSession = ExternalRequest.session,
                      maxRetries: Int = ExternalRequest.maxRetries) async throws -> (Data, HTTPURLResponse) {
        try await ExternalRequest.data(from: url, session: session, maxRetries: maxRetries,
                                       maxResponseBytes: maxTileBytes, allowedHosts: [host])
    }

    /// `MKTileOverlay.loadTile` for a network tile: the data of a 200, nil for any other status, the
    /// error when it fails, as the ICAO overlay's own `URLSession` task answered before. `dropsBlank`:
    /// nil for a plain white tile too (`isBlank`). Through `gate`, newest first, and kept in `memory`.
    ///
    /// `stillWanted`, asked when its turn comes: false for a zoom the map has left, which isn't fetched and goes to
    /// `passedBy` as failed (for MapKit to ask again if the map comes back to it), not through `result` and its
    /// redraw, which would only blank the zoom in view for a frame. (6.4.2)
    static func load(_ url: URL, session: URLSession = ExternalRequest.session, dropsBlank: Bool = false,
                     gate: TileGate = .shared, while stillWanted: @escaping () -> Bool = { true },
                     result: @escaping (Data?, Error?) -> Void,
                     passedBy: ((Data?, Error?) -> Void)? = nil) {
        Task {
            guard let (tile, error) = await fetchTile(url, session: session, dropsBlank: dropsBlank, gate: gate,
                                                      while: stillWanted) else {
                (passedBy ?? result)(nil, URLError(.cancelled))
                return
            }
            result(tile, error)
        }
    }

    /// One tile through `gate`, kept in `memory`; nil when `stillWanted` said no before its turn came.
    private static func fetchTile(_ url: URL, session: URLSession, dropsBlank: Bool, gate: TileGate,
                                  while stillWanted: @escaping () -> Bool = { true }) async -> (Data?, Error?)? {
        guard await gate.enter(while: stillWanted) else { return nil }
        do {
            let (data, response) = try await fetch(url, session: session)
            let tile = response.statusCode == 200 && !(dropsBlank && isBlank(data)) ? data : nil
            // A client error is for good (a tile past the layer's edge): kept as no tile, as a blank one is.
            if response.statusCode == 200 || (400..<500).contains(response.statusCode) { remember(tile, for: url) }
            await gate.leave()
            return (tile, nil)
        } catch {
            await gate.leave()
            return (nil, error)
        }
    }

    // MARK: Tiles kept in memory (6.4.2)

    /// The on-screen tiles fetched this session, by URL; an empty one is no tile. MapKit asks again for
    /// tiles it already drew, or dropped on arrival, at every redraw (`LateTileRedraw`), pan or zoom back:
    /// answered from here at once, they always draw (MapKit draws every tile handed over synchronously,
    /// as from the offline cache). Fetched again over the network, they came in one by one, the map
    /// showing Apple's underneath between them: the "flashing" of the author's device check mp-2.
    static let memory: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.totalCostLimit = memoryBytes
        return cache
    }()

    /// About 400 chart tiles at their median, 1,500 National Map tiles.
    static let memoryBytes = 64 * 1024 * 1024

    /// The tile kept for `url`: nil when none is kept, `.some(nil)` when it is kept as no tile.
    static func remembered(_ url: URL) -> Data?? {
        guard let kept = memory.object(forKey: url as NSURL) else { return nil }
        return .some(kept.length == 0 ? nil : kept as Data)
    }

    static func remember(_ tile: Data?, for url: URL) {
        let data = (tile ?? Data()) as NSData
        memory.setObject(data, forKey: url as NSURL, cost: max(data.length, 64))
    }

    /// Outside Switzerland, past its small scales, the National Map's server answers a plain white JPEG
    /// (668 bytes, measured 19 Oct 2026 at Lyon and Besançon, z12 to z17), where the charts answer a
    /// transparent PNG and both answer 400 further out. Taken as no tile, so Apple's map shows through
    /// (the route builder, 6.4.2). A tile that small and white everywhere; any drawing is larger.
    static let blankTileMaxBytes = 2_048

    static func isBlank(_ data: Data) -> Bool {
        guard data.count <= blankTileMaxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn && pixels.allSatisfy { $0 >= 250 }
    }
}

/// The zoom MapKit asked an overlay's tiles for last: where the map is now. A tile two zooms or more from it is
/// one a pinch passed through. The next zoom up or down is not: MapKit asks for both at once between two zooms,
/// and the first load left holes when they were passed by (the simulator, 19 Oct 2026). (6.4.2)
final class ZoomInView: Sendable {
    private let latest = OSAllocatedUnfairLock(initialState: -1)

    /// MapKit asks for a tile at `z`.
    func asked(_ z: Int) { latest.withLock { $0 = z } }

    /// Whether `z` is within a zoom of the one asked for last.
    func isCurrent(_ z: Int) -> Bool { latest.withLock { $0 < 0 || abs($0 - z) <= 1 } }
}

/// The on-screen tiles' network requests, `limit` at a time and the newest first. A long pinch asks MapKit for
/// every zoom it passes through, hundreds of tiles it never takes back; in the order asked, the zoom the pinch
/// ended at came last, after the levels it had passed, and its last tiles could time out into holes (the
/// author's device check mp-2, 19 Oct 2026). The newest are where the map is now. (6.4.2)
actor TileGate {
    static let shared = TileGate(limit: 8)

    let limit: Int
    private var running = 0
    private struct Waiter {
        let wanted: () -> Bool
        let resume: CheckedContinuation<Bool, Never>
    }
    private var waiting: [Waiter] = []

    init(limit: Int) {
        self.limit = limit
    }

    /// Waits for a place: at once under `limit`, else after every request asked since. False, without a place,
    /// when `wanted` says no by its turn: a zoom the map has left.
    func enter(while wanted: @escaping () -> Bool = { true }) async -> Bool {
        if running < limit {
            running += 1
            return true
        }
        return await withCheckedContinuation { waiting.append(Waiter(wanted: wanted, resume: $0)) }
    }

    /// The place goes to the newest still wanted; the ones no longer wanted on the way are let go.
    func leave() {
        while let newest = waiting.popLast() {
            if newest.wanted() {
                newest.resume.resume(returning: true)
                return
            }
            newest.resume.resume(returning: false)
        }
        running -= 1
    }

    /// For the tests: requests waiting.
    var waitingCount: Int { waiting.count }
}

// MARK: - Tiles MapKit drops

/// Redraws a tile overlay once tiles have come in over the network, so MapKit asks again for the
/// ones it dropped.
///
/// MapKit drops some of the tiles `loadTile` hands it asynchronously, and doesn't ask for them again
/// until the map is redrawn (a pan, a zoom). On a map that doesn't move, those tiles stay holes: Plan ›
/// Map after a relaunch, on a cold HTTP cache, often showed the ICAO chart with half its tiles missing
/// or none at all. Measured on the simulator (2 Oct 2026, on 6.0.1, before #243 and on 6.1.0): every
/// tile answered 200 with its PNG and `result` ran once per tile (on the main thread or off it, no
/// difference), yet MapKit drew a random subset; the same tiles handed over synchronously, from the
/// offline chart cache, drew every time. A redraw (`setNeedsDisplay`) makes MapKit request exactly
/// the missing tiles again, and they draw. The Cockpit's map rarely shows it: following the aircraft
/// moves the camera, which redraws.
///
/// One redraw per burst of tiles, `settle` after the last one. MapKit answers a redraw with the
/// missing tiles, and with a few it already drew (four of 36 in the runs), so the tiles it asks for
/// within `answerWindow` of a redraw call for no other: without that, each redraw called for the
/// next. When a redraw gets no answer at all by `followUp`, MapKit has stopped listening (5 of 76
/// warm-cache relaunches: the map blank, a second redraw ignored too) and `reloadData` brings the
/// tiles back (it did, all three times it ran). `maxRedraws` per `window` is the backstop. (6.1.0)
///
/// The tiles a redraw asks for again come from `SwisstopoTiles.memory`, at once, and the reload comes only
/// while MapKit has never answered a redraw: after every zoom it blanked the map for a frame, every tile at once,
/// when nothing was missing (nothing to ask for is no answer), the second of the author's "flashes" (device check
/// mp-2, measured on the simulator 19 Oct 2026). Repainting a burst's tiles alone (`setNeedsDisplay(_:)`) left
/// the dropped ones holes: MapKit asks again only on a whole redraw. (6.4.2)
@MainActor
final class LateTileRedraw {
    /// Quiet time after the last tile before the redraw.
    nonisolated static let settle: TimeInterval = 0.3
    /// A tile MapKit asks for this soon after a redraw is the redraw's answer (it came within 60 ms
    /// in the runs).
    nonisolated static let answerWindow: TimeInterval = 0.25
    /// How long a redraw may go unanswered before the reload.
    nonisolated static let followUp: TimeInterval = 1
    /// Redraws and reloads allowed per `window`.
    nonisolated static let maxRedraws = 4
    nonisolated static let window: TimeInterval = 10

    /// The renderer drawing the overlay. Set by the map delegate that makes it
    /// (`LateTileRedraw.renderer(for:)`); MapKit keeps it alive while the overlay is on the map.
    weak var renderer: MKTileOverlayRenderer?
    /// `settle` and `followUp`, shorter in tests.
    var settleDelay: TimeInterval = LateTileRedraw.settle
    var followUpDelay: TimeInterval = LateTileRedraw.followUp

    private var pending: Task<Void, Never>?
    private var redraws: [Date] = []

    /// The last redraw and the tiles MapKit asked for since. Written on MapKit's tile threads too,
    /// hence the lock.
    private struct Ledger {
        var lastRedraw: Date?
        var askedSince = 0
    }
    private nonisolated let ledger = OSAllocatedUnfairLock(initialState: Ledger())
    /// MapKit answered a redraw once: it listens, and a later redraw it doesn't answer had nothing missing. (6.4.2)
    private var everAnswered = false

    nonisolated init() {}

    /// MapKit asks for a tile (every `loadTile`, cached or not): counted, so a redraw it answers isn't
    /// taken for ignored. Whether it answers our last redraw. Any thread.
    nonisolated func tileAsked() -> Bool {
        let now = Date()
        return ledger.withLock { ledger -> Bool in
            guard let lastRedraw = ledger.lastRedraw else { return false }
            ledger.askedSince += 1
            return Self.isAnswer(requestedAt: now, lastRedraw: lastRedraw)
        }
    }

    /// MapKit's `result` for a tile fetched over the network, wrapped: it hands the tile over, then
    /// asks for a redraw after the burst, unless the tile came back empty (a redraw would only ask for
    /// it again) or answers a redraw (`tileAsked()`). A tile that failed asks for one too: the redraw
    /// asks for it again, where it stayed a hole until the next pan (the author's device check mp-2,
    /// 6.4.2).
    nonisolated func handingOver(_ result: @escaping (Data?, Error?) -> Void,
                                 answering answersRedraw: Bool) -> (Data?, Error?) -> Void {
        { [self] data, error in
            result(data, error)
            if data != nil || error != nil, !answersRedraw { tileArrived() }
        }
    }

    /// A tile was just handed to MapKit, after `loadTile` returned. Any thread.
    nonisolated func tileArrived() {
        Task { @MainActor in self.schedule() }
    }

    /// Whether a tile MapKit asked for at `requestedAt` answers the redraw that went out at `lastRedraw`.
    nonisolated static func isAnswer(requestedAt: Date, lastRedraw: Date?) -> Bool {
        guard let lastRedraw else { return false }
        let delay = requestedAt.timeIntervalSince(lastRedraw)
        return delay >= 0 && delay < answerWindow
    }

    /// Whether one more redraw fits under the cap, given the times of the previous ones.
    nonisolated static func mayRedraw(after previous: [Date], at now: Date) -> Bool {
        previous.filter { now.timeIntervalSince($0) < window }.count < maxRedraws
    }

    /// How long until the cap frees a redraw: the oldest in the window leaving it. Nil when one fits now.
    nonisolated static func waitForRedraw(after previous: [Date], at now: Date) -> TimeInterval? {
        guard !mayRedraw(after: previous, at: now),
              let oldest = previous.filter({ now.timeIntervalSince($0) < window }).min() else { return nil }
        return window - now.timeIntervalSince(oldest) + 0.05
    }

    /// A renderer for `overlay`, hooked to its redraw when it has one. Every map delegate that draws a
    /// swisstopo or OpenAIP overlay makes its tile renderers here.
    static func renderer(for overlay: MKTileOverlay) -> MKTileOverlayRenderer {
        let renderer = MKTileOverlayRenderer(tileOverlay: overlay)
        (overlay as? LateTileRedrawing)?.redraw.renderer = renderer
        return renderer
    }

    /// The redraw `settle` after this tile, then the reload if MapKit didn't answer it; a later tile
    /// starts over.
    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self, settleDelay, followUpDelay] in
            try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
            guard !Task.isCancelled, let redraw = self else { return }
            if !redraw.redraw(reload: false) {
                // Over the cap, the redraw waits for the window to free one rather than never coming: a long
                // pinch through several zooms spends the cap, and the route builder's chart kept its last
                // dropped tiles as holes until the next pan (device check, 19 Oct 2026). (6.4.2)
                guard redraw.renderer != nil,
                      let wait = Self.waitForRedraw(after: redraw.redraws, at: Date()) else { return }
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled, redraw.redraw(reload: false) else { return }
            }
            try? await Task.sleep(nanoseconds: UInt64(followUpDelay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if self.ledger.withLock({ $0.askedSince }) > 0 {
                self.everAnswered = true
                return
            }
            // Unanswered, from a MapKit that answers redraws: nothing was missing. (6.4.2)
            guard !self.everAnswered else { return }
            self.redraw(reload: true)
        }
    }

    /// Redraws (or reloads) the renderer if the cap allows; whether it did.
    @discardableResult
    private func redraw(reload: Bool) -> Bool {
        guard let renderer else { return false }
        let now = Date()
        guard Self.mayRedraw(after: redraws, at: now) else { return false }
        redraws = redraws.filter { now.timeIntervalSince($0) < Self.window } + [now]
        ledger.withLock { $0 = Ledger(lastRedraw: now) }
        if reload { renderer.reloadData() } else { renderer.setNeedsDisplay() }
        return true
    }
}

/// A tile overlay that loads tiles over the network and redraws after them (`LateTileRedraw`).
protocol LateTileRedrawing: MKTileOverlay {
    var redraw: LateTileRedraw { get }
}

// MARK: - ICAO + Segelflugkarte Tile Overlay (with seamless switching)

/// Custom tile overlay for Swiss ICAO aeronautical chart with seamless Segelflugkarte switching
/// - ICAO Chart (ch.bazl.luftfahrtkarten-icao): zoom 7-10, scale 1:500,000 (7-11 when forced)
/// - Segelflugkarte (ch.bazl.segelflugkarte): zoom 11-12, scale 1:300,000
/// - With `continuesToNationalMap` (the route builder), the National Map from zoom 13 to 18
/// When forceICAO is true, always use ICAO layer even at higher zoom levels
/// When offlineMapManager is provided, use cached tiles from disk (cache-first in online mode)
/// When isStrictOfflineMode is true, only use cached tiles (no network requests)
class ICAOSegelflugkarteTileOverlay: MKTileOverlay, LateTileRedrawing {
    private let icaoLayerIdentifier = "ch.bazl.luftfahrtkarten-icao"
    private let segelflugkarteLayerIdentifier = "ch.bazl.segelflugkarte"
    let forceICAO: Bool
    weak var offlineMapManager: OfflineMapManager?
    let isStrictOfflineMode: Bool
    let hasSegelflugCache: Bool
    let redraw = LateTileRedraw()
    /// The zoom MapKit asks for now: a tile of another one, still waiting its turn, isn't fetched. (6.4.2)
    let zoom = ZoomInView()
    /// The session network tiles come over; a stub in tests.
    var tileSession = ExternalRequest.session

    /// Past the glider chart's last zoom, the National Map (the route builder's chart). (6.4.2)
    let continuesToNationalMap: Bool

    // Zoom level where we switch from ICAO to Segelflugkarte
    // ICAO: zoom 7-11 (1:500,000), 7-10 unless forced
    // Segelflugkarte: zoom 11-12 (1:300,000) - swisstopo only provides up to zoom 12
    private let icaoMinZoom = 7
    private let icaoMaxZoom = 11
    private let segelflugkarteMinZoom = ICAOSegelflugkarteTileOverlay.gliderMinZoom
    private let segelflugkarteMaxZoom = 12

    /// The glider chart from this zoom: its 1:300,000 at z11 is sharper than the 1:500,000 ICAO chart enlarged
    /// to it, and both are cached there (`CacheableLayer`). Until 6.4.2 from z12, which the maps' closest zoom
    /// seldom reached: the author never saw the glider chart in the route builder or the Cockpit's MAP (device
    /// check, 19 Oct 2026). CHART OFFLINE reads the same (`ChartAvailability`).
    static let gliderMinZoom = 11
    /// The National Map after the glider chart, with `continuesToNationalMap`. (6.4.2)
    static let nationalMapMinZoom = 13
    static let nationalMapLayerIdentifier = "ch.swisstopo.pixelkarte-farbe"

    init(forceICAO: Bool = false, offlineMapManager: OfflineMapManager? = nil, isStrictOfflineMode: Bool = false,
         hasSegelflugCache: Bool = false, continuesToNationalMap: Bool = false) {
        self.forceICAO = forceICAO
        self.offlineMapManager = offlineMapManager
        self.isStrictOfflineMode = isStrictOfflineMode
        self.hasSegelflugCache = hasSegelflugCache
        self.continuesToNationalMap = continuesToNationalMap && !forceICAO && !isStrictOfflineMode
        // Use a placeholder URL template - we override loadTile(at:result:) for cache-first loading
        let urlTemplate = "https://wmts.geo.admin.ch/1.0.0/ch.bazl.luftfahrtkarten-icao/default/current/3857/{z}/{x}/{y}.png"
        super.init(urlTemplate: urlTemplate)

        // Set tile overlay zoom constraints to match the camera zoom range
        // This helps MapKit understand the valid tile range
        self.minimumZ = icaoMinZoom

        // In strict offline mode with only ICAO cache, limit to ICAO range
        // In strict offline mode with both caches (or forceICAO off), allow Segelflug range
        if forceICAO {
            self.maximumZ = icaoMaxZoom
        } else if isStrictOfflineMode {
            self.maximumZ = hasSegelflugCache ? segelflugkarteMaxZoom : icaoMaxZoom
        } else {
            self.maximumZ = self.continuesToNationalMap ? 18 : segelflugkarteMaxZoom
        }
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        // This is called as fallback - loadTile handles cache-first logic
        let (layerIdentifier, finalZ) = layerInfo(for: path)
        return SwisstopoTiles.url(layer: layerIdentifier, z: finalZ, x: path.x, y: path.y,
                                  fileExtension: Self.fileExtension(of: layerIdentifier))
            ?? URL(string: "about:blank")!
    }

    /// The charts are PNG, the National Map JPEG.
    private static func fileExtension(of layer: String) -> String { layer == nationalMapLayerIdentifier ? "jpeg" : "png" }

    /// Override loadTile to implement cache-first loading strategy
    /// This provides instant loading from cache while falling back to network when needed
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let answersRedraw = redraw.tileAsked()
        // Determine which layer to use based on zoom and settings
        let (layerIdentifier, finalZ) = layerInfo(for: path)

        // Determine if this tile should come from ICAO or Segelflug based on the layer
        let isICAOTile = layerIdentifier == icaoLayerIdentifier

        // Try cache first when we have a cache manager (the charts; the National Map isn't cached)
        if let manager = offlineMapManager, layerIdentifier != Self.nationalMapLayerIdentifier {
            if isICAOTile {
                // Check for cached ICAO tile
                if let cachedURL = manager.cachedTileURL(z: finalZ, x: path.x, y: path.y, layer: .icao),
                   let data = try? Data(contentsOf: cachedURL) {
                    // Cache hit - return immediately (this is why offline mode is fast!)
                    result(data, nil)
                    return
                }
            } else {
                // Check for cached Segelflug tile
                if let cachedURL = manager.cachedTileURL(z: finalZ, x: path.x, y: path.y, layer: .segelflug),
                   let data = try? Data(contentsOf: cachedURL) {
                    result(data, nil)
                    return
                }
            }
        }

        // In strict offline mode, don't make network requests
        if isStrictOfflineMode {
            // Return empty data for tiles not in cache
            result(nil, nil)
            return
        }

        // Cache miss - fetch from network, through ExternalRequest (cap, timeout, host allow-list).
        // This was a bare URLSession.shared dataTask with none of them.
        let isNationalMap = layerIdentifier == Self.nationalMapLayerIdentifier
        guard let url = SwisstopoTiles.url(layer: layerIdentifier, z: finalZ, x: path.x, y: path.y,
                                           fileExtension: Self.fileExtension(of: layerIdentifier)) else {
            result(nil, nil)
            return
        }
        // Fetched already this session: at once, so it draws. (6.4.2)
        if let kept = SwisstopoTiles.remembered(url) {
            result(kept, nil)
            return
        }
        // MapKit may drop a tile that arrives this late: redraw after the burst. (6.1.0) The National Map's white
        // tiles outside Switzerland are none, for Apple's map to show through. (6.4.2)
        zoom.asked(path.z)
        let zoom = zoom, z = path.z
        SwisstopoTiles.load(url, session: tileSession, dropsBlank: isNationalMap, while: { zoom.isCurrent(z) },
                            result: redraw.handingOver(result, answering: answersRedraw), passedBy: result)
    }

    /// Determine which layer and zoom to use for a given tile path
    private func layerInfo(for path: MKTileOverlayPath) -> (layerIdentifier: String, finalZ: Int) {
        let z = path.z

        if forceICAO {
            // Force ICAO at all zoom levels - clamp to ICAO's valid range
            let finalZ = min(max(z, icaoMinZoom), icaoMaxZoom)
            return (icaoLayerIdentifier, finalZ)
        } else if isStrictOfflineMode && !hasSegelflugCache {
            // Offline mode with only ICAO cache - force ICAO
            let finalZ = min(max(z, icaoMinZoom), icaoMaxZoom)
            return (icaoLayerIdentifier, finalZ)
        } else {
            // Seamless switching between ICAO and Segelflugkarte
            // Works in both online mode and offline mode with both caches
            if z < segelflugkarteMinZoom {
                // Use ICAO chart for lower zoom levels
                let finalZ = min(max(z, icaoMinZoom), icaoMaxZoom)
                return (icaoLayerIdentifier, finalZ)
            } else if continuesToNationalMap && z >= Self.nationalMapMinZoom {
                return (Self.nationalMapLayerIdentifier, min(z, 18))
            } else {
                // Use Segelflugkarte for higher zoom levels
                let finalZ = min(max(z, segelflugkarteMinZoom), segelflugkarteMaxZoom)
                return (segelflugkarteLayerIdentifier, finalZ)
            }
        }
    }
}

// MARK: - Swisstopo Tile Overlay

/// Custom tile overlay for swisstopo WMTS layers
class SwisstopoTileOverlay: MKTileOverlay, LateTileRedrawing {
    let layerIdentifier: String
    let tileExtension: String
    let validMinZoom: Int
    let validMaxZoom: Int
    /// A plain white tile is none (`SwisstopoTiles.isBlank`): the National Map's outside Switzerland, where the
    /// route builder shows Apple's map instead. (6.4.2)
    let dropsBlankTiles: Bool
    let redraw = LateTileRedraw()
    /// The zoom MapKit asks for now: a tile of another one, still waiting its turn, isn't fetched. (6.4.2)
    let zoom = ZoomInView()
    /// The session tiles come over; a stub in tests.
    var tileSession = ExternalRequest.session

    init(layerIdentifier: String, tileExtension: String = "png", minimumZ: Int = 7, maximumZ: Int = 18,
         dropsBlankTiles: Bool = false) {
        self.layerIdentifier = layerIdentifier
        self.tileExtension = tileExtension
        self.dropsBlankTiles = dropsBlankTiles
        self.validMinZoom = minimumZ
        self.validMaxZoom = maximumZ

        // Swisstopo WMTS URL template
        // Using the EPSG:3857 (Web Mercator) projection which is compatible with MapKit
        let urlTemplate = "https://wmts.geo.admin.ch/1.0.0/\(layerIdentifier)/default/current/3857/{z}/{x}/{y}.\(tileExtension)"

        super.init(urlTemplate: urlTemplate)

        // Set proper zoom constraints to match the camera zoom range
        self.minimumZ = minimumZ
        self.maximumZ = maximumZ
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        // Clamp zoom level to valid range for this layer
        let clampedZ = min(max(path.z, validMinZoom), validMaxZoom)

        // Construct the URL for swisstopo tiles
        return SwisstopoTiles.url(layer: layerIdentifier, z: clampedZ, x: path.x, y: path.y, fileExtension: tileExtension)
            ?? URL(string: "about:blank")!
    }

    /// The tile at `url(forTilePath:)`, through `ExternalRequest` rather than MapKit's own loader,
    /// which had no size cap. Same URL, same tile. (6.1) MapKit may drop it on arrival, as it does the
    /// ICAO chart's: redraw after the burst. (6.1.0)
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let answersRedraw = redraw.tileAsked()
        let url = url(forTilePath: path)
        // Fetched already this session: at once, so it draws. (6.4.2)
        if let kept = SwisstopoTiles.remembered(url) {
            result(kept, nil)
            return
        }
        zoom.asked(path.z)
        let zoom = zoom, z = path.z
        SwisstopoTiles.load(url, session: tileSession, dropsBlank: dropsBlankTiles, while: { zoom.isCurrent(z) },
                            result: redraw.handingOver(result, answering: answersRedraw), passedBy: result)
    }
}
