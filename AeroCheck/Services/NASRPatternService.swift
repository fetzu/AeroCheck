import Foundation

/// The traffic patterns of the US public-use airports, from the FAA's NASR through the AeroCheck server
/// (`/data/nasr/v1/us.json`, built in its private data job): the side the pattern turns at each runway end and the
/// pattern altitude where the FAA publishes one, its remarks about it word for word. No circuit shape exists in US
/// data, and the app draws none. Public domain (17 U.S.C. § 105). (6.5.0, the author's q6: the side and the TPA on
/// the approach view, the remark in the approach briefing)
struct NASRPatterns: Codable, Equatable, Sendable {
    static let schema = 1

    let v: Int
    /// The NASR cycle, "2610".
    let cycle: String?
    let aerodromes: [String: Aerodrome]

    /// Left unless the FAA flags right-hand traffic (14 CFR 91.126(b)(1), AIM 4-3-3).
    enum Side: String, Codable, Sendable {
        case left = "L", right = "R"
    }

    struct End: Codable, Equatable, Sendable {
        /// "31", "13L".
        let rwy: String
        let pattern: Side
    }

    /// The pattern altitude, only where it differs from the AIM's recommendation: whole feet above the field, and
    /// above sea level as the Chart Supplement prints it ("TPA—806(800)").
    struct TPA: Codable, Equatable, Sendable {
        let agl: Int
        let msl: Int?
    }

    struct Aerodrome: Codable, Equatable, Sendable {
        var tpa: TPA?
        /// The airport's remarks naming a TPA, as the FAA wrote them: shown as written, never read for a figure.
        var tpaRemark: String?
        var ends: [End] = []

        /// The side of `runway`'s pattern ("31"), matching "31" to "31" and "13L" to "13L".
        func side(of runway: String) -> Side? {
            ends.first { $0.rwy.uppercased() == runway.uppercased() }?.pattern
        }
    }

    func aerodrome(_ ident: String) -> Aerodrome? { aerodromes[ident.uppercased()] }

    init(v: Int = NASRPatterns.schema, cycle: String? = nil, aerodromes: [String: Aerodrome]) {
        self.v = v
        self.cycle = cycle
        self.aerodromes = aerodromes
    }

    // Lenient, as the other files the server builds: an airport or an end this build can't read is left out.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        cycle = try? c.decodeIfPresent(String.self, forKey: .cycle)
        var read: [String: Aerodrome] = [:]
        if let entries = try? c.nestedContainer(keyedBy: BriefingRegistry.AnyKey.self, forKey: .aerodromes) {
            for key in entries.allKeys {
                if let aerodrome = try? entries.decode(Aerodrome.self, forKey: key) { read[key.stringValue.uppercased()] = aerodrome }
            }
        }
        aerodromes = read
    }

    private enum CodingKeys: String, CodingKey { case v, cycle, aerodromes }
}

extension NASRPatterns.Aerodrome {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tpa = try? c.decodeIfPresent(NASRPatterns.TPA.self, forKey: .tpa)
        tpaRemark = (try? c.decodeIfPresent(String.self, forKey: .tpaRemark)).flatMap { $0 }
        var ends: [NASRPatterns.End] = []
        if var list = try? c.nestedUnkeyedContainer(forKey: .ends) {
            while !list.isAtEnd {
                if let end = try? list.decode(NASRPatterns.End.self) { ends.append(end) } else { _ = try? list.decode(Skipped.self) }
            }
        }
        self.ends = ends
    }

    private struct Skipped: Decodable {}
}

/// Loads the NASR patterns the first time a US field asks for them, never at launch: 1.2 MB a Swiss pilot never
/// needs. From the disk cache when it is less than a week old, else from the server; silent on failure. (6.5.0)
@MainActor
final class NASRPatternService: ObservableObject {
    static let shared = NASRPatternService()

    static let fileURL = APIConfig.dataURL("nasr/v1/us.json")
    static let allowedHosts = Set([fileURL.host?.lowercased()].compactMap { $0 })
    /// About 1.2 MB in 2610; the job refuses to publish one over 2 MB.
    static let maxBytes = 3 * 1024 * 1024
    /// A week, the job's rhythm (NASR's own cycle is 28 days).
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    @Published private(set) var patterns: NASRPatterns?
    /// Bumped when the patterns arrive: the map redraws its approach view.
    @Published private(set) var revision = 0
    private var loading = false
    private var lastFetch: Date?

    private let cacheURL: URL
    private let fetchOverride: ((URL) async throws -> Data)?
    private let now: () -> Date

    init(cacheURL: URL? = nil, fetch: ((URL) async throws -> Data)? = nil, now: @escaping () -> Date = Date.init) {
        self.cacheURL = cacheURL ?? DataPersistenceManager.shared.localAppDirectory.appendingPathComponent("nasr-us.json")
        self.fetchOverride = fetch
        self.now = now
    }

    /// A US field's pattern, when loaded; asks for the file the first time.
    func aerodrome(_ ident: String) -> NASRPatterns.Aerodrome? {
        if patterns == nil { Task { await loadIfNeeded() } }
        return patterns?.aerodrome(ident)
    }

    func loadIfNeeded() async {
        guard !loading else { return }
        if patterns == nil { loadCache() }
        if let lastFetch, now().timeIntervalSince(lastFetch) < Self.maxAge, now() >= lastFetch { return }
        loading = true
        defer { loading = false }
        do {
            let data = try await fetch(Self.fileURL)
            let decoded = try JSONDecoder().decode(NASRPatterns.self, from: data)
            guard decoded.v == NASRPatterns.schema, !decoded.aerodromes.isEmpty else { return }
            patterns = decoded
            lastFetch = now()
            revision += 1
            saveCache(data)
        } catch {
            AppLog.general.debugLine("NASR patterns fetch failed: \(error.localizedDescription)")
        }
    }

    private enum FetchError: Error { case http(Int), tooLarge }

    private func fetch(_ url: URL) async throws -> Data {
        guard ExternalRequest.isAllowed(url, hosts: Self.allowedHosts) else { throw ExternalRequest.HostError.notAllowed }
        let data: Data
        if let fetchOverride {
            data = try await fetchOverride(url)
        } else {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let secret = APIConfig.appClientSecret {
                request.setValue(secret, forHTTPHeaderField: "X-AeroCheck-Client")
            }
            let (body, response) = try await ExternalRequest.data(for: request, maxResponseBytes: Self.maxBytes,
                                                                  allowedHosts: Self.allowedHosts)
            guard response.statusCode == 200 else { throw FetchError.http(response.statusCode) }
            data = body
        }
        guard data.count <= Self.maxBytes else { throw FetchError.tooLarge }
        return data
    }

    // MARK: Cache: the file as served, its date the file's

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(NASRPatterns.self, from: data),
              decoded.v == NASRPatterns.schema, !decoded.aerodromes.isEmpty else { return }
        patterns = decoded
        lastFetch = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        revision += 1
    }

    private func saveCache(_ data: Data) {
        do {
            try data.write(to: cacheURL, options: DataPersistenceManager.protectedWriteOptions)
        } catch {
            AppLog.general.debugLine("Failed to cache the NASR patterns: \(error.localizedDescription)")
        }
    }

    /// Seeded directly in tests and previews (nil empties it).
    func seedForTesting(_ seeded: NASRPatterns?) {
        patterns = seeded
        lastFetch = seeded == nil ? nil : now()
        revision += 1
    }
}
