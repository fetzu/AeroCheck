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
        // Europe
        "AT": (minLat: 46.37, minLon: 9.53, maxLat: 49.02, maxLon: 17.16),
        "BE": (minLat: 49.50, minLon: 2.55, maxLat: 51.50, maxLon: 6.40),
        "BG": (minLat: 41.00, minLon: 22.40, maxLat: 44.20, maxLon: 28.60),
        "CH": (minLat: 45.82, minLon: 5.96, maxLat: 47.81, maxLon: 10.49),
        "CZ": (minLat: 48.55, minLon: 12.09, maxLat: 51.06, maxLon: 18.86),
        "DE": (minLat: 47.27, minLon: 5.87, maxLat: 55.06, maxLon: 15.04),
        "DK": (minLat: 54.50, minLon: 8.00, maxLat: 57.80, maxLon: 15.20),
        "ES": (minLat: 36.00, minLon: -9.30, maxLat: 43.79, maxLon: 3.33),
        "FI": (minLat: 59.80, minLon: 19.30, maxLat: 70.10, maxLon: 31.60),
        "FR": (minLat: 41.33, minLon: -5.14, maxLat: 51.09, maxLon: 9.56),
        "GB": (minLat: 49.96, minLon: -7.57, maxLat: 58.64, maxLon: 1.68),
        "GR": (minLat: 34.80, minLon: 19.37, maxLat: 41.75, maxLon: 29.65),
        "HR": (minLat: 42.39, minLon: 13.49, maxLat: 46.55, maxLon: 19.43),
        "HU": (minLat: 45.70, minLon: 16.10, maxLat: 48.60, maxLon: 22.90),
        "IE": (minLat: 51.40, minLon: -10.50, maxLat: 55.40, maxLon: -5.40),
        "IT": (minLat: 36.62, minLon: 6.63, maxLat: 47.09, maxLon: 18.52),
        "LT": (minLat: 53.90, minLon: 20.90, maxLat: 56.45, maxLon: 26.80),
        "LU": (minLat: 49.45, minLon: 5.73, maxLat: 50.18, maxLon: 6.53),
        "LV": (minLat: 55.70, minLon: 20.97, maxLat: 58.08, maxLon: 28.24),
        "NL": (minLat: 50.75, minLon: 3.36, maxLat: 53.47, maxLon: 7.21),
        "NO": (minLat: 57.96, minLon: 4.64, maxLat: 71.19, maxLon: 31.08),
        "PL": (minLat: 49.00, minLon: 14.12, maxLat: 54.84, maxLon: 24.15),
        "PT": (minLat: 36.96, minLon: -9.50, maxLat: 42.15, maxLon: -6.19),
        "RO": (minLat: 43.60, minLon: 20.30, maxLat: 48.30, maxLon: 29.70),
        "RS": (minLat: 42.23, minLon: 18.82, maxLat: 46.19, maxLon: 23.01),
        "SE": (minLat: 55.34, minLon: 11.11, maxLat: 69.06, maxLon: 24.17),
        "SI": (minLat: 45.42, minLon: 13.38, maxLat: 46.88, maxLon: 16.60),
        "SK": (minLat: 47.73, minLon: 16.83, maxLat: 49.60, maxLon: 22.57),
        "TR": (minLat: 35.80, minLon: 25.70, maxLat: 42.70, maxLon: 44.80),
        // North America
        "CA": (minLat: 41.70, minLon: -141.00, maxLat: 83.10, maxLon: -52.60),
        "MX": (minLat: 14.50, minLon: -118.40, maxLat: 32.72, maxLon: -86.70),
        "US": (minLat: 24.40, minLon: -124.85, maxLat: 49.38, maxLon: -66.88),
        // South America
        "AR": (minLat: -55.40, minLon: -73.60, maxLat: -21.80, maxLon: -53.60),
        "BR": (minLat: -33.75, minLon: -73.98, maxLat: 5.27, maxLon: -34.80),
        "CL": (minLat: -56.50, minLon: -80.00, maxLat: -17.50, maxLon: -66.40),
        "CO": (minLat: -4.20, minLon: -79.00, maxLat: 12.50, maxLon: -66.90),
        "PE": (minLat: -18.35, minLon: -81.30, maxLat: 0.04, maxLon: -68.70),
        // Asia & Pacific
        "AU": (minLat: -44.00, minLon: 112.90, maxLat: -10.00, maxLon: 153.70),
        "CN": (minLat: 18.00, minLon: 73.50, maxLat: 53.60, maxLon: 135.10),
        "HK": (minLat: 22.15, minLon: 113.83, maxLat: 22.56, maxLon: 114.43),
        "ID": (minLat: -11.00, minLon: 95.00, maxLat: 6.00, maxLon: 141.00),
        "IN": (minLat: 8.00, minLon: 68.20, maxLat: 35.30, maxLon: 97.20),
        "JP": (minLat: 24.00, minLon: 122.90, maxLat: 45.55, maxLon: 145.80),
        "MY": (minLat: 0.85, minLon: 99.60, maxLat: 7.40, maxLon: 119.30),
        "NZ": (minLat: -47.30, minLon: 166.40, maxLat: -34.40, maxLon: 178.60),
        "PK": (minLat: 23.60, minLon: 60.90, maxLat: 37.10, maxLon: 77.60),
        "RU": (minLat: 41.20, minLon: 19.60, maxLat: 81.90, maxLon: 169.40),
        "TH": (minLat: 5.60, minLon: 97.30, maxLat: 20.50, maxLon: 105.60),
        // Middle East
        "AE": (minLat: 22.60, minLon: 51.00, maxLat: 26.20, maxLon: 56.40),
        "IL": (minLat: 29.50, minLon: 34.20, maxLat: 33.30, maxLon: 35.90),
        // Africa
        "DZ": (minLat: 18.97, minLon: -8.67, maxLat: 37.09, maxLon: 11.98),
        "KE": (minLat: -4.70, minLon: 33.90, maxLat: 4.90, maxLon: 41.90),
        "LY": (minLat: 19.50, minLon: 9.39, maxLat: 33.17, maxLon: 25.15),
        "MA": (minLat: 27.67, minLon: -13.17, maxLat: 35.92, maxLon: -0.99),
        "TN": (minLat: 30.23, minLon: 7.52, maxLat: 37.54, maxLon: 11.60),
        "ZA": (minLat: -34.80, minLon: 16.50, maxLat: -22.10, maxLon: 32.90),
    ]

    // MARK: - Continent Groupings

    /// Continent definition with display name, icon, and country codes
    struct Continent: Identifiable {
        let id: String
        let name: String
        let icon: String
        let countries: [String]
    }

    /// All continents with their countries, ordered for display
    static let continents: [Continent] = [
        Continent(id: "europe", name: "Europe", icon: "globe.europe.africa",
                  countries: ["AT", "BE", "BG", "CH", "CZ", "DE", "DK", "ES", "FI", "FR",
                              "GB", "GR", "HR", "HU", "IE", "IT", "LT", "LU", "LV", "NL",
                              "NO", "PL", "PT", "RO", "RS", "SE", "SI", "SK", "TR"]),
        Continent(id: "northAmerica", name: "North America", icon: "globe.americas",
                  countries: ["CA", "MX", "US"]),
        Continent(id: "southAmerica", name: "South America", icon: "globe.americas",
                  countries: ["AR", "BR", "CL", "CO", "PE"]),
        Continent(id: "asiaPacific", name: "Asia & Pacific", icon: "globe.asia.australia",
                  countries: ["AU", "CN", "HK", "ID", "IN", "JP", "MY", "NZ", "PK", "RU", "TH"]),
        Continent(id: "middleEast", name: "Middle East", icon: "globe.europe.africa",
                  countries: ["AE", "IL"]),
        Continent(id: "africa", name: "Africa", icon: "globe.europe.africa",
                  countries: ["DZ", "KE", "LY", "MA", "TN", "ZA"]),
    ]

    /// Display name for a country code (localized via system)
    static func countryName(for code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    /// Attribution text (required by CC BY-NC 4.0 license)
    static let attributionText = "Aeronautical data © OpenAIP contributors"
}
