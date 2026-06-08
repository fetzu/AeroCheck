import Foundation

/// Manages file-based data persistence
/// - Flights and NavigationPlans: Stored in iCloud Drive (visible in Files app under iCloud/AéroCheck/)
/// - Settings: Stored in iCloud Drive (synced automatically)
/// - Map Cache: Stored locally in Documents (not synced)
@MainActor
class DataPersistenceManager: ObservableObject {
    // MARK: - Singleton

    static let shared = DataPersistenceManager()

    // MARK: - Directory Structure

    /// Folder name for the app in local storage
    private let appFolderName = "AéroCheck"

    /// Subfolder for flight logs
    private let flightsFolderName = "Flights"

    /// Subfolder for navigation plans
    private let navigationPlansFolderName = "NavigationPlans"

    /// Subfolder for map tiles (local only)
    private let mapDataFolderName = "MapData"

    /// Settings file name (in iCloud Documents root)
    private let settingsFileName = "settings.json"

    /// Index file for tracking all flights
    private let flightsIndexFileName = "flights_index.json"

    /// Index file for tracking all navigation plans
    private let plansIndexFileName = "plans_index.json"

    // MARK: - Cached Properties

    /// At-rest protection for the local datastore: encrypts files but still permits the
    /// background GPS app to write while the device is locked (after the first unlock since boot).
    /// (SEC-12)
    static let protectedWriteOptions: Data.WritingOptions = [
        .atomic, .completeFileProtectionUntilFirstUserAuthentication,
    ]

    /// Documents directory URL — retained only as the **migration source** and for exports.
    /// `UIFileSharingEnabled` exposes this folder, so the working datastore no longer lives here.
    private let documentsDirectory: URL

    /// Non-browsable local datastore root in Application Support. Sensitive working data (flights,
    /// plans, settings, map tiles, the crash-recovery checkpoint) lives here instead of the
    /// file-sharing-exposed Documents directory. (SEC-12)
    private let applicationSupportDirectory: URL

    /// iCloud Drive container URL (nil if iCloud not available) - cached at init
    /// IMPORTANT: FileManager.url(forUbiquityContainerIdentifier:) can block the main thread
    /// for seconds when iCloud is initializing. We call it once at init and cache the result.
    private let iCloudContainerURL: URL?

    /// iCloud Documents directory (visible in Files app as iCloud/AéroCheck)
    private let iCloudDocumentsURL: URL?

    /// Local app data directory (non-browsable Application Support, not the exposed Documents root).
    var localAppDirectory: URL {
        applicationSupportDirectory
    }

    /// Flights directory - directly in iCloud Documents (visible as iCloud/AéroCheck/Flights)
    var flightsDirectory: URL {
        if let iCloudDocs = iCloudDocumentsURL {
            return iCloudDocs.appendingPathComponent(flightsFolderName, isDirectory: true)
        }
        return localAppDirectory.appendingPathComponent(flightsFolderName, isDirectory: true)
    }

    /// Navigation plans directory - directly in iCloud Documents (visible as iCloud/AéroCheck/NavigationPlans)
    var navigationPlansDirectory: URL {
        if let iCloudDocs = iCloudDocumentsURL {
            return iCloudDocs.appendingPathComponent(navigationPlansFolderName, isDirectory: true)
        }
        return localAppDirectory.appendingPathComponent(navigationPlansFolderName, isDirectory: true)
    }

    /// Map tiles directory — kept in local Documents (On this iPhone/AéroCheck/MapData).
    /// Map tiles are non-sensitive **public** chart cache (not personal data), so they stay put:
    /// relocating them is unnecessary for SEC-12 and would orphan an existing tile cache (and the
    /// hardcoded Documents/MapData path in OfflineMapManager). Only sensitive flight/plan/settings
    /// data moves to Application Support.
    var mapTilesDirectory: URL {
        documentsDirectory.appendingPathComponent(mapDataFolderName, isDirectory: true)
    }

    /// Settings file URL - in iCloud Documents if available, otherwise local
    private var settingsFileURL: URL {
        if let iCloudDocs = iCloudDocumentsURL {
            return iCloudDocs.appendingPathComponent(settingsFileName)
        }
        return localAppDirectory.appendingPathComponent(settingsFileName)
    }

    /// Whether iCloud is available
    var isICloudAvailable: Bool {
        iCloudContainerURL != nil
    }

