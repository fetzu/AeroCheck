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

    // MARK: - Computed Properties

    /// Documents directory URL (local storage)
    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// iCloud Drive container URL (nil if iCloud not available)
    private var iCloudContainerURL: URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.fetzu.aerocheck")
    }

    /// iCloud Documents directory (visible in Files app as iCloud/AéroCheck)
    /// The NSUbiquitousContainerName in Info.plist sets the display name
    private var iCloudDocumentsURL: URL? {
        iCloudContainerURL?.appendingPathComponent("Documents", isDirectory: true)
    }

    /// Local Documents directory (On this iPhone/AéroCheck - the app name is shown by iOS)
    /// Note: iOS Files app shows the app's Documents folder with the app name,
    /// so we don't need to create an extra subfolder
    var localAppDirectory: URL {
        documentsDirectory
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

    /// Map tiles directory - always local (On this iPhone/AéroCheck/MapData)
    var mapTilesDirectory: URL {
        localAppDirectory.appendingPathComponent(mapDataFolderName, isDirectory: true)
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
        createDirectoryStructure()
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
            try data.write(to: fileURL, options: .atomic)
            
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
            try data.write(to: fileURL, options: .atomic)
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
            try data.write(to: fileURL, options: .atomic)
            
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
            try data.write(to: fileURL, options: .atomic)
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
