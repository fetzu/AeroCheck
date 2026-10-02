import Foundation

// MARK: - The link

/// Where the official chart of one aerodrome lives: a page or a PDF on its publisher's site, opened in
/// the browser. A link and nothing more: the app never downloads, copies or shows a chart, so the AIP
/// stays the source and its amendments reach the pilot without the app knowing about them. (6.2.0)
struct OfficialChartLink: Equatable, Sendable {
    let icao: String
    /// The country of the AIP that publishes it (the registry's key).
    let country: String
    let url: URL
    /// "DFS", "SIA", "SkyBriefing", "Austro Control": a brand, the same in both languages.
    let publisher: String
    /// Behind a login (SkyBriefing's VFR Manual also wants a subscription): said on the button, so a
    /// tap that lands on a sign-in page is no surprise.
    let requiresLogin: Bool

    /// "Official chart", or "Official chart · SkyBriefing (subscription)".
    var title: String {
        requiresLogin
            ? "\(L10n.OfficialChart.title) · \(L10n.OfficialChart.subscription(publisher))"
            : L10n.OfficialChart.title
    }

    /// The subscription note alone, for a button that has room for a second line.
    var note: String? { requiresLogin ? L10n.OfficialChart.subscription(publisher) : nil }

    /// What VoiceOver adds: "Opens SkyBriefing in the browser".
    var accessibilityHint: String { L10n.OfficialChart.opens(publisher) }

    /// A document, locked when it needs a login.
    var symbolName: String { requiresLogin ? "lock.doc" : "doc.richtext" }
}

// MARK: - The registry (charts.json, schema v1)

/// `https://aerocheck.app/data/charts/v1/charts.json`: how each country turns an ICAO code into its
/// official chart. Published weekly by `scripts/vfrdata/charts_registry.py` on the `website` branch,
/// which HEAD-checks a sample of every country and leaves out the ones that fail, so the app never has
/// to judge a link itself. Decoded leniently: a country the app can't read is skipped, never the file.
struct OfficialChartRegistry: Codable, Equatable, Sendable {
    static let schema = 1

    let v: Int
    /// When the job last changed the file (it only moves when the content does).
    let generated: String?
    let countries: [String: Country]

    /// One country's entry. `kind` says which fields it uses:
    /// - `dfs-basicvfr`: `base` + `pages[ICAO]` + `.html` (DE);
    /// - `sia-vac`: `template` with `{icao}`, in the folder of AIRAC `airac` (FR);
    /// - `skybriefing-vfr-manual`: one `url` for every aerodrome, `login` (CH);
    /// - `eaip`: one `url`, the eAIP's start page (AT).
    struct Country: Codable, Equatable, Sendable {
        let kind: String
        var base: String?
        var pages: [String: String]?
        var template: String?
        var airac: String?
        var url: String?
        var login: Bool?

        init(kind: String, base: String? = nil, pages: [String: String]? = nil, template: String? = nil,
             airac: String? = nil, url: String? = nil, login: Bool? = nil) {
            self.kind = kind
            self.base = base
            self.pages = pages
            self.template = template
            self.airac = airac
            self.url = url
            self.login = login
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(String.self, forKey: .kind)
            base = try? container.decodeIfPresent(String.self, forKey: .base)
            pages = try? container.decodeIfPresent([String: String].self, forKey: .pages)
            template = try? container.decodeIfPresent(String.self, forKey: .template)
            airac = try? container.decodeIfPresent(String.self, forKey: .airac)
            url = try? container.decodeIfPresent(String.self, forKey: .url)
            login = try? container.decodeIfPresent(Bool.self, forKey: .login)
        }
    }

    enum Kind {
        static let dfsBasicVFR = "dfs-basicvfr"
        static let siaVAC = "sia-vac"
        static let skyBriefingVFRManual = "skybriefing-vfr-manual"
        static let eAIP = "eaip"
    }

    /// The ICAO nationality letters of each country's AIP. DE needs none (its page table names every
    /// aerodrome); a country the registry adds later needs an app release, which is also when its
    /// publisher gets a host below.
    static let icaoPrefixes: [String: [String]] = ["AT": ["LO"], "CH": ["LS"], "DE": ["ED", "ET"], "FR": ["LF"]]

    /// The publisher's domain per country: a link anywhere else is not opened. The registry is ours,
    /// but a link that asks for a SkyBriefing login is exactly what a tampered file would forge.
    static let publisherDomains: [String: [String]] = [
        "AT": ["austrocontrol.at"],
        "CH": ["skybriefing.com", "skyguide.ch"],
        "DE": ["dfs.de"],
        "FR": ["aviation-civile.gouv.fr"],
    ]

    static let publisherNames = ["AT": "Austro Control", "CH": "SkyBriefing", "DE": "DFS", "FR": "SIA"]

