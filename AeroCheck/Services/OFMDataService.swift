import Foundation
import CryptoKit
import MapKit

// MARK: - Configuration

/// Where the app reads open flightmaps data: small files the AeroCheck server builds from OFM every
/// week and serves at `/data/ofm/v1/` on this build's API host (`APIConfig.dataURL`: the sandbox worker
/// for Debug and TestFlight builds). The app never talks to OFM itself. (6.2.0)
enum OFMConfig {
    static let defaultBaseURL = APIConfig.dataURL("ofm/v1/")

    /// Ceiling per file. The largest (DE) is 650 KB in 2610; the job refuses to publish over 2 MB.
    static let maxFileBytes = 4 * 1024 * 1024

    /// The countries the job publishes, until the first `index.json` says otherwise: every region open
    /// flightmaps publishes (22 countries from 21 regions in 2610, Belgium's split into BE and LU). Some
    /// have few procedures or none yet, and bring their reporting points and runways meanwhile.
    static let knownCountries = ["AT", "BE", "BG", "CH", "CZ", "DE", "DK", "FI", "FR", "GR", "HR", "HU",
                                 "IT", "LU", "MT", "NL", "PL", "RO", "SE", "SI", "SK", "ZA"]

    /// OFM's region per country (its FIR package). The country files carry theirs (`region`), which
    /// wins; this is for a country not downloaded yet. A region can serve two countries (EBBU).
    static let regionByCountry = [
        "AT": "LOVV", "BE": "EBBU", "BG": "LBSR", "CH": "LSAS", "CZ": "LKAA", "DE": "ED", "DK": "EKDK",
        "FI": "EFIN", "FR": "LF", "GR": "LGGG", "HR": "LDZO", "HU": "LHCC", "IT": "LI", "LU": "EBBU",
        "MT": "LMMM", "NL": "EHAA", "PL": "EPWW", "RO": "LRBB", "SE": "ESAA", "SI": "LJLA", "SK": "LZBB",
        "ZA": "FA",
    ]

    static func region(forCountry country: String) -> String? { regionByCountry[country.uppercased()] }

    /// The published files, or in a DEBUG build the override's.
    static var baseURL: URL { debugBaseURL ?? defaultBaseURL }

    /// The hosts a download may reach: the API's, plus a DEBUG override's.
    static var allowedHosts: Set<String> { allowedHosts(override: debugBaseURL) }

    static func allowedHosts(override: URL?) -> Set<String> {
        Set([defaultBaseURL, override].compactMap { $0?.host?.lowercased() })
    }

    static func indexURL(base: URL) -> URL { base.appendingPathComponent("index.json") }

    /// A country file's URL from its index entry: relative to the index (`ch.json`, as the server
    /// writes it, so the sandbox and production hosts serve the same index), or absolute. An absolute
    /// one off the allow-list is refused before it is asked.
    static func fileURL(published: String, base: URL) -> URL? {
        URL(string: published, relativeTo: indexURL(base: base))?.absoluteURL
    }

    #if DEBUG
    /// DEBUG builds only: read the files from another HTTPS base, e.g. a copy of a channel served
    /// somewhere else before it is published. Environment `AEROCHECK_VFR_DATA_BASE` (simctl:
    /// `SIMCTL_CHILD_AEROCHECK_VFR_DATA_BASE=…`) or launch argument `-AEROCHECK_VFR_DATA_BASE …`. Its
    /// host joins the allow-list. Release builds don't contain this.
    static let debugBaseURL: URL? = {
        let raw = ProcessInfo.processInfo.environment["AEROCHECK_VFR_DATA_BASE"]
            ?? UserDefaults.standard.string(forKey: "AEROCHECK_VFR_DATA_BASE")
        return raw.flatMap(debugBaseURL(from:))
    }()

    /// An HTTPS URL with a host, ending in `/` so file names resolve under it.
    static func debugBaseURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed.hasSuffix("/") ? trimmed : trimmed + "/"),
              url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }
    #else
    static let debugBaseURL: URL? = nil
    #endif
}

enum OFMDataError: LocalizedError, Equatable {
    case http(Int)
    case hostNotAllowed
    case tooLarge(Int)
    case checksumMismatch
    case wrongCountry(String)

    var errorDescription: String? {
        switch self {
        case .http(let status): return "HTTP \(status)"
        case .hostNotAllowed: return "Host outside the allow-list"
        case .tooLarge(let bytes): return "File too large (\(bytes) bytes)"
        case .checksumMismatch: return "SHA-256 differs from the index"
        case .wrongCountry(let country): return "File is for \(country)"
        }
    }
}