    // MARK: - Initialization

    private init() {
        // Cache directory URLs once to avoid repeated calls to
        // url(forUbiquityContainerIdentifier:) which blocks the main thread
        self.documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        let appSupportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.applicationSupportDirectory = appSupportRoot.appendingPathComponent(appFolderName, isDirectory: true)
        self.iCloudContainerURL = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.fetzu.aerocheck")
        self.iCloudDocumentsURL = self.iCloudContainerURL?.appendingPathComponent("Documents", isDirectory: true)

        // One-time relocation of any existing local-fallback data out of the exposed Documents
        // root into Application Support, BEFORE creating the (possibly-overlapping) new dirs. (SEC-12)
        migrateLocalDatastoreIfNeeded()

        createDirectoryStructure()
    }

    /// Migration flag key. Bump the suffix if the datastore layout changes again.
    private static let migrationFlagKey = "datastoreMigratedToApplicationSupport_v1"

    /// Moves any pre-existing local datastore items from the Documents root (the old location) into
    /// Application Support exactly once. Safe and idempotent: an item is moved only if it exists at
    /// the source and is absent at the destination, so a partial/interrupted run never loses data.
    private func migrateLocalDatastoreIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.migrationFlagKey) else { return }
        Self.migrateLocalDatastore(
            from: documentsDirectory,
            to: applicationSupportDirectory,
            fileManager: FileManager.default
        )
        defaults.set(true, forKey: Self.migrationFlagKey)
    }

    /// Pure, testable migration: moves each known datastore item from `oldBase` to `newBase` when
    /// it exists at the source and is absent at the destination. Returns the count moved.
    @discardableResult
    nonisolated static func migrateLocalDatastore(
        from oldBase: URL,
        to newBase: URL,
        fileManager: FileManager
    ) -> Int {
        // Only sensitive personal data is relocated. Map tiles (MapData) are non-sensitive public
        // cache and deliberately stay in Documents.
        let items = [
            "Flights", "NavigationPlans",
            "settings.json", "flights_index.json", "plans_index.json", "active_flight.json",
        ]
        try? fileManager.createDirectory(at: newBase, withIntermediateDirectories: true)
        var moved = 0
        for item in items {
            let src = oldBase.appendingPathComponent(item)
            let dst = newBase.appendingPathComponent(item)
            guard fileManager.fileExists(atPath: src.path),
                  !fileManager.fileExists(atPath: dst.path) else { continue }
            do {
                try fileManager.moveItem(at: src, to: dst)
                moved += 1
            } catch {
                print("[AéroCheck] Datastore migration: failed to move \(item): \(error.localizedDescription)")
            }
        }
        if moved > 0 {
            print("[AéroCheck] Datastore migration: moved \(moved) item(s) to Application Support")
        }
        return moved
    }

    // MARK: - Directory Management

    /// Creates the required directory structure
    private func createDirectoryStructure() {
        let fileManager = FileManager.default

        do {
            // Create map data folder (local only - On this iPhone/AéroCheck/MapData)
            try fileManager.createDirectory(at: mapTilesDirectory, withIntermediateDirectories: true)

            // Create iCloud Documents directory if available
            if let iCloudDocs = iCloudDocumentsURL {
                try fileManager.createDirectory(at: iCloudDocs, withIntermediateDirectories: true)
            }

            // Create flights and navigation plans folders (iCloud or local)
            try fileManager.createDirectory(at: flightsDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: navigationPlansDirectory, withIntermediateDirectories: true)

            if isICloudAvailable {
                print("[AéroCheck] Directory structure created with iCloud at: \(flightsDirectory.path)")
            } else {
                print("[AéroCheck] Directory structure created locally at: \(localAppDirectory.path)")
            }
        } catch {
            print("[AéroCheck] Failed to create directory structure: \(error.localizedDescription)")
        }
    }

    // MARK: - Settings Persistence

    /// Save settings to file
    func saveSettings(_ settings: AppSettings) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: settingsFileURL, options: Self.protectedWriteOptions)
            print("[AéroCheck] Settings saved to file")
        } catch {
            print("[AéroCheck] Failed to save settings: \(error.localizedDescription)")
        }
    }

    /// Load settings from file
    func loadSettings() -> AppSettings? {
        guard FileManager.default.fileExists(atPath: settingsFileURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: settingsFileURL)
            let decoder = JSONDecoder()
            let settings = try decoder.decode(AppSettings.self, from: data)
            print("[AéroCheck] Settings loaded from file")
            return settings
        } catch {
            print("[AéroCheck] Failed to load settings: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Active Flight Checkpoint (crash recovery)

    /// Local (non-synced) crash-recovery checkpoint for the in-progress flight.
    /// Kept local on purpose: it must be readable immediately at next launch on *this* device
    /// and must never wait on iCloud. It is cleared once the flight ends and the real flight
    /// file is written. (PERF-02 / PERF-13)
    var activeFlightStateURL: URL {
        localAppDirectory.appendingPathComponent("active_flight.json")
    }

    /// Atomically writes the active-flight checkpoint. Declared `nonisolated static` so the
    /// encode/write can run off the main actor during a long flight — only `Data` and `URL`
    /// (both Sendable) cross the actor boundary.
    nonisolated static func writeActiveFlightStateData(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: Self.protectedWriteOptions)
    }

    /// Reads the raw active-flight checkpoint, or nil if none exists.
    func loadActiveFlightStateData() -> Data? {
        guard FileManager.default.fileExists(atPath: activeFlightStateURL.path) else {
            return nil
        }
        return try? Data(contentsOf: activeFlightStateURL)
    }

    /// Whether a crash-recovery checkpoint file exists.
    var hasActiveFlightStateFile: Bool {
        FileManager.default.fileExists(atPath: activeFlightStateURL.path)
    }

    /// Removes the crash-recovery checkpoint (flight ended / cancelled / restored).
    func clearActiveFlightStateFile() {
        try? FileManager.default.removeItem(at: activeFlightStateURL)
    }

    // MARK: - Flight Persistence (Individual Files)

    /// Generate filename for a flight: YYYYMMDD-HHMM_PLANE.json
    func flightFilename(for flight: Flight) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let dateStr = formatter.string(from: flight.startTime ?? flight.stopTime ?? Date())
        let plane = flight.airplane.replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
        return "\(dateStr)_\(plane).json"
    }

    /// Save a single flight to its own file
    func saveFlight(_ flight: Flight) {
        let fileURL = flightsDirectory.appendingPathComponent(flightFilename(for: flight))

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(flight)
            try data.write(to: fileURL, options: Self.protectedWriteOptions)
            
            print("[AéroCheck] Flight saved: \(flightFilename(for: flight))")
        } catch {
            print("[AéroCheck] Failed to save flight: \(error.localizedDescription)")
        }
    }

    /// Save all flights (saves each to individual file and updates index)
    func saveFlights(_ flights: [Flight]) {
        // Save each flight to its own file
        for flight in flights {
            saveFlight(flight)
        }

        // Save index file for tracking
        saveFlightsIndex(flights)
    }

    /// Save flights index (list of flight IDs and filenames)
    private func saveFlightsIndex(_ flights: [Flight]) {
        let index = flights.map { FlightIndexEntry(id: $0.id, filename: flightFilename(for: $0)) }
        let fileURL = flightsDirectory.appendingPathComponent(flightsIndexFileName)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(index)
            try data.write(to: fileURL, options: Self.protectedWriteOptions)
        } catch {
            print("[AéroCheck] Failed to save flights index: \(error.localizedDescription)")
        }
    }

    /// Load all flights from individual files
    func loadFlights() -> [Flight] {
        var flights: [Flight] = []
        let fileManager = FileManager.default

        // Ensure directory exists
        guard fileManager.fileExists(atPath: flightsDirectory.path) else {
            return []
        }

        do {
            let files = try fileManager.contentsOfDirectory(at: flightsDirectory, includingPropertiesForKeys: nil)
            let jsonFiles = files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.contains("index") }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            for fileURL in jsonFiles {
                do {
                    let data = try Data(contentsOf: fileURL)
                    let flight = try decoder.decode(Flight.self, from: data)
                    flights.append(flight)
                } catch {
                    print("[AéroCheck] Failed to load flight \(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
            }

            // Sort by start time (newest first)
            flights.sort { ($0.startTime ?? .distantPast) > ($1.startTime ?? .distantPast) }
            print("[AéroCheck] Loaded \(flights.count) flights from iCloud")
        } catch {
            print("[AéroCheck] Failed to enumerate flights directory: \(error.localizedDescription)")
        }

        return flights
    }

    /// Delete a flight file
    func deleteFlight(_ flight: Flight) {
        let fileURL = flightsDirectory.appendingPathComponent(flightFilename(for: flight))

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
                print("[AéroCheck] Deleted flight: \(flightFilename(for: flight))")
            }
        } catch {
            print("[AéroCheck] Failed to delete flight: \(error.localizedDescription)")
        }
    }

    // MARK: - Navigation Plan Persistence (Individual Files)

    /// Generate filename for a navigation plan: YYYYMMDD-HHMM_NAME.json
    func navigationPlanFilename(for plan: FlightPlan) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let dateStr = formatter.string(from: plan.createdAt)
        let name = plan.name.isEmpty ? "Plan" : plan.name
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
            .prefix(20)
        return "\(dateStr)_\(name).json"
    }

    /// Save a single navigation plan to its own file
    func saveNavigationPlan(_ plan: FlightPlan) {
        let fileURL = navigationPlansDirectory.appendingPathComponent(navigationPlanFilename(for: plan))

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(plan)
            try data.write(to: fileURL, options: Self.protectedWriteOptions)
            
            print("[AéroCheck] Navigation plan saved: \(navigationPlanFilename(for: plan))")
        } catch {
            print("[AéroCheck] Failed to save navigation plan: \(error.localizedDescription)")
        }
    }

    /// Save all navigation plans (saves each to individual file and updates index)
    func saveNavigationPlans(_ plans: [FlightPlan]) {
        // Save each plan to its own file
        for plan in plans {
            saveNavigationPlan(plan)
        }

        // Save index file for tracking
        saveNavigationPlansIndex(plans)
    }

    /// Save navigation plans index
    private func saveNavigationPlansIndex(_ plans: [FlightPlan]) {
        let index = plans.map { NavigationPlanIndexEntry(id: $0.id, filename: navigationPlanFilename(for: $0)) }
        let fileURL = navigationPlansDirectory.appendingPathComponent(plansIndexFileName)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(index)
            try data.write(to: fileURL, options: Self.protectedWriteOptions)
        } catch {
            print("[AéroCheck] Failed to save navigation plans index: \(error.localizedDescription)")
        }
    }

    /// Load all navigation plans from individual files
    func loadNavigationPlans() -> [FlightPlan] {
        var plans: [FlightPlan] = []
        let fileManager = FileManager.default

        // Ensure directory exists
        guard fileManager.fileExists(atPath: navigationPlansDirectory.path) else {
            return []
        }

        do {
            let files = try fileManager.contentsOfDirectory(at: navigationPlansDirectory, includingPropertiesForKeys: nil)
            let jsonFiles = files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.contains("index") }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            for fileURL in jsonFiles {
                do {
                    let data = try Data(contentsOf: fileURL)
                    let plan = try decoder.decode(FlightPlan.self, from: data)
                    plans.append(plan)
                } catch {
                    print("[AéroCheck] Failed to load navigation plan \(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
            }

            // Sort by creation date (newest first)
            plans.sort { $0.createdAt > $1.createdAt }
            print("[AéroCheck] Loaded \(plans.count) navigation plans from iCloud")
        } catch {
            print("[AéroCheck] Failed to enumerate navigation plans directory: \(error.localizedDescription)")
        }

        return plans
    }

    /// Delete a navigation plan file
    func deleteNavigationPlan(_ plan: FlightPlan) {
        let fileURL = navigationPlansDirectory.appendingPathComponent(navigationPlanFilename(for: plan))

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
                print("[AéroCheck] Deleted navigation plan: \(navigationPlanFilename(for: plan))")
            }
        } catch {
            print("[AéroCheck] Failed to delete navigation plan: \(error.localizedDescription)")
        }
    }

    // MARK: - Map Tiles Directory

    /// Get directory for ICAO map tiles
    var icaoMapTilesDirectory: URL {
        mapTilesDirectory.appendingPathComponent("ICAO", isDirectory: true)
    }

    /// Get directory for Segelflug map tiles
    var segelflugMapTilesDirectory: URL {
        mapTilesDirectory.appendingPathComponent("Segelflug", isDirectory: true)
    }
}

// MARK: - Index Entry Types

/// Entry in the flights index file
struct FlightIndexEntry: Codable {
    let id: UUID
    let filename: String
}

/// Entry in the navigation plans index file
struct NavigationPlanIndexEntry: Codable {
    let id: UUID
    let filename: String
}