    init(v: Int = OfficialChartRegistry.schema, generated: String? = nil, countries: [String: Country]) {
        self.v = v
        self.generated = generated
        self.countries = countries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        generated = try? container.decodeIfPresent(String.self, forKey: .generated)
        var countries: [String: Country] = [:]
        if let entries = try? container.nestedContainer(keyedBy: AnyKey.self, forKey: .countries) {
            for key in entries.allKeys {
                if let country = try? entries.decode(Country.self, forKey: key) {
                    countries[key.stringValue.uppercased()] = country
                }
            }
        }
        self.countries = countries
    }

    private enum CodingKeys: String, CodingKey { case v, generated, countries }

    private struct AnyKey: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    // MARK: Links

    /// The official chart of `icao`, or nil: an unknown country (IT's terms forbid deep links, so it
    /// is never in the file), a code that isn't four letters, a closed field, a link off its
    /// publisher's site, or a French one that can't be trusted to exist.
    ///
    /// - Parameter type: the field's type, when known. France needs it: the SIA atlas has a VAC for
    ///   aerodromes, not for heliports or seaplane bases, and a code without one answers 404. The
    ///   registry doesn't list the atlas's codes, so a French link needs an aerodrome type.
    func link(for icao: String, type: AirportType?, now: Date) -> OfficialChartLink? {
        let code = icao.trimmingCharacters(in: .whitespaces).uppercased()
        guard Self.isICAOCode(code), type != .closed else { return nil }
        for (country, entry) in countries.sorted(by: { $0.key < $1.key }) {
            guard let url = url(of: entry, country: country, code: code, type: type, now: now) else { continue }
            return OfficialChartLink(icao: code, country: country, url: url,
                                     publisher: Self.publisherNames[country] ?? url.host ?? country,
                                     requiresLogin: entry.login ?? (entry.kind == Kind.skyBriefingVFRManual))
        }
        return nil
    }

    private func url(of entry: Country, country: String, code: String, type: AirportType?, now: Date) -> URL? {
        let prefixes = Self.icaoPrefixes[country] ?? []
        switch entry.kind {
        case Kind.dfsBasicVFR:
            guard let base = entry.base, let page = entry.pages?[code], Self.isPageId(page) else { return nil }
            return Self.publisherURL(base + page + ".html", country: country)
        case Kind.siaVAC:
            guard prefixes.contains(where: code.hasPrefix), let type, AirportType.fixedWing.contains(type),
                  let template = entry.template, template.contains("{icao}"),
                  Self.folderIsCurrent(airac: entry.airac, generated: generated, now: now) else { return nil }
            return Self.publisherURL(template.replacingOccurrences(of: "{icao}", with: code), country: country)
        case Kind.skyBriefingVFRManual, Kind.eAIP:
            guard prefixes.contains(where: code.hasPrefix), let link = entry.url else { return nil }
            return Self.publisherURL(link, country: country)
        default:
            return nil
        }
    }

    /// Whether a link that names an AIRAC folder still exists. SIA takes a cycle's folder down when
    /// the next one starts (2609's answered 404 the day after 2610 began), so a template of an older
    /// cycle is only trusted when the job checked it during the cycle in force (it falls back to the
    /// previous folder while SIA hasn't put the new one online).
    static func folderIsCurrent(airac: String?, generated: String?, now: Date) -> Bool {
        guard let airac, let number = Int(airac) else { return true }
        let cycle = AIRACCycle.inForce(on: now)
        if number >= Int(cycle.ident) ?? 0 { return true }
        guard let generated, let checked = parseDate(generated) else { return false }
        return checked >= cycle.validFrom
    }

    static func isICAOCode(_ code: String) -> Bool {
        code.count == 4 && code.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) }
    }

    /// A DFS page id is six hex digits; anything else could walk out of `base`.
    static func isPageId(_ page: String) -> Bool {
        (1...32).contains(page.count) && page.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
    }

    /// `text` as a URL, when it is HTTPS on the country's publisher's domain (or a subdomain of it).
    static func publisherURL(_ text: String, country: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), let domains = publisherDomains[country],
              domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return url
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

// MARK: - AIRAC

/// The AIRAC cycle in force on a date: AIRAC 2001 took effect on 2 January 2020, and every cycle since
/// is exactly 28 days after the previous one (the same sum as `vfrcommon.airac_for` in the data job).
enum AIRACCycle {
    static let length: TimeInterval = 28 * 24 * 60 * 60
    static let anchor: Date = {
        var components = DateComponents()
        components.year = 2020
        components.month = 1
        components.day = 2
        return OFMSchema.utcCalendar.date(from: components)!
    }()

    /// "2610", effective from its first Thursday at 00:00 UTC.
    static func inForce(on date: Date) -> (ident: String, validFrom: Date) {
        let steps = (date.timeIntervalSince(anchor) / length).rounded(.down)
        let start = anchor.addingTimeInterval(steps * length)
        let calendar = OFMSchema.utcCalendar
        let year = calendar.component(.year, from: start)
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: start) ?? 1
        let number = (dayOfYear - 1) / 28 + 1
        return (String(format: "%02d%02d", year % 100, number), start)
    }
}

