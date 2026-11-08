import Combine
import CoreLocation
import Foundation

// MARK: - The NOTAM files on the device

// The server's index and the route's countries' files, fetched on the ground through the client hurdle and kept on
// disk for the flight: in the air the aerodrome card and the map read what's here, and nothing fetches. Free, like the
// airspace and the DABS, and never in a dry run or a test. A country that loses its list loses its file at the next
// refresh, so a NOTAM it had can't stay on a card. Nothing here replaces the official pages (decided 6 Nov 2026).

/// Where the copy on the device stands, in the words' terms.
struct NotamCopyState: Equatable {
    /// Over this, its age shows in amber.
    static let oldAfter: TimeInterval = 3600

    /// When the copy was current; nil with no copy.
    var time: Date?
    /// The last refresh failed.
    var couldNotRefresh = false

    func isOld(now: Date) -> Bool { time.map { now.timeIntervalSince($0) > Self.oldAfter } ?? false }

    /// Whole hours, for "3 h ago".
    func ageHours(now: Date) -> Int { time.map { max(Int(now.timeIntervalSince($0) / 3600), 1) } ?? 0 }
}

/// Fetches the index and the wanted countries' files when the flight page opens, on foreground, at START and on the
/// block's refresh, and keeps them on disk. Silent on failure: the copy stays, and the block says so.
@MainActor
final class NotamService: ObservableObject {
    static let shared = NotamService()

    static let allowedHosts = Set([APIConfig.dataURL("notams/v1").host?.lowercased()].compactMap { $0 })
    static let maxIndexBytes = 512 * 1024
    /// The largest country runs to 6.4 MB.
    static let maxFileBytes = 16 * 1024 * 1024
    /// The server's job runs every 15 minutes: a foreground or a page sooner has nothing to find.
    nonisolated static let minInterval: TimeInterval = 15 * 60
    /// The refresh button's own limit: a second tap fetches nothing new.
    nonisolated static let minForcedInterval: TimeInterval = 20
    /// A country no flight has asked for in this long leaves the device.
    nonisolated static let keptFor: TimeInterval = 8 * 24 * 3600
    /// A country only looked at on Plan › Map, no flight planned through it, leaves after a day (decision q3, 6.10.0).
    nonisolated static let lookedAtKeptFor: TimeInterval = 24 * 3600

    static func url(_ file: String) -> URL { APIConfig.dataURL("notams/v1/\(file)") }

    /// What's on the device beyond the files.
    private struct Memory: Codable {
        /// When this device first saw each NOTAM: what "new since your tick" compares with the tick.
        var firstSeen: [String: Date] = [:]
        /// When a flight last asked for each file.
        var wanted: [String: Date] = [:]
        /// When Plan › Map last asked for each file, for the country under it. Optional: older copies don't have it.
        var lookedAt: [String: Date]?
        /// Each file's ETag, for the next conditional fetch.
        var etags: [String: String] = [:]
        /// The index's time for a country when its file was last known to match: the copy's age. The file's own time only
        /// says when it last changed.
        var confirmed: [String: Date] = [:]
    }

    /// A fetch's answer: the body and its ETag, or no body for a 304, nothing new.
    struct Reply {
        var body: Data?
        var etag: String?
    }

    @Published private(set) var index: NotamIndex?
    /// By file name.
    @Published private(set) var files: [String: NotamFile] = [:]
    @Published private(set) var couldNotRefresh = false
    @Published private(set) var isLoading = false
    /// Bumped when the data changes: what's worked out from it starts again.
    @Published private(set) var revision = 0

    private var memory = Memory()
    private var byLocation: [String: [Notam]] = [:]
    private var everything: [Notam] = []
    private var lastFetch: Date?
    private var lastForced: Date?
    private var isOnDisk = false
    private var sortMemo: (revision: Int, minute: Int, flight: NotamFlight, countries: [String], sorted: NotamSorted)?

    private let folder: URL
    private let fetchOverride: ((URL, String?) async throws -> Reply)?
    private let now: () -> Date

    init(folder: URL? = nil, fetch: ((URL, String?) async throws -> Reply)? = nil, now: @escaping () -> Date = { FlightClock.now }) {
        self.folder = folder ?? DataPersistenceManager.shared.localAppDirectory.appendingPathComponent("notams", isDirectory: true)
        var override = fetch
        #if DEBUG
        // A local folder of the server's files, in place of the network: a look at the screens. (AEROCHECK_NOTAM_DIR)
        // `fixture` is the screenshot run's copy, put in `Library/Application Support/DebugFixtures/notams/` as the
        // weather's (6.10.0).
        if override == nil, let local = ProcessInfo.processInfo.environment["AEROCHECK_NOTAM_DIR"], !local.isEmpty {
            let root = local == "fixture"
                ? URL.applicationSupportDirectory.appending(path: "DebugFixtures/notams", directoryHint: .isDirectory)
                : URL(fileURLWithPath: local, isDirectory: true)
            override = { url, _ in Reply(body: try Data(contentsOf: root.appendingPathComponent(url.lastPathComponent))) }
        }
        #endif
        fetchOverride = override
        self.now = now
    }

