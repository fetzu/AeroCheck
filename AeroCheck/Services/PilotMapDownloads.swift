import CoreLocation
import Foundation
import UIKit

/// The pilot's map regions on this device: the index, the downloads (Settings › Data & Storage, and a planned
/// flight's regions with its other trip data), the monthly update by the index's dates, and the allowance's level for
/// the screens that show it. A downloaded region never counts against the allowance. (6.8.0)
@MainActor
final class PilotMapDownloads: ObservableObject {
    static let shared = PilotMapDownloads(source: PilotMap.shared, imagery: PilotMap.imagery)

    /// One file's transfer: the request, a progress callback (0…1), and the downloaded file, moved somewhere the
    /// caller owns. Tests replace it.
    typealias Transfer = @Sendable (URLRequest, @escaping @Sendable (Double) -> Void) async throws -> URL

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

    @Published private(set) var regions: [PilotMapRegion] = []
    @Published private(set) var downloaded: [PilotMapRegion] = []
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var failed: Set<String> = []
    @Published private(set) var allowanceLevel: PilotMapAllowance.Level = .open
    @Published private(set) var allowanceUsed = 0
    @Published private(set) var allowanceLimit = PilotMapAllowance.freeReads

    let source: PilotTileSource
    /// The imagery's sources, refreshed with the index; nil in tests that don't need them.
    let imagery: ImageryStore?
    private let transfer: Transfer
    private let freeSpace: () -> Int64?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var allowanceObserver: NSObjectProtocol?

    init(source: PilotTileSource, imagery: ImageryStore? = nil,
         transfer: @escaping Transfer = PilotMapDownloads.urlSessionTransfer,
         freeSpace: @escaping () -> Int64? = PilotMapDownloads.availableCapacity) {
        self.source = source
        self.imagery = imagery
        self.transfer = transfer
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
        guard let listed = regions.first(where: { $0.id == id }) else { return .downloaded }
        return Self.kindsToFetch(listed: listed, installed: installed, filesPresent: filesPresent(id)).isEmpty
            ? .downloaded : .updateAvailable
    }

    var bytesOnDisk: Int64 { source.storage.bytesOnDisk }

    /// What a download fetches: each archive the index lists that is missing here or of another build.
    static func kindsToFetch(listed: PilotMapRegion, installed: PilotMapRegion?, filesPresent: Set<PilotMapKind>) -> [PilotMapKind] {
        PilotMapKind.allCases.filter { kind in
            guard listed.has(kind) else { return false }
            guard let installed, filesPresent.contains(kind) else { return true }
            return installed.build(of: kind) != listed.build(of: kind)
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
    /// whose box holds it, as the map itself picks them. A region's box carries its margin past the border.
    static func regions(along route: [CLLocationCoordinate2D], in regions: [PilotMapRegion]) -> [PilotMapRegion] {
        var found: [PilotMapRegion] = []
        for point in RouteDataCalculator.sampledPoints(for: route) {
            guard let region = regions.first(where: {
                point.longitude >= $0.bounds[0] && point.longitude <= $0.bounds[2]
                    && point.latitude >= $0.bounds[1] && point.latitude <= $0.bounds[3]
            }) else { continue }
            if !found.contains(where: { $0.id == region.id }) { found.append(region) }
        }
        return found
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

        var files: [PilotMapKind: URL] = [:]
        var done = 0
        do {
            for kind in kinds {
                let expected = kind == .map ? region.mapBytes : region.reliefBytes
                var request = URLRequest(url: PilotMapConfig.archiveURL(region: region.id, kind: kind),
                                         cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
                for (field, value) in PilotMapConfig.requestHeaders { request.setValue(value, forHTTPHeaderField: field) }
                let before = done
                let file = try await transfer(request) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.progress[region.id] != nil else { return }
                        self.progress[region.id] = Double(before) / Double(max(total, 1))
                            + fraction * Double(expected) / Double(max(total, 1))
                    }
                }
                files[kind] = file
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
                guard expected <= 0 || size == expected else { throw Failure.wrongSize }
                done += expected
                try Task.checkCancellation()
            }
            try source.storage.install(region, files: files)
            AppLog.general.publicLine("Pilot's map region downloaded (\(kinds.count) files)")
        } catch {
            for file in files.values { try? FileManager.default.removeItem(at: file) }
            if !(error is CancellationError) { failed.insert(region.id) }
            AppLog.general.publicLine("Pilot's map download failed: \(type(of: error))")
        }
    }

    /// The monthly update: each downloaded region the index has a newer build of, on an unmetered network only
    /// (a region is a hundred megabytes or more), never in flight. Called when the app comes to the foreground.
    func updateDownloaded(conditions: NetworkConditions, inFlight: Bool) async {
        if conditions.isConnected { await refreshIndex() }
        guard Self.allowsSilentDownload(conditions), !inFlight else { return }
        for region in downloaded {
            guard let listed = regions.first(where: { $0.id == region.id }), state(of: region.id) == .updateAvailable
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
    /// temporary place before the handler returns.
    nonisolated static let urlSessionTransfer: Transfer = { request, onProgress in
        let box = TransferBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let task = PilotMapConfig.session.downloadTask(with: request) { location, response, error in
                    box.observation?.invalidate()
                    if let error { continuation.resume(throwing: error); return }
                    guard let http = response as? HTTPURLResponse, let location else {
                        continuation.resume(throwing: URLError(.badServerResponse)); return
                    }
                    guard http.statusCode == 200 else { continuation.resume(throwing: Failure.http(http.statusCode)); return }
                    let kept = FileManager.default.temporaryDirectory
                        .appendingPathComponent("pilotmap-\(UUID().uuidString).pmtiles")
                    do {
                        try FileManager.default.moveItem(at: location, to: kept)
                        continuation.resume(returning: kept)
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