// MARK: - The service

/// Fetches and caches the chart registry, the way `AirfieldTariffService` does the tariffs: on disk,
/// refreshed when a week old, silent on failure. A pilot planning offline, or in flight, gets the link
/// they had last time; a missing link is a missing convenience, never an error. (6.2.0)
@MainActor
final class OfficialChartService: ObservableObject {
    static let shared = OfficialChartService()

    static let registryURL = URL(string: "https://aerocheck.app/data/charts/v1/charts.json")!
    static let allowedHosts: Set<String> = ["aerocheck.app"]
    /// 12 KB in 2610, nearly all of it DFS's page table.
    static let maxBytes = 1024 * 1024
    /// A week, the job's own rhythm.
    nonisolated static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// After a new cycle starts, how often to look for the file with the new French folder.
    nonisolated static let cycleRetry: TimeInterval = 60 * 60

    @Published private(set) var registry: OfficialChartRegistry?
    @Published private(set) var isLoading = false
    private(set) var lastFetch: Date?
    /// Bumped by a seed: a fetch that started before it doesn't land after it.
    private var generation = 0

    private let cacheURL: URL
    private let fetchOverride: ((URL) async throws -> Data)?
    private let now: () -> Date

    /// - Parameters:
    ///   - cacheURL: tests only; where the cache lives instead of the app's directory.
    ///   - fetch: tests only; replaces the network (URL in, body out).
    ///   - now: the clock, for the cache's age and the French cycle.
    init(cacheURL: URL? = nil, fetch: ((URL) async throws -> Data)? = nil, now: @escaping () -> Date = Date.init) {
        self.cacheURL = cacheURL
            ?? DataPersistenceManager.shared.localAppDirectory.appendingPathComponent("official-charts.json")
        self.fetchOverride = fetch
        self.now = now
        loadCache()
    }

    func link(for icao: String, type: AirportType?) -> OfficialChartLink? {
        registry?.link(for: icao, type: type, now: now())
    }

    func link(for airport: Airport) -> OfficialChartLink? {
        link(for: airport.ident, type: airport.type)
    }

    var isStale: Bool { Self.isStale(registry: registry, fetchedAt: lastFetch, now: now()) }

    /// A week old, from a clock that has gone back, or from before the AIRAC cycle in force while it
    /// names an older French folder (then at most once an hour, until the job publishes the new one).
    nonisolated static func isStale(registry: OfficialChartRegistry?, fetchedAt: Date?, now: Date) -> Bool {
        guard let registry, let fetchedAt else { return true }
        let age = now.timeIntervalSince(fetchedAt)
        if age < 0 || age >= maxAge { return true }
        let french = registry.countries.values.first { $0.kind == OfficialChartRegistry.Kind.siaVAC }
        if let french, !OfficialChartRegistry.folderIsCurrent(airac: french.airac, generated: registry.generated, now: now) {
            return age >= cycleRetry
        }
        return false
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
            let decoded = try JSONDecoder().decode(OfficialChartRegistry.self, from: data)
            guard started == generation else { return }
            guard decoded.v == OfficialChartRegistry.schema else {
                AppLog.general.publicLine("Chart registry: schema \(decoded.v) not read")
                return
            }
            registry = decoded
            lastFetch = now()
            saveCache(decoded)
        } catch {
            AppLog.general.debugLine("Chart registry fetch failed: \(error.localizedDescription)")
        }
    }

    private enum FetchError: Error { case http(Int), tooLarge }

    /// GET the registry: on the allow-list, under the size cap, a 200.
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
            let (body, response) = try await ExternalRequest.data(
                for: request, maxResponseBytes: Self.maxBytes, allowedHosts: Self.allowedHosts)
            guard response.statusCode == 200 else { throw FetchError.http(response.statusCode) }
            data = body
        }
        guard data.count <= Self.maxBytes else { throw FetchError.tooLarge }
        return data
    }

    // MARK: Cache

    private struct CachedRegistry: Codable {
        let fetchedAt: Date
        let registry: OfficialChartRegistry
    }

    private func loadCache() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? decoder.decode(CachedRegistry.self, from: data),
              cached.registry.v == OfficialChartRegistry.schema else { return }
        registry = cached.registry
        lastFetch = cached.fetchedAt
    }

    private func saveCache(_ registry: OfficialChartRegistry) {
        guard let fetchedAt = lastFetch else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(CachedRegistry(fetchedAt: fetchedAt, registry: registry))
                .write(to: cacheURL, options: DataPersistenceManager.protectedWriteOptions)
        } catch {
            AppLog.general.debugLine("Failed to cache the chart registry: \(error.localizedDescription)")
        }
    }

    /// Seeded directly in tests, so no test has to reach the network (nil empties it).
    func seedForTesting(_ seeded: OfficialChartRegistry?, fetchedAt: Date? = nil) {
        generation += 1
        registry = seeded
        lastFetch = seeded == nil ? nil : (fetchedAt ?? now())
    }
}
