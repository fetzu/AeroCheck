import Foundation

/// Configuration for OpenAIP API integration
/// OpenAIP provides worldwide aviation data (airspaces, airports, navaids)
/// License: CC BY-NC 4.0 - Attribution required
enum OpenAIPConfig {
    /// API key for OpenAIP services.
    ///
    /// Injected at build time from the untracked `Secrets.xcconfig` — flowing
    /// `OPENAIP_API_KEY` (build setting) → `OpenAIPAPIKey` (Info.plist) → here.
    /// It is deliberately NOT hard-coded in tracked source; see
    /// `Secrets.example.xcconfig` and the "OpenAIP API key" note in CLAUDE.md.
    /// Register / rotate keys at https://www.openaip.net/.
    ///
    /// Resolves to an empty string when no key is configured (e.g. a fresh
    /// open-source checkout without `Secrets.xcconfig`). Callers degrade
    /// gracefully: tile/CTR requests get a 401 and the airspace overlay simply
    /// doesn't render — the app does not crash.
    static let apiKey: String = {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "OpenAIPAPIKey") as? String,
              !key.isEmpty else {
            AppLog.openAIP.debugLine("OpenAIP API key missing — set OPENAIP_API_KEY in Secrets.xcconfig (copy Secrets.example.xcconfig)")
            return ""
        }
        return key
    }()

    /// Core REST API base URL for structured data (airports, airspaces, navaids)
    static let coreAPIBaseURL = "https://api.core.openaip.net/api"

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

    // MARK: - Streaming CTR Fallback

    /// Search radius for streaming CTR queries (20 NM in meters)
    static let streamingFetchRadiusMeters: Int = 37040
    /// Maximum CTRs per streaming API request
    static let streamingFetchLimit: Int = 10
    /// Time-to-live for streaming cache (5 minutes)
    static let streamingCacheTTL: TimeInterval = 300
    /// Distance threshold to invalidate cache (pilot moved >10nm from cache origin)
    static let streamingCacheInvalidationDistanceNM: Double = 10.0
    /// Minimum interval between streaming API requests (60 seconds)
    static let streamingMinFetchInterval: TimeInterval = 60
    /// Maximum backoff interval on repeated errors (5 minutes)
    static let streamingMaxErrorBackoff: TimeInterval = 300
    /// Request timeout for streaming API calls (10 seconds)
    static let streamingRequestTimeout: TimeInterval = 10

    /// Predefined country bounding boxes for tile downloads
    /// Format: (minLat, minLon, maxLat, maxLon)
    /// Coverage: 119 countries with confirmed OpenAIP airspace data
    static let countryBounds: [String: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)] = [
        // Europe (41 countries)
        "AL": (minLat: 39.64, minLon: 19.26, maxLat: 42.66, maxLon: 21.06),
        "AM": (minLat: 38.83, minLon: 43.45, maxLat: 41.30, maxLon: 46.63),
        "AT": (minLat: 46.37, minLon: 9.53, maxLat: 49.02, maxLon: 17.16),
        "BA": (minLat: 42.55, minLon: 15.72, maxLat: 45.28, maxLon: 19.62),
        "BE": (minLat: 49.50, minLon: 2.55, maxLat: 51.50, maxLon: 6.40),
        "BG": (minLat: 41.00, minLon: 22.40, maxLat: 44.20, maxLon: 28.60),
        "BY": (minLat: 51.26, minLon: 23.18, maxLat: 56.17, maxLon: 32.77),
        "CH": (minLat: 45.82, minLon: 5.96, maxLat: 47.81, maxLon: 10.49),
        "CY": (minLat: 34.57, minLon: 32.27, maxLat: 35.70, maxLon: 34.60),
        "CZ": (minLat: 48.55, minLon: 12.09, maxLat: 51.06, maxLon: 18.86),
        "DE": (minLat: 47.27, minLon: 5.87, maxLat: 55.06, maxLon: 15.04),
        "DK": (minLat: 54.50, minLon: 8.00, maxLat: 57.80, maxLon: 15.20),
        "EE": (minLat: 57.52, minLon: 21.76, maxLat: 59.69, maxLon: 28.21),
        "ES": (minLat: 36.00, minLon: -9.30, maxLat: 43.79, maxLon: 3.33),
        "FI": (minLat: 59.80, minLon: 19.30, maxLat: 70.10, maxLon: 31.60),
        "FO": (minLat: 61.39, minLon: -7.44, maxLat: 62.41, maxLon: -6.26),
        "FR": (minLat: 41.33, minLon: -5.14, maxLat: 51.09, maxLon: 9.56),
        "GB": (minLat: 49.96, minLon: -7.57, maxLat: 58.64, maxLon: 1.68),
        "GE": (minLat: 41.05, minLon: 40.01, maxLat: 43.59, maxLon: 46.71),
        "GL": (minLat: 59.78, minLon: -73.04, maxLat: 83.63, maxLon: -12.17),
        "GR": (minLat: 34.80, minLon: 19.37, maxLat: 41.75, maxLon: 29.65),
        "HR": (minLat: 42.39, minLon: 13.49, maxLat: 46.55, maxLon: 19.43),
        "HU": (minLat: 45.70, minLon: 16.10, maxLat: 48.60, maxLon: 22.90),
        "IE": (minLat: 51.40, minLon: -10.50, maxLat: 55.40, maxLon: -5.40),
        "IM": (minLat: 54.06, minLon: -4.83, maxLat: 54.42, maxLon: -4.31),
        "IS": (minLat: 63.30, minLon: -24.55, maxLat: 66.53, maxLon: -13.50),
        "IT": (minLat: 36.62, minLon: 6.63, maxLat: 47.09, maxLon: 18.52),
        "LT": (minLat: 53.90, minLon: 20.90, maxLat: 56.45, maxLon: 26.80),
        "LU": (minLat: 49.45, minLon: 5.73, maxLat: 50.18, maxLon: 6.53),
        "LV": (minLat: 55.70, minLon: 20.97, maxLat: 58.08, maxLon: 28.24),
        "MD": (minLat: 46.35, minLon: 26.62, maxLat: 48.49, maxLon: 30.16),
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
        // North America & Caribbean (6 countries)
        "CA": (minLat: 41.70, minLon: -141.00, maxLat: 83.10, maxLon: -52.60),
        "CR": (minLat: 8.03, minLon: -85.95, maxLat: 11.22, maxLon: -82.55),
        "CW": (minLat: 12.04, minLon: -69.16, maxLat: 12.39, maxLon: -68.73),
        "MX": (minLat: 14.50, minLon: -118.40, maxLat: 32.72, maxLon: -86.70),
        "PR": (minLat: 17.88, minLon: -67.27, maxLat: 18.52, maxLon: -65.59),
        "US": (minLat: 24.40, minLon: -124.85, maxLat: 49.38, maxLon: -66.88),
        // South America (9 countries)
        "AR": (minLat: -55.40, minLon: -73.60, maxLat: -21.80, maxLon: -53.60),
        "BR": (minLat: -33.75, minLon: -73.98, maxLat: 5.27, maxLon: -34.80),
        "CL": (minLat: -56.50, minLon: -80.00, maxLat: -17.50, maxLon: -66.40),
        "CO": (minLat: -4.20, minLon: -79.00, maxLat: 12.50, maxLon: -66.90),
        "FK": (minLat: -52.41, minLon: -61.35, maxLat: -51.24, maxLon: -57.71),
        "PE": (minLat: -18.35, minLon: -81.30, maxLat: 0.04, maxLon: -68.70),
        "PY": (minLat: -27.59, minLon: -62.64, maxLat: -19.29, maxLon: -54.26),
        "UY": (minLat: -34.95, minLon: -58.44, maxLat: -30.09, maxLon: -53.07),
        "VE": (minLat: 0.63, minLon: -73.38, maxLat: 12.20, maxLon: -59.80),
        // Asia & Pacific (27 countries)
        "AF": (minLat: 29.38, minLon: 60.47, maxLat: 38.49, maxLon: 74.88),
        "AU": (minLat: -44.00, minLon: 112.90, maxLat: -10.00, maxLon: 153.70),
        "BN": (minLat: 4.00, minLon: 114.07, maxLat: 5.05, maxLon: 115.36),
        "CN": (minLat: 18.00, minLon: 73.50, maxLat: 53.60, maxLon: 135.10),
        "HK": (minLat: 22.15, minLon: 113.83, maxLat: 22.56, maxLon: 114.43),
        "ID": (minLat: -11.00, minLon: 95.00, maxLat: 6.00, maxLon: 141.00),
        "IN": (minLat: 8.00, minLon: 68.20, maxLat: 35.30, maxLon: 97.20),
        "IR": (minLat: 25.06, minLon: 44.03, maxLat: 39.78, maxLon: 63.32),
        "JP": (minLat: 24.00, minLon: 122.90, maxLat: 45.55, maxLon: 145.80),
        "KP": (minLat: 37.67, minLon: 124.21, maxLat: 43.01, maxLon: 130.70),
        "KZ": (minLat: 40.57, minLon: 46.49, maxLat: 55.44, maxLon: 87.31),
        "LA": (minLat: 13.91, minLon: 100.08, maxLat: 22.50, maxLon: 107.70),
        "LK": (minLat: 5.92, minLon: 79.65, maxLat: 9.84, maxLon: 81.88),
        "MM": (minLat: 9.78, minLon: 92.17, maxLat: 28.54, maxLon: 101.17),
        "MN": (minLat: 41.58, minLon: 87.75, maxLat: 52.15, maxLon: 119.93),
        "MV": (minLat: -0.69, minLon: 72.68, maxLat: 7.10, maxLon: 73.75),
        "MY": (minLat: 0.85, minLon: 99.60, maxLat: 7.40, maxLon: 119.30),
        "NP": (minLat: 26.35, minLon: 80.06, maxLat: 30.45, maxLon: 88.20),
        "NZ": (minLat: -47.30, minLon: 166.40, maxLat: -34.40, maxLon: 178.60),
        "PG": (minLat: -11.66, minLon: 140.84, maxLat: -1.35, maxLon: 155.96),
        "PK": (minLat: 23.60, minLon: 60.90, maxLat: 37.10, maxLon: 77.60),
        "RU": (minLat: 41.20, minLon: 19.60, maxLat: 81.90, maxLon: 169.40),
        "TH": (minLat: 5.60, minLon: 97.30, maxLat: 20.50, maxLon: 105.60),
        "TJ": (minLat: 36.67, minLon: 67.39, maxLat: 41.04, maxLon: 75.14),
        "TM": (minLat: 35.14, minLon: 52.44, maxLat: 42.80, maxLon: 66.68),
        "UZ": (minLat: 37.18, minLon: 55.99, maxLat: 45.59, maxLon: 73.13),
        "VU": (minLat: -20.25, minLon: 166.52, maxLat: -13.07, maxLon: 170.24),
        // Middle East (6 countries)
        "AE": (minLat: 22.60, minLon: 51.00, maxLat: 26.20, maxLon: 56.40),
        "BH": (minLat: 25.57, minLon: 50.38, maxLat: 26.28, maxLon: 50.82),
        "IL": (minLat: 29.50, minLon: 34.20, maxLat: 33.30, maxLon: 35.90),
        "OM": (minLat: 16.65, minLon: 51.88, maxLat: 26.39, maxLon: 59.84),
        "QA": (minLat: 24.47, minLon: 50.74, maxLat: 26.15, maxLon: 51.64),
        "SA": (minLat: 16.35, minLon: 34.50, maxLat: 32.16, maxLon: 55.67),
        // Africa (30 countries)
        "BF": (minLat: 9.39, minLon: -5.52, maxLat: 15.08, maxLon: 2.41),
        "BJ": (minLat: 6.23, minLon: 0.77, maxLat: 12.42, maxLon: 3.84),
        "CF": (minLat: 2.22, minLon: 14.42, maxLat: 11.00, maxLon: 27.46),
        "CG": (minLat: -5.03, minLon: 11.09, maxLat: 3.71, maxLon: 18.65),
        "CM": (minLat: 1.65, minLon: 8.49, maxLat: 13.08, maxLon: 16.19),
        "DJ": (minLat: 10.94, minLon: 41.77, maxLat: 12.71, maxLon: 43.42),
        "DZ": (minLat: 18.97, minLon: -8.67, maxLat: 37.09, maxLon: 11.98),
        "GA": (minLat: -3.98, minLon: 8.70, maxLat: 2.32, maxLon: 14.50),
        "GQ": (minLat: 0.92, minLon: 9.35, maxLat: 2.35, maxLon: 11.34),
        "GW": (minLat: 10.92, minLon: -16.71, maxLat: 12.69, maxLon: -13.64),
        "KE": (minLat: -4.70, minLon: 33.90, maxLat: 4.90, maxLon: 41.90),
        "KM": (minLat: -12.42, minLon: 43.21, maxLat: -11.36, maxLon: 44.54),
        "LY": (minLat: 19.50, minLon: 9.39, maxLat: 33.17, maxLon: 25.15),
        "MA": (minLat: 27.67, minLon: -13.17, maxLat: 35.92, maxLon: -0.99),
        "MG": (minLat: -25.60, minLon: 43.18, maxLat: -11.95, maxLon: 50.48),
        "ML": (minLat: 10.16, minLon: -12.24, maxLat: 25.00, maxLon: 4.27),
        "MR": (minLat: 14.72, minLon: -17.07, maxLat: 27.30, maxLon: -4.83),
        "MU": (minLat: -20.53, minLon: 56.51, maxLat: -19.97, maxLon: 63.50),
        "MW": (minLat: -17.13, minLon: 32.67, maxLat: -9.37, maxLon: 35.92),
        "MZ": (minLat: -26.87, minLon: 30.22, maxLat: -10.47, maxLon: 40.84),
        "NA": (minLat: -28.97, minLon: 11.72, maxLat: -16.96, maxLon: 25.26),
        "NE": (minLat: 11.69, minLon: 0.17, maxLat: 23.52, maxLon: 15.99),
        "RE": (minLat: -21.39, minLon: 55.22, maxLat: -20.87, maxLon: 55.84),
        "RW": (minLat: -2.84, minLon: 28.86, maxLat: -1.05, maxLon: 30.90),
        "SN": (minLat: 12.31, minLon: -17.54, maxLat: 16.69, maxLon: -11.36),
        "SO": (minLat: -1.68, minLon: 40.98, maxLat: 11.99, maxLon: 51.41),
        "SS": (minLat: 3.49, minLon: 23.44, maxLat: 12.24, maxLon: 35.95),
        "TD": (minLat: 7.44, minLon: 13.47, maxLat: 23.45, maxLon: 24.00),
        "TG": (minLat: 6.10, minLon: -0.15, maxLat: 11.14, maxLon: 1.81),
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
    /// 119 countries total across 6 continent groups
    static let continents: [Continent] = [
        Continent(id: "europe", name: "Europe", icon: "globe.europe.africa",
                  countries: ["AL", "AM", "AT", "BA", "BE", "BG", "BY", "CH", "CY", "CZ",
                              "DE", "DK", "EE", "ES", "FI", "FO", "FR", "GB", "GE", "GL",
                              "GR", "HR", "HU", "IE", "IM", "IS", "IT", "LT", "LU", "LV",
                              "MD", "NL", "NO", "PL", "PT", "RO", "RS", "SE", "SI", "SK", "TR"]),
        Continent(id: "northAmerica", name: "North America", icon: "globe.americas",
                  countries: ["CA", "CR", "CW", "MX", "PR", "US"]),
        Continent(id: "southAmerica", name: "South America", icon: "globe.americas",
                  countries: ["AR", "BR", "CL", "CO", "FK", "PE", "PY", "UY", "VE"]),
        Continent(id: "asiaPacific", name: "Asia & Pacific", icon: "globe.asia.australia",
                  countries: ["AF", "AU", "BN", "CN", "HK", "ID", "IN", "IR", "JP", "KP",
                              "KZ", "LA", "LK", "MM", "MN", "MV", "MY", "NP", "NZ", "PG",
                              "PK", "RU", "TH", "TJ", "TM", "UZ", "VU"]),
        Continent(id: "middleEast", name: "Middle East", icon: "globe.europe.africa",
                  countries: ["AE", "BH", "IL", "OM", "QA", "SA"]),
        Continent(id: "africa", name: "Africa", icon: "globe.europe.africa",
                  countries: ["BF", "BJ", "CF", "CG", "CM", "DJ", "DZ", "GA", "GQ", "GW",
                              "KE", "KM", "LY", "MA", "MG", "ML", "MR", "MU", "MW", "MZ",
                              "NA", "NE", "RE", "RW", "SN", "SO", "SS", "TD", "TG", "TN", "ZA"]),
    ]

    /// Display name for a country code (localized via system)
    static func countryName(for code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    /// Attribution text (required by CC BY-NC 4.0 license). Plain-text form for the concatenated map
    /// "Data sources" line; the hub uses a tappable markdown variant (L10n.DataStorage.openAIPAttribution).
    static let attributionText = "Airspace data from OpenAIP.net (© OpenAIP and contributors, CC BY-NC 4.0)"

    /// Public, keyless GeoJSON exports bucket (per-country `{cc}_<layer>.geojson`). Used for the new
    /// structured layers (navaids / obstacles / reporting points) — no API key required. (v4.1.0)
    static let geoJSONExportBaseURL = "https://storage.googleapis.com/29f98e10-a489-4c82-ae5e-489dbcd4912f"
}
