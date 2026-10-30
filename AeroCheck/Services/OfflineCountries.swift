import Foundation

/// A country as Settings › Offline data lists it: everything AéroCheck has for it, downloaded together. A pilot thinks
/// "I fly in Switzerland and sometimes France", not "I need airspace, obstacles and an Atlas region" (the author's
/// answers 1 A to 3 A, 30 Oct 2026). (6.8.0)
struct OfflineCountry: Identifiable, Equatable {
    /// ISO 3166-1 alpha-2.
    let id: String
    let name: String
    /// The Atlas's regions in the country, by name; one for most countries, none where the Atlas has none yet.
    let atlasRegions: [PilotMapRegion]
    /// OpenAIP publishes the country's airspace, aerodromes, navaids, obstacles and reporting points.
    let hasAeronauticalData: Bool
    /// Open flightmaps publishes its circuits and VFR routes.
    let hasVFRProcedures: Bool

    /// The Swiss charts (swisstopo's ICAO and glider charts) belong to Switzerland's page.
    var hasSwissCharts: Bool { id == "CH" }
    /// A country in several Atlas regions opens its page, where a pilot takes all of it or the regions they fly.
    var isInRegions: Bool { atlasRegions.count > 1 }
}

/// The countries a pilot can download, and what is on the device per country. Pure: the services' state comes in
/// as arguments, so the tests can drive it. (6.8.0)
enum OfflineCountryCatalog {

    /// Every country OpenAIP publishes or the Atlas has a region of, alphabetically in the app's language.
    static func countries(atlasRegions: [PilotMapRegion], vfrCountries: Set<String>,
                          name: (String) -> String = OpenAIPConfig.countryName(for:)) -> [OfflineCountry] {
        let openAIP = Set(OpenAIPConfig.continents.flatMap(\.countries))
        let byCountry = Dictionary(grouping: atlasRegions.filter { $0.id != PilotMapRegion.overviewID },
                                   by: country(of:))
        let codes = openAIP.union(byCountry.keys.compactMap { $0 })
        return codes.map { code in
            OfflineCountry(id: code, name: name(code),
                           atlasRegions: (byCountry[code] ?? [])
                               .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending },
                           hasAeronauticalData: openAIP.contains(code),
                           hasVFRProcedures: vfrCountries.contains(code))
        }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// A region's country: the index's, or its id when that is a country code (indexes before the worldwide regions).
    static func country(of region: PilotMapRegion) -> String? {
        if let country = region.country { return country.uppercased() }
        return region.id.count == 2 ? region.id.uppercased() : nil
    }

    /// The countries on the device: those whose aeronautical data is kept, those with an Atlas region downloaded, and
    /// Switzerland when its charts are.
    static func onDevice(aeronautical: Set<String>, atlasDownloaded: [PilotMapRegion], swissCharts: Bool) -> Set<String> {
        var codes = aeronautical
        for region in atlasDownloaded where region.id != PilotMapRegion.overviewID {
            if let code = country(of: region) { codes.insert(code) }
        }
        if swissCharts { codes.insert("CH") }
        return codes
    }

    /// The home country: the home aerodrome's, else the device's region.
    static func home(homeIdent: String?, locale: Locale = .current) -> String? {
        ICAOCountry.country(of: homeIdent) ?? locale.region?.identifier
    }

    /// Whether OpenAIP's continents put the country in Europe; the Atlas's extra countries go under Elsewhere.
    static func isInEurope(_ code: String) -> Bool {
        OpenAIPConfig.continents.first { $0.id == "europe" }?.countries.contains(code) ?? false
    }