    /// Never in a dry run. The tests' host is the app: only a service given its own fetch reaches out, and never the network.
    private var mayFetch: Bool {
        guard !DryRunCenter.shared.isRunning else { return false }
        return fetchOverride != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    // MARK: Reading

    /// Whether `country` has a list on this device: the server's index says so and its file is here.
    func hasList(_ country: String) -> Bool {
        guard let index, index.hasList(country), let entry = index.countries[country.uppercased()] else { return false }
        return files[entry.file] != nil
    }

    /// The countries at a point. The bundled borders are coarse (Switzerland has 85 points) and about one point in twenty of
    /// the Jura falls in no country: a point the exact test can't place takes those within 5 NM, so the map's word on a
    /// country without a list doesn't drop out along a border.
    static func countries(at coordinate: CLLocationCoordinate2D) -> Set<String> {
        let exact = CountryBoundaries.shared.countries(near: coordinate, bufferNm: 0)
        return exact.isEmpty ? CountryBoundaries.shared.countries(near: coordinate, bufferNm: 5) : exact
    }

    /// Every NOTAM of `countries` on the device, each once, those past their end left out: one can pass it between the
    /// server's daily runs. Liechtenstein shares Switzerland's file.
    func notams(in countries: [String]) -> [Notam] {
        guard let index else { return [] }
        let at = now()
        var seen = Set<String>()
        var out: [Notam] = []
        for country in countries {
            guard hasList(country), let entry = index.countries[country.uppercased()],
                  seen.insert(entry.file).inserted else { continue }
            out += (files[entry.file]?.notams ?? []).filter { ($0.end ?? .distantFuture) >= at }
        }
        return out
    }

    /// Everything on the device still in force, for the map.
    var allNotams: [Notam] {
        let at = now()
        return everything.filter { ($0.end ?? .distantFuture) >= at }
    }

    /// A field's NOTAMs on the device, those over left out, the one that applies first on top.
    func notams(at ident: String, now moment: Date? = nil) -> [Notam] {
        let at = moment ?? now()
        return (byLocation[ident.uppercased()] ?? []).filter { ($0.end ?? .distantFuture) >= at }.sorted { a, b in
            let (sa, sb) = (a.start ?? .distantPast, b.start ?? .distantPast)
            return sa != sb ? sa < sb : a.number < b.number
        }
    }

    /// The sorted list for a flight; worked out once for each state of the data.
    func sorted(for flight: NotamFlight, countries: [String]) -> NotamSorted {
        // To the minute, for a NOTAM reaching its end with the page open.
        let minute = Int(now().timeIntervalSinceReferenceDate / 60)
        if let memo = sortMemo, memo.revision == revision, memo.minute == minute, memo.flight == flight,
           memo.countries == countries { return memo.sorted }
        let sorted = NotamSorter.sort(notams(in: countries), for: flight)
        sortMemo = (revision, minute, flight, countries, sorted)
        return sorted
    }

    var firstSeen: [String: Date] { memory.firstSeen }

    /// The copy's time for `countries`, the oldest of them; with none named, of everything on the device. The United
    /// States' file only changes daily, so its age is over an hour most of the day: the amber is right there.
    func copyState(countries: [String]) -> NotamCopyState {
        guard let index else { return NotamCopyState(time: nil, couldNotRefresh: couldNotRefresh) }
        let names = countries.isEmpty ? Array(files.keys)
            : countries.compactMap { index.countries[$0.uppercased()]?.file }.filter { files[$0] != nil }
        let time = names.compactMap { name in
            memory.confirmed[name] ?? index.countries.values.first { $0.file == name }?.updatedUtc
        }.min()
        return NotamCopyState(time: time ?? index.generatedUtc, couldNotRefresh: couldNotRefresh)
    }

    /// What the country's line says, where the server has one.
    func note(for country: String) -> String? {
        index?.countries[country.uppercased()]?.note?.text()
    }

    // MARK: Fetching

    /// When the flight page opens, on foreground, at START. Only on the ground; `force` is the block's refresh button.
    /// A country not on the device yet doesn't wait for the interval. `lookedAt`: the country under Plan › Map, kept a day
    /// rather than a flight's 8.
    func refreshIfNeeded(countries: [String], force: Bool = false, onGround: Bool, lookedAt: Bool = false) async {
        await ensureLoaded()
        guard onGround, mayFetch else { return }
        let moment = now()
        let wanted = Set(countries.map { $0.uppercased() })
        let missing = wanted.contains { code in
            index?.countries[code].map { files[$0.file] == nil } ?? (index == nil)
        }
        if force {
            if let lastForced, moment.timeIntervalSince(lastForced) < Self.minForcedInterval { return }
            lastForced = moment
        } else if !missing, let lastFetch, moment.timeIntervalSince(lastFetch) < Self.minInterval {
            return
        }
        await refresh(countries: wanted, lookedAt: lookedAt)
    }

    private func refresh(countries: Set<String>, lookedAt: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let moment = now()
        guard let indexData = try? await fetch(Self.url("index.json"), etag: nil, maxBytes: Self.maxIndexBytes).body,
              let newIndex = try? JSONDecoder().decode(NotamIndex.self, from: indexData), newIndex.v == NotamIndex.schema else {
            couldNotRefresh = true
            return
        }
        lastFetch = moment
        var looked = memory.lookedAt ?? [:]
        for code in countries {
            guard let entry = newIndex.countries[code], newIndex.hasList(code) else { continue }
            if lookedAt { looked[entry.file] = moment } else { memory.wanted[entry.file] = moment }
        }
        memory.wanted = memory.wanted.filter { moment.timeIntervalSince($0.value) < Self.keptFor }
        memory.lookedAt = looked.filter { moment.timeIntervalSince($0.value) < Self.lookedAtKeptFor }
        let asked = memory
        let kept = { (name: String) in asked.wanted[name] != nil || asked.lookedAt?[name] != nil }
        var updated = files
        // Whatever no country has any more, or no flight has asked for in a while, goes.
        let listed = Set(newIndex.countries.filter { newIndex.hasList($0.key) }.map(\.value.file))
        updated = updated.filter { listed.contains($0.key) && kept($0.key) }
        var failed = false
        // Every wanted file, conditionally: the index's time moves at every run, whether a file changed or not.
        var entries: [String: NotamIndex.Country] = [:]
        for (code, entry) in newIndex.countries where kept(entry.file) && newIndex.hasList(code) { entries[entry.file] = entry }
        var fresh: [String: Data] = [:]
        for (name, entry) in entries.sorted(by: { $0.key < $1.key }) {
            guard let reply = try? await fetch(Self.url(name), etag: updated[name] == nil ? nil : memory.etags[name],
                                               maxBytes: Self.maxFileBytes) else { failed = true; continue }
            guard let data = reply.body else {
                memory.confirmed[name] = entry.updatedUtc
                continue
            }
            let decoded = await Task.detached(priority: .utility) { try? JSONDecoder().decode(NotamFile.self, from: data) }.value
            guard let file = decoded, file.v == NotamIndex.schema else { failed = true; continue }
            // The first copy of a country is its baseline: what it holds wasn't "new" to anyone.
            let baseline = files[name] == nil
            for notam in file.notams where memory.firstSeen[notam.id] == nil {
                memory.firstSeen[notam.id] = baseline ? .distantPast : moment
            }
            updated[name] = file
            fresh[name] = data
            memory.etags[name] = reply.etag
            memory.confirmed[name] = entry.updatedUtc
        }
        let ids = Set(updated.values.flatMap { $0.notams.map(\.id) })
        memory.firstSeen = memory.firstSeen.filter { ids.contains($0.key) }
        memory.etags = memory.etags.filter { updated[$0.key] != nil }
        memory.confirmed = memory.confirmed.filter { updated[$0.key] != nil }
        await store(index: indexData, fresh: fresh, kept: Set(updated.keys))
        index = newIndex
        files = updated
        couldNotRefresh = failed
        await rebuild()
    }

    /// The copy from the disk, once: for a flight after a relaunch, with no signal.
    func ensureLoaded() async {
        guard !isOnDisk else { return }
        isOnDisk = true
        let folder = self.folder
        let read = await Task.detached(priority: .utility) { () -> (NotamIndex?, [String: NotamFile], Memory?) in
            let decoder = JSONDecoder()
            let index = (try? Data(contentsOf: folder.appendingPathComponent("index.json")))
                .flatMap { try? decoder.decode(NotamIndex.self, from: $0) }
            var files: [String: NotamFile] = [:]
            for name in Set((index?.countries.values).map { $0.map(\.file) } ?? []) {
                if let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                   let file = try? decoder.decode(NotamFile.self, from: data) { files[name] = file }
            }
            let memory = (try? Data(contentsOf: folder.appendingPathComponent(Self.memoryName)))
                .flatMap { try? decoder.decode(Memory.self, from: $0) }
            return (index, files, memory)
        }.value
        // A refresh that got here first has the newer data.
        guard index == nil else { return }
        index = read.0
        files = read.1
        if let saved = read.2 { memory = saved }
        await rebuild()
    }

    private nonisolated static let memoryName = "memory.json"

    /// What the lists and the map read, worked out from the files.
    private struct Built {
        var everything: [Notam] = []
        var byLocation: [String: [Notam]] = [:]
        var areaActivations: [NotamArea] = []
    }

    private nonisolated static func build(_ files: [String: NotamFile]) -> Built {
        var built = Built()
        var seen = Set<String>()
        built.everything = files.keys.sorted().flatMap { files[$0]?.notams ?? [] }.filter { !$0.isChecklist && seen.insert($0.id).inserted }
        built.byLocation = Dictionary(grouping: built.everything, by: \.location)
        // Switzerland (and Liechtenstein, in its file) has the DABS, which carries its NOTAMs' areas already.
        var once = Set<String>()
        built.areaActivations = files.keys.sorted().flatMap { name -> [NotamArea] in
            guard let file = files[name], let country = file.country?.uppercased(), country != "CH", country != "LI" else { return [] }
            return file.notams.compactMap { notam in
                // The FAA repeats a NOTAM for each place on its line A: one area
                guard let activation = notam.activation, once.insert(notam.sameNotamKey).inserted else { return nil }
                return NotamArea(notam: notam, activation: activation, country: country)
            }
        }
        return built
    }

    private func apply(_ built: Built) {
        everything = built.everything
        byLocation = built.byLocation
        areaActivations = built.areaActivations
        revision += 1
    }

    /// Off the main thread: 1 to 2.5 ms of it for three or four countries. A later build supersedes one still running.
    /// (6.10.0)
    private func rebuild() async {
        buildGeneration += 1
        let generation = buildGeneration
        let files = self.files
        let built = await Task.detached(priority: .utility) { Self.build(files) }.value
        guard generation == buildGeneration else { return }
        apply(built)
    }

    private var buildGeneration = 0

    /// Abroad, the NOTAMs that create or activate an area, each once (6.10.0).
    private(set) var areaActivations: [NotamArea] = []

    /// The files written off the main thread: a country's runs to several megabytes, written with file protection. (6.10.0)
    private func store(index data: Data, fresh: [String: Data], kept: Set<String>) async {
        let folder = self.folder
        let options = DataPersistenceManager.protectedWriteOptions
        let saved = try? JSONEncoder().encode(memory)
        await Task.detached(priority: .utility) {
            Self.write(index: data, fresh: fresh, memory: saved, kept: kept, in: folder, options: options)
        }.value
    }

    private nonisolated static func write(index data: Data, fresh: [String: Data], memory saved: Data?, kept: Set<String>,
                                          in folder: URL, options: Data.WritingOptions) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent("index.json"), options: options)
        for (name, body) in fresh {
            try? body.write(to: folder.appendingPathComponent(name), options: options)
        }
        if let saved {
            try? saved.write(to: folder.appendingPathComponent(memoryName), options: options)
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where !kept.contains(name) && name != "index.json" && name != memoryName {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private enum FetchError: Error { case http(Int), tooLarge }

    /// GET a file: on the allow-list, under the size cap, a 200, or a 304 when `etag` still stands.
    private func fetch(_ url: URL, etag: String?, maxBytes: Int) async throws -> Reply {
        guard ExternalRequest.isAllowed(url, hosts: Self.allowedHosts) else { throw ExternalRequest.HostError.notAllowed }
        if let fetchOverride { return try await fetchOverride(url, etag) }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let secret = APIConfig.appClientSecret { request.setValue(secret, forHTTPHeaderField: "X-AeroCheck-Client") }
        let (body, response) = try await ExternalRequest.data(for: request, maxResponseBytes: maxBytes,
                                                              allowedHosts: Self.allowedHosts)
        if response.statusCode == 304, etag != nil { return Reply(body: nil, etag: etag) }
        guard response.statusCode == 200 else { throw FetchError.http(response.statusCode) }
        guard body.count <= maxBytes else { throw FetchError.tooLarge }
        return Reply(body: body, etag: response.value(forHTTPHeaderField: "ETag"))
    }

    /// Seeded directly in tests, so no test has to reach the network.
    func seedForTesting(index: NotamIndex?, files: [String: NotamFile], firstSeen: [String: Date] = [:]) {
        isOnDisk = true
        self.index = index
        self.files = files
        memory.firstSeen = firstSeen
        buildGeneration += 1
        apply(Self.build(files))
    }
}
