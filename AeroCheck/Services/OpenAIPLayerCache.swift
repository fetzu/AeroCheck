import Foundation

/// On-disk metadata for a per-country OpenAIP layer cache (per-country last-sync + count).
///
/// One shared shape for all four keyless GeoJSON-export layers (airports, navaids, obstacles,
/// reporting points). Encodes to JSON byte-identical to the former per-service structs
/// (`OpenAIPAirportCacheMetadata`, `NavaidCacheMetadata`, `ObstacleCacheMetadata`,
/// `ReportingPointCacheMetadata` — same keys, same default `Date` strategy), so every existing
/// user cache keeps decoding unchanged.
struct OpenAIPLayerCacheMetadata: Codable {
    var lastSyncDates: [String: Date] = [:]
    var counts: [String: Int] = [:]
}

/// Shared cache + download lifecycle for the per-country OpenAIP GeoJSON-export layers.
///
/// The four layer services (`OpenAIPAirportDataService`, `OpenAIPNavaidDataService`,
/// `OpenAIPObstacleDataService`, `OpenAIPReportingPointDataService`) previously each carried a
/// near line-for-line copy of the same directory layout, metadata restore, lazy local load,
/// integrity-preserving download loop, prune and delete. Each service now owns one of these,
/// parameterized by its on-disk names, export-endpoint suffix, log label and GeoJSON parser —
/// composition, so each service keeps its own `@Published` surface, spatial grid and queries.
///
/// On-disk layout (unchanged from the per-service copies):
/// `Application Support/<directoryName>/metadata.json` + `<filePrefix>_<COUNTRY>.json` per country.
///
/// NOT in scope: `OpenAIPDataService` (airspace) — it has a different pipeline (REST pagination,
/// streaming fallback, `OpenAIPCacheManager`) and stays separate.
@MainActor
final class OpenAIPLayerCache<Feature: Codable & Sendable> {

    /// Published-state snapshot derived from the on-disk metadata.
    struct Summary {
        let downloadedCountries: [String]
        let totalCount: Int
        let lastUpdated: Date?
        var isDataAvailable: Bool { !downloadedCountries.isEmpty }

        init(metadata: OpenAIPLayerCacheMetadata) {
            downloadedCountries = metadata.counts.keys.sorted()
            totalCount = metadata.counts.values.reduce(0, +)
            lastUpdated = metadata.lastSyncDates.values.max()
        }
    }

    struct DownloadResult {
        let features: [Feature]
        let summary: Summary
        /// Countries no source could serve. Callers surface this instead of silently re-offering a
        /// download button that cannot succeed. (v4.4.0)
        var failedCountries: [String] = []
    }

    private let fileManager = FileManager.default
    private let directoryName: String
    private let filePrefix: String
    private let endpointSuffix: String
    private let restPath: String
    private let logLabel: String
    private let parse: (Data) throws -> [Feature]

    /// - Parameters:
    ///   - directoryName: Application Support subdirectory (e.g. `"OpenAIPNavaidData"`).
    ///   - filePrefix: per-country file prefix (e.g. `"navaids"` → `navaids_CH.json`).
    ///   - endpointSuffix: GeoJSON-export layer suffix (e.g. `"nav"` → `ch_nav.geojson`).
    ///   - restPath: core-API collection for the same layer (e.g. `"navaids"`), used as the fallback
    ///     when the export bucket refuses the request.
    ///   - logLabel: prefix for the per-country download-failure debug line (kept verbatim from
    ///     each service's previous message, e.g. `"Navaid"` / `"OpenAIP airport"`).
    ///   - parse: the layer's GeoJSON parser (e.g. `Navaid.parse(geoJSON:)`).
    init(directoryName: String,
         filePrefix: String,
         endpointSuffix: String,
         restPath: String,
         logLabel: String,
         parse: @escaping (Data) throws -> [Feature]) {
        self.directoryName = directoryName
        self.filePrefix = filePrefix
        self.endpointSuffix = endpointSuffix
        self.restPath = restPath
        self.logLabel = logLabel
        self.parse = parse
    }

    // MARK: - Storage paths

