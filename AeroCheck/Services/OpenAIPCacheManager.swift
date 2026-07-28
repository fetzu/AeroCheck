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
            DataPersistenceManager.excludeFromBackup(cacheDirectory) // SEC-C28
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

        // APP-10: reclaim tiles from any PREVIOUS selection that the new one no longer covers.
        // Runs after `isDownloading` clears (the prune refuses to run mid-download) and after the
        // new tiles have landed, so a shrinking selection never deletes something it still wants.
        await pruneTilesOutside(countries: countries)

        await calculateCacheSize()
    }

    /// Download a single tile and save to disk
    private nonisolated func downloadAndSaveTile(z: Int, x: Int, y: Int, session: URLSession) async -> Bool {
        let subdomain = OpenAIPConfig.tileSubdomains[abs(x + y) % OpenAIPConfig.tileSubdomains.count]
        // Key in a header, not the URL (SA-11).
        guard let request = OpenAIPConfig.tileRequest(subdomain: subdomain, z: z, x: x, y: y) else { return false }

        do {
            let (data, response) = try await session.data(for: request)
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

    /// Deletes cached tiles that fall outside the current country selection. (APP-10)
    ///
    /// This layer was the only one of six with **no eviction at all**. The five sibling per-country
    /// GeoJSON layers each prune on reselect; tiles never did, so deselecting a country left its
    /// tiles on disk permanently — they are keyed `{z}/{x}/{y}.png` with no country namespace, so
    /// nothing outside the new bounding box is ever revisited, and the cache only ever grew. A pilot
    /// who sampled several countries kept every one of them forever, with the Settings size readout
    /// as the only clue and a full delete as the only remedy.
    ///
    /// Reconciles **disk against the currently-desired set** rather than diffing old and new
    /// selections. Countries merge into a single combined bounding box, so "the tiles for country X"
    /// is not a separable set — but "every tile the current selection wants" is exact, which makes
    /// this correct regardless of how the selection changed or how many past selections accumulated.
    ///
    /// - Returns: the number of tile files deleted.
    @discardableResult
    func pruneTilesOutside(countries: [String]) async -> Int {
        // An empty selection is not a licence to wipe the cache: it also occurs transiently while
        // the Settings list is being edited. Clearing everything is `deleteCache()`, explicitly.
        guard !countries.isEmpty, !isDownloading else { return 0 }

        let desired = Set(calculateTilesForCountries(countries).map { "\($0.z)/\($0.x)/\($0.y)" })
        guard !desired.isEmpty else { return 0 }

        let directory = cacheDirectory
        let deleted = await Task.detached(priority: .utility) { () -> Int in
            // The walk lives in a SYNCHRONOUS function on purpose. `FileManager.enumerator` returns
            // an `NSEnumerator`, whose `makeIterator()` is unavailable from an asynchronous context
            // — a warning under the Swift 5 language mode this target uses, and a hard error under
            // Swift 6. Xcode Cloud already fails the build on it. Calling a sync function from the
            // detached task keeps the iteration out of async context entirely.
            Self.removeTiles(under: directory, keeping: desired)
        }.value

        if deleted > 0 {
            AppLog.general.debugLine("Pruned \(deleted) OpenAIP tile(s) outside the current country selection")
            await calculateCacheSize()
        }
        return deleted
    }

    /// Deletes every `.png` under `directory` whose `{z}/{x}/{y}` key is not in `keeping`.
    ///
    /// `nonisolated` and synchronous so the `NSEnumerator` is never iterated from an async context
    /// (see the call site). Kept lazy rather than materialising `walker.allObjects`: a tile cache
    /// spanning several countries holds tens of thousands of files, and the enumerator streams them
    /// instead of building one large array.
    ///
    /// - Returns: the number of files deleted.
    nonisolated static func removeTiles(under directory: URL, keeping: Set<String>) -> Int {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for case let url as URL in walker where url.pathExtension == "png" {
            // .../OpenAIP/{z}/{x}/{y}.png — take the key back out of the path itself, so this
            // stays correct if the cache root ever moves.
            let parts = url.pathComponents
            guard parts.count >= 3 else { continue }
            let z = parts[parts.count - 3]
            let x = parts[parts.count - 2]
            let y = url.deletingPathExtension().lastPathComponent
            if !keeping.contains("\(z)/\(x)/\(y)") {
                try? fm.removeItem(at: url)
                removed += 1
            }
        }
        return removed
    }

    #if DEBUG
    /// Test seam: the tile projection for a country set, so a test can assert against the real
    /// projection instead of hardcoding tile coordinates that would drift from it.
    func tilesForCountriesForTesting(_ countries: [String]) -> [(z: Int, x: Int, y: Int)] {
        calculateTilesForCountries(countries)
    }
    #endif

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
