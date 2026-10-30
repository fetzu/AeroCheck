import Foundation
import MapKit
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
class OpenAIPTileOverlay: MKTileOverlay, ChartTileSource {
    let isStrictOfflineMode: Bool
    /// The session network tiles come over; a stub in tests.
    var tileSession = ExternalRequest.session

    /// Largest tile edge accepted from the origin. Standard tiles are 256; @2x/@3x variants reach
    /// 768. 2048 leaves generous headroom while making an OOM impossible. (SEC-C34)
    private static let maxTileDimension = ChartTileLoader.maxTileDimension

    /// Response ceiling for a single tile — orders of magnitude above a real PNG tile. (SEC-C34)
    private static let maxTileBytes = OpenAIPConfig.maxTileBytes

    /// Minimum alpha threshold (0-255) for pixels to be kept visible.
    /// OpenAIP tiles use very low alpha values (7-54) for airspace region fills,
    /// which create visible grid artifacts when different tiles have different fill levels.
    /// Only pixels above this threshold (labels, lines, symbols) are preserved.
    /// 64 (~25% opacity) filters out the semi-transparent fills while keeping
    /// text, symbols, and boundary lines intact.
    private static let alphaThreshold: UInt8 = 64

    /// No labels enlarged past OpenAIP's last zoom: none were drawn there before 6.4.2.
    let enlargesPastLastZoom = 0

    init(isStrictOfflineMode: Bool = false) {
        self.isStrictOfflineMode = isStrictOfflineMode

        // Placeholder URL template — `spec(for:)` says where each tile comes from. It carries NO api key (SA-11):
        // the key goes in the x-openaip-api-key header of the request, so it can never leak into a URLCache entry, a
        // proxy log, or OpenAIP's access logs.
        let urlTemplate = "https://\(OpenAIPConfig.tileHost)/api/data/openaip/{z}/{x}/{y}.png"
        super.init(urlTemplate: urlTemplate)

        self.minimumZ = OpenAIPConfig.tileMinZoom
        self.maximumZ = OpenAIPConfig.tileMaxZoom
        self.tileSize = CGSize(width: 256, height: 256)

        // This is an overlay, not a base layer replacement
        self.canReplaceMapContent = false
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        OpenAIPConfig.tileURL(z: path.z, x: path.x, y: path.y)
            ?? URL(string: "about:blank")!
    }

    /// From the network unless offline (online only since 6.8.0: the tiles are no longer downloaded), from OpenAIP's one
    /// tile host with the key in a header (SA-11); every tile's fills stripped (`strippingFills`). Drawn by `ChartTileRenderer`, which keeps the stripped
    /// image: until 6.4.2 MapKit's renderer dropped some of them, as it did the charts', and a failed tile was a
    /// transparent one never asked again (the map tile review, F8).
    func spec(for tile: ChartTile) -> ChartTileSpec? {
        var spec = ChartTileSpec(key: "openaip/\(tile.z)/\(tile.x)/\(tile.y)")
        spec.process = { Self.strippingFills(of: $0) }
        guard !isStrictOfflineMode else { return spec }
        guard let request = OpenAIPConfig.tileRequest(z: tile.z, x: tile.x, y: tile.y) else {
            return spec
        }
        let session = tileSession
        spec.fetch = {
            // SEC-C34: through ExternalRequest, for the shared streaming size ceiling and the cross-host redirect
            // header stripping.
            try await ExternalRequest.data(for: request, session: session, maxResponseBytes: Self.maxTileBytes)
        }
        return spec
    }

    // MARK: - Tile Processing

    /// Remove low-alpha airspace fills from OpenAIP tiles while preserving
    /// high-contrast features (text labels, boundary lines, airport symbols, navaids).
    ///
    /// OpenAIP renders airspace region fills with very low alpha (7-54) that vary
    /// between adjacent tiles based on which airspaces overlap each tile. This creates
    /// visible rectangular grid artifacts on the map. Since we already render proper
    /// polygon-based airspace fills from the structured API, we only need the tiles
    /// for their labels and symbols — so we strip the low-alpha fill pixels. The image stays decoded, for the
    /// renderer: no PNG encoded again for MapKit to decode once more. (6.4.2)
    static func strippingFills(of cgImage: CGImage) -> CGImage? {
        // SEC-C34: bound the decode before allocating. A map tile is 256×256 (512 for @2x); this
        // buffer is sized from the DECODED IMAGE's own dimensions, so a maliciously oversized but
        // well-formed PNG from the tile origin would allocate width*height*4 bytes — an OOM with
        // the map open, i.e. in flight. Anything outside the expected envelope is dropped.
        guard cgImage.width > 0, cgImage.height > 0,
              cgImage.width <= Self.maxTileDimension, cgImage.height <= Self.maxTileDimension else {
            AppLog.openAIP.debugLine("Rejected tile with implausible dimensions \(cgImage.width)x\(cgImage.height)")
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let buffer = context.data else {
            return nil
        }

        // Draw the original image into our RGBA buffer
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let threshold = alphaThreshold
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

        // Process pixels: make low-alpha fill pixels fully transparent
        for i in stride(from: 0, to: bytesPerRow * height, by: bytesPerPixel) where pixels[i + 3] < threshold {
            // Low-alpha pixel (airspace fill) — make fully transparent
            pixels[i] = 0     // R
            pixels[i + 1] = 0 // G
            pixels[i + 2] = 0 // B
            pixels[i + 3] = 0 // A
        }

        return context.makeImage()
    }
}
