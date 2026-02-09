import Foundation

/// Configuration for OpenAIP API integration
/// OpenAIP provides worldwide aviation data (airspaces, airports, navaids)
/// License: CC BY-NC 4.0 - Attribution required
enum OpenAIPConfig {
    /// API key for OpenAIP services (bundled with app)
    /// Register at https://www.openaip.net/ to obtain a key
    static let apiKey = "b0965c26c7dcb7982530ed79f4a7cc2f"

    /// Core REST API base URL for structured data (airports, airspaces, navaids)
    static let coreAPIBaseURL = "https://api.core.openaip.net/api"

    /// Tiles API base URL for raster/vector map tiles
    static let tilesAPIBaseURL = "https://api.tiles.openaip.net/api/data"

    /// Subdomains for tile load balancing
    static let tileSubdomains = ["a", "b", "c"]

    /// Tile URL template for raster PNG tiles
    /// Placeholders: {s} = subdomain, {z} = zoom, {x} = x tile, {y} = y tile
    static func tileURL(subdomain: String, z: Int, x: Int, y: Int) -> URL? {
        URL(string: "https://\(subdomain).api.tiles.openaip.net/api/data/openaip/\(z)/\(x)/\(y).png?apiKey=\(apiKey)")
    }

    /// Minimum zoom level for OpenAIP tiles (below this, tiles are too sparse)
    static let tileMinZoom = 5

    /// Maximum zoom level for OpenAIP tiles
    static let tileMaxZoom = 14

    /// Maximum number of airspaces per API page
    static let airspacePageLimit = 1000

    /// Cache expiration interval for airspace data (90 days)
    static let airspaceCacheExpirationInterval: TimeInterval = 90 * 24 * 60 * 60

    /// Predefined country bounding boxes for tile downloads
    /// Format: (minLat, minLon, maxLat, maxLon)
    static let countryBounds: [String: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)] = [
        "CH": (minLat: 45.82, minLon: 5.96, maxLat: 47.81, maxLon: 10.49),    // Switzerland
        "FR": (minLat: 41.33, minLon: -5.14, maxLat: 51.09, maxLon: 9.56),     // France
        "DE": (minLat: 47.27, minLon: 5.87, maxLat: 55.06, maxLon: 15.04),     // Germany
        "AT": (minLat: 46.37, minLon: 9.53, maxLat: 49.02, maxLon: 17.16),     // Austria
        "IT": (minLat: 36.62, minLon: 6.63, maxLat: 47.09, maxLon: 18.52),     // Italy
        "ES": (minLat: 36.00, minLon: -9.30, maxLat: 43.79, maxLon: 3.33),     // Spain
        "GB": (minLat: 49.96, minLon: -7.57, maxLat: 58.64, maxLon: 1.68),     // United Kingdom
        "BE": (minLat: 49.50, minLon: 2.55, maxLat: 51.50, maxLon: 6.40),      // Belgium
        "NL": (minLat: 50.75, minLon: 3.36, maxLat: 53.47, maxLon: 7.21),      // Netherlands
        "LU": (minLat: 49.45, minLon: 5.73, maxLat: 50.18, maxLon: 6.53),      // Luxembourg
        "CZ": (minLat: 48.55, minLon: 12.09, maxLat: 51.06, maxLon: 18.86),    // Czech Republic
        "PL": (minLat: 49.00, minLon: 14.12, maxLat: 54.84, maxLon: 24.15),    // Poland
        "HR": (minLat: 42.39, minLon: 13.49, maxLat: 46.55, maxLon: 19.43),    // Croatia
        "GR": (minLat: 34.80, minLon: 19.37, maxLat: 41.75, maxLon: 29.65),    // Greece
        "PT": (minLat: 36.96, minLon: -9.50, maxLat: 42.15, maxLon: -6.19),    // Portugal
        "SE": (minLat: 55.34, minLon: 11.11, maxLat: 69.06, maxLon: 24.17),    // Sweden
        "NO": (minLat: 57.96, minLon: 4.64, maxLat: 71.19, maxLon: 31.08),     // Norway
        "US": (minLat: 24.40, minLon: -124.85, maxLat: 49.38, maxLon: -66.88), // USA (continental)
    ]

    /// Display name for a country code
    static func countryName(for code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    /// Attribution text (required by CC BY-NC 4.0 license)
    static let attributionText = "Aeronautical data © OpenAIP contributors"
}
