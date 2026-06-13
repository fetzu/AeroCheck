import Foundation

/// Narrow seam over the subscription state `AircraftDataService` needs, so its premium-gating logic
/// can be exercised with a fake instead of a live `SubscriptionManager` + StoreKit. (ARCH-12)
@MainActor
protocol SubscriptionGating {
    func getUserID() async -> String?
    func shouldAllowPremiumAccess() -> Bool
    /// True only when premium access is DEFINITIVELY denied (status resolved, not subscribed, no
    /// valid grace window). Used for the cache-DESTROYING decision so a transient cold-launch state
    /// can't wipe the offline checklist. (PR-05)
    func isPremiumAccessDefinitivelyDenied() -> Bool
}

extension SubscriptionGating {
    /// Conservative default for conformers without richer state (e.g. test fakes): defer to the
    /// access check. `SubscriptionManager` overrides this to avoid clearing caches mid-load. (PR-05)
    func isPremiumAccessDefinitivelyDenied() -> Bool { !shouldAllowPremiumAccess() }
}

extension SubscriptionManager: SubscriptionGating {}

/// Narrow seam over the network transport, so cache/version-comparison logic can be tested with
/// canned responses instead of `URLSession.shared`. `@MainActor` to match the (already main-actor)
/// call/decode sites in `AircraftDataService` and avoid `Sendable` ceremony on the fakes. (ARCH-12)
@MainActor
protocol HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPClient {
    // Explicit witness: URLSession's `data(for:delegate:)` (delegate defaulted) does not satisfy the
    // protocol's `data(for:)` requirement on its own.
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, delegate: nil)
    }
}

/// Service for fetching and caching aircraft checklist data from the API
@MainActor
class AircraftDataService: ObservableObject {

    // MARK: - Published Properties

    /// Available aircraft from the server
    @Published var availableAircraft: [RemoteAircraftMetadata] = []

    /// Whether data is loading
    @Published var isLoading = false

    /// Error message
    @Published var errorMessage: String?

    /// Last sync timestamp
    @Published var lastSyncDate: Date?

    /// Incremented when a checklist is updated in the background, so views can reload
    @Published var checklistUpdateCount: Int = 0

    // MARK: - Private Properties

    private let apiBaseURL: String
    private let gating: SubscriptionGating
    private let httpClient: HTTPClient
    private let cacheDirectory: URL
    private let fileManager = FileManager.default

    // MARK: - Initialization

    /// `subscriptionManager` and `httpClient` are injected as protocols (defaulting to the real
    /// implementations) so production wiring is unchanged but tests can supply fakes. (ARCH-12)
    init(
        apiBaseURL: String = "https://api.aerocheck.app",
        subscriptionManager: SubscriptionGating,
        httpClient: HTTPClient = URLSession.shared
    ) {
        self.apiBaseURL = apiBaseURL
        self.gating = subscriptionManager
        self.httpClient = httpClient

        // Set up cache directory
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.cacheDirectory = appSupport.appendingPathComponent("AeroCheck/Checklists", isDirectory: true)

        // Create cache directory if needed
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        // Load cached data first
        loadCachedMetadata()

        // Seed the home-screen widget with the owned-aircraft list from cache so it's correct
        // even before the first network fetch completes.
        WidgetBridge.publish(available: availableAircraft)
    }

    // MARK: - Public Methods

    /// Fetches the list of available aircraft from the server
    func fetchAvailableAircraft() async {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            let aircraft = try await fetchAircraftList()
            self.availableAircraft = aircraft
            self.lastSyncDate = Date()

            // Cache the metadata
            cacheMetadata(aircraft)

        } catch {
            errorMessage = "Failed to fetch aircraft: \(error.localizedDescription)"
            print("Failed to fetch aircraft list: \(error)")

            // Fall back to cached data
            loadCachedMetadata()
        }

