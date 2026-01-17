import Foundation

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

    // MARK: - Private Properties

    private let apiBaseURL: String
    private let subscriptionManager: SubscriptionManager
    private let cacheDirectory: URL
    private let fileManager = FileManager.default

    // MARK: - Initialization

    init(
        apiBaseURL: String = "https://api.aerocheck.app",
        subscriptionManager: SubscriptionManager
    ) {
        self.apiBaseURL = apiBaseURL
        self.subscriptionManager = subscriptionManager

        // Set up cache directory
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.cacheDirectory = appSupport.appendingPathComponent("AeroCheck/Checklists", isDirectory: true)

        // Create cache directory if needed
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        // Load cached data first
        loadCachedMetadata()
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
    }

    /// Fetches a specific aircraft checklist
    func fetchChecklist(for aircraftId: String) async -> RemoteAircraftChecklist? {
        // Check cache first
        if let cached = loadCachedChecklist(aircraftId: aircraftId) {
            // Check if cache is still valid (24 hours)
            if isCacheValid(aircraftId: aircraftId) {
                print("[AircraftDataService] Using cached checklist for \(aircraftId)")

                // Check if update is available in background (don't block)
                Task {
                    await checkForUpdate(aircraftId: aircraftId)
                }
                return cached
            } else {
                print("[AircraftDataService] Cache expired for \(aircraftId), checking for updates")
                // Cache expired - check for update using checksum
                await checkForUpdate(aircraftId: aircraftId)
                // Return the (possibly updated) cached checklist
                if let updated = loadCachedChecklist(aircraftId: aircraftId) {
                    return updated
                }
            }
        }

        // Fetch from server
        do {
            // First get version info for checksum
            let versionInfo = try? await fetchVersion(aircraftId: aircraftId)
            let checklist = try await fetchChecklistFromServer(aircraftId: aircraftId)
            cacheChecklist(checklist, aircraftId: aircraftId, checksum: versionInfo?.checksum)
            print("[AircraftDataService] Cached fresh checklist for \(aircraftId)")
            return checklist
        } catch {
            // If offline and we have cached data (even if expired), use it
            if let cached = loadCachedChecklist(aircraftId: aircraftId) {
                print("[AircraftDataService] Using expired cache for \(aircraftId) (offline)")
                errorMessage = "Using cached data (offline)"
                return cached
            }

            errorMessage = "Failed to fetch checklist: \(error.localizedDescription)"
            print("Failed to fetch checklist for \(aircraftId): \(error)")
            return nil
        }
    }

    /// Checks if an update is available for a checklist using checksum comparison
    func checkForUpdate(aircraftId: String) async {
        guard loadCachedChecklist(aircraftId: aircraftId) != nil else { return }
        let cachedMetadata = loadCacheMetadata(aircraftId: aircraftId)

        do {
            let serverVersion = try await fetchVersion(aircraftId: aircraftId)

            // Compare checksums if available, otherwise fall back to version comparison
            let needsUpdate: Bool
            if let serverChecksum = serverVersion.checksum,
               let cachedChecksum = cachedMetadata?.checksum {
                needsUpdate = serverChecksum != cachedChecksum
            } else {
                // Fallback to version comparison if checksums not available
                let cachedChecklist = loadCachedChecklist(aircraftId: aircraftId)
                needsUpdate = serverVersion.version != cachedChecklist?.version
            }

            if needsUpdate {
                print("[AircraftDataService] Update available for \(aircraftId), downloading...")
                // Update available, fetch new version
                if let updated = try? await fetchChecklistFromServer(aircraftId: aircraftId) {
                    cacheChecklist(updated, aircraftId: aircraftId, checksum: serverVersion.checksum)

                    // Notify that update is available
                    await MainActor.run {
                        // Update the metadata to reflect new version
                        if let index = availableAircraft.firstIndex(where: { $0.id == aircraftId }) {
                            availableAircraft[index].version = updated.version
                            availableAircraft[index].lastUpdated = updated.lastUpdated
                        }
                    }
                }
            } else {
                print("[AircraftDataService] Checklist for \(aircraftId) is up to date")
            }
        } catch {
            print("Failed to check for update: \(error)")
        }
    }

    /// Syncs all cached checklists with the server
    func syncAllChecklists() async {
        for aircraft in availableAircraft where aircraft.hasAccess {
            await checkForUpdate(aircraftId: aircraft.id)
        }
        lastSyncDate = Date()
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

    /// Gets all cached aircraft (combines remote and bundled)
    func getAllCachedAircraft() -> [CachedAircraftInfo] {
        var cached: [CachedAircraftInfo] = []

        // Add bundled aircraft
        for aircraft in AircraftType.allCases {
            cached.append(CachedAircraftInfo(
                registration: aircraft.registration,
                modelName: aircraft.shortModelName,
                version: aircraft.checklistVersion,
                lastUpdated: aircraft.lastUpdated,
                isPremium: false
            ))
        }

        // Add remote aircraft that are cached
        for aircraft in availableAircraft where isChecklistCached(aircraftId: aircraft.id) {
            // Load the cached checklist to get the actual lastUpdated value
            if let cachedChecklist = loadCachedChecklist(aircraftId: aircraft.id) {
                cached.append(CachedAircraftInfo(
                    registration: aircraft.registration,
                    modelName: aircraft.shortModelName,
                    version: cachedChecklist.version,
                    lastUpdated: cachedChecklist.lastUpdated,
                    isPremium: !aircraft.isFree
                ))
            }
        }

        return cached
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
    func validatePremiumCaches(subscriptionManager: SubscriptionManager) -> Bool {
        guard subscriptionManager.shouldAllowPremiumAccess() else {
            print("[AircraftDataService] Subscription access revoked, clearing premium caches")
            clearPremiumCaches()
            return false
        }
        return true
    }

    // MARK: - Private Methods

    private func fetchAircraftList() async throws -> [RemoteAircraftMetadata] {
        let url = URL(string: "\(apiBaseURL)/api/v1/aircraft/available")!

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Add auth header if available
        if let userID = await subscriptionManager.getUserID() {
            request.setValue("Bearer \(userID)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AircraftDataError.serverError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let decoder = JSONDecoder()
        let result = try decoder.decode(AircraftListResponse.self, from: data)

        return result.data.aircraft
    }

    private func fetchChecklistFromServer(aircraftId: String) async throws -> RemoteAircraftChecklist {
        let url = URL(string: "\(apiBaseURL)/api/v1/aircraft/\(aircraftId)/checklist")!

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Add auth header if available
        if let userID = await subscriptionManager.getUserID() {
            request.setValue("Bearer \(userID)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

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

    private func fetchVersion(aircraftId: String) async throws -> VersionInfo {
        let url = URL(string: "\(apiBaseURL)/api/v1/aircraft/\(aircraftId)/version")!

        let (data, response) = try await URLSession.shared.data(from: url)

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
    let version: String
    let lastUpdated: String
    let isPremium: Bool
}

// MARK: - Error Types

enum AircraftDataError: LocalizedError {
    case serverError(Int)
    case accessDenied
    case notFound
    case invalidResponse
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
