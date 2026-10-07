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
    /// Whether that login is a subscription (SkyBriefing, Croatia Control) rather than a free sign-in
    /// (BULATSA's B-FLIP): the button says which.
    var isSubscription = true

    /// "Official chart", or "Official chart · SkyBriefing (subscription)".
    var title: String {
        guard let note else { return L10n.OfficialChart.title }
        return "\(L10n.OfficialChart.title) · \(note)"
    }

    /// The login note alone, for a button that has room for a second line.
    var note: String? {
        guard requiresLogin else { return nil }
        return isSubscription ? L10n.OfficialChart.subscription(publisher) : L10n.OfficialChart.signIn(publisher)
    }

    /// The login note in one word, where the publisher's name doesn't fit.
    var shortNote: String? {
        guard requiresLogin else { return nil }
        return isSubscription ? L10n.OfficialChart.subscriptionShort : L10n.OfficialChart.signInShort
    }

    /// What VoiceOver adds: "Opens SkyBriefing in the browser".
    var accessibilityHint: String { L10n.OfficialChart.opens(publisher) }

    /// A document, locked when it needs a login.
    var symbolName: String { requiresLogin ? "lock.doc" : "doc.richtext" }
}

// MARK: - The registry (charts.json, schema v1)

/// `/data/charts/v1/charts.json` on the API host: how each country turns an ICAO code into its
/// official chart. Built weekly by the AeroCheck server, which HEAD-checks a sample of every country
/// and leaves out the ones that fail, so the app never has to judge a link itself. Decoded leniently:
/// a country the app can't read is skipped, never the file.
struct OfficialChartRegistry: Codable, Equatable, Sendable {
    static let schema = 1

    let v: Int
    /// When the job last changed the file (it only moves when the content does).
    let generated: String?
    let countries: [String: Country]

    /// One country's entry. `kind` says which fields it uses:
    /// - `dfs-basicvfr`: `base` + `pages[ICAO]` + `.html` (DE);
    /// - `sia-vac`: `template` with `{icao}`, in the folder of AIRAC `airac`, and `codes`, the aerodromes
    ///   that have a VAC there (FR; `codes` since the registry of 2 October 2026, optional);
    /// - `skybriefing-vfr-manual`: one `url` for every aerodrome, `login` (CH);
    /// - `eaip`: one `url`, the eAIP's start page (AT).
    /// The generic kinds, for every country added since (6 October 2026), so the next one needs no new
    /// code, only its publisher's domain below:
    /// - `pages`: `pages[ICAO]`, the job's link from the publisher's own index: a path under `base`, or a
    ///   whole https URL when a country's charts live on two hosts (a VFR manual and the AIP);
    /// - `template`: `template` with `{icao}`, for the `codes` listed (else the aerodrome types that have
    ///   one), optionally in the folder of AIRAC `airac`;
    /// - `url`: one `url` for every aerodrome of the country (a start page).
    /// Any kind can carry `until`: when its links stop working (the publisher's next amendment takes the
    /// folder down), after which they are not offered and the registry is fetched again.
    struct Country: Codable, Equatable, Sendable {
        let kind: String
        var base: String?
        var pages: [String: String]?
        var template: String?
        var airac: String?
        var url: String?
        var login: Bool?
        /// The codes that have a chart behind the template (FR: SIA's own list of the atlas).
        var codes: [String]?
        /// With `login`: "sign-in" for a free one; anything else, or nothing, is a subscription.
        var access: String?
        /// ISO 8601: the links stop working then (the next amendment's date, when the job knows it).
        var until: String?

        init(kind: String, base: String? = nil, pages: [String: String]? = nil, template: String? = nil,
             airac: String? = nil, url: String? = nil, login: Bool? = nil, codes: [String]? = nil,
             until: String? = nil, access: String? = nil) {
            self.kind = kind
            self.base = base
            self.pages = pages
            self.template = template
            self.airac = airac
            self.url = url
            self.login = login
            self.codes = codes
            self.until = until
            self.access = access
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
            codes = try? container.decodeIfPresent([String].self, forKey: .codes)
            until = try? container.decodeIfPresent(String.self, forKey: .until)
            access = try? container.decodeIfPresent(String.self, forKey: .access)
        }

        /// Whether the links are past their `until` (an unreadable one counts as no limit).
        func hasExpired(now: Date) -> Bool {
            guard let until, let date = OfficialChartRegistry.parseDate(until) else { return false }
            return now >= date
        }
    }

