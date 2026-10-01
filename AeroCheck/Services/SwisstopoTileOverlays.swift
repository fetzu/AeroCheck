import Foundation
import MapKit

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

// MARK: - ICAO + Segelflugkarte Tile Overlay (with seamless switching)

/// Custom tile overlay for Swiss ICAO aeronautical chart with seamless Segelflugkarte switching
/// - ICAO Chart (ch.bazl.luftfahrtkarten-icao): zoom 7-11, scale 1:500,000
/// - Segelflugkarte (ch.bazl.segelflugkarte): zoom 11-12, scale 1:300,000
/// When forceICAO is true, always use ICAO layer even at higher zoom levels
/// When offlineMapManager is provided, use cached tiles from disk (cache-first in online mode)
/// When isStrictOfflineMode is true, only use cached tiles (no network requests)
class ICAOSegelflugkarteTileOverlay: MKTileOverlay {
    private let icaoLayerIdentifier = "ch.bazl.luftfahrtkarten-icao"
    private let segelflugkarteLayerIdentifier = "ch.bazl.segelflugkarte"
    let forceICAO: Bool
    weak var offlineMapManager: OfflineMapManager?
    let isStrictOfflineMode: Bool
    let hasSegelflugCache: Bool

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
        SwisstopoTiles.load(url, result: result)
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
class SwisstopoTileOverlay: MKTileOverlay {
    let layerIdentifier: String
    let tileExtension: String
    let validMinZoom: Int
    let validMaxZoom: Int

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
    /// which had no size cap. Same URL, same tile. (6.1)
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        SwisstopoTiles.load(url(forTilePath: path), result: result)
    }
}
