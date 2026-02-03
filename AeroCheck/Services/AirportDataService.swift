import Foundation
import CoreLocation

/// URLs for OurAirports data files
private enum OurAirportsURL {
    static let airports = "https://davidmegginson.github.io/ourairports-data/airports.csv"
    static let frequencies = "https://davidmegginson.github.io/ourairports-data/airport-frequencies.csv"
    static let runways = "https://davidmegginson.github.io/ourairports-data/runways.csv"
}

/// Service for managing OurAirports data
/// Downloads, caches, and queries airport/frequency/runway data
@MainActor
class AirportDataService: ObservableObject {
    // MARK: - Published Properties

    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadError: String?
    @Published var lastUpdated: Date?
    @Published var isDataAvailable: Bool = false
    @Published var airportCount: Int = 0

    // MARK: - Private Properties

    private var airports: [Airport] = []
    private var airportsByIdent: [String: Airport] = [:]
    private var frequenciesByAirport: [String: [AirportFrequency]] = [:]
    private var runwaysByAirport: [String: [Runway]] = [:]

    // File storage
    private let fileManager = FileManager.default
    private var dataDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AirportData", isDirectory: true)
    }

    private var airportsFileURL: URL { dataDirectory.appendingPathComponent("airports.json") }
    private var frequenciesFileURL: URL { dataDirectory.appendingPathComponent("frequencies.json") }
    private var runwaysFileURL: URL { dataDirectory.appendingPathComponent("runways.json") }
    private var metadataFileURL: URL { dataDirectory.appendingPathComponent("metadata.json") }

    // MARK: - Initialization

    init() {
        Task {
            await loadFromLocal()
        }
    }

    // MARK: - Public Methods

    /// Check if data needs updating (older than 90 days)
    var needsUpdate: Bool {
        guard let lastUpdate = lastUpdated else { return true }
        let daysSinceUpdate = Calendar.current.dateComponents([.day], from: lastUpdate, to: Date()).day ?? 0
        return daysSinceUpdate > 90
    }

    /// Download all airport data from OurAirports
    func downloadData() async {
        guard !isDownloading else { return }

        isDownloading = true
        downloadProgress = 0
        downloadError = nil

        do {
            // Ensure data directory exists
            try createDataDirectory()

            // Download and parse airports (largest file, ~10MB)
            downloadProgress = 0.05
            print("[AirportData] Downloading airports...")
            let airportsCSV = try await downloadCSV(from: OurAirportsURL.airports)
            downloadProgress = 0.35

            print("[AirportData] Parsing airports...")
            let parsedAirports = parseAirportsCSV(airportsCSV)
            downloadProgress = 0.45

            // Download and parse frequencies (~2MB)
            print("[AirportData] Downloading frequencies...")
            let frequenciesCSV = try await downloadCSV(from: OurAirportsURL.frequencies)
            downloadProgress = 0.55

            print("[AirportData] Parsing frequencies...")
            let parsedFrequencies = parseFrequenciesCSV(frequenciesCSV)
            downloadProgress = 0.65

            // Download and parse runways (~3MB)
            print("[AirportData] Downloading runways...")
            let runwaysCSV = try await downloadCSV(from: OurAirportsURL.runways)
            downloadProgress = 0.75

            print("[AirportData] Parsing runways...")
            let parsedRunways = parseRunwaysCSV(runwaysCSV)
            downloadProgress = 0.85

            // Save to local storage
            print("[AirportData] Saving to local storage...")
            try await saveToLocal(airports: parsedAirports, frequencies: parsedFrequencies, runways: parsedRunways)
            downloadProgress = 0.95

            // Update in-memory data
            self.airports = parsedAirports
            self.airportsByIdent = Dictionary(uniqueKeysWithValues: parsedAirports.map { ($0.ident, $0) })
            self.frequenciesByAirport = Dictionary(grouping: parsedFrequencies) { $0.airportIdent }
            self.runwaysByAirport = Dictionary(grouping: parsedRunways) { $0.airportIdent }
            self.airportCount = parsedAirports.count
            self.lastUpdated = Date()
            self.isDataAvailable = true

            downloadProgress = 1.0
            print("[AirportData] Download complete. \(parsedAirports.count) airports, \(parsedFrequencies.count) frequencies, \(parsedRunways.count) runways")

        } catch {
            downloadError = error.localizedDescription
            print("[AirportData] Download failed: \(error)")
        }

        isDownloading = false
    }

    /// Load data from local cache
    func loadFromLocal() async {
        guard fileManager.fileExists(atPath: airportsFileURL.path) else {
            print("[AirportData] No local data found")
            return
        }

        do {
            // Load metadata
            if let metadataData = try? Data(contentsOf: metadataFileURL),
               let metadata = try? JSONDecoder().decode(AirportDataMetadata.self, from: metadataData) {
                self.lastUpdated = metadata.lastUpdated
            }

            // Load airports
            let airportsData = try Data(contentsOf: airportsFileURL)
            let loadedAirports = try JSONDecoder().decode([Airport].self, from: airportsData)

            // Load frequencies
            var loadedFrequencies: [AirportFrequency] = []
            if let freqData = try? Data(contentsOf: frequenciesFileURL) {
                loadedFrequencies = (try? JSONDecoder().decode([AirportFrequency].self, from: freqData)) ?? []
            }

            // Load runways
            var loadedRunways: [Runway] = []
            if let runwayData = try? Data(contentsOf: runwaysFileURL) {
                loadedRunways = (try? JSONDecoder().decode([Runway].self, from: runwayData)) ?? []
            }

            // Update in-memory data
            self.airports = loadedAirports
            self.airportsByIdent = Dictionary(uniqueKeysWithValues: loadedAirports.map { ($0.ident, $0) })
            self.frequenciesByAirport = Dictionary(grouping: loadedFrequencies) { $0.airportIdent }
            self.runwaysByAirport = Dictionary(grouping: loadedRunways) { $0.airportIdent }
            self.airportCount = loadedAirports.count
            self.isDataAvailable = true

            print("[AirportData] Loaded from cache: \(loadedAirports.count) airports")

        } catch {
            print("[AirportData] Failed to load from cache: \(error)")
        }
    }

    /// Delete all cached data
    func deleteData() {
        do {
            if fileManager.fileExists(atPath: dataDirectory.path) {
                try fileManager.removeItem(at: dataDirectory)
            }
            airports = []
            airportsByIdent = [:]
            frequenciesByAirport = [:]
            runwaysByAirport = [:]
            airportCount = 0
            lastUpdated = nil
            isDataAvailable = false
            print("[AirportData] Data deleted")
        } catch {
            print("[AirportData] Failed to delete data: \(error)")
        }
    }

    // MARK: - Query Methods

    /// Find airport by ICAO identifier
    func findAirport(byIdent ident: String) -> Airport? {
        airportsByIdent[ident.uppercased()]
    }

    /// Search airports by name or identifier
    func searchAirports(query: String, limit: Int = 20) -> [Airport] {
        let searchTerm = query.lowercased()

        let results = airports.filter { airport in
            airport.ident.lowercased().contains(searchTerm) ||
            airport.name.lowercased().contains(searchTerm) ||
            (airport.iataCode?.lowercased().contains(searchTerm) ?? false) ||
            (airport.municipality?.lowercased().contains(searchTerm) ?? false)
        }

        // Sort by relevance: exact ICAO match first, then by name
        let sorted = results.sorted { a, b in
            if a.ident.lowercased() == searchTerm { return true }
            if b.ident.lowercased() == searchTerm { return false }
            if a.ident.lowercased().hasPrefix(searchTerm) && !b.ident.lowercased().hasPrefix(searchTerm) { return true }
            if !a.ident.lowercased().hasPrefix(searchTerm) && b.ident.lowercased().hasPrefix(searchTerm) { return false }
            return a.name < b.name
        }

        return Array(sorted.prefix(limit))
    }

    /// Find nearest airports to a coordinate
    func findNearestAirports(
        to coordinate: CLLocationCoordinate2D,
        limit: Int = 10,
        maxDistanceNm: Double? = nil,
        types: Set<AirportType>? = nil
    ) -> [Airport] {
        var filtered = airports

        // Filter by type if specified
        if let types = types {
            filtered = filtered.filter { types.contains($0.type) }
        }

        // Calculate distances and sort
        let withDistances = filtered.map { airport in
            (airport: airport, distance: airport.distance(from: coordinate))
        }

        var sorted = withDistances.sorted { $0.distance < $1.distance }

        // Filter by max distance if specified
        if let maxDist = maxDistanceNm {
            sorted = sorted.filter { $0.distance <= maxDist }
        }

        return Array(sorted.prefix(limit).map { $0.airport })
    }

    /// Get frequencies for an airport
    func getFrequencies(for airportIdent: String) -> [AirportFrequency] {
        frequenciesByAirport[airportIdent.uppercased()] ?? []
    }

    /// Get runways for an airport
    func getRunways(for airportIdent: String) -> [Runway] {
        runwaysByAirport[airportIdent.uppercased()] ?? []
    }

    /// Suggest the best runway based on wind direction
    func suggestRunway(for airport: Airport?, windDirection: Double?) -> Runway? {
        guard let airport = airport else { return nil }

        let runways = getRunways(for: airport.ident).filter { !$0.closed }

        guard !runways.isEmpty else { return nil }

        // If no wind info, return the longest runway
        guard let wind = windDirection else {
            return runways.max { ($0.lengthFt ?? 0) < ($1.lengthFt ?? 0) }
        }

        // Find runway with best headwind component
        var bestRunway: Runway?
        var bestHeadwind: Double = -.infinity

        for runway in runways {
            // Check low-end
            if let leHeading = runway.leHeadingDegT {
                let relativeAngle = abs(wind - leHeading)
                let normalizedAngle = min(relativeAngle, 360 - relativeAngle)
                let headwindComponent = cos(normalizedAngle * .pi / 180.0)

                if headwindComponent > bestHeadwind {
                    bestHeadwind = headwindComponent
                    bestRunway = runway
                }
            }

            // Check high-end
            if let heHeading = runway.heHeadingDegT {
                let relativeAngle = abs(wind - heHeading)
                let normalizedAngle = min(relativeAngle, 360 - relativeAngle)
                let headwindComponent = cos(normalizedAngle * .pi / 180.0)

                if headwindComponent > bestHeadwind {
                    bestHeadwind = headwindComponent
                    bestRunway = runway
                }
            }
        }

        return bestRunway
    }

    /// Get all airports in a bounding box (for map display)
    func getAirportsInRegion(
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double,
        types: Set<AirportType>? = nil,
        limit: Int = 500
    ) -> [Airport] {
        var filtered = airports.filter { airport in
            airport.latitude >= minLat && airport.latitude <= maxLat &&
            airport.longitude >= minLon && airport.longitude <= maxLon
        }

        if let types = types {
            filtered = filtered.filter { types.contains($0.type) }
        }

        // Prioritize larger airports if we need to limit
        if filtered.count > limit {
            filtered = filtered.sorted { a, b in
                // Large > Medium > Small > others
                let order: [AirportType] = [.largeAirport, .mediumAirport, .smallAirport]
                let aIndex = order.firstIndex(of: a.type) ?? order.count
                let bIndex = order.firstIndex(of: b.type) ?? order.count
                return aIndex < bIndex
            }
            filtered = Array(filtered.prefix(limit))
        }

        return filtered
    }

    // MARK: - Private Methods

    private func createDataDirectory() throws {
        if !fileManager.fileExists(atPath: dataDirectory.path) {
            try fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        }
    }

    private func downloadCSV(from urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        guard let csvString = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }

        return csvString
    }

    private func parseAirportsCSV(_ csv: String) -> [Airport] {
        let rows = parseCSV(csv)
        return rows.compactMap { Airport(csvRow: $0) }
    }

    private func parseFrequenciesCSV(_ csv: String) -> [AirportFrequency] {
        let rows = parseCSV(csv)
        return rows.compactMap { AirportFrequency(csvRow: $0) }
    }

    private func parseRunwaysCSV(_ csv: String) -> [Runway] {
        let rows = parseCSV(csv)
        return rows.compactMap { Runway(csvRow: $0) }
    }

    /// Parse CSV string into array of dictionaries
    private func parseCSV(_ csv: String) -> [[String: String]] {
        var results: [[String: String]] = []
        let lines = csv.components(separatedBy: .newlines)

        guard lines.count > 1 else { return results }

        // Parse header row
        let headers = parseCSVRow(lines[0])

        // Parse data rows
        for i in 1..<lines.count {
            let line = lines[i]
            guard !line.isEmpty else { continue }

            let values = parseCSVRow(line)
            guard values.count == headers.count else { continue }

            var row: [String: String] = [:]
            for (index, header) in headers.enumerated() {
                let value = values[index]
                // Only store non-empty values
                if !value.isEmpty {
                    row[header] = value
                }
            }
            results.append(row)
        }

        return results
    }

    /// Parse a single CSV row, handling quoted fields
    private func parseCSVRow(_ row: String) -> [String] {
        var results: [String] = []
        var current = ""
        var inQuotes = false

        for char in row {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                results.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        results.append(current)

        return results
    }

    private func saveToLocal(airports: [Airport], frequencies: [AirportFrequency], runways: [Runway]) async throws {
        let encoder = JSONEncoder()

        // Save airports
        let airportsData = try encoder.encode(airports)
        try airportsData.write(to: airportsFileURL)

        // Save frequencies
        let freqData = try encoder.encode(frequencies)
        try freqData.write(to: frequenciesFileURL)

        // Save runways
        let runwayData = try encoder.encode(runways)
        try runwayData.write(to: runwaysFileURL)

        // Save metadata
        let metadata = AirportDataMetadata(lastUpdated: Date(), airportCount: airports.count)
        let metadataData = try encoder.encode(metadata)
        try metadataData.write(to: metadataFileURL)
    }
}

// MARK: - Metadata

private struct AirportDataMetadata: Codable {
    let lastUpdated: Date
    let airportCount: Int
}