// MARK: - Freshness by cycle

/// The one dataset whose AIRAC cycle means something: OFM publishes per cycle, and a circuit or a
/// route can change on a cycle date. Fresh until the next cycle is effective (`validTo`, a Thursday at
/// 00:00 UTC), aging from then on whether or not the new cycle is published yet, stale four weeks
/// later. (6.2.0)
enum OFMCycleFreshness {
    static let staleAfter: TimeInterval = 28 * 24 * 60 * 60

    static func freshness(validTo: Date?, now: Date) -> DataFreshness {
        guard let validTo else { return .missing }
        if now < validTo { return .fresh }
        if now < validTo.addingTimeInterval(staleAfter) { return .aging }
        return .stale
    }
}

// MARK: - Cache metadata

/// `OFMData/metadata.json`: what is on disk, per country. New fields must be optional (older files
/// decode with them absent).
struct OFMCacheMetadata: Codable, Equatable {
    struct Country: Codable, Equatable {
        /// SHA-256 of the file on disk, as the index published it.
        var sha256: String
        var airac: String
        var validFrom: Date
        var validTo: Date
        var region: String?
        var bytes: Int?
        /// The last time the index confirmed or replaced this file.
        var checked: Date?
    }

    var countries: [String: Country] = [:]
    /// The last index read that succeeded.
    var lastIndexCheck: Date?
}

// MARK: - Service

/// Traffic circuits, VFR arrival and departure routes with their sectors, reporting points and runway
/// designators from open flightmaps, for the countries the pilot keeps offline that OFM covers (CH, AT,
/// DE, CZ in 2610). Downloaded with the other aeronautical data, kept per country, current for one
/// AIRAC cycle. The maps draw it through `VFRMapLayer`, and `ReportingPointCatalog` merges its points.
///
/// A download reads `index.json`, then fetches only the countries whose SHA-256 changed and checks the
/// SHA-256 of what arrived. Files are stored byte for byte as published, in
/// `Application Support/OFMData` (excluded from backup), and decoded off the main actor on demand
/// (`ensureLoaded`). (6.2.0)
@MainActor
final class OFMDataService: ObservableObject {
    static let shared = OFMDataService()

    nonisolated static let directoryName = "OFMData"
    /// The foreground refresh of aging data re-reads the index at most this often: until OFM publishes
    /// the new cycle, every return to the app would ask again.
    nonisolated static let agingRecheckInterval: TimeInterval = 60 * 60

    struct Cycle: Equatable, Sendable {
        let airac: String
        let validFrom: Date
        let validTo: Date
    }

    /// One loaded country file's reporting points, with its cycle: what `ReportingPointCatalog` merges
    /// into OpenAIP's. (6.2.0)
    struct PointSet: Sendable {
        let country: String
        let airac: String
        let points: [VFRPoint]
    }

    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress: Double = 0
    /// Countries the last download could not update (their old file, if any, is kept): the row's error
    /// line and Navigation & Maps'. Empty after a download that served every country.
    @Published var failedCountries: [String] = []
    @Published private(set) var downloadedCountries: [String] = []
    @Published private(set) var lastUpdated: Date?
    /// The cycle on disk, per country.
    @Published private(set) var cycles: [String: Cycle] = [:]
    /// The last index read, kept on disk: the countries OFM covers, newer cycles, the report form.
    @Published private(set) var index: OFMIndex?
    @Published private(set) var isLoaded = false
    /// Bumped whenever the loaded procedures change, for the maps to redraw.
    @Published private(set) var revision = 0

    var isDataAvailable: Bool { !downloadedCountries.isEmpty }

    /// The countries OFM data is published for: the last index's, or `OFMConfig.knownCountries` before one.
    var supportedCountries: [String] { index?.countries ?? OFMConfig.knownCountries }

    /// The last index read attempted, successful or not (in memory: a relaunch may try again).
    private(set) var lastIndexAttempt: Date?

    private let fileManager = FileManager.default
    private let rootDirectory: URL?
    private let baseURL: URL
    private let allowedHosts: Set<String>
    private let fetchOverride: ((URL) async throws -> Data)?
    private let now: () -> Date

