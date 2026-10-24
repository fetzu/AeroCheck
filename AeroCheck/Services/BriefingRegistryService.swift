import Foundation

/// Fetches and caches the briefing registry, as `OfficialChartService` does the chart links: on disk, refreshed when a
/// week old, silent on failure. Until the first download (a first launch offline, at the club) the app reads the copy
/// it shipped with, `briefing-registry.json`, refreshed at every release by `scripts/sync-briefing-registry.sh`: a
/// Swiss pilot planning before any network still gets the DABS and the numbers to call. (6.5.0, decision q7)
@MainActor
final class BriefingRegistryService: ObservableObject {
    static let shared = BriefingRegistryService()

    static let registryURL = APIConfig.dataURL("briefing/v1/briefing.json")
    static let allowedHosts = Set([registryURL.host?.lowercased()].compactMap { $0 })
    /// About 75 KB for 42 countries in 2610.
    static let maxBytes = 1024 * 1024
    /// A week, the job's own rhythm.
    nonisolated static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    /// The registry the app reads: the last download, else the copy it shipped with.
    @Published private(set) var registry: BriefingRegistry?
    @Published private(set) var isLoading = false
    /// When the registry in use was downloaded; nil while it is the shipped copy.
    private(set) var lastFetch: Date?
    private var generation = 0

    private let cacheURL: URL
    private let fetchOverride: ((URL) async throws -> Data)?
    private let now: () -> Date

    /// - Parameters:
    ///   - cacheURL: tests only; where the cache lives instead of the app's directory.
    ///   - bundled: tests only; the shipped copy (nil reads the app bundle's).
    ///   - fetch: tests only; replaces the network (URL in, body out).
    ///   - now: the clock, for the cache's age.
    init(cacheURL: URL? = nil, bundled: Data? = nil, fetch: ((URL) async throws -> Data)? = nil,
         now: @escaping () -> Date = Date.init) {
        self.cacheURL = cacheURL
            ?? DataPersistenceManager.shared.localAppDirectory.appendingPathComponent("briefing-registry.json")
        self.fetchOverride = fetch
        self.now = now
        loadCache()
        if registry == nil {
            registry = Self.decodeShipped(bundled ?? Self.shippedData())
        }
    }

    var isStale: Bool {
        guard let lastFetch else { return true }
        let age = now().timeIntervalSince(lastFetch)
        return age < 0 || age >= Self.maxAge
    }

    /// Refresh when stale. Silent on failure.
    func refreshIfNeeded() async {
        guard isStale else { return }
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let started = generation
        do {
            let data = try await fetch(Self.registryURL)
            let decoded = try JSONDecoder().decode(BriefingRegistry.self, from: data)
            guard started == generation else { return }
            guard decoded.v == BriefingRegistry.schema else {
                AppLog.general.publicLine("Briefing registry: schema \(decoded.v) not read")
                return
            }
            guard !decoded.countries.isEmpty else { return }
            registry = decoded
            lastFetch = now()
            saveCache(decoded)
        } catch {
            AppLog.general.debugLine("Briefing registry fetch failed: \(error.localizedDescription)")
        }
    }

    private enum FetchError: Error { case http(Int), tooLarge }

    /// GET the registry: on the allow-list, under the size cap, a 200, with the API's app-client hurdle.
    private func fetch(_ url: URL) async throws -> Data {
        guard ExternalRequest.isAllowed(url, hosts: Self.allowedHosts) else { throw ExternalRequest.HostError.notAllowed }
        let data: Data
        if let fetchOverride {
            data = try await fetchOverride(url)
        } else {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let secret = APIConfig.appClientSecret {
                request.setValue(secret, forHTTPHeaderField: "X-AeroCheck-Client")
            }
            let (body, response) = try await ExternalRequest.data(
                for: request, maxResponseBytes: Self.maxBytes, allowedHosts: Self.allowedHosts)
            guard response.statusCode == 200 else { throw FetchError.http(response.statusCode) }
            data = body
        }
        guard data.count <= Self.maxBytes else { throw FetchError.tooLarge }
        return data
    }

    // MARK: The shipped copy

    /// The shipped copy, decoded once: for what runs off the main actor (a trip rebuilt at load).
    nonisolated static let shipped: BriefingRegistry? = decodeShipped(shippedData())

    nonisolated static func shippedData() -> Data? {
        Bundle.main.url(forResource: "briefing-registry", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
    }

    nonisolated static func decodeShipped(_ data: Data?) -> BriefingRegistry? {
        guard let data, let decoded = try? JSONDecoder().decode(BriefingRegistry.self, from: data),
              decoded.v == BriefingRegistry.schema, !decoded.countries.isEmpty else { return nil }
        return decoded
    }

    // MARK: Cache

    private struct CachedRegistry: Codable {
        let fetchedAt: Date
        let registry: BriefingRegistry
        /// The address it was read from: a cache from the other server (a switch between TestFlight and the App
        /// Store) keeps its links offline but counts as stale.
        let source: String
        /// The app build that read it; nil before 6.6.0. A cache is what that build could decode, re-encoded: a build
        /// before 6.6.0 dropped the filing lead times it can't read, so another build counts it as stale and fetches
        /// anew, keeping its links meanwhile, as the chart links' cache does since 6.5.0.
        var build: String?
    }

    private func loadCache() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? decoder.decode(CachedRegistry.self, from: data),
              cached.registry.v == BriefingRegistry.schema, !cached.registry.countries.isEmpty else { return }
        registry = cached.registry
        lastFetch = cached.source == Self.registryURL.absoluteString && cached.build == OfficialChartService.appBuild
            ? cached.fetchedAt : nil
    }

    private func saveCache(_ registry: BriefingRegistry) {
        guard let fetchedAt = lastFetch else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(CachedRegistry(fetchedAt: fetchedAt, registry: registry,
                                              source: Self.registryURL.absoluteString, build: OfficialChartService.appBuild))
                .write(to: cacheURL, options: DataPersistenceManager.protectedWriteOptions)
        } catch {
            AppLog.general.debugLine("Failed to cache the briefing registry: \(error.localizedDescription)")
        }
    }

    /// Seeded directly in tests and previews, so nothing has to reach the network (nil empties it).
    func seedForTesting(_ seeded: BriefingRegistry?, fetchedAt: Date? = nil) {
        generation += 1
        registry = seeded
        lastFetch = seeded == nil ? nil : (fetchedAt ?? now())
    }
}