        // Refresh the widget's owned-aircraft list to reflect the latest access state. (UX-07)
        WidgetBridge.publish(available: availableAircraft)
    }

    /// Fetches a specific aircraft checklist
    /// For bundled aircraft (like WT9), prefers API version if newer, falls back to bundled version
    /// - Parameters:
    ///   - aircraftId: The aircraft identifier
    ///   - language: The language for checklist content (default: nil, uses server default)
    func fetchChecklist(for aircraftId: String, language: String? = nil) async -> RemoteAircraftChecklist? {
        // Create cache key that includes language
        let cacheKey = language != nil ? "\(aircraftId)_\(language!)" : aircraftId

        // SEC-05 (defense-in-depth — the server gate is authoritative): for a known premium
        // aircraft, drop the cached content ONLY once the entitlement is DEFINITIVELY lapsed.
        // PR-05: this previously used !shouldAllowPremiumAccess(), which is also false during the
        // transient cold-launch window (status still .unknown, grace not yet loaded) and for a
        // subscribed user whose last server verification is merely stale — so a widget/deep-link
        // flight start could destroy the only offline copy of the checklist and lock the pilot out
        // mid-flight. isPremiumAccessDefinitivelyDenied() never fires on those transient states, so
        // an uncertain status now serves the cached checklist instead of clearing it.
        if let meta = availableAircraft.first(where: { $0.id == aircraftId }), !meta.isFree,
           gating.isPremiumAccessDefinitivelyDenied() {
            print("[AircraftDataService] Premium access definitively denied for \(aircraftId); withholding checklist and clearing cache")
            clearCache(for: cacheKey)
            return nil
        }

        // Check cache first
        if let cached = loadCachedChecklist(aircraftId: cacheKey) {
            if isCacheValid(aircraftId: cacheKey) {
                print("[AircraftDataService] Using cached checklist for \(cacheKey)")

                // Check for updates in background - will increment checklistUpdateCount if found
                Task { [weak self] in
                    await self?.checkForUpdate(aircraftId: aircraftId, language: language)
                }
                return cached
            } else {
                print("[AircraftDataService] Cache expired for \(cacheKey), checking for updates")
                // Cache expired - do a blocking update check
                await checkForUpdate(aircraftId: aircraftId, language: language)
                // Return the (possibly updated) cached checklist
                if let updated = loadCachedChecklist(aircraftId: cacheKey) {
                    return updated
                }
            }
        }

        // Fetch from server
        do {
            // First get version info for checksum
            let versionInfo = try? await fetchVersion(aircraftId: aircraftId, language: language)
            let checklist = try await fetchChecklistFromServer(aircraftId: aircraftId, language: language)

            // For bundled aircraft, compare against bundled version for the same language
            if BundledChecklistService.isBundled(aircraftId: aircraftId) {
                // Get bundled checklist for the requested language (or default)
                if let bundled = BundledChecklistService.loadBundledChecklist(for: aircraftId, language: language) {
                    if BundledChecklistService.isNewer(checklist.version, than: bundled.version) ||
                       checklist.version == bundled.version {
                        cacheChecklist(checklist, aircraftId: cacheKey, checksum: versionInfo?.checksum)
                        print("[AircraftDataService] API version (\(checklist.version)) cached for bundled aircraft \(cacheKey)")
                        return checklist
                    } else {
                        // API version is older than bundled - use bundled
                        print("[AircraftDataService] API version (\(checklist.version)) older than bundled (\(bundled.version)), using bundled")
                        return bundled
                    }
                } else {
                    // Language not bundled but aircraft is bundled - this is a new language from API
                    // Cache it as it's new content not available in the bundle
                    cacheChecklist(checklist, aircraftId: cacheKey, checksum: versionInfo?.checksum)
                    print("[AircraftDataService] New language variant (\(language ?? "default")) from API for bundled aircraft \(aircraftId)")
                    return checklist
                }
            }

            cacheChecklist(checklist, aircraftId: cacheKey, checksum: versionInfo?.checksum)
            print("[AircraftDataService] Cached fresh checklist for \(cacheKey)")
            return checklist
        } catch {
            // If offline and we have cached data (even if expired), use it
            if let cached = loadCachedChecklist(aircraftId: cacheKey) {
                print("[AircraftDataService] Using expired cache for \(cacheKey) (offline)")
                errorMessage = "Using cached data (offline)"
                return cached
            }

            // For bundled aircraft, fall back to bundled version when offline
            // Use language-aware fallback
            if BundledChecklistService.isBundled(aircraftId: aircraftId) {
                if let bundled = BundledChecklistService.loadBundledChecklist(for: aircraftId, language: language) {
                    print("[AircraftDataService] Using bundled checklist for \(aircraftId) (\(language ?? "default")) (offline/error)")
                    return bundled
                }
            }

            errorMessage = "Failed to fetch checklist: \(error.localizedDescription)"
            print("Failed to fetch checklist for \(cacheKey): \(error)")
            return nil
        }
    }

    /// Gets the best available checklist for a bundled aircraft
    /// Checks cache, then API, then falls back to bundled version
    /// - Parameter aircraftId: The bundled aircraft identifier (e.g., "wt9-dynamic")
    /// - Parameter language: The language for checklist content (default: nil)
    /// - Returns: The best available checklist, never nil for bundled aircraft with bundled languages
    func getBundledAircraftChecklist(for aircraftId: String, language: String? = nil) async -> RemoteAircraftChecklist? {
        guard BundledChecklistService.isBundled(aircraftId: aircraftId) else {
            return await fetchChecklist(for: aircraftId, language: language)
        }

        // Try to get from API/cache first
        if let checklist = await fetchChecklist(for: aircraftId, language: language) {
            return checklist
        }

        // Fall back to bundled version with language support
        // (should always succeed for bundled aircraft with bundled languages)
        return BundledChecklistService.loadBundledChecklist(for: aircraftId, language: language)
    }

    /// Checks if an update is available for a checklist using checksum comparison
    /// For bundled aircraft, also compares against bundled version to ensure we don't downgrade
    /// - Parameters:
    ///   - aircraftId: The aircraft identifier
    ///   - language: The language for checklist content (default: nil)
    func checkForUpdate(aircraftId: String, language: String? = nil) async {
        let cacheKey = language != nil ? "\(aircraftId)_\(language!)" : aircraftId

        // For bundled aircraft, we can check for updates even without cache
        let isBundled = BundledChecklistService.isBundled(aircraftId: aircraftId)
        let cachedChecklist = loadCachedChecklist(aircraftId: cacheKey)
        // Get bundled checklist for the specific language (if available)
        let bundledChecklist = isBundled ? BundledChecklistService.loadBundledChecklist(for: aircraftId, language: language) : nil

        // Need either cached or bundled version to compare against
        // Exception: if language is not bundled but aircraft is bundled, we should still check for API updates
        let hasLocalVersion = cachedChecklist != nil || bundledChecklist != nil
        let isNewLanguageForBundledAircraft = isBundled && language != nil && !BundledChecklistService.isLanguageBundled(aircraftId: aircraftId, language: language!)

        guard hasLocalVersion || isNewLanguageForBundledAircraft else { return }

        let cachedMetadata = loadCacheMetadata(aircraftId: cacheKey)

        do {
            let serverVersion = try await fetchVersion(aircraftId: aircraftId, language: language)

            // Determine the current version we have (cached or bundled)
            let currentVersion = cachedChecklist?.version ?? bundledChecklist?.version ?? ""

            // Compare checksums if available, otherwise fall back to version comparison
            let needsUpdate: Bool
            if let serverChecksum = serverVersion.checksum,
               let cachedChecksum = cachedMetadata?.checksum {
                needsUpdate = serverChecksum != cachedChecksum
            } else if currentVersion.isEmpty {
                // No local version (new language from API) - always update
                needsUpdate = true
            } else {
                needsUpdate = serverVersion.version != currentVersion
            }

            if needsUpdate {
                // For bundled aircraft with bundled language, only update if server version is newer than bundled
                if isBundled, let bundled = bundledChecklist {
                    if !BundledChecklistService.isNewer(serverVersion.version, than: bundled.version) &&
                       serverVersion.version != bundled.version {
                        print("[AircraftDataService] Server version (\(serverVersion.version)) not newer than bundled (\(bundled.version)), skipping update")
                        return
                    }
                }

                print("[AircraftDataService] Update available for \(cacheKey), downloading...")
                do {
                    let updated = try await fetchChecklistFromServer(aircraftId: aircraftId, language: language)
                    cacheChecklist(updated, aircraftId: cacheKey, checksum: serverVersion.checksum)

                    // Update the metadata to reflect new version and signal UI to reload
                    if let index = availableAircraft.firstIndex(where: { $0.id == aircraftId }) {
                        availableAircraft[index].version = updated.version
                        availableAircraft[index].lastUpdated = updated.lastUpdated
                    }
                    checklistUpdateCount += 1
                    print("[AircraftDataService] Successfully updated checklist for \(cacheKey) to v\(updated.version)")
                } catch {
                    print("[AircraftDataService] Failed to download update for \(cacheKey): \(error.localizedDescription)")
                }
            } else {
                print("[AircraftDataService] Checklist for \(cacheKey) is up to date")
            }
        } catch {
            print("[AircraftDataService] Failed to check for update for \(cacheKey): \(error.localizedDescription)")
        }
    }

    /// Syncs all cached checklists with the server
    func syncAllChecklists() async {
        for aircraft in availableAircraft where aircraft.hasAccess {
            await checkForUpdate(aircraftId: aircraft.id)
        }
        lastSyncDate = Date()
    }

    /// Syncs bundled aircraft checklists with the server
    /// Call this on app launch to check for updates to bundled aircraft
    /// Also checks for new language variants available from the API
    func syncBundledAircraft() async {
        for aircraftId in BundledChecklistService.bundledAircraftIds {
            // Check default language
            await checkForUpdate(aircraftId: aircraftId)

            // Check all bundled languages
            for language in BundledChecklistService.availableLanguages(for: aircraftId) {
                await checkForUpdate(aircraftId: aircraftId, language: language)
            }

            // Also check if API has new languages not in the bundle
            // by checking the aircraft metadata for available languages
            if let aircraft = availableAircraft.first(where: { $0.id == aircraftId }) {
                let bundledLanguages = Set(BundledChecklistService.availableLanguages(for: aircraftId))
                let apiLanguages = Set(aircraft.checklistLanguages)
                let newLanguages = apiLanguages.subtracting(bundledLanguages)

                for language in newLanguages {
                    print("[AircraftDataService] Checking new API language '\(language)' for bundled aircraft \(aircraftId)")
                    await checkForUpdate(aircraftId: aircraftId, language: language)
                }
            }
        }
    }

    /// Gets a checklist, preferring cached data
    func getChecklist(for aircraftId: String) -> RemoteAircraftChecklist? {
        return loadCachedChecklist(aircraftId: aircraftId)
    }

    /// Checks if a checklist is cached locally
    func isChecklistCached(aircraftId: String) -> Bool {
        let path = cacheDirectory.appendingPathComponent("\(aircraftId).json")
        return fileManager.fileExists(atPath: path.path)
    }

    /// Gets all cached aircraft (combines remote and bundled), sorted by aeroclub
    func getAllCachedAircraft() -> [CachedAircraftInfo] {
        var cached: [CachedAircraftInfo] = []
        var processedIds: Set<String> = []

        // Add bundled aircraft first
        for aircraftId in BundledChecklistService.bundledAircraftIds {
            // Get available languages from bundled config
            let bundledLanguages = BundledChecklistService.availableLanguages(for: aircraftId)

            // Check if we have a cached (possibly newer) version from API
            if let cachedChecklist = loadCachedChecklist(aircraftId: aircraftId) {
                // Determine all available languages (bundled + any cached from API)
                var allLanguages = Set(bundledLanguages)
                if let aircraft = availableAircraft.first(where: { $0.id == aircraftId }) {
                    allLanguages.formUnion(aircraft.checklistLanguages)
                }

                cached.append(CachedAircraftInfo(
                    registration: cachedChecklist.registration,
                    modelName: cachedChecklist.shortModelName,
                    aeroclub: cachedChecklist.aeroclub,
                    version: cachedChecklist.version,
                    lastUpdated: cachedChecklist.lastUpdated,
                    isPremium: false, // Bundled aircraft are always free
                    checklistLanguages: Array(allLanguages).sorted()
                ))
            } else if let bundled = BundledChecklistService.loadBundledChecklist(for: aircraftId) {
                // Use bundled version
                cached.append(CachedAircraftInfo(
                    registration: bundled.registration,
                    modelName: bundled.shortModelName,
                    aeroclub: bundled.aeroclub,
                    version: bundled.version,
                    lastUpdated: bundled.lastUpdated,
                    isPremium: false,
                    checklistLanguages: bundledLanguages
                ))
            }
            processedIds.insert(aircraftId)
        }

        // Add non-bundled remote aircraft that are cached
        for aircraft in availableAircraft where isChecklistCached(aircraftId: aircraft.id) && !processedIds.contains(aircraft.id) {
            // Load the cached checklist to get the actual lastUpdated value
            if let cachedChecklist = loadCachedChecklist(aircraftId: aircraft.id) {
                cached.append(CachedAircraftInfo(
                    registration: aircraft.registration,
                    modelName: aircraft.shortModelName,
                    aeroclub: aircraft.aeroclub,
                    version: cachedChecklist.version,
                    lastUpdated: cachedChecklist.lastUpdated,
                    isPremium: !aircraft.isFree,
                    checklistLanguages: aircraft.checklistLanguages
                ))
            }
        }

        // Sort by aeroclub (nil values first, then alphabetically)
        return cached.sorted { lhs, rhs in
            switch (lhs.aeroclub, rhs.aeroclub) {
            case (nil, nil): return lhs.registration < rhs.registration
            case (nil, _): return true
            case (_, nil): return false
            case (let a?, let b?): return a == b ? lhs.registration < rhs.registration : a < b
            }
        }
    }

    /// Gets the cache date for a checklist
    func getCacheDate(aircraftId: String) -> Date? {
        let path = cacheDirectory.appendingPathComponent("\(aircraftId).json")
        guard let attributes = try? fileManager.attributesOfItem(atPath: path.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    /// Checks if cached checklist is still valid (within 24 hours)
    func isCacheValid(aircraftId: String) -> Bool {
        guard let cacheDate = getCacheDate(aircraftId: aircraftId) else {
            return false
        }

        let expirationInterval: TimeInterval = 24 * 60 * 60 // 24 hours
        let expirationDate = cacheDate.addingTimeInterval(expirationInterval)

        return Date() < expirationDate
    }

    /// Clears the cache for a specific aircraft
    func clearCache(for aircraftId: String) {
        let checklistPath = cacheDirectory.appendingPathComponent("\(aircraftId).json")
        let metadataPath = cacheDirectory.appendingPathComponent("\(aircraftId).metadata.json")

        do {
            if fileManager.fileExists(atPath: checklistPath.path) {
                try fileManager.removeItem(at: checklistPath)
            }
            if fileManager.fileExists(atPath: metadataPath.path) {
                try fileManager.removeItem(at: metadataPath)
            }
            print("[AircraftDataService] Cleared cache for \(aircraftId)")
        } catch {
            print("[AircraftDataService] Failed to clear cache for \(aircraftId): \(error)")
        }
    }

    /// Clears all cached checklists
    func clearAllCaches() {
        do {
            let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)

            for fileURL in contents where fileURL.pathExtension == "json" {
                try? fileManager.removeItem(at: fileURL)
            }

            print("[AircraftDataService] Cleared all caches")
        } catch {
            print("[AircraftDataService] Failed to clear caches: \(error)")
        }
    }

    /// Clears all premium (non-free) cached checklists
    /// Called when subscription expires and grace period ends
    func clearPremiumCaches() {
        print("[AircraftDataService] Clearing premium cached checklists")
        for aircraft in availableAircraft where !aircraft.isFree {
            clearCache(for: aircraft.id)
        }
    }

    /// Checks and clears premium caches if subscription is no longer valid
    /// Returns true if premium caches are still valid, false if they were cleared
    func validatePremiumCaches(subscriptionManager: SubscriptionGating) -> Bool {
        guard subscriptionManager.shouldAllowPremiumAccess() else {
            print("[AircraftDataService] Subscription access revoked, clearing premium caches")
            clearPremiumCaches()
            return false
        }
        return true
    }

    // MARK: - Private Methods

    private func fetchAircraftList() async throws -> [RemoteAircraftMetadata] {
        guard let url = URL(string: "\(apiBaseURL)/api/v3/aircraft/available") else {
            throw AircraftDataError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15 // Set timeout for poor network conditions

        // Add auth header if available
        if let userID = await gating.getUserID() {
            request.setValue("Bearer \(userID)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await httpClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AircraftDataError.serverError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        // Parse aircraft list with resilient decoding - skip malformed entries
        return parseAircraftListResilient(from: data)
    }

    /// Parses aircraft list data, skipping any malformed aircraft entries
    /// This ensures the app can display valid aircraft even if some entries are malformed
    private func parseAircraftListResilient(from data: Data) -> [RemoteAircraftMetadata] {
        // First try to parse the wrapper to get the aircraft array
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any],
              let aircraftArray = dataDict["aircraft"] as? [[String: Any]] else {
            print("[AircraftDataService] Failed to parse aircraft list wrapper")
            return []
        }

        var validAircraft: [RemoteAircraftMetadata] = []
        let decoder = JSONDecoder()

        for (index, aircraftDict) in aircraftArray.enumerated() {
            do {
                let aircraftData = try JSONSerialization.data(withJSONObject: aircraftDict)
                let aircraft = try decoder.decode(RemoteAircraftMetadata.self, from: aircraftData)
                validAircraft.append(aircraft)
            } catch {
                // Log the error but continue processing other aircraft
                let aircraftId = aircraftDict["id"] as? String ?? "unknown"
                print("[AircraftDataService] Skipping malformed aircraft at index \(index) (id: \(aircraftId)): \(error.localizedDescription)")
            }
        }

        print("[AircraftDataService] Parsed \(validAircraft.count)/\(aircraftArray.count) aircraft successfully")
        return validAircraft
    }

    private func fetchChecklistFromServer(aircraftId: String, language: String? = nil) async throws -> RemoteAircraftChecklist {
        // Build URL with optional language parameter. The aircraftId is server-supplied,
        // so percent-encode it (and the language) and fail safely on an unbuildable URL
        // rather than force-unwrapping (PERF-14).
        let encodedId = aircraftId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? aircraftId
        var urlString = "\(apiBaseURL)/api/v3/aircraft/\(encodedId)/checklist"
        if let lang = language,
           let encodedLang = lang.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            urlString += "?lang=\(encodedLang)"
        }
        guard let url = URL(string: urlString) else { throw AircraftDataError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30 // Checklists can be larger, allow more time

        // Add auth header if available
        if let userID = await gating.getUserID() {
            request.setValue("Bearer \(userID)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await httpClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AircraftDataError.invalidResponse
        }

        if httpResponse.statusCode == 403 {
            throw AircraftDataError.accessDenied
        }

        if httpResponse.statusCode == 404 {
            throw AircraftDataError.notFound
        }

        guard httpResponse.statusCode == 200 else {
            throw AircraftDataError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        let result = try decoder.decode(ChecklistResponse.self, from: data)

        return result.data
    }

    private func fetchVersion(aircraftId: String, language: String? = nil) async throws -> VersionInfo {
        // Build URL with optional language parameter (server-supplied id; encode + fail safe).
        let encodedId = aircraftId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? aircraftId
        var urlString = "\(apiBaseURL)/api/v3/aircraft/\(encodedId)/version"
        if let lang = language,
           let encodedLang = lang.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            urlString += "?lang=\(encodedLang)"
        }
        guard let url = URL(string: urlString) else { throw AircraftDataError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10 // Version check should be quick

        let (data, response) = try await httpClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AircraftDataError.serverError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let decoder = JSONDecoder()
        let result = try decoder.decode(VersionResponse.self, from: data)

        return result.data
    }

    // MARK: - Caching

    private func cacheMetadata(_ aircraft: [RemoteAircraftMetadata]) {
        let path = cacheDirectory.appendingPathComponent("metadata.json")

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(aircraft)
            try data.write(to: path)
        } catch {
            print("Failed to cache metadata: \(error)")
        }
    }

    private func loadCachedMetadata() {
        let path = cacheDirectory.appendingPathComponent("metadata.json")

        guard fileManager.fileExists(atPath: path.path) else { return }

        do {
            let data = try Data(contentsOf: path)
            let decoder = JSONDecoder()
            availableAircraft = try decoder.decode([RemoteAircraftMetadata].self, from: data)

            // Get cache date
            if let attributes = try? fileManager.attributesOfItem(atPath: path.path) {
                lastSyncDate = attributes[.modificationDate] as? Date
            }
        } catch {
            print("Failed to load cached metadata: \(error)")
        }
    }

    private func cacheChecklist(_ checklist: RemoteAircraftChecklist, aircraftId: String, checksum: String? = nil) {
        let path = cacheDirectory.appendingPathComponent("\(aircraftId).json")
        let metadataPath = cacheDirectory.appendingPathComponent("\(aircraftId).metadata.json")

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(checklist)
            try data.write(to: path)

            // Also store metadata for cache validation
            let metadata = CacheMetadata(
                aircraftId: aircraftId,
                checksum: checksum,
                cachedAt: Date(),
                subscriptionVerifiedAt: Date()
            )
            let metadataData = try encoder.encode(metadata)
            try metadataData.write(to: metadataPath)
        } catch {
            print("Failed to cache checklist: \(error)")
        }
    }

    private func loadCacheMetadata(aircraftId: String) -> CacheMetadata? {
        let path = cacheDirectory.appendingPathComponent("\(aircraftId).metadata.json")

        guard fileManager.fileExists(atPath: path.path) else { return nil }

        do {
            let data = try Data(contentsOf: path)
            let decoder = JSONDecoder()
            return try decoder.decode(CacheMetadata.self, from: data)
        } catch {
            print("Failed to load cache metadata: \(error)")
            return nil
        }
    }

    private func updateSubscriptionVerificationDate(aircraftId: String) {
        let metadataPath = cacheDirectory.appendingPathComponent("\(aircraftId).metadata.json")

        guard let metadata = loadCacheMetadata(aircraftId: aircraftId) else { return }

        // Create updated metadata with new verification date
        let updatedMetadata = CacheMetadata(
            aircraftId: metadata.aircraftId,
            checksum: metadata.checksum,
            cachedAt: metadata.cachedAt,
            subscriptionVerifiedAt: Date()
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(updatedMetadata)
            try data.write(to: metadataPath)
        } catch {
            print("Failed to update cache metadata: \(error)")
        }
    }

    private func loadCachedChecklist(aircraftId: String) -> RemoteAircraftChecklist? {
        let path = cacheDirectory.appendingPathComponent("\(aircraftId).json")

        guard fileManager.fileExists(atPath: path.path) else { return nil }

        do {
            let data = try Data(contentsOf: path)
            let decoder = JSONDecoder()
            return try decoder.decode(RemoteAircraftChecklist.self, from: data)
        } catch {
            print("Failed to load cached checklist: \(error)")
            return nil
        }
    }
}

// MARK: - Cached Aircraft Info

/// Information about a cached aircraft checklist
struct CachedAircraftInfo: Identifiable {
    let id = UUID()
    let registration: String
    let modelName: String
    let aeroclub: String?
    let version: String
    let lastUpdated: String
    let isPremium: Bool
    let checklistLanguages: [String]
}

// MARK: - Error Types

enum AircraftDataError: LocalizedError {
    case serverError(Int)
    case accessDenied
    case notFound
    case invalidResponse
    case invalidURL
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .serverError(let code):
            return "Server error: \(code)"
        case .accessDenied:
            return "Subscription required to access this aircraft"
        case .notFound:
            return "Aircraft not found"
        case .invalidResponse:
            return "Invalid response from server"
        case .invalidURL:
            return "Could not build a valid request URL"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

// MARK: - API Response Types

private struct AircraftListResponse: Codable {
    let success: Bool
    let data: AircraftListData
}

private struct AircraftListData: Codable {
    let aircraft: [RemoteAircraftMetadata]
}

private struct ChecklistResponse: Codable {
    let success: Bool
    let data: RemoteAircraftChecklist
}

private struct VersionResponse: Codable {
    let success: Bool
    let data: VersionInfo
}

private struct VersionInfo: Codable {
    let id: String
    let version: String
    let lastUpdated: String
    let checksum: String?
}

/// Cache metadata stored alongside the checklist
private struct CacheMetadata: Codable {
    let aircraftId: String
    let checksum: String?
    let cachedAt: Date
    let subscriptionVerifiedAt: Date?
}
