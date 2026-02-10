import Foundation
import MapKit
import UIKit

/// Custom tile overlay for OpenAIP aviation raster tiles
/// Renders airspace boundaries, airports, and navaids on top of any base map layer
/// Uses cache-first loading strategy with offline mode support
class OpenAIPTileOverlay: MKTileOverlay {
    weak var cacheManager: OpenAIPCacheManager?
    let isStrictOfflineMode: Bool

    /// Rotating subdomain index for load balancing
    private var subdomainIndex = 0
    private let subdomains = OpenAIPConfig.tileSubdomains

    /// A 1x1 fully transparent PNG used for empty/missing tiles.
    /// Returning this instead of nil ensures MapKit renders all tiles uniformly,
    /// preventing visible grid artifacts where some tiles have OpenAIP's background
    /// tint and others are completely transparent.
    private static let transparentTilePNG: Data = {
        let size = CGSize(width: 1, height: 1)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData() ?? Data()
    }()

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
        let z = path.z

        // If zoom is outside our supported range, return a transparent tile
        // Do NOT clamp to min/max because the tile x/y coordinates would be wrong
        // for the clamped zoom level, causing misaligned/mismatched tiles
        if z < OpenAIPConfig.tileMinZoom || z > OpenAIPConfig.tileMaxZoom {
            result(Self.transparentTilePNG, nil)
            return
        }

        // Try cache first
        if let manager = cacheManager {
            if let cachedURL = manager.cachedTileURL(z: z, x: path.x, y: path.y),
               let data = try? Data(contentsOf: cachedURL) {
                result(data, nil)
                return
            }
        }

        // In strict offline mode, return transparent tile (no network requests)
        if isStrictOfflineMode {
            result(Self.transparentTilePNG, nil)
            return
        }

        // Cache miss - fetch from network with subdomain rotation
        let subdomain = subdomains[abs(path.x + path.y) % subdomains.count]
        guard let url = OpenAIPConfig.tileURL(subdomain: subdomain, z: z, x: path.x, y: path.y) else {
            result(Self.transparentTilePNG, nil)
            return
        }

        let transparentPNG = Self.transparentTilePNG
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if error != nil {
                // On network error, return transparent tile instead of error
                // to avoid rendering artifacts from partial tile loads
                result(transparentPNG, nil)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data = data, !data.isEmpty else {
                // HTTP 204 or other non-200 = no tile data for this position
                // Return transparent tile for uniform rendering
                result(transparentPNG, nil)
                return
            }

            result(data, nil)
        }
        task.resume()
    }
}
