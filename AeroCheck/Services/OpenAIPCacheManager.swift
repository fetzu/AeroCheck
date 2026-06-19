import Foundation
import MapKit

/// Manager for offline caching of OpenAIP map tiles
/// Handles downloading, storing, and serving cached tiles for offline use
/// Follows the same pattern as OfflineMapManager for Swiss tiles
@MainActor
class OpenAIPCacheManager: ObservableObject {
    // MARK: - Published Properties

    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadedTileCount: Int = 0
    @Published var totalTileCount: Int = 0
    @Published var downloadError: String?
    @Published var isCacheAvailable: Bool = false
    @Published var cacheDate: Date?
    @Published var cacheSizeBytes: Int64 = 0
    @Published var cachedCountries: [String] = []
    @Published var downloadStartTime: Date?
    @Published var estimatedTimeRemaining: TimeInterval?

    // MARK: - Private Properties

    private let fileManager = FileManager.default

    /// Base directory for OpenAIP tile cache
    private var cacheDirectory: URL {
        DataPersistenceManager.shared.mapTilesDirectory
            .appendingPathComponent("OpenAIP", isDirectory: true)
    }

    /// UserDefaults keys for cache metadata
    private let cacheDateKey = "openAIPTileCacheDate"
    private let cachedCountriesKey = "openAIPCachedCountries"

    // MARK: - Initialization

    init() {
        loadCacheStatus()
    }

    // MARK: - Cache Status

    private func loadCacheStatus() {
        cacheDate = UserDefaults.standard.object(forKey: cacheDateKey) as? Date
        cachedCountries = UserDefaults.standard.stringArray(forKey: cachedCountriesKey) ?? []
        isCacheAvailable = cacheDate != nil && !cachedCountries.isEmpty
        Task {
            await calculateCacheSize()
        }
    }

