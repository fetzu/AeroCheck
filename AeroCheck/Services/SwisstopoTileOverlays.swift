import Foundation
import MapKit

// MARK: - Swisstopo / swisstopo WMTS tile overlays (shared)

// The single source of truth for the app's swisstopo WMTS tile overlays. Previously duplicated as
// `WaypointPickerICAOTileOverlay`/`WaypointPickerSwisstopoTileOverlay` in FlightPlanEditorView; all
// map consumers (NavigationView, the flight mini-map, the flight-plan editor + map builder) now use
// these. Use default args for a simple online overlay; pass an `OfflineMapManager` for the cache-first
// behavior the main navigation map needs. (v4 UI/UX Revamp design-system consolidation)

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
        let urlString = "https://wmts.geo.admin.ch/1.0.0/\(layerIdentifier)/default/current/3857/\(finalZ)/\(path.x)/\(path.y).png"
        return URL(string: urlString) ?? URL(string: "about:blank")!
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

        // Cache miss - fetch from network
        let urlString = "https://wmts.geo.admin.ch/1.0.0/\(layerIdentifier)/default/current/3857/\(finalZ)/\(path.x)/\(path.y).png"

        guard let url = URL(string: urlString) else {
            result(nil, nil)
            return
        }

        // Use URLSession for network requests
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                result(nil, error)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data = data else {
                result(nil, nil)
                return
            }

            result(data, nil)
        }
        task.resume()
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
        let urlString = "https://wmts.geo.admin.ch/1.0.0/\(layerIdentifier)/default/current/3857/\(clampedZ)/\(path.x)/\(path.y).\(tileExtension)"
        return URL(string: urlString) ?? URL(string: "about:blank")!
    }
}
