import Foundation
import CryptoKit

/// Narrow seam over the subscription state `AircraftDataService` needs, so its premium-gating logic
/// can be exercised with a fake instead of a live `SubscriptionManager` + StoreKit. (ARCH-12)
@MainActor
protocol SubscriptionGating {
    func getUserID() async -> String?
    /// Credential for `Authorization: Bearer …` — the minted session token when one exists,
    /// otherwise the legacy identifier during migration. (SEC-C3)
    func getAuthCredential() async -> String?
    func shouldAllowPremiumAccess() -> Bool
    /// True only when premium access is DEFINITIVELY denied (status resolved, not subscribed, no
    /// valid grace window). Used for the cache-DESTROYING decision so a transient cold-launch state
    /// can't wipe the offline checklist. (PR-05)
    func isPremiumAccessDefinitivelyDenied() -> Bool
}

extension SubscriptionGating {
    /// Default for conformers (e.g. test fakes) that predate the session token.
    func getAuthCredential() async -> String? { await getUserID() }

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

/// Default `HTTPClient` for this service: the shared `ExternalRequest` path. (SEC-C35)
///
/// The three fetch sites here called the injected client directly, and the default was
/// `URLSession.shared` — so the aircraft-list and checklist downloads were the only external
/// fetches in the app with NO response-size ceiling, while every other service went through
/// `ExternalRequest`. A checklist fetch can happen mid-flight (widget/deep-link start), so the
/// unbounded buffer was reachable at the worst possible moment. Fixing the DEFAULT rather than the
/// call sites keeps the `HTTPClient` seam intact for tests.
nonisolated struct SizeLimitedHTTPClient: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await ExternalRequest.data(for: request)
        return (data, response)
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
        apiBaseURL: String = APIConfig.baseURL,
        subscriptionManager: SubscriptionGating,
        httpClient: HTTPClient = SizeLimitedHTTPClient()
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

        // SA-22: keep the paywalled checklist cache OUT of device backups. Application Support is
        // included in backups (only Library/Caches and tmp are excluded), so without this an
        // ordinary unencrypted Finder/iTunes backup of a subscriber's iPad contains every premium
        // checklist as plaintext JSON — no jailbreak, just a backup extractor. Nothing is lost by
        // excluding it: the cache is fully re-downloadable.
        var excludeFromBackup = URLResourceValues()
        excludeFromBackup.isExcludedFromBackup = true
        var cacheDirectoryURL = cacheDirectory
        try? cacheDirectoryURL.setResourceValues(excludeFromBackup)

        // Load cached data first
        loadCachedMetadata()