    /// Calculate total cache size on disk
    private func calculateCacheSize() async {
        let directory = cacheDirectory
        guard fileManager.fileExists(atPath: directory.path) else {
            cacheSizeBytes = 0
            return
        }

        let totalSize = await Task.detached { [fileManager] () -> Int64 in
            var size: Int64 = 0
            if let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) {
                let fileURLs = enumerator.allObjects.compactMap { $0 as? URL }
                for fileURL in fileURLs {
                    if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        size += Int64(fileSize)
                    }
                }
            }
            return size
        }.value

        cacheSizeBytes = totalSize
    }

    /// Formatted cache size string
    var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: cacheSizeBytes, countStyle: .file)
    }

    /// Formatted cache date string
    var formattedCacheDate: String {
        guard let date = cacheDate else { return "-" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Tile Lookup (called from OpenAIPTileOverlay)

    /// Look up a cached tile file on disk
    /// nonisolated for thread safety (called from MKTileOverlay background threads)
    nonisolated func cachedTileURL(z: Int, x: Int, y: Int) -> URL? {
        // Compute path directly to avoid referencing MainActor-isolated properties
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let tilePath = documentsPath
            .appendingPathComponent("MapData", isDirectory: true)
            .appendingPathComponent("OpenAIP", isDirectory: true)
            .appendingPathComponent("\(z)", isDirectory: true)
            .appendingPathComponent("\(x)", isDirectory: true)
            .appendingPathComponent("\(y).png")

        guard FileManager.default.fileExists(atPath: tilePath.path) else { return nil }
        return tilePath
    }

    // MARK: - Download

    /// Download tiles for selected countries
    /// - Parameter countries: Array of ISO alpha-2 country codes
    func downloadTiles(for countries: [String]) async {
        guard !isDownloading else { return }

        isDownloading = true
        downloadError = nil
        downloadProgress = 0
        downloadedTileCount = 0
        downloadStartTime = Date()

        // Calculate all tiles needed for the combined bounding box of all countries
        let allTiles = calculateTilesForCountries(countries)
        totalTileCount = allTiles.count

        guard totalTileCount > 0 else {
            downloadError = "No tiles to download for selected countries"
            isDownloading = false
            return
        }

        // Create cache directory
        do {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            downloadError = "Failed to create cache directory: \(error.localizedDescription)"
            isDownloading = false
            return
        }

        // Download in batches using TaskGroup
        let batchSize = 50
        let maxConcurrent = 6
        var downloaded = 0
        var failed = 0

        let session = URLSession(configuration: {
            let config = URLSessionConfiguration.default
            config.httpMaximumConnectionsPerHost = maxConcurrent
            config.timeoutIntervalForRequest = 15
            return config
        }())

        for batchStart in stride(from: 0, to: allTiles.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, allTiles.count)
            let batch = Array(allTiles[batchStart..<batchEnd])

            await withTaskGroup(of: Bool.self) { group in
                for tile in batch {
                    group.addTask { [weak self] in
                        guard let self else { return false }
                        return await self.downloadAndSaveTile(z: tile.z, x: tile.x, y: tile.y, session: session)
                    }
                }

                for await success in group {
                    if success {
                        downloaded += 1
                    } else {
                        failed += 1
                    }

                    // Update progress on main actor
                    let totalProcessed = downloaded + failed
                    downloadedTileCount = downloaded
                    downloadProgress = Double(totalProcessed) / Double(totalTileCount)

                    // Estimate remaining time
                    if let startTime = downloadStartTime, totalProcessed > 10 {
                        let elapsed = Date().timeIntervalSince(startTime)
                        let rate = Double(totalProcessed) / elapsed
                        let remaining = Double(totalTileCount - totalProcessed) / rate
                        estimatedTimeRemaining = remaining
                    }
                }
            }

            // Check for cancellation
            if Task.isCancelled { break }
        }

        // Save cache metadata
        if downloaded > 0 {
            cacheDate = Date()
            UserDefaults.standard.set(cacheDate, forKey: cacheDateKey)
            UserDefaults.standard.set(countries, forKey: cachedCountriesKey)
            cachedCountries = countries
            isCacheAvailable = true
        }

        if failed > 0 {
            downloadError = "\(failed) tiles failed to download (out of \(totalTileCount))"
        }

        isDownloading = false
        downloadStartTime = nil
        estimatedTimeRemaining = nil

        await calculateCacheSize()
    }

    /// Download a single tile and save to disk
    private nonisolated func downloadAndSaveTile(z: Int, x: Int, y: Int, session: URLSession) async -> Bool {
        let subdomain = OpenAIPConfig.tileSubdomains[abs(x + y) % OpenAIPConfig.tileSubdomains.count]
        guard let url = OpenAIPConfig.tileURL(subdomain: subdomain, z: z, x: x, y: y) else { return false }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else { return false }

            // HTTP 204 = no content for this tile (valid, skip)
            if httpResponse.statusCode == 204 { return true }
            guard httpResponse.statusCode == 200 else { return false }

            // Save to disk - compute path directly to avoid MainActor isolation
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let directory = documentsPath
                .appendingPathComponent("MapData", isDirectory: true)
                .appendingPathComponent("OpenAIP", isDirectory: true)
                .appendingPathComponent("\(z)", isDirectory: true)
                .appendingPathComponent("\(x)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let filePath = directory.appendingPathComponent("\(y).png")
            try data.write(to: filePath)
            return true
        } catch {
            return false
        }
    }

    /// Calculate all tile coordinates needed for given countries at aviation zoom levels
    private func calculateTilesForCountries(_ countries: [String]) -> [(z: Int, x: Int, y: Int)] {
        // Merge bounding boxes for all countries
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0

        for country in countries {
            guard let bounds = OpenAIPConfig.countryBounds[country] else { continue }
            minLat = min(minLat, bounds.minLat)
            maxLat = max(maxLat, bounds.maxLat)
            minLon = min(minLon, bounds.minLon)
            maxLon = max(maxLon, bounds.maxLon)
        }

        guard minLat < maxLat else { return [] }

        var tiles: [(z: Int, x: Int, y: Int)] = []

        // Download zoom levels 7-12 (aviation relevant: overview to detailed approach)
        // Skip very high zoom levels (13-14) to keep download size reasonable
        for z in 7...12 {
            let minX = lonToTileX(lon: minLon, zoom: z)
            let maxX = lonToTileX(lon: maxLon, zoom: z)
            let minY = latToTileY(lat: maxLat, zoom: z) // Note: Y is inverted
            let maxY = latToTileY(lat: minLat, zoom: z)

            for x in minX...maxX {
                for y in minY...maxY {
                    tiles.append((z: z, x: x, y: y))
                }
            }
        }

        return tiles
    }

    // MARK: - Coordinate Conversion

    /// Convert longitude to tile X coordinate (Web Mercator)
    private func lonToTileX(lon: Double, zoom: Int) -> Int {
        Int(floor((lon + 180.0) / 360.0 * pow(2.0, Double(zoom))))
    }

    /// Convert latitude to tile Y coordinate (Web Mercator)
    private func latToTileY(lat: Double, zoom: Int) -> Int {
        let latRad = lat * .pi / 180.0
        let n = pow(2.0, Double(zoom))
        return Int(floor((1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / .pi) / 2.0 * n))
    }

    // MARK: - Cache Management

    /// Delete all cached OpenAIP tiles
    func deleteCache() {
        do {
            if fileManager.fileExists(atPath: cacheDirectory.path) {
                try fileManager.removeItem(at: cacheDirectory)
            }
            cacheDate = nil
            cachedCountries = []
            isCacheAvailable = false
            cacheSizeBytes = 0
            UserDefaults.standard.removeObject(forKey: cacheDateKey)
            UserDefaults.standard.removeObject(forKey: cachedCountriesKey)
        } catch {
            downloadError = "Failed to delete cache: \(error.localizedDescription)"
        }
    }

    /// Estimated download size for given countries (rough approximation)
    func estimatedDownloadSize(for countries: [String]) -> String {
        let tiles = calculateTilesForCountries(countries)
        // Average tile size ~5.5KB for OpenAIP raster tiles (sparse aviation data)
        let estimatedBytes = Int64(tiles.count) * 5_500
        return ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file)
    }

    /// Number of tiles for given countries
    func tileCount(for countries: [String]) -> Int {
        calculateTilesForCountries(countries).count
    }
}
