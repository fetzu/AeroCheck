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
        apiBaseURL: String = "https://aerocheck-api.workers.dev",
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
            // Check if update is available in background
            Task {
                await checkForUpdate(aircraftId: aircraftId)
            }
            return cached
        }

        // Fetch from server
        do {
            let checklist = try await fetchChecklistFromServer(aircraftId: aircraftId)
            cacheChecklist(checklist, aircraftId: aircraftId)
            return checklist
        } catch {
            errorMessage = "Failed to fetch checklist: \(error.localizedDescription)"
            print("Failed to fetch checklist for \(aircraftId): \(error)")
            return nil
        }
    }

    /// Checks if an update is available for a checklist
    func checkForUpdate(aircraftId: String) async {
        guard let cached = loadCachedChecklist(aircraftId: aircraftId) else { return }

        do {
            let serverVersion = try await fetchVersion(aircraftId: aircraftId)

            if serverVersion.version != cached.version {
                // Update available, fetch new version
                if let updated = try? await fetchChecklistFromServer(aircraftId: aircraftId) {
                    cacheChecklist(updated, aircraftId: aircraftId)

                    // Notify that update is available
                    await MainActor.run {
                        // Update the metadata to reflect new version
                        if let index = availableAircraft.firstIndex(where: { $0.id == aircraftId }) {
                            availableAircraft[index].version = updated.version
                            availableAircraft[index].lastUpdated = updated.lastUpdated
                        }
                    }
                }
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

    /// Gets the cache date for a checklist
    func getCacheDate(aircraftId: String) -> Date? {
        let path = cacheDirectory.appendingPathComponent("\(aircraftId).json")
        guard let attributes = try? fileManager.attributesOfItem(atPath: path.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
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

    private func cacheChecklist(_ checklist: RemoteAircraftChecklist, aircraftId: String) {
        let path = cacheDirectory.appendingPathComponent("\(aircraftId).json")

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(checklist)
            try data.write(to: path)
        } catch {
            print("Failed to cache checklist: \(error)")
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
}