    private var dataDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }
    private var metadataFileURL: URL { dataDirectory.appendingPathComponent("metadata.json") }
    private func featureFileURL(for country: String) -> URL {
        dataDirectory.appendingPathComponent("\(filePrefix)_\(country).json")
    }

    // MARK: - Metadata restore (service init)

    /// Restore lightweight metadata (counts/dates) without loading the features into memory.
    /// Returns nil when no readable metadata exists (fresh install / wiped cache).
    func restoredSummary() -> Summary? {
        guard let data = try? Data(contentsOf: metadataFileURL),
              let metadata = try? JSONDecoder().decode(OpenAIPLayerCacheMetadata.self, from: data) else { return nil }
        return Summary(metadata: metadata)
    }

    /// Stale once older than the shared aeronautical-data TTL (90 days).
    func isStale(lastUpdated: Date?) -> Bool {
        guard let lastUpdated else { return true }
        return Date().timeIntervalSince(lastUpdated) > OpenAIPConfig.airspaceCacheExpirationInterval
    }

    // MARK: - Load

    /// Decode every downloaded country file off the main actor. Returns nil when no readable
    /// metadata exists, so the caller leaves its `isLoaded` flag untouched and can retry later.
    func loadFromLocal() async -> [Feature]? {
        guard let metaData = try? Data(contentsOf: metadataFileURL),
              let metadata = try? JSONDecoder().decode(OpenAIPLayerCacheMetadata.self, from: metaData) else { return nil }
        let urls = metadata.counts.keys.map { featureFileURL(for: $0) }
        return await Task.detached(priority: .userInitiated) {
            let decoder = JSONDecoder()
            var all: [Feature] = []
            for url in urls {
                guard let data = try? Data(contentsOf: url),
                      let decoded = try? decoder.decode([Feature].self, from: data) else { continue }
                all.append(contentsOf: decoded)
            }
            return all
        }.value
    }

    // MARK: - Download (keyless GeoJSON exports)

    /// Download + cache the layer for the given countries from the public, keyless GeoJSON exports.
    /// A per-country failure keeps that country's existing cache rather than dropping it.
    /// `onProgress` is called on the main actor after each completed country.
    func downloadData(for countries: [String], onProgress: (Double) -> Void) async -> DownloadResult {
        try? fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        DataPersistenceManager.excludeFromBackup(dataDirectory) // SEC-C28
        var metadata = (try? Data(contentsOf: metadataFileURL))
            .flatMap { try? JSONDecoder().decode(OpenAIPLayerCacheMetadata.self, from: $0) } ?? OpenAIPLayerCacheMetadata()
        var allLoaded: [Feature] = []

        var failed: [String] = []
        for (index, country) in countries.enumerated() {
            do {
                // Bucket first (one request), core API second (paged). See `fetchViaCoreAPI`.
                let parsed: [Feature]
                if let fromBucket = try await fetchViaExportBucket(country: country) {
                    parsed = fromBucket
                } else {
                    parsed = try await fetchViaCoreAPI(country: country)
                }
                let encoded = try JSONEncoder().encode(parsed)
                try encoded.write(to: featureFileURL(for: country), options: .atomic)
                metadata.counts[country] = parsed.count
                metadata.lastSyncDates[country] = Date()
                allLoaded.append(contentsOf: parsed)
            } catch {
                AppLog.openAIP.debugLine("\(logLabel) download failed for \(country): \(error)")
                failed.append(country)
                appendExistingCache(for: country, into: &allLoaded)
            }
            onProgress(Double(index + 1) / Double(countries.count))
        }

        // De-selected countries are pruned (file + metadata) so this layer matches the requested set —
        // consistent with the airspace layer. Additive callers (trip-prefetch, builder, refresh) union
        // before calling, so they pass the full set and lose nothing. (download-integrity fix)
        OpenAIPConfig.pruneDeselectedCountries(
            keeping: countries, counts: &metadata.counts, lastSyncDates: &metadata.lastSyncDates,
            fileURL: { featureFileURL(for: $0) }, fileManager: fileManager)
        if let metaEncoded = try? JSONEncoder().encode(metadata) {
            try? metaEncoded.write(to: metadataFileURL, options: .atomic)
        }
        return DownloadResult(features: allLoaded, summary: Summary(metadata: metadata),
                              failedCountries: failed)
    }

    // MARK: - Sources

    /// The keyless per-country GeoJSON export. Returns nil — rather than throwing — when the bucket
    /// refuses the request, so the caller moves on to the core API instead of recording a failure.
    private func fetchViaExportBucket(country: String) async throws -> [Feature]? {
        let cc = country.lowercased()
        guard let url = URL(string: "\(OpenAIPConfig.geoJSONExportBaseURL)/\(cc)_\(endpointSuffix).geojson") else { return nil }
        do {
            let (data, response) = try await ExternalRequest.data(from: url)
            guard response.statusCode == 200 else {
                AppLog.openAIP.debugLine("\(logLabel) export bucket returned \(response.statusCode) for \(country); trying core API")
                return nil
            }
            return try parse(data)
        } catch {
            AppLog.openAIP.debugLine("\(logLabel) export bucket unreachable for \(country) (\(error)); trying core API")
            return nil
        }
    }

    /// The authenticated core REST API, paged, reshaped into the export's FeatureCollection form.
    ///
    /// This exists because the export bucket went Requester Pays in July 2026 and now 400s every
    /// anonymous read (see `OpenAIPConfig.geoJSONExportBaseURL`) — which silently took navaids,
    /// obstacles, reporting points and OpenAIP airports out of the app while airspace, alone in coming
    /// from the REST API, kept working. That asymmetry is what made "Download data" spin for ten
    /// seconds and leave the banner up.
    ///
    /// No new parsers: a core-API item is a GeoJSON feature turned inside out — the same property keys
    /// at the top level, with `geometry` beside them instead of wrapping them. Rebuilding the
    /// FeatureCollection shape is a re-nesting, so every layer keeps its existing lossy, hardened
    /// decoder rather than gaining a second one to keep in sync.
    private func fetchViaCoreAPI(country: String) async throws -> [Feature] {
        var items: [Any] = []
        var page = 1
        while page <= OpenAIPConfig.layerMaxPages {
            let urlString = "\(OpenAIPConfig.coreAPIBaseURL)/\(restPath)"
                + "?country=\(country)&limit=\(OpenAIPConfig.layerPageLimit)&page=\(page)"
            guard let url = URL(string: urlString) else { throw OpenAIPLayerCacheError.invalidURL }
            var request = URLRequest(url: url)
            request.setValue(OpenAIPConfig.apiKey, forHTTPHeaderField: OpenAIPConfig.apiKeyHeader)
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await ExternalRequest.data(for: request)
            guard response.statusCode == 200 else {
                throw OpenAIPLayerCacheError.apiError(statusCode: response.statusCode)
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pageItems = object["items"] as? [Any] else {
                throw OpenAIPLayerCacheError.malformedResponse
            }
            items.append(contentsOf: pageItems)
            let totalPages = (object["totalPages"] as? Int) ?? page
            if page >= totalPages { break }
            page += 1
        }

        return try parse(Self.featureCollectionData(fromCoreAPIItems: items))
    }

    /// Re-nests core-API items into the export's FeatureCollection shape.
    ///
    /// Pure and `nonisolated` so it can be tested against real payloads without a network or an actor
    /// hop. An item without a `geometry` is dropped here rather than reaching the parser as a feature
    /// it would have to reject — matching the export's own lossy-per-feature contract.
    nonisolated static func featureCollectionData(fromCoreAPIItems items: [Any]) throws -> Data {
        let features = items.compactMap { item -> [String: Any]? in
            guard let properties = item as? [String: Any],
                  let geometry = properties["geometry"] else { return nil }
            return ["type": "Feature", "properties": properties, "geometry": geometry]
        }
        let collection: [String: Any] = ["type": "FeatureCollection", "features": features]
        return try JSONSerialization.data(withJSONObject: collection)
    }

    private func appendExistingCache(for country: String, into accumulator: inout [Feature]) {
        if let data = try? Data(contentsOf: featureFileURL(for: country)),
           let decoded = try? JSONDecoder().decode([Feature].self, from: data) {
            accumulator.append(contentsOf: decoded)
        }
    }

    // MARK: - Delete

    func deleteData() {
        try? fileManager.removeItem(at: dataDirectory)
    }
}

enum OpenAIPLayerCacheError: LocalizedError {
    case invalidURL
    case apiError(statusCode: Int)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid OpenAIP URL"
        case .apiError(let statusCode): return "OpenAIP API error \(statusCode)"
        case .malformedResponse: return "Malformed OpenAIP response"
        }
    }
}