    private var procedures: [VFRProcedure] = []
    private var points: [VFRPoint] = []
    /// The loaded reporting points, per country file, in country order. Empty until `ensureLoaded()`.
    private(set) var pointSets: [PointSet] = []
    private var runways: [String: [String]] = [:]
    private var thresholds: [String: [VFRThreshold]] = [:]
    private var procedureGrid: [GridKey: [Int]] = [:]
    private var pointGrid: [GridKey: [Int]] = [:]
    private var proceduresByAerodrome: [String: [Int]] = [:]
    private var regionByCountry: [String: String] = [:]
    /// Bumped by every download and delete, so a load that read the disk before one doesn't land after it.
    private var generation = 0
    /// Someone asked for the procedures: a download reloads them.
    private var wantsLoaded = false

    /// - Parameters:
    ///   - rootDirectory: tests only; holds `OFMData` instead of Application Support.
    ///   - baseURL: where `index.json` is.
    ///   - allowedHosts: the hosts a download may reach (`OFMConfig.allowedHosts`).
    ///   - fetch: tests only; replaces the network (URL in, body out).
    ///   - now: the clock, for the cycle checks.
    init(rootDirectory: URL? = nil,
         baseURL: URL = OFMConfig.baseURL,
         allowedHosts: Set<String> = OFMConfig.allowedHosts,
         fetch: ((URL) async throws -> Data)? = nil,
         now: @escaping () -> Date = Date.init) {
        self.rootDirectory = rootDirectory
        self.baseURL = baseURL
        self.allowedHosts = allowedHosts
        self.fetchOverride = fetch
        self.now = now
        publish(readMetadata())
        if let data = try? Data(contentsOf: indexFileURL) {
            index = try? JSONDecoder().decode(OFMIndex.self, from: data)
        }
    }

    // MARK: Storage

    private var dataDirectory: URL {
        let base = rootDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(Self.directoryName, isDirectory: true)
    }
    private var metadataFileURL: URL { dataDirectory.appendingPathComponent("metadata.json") }
    private var indexFileURL: URL { dataDirectory.appendingPathComponent("index.json") }
    private func countryFileURL(_ country: String) -> URL {
        dataDirectory.appendingPathComponent("ofm_\(country).json")
    }

    private func readMetadata() -> OFMCacheMetadata {
        guard let data = try? Data(contentsOf: metadataFileURL),
              let metadata = try? JSONDecoder().decode(OFMCacheMetadata.self, from: data) else { return OFMCacheMetadata() }
        return metadata
    }