    enum Kind {
        static let dfsBasicVFR = "dfs-basicvfr"
        static let siaVAC = "sia-vac"
        static let skyBriefingVFRManual = "skybriefing-vfr-manual"
        static let eAIP = "eaip"
        static let pages = "pages"
        static let template = "template"
        static let url = "url"
    }

    /// The ICAO nationality letters of each country's AIP, for the kinds that serve a whole country
    /// (`template`, `url`); a `pages` table names its aerodromes. A country the registry adds later
    /// needs an app release, which is also when its publisher gets a host below.
    static let icaoPrefixes: [String: [String]] = [
        "AT": ["LO"], "BG": ["LB"], "CH": ["LS"], "CZ": ["LK"], "DE": ["ED", "ET"], "DK": ["EK"], "FI": ["EF"],
        "FR": ["LF"], "GR": ["LG"], "HR": ["LD"], "HU": ["LH"], "NL": ["EH"], "PL": ["EP"], "RO": ["LR"],
        "SE": ["ES"], "SI": ["LJ"], "SK": ["LZ"], "ZA": ["FA"],
    ]

    /// The publisher's domain per country: a link anywhere else is not opened. The registry is ours,
    /// but a link that asks for a SkyBriefing login is exactly what a tampered file would forge. South
    /// Africa's charts are on a storage host of a shared cloud domain: that one host, never the domain.
    static let publisherDomains: [String: [String]] = [
        "AT": ["austrocontrol.at"],
        "BG": ["bulatsa.com"],
        "CH": ["skybriefing.com", "skyguide.ch"],
        "CZ": ["aim.rlp.cz"],
        "DE": ["dfs.de"],
        "DK": ["naviair.dk"],
        "FI": ["ais.fi"],
        "FR": ["aviation-civile.gouv.fr"],
        "GR": ["hasp.gov.gr"],
        "HR": ["crocontrol.hr"],
        "HU": ["hungarocontrol.hu"],
        "NL": ["lvnl.nl"],
        "PL": ["pansa.pl"],
        "RO": ["aisro.ro"],
        "SE": ["lfv.se"],
        "SI": ["sloveniacontrol.si"],
        "SK": ["lps.sk"],
        "ZA": ["caasanwebsitestorage.blob.core.windows.net"],
    ]

    static let publisherNames = [
        "AT": "Austro Control", "BG": "BULATSA", "CH": "SkyBriefing", "CZ": "ANS CR", "DE": "DFS", "DK": "Naviair",
        "FI": "Fintraffic", "FR": "SIA", "GR": "HASP", "HR": "Croatia Control", "HU": "HungaroControl",
        "NL": "LVNL", "PL": "PANSA", "RO": "ROMATSA", "SE": "LFV", "SI": "Slovenia Control", "SK": "LPS SR",
        "ZA": "SACAA",
    ]

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
    /// - Parameter type: the field's type, when known. France needs it when the registry has no list of
    ///   the atlas's codes (`codes`): the atlas has a VAC for aerodromes, not for heliports or seaplane
    ///   bases, and a code without one answers 404. With the list, the list decides.
    func link(for icao: String, type: AirportType?, now: Date) -> OfficialChartLink? {
        let code = icao.trimmingCharacters(in: .whitespaces).uppercased()
        guard Self.isICAOCode(code), type != .closed else { return nil }
        for (country, entry) in countries.sorted(by: { $0.key < $1.key }) {
            guard let url = url(of: entry, country: country, code: code, type: type, now: now) else { continue }
            return OfficialChartLink(icao: code, country: country, url: url,
                                     publisher: Self.publisherNames[country] ?? url.host ?? country,
                                     requiresLogin: entry.login ?? (entry.kind == Kind.skyBriefingVFRManual),
                                     isSubscription: entry.access != "sign-in")
        }
        return nil
    }

