import Foundation
import ImageIO
import MapKit

// MARK: - Swisstopo / swisstopo WMTS tile overlays (shared)

// The single source of truth for the app's swisstopo WMTS tile overlays. Previously duplicated as
// `WaypointPickerICAOTileOverlay`/`WaypointPickerSwisstopoTileOverlay` in FlightPlanEditorView; all
// map consumers (NavigationView, the flight mini-map, the flight-plan editor + map builder) now use
// these. (v4 UI/UX Revamp design-system consolidation) Every map reads the downloaded charts first, and
// `ChartTileRenderer` draws the tiles. (6.4.2)

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

// MARK: - ICAO + Segelflugkarte Tile Overlay (with seamless switching)

/// Custom tile overlay for Swiss ICAO aeronautical chart with seamless Segelflugkarte switching
/// - ICAO Chart (ch.bazl.luftfahrtkarten-icao): zoom 7-10, scale 1:500,000 (7-11 when forced)
/// - Segelflugkarte (ch.bazl.segelflugkarte): zoom 11-12, scale 1:300,000
/// - With `continuesToNationalMap` (the route builder), the National Map from zoom 13 to 18
/// When forceICAO is true, always use ICAO layer even at higher zoom levels
/// The downloaded charts (`OfflineMapManager`) are read before the network, on every map: the route builder's too since
/// 6.4.2, where they came over the network again and there was no chart offline (the map tile review, F7).
/// When isStrictOfflineMode is true, only use cached tiles (no network requests)
/// Drawn by `ChartTileRenderer`, which enlarges the last zoom past `maximumZ`. (6.4.2)
class ICAOSegelflugkarteTileOverlay: MKTileOverlay, ChartTileSource {
    private let icaoLayerIdentifier = "ch.bazl.luftfahrtkarten-icao"
    private let segelflugkarteLayerIdentifier = "ch.bazl.segelflugkarte"
    let forceICAO: Bool
    let isStrictOfflineMode: Bool
    let hasSegelflugCache: Bool
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

    init(forceICAO: Bool = false, isStrictOfflineMode: Bool = false,
         hasSegelflugCache: Bool = false, continuesToNationalMap: Bool = false) {
        self.forceICAO = forceICAO
        self.isStrictOfflineMode = isStrictOfflineMode
        self.hasSegelflugCache = hasSegelflugCache
        self.continuesToNationalMap = continuesToNationalMap && !forceICAO && !isStrictOfflineMode
        // A placeholder: `spec(for:)` says where each tile comes from.
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

    /// The downloaded copy first (the charts; the National Map isn't downloaded), then the network unless offline. The
    /// National Map's white tiles outside Switzerland are none, for Apple's map to show through. (6.4.2)
    func spec(for tile: ChartTile) -> ChartTileSpec? {
        let (layerIdentifier, finalZ) = layerInfo(for: MKTileOverlayPath(x: tile.x, y: tile.y, z: tile.z, contentScaleFactor: 1))
        guard let url = SwisstopoTiles.url(layer: layerIdentifier, z: finalZ, x: tile.x, y: tile.y,
                                           fileExtension: Self.fileExtension(of: layerIdentifier)) else { return nil }
        let isNationalMap = layerIdentifier == Self.nationalMapLayerIdentifier
        var spec = ChartTileSpec(key: url.absoluteString, dropsBlank: isNationalMap)
        if !isNationalMap {
            let layer: CacheableLayer = layerIdentifier == icaoLayerIdentifier ? .icao : .segelflug
            spec.disk = OfflineMapManager.tileFileURL(z: finalZ, x: tile.x, y: tile.y, layer: layer)
        }
        if !isStrictOfflineMode {
            let session = tileSession
            spec.fetch = { try await SwisstopoTiles.fetch(url, session: session) }
        }
        return spec
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

/// Custom tile overlay for swisstopo WMTS layers, drawn by `ChartTileRenderer`. (6.4.2)
class SwisstopoTileOverlay: MKTileOverlay, ChartTileSource {
    let layerIdentifier: String
    let tileExtension: String
    let validMinZoom: Int
    let validMaxZoom: Int
    /// A plain white tile is none (`SwisstopoTiles.isBlank`): the National Map's outside Switzerland, where the
    /// route builder shows Apple's map instead. (6.4.2)
    let dropsBlankTiles: Bool
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

    /// The tile at `url(forTilePath:)`, through `ExternalRequest` rather than MapKit's own loader, which had no size
    /// cap. Same URL, same tile. (6.1)
    func spec(for tile: ChartTile) -> ChartTileSpec? {
        let url = url(forTilePath: MKTileOverlayPath(x: tile.x, y: tile.y, z: tile.z, contentScaleFactor: 1))
        let session = tileSession
        return ChartTileSpec(key: url.absoluteString, fetch: { try await SwisstopoTiles.fetch(url, session: session) },
                             dropsBlank: dropsBlankTiles)
    }
}