    private func write(_ metadata: OFMCacheMetadata) {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: metadataFileURL, options: .atomic)
    }

    private func publish(_ metadata: OFMCacheMetadata) {
        downloadedCountries = metadata.countries.keys.sorted()
        cycles = metadata.countries.mapValues { Cycle(airac: $0.airac, validFrom: $0.validFrom, validTo: $0.validTo) }
        lastUpdated = metadata.countries.values.compactMap(\.checked).max()
        regionByCountry = metadata.countries.compactMapValues(\.region)
    }

    // MARK: Download

    /// Bring the cached countries up to date with the published ones, for `countries` (ISO-2), and drop
    /// every cached country not in `countries`. Callers pass the UNION of what they want and what is
    /// cached (the offline-country selection, or a trip's countries added to it), as for the OpenAIP
    /// layers. Countries OFM doesn't cover are ignored. An empty list does nothing (not "remove all").
    ///
    /// One request for `index.json`, then one per country whose SHA-256 changed; a file whose SHA-256
    /// differs from the index's, that is too large, or that doesn't decode is refused, and that country
    /// keeps its old file.
    func downloadData(for countries: [String]) async {
        let requested = Set(countries.map { $0.uppercased() })
        guard !isDownloading, !requested.isEmpty else { return }
        isDownloading = true
        downloadProgress = 0
        failedCountries = []
        defer { isDownloading = false }
        let startGeneration = generation

        guard let index = await fetchIndex() else {
            // Nothing could be checked: every requested country OFM covers failed.
            failedCountries = requested.intersection(supportedCountries).sorted()
            return
        }

        try? fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        DataPersistenceManager.excludeFromBackup(dataDirectory)
        var metadata = readMetadata()
        metadata.lastIndexCheck = now()
        let wanted = requested.filter { index.regions[$0] != nil }.sorted()
        var failed: [String] = []
        for (position, country) in wanted.enumerated() {
            defer { downloadProgress = Double(position + 2) / Double(wanted.count + 1) }
            guard let entry = index.regions[country] else { continue }
            if let cached = metadata.countries[country], cached.sha256 == entry.sha256,
               await Self.sha256(ofFileAt: countryFileURL(country)) == entry.sha256 {
                metadata.countries[country]?.checked = now()
                continue
            }
            do {
                let file = try await downloadCountry(country, entry: entry)
                metadata.countries[country] = OFMCacheMetadata.Country(
                    sha256: entry.sha256, airac: file.airac, validFrom: file.validFrom, validTo: file.validTo,
                    region: file.region, bytes: file.bytes, checked: now())
            } catch {
                AppLog.openAIP.debugLine("open flightmaps download failed for \(country): \(error)")
                failed.append(country)
            }
        }

        // Deleted meanwhile ("Remove all downloads"): what this download fetched is not brought back.
        guard generation == startGeneration else { return }
        generation &+= 1   // a load that read the disk before this point doesn't land after it

        // Only what the caller left out of its union goes: a country OFM stopped listing, or that failed,
        // keeps its file and ages by its cycle.
        for country in Set(metadata.countries.keys).subtracting(requested) {
            metadata.countries.removeValue(forKey: country)
            try? fileManager.removeItem(at: countryFileURL(country))
        }
        write(metadata)
        publish(metadata)
        failedCountries = failed
        downloadProgress = 1
        if wantsLoaded { await reload() }
    }

    /// Read `index.json` and keep it on disk; nil when it can't be read (the old one stays).
    private func fetchIndex() async -> OFMIndex? {
        lastIndexAttempt = now()
        do {
            let data = try await fetch(OFMConfig.indexURL(base: baseURL))
            let index = try JSONDecoder().decode(OFMIndex.self, from: data)
            try? fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            DataPersistenceManager.excludeFromBackup(dataDirectory)
            try? data.write(to: indexFileURL, options: .atomic)
            self.index = index
            return index
        } catch {
            AppLog.openAIP.debugLine("open flightmaps index unavailable: \(error)")
            return nil
        }
    }

    private struct DownloadedFile {
        let airac: String
        let validFrom: Date
        let validTo: Date
        let region: String?
        let bytes: Int
    }

    private func downloadCountry(_ country: String, entry: OFMIndex.Region) async throws -> DownloadedFile {
        guard let url = OFMConfig.fileURL(published: entry.url, base: baseURL) else { throw OFMDataError.hostNotAllowed }
        let data = try await fetch(url)
        let (digest, file) = try await Task.detached(priority: .userInitiated) {
            (Self.sha256(of: data), try JSONDecoder().decode(OFMRegionFile.self, from: data))
        }.value
        guard digest == entry.sha256 else { throw OFMDataError.checksumMismatch }
        guard file.country == country else { throw OFMDataError.wrongCountry(file.country) }
        if file.droppedProcedures > 0 {
            AppLog.openAIP.publicLine("open flightmaps: dropped \(file.droppedProcedures) unreadable procedure(s)")
        }
        try data.write(to: countryFileURL(country), options: .atomic)
        return DownloadedFile(airac: file.airac, validFrom: file.validFrom, validTo: file.validTo,
                              region: file.region, bytes: data.count)
    }

    /// GET one file: on the allow-list, under the size cap, a 200, never from the local HTTP cache (the
    /// index and a country file must be the same publication for the checksum to hold).
    private func fetch(_ url: URL) async throws -> Data {
        guard ExternalRequest.isAllowed(url, hosts: allowedHosts) else { throw OFMDataError.hostNotAllowed }
        let data: Data
        if let fetchOverride {
            data = try await fetchOverride(url)
        } else {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            // The API's app-client hurdle, as for `/airfields`: absent in a build without Secrets.xcconfig.
            if let secret = APIConfig.appClientSecret {
                request.setValue(secret, forHTTPHeaderField: "X-AeroCheck-Client")
            }
            let (body, response) = try await ExternalRequest.data(
                for: request, maxResponseBytes: OFMConfig.maxFileBytes, allowedHosts: allowedHosts)
            guard response.statusCode == 200 else { throw OFMDataError.http(response.statusCode) }
            data = body
        }
        guard data.count <= OFMConfig.maxFileBytes else { throw OFMDataError.tooLarge(data.count) }
        return data
    }

    nonisolated static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func sha256(ofFileAt url: URL) async -> String? {
        await Task.detached(priority: .utility) {
            (try? Data(contentsOf: url)).map(sha256(of:))
        }.value
    }

    // MARK: Index-only reads

    /// What a country's file weighs and holds, from the index, for the trip-size estimate. Reads the
    /// index first when there is none on disk yet or it is a day old.
    func publishedSize(for country: String) async -> (bytes: Int64, procedures: Int)? {
        let dayOld = lastIndexAttempt.map { now().timeIntervalSince($0) > 24 * 60 * 60 } ?? true
        if index == nil || dayOld { _ = await fetchIndex() }
        guard let entry = index?.regions[country.uppercased()] else { return nil }
        return (entry.bytes ?? 0, entry.procedures ?? 0)
    }

    // MARK: Freshness

    /// The oldest cycle on disk decides: one country a cycle behind is data a cycle behind.
    func freshness(now: Date) -> DataFreshness {
        OFMCycleFreshness.freshness(validTo: cycles.values.map(\.validTo).min(), now: now)
    }

    /// Whether the foreground refresh should read the index again for aging data.
    func isAgingRecheckDue(now: Date) -> Bool {
        guard let lastIndexAttempt else { return true }
        return now.timeIntervalSince(lastIndexAttempt) >= Self.agingRecheckInterval
    }

    /// The cycle line under the Data & Storage row, e.g. "AIRAC 2610 · valid 1–28 Oct 2026", or one line
    /// per cycle when the countries are on different ones. Nil when nothing is downloaded.
    func cycleDetail(now: Date) -> String? {
        let published = index?.regions.mapValues(\.airac) ?? [:]
        let lines = Self.cycleLines(cycles: cycles, published: published, now: now)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    nonisolated static func cycleLines(cycles: [String: Cycle], published: [String: String], now: Date) -> [String] {
        let groups = Dictionary(grouping: cycles, by: { $0.value.airac })
        return groups.keys.sorted(by: >).compactMap { airac -> String? in
            guard let members = groups[airac], let cycle = members.first?.value else { return nil }
            let countries = members.map(\.key).sorted()
            let newer = countries.compactMap { published[$0] }
                .filter { OFMSchema.isCycle($0, newerThan: airac) }.max()
            let text: String
            if now < cycle.validTo {
                text = L10n.DataStorage.vfrCycleValid(airac, validityRange(cycle))
            } else if let newer {
                text = L10n.DataStorage.vfrCycleAvailable(airac, newer)
            } else {
                text = L10n.DataStorage.vfrCycleNotPublished(airac)
            }
            return groups.count > 1 ? "\(countries.joined(separator: ", ")) · \(text)" : text
        }
    }

    /// The cycle's days, first to last, in UTC (the last day is the one before the next cycle):
    /// "1 Oct – 28 Oct 2026". Two `DateFormatter`s rather than a `DateIntervalFormatter`, whose patterns
    /// didn't follow the locale the row's "Data as of" date uses.
    nonisolated static func validityRange(_ cycle: Cycle) -> String {
        let utc = TimeZone(identifier: "UTC")
        let first = DateFormatter()
        first.timeZone = utc
        first.setLocalizedDateFormatFromTemplate("dMMM")
        let last = DateFormatter()
        last.timeZone = utc
        last.dateStyle = .medium
        last.timeStyle = .none
        let lastDay = max(cycle.validFrom, cycle.validTo.addingTimeInterval(-24 * 60 * 60))
        return "\(first.string(from: cycle.validFrom)) – \(last.string(from: lastDay))"
    }

    // MARK: Load

    /// Decode the cached countries off the main actor, once.
    func ensureLoaded() async {
        wantsLoaded = true
        guard !isLoaded else { return }
        await reload()
    }

    private func reload() async {
        let generation = self.generation
        let urls = downloadedCountries.map(countryFileURL)
        let files = await Task.detached(priority: .userInitiated) {
            let decoder = JSONDecoder()
            return urls.compactMap { url -> OFMRegionFile? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(OFMRegionFile.self, from: data)
            }
        }.value
        guard generation == self.generation else { return }   // a download or a delete moved on
        install(files)
    }

    private func install(_ files: [OFMRegionFile]) {
        let sorted = files.sorted { $0.country < $1.country }
        procedures = sorted.flatMap(\.procedures)
        points = sorted.flatMap(\.points)
        pointSets = sorted.map { PointSet(country: $0.country, airac: $0.airac, points: $0.points) }
        runways = sorted.reduce(into: [:]) { result, file in
            result.merge(file.runways) { first, _ in first }
        }
        thresholds = sorted.reduce(into: [:]) { result, file in
            result.merge(file.thresholds) { first, _ in first }
        }
        for file in sorted { if let region = file.region { regionByCountry[file.country] = region } }

        var procedureGrid: [GridKey: [Int]] = [:]
        var byAerodrome: [String: [Int]] = [:]
        for (index, procedure) in procedures.enumerated() {
            for key in Self.gridKeys(covering: procedure.bounds) { procedureGrid[key, default: []].append(index) }
            byAerodrome[procedure.aerodrome.uppercased(), default: []].append(index)
        }
        var pointGrid: [GridKey: [Int]] = [:]
        for (index, point) in points.enumerated() {
            pointGrid[Self.gridKey(latitude: point.position.latitude, longitude: point.position.longitude), default: []].append(index)
        }
        self.procedureGrid = procedureGrid
        self.proceduresByAerodrome = byAerodrome
        self.pointGrid = pointGrid
        isLoaded = true
        revision &+= 1
    }

    // MARK: Queries (1° grid)

    private struct GridKey: Hashable { let lat: Int; let lon: Int }

    private nonisolated static func gridKey(latitude: Double, longitude: Double) -> GridKey {
        GridKey(lat: latitude.safeRoundedInt(.down, or: 0), lon: longitude.safeRoundedInt(.down, or: 0))
    }

    private nonisolated static func gridKeys(covering bounds: VFRBounds) -> [GridKey] {
        let low = gridKey(latitude: bounds.minLatitude, longitude: bounds.minLongitude)
        let high = gridKey(latitude: bounds.maxLatitude, longitude: bounds.maxLongitude)
        // A procedure spans a few NM; a query box can't ask for more than the globe.
        guard high.lat - low.lat <= 180, high.lon - low.lon <= 360 else { return [] }
        return (low.lat...high.lat).flatMap { lat in (low.lon...high.lon).map { GridKey(lat: lat, lon: $0) } }
    }

    /// Procedures whose line or areas reach into `region`, of the given kinds and for any of the given
    /// categories, in file order (by country). Empty until `ensureLoaded()`.
    func procedures(in region: MKCoordinateRegion,
                    kinds: Set<VFRProcedure.Kind> = Set(VFRProcedure.Kind.allCases),
                    categories: Set<VFRProcedure.Category> = Set(VFRProcedure.Category.allCases)) -> [VFRProcedure] {
        let bounds = Self.bounds(of: region)
        let candidates = Set(Self.gridKeys(covering: bounds).flatMap { procedureGrid[$0] ?? [] })
        return candidates.sorted().map { procedures[$0] }.filter {
            kinds.contains($0.kind) && $0.isFor(any: categories) && $0.bounds.intersects(bounds)
        }
    }

    /// Every procedure of an aerodrome (its ICAO code, or OFM's code for a field without one).
    func procedures(forAerodrome code: String) -> [VFRProcedure] {
        (proceduresByAerodrome[code.uppercased()] ?? []).map { procedures[$0] }
    }

    /// Reporting points inside `region`.
    func points(in region: MKCoordinateRegion) -> [VFRPoint] {
        let bounds = Self.bounds(of: region)
        return Set(Self.gridKeys(covering: bounds).flatMap { pointGrid[$0] ?? [] })
            .sorted().map { points[$0] }.filter { bounds.contains($0.position) }
    }

    /// OFM's runway thresholds for an aerodrome, for the approach view's centreline. Empty when the file
    /// has none (older files) or OFM doesn't know them. (6.2.0)
    func thresholds(forAerodrome code: String) -> [VFRThreshold] {
        thresholds[code.uppercased()] ?? []
    }

    /// OFM's runway designators for an aerodrome (`["05/23"]`), for the runway vote. Empty when unknown.
    func runwayDesignators(forAerodrome code: String) -> [String] {
        runways[code.uppercased()] ?? []
    }

    /// OFM's region for a country: the downloaded file's, else the known one.
    func region(forCountry country: String) -> String? {
        regionByCountry[country.uppercased()] ?? OFMConfig.region(forCountry: country)
    }

    nonisolated static func bounds(of region: MKCoordinateRegion) -> VFRBounds {
        let halfLat = abs(region.span.latitudeDelta) / 2
        let halfLon = abs(region.span.longitudeDelta) / 2
        return VFRBounds(minLatitude: region.center.latitude - halfLat, maxLatitude: region.center.latitude + halfLat,
                         minLongitude: region.center.longitude - halfLon, maxLongitude: region.center.longitude + halfLon)
    }

    // MARK: Delete

    func deleteData() {
        try? fileManager.removeItem(at: dataDirectory)
        generation &+= 1
        index = nil
        failedCountries = []
        lastIndexAttempt = nil
        publish(OFMCacheMetadata())
        install([])
        isLoaded = wantsLoaded
    }
}