    private func url(of entry: Country, country: String, code: String, type: AirportType?, now: Date) -> URL? {
        let prefixes = Self.icaoPrefixes[country] ?? []
        guard !entry.hasExpired(now: now) else { return nil }
        switch entry.kind {
        case Kind.dfsBasicVFR:
            guard let base = entry.base, let page = entry.pages?[code], Self.isPageId(page) else { return nil }
            return Self.publisherURL(base + page + ".html", country: country)
        case Kind.siaVAC:
            guard prefixes.contains(where: code.hasPrefix), Self.hasVAC(code, codes: entry.codes, type: type),
                  let template = entry.template, template.contains("{icao}"),
                  Self.folderIsCurrent(airac: entry.airac, generated: generated, now: now) else { return nil }
            return Self.publisherURL(template.replacingOccurrences(of: "{icao}", with: code), country: country)
        case Kind.skyBriefingVFRManual, Kind.eAIP, Kind.url:
            guard prefixes.contains(where: code.hasPrefix), let link = entry.url else { return nil }
            return Self.publisherURL(link, country: country)
        case Kind.pages:
            guard let page = entry.pages?[code] else { return nil }
            if page.hasPrefix("https://") {
                guard Self.isRelativePath(String(page.dropFirst("https://".count))) else { return nil }
                return Self.publisherURL(page, country: country)
            }
            guard let base = entry.base, Self.isRelativePath(page) else { return nil }
            return Self.publisherURL(base + page, country: country)
        case Kind.template:
            guard prefixes.contains(where: code.hasPrefix), Self.hasVAC(code, codes: entry.codes, type: type),
                  let template = entry.template, template.contains("{icao}"),
                  Self.folderIsCurrent(airac: entry.airac, generated: generated, now: now) else { return nil }
            return Self.publisherURL(template.replacingOccurrences(of: "{icao}", with: code), country: country)
        default:
            return nil
        }
    }

    /// Whether the SIA atlas has a VAC for `code`: in its list when the registry has one (419 codes in
    /// 2610, most air bases not among them), else an aerodrome of a type the atlas covers.
    static func hasVAC(_ code: String, codes: [String]?, type: AirportType?) -> Bool {
        if let codes, !codes.isEmpty { return codes.contains(code) }
        guard let type else { return false }
        return AirportType.fixedWing.contains(type)
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

    /// A `pages` path the job read from a publisher's index: relative, without `..`, a scheme or a
    /// query, in URL characters (spaces arrive encoded). It is only ever appended to its own `base`.
    static func isRelativePath(_ path: String) -> Bool {
        guard (1...512).contains(path.count), !path.hasPrefix("/"), !path.contains(".."), !path.contains("//"),
              !path.contains("?"), !path.contains("#") else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~%/()")
        return path.unicodeScalars.allSatisfy(allowed.contains)
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

    static let registryURL = APIConfig.dataURL("charts/v1/charts.json")
    static let allowedHosts = Set([registryURL.host?.lowercased()].compactMap { $0 })
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

    /// A week old, from a clock that has gone back, or, at most once an hour until the job publishes the
    /// new one, when a country's links have expired: a folder of an AIRAC cycle older than the one in
    /// force (France, and any template that names its cycle), or a country past its `until`.
    nonisolated static func isStale(registry: OfficialChartRegistry?, fetchedAt: Date?, now: Date) -> Bool {
        guard let registry, let fetchedAt else { return true }
        let age = now.timeIntervalSince(fetchedAt)
        if age < 0 || age >= maxAge { return true }
        let cycleKinds = [OfficialChartRegistry.Kind.siaVAC, OfficialChartRegistry.Kind.template]
        let expired = registry.countries.values.contains { entry in
            entry.hasExpired(now: now)
                || (cycleKinds.contains(entry.kind)
                    && !OfficialChartRegistry.folderIsCurrent(airac: entry.airac, generated: registry.generated, now: now))
        }
        return expired && age >= cycleRetry
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
            // The API's app-client hurdle, as for `/airfields`: absent in a build without Secrets.xcconfig.
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

    // MARK: Cache

    private struct CachedRegistry: Codable {
        let fetchedAt: Date
        let registry: OfficialChartRegistry
        /// The address it was read from; nil in a cache written before 6.2.0 kept it.
        var source: String?
    }

    /// The cache, and its age when it came from today's address. One from another address (aerocheck.app
    /// until the registry moved to the API, or the other server's after a switch between TestFlight and
    /// the App Store) keeps its links for offline use but counts as stale, so the first refresh replaces
    /// it: kept a week, the old file hid the countries added since. (6.2.0, device check 7 Oct)
    private func loadCache() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? decoder.decode(CachedRegistry.self, from: data),
              cached.registry.v == OfficialChartRegistry.schema else { return }
        registry = cached.registry
        lastFetch = cached.source == Self.registryURL.absoluteString ? cached.fetchedAt : nil
    }

    private func saveCache(_ registry: OfficialChartRegistry) {
        guard let fetchedAt = lastFetch else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(CachedRegistry(fetchedAt: fetchedAt, registry: registry,
                                              source: Self.registryURL.absoluteString))
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
