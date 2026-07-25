import Foundation
import MapKit
import UIKit
import CoreGraphics

/// Custom tile overlay for OpenAIP aviation raster tiles
/// Renders airspace boundaries, airports, and navaids on top of any base map layer
/// Uses cache-first loading strategy with offline mode support
///
/// OpenAIP raster tiles contain semi-transparent airspace fills, boundary lines,
/// text labels, and symbols. Since we render our own polygon-based airspace fills
/// from structured API data, we strip the low-alpha fills from the raster tiles
/// to avoid visual grid artifacts (different tiles have different fill opacities
/// creating a visible checkerboard pattern). Only high-contrast features like
/// labels, lines, and symbols are preserved.
class OpenAIPTileOverlay: MKTileOverlay {
    weak var cacheManager: OpenAIPCacheManager?
    let isStrictOfflineMode: Bool

    /// Rotating subdomain index for load balancing
    private var subdomainIndex = 0
    private let subdomains = OpenAIPConfig.tileSubdomains

    /// Processed tiles memoized by z/x/y. The per-pixel alpha-strip (processedTile) is expensive and
    /// MapKit re-requests already-cached tiles on every pan/zoom; without this the strip re-ran each
    /// render. Bounded, and thread-safe since loadTile runs off the main thread. (v4.0.0 review P2)
    private let processedTileCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 512
        return cache
    }()

    /// A 256x256 fully transparent PNG used for empty/missing tiles.
    /// Returning this instead of nil ensures MapKit renders all tiles uniformly,
    /// preventing visible seams where some tiles load and others don't.
    /// Must be 256x256 to match the standard tile size and avoid scaling artifacts.
    private static let transparentTilePNG: Data = {
        let size = CGSize(width: 256, height: 256)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData() ?? Data()
    }()

    /// Minimum alpha threshold (0-255) for pixels to be kept visible.
    /// OpenAIP tiles use very low alpha values (7-54) for airspace region fills,
    /// which create visible grid artifacts when different tiles have different fill levels.
    /// Only pixels above this threshold (labels, lines, symbols) are preserved.
    /// 64 (~25% opacity) filters out the semi-transparent fills while keeping
    /// text, symbols, and boundary lines intact.
    private static let alphaThreshold: UInt8 = 64

    init(cacheManager: OpenAIPCacheManager? = nil, isStrictOfflineMode: Bool = false) {
        self.cacheManager = cacheManager
        self.isStrictOfflineMode = isStrictOfflineMode

        // Placeholder URL template — we override loadTile for cache-first logic, so MapKit never
        // fetches from this template itself. It carries NO api key (SA-11): the key goes in the
        // x-openaip-api-key header on the request built in loadTile, so it can never leak into a
        // URLCache entry, a proxy log, or OpenAIP's access logs.
        let urlTemplate = "https://a.api.tiles.openaip.net/api/data/openaip/{z}/{x}/{y}.png"
        super.init(urlTemplate: urlTemplate)

        self.minimumZ = OpenAIPConfig.tileMinZoom
        self.maximumZ = OpenAIPConfig.tileMaxZoom
        self.tileSize = CGSize(width: 256, height: 256)

        // This is an overlay, not a base layer replacement
        self.canReplaceMapContent = false
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        // Rotate subdomains for load balancing
        let subdomain = subdomains[abs(path.x + path.y) % subdomains.count]
        return OpenAIPConfig.tileURL(subdomain: subdomain, z: path.z, x: path.x, y: path.y)
            ?? URL(string: "about:blank")!
    }

    /// Cache-first tile loading: check disk cache before making network requests.
    /// All tiles are processed to remove low-alpha airspace fills before display.
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let z = path.z

        // If zoom is outside our supported range, return a transparent tile
        // Do NOT clamp to min/max because the tile x/y coordinates would be wrong
        // for the clamped zoom level, causing misaligned/mismatched tiles
        if z < OpenAIPConfig.tileMinZoom || z > OpenAIPConfig.tileMaxZoom {
            result(Self.transparentTilePNG, nil)
            return
        }

        // Serve an already-processed tile without re-running the pixel strip.
        let memoKey = "\(z)/\(path.x)/\(path.y)" as NSString
        if let memo = processedTileCache.object(forKey: memoKey) {
            result(memo as Data, nil)
            return
        }

        // Try cache first
        if let manager = cacheManager {
            if let cachedURL = manager.cachedTileURL(z: z, x: path.x, y: path.y),
               let data = try? Data(contentsOf: cachedURL) {
                let processed = Self.processedTile(from: data)
                processedTileCache.setObject(processed as NSData, forKey: memoKey)
                result(processed, nil)
                return
            }
        }

        // In strict offline mode, return transparent tile (no network requests)
        if isStrictOfflineMode {
            result(Self.transparentTilePNG, nil)
            return
        }

        // Cache miss - fetch from network with subdomain rotation. The key rides in a header
        // rather than the URL. (SA-11)
        let subdomain = subdomains[abs(path.x + path.y) % subdomains.count]
        guard let request = OpenAIPConfig.tileRequest(subdomain: subdomain, z: z, x: path.x, y: path.y) else {
            result(Self.transparentTilePNG, nil)
            return
        }

        let transparentPNG = Self.transparentTilePNG
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if error != nil {
                result(transparentPNG, nil)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data = data, !data.isEmpty else {
                result(transparentPNG, nil)
                return
            }

            let processed = Self.processedTile(from: data)
            self?.processedTileCache.setObject(processed as NSData, forKey: memoKey)
            result(processed, nil)
        }
        task.resume()
    }

    // MARK: - Tile Processing

    /// Remove low-alpha airspace fills from OpenAIP tiles while preserving
    /// high-contrast features (text labels, boundary lines, airport symbols, navaids).
    ///
    /// OpenAIP renders airspace region fills with very low alpha (7-54) that vary
    /// between adjacent tiles based on which airspaces overlap each tile. This creates
    /// visible rectangular grid artifacts on the map. Since we already render proper
    /// polygon-based airspace fills from the structured API, we only need the tiles
    /// for their labels and symbols — so we strip the low-alpha fill pixels.
    private static func processedTile(from pngData: Data) -> Data {
        guard let image = UIImage(data: pngData),
              let cgImage = image.cgImage else {
            return transparentTilePNG
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = height * bytesPerRow

        // Create a buffer for RGBA pixel data
        var pixelData = [UInt8](repeating: 0, count: totalBytes)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return transparentTilePNG
        }

        // Draw the original image into our RGBA buffer
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let threshold = alphaThreshold

        // Process pixels: make low-alpha fill pixels fully transparent
        for i in stride(from: 0, to: totalBytes, by: bytesPerPixel) {
            let alpha = pixelData[i + 3]

            if alpha < threshold {
                // Low-alpha pixel (airspace fill) — make fully transparent
                pixelData[i] = 0     // R
                pixelData[i + 1] = 0 // G
                pixelData[i + 2] = 0 // B
                pixelData[i + 3] = 0 // A
            }
            // High-alpha pixels (labels, lines, symbols) — keep as-is
        }

        // Create new image from processed pixel data
        guard let processedImage = context.makeImage() else {
            return transparentTilePNG
        }

        // Convert back to PNG data
        let uiImage = UIImage(cgImage: processedImage)
        return uiImage.pngData() ?? transparentTilePNG
    }
}
