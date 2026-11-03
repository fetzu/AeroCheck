import CoreLocation
import Foundation
import UIKit

/// The pilot's map regions on this device: the index, the downloads (Settings › Data & Storage, and a planned
/// flight's regions with its other trip data), the update every three months, and the allowance's level for the
/// screens that show it. A downloaded region never counts against the allowance. The same tiles are never fetched
/// twice: a file whose hash (or date) the index still lists isn't asked for, and one that is goes with its ETag, so
/// R2 answers "not modified" when nothing changed. (6.8.0)
@MainActor
final class PilotMapDownloads: ObservableObject {
    static let shared = PilotMapDownloads(source: PilotMap.shared, imagery: PilotMap.imagery)

    /// One file's transfer: the request, a progress callback (0…1), and what came back. Tests replace it.
    typealias Transfer = @Sendable (URLRequest, @escaping @Sendable (Double) -> Void) async throws -> Transferred

    enum Transferred: Equatable, Sendable {
        /// The downloaded file, moved somewhere the caller owns, and its ETag.
        case file(URL, etag: String?)
        /// 304: the copy here (its ETag sent as If-None-Match) is the file on the server.
        case unchanged
    }

    /// A downloaded region updates itself once its copy is this many months old (decided 26 Oct 2026: a month of OpenStreetMap
    /// edits changes nearly every tile and little a pilot sees, so monthly updates cost much and give little).
    static let autoUpdateMonths = 3

    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case downloaded
        /// Downloaded, and the index has a newer build of the map or the relief.
        case updateAvailable
        case failed
    }

    enum Failure: Error, Equatable {
        case http(Int)
        case wrongSize
        case notEnoughSpace
    }

    /// The month's downloads used up on this device (the Atlas gate's ceiling: free 40, Pro 120 files). (6.8.0)
    struct Ceiling: Equatable {
        let limit: Int
        let resetsAt: Date?
    }

    /// The links a download asks the Atlas gate for; the tests replace it.
    typealias Links = @Sendable ([String]) async -> AtlasAccess.Links

    @Published private(set) var regions: [PilotMapRegion] = []
    @Published private(set) var downloaded: [PilotMapRegion] = []
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var failed: Set<String> = []
    @Published private(set) var allowanceLevel: PilotMapAllowance.Level = .open
    @Published private(set) var allowanceUsed = 0
    @Published private(set) var allowanceLimit = PilotMapAllowance.freeReads
    /// Set when the server refused a download for the month's ceiling; cleared by the next download it allows.
    @Published private(set) var ceiling: Ceiling?

    /// "This month's downloads are used up (40 files). They start again on 1 Nov.", while the ceiling holds.
    var ceilingMessage: String? {
        guard let ceiling else { return nil }
        return L10n.PilotMap.ceiling(limit: ceiling.limit, resetsAt: ceiling.resetsAt ?? Self.nextMonth())
    }

    /// The first of next month, where the server didn't say when the ceiling resets.
    nonisolated static func nextMonth(_ now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        return calendar.date(byAdding: .month, value: 1, to: start) ?? now
    }

    let source: PilotTileSource
    /// The imagery's sources, refreshed with the index; nil in tests that don't need them.
    let imagery: ImageryStore?
    private let transfer: Transfer
    private let links: Links
    private let freeSpace: () -> Int64?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var allowanceObserver: NSObjectProtocol?

    init(source: PilotTileSource, imagery: ImageryStore? = nil,
         transfer: @escaping Transfer = PilotMapDownloads.urlSessionTransfer,
         links: @escaping Links = { await AtlasAccess.shared.links($0) },
         freeSpace: @escaping () -> Int64? = PilotMapDownloads.availableCapacity) {
        self.source = source
        self.imagery = imagery
        self.transfer = transfer
        self.links = links
        self.freeSpace = freeSpace
        reload()
        allowanceObserver = NotificationCenter.default.addObserver(forName: PilotMapAllowance.levelChanged,
                                                                   object: source.allowance, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadAllowance() }
        }
    }

    deinit {
        if let allowanceObserver { NotificationCenter.default.removeObserver(allowanceObserver) }
    }

    func reload() {
        regions = source.index.regions
        downloaded = source.storage.downloaded
        reloadAllowance()
    }

    func reloadAllowance() {
        allowanceLevel = source.allowance.level
        allowanceUsed = source.allowance.used
        allowanceLimit = source.allowance.limit
    }

    /// Pro and lifetime get the larger allowance; called whenever `SubscriptionManager.shouldAllowPremiumAccess()`
    /// may have changed (it holds Pro through a flight started with it).
    func setPro(_ isPro: Bool) {
        source.allowance.plan = isPro ? .pro : .free
        reloadAllowance()
    }

    /// The index, when it is older than `maxAge`; drops the directories of builds it no longer lists.
    func refreshIndex(maxAge: TimeInterval = 6 * 3600) async {
        if await source.index.refresh(maxAge: maxAge) { source.pruneDirectoryCache() }
        // The aerial imagery's sources come from the same host, as often. (6.8.0)
        await imagery?.refresh(maxAge: maxAge)
        reload()
    }

    // MARK: - State

    func state(of id: String) -> State {
        if let fraction = progress[id] { return .downloading(fraction) }
        if failed.contains(id) { return .failed }
        guard let installed = downloaded.first(where: { $0.id == id }) else { return .notDownloaded }
        guard let listed = listed(id) else { return .downloaded }
        return Self.kindsToFetch(listed: listed, installed: installed, filesPresent: filesPresent(id)).isEmpty
            ? .downloaded : .updateAvailable
    }

    var bytesOnDisk: Int64 { source.storage.bytesOnDisk }

    /// The overview to download, its map only: every country zoomed out, offline (the author's answer to question
    /// 10, 30 Oct 2026). nil until the index has one.
    var overview: PilotMapRegion? { source.index.overview?.mapOnly(named: L10n.PilotMap.overview) }

    /// The entry the index lists for a downloaded id: a region, or the overview.
    private func listed(_ id: String) -> PilotMapRegion? {
        id == PilotMapRegion.overviewID ? overview : regions.first { $0.id == id }
    }

    /// The entry to download for an update of `id`. (6.8.0)
    func listedRegion(_ id: String) -> PilotMapRegion? { listed(id) }

    /// What a download fetches: each archive the index lists that is missing here or of another build.
    static func kindsToFetch(listed: PilotMapRegion, installed: PilotMapRegion?, filesPresent: Set<PilotMapKind>) -> [PilotMapKind] {
        PilotMapKind.allCases.filter { kind in
            guard listed.has(kind) else { return false }
            guard let installed, filesPresent.contains(kind) else { return true }
            if let have = installed.hash(of: kind), have == listed.hash(of: kind) { return false }
            return installed.build(of: kind) != listed.build(of: kind)
        }
    }

    /// Whether the update every three months is due: a file is missing, or one to fetch is from a build that old.
    static func autoUpdateDue(listed: PilotMapRegion, installed: PilotMapRegion, filesPresent: Set<PilotMapKind>,
                              now: Date = Date()) -> Bool {
        let kinds = kindsToFetch(listed: listed, installed: installed, filesPresent: filesPresent)
        // Build dates are UTC days: the cutoff is counted in UTC too, whatever the device's time zone.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let cutoff = utc.date(byAdding: .month, value: -autoUpdateMonths, to: now) else { return false }
        let format = DateFormatter()
        format.calendar = utc
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyyMMdd"
        return kinds.contains { kind in
            guard filesPresent.contains(kind), let built = format.date(from: installed.build(of: kind)) else { return true }
            return built <= cutoff
        }
    }

    private func filesPresent(_ id: String) -> Set<PilotMapKind> {
        Set(PilotMapKind.allCases.filter {
            FileManager.default.fileExists(atPath: source.storage.fileURL(region: id, kind: $0).path)
        })
    }

    /// Bytes a download of the region would fetch now.
    func bytesToFetch(_ region: PilotMapRegion) -> Int {
        let installed = downloaded.first { $0.id == region.id }
        return Self.kindsToFetch(listed: region, installed: installed, filesPresent: filesPresent(region.id))
            .reduce(0) { $0 + ($1 == .map ? region.mapBytes : region.reliefBytes) }
    }

    // MARK: - A route's regions

    /// The regions a route needs: for every point along it (sampled every 10 NM), the first region in the index
    /// whose box holds it. Boxes overlap at borders, so a point near one may name the neighbour: the route's next
    /// points name the right one, and a download too many is a small one.
    static func regions(along route: [CLLocationCoordinate2D], in regions: [PilotMapRegion]) -> [PilotMapRegion] {
        var found: [PilotMapRegion] = []
        for point in RouteDataCalculator.sampledPoints(for: route) {
            guard let region = region(at: point, in: regions) else { continue }
            if !found.contains(where: { $0.id == region.id }) { found.append(region) }
        }
        return found
    }

    /// The first region in the index whose box holds the point, as the map picks it.
    static func region(at point: CLLocationCoordinate2D, in regions: [PilotMapRegion]) -> PilotMapRegion? {
        regions.first { $0.contains(latitude: point.latitude, longitude: point.longitude) }
    }

    /// The region under a point when it isn't on the device yet: what the allowance line offers. (6.8.0)
    func missingRegion(at point: CLLocationCoordinate2D) -> PilotMapRegion? {
        guard let region = Self.region(at: point, in: regions),
              !downloaded.contains(where: { $0.id == region.id }) else { return nil }
        return region
    }

    /// The route's regions not downloaded yet (an update due is not a gap: the old build still draws).
    func missingRegions(along route: [CLLocationCoordinate2D]) -> [PilotMapRegion] {
        guard route.count >= 2 else { return [] }
        let have = Set(downloaded.map(\.id))
        return Self.regions(along: route, in: regions).filter { !have.contains($0.id) }
    }

    // MARK: - Download

    func download(_ region: PilotMapRegion) {
        guard tasks[region.id] == nil else { return }
        tasks[region.id] = Task { [weak self] in
            await self?.run(region)
        }
    }

    /// Downloads the region and waits for it; false when it failed.
    @discardableResult
    func downloadNow(_ region: PilotMapRegion) async -> Bool {
        download(region)
        await tasks[region.id]?.value
        return downloaded.contains { $0.id == region.id } && !failed.contains(region.id)
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
    }

    func delete(_ id: String) {
        cancel(id)
        source.storage.remove(id)
        failed.remove(id)
        reload()
    }

    func deleteAll() {
        for region in downloaded { delete(region.id) }
    }

    private func run(_ region: PilotMapRegion) async {
        failed.remove(region.id)
        progress[region.id] = 0
        defer {
            progress[region.id] = nil
            tasks[region.id] = nil
            reload()
        }
        let installed = downloaded.first { $0.id == region.id }
        let kinds = Self.kindsToFetch(listed: region, installed: installed, filesPresent: filesPresent(region.id))
        guard !kinds.isEmpty else { return }
        let total = kinds.reduce(0) { $0 + ($1 == .map ? region.mapBytes : region.reliefBytes) }
        if let free = freeSpace(), free < Int64(Double(total) * 1.2) + 50_000_000 {
            failed.insert(region.id)
            AppLog.general.publicLine("Pilot's map download refused: not enough space")
            return
        }
        // Finishes a file under way when the app goes to the background; a whole region takes longer, and a
        // download stopped there is offered again.
        let background = UIApplication.shared.beginBackgroundTask(withName: "PilotMapDownload")
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }

        // The Atlas gate: one-hour links to Cloudflare's storage, counted against this month's ceiling. Without the
        // gate on the server (yet), the files come from tiles.aerocheck.app as before.
        let names = kinds.map { Self.archiveName(region, $0) }
        var linked: [String: URL] = [:]
        switch await links(names) {
        case let .links(urls):
            linked = urls
            ceiling = nil
        case let .ceiling(limit, resetsAt):
            ceiling = Ceiling(limit: limit, resetsAt: resetsAt)
            failed.insert(region.id)
            AppLog.general.publicLine("Pilot's map download refused: this month's downloads are used up")
            return
        case .unavailable:
            break
        }

        var files: [PilotMapKind: URL] = [:]
        var etags: [PilotMapKind: String] = [:]
        var done = 0
        let present = filesPresent(region.id)
        do {
            for kind in kinds {
                let expected = kind == .map ? region.mapBytes : region.reliefBytes
                let link = linked[Self.archiveName(region, kind)]
                var request = URLRequest(url: link ?? PilotMapConfig.archiveURL(region: region, kind: kind),
                                         cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
                if link == nil {
                    for (field, value) in PilotMapConfig.requestHeaders { request.setValue(value, forHTTPHeaderField: field) }
                } else {
                    request.setValue(PilotMapConfig.userAgent, forHTTPHeaderField: "User-Agent")
                }
                if present.contains(kind), let etag = source.storage.etag(region: region.id, kind: kind) {
                    request.setValue(etag, forHTTPHeaderField: "If-None-Match")
                }
                let before = done
                let answer = try await transfer(request) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.progress[region.id] != nil else { return }
                        self.progress[region.id] = Double(before) / Double(max(total, 1))
                            + fraction * Double(expected) / Double(max(total, 1))
                    }
                }
                done += expected
                guard case let .file(file, etag) = answer else {
                    // Not modified: the file here stays, under the index's newer entry.
                    try Task.checkCancellation()
                    continue
                }
                files[kind] = file
                if let etag { etags[kind] = etag }
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
                guard expected <= 0 || size == expected else { throw Failure.wrongSize }
                try Task.checkCancellation()
            }
            try source.storage.install(region, files: files, etags: etags)
            AppLog.general.publicLine("Pilot's map region downloaded (\(files.count) of \(kinds.count) files changed)")
        } catch {
            for file in files.values { try? FileManager.default.removeItem(at: file) }
            if !(error is CancellationError) { failed.insert(region.id) }
            AppLog.general.publicLine("Pilot's map download failed: \(type(of: error))")
        }
    }

    /// An archive as the Atlas gate names it: `<region>/<file>`.
    nonisolated static func archiveName(_ region: PilotMapRegion, _ kind: PilotMapKind) -> String {
        "\(region.id)/\(region.file(of: kind))"
    }

    /// The update every three months: each downloaded region the index has another build of, once the copy here is
    /// three months old, on an unmetered network only (a region is tens of megabytes or more), never in flight.
    /// A pilot can update sooner by hand. Called when the app comes to the foreground.
    func updateDownloaded(conditions: NetworkConditions, inFlight: Bool, now: Date = Date()) async {
        if conditions.isConnected { await refreshIndex() }
        guard Self.allowsSilentDownload(conditions), !inFlight else { return }
        for region in downloaded {
            guard let listed = listed(region.id), state(of: region.id) == .updateAvailable,
                  Self.autoUpdateDue(listed: listed, installed: region, filesPresent: filesPresent(region.id), now: now)
            else { continue }
            await downloadNow(listed)
        }
    }

    /// A silent download of a region: Wi-Fi (or another unmetered path), not Low Data Mode.
    nonisolated static func allowsSilentDownload(_ conditions: NetworkConditions) -> Bool {
        conditions.isConnected && !conditions.isExpensive && !conditions.isConstrained
    }

    // MARK: - Defaults

    nonisolated static func availableCapacity() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// A download task on the pilot's map session, its progress observed, the file moved out of URLSession's
    /// temporary place before the handler returns; a 304 (the If-None-Match matched) is `.unchanged`.
    nonisolated static let urlSessionTransfer: Transfer = { request, onProgress in
        let box = TransferBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Transferred, Error>) in
                let task = PilotMapConfig.session.downloadTask(with: request) { location, response, error in
                    box.observation?.invalidate()
                    if let error { continuation.resume(throwing: error); return }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: URLError(.badServerResponse)); return
                    }
                    if http.statusCode == 304 { continuation.resume(returning: .unchanged); return }
                    guard http.statusCode == 200, let location else {
                        continuation.resume(throwing: Failure.http(http.statusCode)); return
                    }
                    let kept = FileManager.default.temporaryDirectory
                        .appendingPathComponent("pilotmap-\(UUID().uuidString).pmtiles")
                    do {
                        try FileManager.default.moveItem(at: location, to: kept)
                        continuation.resume(returning: .file(kept, etag: http.value(forHTTPHeaderField: "ETag")))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.observation = task.progress.observe(\.fractionCompleted) { progress, _ in
                    onProgress(progress.fractionCompleted)
                }
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    private final class TransferBox: @unchecked Sendable {
        var observation: NSKeyValueObservation?
        var task: URLSessionDownloadTask?
    }
}
