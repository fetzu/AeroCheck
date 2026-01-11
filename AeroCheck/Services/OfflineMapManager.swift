import Foundation
import MapKit

/// Layer types that can be cached
enum CacheableLayer: String, CaseIterable {
    case icao = "ICAO"
    case segelflug = "Segelflug"

    var swisstopoIdentifier: String {
        switch self {
        case .icao: return "ch.bazl.luftfahrtkarten-icao"
        case .segelflug: return "ch.bazl.segelflugkarte"
        }
    }

    var minZoom: Int {
        switch self {
        case .icao: return 7
        case .segelflug: return 11
        }
    }

    var maxZoom: Int {
        switch self {
        case .icao: return 11
        case .segelflug: return 12  // Swisstopo only provides Segelflugkarte up to zoom 12
        }
    }

    var displayName: String {
        switch self {
        case .icao: return "ICAO Chart"
        case .segelflug: return "Segelflugkarte"
        }
    }
}

/// Cache options for offline maps
enum CacheOption: String, CaseIterable, Identifiable {
    case icaoOnly = "icaoOnly"
    case icaoAndSegelflug = "icaoAndSegelflug"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .icaoOnly: return "ICAO Chart only"
        case .icaoAndSegelflug: return "ICAO + Segelflugkarte"
        }
    }

    var layers: [CacheableLayer] {
        switch self {
        case .icaoOnly: return [.icao]
        case .icaoAndSegelflug: return [.icao, .segelflug]
        }
    }
}

/// Manager for offline ICAO/Segelflug chart tile caching
/// Handles downloading, storing, and serving cached tiles for offline use
/// Map cache is stored locally in "On this iPhone/AéroCheck/MapData"
@MainActor
class OfflineMapManager: ObservableObject {
    // MARK: - Published Properties

    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadedTileCount: Int = 0
    @Published var totalTileCount: Int = 0
    @Published var downloadError: String?
    @Published var isCacheAvailable: Bool = false
    @Published var isSegelflugCacheAvailable: Bool = false
    @Published var cacheDate: Date?
    @Published var segelflugCacheDate: Date?
    @Published var cacheSizeBytes: Int64 = 0
    @Published var currentDownloadingLayer: CacheableLayer?
    @Published var downloadStartTime: Date?
    @Published var estimatedTimeRemaining: TimeInterval?

    // MARK: - Constants

    /// Switzerland bounding box (approximate)
    private let switzerlandBounds = (
        minLat: 45.82,  // Southern border
        maxLat: 47.81,  // Northern border
        minLon: 5.96,   // Western border
        maxLon: 10.49   // Eastern border
    )

    /// Base URL for swisstopo WMTS
    private let baseURL = "https://wmts.geo.admin.ch/1.0.0"

    /// UserDefaults keys
    private let icaoCacheDateKey = "offlineMapCacheDate"
    private let segelflugCacheDateKey = "offlineMapSegelflugCacheDate"
    private let updateReminderDismissedKey = "offlineMapUpdateReminderDismissed"

    // MARK: - Computed Properties

    /// Base directory for storing cached tiles (local storage only)
    private var baseCacheDirectory: URL {
        return DataPersistenceManager.shared.mapTilesDirectory
    }

    /// Directory for ICAO cache
    var cacheDirectory: URL {
        return baseCacheDirectory.appendingPathComponent("ICAO", isDirectory: true)
    }

    /// Directory for Segelflug cache
    var segelflugCacheDirectory: URL {
        return baseCacheDirectory.appendingPathComponent("Segelflug", isDirectory: true)
    }

    /// Get cache directory for a specific layer
    func cacheDirectory(for layer: CacheableLayer) -> URL {
        switch layer {
        case .icao: return cacheDirectory
        case .segelflug: return segelflugCacheDirectory
        }
    }

