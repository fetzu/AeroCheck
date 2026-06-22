import Foundation
import CoreLocation

/// On-disk metadata for the OpenAIP airport cache (per-country last-sync + count).
struct OpenAIPAirportCacheMetadata: Codable {
    var lastSyncDates: [String: Date] = [:]
    var counts: [String: Int] = [:]
}

/// Manages OpenAIP AIRPORT data via the keyless, per-country GeoJSON exports
/// (`storage.googleapis.com/.../{cc}_apt.geojson`) — a sibling to the other OpenAIP layer services.
/// Feeds `AirportDataMergeEngine` (OpenAIP is the primary airport source; OurAirports gap-fills). When
/// no OpenAIP airport data is downloaded, the merge is a no-op and OurAirports remains the backbone. (v4.1.0)
@MainActor
final class OpenAIPAirportDataService: ObservableObject {
    static let shared = OpenAIPAirportDataService()

    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadError: String?
    @Published var lastUpdated: Date?
    @Published var isDataAvailable = false
    @Published var airportCount = 0
    @Published var downloadedCountries: [String] = []
    @Published private(set) var isLoaded = false

    private var airports: [OpenAIPAirport] = []

    // MARK: - Storage

    private let fileManager = FileManager.default
    private var dataDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("OpenAIPAirportData", isDirectory: true)
    }
    private var metadataFileURL: URL { dataDirectory.appendingPathComponent("metadata.json") }
    private func airportFileURL(for country: String) -> URL {
        dataDirectory.appendingPathComponent("airports_\(country).json")
    }

    init() {
        if let data = try? Data(contentsOf: metadataFileURL),
           let metadata = try? JSONDecoder().decode(OpenAIPAirportCacheMetadata.self, from: data) {
            downloadedCountries = metadata.counts.keys.sorted()
            airportCount = metadata.counts.values.reduce(0, +)
            lastUpdated = metadata.lastSyncDates.values.max()
            isDataAvailable = !downloadedCountries.isEmpty
        }
    }

    /// Stale once older than the shared aeronautical-data TTL (90 days).
    var needsUpdate: Bool {
        guard let lastUpdated else { return true }
        return Date().timeIntervalSince(lastUpdated) > OpenAIPConfig.airspaceCacheExpirationInterval
    }

    // MARK: - Load

    func ensureLoaded() async {
        guard !isLoaded else { return }
        await loadFromLocal()
    }

    private func loadFromLocal() async {
        guard let metaData = try? Data(contentsOf: metadataFileURL),
              let metadata = try? JSONDecoder().decode(OpenAIPAirportCacheMetadata.self, from: metaData) else { return }
        let urls = metadata.counts.keys.map { airportFileURL(for: $0) }
        let loaded: [OpenAIPAirport] = await Task.detached(priority: .userInitiated) {
            let decoder = JSONDecoder()
            var all: [OpenAIPAirport] = []
            for url in urls {
                guard let data = try? Data(contentsOf: url),
                      let decoded = try? decoder.decode([OpenAIPAirport].self, from: data) else { continue }
                all.append(contentsOf: decoded)
            }
            return all
        }.value
        airports = loaded
        airportCount = loaded.count
        isLoaded = true
    }

    // MARK: - Download (keyless GeoJSON exports)

    func downloadData(for countries: [String]) async {
        guard !isDownloading, !countries.isEmpty else { return }
        isDownloading = true
        downloadProgress = 0
        downloadError = nil
        defer { isDownloading = false }

        try? fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        var metadata = (try? Data(contentsOf: metadataFileURL))
            .flatMap { try? JSONDecoder().decode(OpenAIPAirportCacheMetadata.self, from: $0) } ?? OpenAIPAirportCacheMetadata()
        var allLoaded: [OpenAIPAirport] = []

        for (index, country) in countries.enumerated() {
            let cc = country.lowercased()
            guard let url = URL(string: "\(OpenAIPConfig.geoJSONExportBaseURL)/\(cc)_apt.geojson") else { continue }
            do {
                let (data, response) = try await ExternalRequest.data(from: url)
                guard response.statusCode == 200 else {
                    appendExistingCache(for: country, into: &allLoaded)
                    continue
                }
                let parsed = try OpenAIPAirport.parse(geoJSON: data)
                let encoded = try JSONEncoder().encode(parsed)
                try encoded.write(to: airportFileURL(for: country), options: .atomic)
                metadata.counts[country] = parsed.count
                metadata.lastSyncDates[country] = Date()
                allLoaded.append(contentsOf: parsed)
            } catch {
                AppLog.openAIP.debugLine("OpenAIP airport download failed for \(country): \(error)")
                appendExistingCache(for: country, into: &allLoaded)
            }
            downloadProgress = Double(index + 1) / Double(countries.count)
        }

        // De-selected countries are pruned (file + metadata) so this layer matches the requested set —
        // consistent with the airspace layer; additive callers union first, so they lose nothing.
        // (download-integrity fix)
        OpenAIPConfig.pruneDeselectedCountries(
            keeping: countries, counts: &metadata.counts, lastSyncDates: &metadata.lastSyncDates,
            fileURL: { airportFileURL(for: $0) }, fileManager: fileManager)
        if let metaEncoded = try? JSONEncoder().encode(metadata) {
            try? metaEncoded.write(to: metadataFileURL, options: .atomic)
        }
        airports = allLoaded
        airportCount = allLoaded.count
        downloadedCountries = metadata.counts.keys.sorted()
        lastUpdated = metadata.lastSyncDates.values.max()
        isDataAvailable = !downloadedCountries.isEmpty
        isLoaded = true
    }

    private func appendExistingCache(for country: String, into accumulator: inout [OpenAIPAirport]) {
        if let data = try? Data(contentsOf: airportFileURL(for: country)),
           let decoded = try? JSONDecoder().decode([OpenAIPAirport].self, from: data) {
            accumulator.append(contentsOf: decoded)
        }
    }

    // MARK: - Queries

    /// All loaded OpenAIP airports — consumed by the merge engine. Call `ensureLoaded()` first.
    func allLoadedAirports() -> [OpenAIPAirport] { airports }

    func airportsInRegion(latRange: ClosedRange<Double>, lonRange: ClosedRange<Double>) -> [OpenAIPAirport] {
        airports.filter { latRange.contains($0.latitude) && lonRange.contains($0.longitude) }
    }

    func deleteData() {
        try? fileManager.removeItem(at: dataDirectory)
        airports = []
        airportCount = 0
        downloadedCountries = []
        lastUpdated = nil
        isDataAvailable = false
        isLoaded = false
    }

    #if DEBUG
    func seedForTesting(_ seeded: [OpenAIPAirport]) {
        airports = seeded
        airportCount = seeded.count
        isLoaded = true
    }
    #endif
}
