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

    /// When true, assigning `airports` does NOT rebuild the spatial grid — so a load-then-merge sequence
    /// that re-assigns `airports` twice rebuilds the ~40K-entry grid once, not twice, on `@MainActor`.
    /// Callers MUST rebuild once when clearing it (see `ensureLoaded`'s `defer`). (v4.1.0 pre-tag fix)
    private var suppressGridRebuild = false
    private var airports: [Airport] = [] {
        didSet { if !suppressGridRebuild { rebuildSpatialGrid() } }
    }
    private var airportsByIdent: [String: Airport] = [:]
    private var frequenciesByAirport: [String: [AirportFrequency]] = [:]
    private var runwaysByAirport: [String: [Runway]] = [:]

    // MARK: - Spatial index (PR-08)
    // A coarse lat/lon grid so a nearest-airport query touches only neighbouring cells instead of
    // scanning all ~40K airports (and allocating two CLLocation objects each) on every recorded GPS
    // point. Distances use haversine on the stored doubles — no CLLocation allocation.
    private struct GridKey: Hashable { let lat: Int; let lon: Int }
    private static let gridCellDegrees = 1.0   // ~60 nm of latitude per cell
    private var spatialGrid: [GridKey: [Airport]] = [:]

    private func gridKey(lat: Double, lon: Double) -> GridKey {
        // `Int(_:)` on a Double TRAPS on NaN or infinity — it does not return a sentinel — so a
        // single non-finite coordinate reaching here crashes the app rather than degrading. Every
        // sibling grid (navaids, obstacles, reporting points, airspaces) already uses the safe
        // helper; this one was never migrated. (CQ-08)
        GridKey(lat: ((lat / Self.gridCellDegrees).safeRoundedInt(.down, or: 0)),
                lon: ((lon / Self.gridCellDegrees).safeRoundedInt(.down, or: 0)))
    }

    private func rebuildSpatialGrid() {
        var grid: [GridKey: [Airport]] = [:]
        grid.reserveCapacity(airports.count / 4 + 1)
        // Skip invalid coordinates: `gridKey`'s `Int(...)` conversion TRAPS (hard crash) on NaN, infinity,
        // AND any finite value too large for Int (e.g. a corrupt `1e30` magnitude). A corrupt OurAirports
        // CSV (`Double("inf")`/`"nan"` parse successfully) would otherwise crash every user at load.
        // `CLLocationCoordinate2DIsValid` rejects all three (range -90…90 / -180…180, not-NaN). Universal
        // backstop; the OpenAIP ingest also drops these in AirportDataMergeEngine. (v4.1.0)
        for airport in airports where CLLocationCoordinate2DIsValid(airport.coordinate) {
            grid[gridKey(lat: airport.latitude, lon: airport.longitude), default: []].append(airport)
        }
        spatialGrid = grid
    }

    /// Great-circle distance in nautical miles (haversine on stored doubles, no allocation).
    private static func haversineNm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let earthRadiusNm = 3440.065
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusNm * asin(min(1, sqrt(a)))
    }

    // File storage
    private let fileManager = FileManager.default
    private var dataDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("AirportData", isDirectory: true)
    }

    private var airportsFileURL: URL { dataDirectory.appendingPathComponent("airports.json") }
    private var frequenciesFileURL: URL { dataDirectory.appendingPathComponent("frequencies.json") }
    private var runwaysFileURL: URL { dataDirectory.appendingPathComponent("runways.json") }
    private var metadataFileURL: URL { dataDirectory.appendingPathComponent("metadata.json") }

    /// Whether in-memory data has been loaded from disk
    private var isLoaded = false

    // MARK: - Initialization

    init() {
        // Defer loading until data is actually needed (flight start or map overlay)
        // to save ~20-30MB of memory at app startup.
        // Callers use ensureLoaded() to trigger loading on demand.

        // Check if data files exist on disk and restore metadata
        // without loading the full dataset into memory.
        // OpenAIP alone is a valid dataset: report data as available when EITHER source has something
        // on disk, so the UI offers its surfaces (and triggers `ensureLoaded`) rather than behaving as
        // if there were no airport data at all.
        if OpenAIPAirportDataService.shared.isDataAvailable {
            isDataAvailable = true
        }

        if fileManager.fileExists(atPath: airportsFileURL.path) {
            isDataAvailable = true
            if let metadataData = try? Data(contentsOf: metadataFileURL),
               let metadata = try? JSONDecoder().decode(AirportDataMetadata.self, from: metadataData) {
                lastUpdated = metadata.lastUpdated
                airportCount = metadata.airportCount
            }
        }
    }

    /// Load airport data into memory if not already loaded.
    /// Called automatically by query methods that need the data.
    func ensureLoaded() async {
        guard !isLoaded else { return }
        // Suppress the per-assignment grid rebuild across the load+merge, then rebuild exactly once on
        // exit (defer covers every path). Avoids building the full grid twice. (v4.1.0 pre-tag fix)
        suppressGridRebuild = true
        defer { suppressGridRebuild = false; rebuildSpatialGrid() }
        await loadFromLocal()
        await applyOpenAIPMergeIfAvailable()
    }

    /// OpenAIP is the primary airport source: whenever OpenAIP airport data is downloaded, fold it into
    /// the loaded backbone (identity + position + frequencies; OpenAIP wins on ICAO match within
    /// tolerance, OurAirports gap-fills). No-op when OpenAIP airport data isn't downloaded → OurAirports
    /// is the fallback. Re-sets `airports` (didSet rebuilds the spatial grid). Idempotent. (v4.1.0)
    func applyOpenAIPMergeIfAvailable() async {
        // NOT guarded on `!airports.isEmpty`. It used to be, which made OpenAIP unusable on its own:
        // with OurAirports absent this returned immediately, so a pilot who had downloaded OpenAIP
        // data for their country — and nothing else — got no airports and no frequencies at all,
        // silently. The merge engine has always appended OpenAIP-only airports (see its `else`
        // branch); it simply never ran. OurAirports is a backbone when present, not a precondition.
        await OpenAIPAirportDataService.shared.ensureLoaded()
        let oaip = OpenAIPAirportDataService.shared.allLoadedAirports()
        guard !oaip.isEmpty else { return }
        let merged = AirportDataMergeEngine.merge(ourAirports: airports, openAIP: oaip)
        airports = merged   // didSet rebuilds the spatial grid
        airportsByIdent = Dictionary(merged.map { ($0.ident, $0) }, uniquingKeysWith: { first, _ in first })
        airportCount = merged.count

        // OpenAIP-primary frequencies: UNION per airport — OpenAIP wins on a frequency-type conflict, but
        // OurAirports-only types (e.g. GND/ATIS the export omits) are kept rather than dropped. (review #2)
        let openAIPFreqsByIdent = Dictionary(grouping: AirportDataMergeEngine.openAIPFrequencies(from: oaip)) {
            $0.airportIdent
        }
        for (ident, openAIPFreqs) in openAIPFreqsByIdent {
            let openAIPTypes = Set(openAIPFreqs.map { $0.type })
            let keptOurAirports = (frequenciesByAirport[ident] ?? []).filter { !openAIPTypes.contains($0.type) }
            frequenciesByAirport[ident] = openAIPFreqs + keptOurAirports
        }

        // OpenAIP-primary runways: UNION per airport — OpenAIP wins on a runway-identifier match (e.g.
        // "10/28"), but OurAirports-only runways (the ~62% of airports OpenAIP lacks) are kept. Mirrors
        // the frequency merge, so no runway data is ever lost. (v4.1.0 runway merge)
        let openAIPRwysByIdent = Dictionary(grouping: AirportDataMergeEngine.openAIPRunways(from: oaip)) {
            $0.airportIdent
        }
        for (ident, openAIPRwys) in openAIPRwysByIdent {
            runwaysByAirport[ident] = AirportDataMergeEngine.unionRunways(
                our: runwaysByAirport[ident] ?? [], openAIP: openAIPRwys)
        }
        // Queryable data now exists, whatever its source. Every frequency/airport surface in the app
        // gates on this flag, and it used to be set only by OurAirports — so even once the merge
        // above ran, an OpenAIP-only dataset stayed invisible to the UI.
        if !merged.isEmpty { isDataAvailable = true }

        AppLog.airportData.debugLine("OpenAIP-primary merge applied: \(merged.count) airports, \(openAIPFreqsByIdent.count) airports got OpenAIP frequencies, \(openAIPRwysByIdent.count) got OpenAIP runways")

        // The raw OpenAIP array has now been folded into `airports`, `frequenciesByAirport` and
        // `runwaysByAirport`, and nothing reads it again — so drop it instead of keeping a second
        // full copy of the country dataset resident for the process lifetime. (APP-16)
        OpenAIPAirportDataService.shared.releaseLoadedAirports()
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
            AppLog.airportData.debugLine("Downloading airports...")
            let airportsCSV = try await downloadCSV(from: OurAirportsURL.airports)
            downloadProgress = 0.35

            AppLog.airportData.debugLine("Parsing airports...")
            let parsedAirports = await Task.detached(priority: .userInitiated) {
                AirportDataService.parseAirportsCSV(airportsCSV)
            }.value
            downloadProgress = 0.45

            // PR-29: a captive portal (typical airfield/hotel Wi-Fi) returns HTTP 200 with an HTML
            // login page; the CSV parser silently drops every mismatched row, yielding ~0 airports.
            // Abort before saveToLocal/replacing in-memory state so a bad download can't destroy the
            // existing ~40K-airport cache (the real file has tens of thousands of rows). Existing
            // files and in-memory state are left untouched; the catch surfaces downloadError.
            guard parsedAirports.count >= 1000 else {
                throw NSError(domain: "AirportData", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Airport data download looked invalid (\(parsedAirports.count) airports parsed — your connection may be redirecting to a login page). Your existing airport data was kept."])
            }

            // Download and parse frequencies (~2MB)
            AppLog.airportData.debugLine("Downloading frequencies...")
            let frequenciesCSV = try await downloadCSV(from: OurAirportsURL.frequencies)
            downloadProgress = 0.55

            AppLog.airportData.debugLine("Parsing frequencies...")
            let parsedFrequencies = await Task.detached(priority: .userInitiated) {
                AirportDataService.parseFrequenciesCSV(frequenciesCSV)
            }.value
            downloadProgress = 0.65

            // Download and parse runways (~3MB)
            AppLog.airportData.debugLine("Downloading runways...")
            let runwaysCSV = try await downloadCSV(from: OurAirportsURL.runways)
            downloadProgress = 0.75

            AppLog.airportData.debugLine("Parsing runways...")
            let parsedRunways = await Task.detached(priority: .userInitiated) {
                AirportDataService.parseRunwaysCSV(runwaysCSV)
            }.value
            downloadProgress = 0.85

            // Save to local storage
            AppLog.airportData.debugLine("Saving to local storage...")
            try await saveToLocal(airports: parsedAirports, frequencies: parsedFrequencies, runways: parsedRunways)
            downloadProgress = 0.95

            // Update in-memory data
            self.airports = parsedAirports
            // Tolerate duplicate idents in source data (keep first) rather than trapping.
            self.airportsByIdent = Dictionary(parsedAirports.map { ($0.ident, $0) }, uniquingKeysWith: { first, _ in first })
            self.frequenciesByAirport = Dictionary(grouping: parsedFrequencies) { $0.airportIdent }
            self.runwaysByAirport = Dictionary(grouping: parsedRunways) { $0.airportIdent }
            self.airportCount = parsedAirports.count
            self.lastUpdated = Date()
            self.isDataAvailable = true
            self.isLoaded = true

            downloadProgress = 1.0
            AppLog.airportData.debugLine("Download complete. \(parsedAirports.count) airports, \(parsedFrequencies.count) frequencies, \(parsedRunways.count) runways")

            await applyOpenAIPMergeIfAvailable()

        } catch {
            downloadError = error.localizedDescription
            AppLog.airportData.debugLine("Download failed: \(error)")
        }

        isDownloading = false
    }

    /// Load data from local cache
    func loadFromLocal() async {
        guard fileManager.fileExists(atPath: airportsFileURL.path) else {
            AppLog.airportData.debugLine("No local data found")
            isLoaded = true // Mark as attempted to avoid repeated checks
            return
        }

        // Read + JSON-decode the ~40K-row cache off the main actor; only the decoded value-type
        // results hop back for assignment. (PERF-07)
        let airportsURL = airportsFileURL
        let frequenciesURL = frequenciesFileURL
        let runwaysURL = runwaysFileURL
        let metadataURL = metadataFileURL

        let loaded: AirportCacheLoad? = await Task.detached(priority: .userInitiated) {
            do {
                let lastUpdated = (try? Data(contentsOf: metadataURL))
                    .flatMap { try? JSONDecoder().decode(AirportDataMetadata.self, from: $0) }?
                    .lastUpdated

                let airportsData = try Data(contentsOf: airportsURL)
                let airports = try JSONDecoder().decode([Airport].self, from: airportsData)

                let frequencies = (try? Data(contentsOf: frequenciesURL))
                    .flatMap { try? JSONDecoder().decode([AirportFrequency].self, from: $0) } ?? []
                let runways = (try? Data(contentsOf: runwaysURL))
                    .flatMap { try? JSONDecoder().decode([Runway].self, from: $0) } ?? []

                return AirportCacheLoad(
                    airports: airports, frequencies: frequencies,
                    runways: runways, lastUpdated: lastUpdated
                )
            } catch {
                AppLog.airportData.debugLine("Failed to load from cache: \(error)")
                return nil
            }
        }.value

        if let loaded {
            if let lastUpdated = loaded.lastUpdated { self.lastUpdated = lastUpdated }
            self.airports = loaded.airports
            self.airportsByIdent = Dictionary(loaded.airports.map { ($0.ident, $0) }, uniquingKeysWith: { first, _ in first })
            self.frequenciesByAirport = Dictionary(grouping: loaded.frequencies) { $0.airportIdent }
            self.runwaysByAirport = Dictionary(grouping: loaded.runways) { $0.airportIdent }
            self.airportCount = loaded.airports.count
            self.isDataAvailable = true
            AppLog.airportData.debugLine("Loaded from cache: \(loaded.airports.count) airports")
        }
        self.isLoaded = true
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
            isLoaded = false
            AppLog.airportData.debugLine("Data deleted")
        } catch {
            AppLog.airportData.debugLine("Failed to delete data: \(error)")
        }
    }

    // MARK: - Query Methods

    /// Find airport by ICAO identifier
    func findAirport(byIdent ident: String) -> Airport? {
        airportsByIdent[ident.uppercased()]
    }

    /// Search airports by name or identifier
    /// Search airports by ICAO/IATA/name/municipality.
    /// - Parameters:
    ///   - near: when provided, results are ordered by distance to this coordinate *within* each
    ///     relevance tier (exact ICAO → ICAO prefix → other), so a typed identifier still wins but
    ///     otherwise the closest fields float to the top (flight-plan builder feedback #2).
    ///   - types: when provided, only these airport types are returned. The builder passes
    ///     `AirportType.fixedWing` to drop heliports/seaplane/closed/balloon results (feedback #3 —
    ///     see CLAUDE.md "Re-enabling heliports" to surface rotorcraft sites again).
    func searchAirports(
        query: String,
        limit: Int = 20,
        near reference: CLLocationCoordinate2D? = nil,
        types: Set<AirportType>? = nil
    ) -> [Airport] {
        let searchTerm = query.lowercased()

        var results = airports.filter { airport in
            airport.ident.lowercased().contains(searchTerm) ||
            airport.name.lowercased().contains(searchTerm) ||
            (airport.iataCode?.lowercased().contains(searchTerm) ?? false) ||
            (airport.municipality?.lowercased().contains(searchTerm) ?? false)
        }
        if let types = types {
            results = results.filter { types.contains($0.type) }
        }

        // Relevance tier: exact ICAO match, then ICAO prefix, then everything else.
        func tier(_ a: Airport) -> Int {
            let id = a.ident.lowercased()
            if id == searchTerm { return 0 }
            if id.hasPrefix(searchTerm) { return 1 }
            return 2
        }

        let sorted: [Airport]
        if let reference = reference {
            // Precompute (tier, distance) once per candidate, then order by tier → distance → name.
            let scored = results.map { airport -> (airport: Airport, tier: Int, distance: Double) in
                (airport, tier(airport),
                 Self.haversineNm(lat1: reference.latitude, lon1: reference.longitude,
                                  lat2: airport.latitude, lon2: airport.longitude))
            }
            sorted = scored.sorted { a, b in
                if a.tier != b.tier { return a.tier < b.tier }
                if a.distance != b.distance { return a.distance < b.distance }
                return a.airport.name < b.airport.name
            }.map { $0.airport }
        } else {
            sorted = results.sorted { a, b in
                let ta = tier(a), tb = tier(b)
                if ta != tb { return ta < tb }
                return a.name < b.name
            }
        }

        return Array(sorted.prefix(limit))
    }

    /// Find nearest airports to a coordinate.
    /// PR-08: queries only the neighbouring grid cells (expanding rings) instead of scanning all
    /// ~40K airports, and computes distance with haversine on doubles — this runs on every recorded
    /// GPS point, so the old full scan + 80K CLLocation allocations per call was a per-tick cost.
    func findNearestAirports(
        to coordinate: CLLocationCoordinate2D,
        limit: Int = 10,
        maxDistanceNm: Double? = nil,
        types: Set<AirportType>? = nil
    ) -> [Airport] {
        guard !airports.isEmpty else { return [] }
        let lat = coordinate.latitude
        let lon = coordinate.longitude
        let center = gridKey(lat: lat, lon: lon)

        // Safety cap on how far out we search (~8° ≈ 480 nm) so a query in an empty ocean region
        // doesn't sweep the whole grid. With a maxDistance, derive the exact ring needed (≈60 nm per
        // degree latitude) plus a one-cell margin; without one, expand until we have enough.
        let cappedRing = 8
        let neededRing: Int? = maxDistanceNm.map {
            min(cappedRing, max(1, Int(($0 / 60.0 / Self.gridCellDegrees).rounded(.up)) + 1))
        }

        var candidates: [Airport] = []
        var ring = 0
        while ring <= cappedRing {
            for dLat in -ring...ring {
                for dLon in -ring...ring {
                    // Only the perimeter of the current ring (inner cells already gathered).
                    if ring > 0 && abs(dLat) != ring && abs(dLon) != ring { continue }
                    if let cell = spatialGrid[GridKey(lat: center.lat + dLat, lon: center.lon + dLon)] {
                        candidates.append(contentsOf: cell)
                    }
                }
            }
            if let neededRing {
                if ring >= neededRing { break }
            } else if candidates.count >= limit && ring >= 1 {
                break
            }
            ring += 1
        }

        var typed = candidates
        if let types = types {
            typed = typed.filter { types.contains($0.type) }
        }

        var scored = typed.map { airport in
            (airport: airport, distance: Self.haversineNm(lat1: lat, lon1: lon, lat2: airport.latitude, lon2: airport.longitude))
        }
        scored.sort { $0.distance < $1.distance }
        if let maxDist = maxDistanceNm {
            scored = scored.filter { $0.distance <= maxDist }
        }
        return Array(scored.prefix(limit).map { $0.airport })
    }

    /// Nearest single airport within a distance cap — used by the flight-plan builder to snap a dragged
    /// waypoint to an airfield on release (flight-plan revamp #3). Returns nil if nothing qualifies.
    func nearestAirport(
        to coordinate: CLLocationCoordinate2D,
        maxDistanceNm: Double,
        types: Set<AirportType>? = nil
    ) -> Airport? {
        findNearestAirports(to: coordinate, limit: 1, maxDistanceNm: maxDistanceNm, types: types).first
    }

    /// Get frequencies for an airport
    func getFrequencies(for airportIdent: String) -> [AirportFrequency] {
        frequenciesByAirport[airportIdent.uppercased()] ?? []
    }

    /// The order a VFR pilot would actually contact a field on: its tower, else its own
    /// advisory/info frequency (AFIS / INFO / air-to-ground / CTAF / UNICOM / radio). Area-control
    /// frequencies (APP, DEP, CNTR) and listen-only ATIS are deliberately NOT field-contact freqs —
    /// an uncontrolled field's AFIS must win over a distant approach controller. (Shared by the HUD
    /// NEAREST strip and the Navigation FREQ panel so they can't drift.)
    nonisolated static let fieldContactPriority = ["TWR", "AFIS", "INFO", "A/G", "CTAF", "UNIC", "RDO"]

    /// The single most relevant field-contact frequency for an airport, or nil if it has none at all.
    func bestFieldFrequency(for airportIdent: String) -> AirportFrequency? {
        Self.pickFieldContact(from: getFrequencies(for: airportIdent))
    }

    /// Pure pick (no I/O — unit-testable): the most relevant field-contact frequency from a list.
    /// Picks by `fieldContactPriority`; falls back to ATIS, then any published frequency, so a field
    /// that only has an approach/area freq still shows something rather than nothing.
    nonisolated static func pickFieldContact(from freqs: [AirportFrequency]) -> AirportFrequency? {
        guard !freqs.isEmpty else { return nil }
        for type in fieldContactPriority {
            if let match = freqs.first(where: { $0.type.uppercased().contains(type) }) { return match }
        }
        return freqs.first(where: { $0.type.uppercased().contains("ATIS") }) ?? freqs.first
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
        guard !airports.isEmpty, minLat <= maxLat, minLon <= maxLon else { return [] }

        // Gather only the grid cells overlapping the bbox instead of scanning all ~40K airports on
        // every map region change. Cells are gridCellDegrees wide; key = floor(coord / cellDegrees).
        let minLatKey = Int((minLat / Self.gridCellDegrees).rounded(.down))
        let maxLatKey = Int((maxLat / Self.gridCellDegrees).rounded(.down))
        let minLonKey = Int((minLon / Self.gridCellDegrees).rounded(.down))
        let maxLonKey = Int((maxLon / Self.gridCellDegrees).rounded(.down))

        var candidates: [Airport] = []
        for latKey in minLatKey...maxLatKey {
            for lonKey in minLonKey...maxLonKey {
                if let cell = spatialGrid[GridKey(lat: latKey, lon: lonKey)] {
                    candidates.append(contentsOf: cell)
                }
            }
        }

        // Cells are coarse (~60 nm), so still apply the exact bbox bounds.
        var filtered = candidates.filter { airport in
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
            DataPersistenceManager.excludeFromBackup(dataDirectory) // SEC-C28
        }
    }

    private func downloadCSV(from urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        // Route through ExternalRequest for a request timeout + retry/backoff. Use the shared session
        // so the large (~MB) airport CSV isn't cut off by a tight resource deadline on slow links.
        let (data, httpResponse) = try await ExternalRequest.data(from: url, session: .shared)

        guard httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        guard let csvString = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }

        return csvString
    }

    // The CSV parsers are `nonisolated static` pure functions (no instance/UI state) so the
    // ~40K-row parse can run inside `Task.detached` off the main actor — only the value-type
    // results (Sendable structs) hop back to the MainActor for assignment. (PERF-07)
    nonisolated static func parseAirportsCSV(_ csv: String) -> [Airport] {
        parseCSV(csv).compactMap { Airport(csvRow: $0) }
    }

    nonisolated static func parseFrequenciesCSV(_ csv: String) -> [AirportFrequency] {
        parseCSV(csv).compactMap { AirportFrequency(csvRow: $0) }
    }

    nonisolated static func parseRunwaysCSV(_ csv: String) -> [Runway] {
        parseCSV(csv).compactMap { Runway(csvRow: $0) }
    }

    /// Parse CSV string into array of dictionaries
    nonisolated static func parseCSV(_ csv: String) -> [[String: String]] {
        var results: [[String: String]] = []
        let lines = csv.components(separatedBy: .newlines)

        guard lines.count > 1 else { return results }

        // Parse header row
        let headers = parseCSVRow(lines[0])
        results.reserveCapacity(lines.count)

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

    /// Parse a single CSV row, handling quoted fields.
    /// Slices the row into per-field substrings (one allocation per field) instead of appending
    /// character-by-character into an accumulator String — the same quote-stripping / unquoted-
    /// comma-splitting semantics as before, but far fewer allocations across ~40K rows. (PERF-07)
    nonisolated static func parseCSVRow(_ row: String) -> [String] {
        var results: [String] = []
        var fieldStart = row.startIndex
        var inQuotes = false
        var fieldHadQuotes = false
        var i = row.startIndex

        while i < row.endIndex {
            let char = row[i]
            if char == "\"" {
                inQuotes.toggle()
                fieldHadQuotes = true
            } else if char == "," && !inQuotes {
                results.append(Self.csvField(row[fieldStart..<i], hadQuotes: fieldHadQuotes))
                i = row.index(after: i)
                fieldStart = i
                fieldHadQuotes = false
                continue
            }
            i = row.index(after: i)
        }
        results.append(Self.csvField(row[fieldStart..<row.endIndex], hadQuotes: fieldHadQuotes))

        return results
    }

    /// Materializes one CSV field, stripping quote characters only when the field contained any
    /// (preserving the previous parser's behavior of removing all `"`).
    private nonisolated static func csvField(_ slice: Substring, hadQuotes: Bool) -> String {
        hadQuotes ? String(slice.filter { $0 != "\"" }) : String(slice)
    }

    private func saveToLocal(airports: [Airport], frequencies: [AirportFrequency], runways: [Runway]) async throws {
        // Encode + write the large arrays off the main actor (atomically). (PERF-07)
        let airportsURL = airportsFileURL
        let frequenciesURL = frequenciesFileURL
        let runwaysURL = runwaysFileURL
        let metadataURL = metadataFileURL
        let airportCount = airports.count

        try await Task.detached(priority: .userInitiated) {
            let encoder = JSONEncoder()
            try encoder.encode(airports).write(to: airportsURL, options: .atomic)
            try encoder.encode(frequencies).write(to: frequenciesURL, options: .atomic)
            try encoder.encode(runways).write(to: runwaysURL, options: .atomic)

            let metadata = AirportDataMetadata(lastUpdated: Date(), airportCount: airportCount)
            try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
        }.value
    }
}

// MARK: - Cache load result

/// Decoded airport cache produced off the main actor, then assigned on the MainActor. (PERF-07)
private struct AirportCacheLoad: Sendable {
    let airports: [Airport]
    let frequencies: [AirportFrequency]
    let runways: [Runway]
    let lastUpdated: Date?
}

// MARK: - Metadata

private struct AirportDataMetadata: Codable {
    let lastUpdated: Date
    let airportCount: Int
}