        // Seed the home-screen widget with the owned-aircraft list from cache so it's correct
        // even before the first network fetch completes.
        WidgetBridge.publish(available: availableAircraft)
    }

    // MARK: - Marketing Owned-Aircraft Override (DEBUG-ONLY)

    #if DEBUG
    /// The owned-id set requested by Marketing Mode, retained so it can be re-applied after any late
    /// `fetchAvailableAircraft()` resolves. Without this, a still-in-flight startup fetch can land
    /// AFTER the override and clobber `hasAccess` back to the real (locked) state — a race that made
    /// the home-carousel scene flaky (it depended on which fetch resolved last). Process-memory only.
    private var marketingOwnedOverride: Set<String>?

    /// DEBUG-ONLY (Marketing Mode): force the owned-aircraft set so Home shows exactly the aircraft
    /// whose ids are in `ownedIds`, plus the always-bundled WT9 (HomeView adds bundled aircraft
    /// unconditionally). Mutates the in-memory `availableAircraft` `hasAccess` flags only — nothing
    /// is persisted to disk, so a relaunch restores the real state.
    ///
    /// HomeView's owned list is `availableAircraft where remote.hasAccess && !remote.isBundled`, so
    /// setting `hasAccess = true` for exactly the requested premium ids and `false` for the rest
    /// yields a deterministic carousel (e.g. just F-HVXA + HB-PFA for scene #1).
    ///
    /// Compiled OUT of release builds: this grants premium *access* in the UI, so it must never ship.
    func applyMarketingOwnedOverride(ownedIds: Set<String>) {
        marketingOwnedOverride = ownedIds
        reapplyMarketingOwnedOverride()
    }

    /// Re-applies the retained marketing owned-override (if any) over the current `availableAircraft`.
    /// Called both by `applyMarketingOwnedOverride` and at the tail of `fetchAvailableAircraft()` so a
    /// late-resolving fetch can never strip the forced ownership.
    private func reapplyMarketingOwnedOverride() {
        guard let ownedIds = marketingOwnedOverride else { return }
        for index in availableAircraft.indices {
            let meta = availableAircraft[index]
            if meta.isBundled { continue } // bundled WT9 is always shown by HomeView regardless
            availableAircraft[index].hasAccess = ownedIds.contains(meta.id)
        }
        WidgetBridge.publish(available: availableAircraft)
    }
    #endif

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
            AppLog.aircraftData.debugLine("Failed to fetch aircraft list: \(error)")

            // Fall back to cached data
            loadCachedMetadata()
        }

        #if DEBUG
        // Marketing Mode: re-assert the forced owned-set AFTER this fetch wrote `availableAircraft`,
        // so a late startup fetch can't clobber the home-carousel override (race fix). No-op otherwise.
        reapplyMarketingOwnedOverride()
        #endif

        // Refresh the widget's owned-aircraft list to reflect the latest access state. (UX-07)
        WidgetBridge.publish(available: availableAircraft)
    }

    /// After a purchase, the server's entitlement write can lag the client's StoreKit confirmation, so
    /// a single refetch can still return the locked list ("bought it but still locked"). Retry a few
    /// times with backoff until at least one premium aircraft reports access — then stop. If it never
    /// unlocks within the attempts, the periodic check / next launch reconciles. (premium reliability)
    func refetchUntilPremiumUnlocked(maxAttempts: Int = 4) async {
        let attempts = max(1, maxAttempts)
        for attempt in 1...attempts {
            await fetchAvailableAircraft()
            if availableAircraft.contains(where: { !$0.isFree && $0.hasAccess }) {
                AppLog.aircraftData.debugLine("Premium unlocked after \(attempt) fetch attempt(s)")
                return
            }
            if attempt < attempts {
                // 1.5s, 3s, 4.5s — enough for the edge KV write to propagate without a long hang.
                try? await Task.sleep(for: .seconds(Double(attempt) * 1.5))
            }
        }
        AppLog.aircraftData.debugLine("Premium still locked after \(attempts) attempt(s); periodic check will reconcile")
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
            AppLog.aircraftData.debugLine("Premium access definitively denied for \(aircraftId); withholding checklist and clearing cache")
            clearCache(for: cacheKey)
            return nil
        }

        // Check cache first
        if let cached = loadCachedChecklist(aircraftId: cacheKey) {
            if isCacheValid(aircraftId: cacheKey) {
                AppLog.aircraftData.debugLine("Using cached checklist for \(cacheKey)")

                // Check for updates in background - will increment checklistUpdateCount if found
                Task { [weak self] in
                    await self?.checkForUpdate(aircraftId: aircraftId, language: language)
                }
                return cached
            } else {
                AppLog.aircraftData.debugLine("Cache expired for \(cacheKey), checking for updates")
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

            // RES-13: these are two SEPARATE requests, and their results were paired and cached
            // without ever checking they describe the same revision. A deploy landing between them —
            // or a stale edge cache on one of the two — stores this content under that checksum, and
            // because the update check compares checksums first, the mismatched pair then compares
            // equal forever: the stale checklist is never refreshed.
            //
            // Dropping the checksum on a mismatch costs nothing (the next check falls back to
            // version comparison, which is correct) and cannot poison the cache.
            //
            // Note this is a consistency check, not an integrity one: the client cannot recompute
            // the server's digest, which is taken over the server's own checklist object rather than
            // the response body the client receives. On-disk integrity is covered separately by
            // `CacheMetadata.contentHash` (SEC-C30).
            let trustedChecksum: String? = {
                guard let info = versionInfo else { return nil }
                guard info.version == checklist.version else {
                    AppLog.aircraftData.debugLine(
                        "Version/checklist disagree for \(cacheKey) (\(info.version) vs \(checklist.version)); caching without a checksum")
                    return nil
                }
                return info.checksum
            }()

            // For bundled aircraft, compare against bundled version for the same language
            if BundledChecklistService.isBundled(aircraftId: aircraftId) {
                // Get bundled checklist for the requested language (or default)
                if let bundled = BundledChecklistService.loadBundledChecklist(for: aircraftId, language: language) {
                    if BundledChecklistService.isNewer(checklist.version, than: bundled.version) ||
                       checklist.version == bundled.version {
                        cacheChecklist(checklist, aircraftId: cacheKey, checksum: trustedChecksum)
                        AppLog.aircraftData.debugLine("API version (\(checklist.version)) cached for bundled aircraft \(cacheKey)")
                        return checklist
                    } else {
                        // API version is older than bundled - use bundled
                        AppLog.aircraftData.debugLine("API version (\(checklist.version)) older than bundled (\(bundled.version)), using bundled")
                        return bundled
                    }
                } else {
                    // Language not bundled but aircraft is bundled - this is a new language from API
                    // Cache it as it's new content not available in the bundle
                    cacheChecklist(checklist, aircraftId: cacheKey, checksum: trustedChecksum)
                    AppLog.aircraftData.debugLine("New language variant (\(language ?? "default")) from API for bundled aircraft \(aircraftId)")
                    return checklist
                }
            }

            cacheChecklist(checklist, aircraftId: cacheKey, checksum: trustedChecksum)
            AppLog.aircraftData.debugLine("Cached fresh checklist for \(cacheKey)")
            return checklist
        } catch {
            // If offline and we have cached data (even if expired), use it
            if let cached = loadCachedChecklist(aircraftId: cacheKey) {
                AppLog.aircraftData.debugLine("Using expired cache for \(cacheKey) (offline)")
                errorMessage = "Using cached data (offline)"
                return cached
            }

            // For bundled aircraft, fall back to bundled version when offline
            // Use language-aware fallback
            if BundledChecklistService.isBundled(aircraftId: aircraftId) {
                if let bundled = BundledChecklistService.loadBundledChecklist(for: aircraftId, language: language) {
                    AppLog.aircraftData.debugLine("Using bundled checklist for \(aircraftId) (\(language ?? "default")) (offline/error)")
                    return bundled
                }
            }

            errorMessage = "Failed to fetch checklist: \(error.localizedDescription)"
            AppLog.aircraftData.debugLine("Failed to fetch checklist for \(cacheKey): \(error)")
            return nil
        }
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

            let needsUpdate = ChecklistUpdateDecision.needsUpdate(
                serverChecksum: serverVersion.checksum,
                cachedChecksum: cachedMetadata?.checksum,
                serverVersion: serverVersion.version,
                currentVersion: currentVersion
            )

            if needsUpdate {
                // For bundled aircraft with bundled language, only update if server version is newer than bundled
                if isBundled, let bundled = bundledChecklist {
                    if !BundledChecklistService.isNewer(serverVersion.version, than: bundled.version) &&
                       serverVersion.version != bundled.version {
                        AppLog.aircraftData.debugLine("Server version (\(serverVersion.version)) not newer than bundled (\(bundled.version)), skipping update")
                        return
                    }
                }

                AppLog.aircraftData.debugLine("Update available for \(cacheKey), downloading...")
                do {
                    let updated = try await fetchChecklistFromServer(aircraftId: aircraftId, language: language)
                    cacheChecklist(updated, aircraftId: cacheKey, checksum: serverVersion.checksum)

                    // Update the metadata to reflect new version and signal UI to reload
                    if let index = availableAircraft.firstIndex(where: { $0.id == aircraftId }) {
                        availableAircraft[index].version = updated.version
                        availableAircraft[index].lastUpdated = updated.lastUpdated
                    }
                    checklistUpdateCount += 1
                    AppLog.aircraftData.debugLine("Successfully updated checklist for \(cacheKey) to v\(updated.version)")
                } catch {
                    AppLog.aircraftData.debugLine("Failed to download update for \(cacheKey): \(error.localizedDescription)")
                }
            } else {
                AppLog.aircraftData.debugLine("Checklist for \(cacheKey) is up to date")
            }
        } catch {
            AppLog.aircraftData.debugLine("Failed to check for update for \(cacheKey): \(error.localizedDescription)")
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
                    AppLog.aircraftData.debugLine("Checking new API language '\(language)' for bundled aircraft \(aircraftId)")
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
        guard let path = cacheFileURL(aircraftId: aircraftId, suffix: ".json") else { return false }
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
        guard let path = cacheFileURL(aircraftId: aircraftId, suffix: ".json"),
              let attributes = try? fileManager.attributesOfItem(atPath: path.path) else {
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
        guard let checklistPath = cacheFileURL(aircraftId: aircraftId, suffix: ".json"),
              let metadataPath = cacheFileURL(aircraftId: aircraftId, suffix: ".metadata.json") else { return }

        do {
            if fileManager.fileExists(atPath: checklistPath.path) {
                try fileManager.removeItem(at: checklistPath)
            }
            if fileManager.fileExists(atPath: metadataPath.path) {
                try fileManager.removeItem(at: metadataPath)
            }
            AppLog.aircraftData.debugLine("Cleared cache for \(aircraftId)")
        } catch {
            AppLog.aircraftData.debugLine("Failed to clear cache for \(aircraftId): \(error)")
        }
    }

    /// Clears all premium (non-free) cached checklists
    /// Called when subscription expires and grace period ends
    func clearPremiumCaches() {
        AppLog.aircraftData.debugLine("Clearing premium cached checklists")
        for aircraft in availableAircraft where !aircraft.isFree {
            clearCache(for: aircraft.id)
        }
    }

    /// Checks and clears premium caches if subscription is no longer valid
    /// Returns true if premium caches are still valid, false if they were cleared
    func validatePremiumCaches(subscriptionManager: SubscriptionGating) -> Bool {
        // Gate on the DEFINITIVELY-denied predicate, not shouldAllowPremiumAccess(): the latter returns
        // false on transient/unknown/offline-too-long states, which would wrongly wipe a subscribed
        // pilot's offline cache. Mirrors the cache-destroying gate in fetchChecklist. (v4.1.0 pre-tag fix)
        guard subscriptionManager.isPremiumAccessDefinitivelyDenied() else {
            return true
        }
        AppLog.aircraftData.debugLine("Subscription access definitively denied, clearing premium caches")
        clearPremiumCaches()
        return false
    }

    // MARK: - Private Methods

    private func fetchAircraftList() async throws -> [RemoteAircraftMetadata] {
        guard let url = URL(string: "\(apiBaseURL)/api/v3/aircraft/available") else {
            throw AircraftDataError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15 // Set timeout for poor network conditions

        // Add auth header if available (minted session token, or legacy id during migration)
        if let credential = await gating.getAuthCredential() {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await httpClient.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AircraftDataError.serverError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        // Parse aircraft list with resilient decoding - skip malformed entries, then expand
        // multi-registration aircraft into one selectable entry per tail (PR-17 selector).
        return parseAircraftListResilient(from: data).flatMap { $0.expandedPerRegistration() }
    }

    /// Parses aircraft list data, skipping any malformed aircraft entries
    /// This ensures the app can display valid aircraft even if some entries are malformed
    private func parseAircraftListResilient(from data: Data) -> [RemoteAircraftMetadata] {
        // First try to parse the wrapper to get the aircraft array
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any],
              let aircraftArray = dataDict["aircraft"] as? [[String: Any]] else {
            AppLog.aircraftData.debugLine("Failed to parse aircraft list wrapper")
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
                AppLog.aircraftData.debugLine("Skipping malformed aircraft at index \(index) (id: \(aircraftId)): \(error.localizedDescription)")
            }
        }

        AppLog.aircraftData.debugLine("Parsed \(validAircraft.count)/\(aircraftArray.count) aircraft successfully")
        return validAircraft
    }

    private func fetchChecklistFromServer(aircraftId: String, language: String? = nil) async throws -> RemoteAircraftChecklist {
        // Build URL with optional language/registration parameters. The aircraftId is
        // server-supplied, so percent-encode it (and the query values) and fail safely on an
        // unbuildable URL rather than force-unwrapping (PERF-14). An "id~REG" tail token is
        // split into the path id plus a `reg` query (the server serves that tail's file).
        // SA-23: reject an id that is not safe as a URL path segment before building the request.
        // `.urlPathAllowed` preserves `/` and `..`, so percent-encoding alone does NOT stop a
        // traversal reaching the server (or the response landing at a traversed cache path).
        guard AircraftRegistrationToken.isWellFormed(aircraftId) else {
            throw AircraftDataError.invalidURL
        }
        let (baseId, registration) = AircraftRegistrationToken.split(aircraftId)
        let encodedId = baseId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? baseId
        var urlString = "\(apiBaseURL)/api/v3/aircraft/\(encodedId)/checklist"
        var query: [String] = []
        if let lang = language,
           let encodedLang = lang.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            query.append("lang=\(encodedLang)")
        }
        if let reg = registration,
           let encodedReg = reg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            query.append("reg=\(encodedReg)")
        }
        if !query.isEmpty { urlString += "?" + query.joined(separator: "&") }
        guard let url = URL(string: urlString) else { throw AircraftDataError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30 // Checklists can be larger, allow more time

        // Add auth header if available (minted session token, or legacy id during migration)
        if let credential = await gating.getAuthCredential() {
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
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
        // SEC-C29: the SA-23 traversal guard applied to fetchChecklistFromServer (:618) and
        // cacheFileURL (:748) but NOT here, even though this builds a URL path segment from the
        // same id — and fetchChecklist calls fetchVersion FIRST, so the unguarded request fired
        // regardless of what the guarded sibling later did. `.urlPathAllowed` preserves `/` and
        // `..`, so percent-encoding alone does not stop a traversal.
        guard AircraftRegistrationToken.isWellFormed(aircraftId) else {
            throw AircraftDataError.invalidURL
        }
        // Build URL with optional language/registration parameters (server-supplied id;
        // encode + fail safe). "id~REG" tail tokens split into path id + `reg` query.
        let (baseId, registration) = AircraftRegistrationToken.split(aircraftId)
        let encodedId = baseId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? baseId
        var urlString = "\(apiBaseURL)/api/v3/aircraft/\(encodedId)/version"
        var query: [String] = []
        if let lang = language,
           let encodedLang = lang.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            query.append("lang=\(encodedLang)")
        }
        if let reg = registration,
           let encodedReg = reg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            query.append("reg=\(encodedReg)")
        }
        if !query.isEmpty { urlString += "?" + query.joined(separator: "&") }
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
            try data.write(to: path, options: DataPersistenceManager.protectedWriteOptions)
        } catch {
            AppLog.aircraftData.debugLine("Failed to cache metadata: \(error)")
        }
    }

    private func loadCachedMetadata() {
        let path = cacheDirectory.appendingPathComponent("metadata.json")

        guard fileManager.fileExists(atPath: path.path) else { return }

        do {
            let data = try Data(contentsOf: path)
            let decoder = JSONDecoder()
            // Expand per tail here too so a metadata cache written before the per-registration
            // selector shipped still lists every registration (idempotent on new caches).
            availableAircraft = try decoder.decode([RemoteAircraftMetadata].self, from: data)
                .flatMap { $0.expandedPerRegistration() }

            // Get cache date
            if let attributes = try? fileManager.attributesOfItem(atPath: path.path) {
                lastSyncDate = attributes[.modificationDate] as? Date
            }
        } catch {
            AppLog.aircraftData.debugLine("Failed to load cached metadata: \(error)")
        }
    }

    /// Cache-file URL for an aircraft id, or nil when the id is not safe as a path component.
    ///
    /// SA-23: `cacheDirectory.appendingPathComponent("\(id).json")` trusted the id, and the id can
    /// arrive from a synced CloudKit Settings record or a compromised/misbehaving API server.
    /// `../../../Documents/leak` resolves outside the cache and inside the
    /// `UIFileSharingEnabled`-exposed Documents folder. Validating here as well as on ingest means
    /// the sink is safe even if a future caller forgets — defence at the boundary AND at the sink.
    private func cacheFileURL(aircraftId: String, suffix: String) -> URL? {
        guard AircraftRegistrationToken.isWellFormed(aircraftId) else {
            AppLog.aircraftData.debugLine("Refused unsafe aircraft id for a cache path")
            return nil
        }
        return cacheDirectory.appendingPathComponent("\(aircraftId)\(suffix)")
    }

    private func cacheChecklist(_ checklist: RemoteAircraftChecklist, aircraftId: String, checksum: String? = nil) {
        guard let path = cacheFileURL(aircraftId: aircraftId, suffix: ".json"),
              let metadataPath = cacheFileURL(aircraftId: aircraftId, suffix: ".metadata.json") else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(checklist)
            // At-rest protection, matching every other local write (DataPersistenceManager applies
            // the same options with an in-code SEC-12 comment about exactly this). The checklist
            // cache never adopted it. (SA-22)
            try data.write(to: path, options: DataPersistenceManager.protectedWriteOptions)

            // Also store metadata for cache validation
            let metadata = CacheMetadata(
                aircraftId: aircraftId,
                checksum: checksum,
                cachedAt: Date(),
                subscriptionVerifiedAt: Date(),
                contentHash: data.sha256Hex // SEC-C30
            )
            let metadataData = try encoder.encode(metadata)
            try metadataData.write(to: metadataPath, options: DataPersistenceManager.protectedWriteOptions)
        } catch {
            AppLog.aircraftData.debugLine("Failed to cache checklist: \(error)")
        }
    }

    private func loadCacheMetadata(aircraftId: String) -> CacheMetadata? {
        guard let path = cacheFileURL(aircraftId: aircraftId, suffix: ".metadata.json") else { return nil }

        guard fileManager.fileExists(atPath: path.path) else { return nil }

        do {
            let data = try Data(contentsOf: path)
            let decoder = JSONDecoder()
            return try decoder.decode(CacheMetadata.self, from: data)
        } catch {
            AppLog.aircraftData.debugLine("Failed to load cache metadata: \(error)")
            return nil
        }
    }

    private func loadCachedChecklist(aircraftId: String) -> RemoteAircraftChecklist? {
        guard let path = cacheFileURL(aircraftId: aircraftId, suffix: ".json"),
              fileManager.fileExists(atPath: path.path) else { return nil }

        do {
            let data = try Data(contentsOf: path)

            // SEC-C30: verify the bytes are the ones we wrote. The cache was previously
            // decode-and-trust: any file that happened to parse was served to the pilot as a
            // genuine checklist. A mismatch means the file was replaced or corrupted, so treat it
            // as absent — the caller re-downloads rather than displaying unverified procedures.
            if let expected = loadCacheMetadata(aircraftId: aircraftId)?.contentHash,
               expected != data.sha256Hex {
                AppLog.aircraftData.debugLine("Cached checklist failed integrity check; discarding")
                return nil
            }

            let decoder = JSONDecoder()
            return try decoder.decode(RemoteAircraftChecklist.self, from: data)
        } catch {
            AppLog.aircraftData.debugLine("Failed to load cached checklist: \(error)")
            return nil
        }
    }
}

