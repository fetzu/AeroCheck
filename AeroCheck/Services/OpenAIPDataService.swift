import Foundation
import CoreLocation
import MapKit

/// Service for managing OpenAIP airspace data
/// Downloads, caches, and queries airspace data for flight planning and navigation.
/// `airspacesInBounds` (the throttled map-region-change hot path) is backed by a coarse 1° spatial
/// grid — mirroring `OpenAIPNavaidDataService` — keyed on each airspace's precomputed bounding box
/// rather than a point, since airspaces are polygons that can span multiple cells.
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

    private var airspaces: [Airspace] = [] {
        didSet { rebuildSpatialGrid() }
    }
    @Published private(set) var isLoaded = false

    // MARK: - Spatial index (coarse 1° grid, mirrors OpenAIPNavaidDataService)

    /// Airspaces are polygons, not points, so each one is inserted into EVERY cell its precomputed
    /// bounding box (`Airspace.boundingBox`, PR-11) overlaps — a query then only has to gather the
    /// cells its own bounds overlap and can never miss a true intersection (two boxes that truly
    /// overlap always share at least one grid cell), at the cost of some false-positive candidates
    /// that the existing exact per-element check below still filters out.
    private struct GridKey: Hashable { let lat: Int; let lon: Int }
    private static let gridCellDegrees = 1.0
    private var spatialGrid: [GridKey: [Airspace]] = [:]

    private func gridKeyRange(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) -> (lat: ClosedRange<Int>, lon: ClosedRange<Int>) {
        let minLatKey = ((minLat / Self.gridCellDegrees).safeRoundedInt(.down, or: 0))
        let maxLatKey = ((maxLat / Self.gridCellDegrees).safeRoundedInt(.down, or: 0))
        let minLonKey = ((minLon / Self.gridCellDegrees).safeRoundedInt(.down, or: 0))
        let maxLonKey = ((maxLon / Self.gridCellDegrees).safeRoundedInt(.down, or: 0))
        return (minLatKey...maxLatKey, minLonKey...maxLonKey)
    }

    private func rebuildSpatialGrid() {
        var grid: [GridKey: [Airspace]] = [:]
        for airspace in airspaces {
            // An airspace with no bounding box has an empty polygon ring and can never pass the exact
            // check in `airspacesInBounds` (it early-returns false on `coords.isEmpty`), so it's safe —
            // and matches prior behavior exactly — to leave it out of the index entirely.
            guard let box = airspace.boundingBox else { continue }
            let keys = gridKeyRange(minLat: box.minLat, maxLat: box.maxLat, minLon: box.minLon, maxLon: box.maxLon)
            for latKey in keys.lat {
                for lonKey in keys.lon {
                    grid[GridKey(lat: latKey, lon: lonKey), default: []].append(airspace)
                }
            }
        }
        spatialGrid = grid
    }

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

        // PR-31: read + decode every country's airspace JSON off the main actor — continent-scale
        // selections are tens of MB of polygon JSON, and this runs at NavigationView.onAppear (the
        // worst moment: opening the map in flight). Only the decoded value-type arrays hop back.
        let fileURLs = metadata.lastSyncDates.keys.map { (country: $0, url: airspaceFileURL(for: $0)) }
        let result: (all: [Airspace], byCountry: [String: [Airspace]]) = await Task.detached(priority: .userInitiated) {
            let decoder = JSONDecoder()
            var loadedAirspaces: [Airspace] = []
            var byCountry: [String: [Airspace]] = [:]
            for entry in fileURLs {
                guard FileManager.default.fileExists(atPath: entry.url.path) else { continue }
                do {
                    let data = try Data(contentsOf: entry.url)
                    let countryAirspaces = try decoder.decode([Airspace].self, from: data)
                    loadedAirspaces.append(contentsOf: countryAirspaces)
                    byCountry[entry.country] = countryAirspaces
                } catch {
                    AppLog.openAIP.debugLine("Failed to load airspaces for \(entry.country): \(error)")
                }
            }
            return (loadedAirspaces, byCountry)
        }.value

        airspaces = result.all
        airspaceCount = result.all.count
        isLoaded = true
    }

    // MARK: - Data Download

    /// Check if data needs updating (older than cache expiration)
    var needsUpdate: Bool {
        guard let lastUpdate = lastUpdated else { return true }
        return Date().timeIntervalSince(lastUpdate) > OpenAIPConfig.airspaceCacheExpirationInterval
    }

    /// Rough estimate of the structured-data (GeoJSON) download size for a set of countries — the five
    /// keyless layers (airspace + navaids + obstacles + reporting points + airports) run ~5 MB/country.
    /// Approximate; the data is far smaller than the raster map tiles, which is the point. (v4.1.0)
    nonisolated static func estimatedDataSize(for countries: [String]) -> String {
        let bytes = Int64(max(1, countries.count)) * 5_000_000
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Download airspace data for selected countries from OpenAIP Core API
    /// `skippingCached` reuses a country already on disk rather than fetching it again — see the
    /// note on `OpenAIPLayerCache.downloadData`. Additive callers must still pass the union or the
    /// prune below would drop what they left out; this stops that union costing a full re-download.
    func downloadData(for countries: [String], skippingCached: Bool = false) async {
        // Mirror the navaid/obstacle/RP/airport services: an empty set is a no-op, NOT a signal to prune
        // (the removal loop below would otherwise treat subtracting([]) as "remove everything" and wipe all
        // cached airspace). Callers that prune a country pass the full remaining set.
        guard !isDownloading, !countries.isEmpty else { return }

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

            if skippingCached, metadata.airspaceCounts[country] != nil,
               let data = try? Data(contentsOf: airspaceFileURL(for: country)),
               let cached = try? JSONDecoder().decode([Airspace].self, from: data) {
                allAirspaces.append(contentsOf: cached)
                byCountry[country] = cached
                continue
            }

            do {
                let countryAirspaces = try await fetchAirspaces(for: country)
                allAirspaces.append(contentsOf: countryAirspaces)
                byCountry[country] = countryAirspaces

                // Save per-country file. Atomic so a crash/suspend mid-write (e.g. flaky inflight
                // Wi-Fi during a multi-country download) can't truncate the prior valid file and
                // silently drop that country's CTR/restricted zones on next launch.
                let encoded = try JSONEncoder().encode(countryAirspaces)
                try encoded.write(to: airspaceFileURL(for: country), options: .atomic)

                // Update metadata
                metadata.lastSyncDates[country] = Date()
                metadata.airspaceCounts[country] = countryAirspaces.count

                AppLog.openAIP.debugLine("Downloaded \(countryAirspaces.count) airspaces for \(country)")
            } catch {
                AppLog.openAIP.debugLine("Failed to download airspaces for \(country): \(error)")
                downloadError = "Failed to download data for \(OpenAIPConfig.countryName(for: country)): \(error.localizedDescription)"
                // PR-30: fall back to the existing on-disk file for this country so a failed refresh
                // doesn't drop its airspaces from memory (the data is still valid on disk). Its
                // metadata entry is preserved (we don't overwrite lastSyncDates on failure).
                if let data = try? Data(contentsOf: airspaceFileURL(for: country)),
                   let existing = try? JSONDecoder().decode([Airspace].self, from: data) {
                    allAirspaces.append(contentsOf: existing)
                    byCountry[country] = existing
                }
            }

            if Task.isCancelled { break }
        }

        // Remove countries that are no longer selected (shared with the other four OpenAIP layers).
        OpenAIPConfig.pruneDeselectedCountries(
            keeping: countries, counts: &metadata.airspaceCounts, lastSyncDates: &metadata.lastSyncDates,
            fileURL: { airspaceFileURL(for: $0) }, fileManager: fileManager)

        // Save metadata
        metadata.lastFullRefresh = Date()
        if let metaEncoded = try? JSONEncoder().encode(metadata) {
            // Atomic: a truncated metadata file fails the decode at launch and drops ALL countries
            // via the early-return guard, not just one.
            try? metaEncoded.write(to: metadataFileURL, options: .atomic)
        }

        // Update in-memory data.
        // PR-30: never replace good in-memory airspaces with an empty set produced by a totally
        // failed (e.g. offline) refresh — keep what we have. downloadedCountries is derived from the
        // persisted metadata, not the requested list, so it can't claim countries that failed.
        if !allAirspaces.isEmpty || airspaces.isEmpty {
            airspaces = allAirspaces
            airspaceCount = allAirspaces.count
        }
        downloadedCountries = metadata.lastSyncDates.keys.sorted()
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

            // ExternalRequest adds a request timeout + retry/backoff on 429/5xx & transient errors.
            let (data, httpResponse) = try await ExternalRequest.data(for: request)

            guard httpResponse.statusCode == 200 else {
                throw OpenAIPError.apiError(statusCode: httpResponse.statusCode)
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

    /// Find airspaces that intersect a map region
    func airspacesInBounds(_ region: MKCoordinateRegion) -> [Airspace] {
        guard isLoaded else { return [] }

        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2

        // Gather only the grid cells the query bounds overlap instead of scanning every downloaded
        // airspace on every throttled map-region change. Since each airspace was inserted into every
        // cell its own bbox overlaps, any airspace whose bbox truly intersects the query bounds is
        // guaranteed to share at least one cell with the query — candidates are a superset, deduped by
        // id (an airspace can span several cells within the query range too).
        let keys = gridKeyRange(minLat: minLat, maxLat: maxLat, minLon: minLon, maxLon: maxLon)
        var seenIds = Set<String>()
        var candidates: [Airspace] = []
        for latKey in keys.lat {
            for lonKey in keys.lon {
                guard let cell = spatialGrid[GridKey(lat: latKey, lon: lonKey)] else { continue }
                for airspace in cell where seenIds.insert(airspace.id).inserted {
                    candidates.append(airspace)
                }
            }
        }

        return candidates.filter { airspace in
            // Fast reject: skip any airspace whose bounding box doesn't overlap the visible region,
            // without touching its coordinate ring. (PR-11)
            if let box = airspace.boundingBox,
               !box.intersects(latRange: minLat...maxLat, lonRange: minLon...maxLon) {
                return false
            }

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

    /// Every airspace whose footprint the route enters, with the along-track distance band it spans and
    /// its vertical band — for the builder's route-profile cross-section (#4 redesign). `isConflict` is
    /// true when the extrapolated flight altitude there is within the airspace ± the buffer; the others
    /// are "context" (crossed horizontally but cleared vertically) and drawn faded. Conflicts sort
    /// first, then by start distance.
    func airspaceProfileBlocks(
        _ waypoints: [CLLocationCoordinate2D],
        altitudesFt: [Double?] = [],
        verticalBufferFt: Double = 500,
        sampleStepNM: Double = 1.0
    ) -> [AirspaceProfileBlock] {
        guard isLoaded, waypoints.count >= 2 else { return [] }
        let candidates = airspacesAlongRoute(waypoints)
        guard !candidates.isEmpty else { return [] }

        // Cumulative along-track distance per waypoint, and the known-altitude profile points.
        var cum: [Double] = [0]
        for i in 1..<waypoints.count { cum.append(cum[i - 1] + Self.distanceNM(waypoints[i - 1], waypoints[i])) }
        var profile: [(d: Double, alt: Double)] = []
        for (i, a) in altitudesFt.enumerated() where i < waypoints.count {
            if let a = a { profile.append((cum[i], a)) }
        }
        profile.sort { $0.d < $1.d }
        let hasProfile = !profile.isEmpty

        func altAt(_ d: Double) -> Double? {
            guard hasProfile else { return nil }
            if d <= profile.first!.d { return profile.first!.alt }
            if d >= profile.last!.d { return profile.last!.alt }
            for k in 1..<profile.count where d <= profile[k].d {
                let p0 = profile[k - 1], p1 = profile[k]
                let t = (d - p0.d) / max(0.0001, p1.d - p0.d)
                return p0.alt + (p1.alt - p0.alt) * t
            }
            return profile.last!.alt
        }

        // Densify into samples (endpoints + ~1 NM interpolation) carrying their along-track distance.
        var samples: [(c: CLLocationCoordinate2D, d: Double)] = []
        for i in 0..<(waypoints.count - 1) {
            let a = waypoints[i], b = waypoints[i + 1]
            let segNM = cum[i + 1] - cum[i]
            let steps = max(1, Int((segNM / max(0.1, sampleStepNM)).rounded(.up)))
            for s in 0..<steps {
                let t = Double(s) / Double(steps)
                samples.append((CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t), cum[i] + segNM * t))
            }
        }
        if let last = waypoints.last { samples.append((last, cum.last ?? 0)) }

        var blocks: [AirspaceProfileBlock] = []
        for airspace in candidates {
            var minD = Double.infinity, maxD = -Double.infinity, anyInside = false, anyVertical = false
            let floor = airspace.lowerCeiling.asFeetMSL
            let ceiling = airspace.upperCeiling.asFeetMSL
            for sample in samples where airspace.containsPoint(sample.c) {
                anyInside = true
                minD = min(minD, sample.d); maxD = max(maxD, sample.d)
                if let alt = altAt(sample.d) {
                    if alt + verticalBufferFt >= floor && alt - verticalBufferFt <= ceiling { anyVertical = true }
                } else {
                    anyVertical = true // no altitude profile → treat horizontal crossing as a conflict
                }
            }
            guard anyInside else { continue }
            blocks.append(AirspaceProfileBlock(airspace: airspace, startNM: minD, endNM: maxD,
                                               floorFt: floor, ceilingFt: ceiling, isConflict: anyVertical))
        }
        return blocks.sorted { a, b in
            if a.isConflict != b.isConflict { return a.isConflict }
            if a.airspace.isRestrictive != b.airspace.isRestrictive { return a.airspace.isRestrictive }
            return a.startNM < b.startNM
        }
    }

    private static func distanceNM(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1852.0
    }

    /// Find nearby CTR airspaces sorted by distance
    /// Returns all nearby CTRs regardless of altitude — UI handles altitude-based highlighting
    /// When `requireFrequencies` is true (default), only returns CTRs with frequency data
    func nearbyCTRs(from coordinate: CLLocationCoordinate2D, withinNM distance: Double = 20.0, requireFrequencies: Bool = false) -> [(airspace: Airspace, distanceNM: Double)] {
        guard isLoaded else { return [] }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let maxDistanceMeters = distance * 1852

        // Gather candidates from the spatial grid instead of scanning every airspace. The grid is
        // already built and maintained for `airspacesInBounds`; this query simply never used it, so
        // it ran a full linear scan of the whole loaded dataset — on the in-flight FREQ path, which
        // re-runs as the aircraft moves. (APP-11, same fix as PERF-27 got for navaids)
        //
        // The search box is the lat/lon envelope of `distance`, widened by one cell so a CTR whose
        // centroid sits just outside the box but within range still appears. Longitude degrees
        // shrink with latitude, so the lon half-width is divided by cos(lat); clamped because that
        // term explodes near the poles.
        let latDelta = distance / 60.0 + Self.gridCellDegrees
        let cosLat = max(cos(coordinate.latitude * .pi / 180.0), 0.01)
        let lonDelta = min(distance / 60.0 / cosLat + Self.gridCellDegrees, 180.0)
        let keys = gridKeyRange(
            minLat: coordinate.latitude - latDelta, maxLat: coordinate.latitude + latDelta,
            minLon: coordinate.longitude - lonDelta, maxLon: coordinate.longitude + lonDelta
        )
        var seenIds = Set<String>()
        var candidates: [Airspace] = []
        for latKey in keys.lat {
            for lonKey in keys.lon {
                guard let cell = spatialGrid[GridKey(lat: latKey, lon: lonKey)] else { continue }
                for airspace in cell where seenIds.insert(airspace.id).inserted {
                    candidates.append(airspace)
                }
            }
        }

        return candidates
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
                AppLog.openAIP.debugLine("Rate limited (429), backing off")
                isStreamingFetchInProgress = false
                return
            }

            guard httpResponse.statusCode == 200 else {
                consecutiveStreamingErrors += 1
                AppLog.openAIP.debugLine("API error: HTTP \(httpResponse.statusCode)")
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

            // Don't log the user's coordinates: debugLine forces .public privacy and persists to the
            // unified log (captured in sysdiagnose). Count only — no position. (v4.1.0 pre-tag fix)
            AppLog.openAIP.debugLine("Fetched \(decoded.items.count) CTRs near current position")
        } catch {
            consecutiveStreamingErrors += 1
            AppLog.openAIP.debugLine("Fetch failed: \(error.localizedDescription)")
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
            airspaceCount = 0
            downloadedCountries = []
            lastUpdated = nil
            isDataAvailable = false
            isLoaded = false
        } catch {
            downloadError = "Failed to delete data: \(error.localizedDescription)"
        }
    }

    #if DEBUG
    /// Test seam: seed in-memory airspaces without a network download. Mirrors
    /// `OpenAIPNavaidDataService.seedForTesting`.
    func seedForTesting(_ seeded: [Airspace]) {
        airspaces = seeded
        airspaceCount = seeded.count
        isLoaded = true
    }
    #endif
}

// MARK: - Errors

enum OpenAIPError: LocalizedError {
    case invalidURL
    case apiError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid API URL"
        case .apiError(let code): return "API error (HTTP \(code))"
        }
    }
}
