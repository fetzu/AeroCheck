import Foundation

/// Manages file-based data persistence in the app's Documents folder
/// Data is stored in the "AéroCheck" subfolder, making it visible in the Files app
@MainActor
class DataPersistenceManager: ObservableObject {
    // MARK: - Singleton

    static let shared = DataPersistenceManager()

    // MARK: - Directory Structure

    /// Root folder name visible in Files app
    private let appFolderName = "AéroCheck"

    /// Subfolder for flight logs (visible to user)
    private let flightsFolderName = "Flights"

    /// Subfolder for map tiles in Caches directory (local storage only, not synced)
    private let mapTilesFolderName = "Maps"

    /// Hidden settings file name (prefixed with dot to hide on macOS/Files app)
    private let settingsFileName = ".settings.json"

    /// File for storing all flights
    private let flightsFileName = "flights.json"

    // MARK: - UserDefaults Keys (for migration)

    private let legacyFlightsKey = "savedFlights"
    private let legacySettingsKey = "appSettings"
    private let migrationCompletedKey = "dataMigrationCompleted"

    // MARK: - Computed Properties

    /// Documents directory URL
    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Caches directory URL (for local-only data like map tiles)
    private var cachesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    /// App's root folder in Documents (visible in Files app as "AéroCheck")
    var appDirectory: URL {
        documentsDirectory.appendingPathComponent(appFolderName, isDirectory: true)
    }

    /// Flights folder URL
    var flightsDirectory: URL {
        appDirectory.appendingPathComponent(flightsFolderName, isDirectory: true)
    }

    /// Map tiles folder URL - stored in Caches directory for local-only storage
    /// This keeps map data under "On this iPhone" and prevents iCloud sync
    var mapTilesDirectory: URL {
        cachesDirectory.appendingPathComponent(appFolderName, isDirectory: true)
            .appendingPathComponent(mapTilesFolderName, isDirectory: true)
    }

    /// Settings file URL (hidden file in app directory)
    private var settingsFileURL: URL {
        appDirectory.appendingPathComponent(settingsFileName)
    }

    /// Flights data file URL
    private var flightsFileURL: URL {
        flightsDirectory.appendingPathComponent(flightsFileName)
    }

    // MARK: - Initialization

    private init() {
        createDirectoryStructure()
        migrateFromUserDefaultsIfNeeded()
    }

    // MARK: - Directory Management

    /// Creates the required directory structure
    private func createDirectoryStructure() {
        let fileManager = FileManager.default

        do {
            // Create main app folder
            try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)

            // Create Flights subfolder
            try fileManager.createDirectory(at: flightsDirectory, withIntermediateDirectories: true)

            // Create Maps subfolder
            try fileManager.createDirectory(at: mapTilesDirectory, withIntermediateDirectories: true)

            print("[AéroCheck] Directory structure created at: \(appDirectory.path)")
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
            try data.write(to: settingsFileURL, options: .atomic)
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

    // MARK: - Flights Persistence

    /// Save flights to file
    func saveFlights(_ flights: [Flight]) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(flights)
            try data.write(to: flightsFileURL, options: .atomic)
            print("[AéroCheck] Flights saved to file (\(flights.count) flights)")
        } catch {
            print("[AéroCheck] Failed to save flights: \(error.localizedDescription)")
        }
    }

    /// Load flights from file
    func loadFlights() -> [Flight] {
        guard FileManager.default.fileExists(atPath: flightsFileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: flightsFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let flights = try decoder.decode([Flight].self, from: data)
            print("[AéroCheck] Flights loaded from file (\(flights.count) flights)")
            return flights
        } catch {
            print("[AéroCheck] Failed to load flights: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Migration from UserDefaults

    /// Migrate data from UserDefaults to file-based storage
    private func migrateFromUserDefaultsIfNeeded() {
        let defaults = UserDefaults.standard

        // Check if migration was already completed
        if defaults.bool(forKey: migrationCompletedKey) {
            return
        }

        print("[AéroCheck] Starting data migration from UserDefaults...")

        var migrationSuccess = true

        // Migrate settings
        if let settingsData = defaults.data(forKey: legacySettingsKey) {
            do {
                let decoder = JSONDecoder()
                let settings = try decoder.decode(AppSettings.self, from: settingsData)
                saveSettings(settings)
                print("[AéroCheck] Settings migrated successfully")
            } catch {
                print("[AéroCheck] Failed to migrate settings: \(error.localizedDescription)")
                migrationSuccess = false
            }
        }

        // Migrate flights
        if let flightsData = defaults.data(forKey: legacyFlightsKey) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let flights = try decoder.decode([Flight].self, from: flightsData)
                saveFlights(flights)
                print("[AéroCheck] Flights migrated successfully (\(flights.count) flights)")
            } catch {
                print("[AéroCheck] Failed to migrate flights: \(error.localizedDescription)")
                migrationSuccess = false
            }
        }

        if migrationSuccess {
            // Mark migration as completed
            defaults.set(true, forKey: migrationCompletedKey)

            // Clean up old UserDefaults data (optional - keep for safety during transition)
            // defaults.removeObject(forKey: legacySettingsKey)
            // defaults.removeObject(forKey: legacyFlightsKey)

            print("[AéroCheck] Data migration completed successfully")
        } else {
            print("[AéroCheck] Data migration completed with errors")
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
