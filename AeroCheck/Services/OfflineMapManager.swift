import Foundation
import MapKit

/// Manager for offline ICAO chart tile caching
/// Handles downloading, storing, and serving cached tiles for offline use
@MainActor
class OfflineMapManager: ObservableObject {
    // MARK: - Published Properties

    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadedTileCount: Int = 0
    @Published var totalTileCount: Int = 0
    @Published var downloadError: String?
    @Published var isCacheAvailable: Bool = false
    @Published var cacheDate: Date?
    @Published var cacheSizeBytes: Int64 = 0

    // MARK: - Constants

    /// ICAO layer identifier for SwissTopo WMTS
    private let icaoLayerIdentifier = "ch.bazl.luftfahrtkarten-icao"

    /// Switzerland bounding box (approximate)
    private let switzerlandBounds = (
        minLat: 45.82,  // Southern border
        maxLat: 47.81,  // Northern border
        minLon: 5.96,   // Western border
        maxLon: 10.49   // Eastern border
    )

    /// Zoom levels to cache for ICAO chart (7-11)
    private let minZoom = 7
    private let maxZoom = 11

    /// Base URL for SwissTopo WMTS
    private let baseURL = "https://wmts.geo.admin.ch/1.0.0"

    /// UserDefaults keys
    private let cacheDateKey = "offlineMapCacheDate"
    private let lastUpdateCheckKey = "offlineMapLastUpdateCheck"
    private let updateReminderDismissedKey = "offlineMapUpdateReminderDismissed"

    // MARK: - Computed Properties

    /// Directory for storing cached tiles
    var cacheDirectory: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("AeroCheck/OfflineMaps/ICAO", isDirectory: true)
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

    /// Cache version string (based on download date)
    var cacheVersion: String {
        guard let date = cacheDate else { return "N/A" }
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
        let cacheYear = calendar.component(.year, from: cacheDate)

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

    /// Download all ICAO chart tiles for offline use
    func downloadICAOChart() async {
        isDownloading = true
        downloadProgress = 0.0
        downloadedTileCount = 0
        downloadError = nil

        // Calculate total tiles to download
        let tiles = calculateTilesToDownload()
        totalTileCount = tiles.count

        // Create cache directory if needed
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            downloadError = "Failed to create cache directory: \(error.localizedDescription)"
            isDownloading = false
            return
        }

        // Download tiles
        let session = URLSession.shared
        var successCount = 0
        var failCount = 0

        // Download in batches to avoid overwhelming the network
        let batchSize = 20
        for batchStart in stride(from: 0, to: tiles.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, tiles.count)
            let batch = Array(tiles[batchStart..<batchEnd])

            await withTaskGroup(of: Bool.self) { group in
                for tile in batch {
                    group.addTask { [weak self] in
                        guard let self = self else { return false }
                        return await self.downloadTile(tile: tile, session: session)
                    }
                }

                for await success in group {
                    if success {
                        successCount += 1
                    } else {
                        failCount += 1
                    }
                    await MainActor.run {
                        downloadedTileCount = successCount + failCount
                        downloadProgress = Double(downloadedTileCount) / Double(totalTileCount)
                    }
                }
            }

            // Check for cancellation
            if Task.isCancelled {
                downloadError = "Download cancelled"
                isDownloading = false
                return
            }
        }

        // Save metadata
        if failCount == 0 {
            cacheDate = Date()
            UserDefaults.standard.set(cacheDate, forKey: cacheDateKey)
            updateCacheSize()
            isCacheAvailable = true
            updateReminderDismissed = false // Reset reminder for next year
        } else if successCount > 0 {
            downloadError = "Completed with \(failCount) failed tiles"
            cacheDate = Date()
            UserDefaults.standard.set(cacheDate, forKey: cacheDateKey)
            updateCacheSize()
            isCacheAvailable = true
        } else {
            downloadError = "Download failed"
        }

        isDownloading = false
    }

    /// Delete cached tiles
    func deleteCache() {
        do {
            if FileManager.default.fileExists(atPath: cacheDirectory.path) {
                try FileManager.default.removeItem(at: cacheDirectory)
            }
            cacheDate = nil
            cacheSizeBytes = 0
            isCacheAvailable = false
            UserDefaults.standard.removeObject(forKey: cacheDateKey)
        } catch {
            downloadError = "Failed to delete cache: \(error.localizedDescription)"
        }
    }

    /// Get cached tile URL if available
    /// This method is nonisolated because it only performs file system operations
    /// and needs to be called from the tile overlay's url(forTilePath:) method
    nonisolated func cachedTileURL(z: Int, x: Int, y: Int) -> URL? {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let cacheDir = documentsPath.appendingPathComponent("AeroCheck/OfflineMaps/ICAO", isDirectory: true)
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
        cacheDate = UserDefaults.standard.object(forKey: cacheDateKey) as? Date
        isCacheAvailable = FileManager.default.fileExists(atPath: cacheDirectory.path) && cacheDate != nil

        if isCacheAvailable {
            updateCacheSize()
        }
    }

    private func updateCacheSize() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let size = self.calculateDirectorySize(url: self.cacheDirectory)
            DispatchQueue.main.async {
                self.cacheSizeBytes = size
            }
        }
    }

    private func calculateDirectorySize(url: URL) -> Int64 {
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

    private func calculateTilesToDownload() -> [(z: Int, x: Int, y: Int)] {
        var tiles: [(z: Int, x: Int, y: Int)] = []

        for z in minZoom...maxZoom {
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

    private func downloadTile(tile: (z: Int, x: Int, y: Int), session: URLSession) async -> Bool {
        let urlString = "\(baseURL)/\(icaoLayerIdentifier)/default/current/3857/\(tile.z)/\(tile.x)/\(tile.y).png"

        guard let url = URL(string: urlString) else { return false }

        do {
            let (data, response) = try await session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false
            }

            // Save tile to disk
            let tilePath = cacheDirectory
                .appendingPathComponent("\(tile.z)", isDirectory: true)
                .appendingPathComponent("\(tile.x)", isDirectory: true)

            try FileManager.default.createDirectory(at: tilePath, withIntermediateDirectories: true)

            let fileURL = tilePath.appendingPathComponent("\(tile.y).png")
            try data.write(to: fileURL)

            return true
        } catch {
            return false
        }
    }
}
