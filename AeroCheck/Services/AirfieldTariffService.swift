import Foundation

/// Where an aerodrome publishes its own landing-fee tariff, from `/api/v3/airfields/tariffs`.
///
/// The server serves links, not amounts — the only automatable fee dataset is licence-forbidden for
/// a commercial app and was wrong in seven of eight spot checks, and a landing fee is a function of
/// MTOW band, noise class, flight nature, homebase and VAT rather than a single number. So the app
/// takes the pilot to the operator's own page and records what they actually paid.
struct AirfieldTariff: Codable, Identifiable, Equatable, Sendable {
    let icao: String
    let name: String
    let url: String
    let country: String
    let format: String
    let validFrom: String?
    let notPublished: Bool?
    let note: String?
    let checkedAt: String?
    /// When the page last CHANGED — not when a fee changed. A "worth a look" signal.
    let changedAt: String?
    let unreachable: Bool?

    var id: String { icao }
    var destination: URL? { URL(string: url) }
    var publishesTariff: Bool { notPublished != true }
}

/// Fetches and caches the tariff registry.
///
/// Cached on disk with a long life on purpose: the registry changes when someone adds an aerodrome,
/// which is a deploy, and the server itself only re-checks the pages quarterly. A pilot planning a
/// flight offline should still get the link they saw last week.
@MainActor
final class AirfieldTariffService: ObservableObject {
    static let shared = AirfieldTariffService()

    @Published private(set) var tariffs: [String: AirfieldTariff] = [:]
    @Published private(set) var isLoading = false

    /// A week. Well inside the server's quarterly re-check, and far outside a planning session.
    private let maxAge: TimeInterval = 7 * 24 * 60 * 60
    private var lastFetch: Date?

    private var cacheURL: URL {
        DataPersistenceManager.shared.localAppDirectory
            .appendingPathComponent("airfield-tariffs.json")
    }

    private init() {
        loadCache()
    }

    func tariff(for icao: String) -> AirfieldTariff? {
        tariffs[icao.trimmingCharacters(in: .whitespaces).uppercased()]
    }

    /// Refresh if the cache is stale. Silent on failure — a missing link is a missing convenience,
    /// never an error worth interrupting a pilot for.
    func refreshIfNeeded(country: String? = nil) async {
        if let lastFetch, Date().timeIntervalSince(lastFetch) < maxAge, !tariffs.isEmpty { return }
        await refresh(country: country)
    }

    func refresh(country: String? = nil) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        var components = URLComponents(string: "\(APIConfig.baseURL)/api/v3/airfields/tariffs")
        if let country { components?.queryItems = [URLQueryItem(name: "country", value: country)] }
        guard let url = components?.url else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // The app-client hurdle. Absent when Secrets.xcconfig is missing, which is exactly when a
        // repository clone should be refused — the worker fails open only if IT has no list set.
        if let secret = APIConfig.appClientSecret {
            request.setValue(secret, forHTTPHeaderField: "X-AeroCheck-Client")
        }

        do {
            let (data, response) = try await ExternalRequest.data(for: request)
            // `ExternalRequest.data(for:)` already returns an `HTTPURLResponse`, so the casts this
            // used to do could never fail and the compiler said so.
            guard response.statusCode == 200 else {
                AppLog.general.debugLine("Tariff registry fetch failed: \(response.statusCode)")
                return
            }
            let decoded = try JSONDecoder().decode(TariffResponse.self, from: data)
            guard decoded.success else { return }

            tariffs = Dictionary(decoded.data.tariffs.map { ($0.icao, $0) }, uniquingKeysWith: { first, _ in first })
            lastFetch = Date()
            saveCache(decoded.data.tariffs)
        } catch {
            AppLog.general.debugLine("Tariff registry fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Cache

    private func loadCache() {
        // `.iso8601` on BOTH sides. `saveCache` encodes `fetchedAt` as "2026-09-06T20:39:35Z" while
        // this decoded with a default JSONDecoder, whose `.deferredToDate` wants a Double — so the
        // decode always failed, the guard always bailed, and the cache was write-only. The offline
        // promise ("a pilot planning a flight offline should still get the link they saw last week")
        // never held, and `lastFetch` never restored either, so every launch re-fetched. (review F24)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? decoder.decode(CachedRegistry.self, from: data) else { return }
        tariffs = Dictionary(cached.tariffs.map { ($0.icao, $0) }, uniquingKeysWith: { first, _ in first })
        lastFetch = cached.fetchedAt
    }

    private func saveCache(_ tariffs: [AirfieldTariff]) {
        let payload = CachedRegistry(fetchedAt: Date(), tariffs: tariffs)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(payload).write(to: cacheURL, options: DataPersistenceManager.protectedWriteOptions)
        } catch {
            AppLog.general.debugLine("Failed to cache tariff registry: \(error.localizedDescription)")
        }
    }

    /// Seeded directly in tests, so no test has to reach the network.
    func seedForTesting(_ seeded: [AirfieldTariff]) {
        tariffs = Dictionary(seeded.map { ($0.icao, $0) }, uniquingKeysWith: { first, _ in first })
        lastFetch = Date()
    }

    private struct TariffResponse: Decodable {
        let success: Bool
        let data: Payload
        struct Payload: Decodable { let tariffs: [AirfieldTariff] }
    }

    private struct CachedRegistry: Codable {
        let fetchedAt: Date
        let tariffs: [AirfieldTariff]
    }
}
