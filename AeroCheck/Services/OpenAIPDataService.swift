import Foundation
import CoreLocation
import MapKit

/// Service for managing OpenAIP airspace data
/// Downloads, caches, and queries airspace data for flight planning and navigation
@MainActor
class OpenAIPDataService: ObservableObject {
    // MARK: - Published Properties

    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadError: String?
    @Published var lastUpdated: Date?
    @Published var isDataAvailable: Bool = false
    @Published var airspaceCount: Int = 0
    @Published var downloadedCountries: [String] = []

    // MARK: - Streaming CTR Properties

    @Published var streamingCTRs: [(airspace: Airspace, distanceNM: Double)] = []
    @Published var isStreamingFetchInProgress: Bool = false

    // MARK: - Private Properties

    private var airspaces: [Airspace] = []
    private var airspacesByCountry: [String: [Airspace]] = [:]
    @Published private(set) var isLoaded = false

    // Streaming cache
    private struct StreamingCTRCache {
        let airspaces: [Airspace]
        let fetchCoordinate: CLLocationCoordinate2D
        let fetchTime: Date
    }
    private var streamingCache: StreamingCTRCache?
    private var lastStreamingFetchAttempt: Date?
    private var consecutiveStreamingErrors: Int = 0

    private let fileManager = FileManager.default
    private var dataDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("OpenAIPData", isDirectory: true)
    }

    private var metadataFileURL: URL { dataDirectory.appendingPathComponent("metadata.json") }

    private func airspaceFileURL(for country: String) -> URL {
        dataDirectory.appendingPathComponent("airspaces_\(country).json")
    }

    // MARK: - Initialization

    init() {
        // Check if data files exist without loading into memory
        if fileManager.fileExists(atPath: metadataFileURL.path),
           let data = try? Data(contentsOf: metadataFileURL),
           let metadata = try? JSONDecoder().decode(OpenAIPCacheMetadata.self, from: data) {
            downloadedCountries = Array(metadata.lastSyncDates.keys).sorted()
            airspaceCount = metadata.airspaceCounts.values.reduce(0, +)
            lastUpdated = metadata.lastSyncDates.values.max()
            isDataAvailable = !downloadedCountries.isEmpty
        }
    }

    /// Load airspace data into memory if not already loaded
    func ensureLoaded() async {
        guard !isLoaded else { return }
        await loadFromLocal()
    }

    // MARK: - Data Loading

    private func loadFromLocal() async {
        guard fileManager.fileExists(atPath: metadataFileURL.path),
              let metaData = try? Data(contentsOf: metadataFileURL),
              let metadata = try? JSONDecoder().decode(OpenAIPCacheMetadata.self, from: metaData) else {
            return
        }

        let decoder = JSONDecoder()
        var loadedAirspaces: [Airspace] = []
        var byCountry: [String: [Airspace]] = [:]

        for country in metadata.lastSyncDates.keys {
            let fileURL = airspaceFileURL(for: country)
            guard fileManager.fileExists(atPath: fileURL.path) else { continue }
            do {
                let data = try Data(contentsOf: fileURL)
                let countryAirspaces = try decoder.decode([Airspace].self, from: data)
                loadedAirspaces.append(contentsOf: countryAirspaces)
                byCountry[country] = countryAirspaces
            } catch {
                print("[OpenAIP] Failed to load airspaces for \(country): \(error)")
            }
        }

        airspaces = loadedAirspaces
        airspacesByCountry = byCountry
        airspaceCount = loadedAirspaces.count
        isLoaded = true
    }

    // MARK: - Data Download

    /// Check if data needs updating (older than cache expiration)
    var needsUpdate: Bool {
        guard let lastUpdate = lastUpdated else { return true }
        return Date().timeIntervalSince(lastUpdate) > OpenAIPConfig.airspaceCacheExpirationInterval
    }

    /// Download airspace data for selected countries from OpenAIP Core API
    func downloadData(for countries: [String]) async {
        guard !isDownloading else { return }

        isDownloading = true
        downloadProgress = 0
        downloadError = nil

        do {
            try fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        } catch {
            downloadError = "Failed to create data directory"
            isDownloading = false
            return
        }

        // Load existing metadata
        var metadata: OpenAIPCacheMetadata
        if let data = try? Data(contentsOf: metadataFileURL),
           let existing = try? JSONDecoder().decode(OpenAIPCacheMetadata.self, from: data) {
            metadata = existing
        } else {
            metadata = OpenAIPCacheMetadata()
        }

        var allAirspaces: [Airspace] = []
        var byCountry: [String: [Airspace]] = [:]
        let totalCountries = Double(countries.count)

        for (index, country) in countries.enumerated() {
            downloadProgress = Double(index) / totalCountries

            do {
                let countryAirspaces = try await fetchAirspaces(for: country)
                allAirspaces.append(contentsOf: countryAirspaces)
                byCountry[country] = countryAirspaces

                // Save per-country file
                let encoded = try JSONEncoder().encode(countryAirspaces)
                try encoded.write(to: airspaceFileURL(for: country))

                // Update metadata
                metadata.lastSyncDates[country] = Date()
                metadata.airspaceCounts[country] = countryAirspaces.count

                print("[OpenAIP] Downloaded \(countryAirspaces.count) airspaces for \(country)")
            } catch {
                print("[OpenAIP] Failed to download airspaces for \(country): \(error)")
                downloadError = "Failed to download data for \(OpenAIPConfig.countryName(for: country)): \(error.localizedDescription)"
            }

            if Task.isCancelled { break }
        }

        // Remove countries that are no longer selected
        let removedCountries = Set(metadata.lastSyncDates.keys).subtracting(countries)
        for country in removedCountries {
            metadata.lastSyncDates.removeValue(forKey: country)
            metadata.airspaceCounts.removeValue(forKey: country)
            try? fileManager.removeItem(at: airspaceFileURL(for: country))
        }

        // Save metadata
        metadata.lastFullRefresh = Date()
        if let metaEncoded = try? JSONEncoder().encode(metadata) {
            try? metaEncoded.write(to: metadataFileURL)
        }

        // Update in-memory data
        airspaces = allAirspaces
        airspacesByCountry = byCountry
        airspaceCount = allAirspaces.count
        downloadedCountries = countries.sorted()
        lastUpdated = Date()
        isDataAvailable = !allAirspaces.isEmpty
        isLoaded = true

        downloadProgress = 1.0
        isDownloading = false
    }

    /// Fetch all airspaces for a given country from OpenAIP API with pagination
    private func fetchAirspaces(for country: String) async throws -> [Airspace] {
        var allAirspaces: [Airspace] = []
        var page = 1
        let limit = OpenAIPConfig.airspacePageLimit

        while true {
            let urlString = "\(OpenAIPConfig.coreAPIBaseURL)/airspaces?country=\(country)&limit=\(limit)&page=\(page)"
            guard let url = URL(string: urlString) else {
                throw OpenAIPError.invalidURL
            }

            var request = URLRequest(url: url)
            request.setValue(OpenAIPConfig.apiKey, forHTTPHeaderField: "x-openaip-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw OpenAIPError.apiError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
            }

            let decoded = try JSONDecoder().decode(OpenAIPResponse<Airspace>.self, from: data)
            allAirspaces.append(contentsOf: decoded.items)

            // Check if there are more pages
            if page >= decoded.totalPages {
                break
            }
            page += 1
        }

        return allAirspaces
    }

    // MARK: - Spatial Queries

    /// Find airspaces near a coordinate within a given radius
    func airspacesNear(_ coordinate: CLLocationCoordinate2D, withinNM distance: Double) -> [Airspace] {
        guard isLoaded else { return [] }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let distanceMeters = distance * 1852 // 1 NM = 1852 meters

        return airspaces.filter { airspace in
            // Quick check: is the airspace centroid within range?
            let coords = airspace.polygonCoordinates
            guard !coords.isEmpty else { return false }

            // Use the centroid as a rough proximity check
            let avgLat = coords.map(\.latitude).reduce(0, +) / Double(coords.count)
            let avgLon = coords.map(\.longitude).reduce(0, +) / Double(coords.count)
            let centroid = CLLocation(latitude: avgLat, longitude: avgLon)

            return location.distance(from: centroid) <= distanceMeters * 2 // generous filter, refine later
        }
    }

    /// Find airspaces that intersect a map region
    func airspacesInBounds(_ region: MKCoordinateRegion) -> [Airspace] {
        guard isLoaded else { return [] }

        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2

        return airspaces.filter { airspace in
            let coords = airspace.polygonCoordinates
            guard !coords.isEmpty else { return false }

            // Check 1: Any polygon vertex inside the bounding box (catches small airspaces)
            let vertexInBounds = coords.contains { coord in
                coord.latitude >= minLat && coord.latitude <= maxLat &&
                coord.longitude >= minLon && coord.longitude <= maxLon
            }
            if vertexInBounds { return true }

            // Check 2: Bounding box center inside the polygon (catches large surrounding airspaces)
            return airspace.containsPoint(region.center)
        }
    }

    /// Find airspaces along a flight route (for flight plan analysis)
    func airspacesAlongRoute(_ waypoints: [CLLocationCoordinate2D]) -> [Airspace] {
        guard isLoaded, waypoints.count >= 2 else { return [] }

        // Create a bounding box that encompasses the entire route with a buffer
        let lats = waypoints.map(\.latitude)
        let lons = waypoints.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return [] }

        let buffer = 0.2 // ~12 NM buffer around route
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: (maxLat - minLat) + buffer * 2,
                longitudeDelta: (maxLon - minLon) + buffer * 2
            )
        )

        return airspacesInBounds(region)
    }

    /// Fetch airspaces along a route on-demand from the OpenAIP API
    /// Used when no downloaded data is available — makes API calls along the route
    /// Returns airspaces near the route for conflict analysis
    func fetchAirspacesAlongRoute(_ waypoints: [CLLocationCoordinate2D]) async throws -> [Airspace] {
        guard waypoints.count >= 2 else { return [] }

        // Calculate the route bounding box center and a search radius that covers the route
        let lats = waypoints.map(\.latitude)
        let lons = waypoints.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return [] }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        // Calculate the maximum distance from center to any waypoint, plus buffer
        let centerLocation = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let maxDistance = waypoints.map { wp in
            CLLocation(latitude: wp.latitude, longitude: wp.longitude).distance(from: centerLocation)
        }.max() ?? 0

        // Add 5 NM buffer, cap at 100km to stay within API limits
        let searchRadius = min(Int(maxDistance) + 9260, 100_000) // 5 NM = 9260m

        // Fetch all airspace types (no type filter) within the radius
        let urlString = "\(OpenAIPConfig.coreAPIBaseURL)/airspaces?pos=\(center.latitude),\(center.longitude)&dist=\(searchRadius)&limit=\(OpenAIPConfig.airspacePageLimit)&page=1"
        guard let url = URL(string: urlString) else {
            throw OpenAIPError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(OpenAIPConfig.apiKey, forHTTPHeaderField: "x-openaip-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw OpenAIPError.apiError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        let decoded = try JSONDecoder().decode(OpenAIPResponse<Airspace>.self, from: data)

        // If there are more pages, fetch them too
        var allAirspaces = decoded.items
        if decoded.totalPages > 1 {
            for page in 2...decoded.totalPages {
                let pageURL = "\(OpenAIPConfig.coreAPIBaseURL)/airspaces?pos=\(center.latitude),\(center.longitude)&dist=\(searchRadius)&limit=\(OpenAIPConfig.airspacePageLimit)&page=\(page)"
                guard let url = URL(string: pageURL) else { continue }
                var pageRequest = URLRequest(url: url)
                pageRequest.setValue(OpenAIPConfig.apiKey, forHTTPHeaderField: "x-openaip-api-key")
                pageRequest.setValue("application/json", forHTTPHeaderField: "Accept")
                pageRequest.timeoutInterval = 15

                if let (pageData, pageResp) = try? await URLSession.shared.data(for: pageRequest),
                   let httpResp = pageResp as? HTTPURLResponse, httpResp.statusCode == 200,
                   let pageDecoded = try? JSONDecoder().decode(OpenAIPResponse<Airspace>.self, from: pageData) {
                    allAirspaces.append(contentsOf: pageDecoded.items)
                }
            }
        }

        print("[OpenAIP] On-demand route fetch: \(allAirspaces.count) airspaces within \(searchRadius / 1000)km of route center")
        return allAirspaces
    }

    /// Find nearby CTR airspaces sorted by distance
    /// Returns all nearby CTRs regardless of altitude — UI handles altitude-based highlighting
    /// When `requireFrequencies` is true (default), only returns CTRs with frequency data
    func nearbyCTRs(from coordinate: CLLocationCoordinate2D, withinNM distance: Double = 20.0, requireFrequencies: Bool = false) -> [(airspace: Airspace, distanceNM: Double)] {
        guard isLoaded else { return [] }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let maxDistanceMeters = distance * 1852

        return airspaces
            .filter { $0.airspaceType == .ctr && (!requireFrequencies || $0.frequencies?.isEmpty == false) }
            .compactMap { airspace -> (airspace: Airspace, distanceNM: Double)? in
                guard let centroid = airspace.centroid else { return nil }
                let centroidLocation = CLLocation(latitude: centroid.latitude, longitude: centroid.longitude)
                let distanceMeters = location.distance(from: centroidLocation)
                guard distanceMeters <= maxDistanceMeters else { return nil }
                return (airspace: airspace, distanceNM: distanceMeters / 1852.0)
            }
            .sorted { $0.distanceNM < $1.distanceNM }
            .prefix(8)
            .map { $0 }
    }

    // MARK: - Streaming CTR Fallback

    /// Fetch nearby CTRs from the API if needed (when no downloaded data is available)
    /// Uses aggressive caching and throttling to minimize API load
    func fetchStreamingCTRsIfNeeded(from coordinate: CLLocationCoordinate2D) async {
        // Skip if full downloaded data is available
        guard !isDataAvailable else { return }

        let now = Date()
        let currentLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        // Check if cache is still valid
        if let cache = streamingCache {
            let cacheAge = now.timeIntervalSince(cache.fetchTime)
            let cacheLocation = CLLocation(latitude: cache.fetchCoordinate.latitude, longitude: cache.fetchCoordinate.longitude)
            let distanceFromCacheNM = currentLocation.distance(from: cacheLocation) / 1852.0

            if cacheAge < OpenAIPConfig.streamingCacheTTL
                && distanceFromCacheNM < OpenAIPConfig.streamingCacheInvalidationDistanceNM {
                // Cache valid — just recalculate distances from current position
                updateStreamingDistances(from: coordinate)
                return
            }
        }

        // Check cooldown (exponential backoff on errors)
        let backoff = min(
            OpenAIPConfig.streamingMinFetchInterval * pow(2.0, Double(consecutiveStreamingErrors)),
            OpenAIPConfig.streamingMaxErrorBackoff
        )
        if let lastAttempt = lastStreamingFetchAttempt,
           now.timeIntervalSince(lastAttempt) < backoff {
            return
        }

        await performStreamingFetch(from: coordinate)
    }

    /// Perform the actual API call to fetch nearby CTRs
    private func performStreamingFetch(from coordinate: CLLocationCoordinate2D) async {
        let urlString = "\(OpenAIPConfig.coreAPIBaseURL)/airspaces?pos=\(coordinate.latitude),\(coordinate.longitude)&dist=\(OpenAIPConfig.streamingFetchRadiusMeters)&type=4&limit=\(OpenAIPConfig.streamingFetchLimit)"

        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue(OpenAIPConfig.apiKey, forHTTPHeaderField: "x-openaip-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = OpenAIPConfig.streamingRequestTimeout

        isStreamingFetchInProgress = true
        lastStreamingFetchAttempt = Date()

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                consecutiveStreamingErrors += 1
                isStreamingFetchInProgress = false
                return
            }

            if httpResponse.statusCode == 429 {
                // Rate limited — force maximum backoff
                consecutiveStreamingErrors = max(consecutiveStreamingErrors, 3)
                print("[OpenAIP Streaming] Rate limited (429), backing off")
                isStreamingFetchInProgress = false
                return
            }

            guard httpResponse.statusCode == 200 else {
                consecutiveStreamingErrors += 1
                print("[OpenAIP Streaming] API error: HTTP \(httpResponse.statusCode)")
                isStreamingFetchInProgress = false
                return
            }

            let decoded = try JSONDecoder().decode(OpenAIPResponse<Airspace>.self, from: data)

            // Cache the raw airspaces
            streamingCache = StreamingCTRCache(
                airspaces: decoded.items,
                fetchCoordinate: coordinate,
                fetchTime: Date()
            )
            consecutiveStreamingErrors = 0

            // Calculate distances and update published property
            updateStreamingDistances(from: coordinate)

            print("[OpenAIP Streaming] Fetched \(decoded.items.count) CTRs near (\(String(format: "%.2f", coordinate.latitude)), \(String(format: "%.2f", coordinate.longitude)))")
        } catch {
            consecutiveStreamingErrors += 1
            print("[OpenAIP Streaming] Fetch failed: \(error.localizedDescription)")
        }

        isStreamingFetchInProgress = false
    }

    /// Recalculate distances from a new position using cached airspaces (no API call)
    private func updateStreamingDistances(from coordinate: CLLocationCoordinate2D) {
        guard let cache = streamingCache else {
            streamingCTRs = []
            return
        }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        streamingCTRs = cache.airspaces
            .compactMap { airspace -> (airspace: Airspace, distanceNM: Double)? in
                guard let centroid = airspace.centroid else { return nil }
                let centroidLocation = CLLocation(latitude: centroid.latitude, longitude: centroid.longitude)
                let distanceNM = location.distance(from: centroidLocation) / 1852.0
                return (airspace: airspace, distanceNM: distanceNM)
            }
            .sorted { $0.distanceNM < $1.distanceNM }
            .prefix(8)
            .map { $0 }
    }

    // MARK: - Cache Management

    /// Delete all cached airspace data
    func deleteData() {
        do {
            if fileManager.fileExists(atPath: dataDirectory.path) {
                try fileManager.removeItem(at: dataDirectory)
            }
            airspaces = []
            airspacesByCountry = [:]
            airspaceCount = 0
            downloadedCountries = []
            lastUpdated = nil
            isDataAvailable = false
            isLoaded = false
        } catch {
            downloadError = "Failed to delete data: \(error.localizedDescription)"
        }
    }
}

// MARK: - Errors

enum OpenAIPError: LocalizedError {
    case invalidURL
    case apiError(statusCode: Int)
    case decodingError
    case noData

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid API URL"
        case .apiError(let code): return "API error (HTTP \(code))"
        case .decodingError: return "Failed to parse API response"
        case .noData: return "No data received"
        }
    }
}