// MARK: - Checklist Update Decision

/// Whether a cached checklist should be re-downloaded.
///
/// Extracted as a pure rule because it is the single point where a correct, deployed checklist
/// either reaches the pilot or silently does not — and it had no test until it failed in the field.
///
/// In the 2026-07 cycle, ten aircraft were corrected, merged and deployed, and every install kept
/// serving the old figures — including a stall speed that read LOW, so an aircraft in that band was
/// stalled and shown green. The old rule required BOTH checksums to be present and otherwise fell
/// back to comparing version strings. `version` mirrors the club document revision, so correcting
/// our transcription of an unchanged document does not move it; any install whose cache carried no
/// checksum was therefore permanently blind to content-only changes, while reporting itself
/// up to date.
enum ChecklistUpdateDecision {

    /// - Parameters:
    ///   - serverChecksum: content hash from `/version`; nil when the caller is not entitled to it.
    ///   - cachedChecksum: hash stored alongside the local copy; nil if it was cached without one.
    ///   - serverVersion: the server's version string (the club document revision).
    ///   - currentVersion: the local version string; empty when nothing is cached.
    static func needsUpdate(
        serverChecksum: String?,
        cachedChecksum: String?,
        serverVersion: String,
        currentVersion: String
    ) -> Bool {
        // The checksum is the only signal that reflects CONTENT, so it wins whenever the server
        // gives us one. A missing *cached* checksum means "unknown", NOT "up to date" — treating
        // nil as "differs" costs at most one redundant download per aircraft and is self-healing,
        // because that download stores a checksum.
        if let serverChecksum {
            return serverChecksum != cachedChecksum
        }
        // Nothing cached at all (e.g. a language newly offered by the API).
        if currentVersion.isEmpty {
            return true
        }
        // No checksum available (premium content without entitlement): the version string is all
        // there is, and content-only edits are invisible to it. That is why AeroCheck-checklists
        // enforces a version bump in CI (`scripts/check-version-bump.py`).
        return serverVersion != currentVersion
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
    /// SHA-256 of the checklist bytes as written by THIS app. (SEC-C30)
    ///
    /// Distinct from `checksum`, which is the server's value and is only ever compared against
    /// another server value to decide whether an update exists — it was never checked against the
    /// bytes actually on disk, so a cached checklist was decode-and-trust. Optional so caches
    /// written before this change still load (they simply skip verification once, then get a hash
    /// on the next refresh).
    var contentHash: String?
}

extension Data {
    /// Lowercase hex SHA-256, used for at-rest cache integrity. (SEC-C30)
    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
