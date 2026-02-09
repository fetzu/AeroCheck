import Foundation
import MapKit

/// Custom tile overlay for OpenAIP aviation raster tiles
/// Renders airspace boundaries, airports, and navaids on top of any base map layer
/// Uses cache-first loading strategy with offline mode support
class OpenAIPTileOverlay: MKTileOverlay {
    weak var cacheManager: OpenAIPCacheManager?
    let isStrictOfflineMode: Bool

    /// Rotating subdomain index for load balancing
    private var subdomainIndex = 0
    private let subdomains = OpenAIPConfig.tileSubdomains

    init(cacheManager: OpenAIPCacheManager? = nil, isStrictOfflineMode: Bool = false) {
        self.cacheManager = cacheManager
        self.isStrictOfflineMode = isStrictOfflineMode

        // Placeholder URL template - we override loadTile for cache-first logic
        let urlTemplate = "https://a.api.tiles.openaip.net/api/data/openaip/{z}/{x}/{y}.png?apiKey=\(OpenAIPConfig.apiKey)"
        super.init(urlTemplate: urlTemplate)

        self.minimumZ = OpenAIPConfig.tileMinZoom
        self.maximumZ = OpenAIPConfig.tileMaxZoom

        // This is an overlay, not a base layer replacement
        self.canReplaceMapContent = false
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        // Rotate subdomains for load balancing
        let subdomain = subdomains[abs(path.x + path.y) % subdomains.count]
        return OpenAIPConfig.tileURL(subdomain: subdomain, z: path.z, x: path.x, y: path.y)
            ?? URL(string: "about:blank")!
    }

    /// Cache-first tile loading: check disk cache before making network requests
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        // Clamp zoom to valid range
        let z = min(max(path.z, OpenAIPConfig.tileMinZoom), OpenAIPConfig.tileMaxZoom)

        // Try cache first
        if let manager = cacheManager {
            if let cachedURL = manager.cachedTileURL(z: z, x: path.x, y: path.y),
               let data = try? Data(contentsOf: cachedURL) {
                result(data, nil)
                return
            }
        }

        // In strict offline mode, don't make network requests
        if isStrictOfflineMode {
            result(nil, nil)
            return
        }

        // Cache miss - fetch from network with subdomain rotation
        let subdomain = subdomains[abs(path.x + path.y) % subdomains.count]
        guard let url = OpenAIPConfig.tileURL(subdomain: subdomain, z: z, x: path.x, y: path.y) else {
            result(nil, nil)
            return
        }

        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                result(nil, error)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data = data else {
                // HTTP 204 means no tile data for this zoom/position - return empty
                result(nil, nil)
                return
            }

            result(data, nil)
        }
        task.resume()
    }
}
