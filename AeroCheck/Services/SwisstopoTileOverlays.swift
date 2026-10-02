import Foundation
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
    /// error when it fails, as the ICAO overlay's own `URLSession` task answered before.
    static func load(_ url: URL, session: URLSession = ExternalRequest.session,
                     result: @escaping (Data?, Error?) -> Void) {
        Task {
            do {
                let (data, response) = try await fetch(url, session: session)
                result(response.statusCode == 200 ? data : nil, nil)
            } catch {
                result(nil, error)
            }
        }
    }
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
    /// it again) or answers a redraw (`tileAsked()`).
    nonisolated func handingOver(_ result: @escaping (Data?, Error?) -> Void,
                                 answering answersRedraw: Bool) -> (Data?, Error?) -> Void {
        { [self] data, error in
            result(data, error)
            if data != nil, !answersRedraw { tileArrived() }
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

    /// A renderer for `overlay`, hooked to its redraw when it has one. Every map delegate that draws a
    /// swisstopo overlay makes its tile renderers here.
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
            guard !Task.isCancelled, self?.redraw(reload: false) == true else { return }
            try? await Task.sleep(nanoseconds: UInt64(followUpDelay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.ledger.withLock({ $0.askedSince }) == 0 else { return }
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
/// - ICAO Chart (ch.bazl.luftfahrtkarten-icao): zoom 7-11, scale 1:500,000
/// - Segelflugkarte (ch.bazl.segelflugkarte): zoom 11-12, scale 1:300,000
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
    /// The session network tiles come over; a stub in tests.
    var tileSession = ExternalRequest.session

    // Zoom level where we switch from ICAO to Segelflugkarte
    // ICAO: zoom 7-11 (1:500,000)
    // Segelflugkarte: zoom 11-12 (1:300,000) - swisstopo only provides up to zoom 12
    private let icaoMinZoom = 7
    private let icaoMaxZoom = 11
    private let segelflugkarteMinZoom = 11
    private let segelflugkarteMaxZoom = 12

    init(forceICAO: Bool = false, offlineMapManager: OfflineMapManager? = nil, isStrictOfflineMode: Bool = false, hasSegelflugCache: Bool = false) {
        self.forceICAO = forceICAO
        self.offlineMapManager = offlineMapManager
        self.isStrictOfflineMode = isStrictOfflineMode
        self.hasSegelflugCache = hasSegelflugCache
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
            self.maximumZ = segelflugkarteMaxZoom
        }
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        // This is called as fallback - loadTile handles cache-first logic
        let (layerIdentifier, finalZ) = layerInfo(for: path)
        return SwisstopoTiles.url(layer: layerIdentifier, z: finalZ, x: path.x, y: path.y, fileExtension: "png")
            ?? URL(string: "about:blank")!
    }

    /// Override loadTile to implement cache-first loading strategy
    /// This provides instant loading from cache while falling back to network when needed
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let answersRedraw = redraw.tileAsked()
        // Determine which layer to use based on zoom and settings
        let (layerIdentifier, finalZ) = layerInfo(for: path)

        // Determine if this tile should come from ICAO or Segelflug based on the layer
        let isICAOTile = layerIdentifier == icaoLayerIdentifier

        // Try cache first when we have a cache manager
        if let manager = offlineMapManager {
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
        guard let url = SwisstopoTiles.url(layer: layerIdentifier, z: finalZ, x: path.x, y: path.y,
                                           fileExtension: "png") else {
            result(nil, nil)
            return
        }
        // MapKit may drop a tile that arrives this late: redraw after the burst. (6.1.0)
        SwisstopoTiles.load(url, session: tileSession, result: redraw.handingOver(result, answering: answersRedraw))
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
            if z <= icaoMaxZoom {
                // Use ICAO chart for lower zoom levels
                let finalZ = min(max(z, icaoMinZoom), icaoMaxZoom)
                return (icaoLayerIdentifier, finalZ)
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
    let redraw = LateTileRedraw()
    /// The session tiles come over; a stub in tests.
    var tileSession = ExternalRequest.session

    init(layerIdentifier: String, tileExtension: String = "png", minimumZ: Int = 7, maximumZ: Int = 18) {
        self.layerIdentifier = layerIdentifier
        self.tileExtension = tileExtension
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
        SwisstopoTiles.load(url(forTilePath: path), session: tileSession,
                            result: redraw.handingOver(result, answering: redraw.tileAsked()))
    }
}