    /// Formatted cache size string
    var formattedCacheSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: cacheSizeBytes)
    }

    /// Formatted cache date string
    var formattedCacheDate: String {
        guard let date = cacheDate else { return "Not downloaded" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Formatted Segelflug cache date string
    var formattedSegelflugCacheDate: String {
        guard let date = segelflugCacheDate else { return "Not downloaded" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Cache version string (based on download date)
    var cacheVersion: String {
        guard let date = cacheDate else { return "N/A" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM"
        return formatter.string(from: date)
    }

    /// Segelflug cache version string
    var segelflugCacheVersion: String {
        guard let date = segelflugCacheDate else { return "N/A" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM"
        return formatter.string(from: date)
    }

    /// Check if cache needs update (after April 1st each year)
    var needsYearlyUpdate: Bool {
        guard let cacheDate = cacheDate else { return false }

        let calendar = Calendar.current
        let now = Date()
        let currentYear = calendar.component(.year, from: now)

        // Get April 1st of current year
        var aprilComponents = DateComponents()
        aprilComponents.year = currentYear
        aprilComponents.month = 4
        aprilComponents.day = 1

        guard let aprilFirst = calendar.date(from: aprilComponents) else { return false }

        // Need update if:
        // 1. We're past April 1st of this year
        // 2. Cache was downloaded before April 1st of this year
        return now >= aprilFirst && cacheDate < aprilFirst
    }

    /// Check if update reminder was dismissed this year
    var updateReminderDismissed: Bool {
        get {
            guard let dismissedDate = UserDefaults.standard.object(forKey: updateReminderDismissedKey) as? Date else {
                return false
            }
            let calendar = Calendar.current
            let currentYear = calendar.component(.year, from: Date())
            let dismissedYear = calendar.component(.year, from: dismissedDate)
            return currentYear == dismissedYear
        }
        set {
            if newValue {
                UserDefaults.standard.set(Date(), forKey: updateReminderDismissedKey)
            } else {
                UserDefaults.standard.removeObject(forKey: updateReminderDismissedKey)
            }
        }
    }

    /// Check if should show update reminder
    var shouldShowUpdateReminder: Bool {
        return needsYearlyUpdate && !updateReminderDismissed
    }

    // MARK: - Initialization

    init() {
        loadCacheMetadata()
    }

    // MARK: - Public Methods

    /// Download charts for offline use with the specified cache option
    func downloadCharts(option: CacheOption) async {
        isDownloading = true
        downloadProgress = 0.0
        downloadedTileCount = 0
        downloadError = nil
        downloadStartTime = Date()
        estimatedTimeRemaining = nil

        // Calculate total tiles for all layers
        var allTiles: [(layer: CacheableLayer, z: Int, x: Int, y: Int)] = []
        for layer in option.layers {
            let tiles = calculateTilesToDownload(for: layer)
            allTiles.append(contentsOf: tiles.map { (layer, $0.z, $0.x, $0.y) })
        }
        totalTileCount = allTiles.count

        // Create cache directories
        for layer in option.layers {
            do {
                try FileManager.default.createDirectory(at: cacheDirectory(for: layer), withIntermediateDirectories: true)
            } catch {
                downloadError = "Failed to create cache directory: \(error.localizedDescription)"
                isDownloading = false
                downloadStartTime = nil
                return
            }
        }

        // Create a custom URLSession with optimized configuration for bulk downloads
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 6  // Increase concurrent connections
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.urlCache = nil  // Disable URL cache since we're caching to disk
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)

        var successCount = 0
        var failCount = 0
        var layerSuccessCounts: [CacheableLayer: Int] = [:]
        var layerFailCounts: [CacheableLayer: Int] = [:]

        for layer in option.layers {
            layerSuccessCounts[layer] = 0
            layerFailCounts[layer] = 0
        }

        // Download in batches - larger batches for better throughput
        let batchSize = 50  // Increased from 20 for better parallelism
        for batchStart in stride(from: 0, to: allTiles.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, allTiles.count)
            let batch = Array(allTiles[batchStart..<batchEnd])

            // Update current layer being downloaded
            if let firstTile = batch.first {
                currentDownloadingLayer = firstTile.layer
            }

            await withTaskGroup(of: (CacheableLayer, Bool).self) { group in
                for tile in batch {
                    group.addTask { [weak self] in
                        guard let self = self else { return (tile.layer, false) }
                        let success = await self.downloadTile(
                            layer: tile.layer,
                            z: tile.z,
                            x: tile.x,
                            y: tile.y,
                            session: session
                        )
                        return (tile.layer, success)
                    }
                }

                for await (layer, success) in group {
                    if success {
                        successCount += 1
                        layerSuccessCounts[layer, default: 0] += 1
                    } else {
                        failCount += 1
                        layerFailCounts[layer, default: 0] += 1
                    }
                    await MainActor.run {
                        downloadedTileCount = successCount + failCount
                        downloadProgress = Double(downloadedTileCount) / Double(totalTileCount)

                        // Calculate estimated time remaining
                        if let startTime = downloadStartTime, downloadedTileCount > 0 {
                            let elapsed = Date().timeIntervalSince(startTime)
                            let tilesPerSecond = Double(downloadedTileCount) / elapsed
                            if tilesPerSecond > 0 {
                                let remainingTiles = totalTileCount - downloadedTileCount
                                estimatedTimeRemaining = Double(remainingTiles) / tilesPerSecond
                            }
                        }
                    }
                }
            }

            // Check for cancellation
            if Task.isCancelled {
                downloadError = "Download cancelled"
                isDownloading = false
                currentDownloadingLayer = nil
                downloadStartTime = nil
                estimatedTimeRemaining = nil
                return
            }
        }

        // Save metadata for each layer
        let now = Date()
        for layer in option.layers {
            let layerSuccess = layerSuccessCounts[layer, default: 0]
            let layerFail = layerFailCounts[layer, default: 0]

            if layerFail == 0 || layerSuccess > 0 {
                switch layer {
                case .icao:
                    cacheDate = now
                    UserDefaults.standard.set(cacheDate, forKey: icaoCacheDateKey)
                    isCacheAvailable = true
                case .segelflug:
                    segelflugCacheDate = now
                    UserDefaults.standard.set(segelflugCacheDate, forKey: segelflugCacheDateKey)
                    isSegelflugCacheAvailable = true
                }
            }
        }

        updateCacheSize()

        if failCount == 0 {
            updateReminderDismissed = false // Reset reminder for next year
            downloadError = nil
        } else if successCount > 0 {
            // Only report as error if failure rate is significant (> 1%)
            let failureRate = Double(failCount) / Double(totalTileCount)
            if failureRate > 0.01 {
                downloadError = "Completed with \(failCount) failed tiles (\(Int(failureRate * 100))%)"
            } else {
                // Minor failures are normal (edge tiles, transient network issues)
                downloadError = nil
            }
            updateReminderDismissed = false // Reset reminder for next year
        } else {
            downloadError = "Download failed"
        }

        isDownloading = false
        currentDownloadingLayer = nil
    }

    /// Download all ICAO chart tiles for offline use (legacy compatibility)
    func downloadICAOChart() async {
        await downloadCharts(option: .icaoOnly)
    }

    /// Delete all cached tiles
    func deleteCache() {
        do {
            // Delete ICAO cache
            if FileManager.default.fileExists(atPath: cacheDirectory.path) {
                try FileManager.default.removeItem(at: cacheDirectory)
            }
            // Delete Segelflug cache
            if FileManager.default.fileExists(atPath: segelflugCacheDirectory.path) {
                try FileManager.default.removeItem(at: segelflugCacheDirectory)
            }

            cacheDate = nil
            segelflugCacheDate = nil
            cacheSizeBytes = 0
            isCacheAvailable = false
            isSegelflugCacheAvailable = false
            UserDefaults.standard.removeObject(forKey: icaoCacheDateKey)
            UserDefaults.standard.removeObject(forKey: segelflugCacheDateKey)
        } catch {
            downloadError = "Failed to delete cache: \(error.localizedDescription)"
        }
    }

    /// Delete cache for a specific layer
    func deleteCache(for layer: CacheableLayer) {
        do {
            let dir = cacheDirectory(for: layer)
            if FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.removeItem(at: dir)
            }

            switch layer {
            case .icao:
                cacheDate = nil
                isCacheAvailable = false
                UserDefaults.standard.removeObject(forKey: icaoCacheDateKey)
            case .segelflug:
                segelflugCacheDate = nil
                isSegelflugCacheAvailable = false
                UserDefaults.standard.removeObject(forKey: segelflugCacheDateKey)
            }

            updateCacheSize()
        } catch {
            downloadError = "Failed to delete \(layer.displayName) cache: \(error.localizedDescription)"
        }
    }

    /// Get cached tile URL if available (legacy method for backwards compatibility)
    nonisolated func cachedTileURL(z: Int, x: Int, y: Int) -> URL? {
        return cachedTileURL(z: z, x: x, y: y, layer: .icao)
    }

    /// Get cached tile URL if available for a specific layer
    /// This method is nonisolated because it only performs file system operations
    /// and needs to be called from the tile overlay's loadTile method
    nonisolated func cachedTileURL(z: Int, x: Int, y: Int, layer: CacheableLayer) -> URL? {
        // Use the local Documents directory for map cache (On this iPhone/AéroCheck/MapData)
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let appFolder = "AéroCheck"
        let mapDataFolder = "MapData"
        let layerDir: String
        switch layer {
        case .icao: layerDir = "ICAO"
        case .segelflug: layerDir = "Segelflug"
        }
        let cacheDir = documentsPath
            .appendingPathComponent(appFolder, isDirectory: true)
            .appendingPathComponent(mapDataFolder, isDirectory: true)
            .appendingPathComponent(layerDir, isDirectory: true)
        let tilePath = cacheDir.appendingPathComponent("\(z)/\(x)/\(y).png")
        if FileManager.default.fileExists(atPath: tilePath.path) {
            return tilePath
        }
        return nil
    }

    /// Mark "Remind me later" for update
    func remindLater() {
        // Don't dismiss, just close - will show again next app launch
    }

    /// Ignore update for this year
    func ignoreUpdate() {
        updateReminderDismissed = true
    }

    // MARK: - Private Methods

    private func loadCacheMetadata() {
        // Load ICAO cache metadata
        cacheDate = UserDefaults.standard.object(forKey: icaoCacheDateKey) as? Date
        isCacheAvailable = FileManager.default.fileExists(atPath: cacheDirectory.path) && cacheDate != nil

        // Load Segelflug cache metadata
        segelflugCacheDate = UserDefaults.standard.object(forKey: segelflugCacheDateKey) as? Date
        isSegelflugCacheAvailable = FileManager.default.fileExists(atPath: segelflugCacheDirectory.path) && segelflugCacheDate != nil

        if isCacheAvailable || isSegelflugCacheAvailable {
            updateCacheSize()
        }
    }

    private func updateCacheSize() {
        let icaoDir = self.cacheDirectory
        let segelflugDir = self.segelflugCacheDirectory
        // Capture self weakly to avoid retain cycle in detached task
        Task.detached(priority: .utility) { [weak self, icaoDir, segelflugDir] in
            guard let self = self else { return }
            let icaoSize = self.calculateDirectorySize(url: icaoDir)
            let segelflugSize = self.calculateDirectorySize(url: segelflugDir)
            await MainActor.run { [weak self] in
                self?.cacheSizeBytes = icaoSize + segelflugSize
            }
        }
    }

    private nonisolated func calculateDirectorySize(url: URL) -> Int64 {
        let fileManager = FileManager.default
        var size: Int64 = 0

        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [], errorHandler: nil) else {
            return 0
        }

        for case let fileURL as URL in enumerator {
            do {
                let attributes = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                size += Int64(attributes.fileSize ?? 0)
            } catch {
                continue
            }
        }

        return size
    }

    private func calculateTilesToDownload(for layer: CacheableLayer) -> [(z: Int, x: Int, y: Int)] {
        var tiles: [(z: Int, x: Int, y: Int)] = []

        for z in layer.minZoom...layer.maxZoom {
            let tileRange = calculateTileRange(zoom: z)
            for x in tileRange.minX...tileRange.maxX {
                for y in tileRange.minY...tileRange.maxY {
                    tiles.append((z: z, x: x, y: y))
                }
            }
        }

        return tiles
    }

    private func calculateTileRange(zoom: Int) -> (minX: Int, maxX: Int, minY: Int, maxY: Int) {
        // Convert lat/lon to tile coordinates
        // Using Web Mercator (EPSG:3857) tile scheme
        let n = pow(2.0, Double(zoom))

        let minX = Int(floor((switzerlandBounds.minLon + 180.0) / 360.0 * n))
        let maxX = Int(floor((switzerlandBounds.maxLon + 180.0) / 360.0 * n))

        // Note: Y is inverted in TMS
        let minLatRad = switzerlandBounds.minLat * .pi / 180.0
        let maxLatRad = switzerlandBounds.maxLat * .pi / 180.0

        let maxY = Int(floor((1.0 - log(tan(minLatRad) + 1.0/cos(minLatRad)) / .pi) / 2.0 * n))
        let minY = Int(floor((1.0 - log(tan(maxLatRad) + 1.0/cos(maxLatRad)) / .pi) / 2.0 * n))

        return (minX: minX, maxX: maxX, minY: minY, maxY: maxY)
    }

    private func downloadTile(layer: CacheableLayer, z: Int, x: Int, y: Int, session: URLSession) async -> Bool {
        let urlString = "\(baseURL)/\(layer.swisstopoIdentifier)/default/current/3857/\(z)/\(x)/\(y).png"

        guard let url = URL(string: urlString) else { return false }

        do {
            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false
            }

            // Save tile to disk
            let tilePath = cacheDirectory(for: layer)
                .appendingPathComponent("\(z)", isDirectory: true)
                .appendingPathComponent("\(x)", isDirectory: true)

            try FileManager.default.createDirectory(at: tilePath, withIntermediateDirectories: true)

            let fileURL = tilePath.appendingPathComponent("\(y).png")
            try data.write(to: fileURL)

            return true
        } catch {
            return false
        }
    }
}