    /// A search on the country's name and its regions' names.
    static func matches(_ country: OfflineCountry, _ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        func has(_ text: String) -> Bool { text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return has(country.name) || has(country.id) || country.atlasRegions.contains { has($0.displayName) }
    }

    /// What one press on the country fetches: its Atlas regions not on the device, and its aeronautical data when not
    /// kept (OpenAIP's own rough figure: about 5 MB a country, less where little is published).
    static func bytesToFetch(_ country: OfflineCountry, downloadedRegions: Set<String>, aeronauticalKept: Bool) -> Int64 {
        let atlas = country.atlasRegions.filter { !downloadedRegions.contains($0.id) }.reduce(0) { $0 + $1.downloadBytes }
        let data: Int64 = country.hasAeronauticalData && !aeronauticalKept ? 5_000_000 : 0
        return Int64(atlas) + data
    }

    /// The flag, from the two regional-indicator letters.
    static func flag(_ code: String) -> String {
        code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value).map(String.init) }.joined()
    }

    // MARK: - On disk

    /// The per-country files of the aeronautical layers: each service's directory and the prefix of its
    /// `<prefix>_<CC>.json`.
    static let aeronauticalFiles: [(directory: String, prefix: String)] = [
        ("OpenAIPData", "airspaces"),
        ("OpenAIPNavaidData", "navaids"),
        ("OpenAIPObstacleData", "obstacles"),
        ("OpenAIPReportingPointData", "reportingpoints"),
        (OpenAIPAirportDataService.directoryName, "airports"),
    ]

    /// The bytes each country's aeronautical data and VFR procedures take, by country; reads file sizes only.
    static func bytesOnDisk(base: URL? = FileManager.default.urls(for: .applicationSupportDirectory,
                                                                  in: .userDomainMask).first) -> OfflineCountrySizes {
        guard let base else { return OfflineCountrySizes() }
        func sizes(_ directory: String, _ prefix: String) -> [String: Int64] {
            let dir = base.appendingPathComponent(directory, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            var result: [String: Int64] = [:]
            for file in files {
                let name = file.deletingPathExtension().lastPathComponent
                guard file.pathExtension == "json", name.hasPrefix(prefix + "_") else { continue }
                let code = String(name.dropFirst(prefix.count + 1)).uppercased()
                guard code.count == 2 else { continue }
                result[code, default: 0] += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return result
        }
        var aeronautical: [String: Int64] = [:]
        for (directory, prefix) in aeronauticalFiles {
            aeronautical.merge(sizes(directory, prefix), uniquingKeysWith: +)
        }
        return OfflineCountrySizes(aeronautical: aeronautical, vfr: sizes(OFMDataService.directoryName, "ofm"))
    }
}

/// The bytes on the device per country, for the rows: read off the main thread when a page appears.
struct OfflineCountrySizes: Equatable, Sendable {
    var aeronautical: [String: Int64] = [:]
    var vfr: [String: Int64] = [:]

    static func read() async -> OfflineCountrySizes {
        await Task.detached(priority: .utility) { OfflineCountryCatalog.bytesOnDisk() }.value
    }
}

/// What the device holds for one country, for its row and its page.
struct OfflineCountryHolding: Equatable {
    let country: OfflineCountry
    /// Its aeronautical data is kept (the selection, or fetched for a trip).
    let aeronautical: Bool
    let vfr: Bool
    /// Its Atlas regions on the device.
    let atlasDownloaded: [PilotMapRegion]
    /// The ICAO or the glider chart is on the device (Switzerland).
    let swissCharts: Bool
    let bytes: Int64

    var isOnDevice: Bool { aeronautical || vfr || !atlasDownloaded.isEmpty || swissCharts }

    /// The Atlas regions still to download.
    var atlasMissing: [PilotMapRegion] {
        let here = Set(atlasDownloaded.map(\.id))
        return country.atlasRegions.filter { !here.contains($0.id) }
    }
}

/// Every country's holding, from the services' state at one moment.
struct OfflineDataSnapshot {
    let countries: [OfflineCountry]
    let kept: Set<String>
    let vfrKept: Set<String>
    /// The countries being added: listed with the others while their data downloads.
    let adding: Set<String>
    let downloadedRegions: [PilotMapRegion]
    let swissCharts: Bool
    let swissChartBytes: Int64
    let sizes: OfflineCountrySizes

    func holding(_ country: OfflineCountry) -> OfflineCountryHolding {
        let atlas = downloadedRegions.filter {
            $0.id != PilotMapRegion.overviewID && OfflineCountryCatalog.country(of: $0) == country.id
        }
        let charts = country.hasSwissCharts && swissCharts
        let bytes = Int64(atlas.reduce(0) { $0 + $1.downloadBytes })
            + (sizes.aeronautical[country.id] ?? 0) + (sizes.vfr[country.id] ?? 0) + (charts ? swissChartBytes : 0)
        return OfflineCountryHolding(country: country, aeronautical: kept.contains(country.id),
                                     vfr: vfrKept.contains(country.id), atlasDownloaded: atlas,
                                     swissCharts: charts, bytes: bytes)
    }

    func country(_ code: String) -> OfflineCountry? { countries.first { $0.id == code } }

    /// The countries with anything on the device, by name.
    var onDevice: [OfflineCountryHolding] {
        let codes = OfflineCountryCatalog.onDevice(aeronautical: kept.union(vfrKept), atlasDownloaded: downloadedRegions,
                                                   swissCharts: swissCharts).union(adding)
        return countries.filter { codes.contains($0.id) }.map(holding)
    }
}

/// Adds and removes countries' aeronautical data: the five OpenAIP layers and open flightmaps' procedures, for the
/// countries kept. One sync at a time: a country added while one runs is fetched by the next, as the services ignore
/// a request while they download. (6.8.0)
@MainActor
final class OfflineCountryDownloads: ObservableObject {
    static let shared = OfflineCountryDownloads()

    @Published private(set) var isSyncing = false
    /// The countries the running or next sync was asked for that it doesn't hold yet: their rows say "Downloading".
    @Published private(set) var adding: Set<String> = []

    private var wanted: [String]?
    private var airspace: OpenAIPDataService?
    private var navaids: OpenAIPNavaidDataService?

    /// The countries whose aeronautical data is kept: the selection, and any a trip or an older version fetched.
    static func kept(selection: [String], airspace: OpenAIPDataService, vfr: OFMDataService) -> Set<String> {
        Set(selection).union(airspace.downloadedCountries).union(vfr.downloadedCountries)
    }

    /// One more country: its aeronautical data with the others kept.
    func add(_ code: String, appState: AppState, airspace: OpenAIPDataService, navaids: OpenAIPNavaidDataService) {
        add([code], appState: appState, airspace: airspace, navaids: navaids)
    }

    /// Several countries in one sync: onboarding's chosen ones.
    func add(_ codes: [String], appState: AppState, airspace: OpenAIPDataService, navaids: OpenAIPNavaidDataService) {
        guard !codes.isEmpty else { return }
        let countries = Self.kept(selection: appState.settings.openAIPOfflineCountries, airspace: airspace,
                                  vfr: .shared).union(codes).sorted()
        adding.formUnion(codes)
        save(countries, appState: appState)
        sync(countries, airspace: airspace, navaids: navaids)
    }

    /// One country less: its aeronautical data and VFR procedures dropped, the others kept. The last one deletes the
    /// layers outright, as a layer asked for no country does nothing rather than remove everything.
    func remove(_ code: String, appState: AppState, airspace: OpenAIPDataService, navaids: OpenAIPNavaidDataService) {
        let countries = Self.kept(selection: appState.settings.openAIPOfflineCountries, airspace: airspace,
                                  vfr: .shared).subtracting([code]).sorted()
        adding.remove(code)
        save(countries, appState: appState)
        if countries.isEmpty {
            wanted = nil
            airspace.deleteData()
            navaids.deleteData()
            OpenAIPObstacleDataService.shared.deleteData()
            OpenAIPReportingPointDataService.shared.deleteData()
            OpenAIPAirportDataService.shared.deleteData()
            OFMDataService.shared.deleteData()
        } else {
            sync(countries, airspace: airspace, navaids: navaids)
        }
    }

    private func save(_ countries: [String], appState: AppState) {
        appState.settings.openAIPOfflineCountries = countries
        appState.saveSettings()
    }

    private func sync(_ countries: [String], airspace: OpenAIPDataService, navaids: OpenAIPNavaidDataService) {
        wanted = countries
        self.airspace = airspace
        self.navaids = navaids
        guard !isSyncing else { return }
        isSyncing = true
        Task {
            while let next = wanted, let airspace = self.airspace, let navaids = self.navaids {
                wanted = nil
                await Self.syncLayers(next, airspace: airspace, navaids: navaids)
                adding.subtract(airspace.downloadedCountries)
                adding.subtract(airspace.failedCountries)
            }
            adding = []
            isSyncing = false
        }
    }

    /// Every layer brought to `countries`: a layer that holds exactly them is updated, every country fetched again;
    /// one that differs takes only what it lacks and drops what isn't asked for. Open flightmaps compares each
    /// file's hash already. Lifted from the OpenAIP Data page. (6.2.0, 6.5.0, 6.8.0)
    static func syncLayers(_ countries: [String], airspace: OpenAIPDataService, navaids: OpenAIPNavaidDataService) async {
        guard !countries.isEmpty else { return }
        let obstacles = OpenAIPObstacleDataService.shared
        let points = OpenAIPReportingPointDataService.shared
        let aerodromes = OpenAIPAirportDataService.shared
        let procedures = OFMDataService.shared
        let selection = Set(countries)
        func onlyChanges(_ downloaded: [String]) -> Bool { Set(downloaded) != selection }
        let airspaceOnly = onlyChanges(airspace.downloadedCountries)
        let navaidsOnly = onlyChanges(navaids.downloadedCountries)
        let obstaclesOnly = onlyChanges(obstacles.downloadedCountries)
        let pointsOnly = onlyChanges(points.downloadedCountries)
        let aerodromesOnly = onlyChanges(aerodromes.downloadedCountries)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await airspace.downloadData(for: countries, skippingCached: airspaceOnly) }
            group.addTask { await navaids.downloadData(for: countries, skippingCached: navaidsOnly) }
            group.addTask { await obstacles.downloadData(for: countries, skippingCached: obstaclesOnly) }
            group.addTask { await points.downloadData(for: countries, skippingCached: pointsOnly) }
            group.addTask { await aerodromes.downloadData(for: countries, skippingCached: aerodromesOnly) }
            group.addTask { await procedures.downloadData(for: countries) }
            await group.waitForAll()
        }
    }
}
