import XCTest
@testable import AeroCheck

/// Settings › Offline data by country (6.8.0): the catalog of countries, what is on the device per country, the
/// groups of Add a country, and the bytes each country takes on the device.
@MainActor
final class OfflineCountriesTests: XCTestCase {

    private static func region(_ id: String, country: String?, name: String? = nil, bytes: Int = 10) -> PilotMapRegion {
        PilotMapRegion(id: id, name: name ?? id, bounds: [0, 0, 1, 1], built: "20261027", mapBytes: bytes,
                       reliefBytes: 0, country: country)
    }

    private static let atlas = [
        region("ch", country: "CH", name: "Switzerland and Liechtenstein", bytes: 88),
        region("fr-bre", country: "FR", name: "Brittany", bytes: 36),
        region("fr-ara", country: "FR", name: "Auvergne-Rhône-Alpes", bytes: 93),
        region("fr-ges", country: "FR", name: "Grand Est", bytes: 49),
        region("xk", country: nil, name: "Kosovo", bytes: 5),
        region(PilotMapRegion.overviewID, country: nil, name: "Overview", bytes: 43),
    ]

    private static func catalog() -> [OfflineCountry] {
        OfflineCountryCatalog.countries(atlasRegions: atlas, vfrCountries: ["CH", "FR"], name: { $0 })
    }

    // MARK: - Catalog

    func testCatalogJoinsOpenAIPsCountriesAndTheAtlasesWithTheRegionsByName() throws {
        let countries = Self.catalog()
        let france = try XCTUnwrap(countries.first { $0.id == "FR" })
        XCTAssertEqual(france.atlasRegions.map(\.id), ["fr-ara", "fr-bre", "fr-ges"], "by name")
        XCTAssertTrue(france.isInRegions)
        XCTAssertTrue(france.hasAeronauticalData)
        XCTAssertTrue(france.hasVFRProcedures)

        let switzerland = try XCTUnwrap(countries.first { $0.id == "CH" })
        XCTAssertFalse(switzerland.isInRegions, "one region: one press")
        XCTAssertTrue(switzerland.hasSwissCharts)

        // A country OpenAIP doesn't list still comes from the Atlas, by its id when the index has no country.
        let kosovo = try XCTUnwrap(countries.first { $0.id == "XK" })
        XCTAssertFalse(kosovo.hasAeronauticalData)
        XCTAssertEqual(kosovo.atlasRegions.map(\.id), ["xk"])

        // OpenAIP's countries without an Atlas region are offered for their data alone.
        let morocco = try XCTUnwrap(countries.first { $0.id == "MA" })
        XCTAssertTrue(morocco.atlasRegions.isEmpty)
        XCTAssertFalse(morocco.hasVFRProcedures)

        XCTAssertFalse(countries.contains { $0.atlasRegions.contains { $0.id == PilotMapRegion.overviewID } },
                       "the overview is Worldwide's, no country's")
        XCTAssertEqual(countries.map(\.name), countries.map(\.name).sorted { $0.localizedCompare($1) == .orderedAscending })
    }

    func testOnDeviceIsTheDataKeptTheAtlasRegionsAndTheSwissCharts() {
        XCTAssertEqual(OfflineCountryCatalog.onDevice(aeronautical: ["AT"], atlasDownloaded: [Self.atlas[1], Self.atlas[5]],
                                                      swissCharts: true),
                       ["AT", "FR", "CH"], "the overview counts for no country")
        XCTAssertEqual(OfflineCountryCatalog.onDevice(aeronautical: [], atlasDownloaded: [], swissCharts: false), [])
    }

    func testHomeIsTheHomeAerodromesCountryElseTheDevicesRegion() {
        XCTAssertEqual(OfflineCountryCatalog.home(homeIdent: "LSZQ", locale: Locale(identifier: "fr_FR")), "CH")
        XCTAssertEqual(OfflineCountryCatalog.home(homeIdent: nil, locale: Locale(identifier: "fr_FR")), "FR")
        XCTAssertEqual(OfflineCountryCatalog.home(homeIdent: "", locale: Locale(identifier: "de_AT")), "AT")
    }

    func testSearchMatchesTheCountryAndItsRegionsWhateverTheAccents() throws {
        let france = try XCTUnwrap(Self.catalog().first { $0.id == "FR" })
        XCTAssertTrue(OfflineCountryCatalog.matches(france, "fr"), "the country, here named by its code")
        XCTAssertTrue(OfflineCountryCatalog.matches(france, "rhone"), "Auvergne-Rhône-Alpes")
        XCTAssertTrue(OfflineCountryCatalog.matches(france, "  "))
        XCTAssertFalse(OfflineCountryCatalog.matches(france, "bavaria"))
    }

    func testOnePressFetchesTheMissingRegionsAndTheDataWhenNotKept() throws {
        let france = try XCTUnwrap(Self.catalog().first { $0.id == "FR" })
        XCTAssertEqual(OfflineCountryCatalog.bytesToFetch(france, downloadedRegions: [], aeronauticalKept: false),
                       36 + 93 + 49 + 5_000_000)
        XCTAssertEqual(OfflineCountryCatalog.bytesToFetch(france, downloadedRegions: ["fr-bre"], aeronauticalKept: true),
                       93 + 49)
        let kosovo = try XCTUnwrap(Self.catalog().first { $0.id == "XK" })
        XCTAssertEqual(OfflineCountryCatalog.bytesToFetch(kosovo, downloadedRegions: [], aeronauticalKept: false), 5,
                       "no OpenAIP data to fetch")
    }

    // MARK: - Holdings

    func testAHoldingAddsTheCountrysPartsAndAddingCountsAsOnTheDevice() throws {
        let snapshot = OfflineDataSnapshot(
            countries: Self.catalog(), kept: ["FR"], vfrKept: ["FR"], adding: ["AT"],
            downloadedRegions: [Self.atlas[1], Self.atlas[0], Self.atlas[5]], swissCharts: true, swissChartBytes: 1_000,
            sizes: OfflineCountrySizes(aeronautical: ["FR": 200, "CH": 50], vfr: ["FR": 7]))
        let france = snapshot.holding(try XCTUnwrap(snapshot.country("FR")))
        XCTAssertEqual(france.atlasDownloaded.map(\.id), ["fr-bre"])
        XCTAssertEqual(france.atlasMissing.map(\.id), ["fr-ara", "fr-ges"])
        XCTAssertEqual(france.bytes, 36 + 200 + 7)
        XCTAssertFalse(france.swissCharts)

        let switzerland = snapshot.holding(try XCTUnwrap(snapshot.country("CH")))
        XCTAssertTrue(switzerland.swissCharts)
        XCTAssertEqual(switzerland.bytes, 88 + 50 + 1_000)
        XCTAssertFalse(switzerland.aeronautical, "its data is not kept here")

        XCTAssertEqual(snapshot.onDevice.map(\.country.id), ["AT", "FR", "CH"].sorted(),
                       "Austria while it downloads; the overview is no country")
    }

    func testRowsSayWhatIsOnTheDevice() throws {
        let snapshot = OfflineDataSnapshot(
            countries: Self.catalog(), kept: ["FR", "CH"], vfrKept: ["FR", "CH"], adding: [],
            downloadedRegions: [Self.atlas[0], Self.atlas[1]], swissCharts: true, swissChartBytes: 0,
            sizes: OfflineCountrySizes())
        let france = snapshot.holding(try XCTUnwrap(snapshot.country("FR")))
        XCTAssertEqual(OfflineDataView.parts(france, adding: []),
                       "\(L10n.OfflineData.partAtlasSome(1, 3)) · \(L10n.OfflineData.partAeronautical) · \(L10n.OfflineData.partVFR)")
        XCTAssertEqual(OfflineDataView.parts(france, adding: ["FR"]), L10n.OfflineData.downloading)
        let switzerland = snapshot.holding(try XCTUnwrap(snapshot.country("CH")))
        XCTAssertTrue(OfflineDataView.parts(switzerland, adding: []).hasSuffix(L10n.OfflineData.partSwissCharts))
        XCTAssertTrue(OfflineDataView.readyDetail([france, switzerland], totalBytes: 0)
            .hasPrefix(L10n.OfflineData.inRegions("FR", 1, 3)))

        let morocco = try XCTUnwrap(snapshot.country("MA"))
        XCTAssertEqual(OfflineDataView.offer(morocco), L10n.OfflineData.aeronauticalOnly)
        let notKept = snapshot.holding(try XCTUnwrap(snapshot.country("XK")))
        XCTAssertEqual(OfflineDataView.parts(notKept, adding: []), "", "nothing of Kosovo here")
    }

    // MARK: - Add a country

    func testAddACountryListsHomeThenItsNeighboursThenEuropeThenElsewhere() {
        let candidates = Self.catalog().filter { ["CH", "FR", "DE", "BE", "MA", "XK"].contains($0.id) }
        let groups = AddCountryPage.groups(candidates, home: "CH", search: "")
        XCTAssertEqual(groups.map(\.id), ["home", "next", "europe", "elsewhere"])
        XCTAssertEqual(groups[0].countries.map(\.id), ["CH"])
        XCTAssertEqual(Set(groups[1].countries.map(\.id)), ["FR", "DE"])
        XCTAssertEqual(groups[2].countries.map(\.id), ["BE"])
        XCTAssertEqual(Set(groups[3].countries.map(\.id)), ["MA", "XK"], "Kosovo is no OpenAIP European country")

        let searched = AddCountryPage.groups(candidates, home: "CH", search: "bri")
        XCTAssertEqual(searched.flatMap(\.countries).map(\.id), ["FR"], "Brittany")
        XCTAssertEqual(AddCountryPage.groups(candidates, home: nil, search: "").map(\.id), ["europe", "elsewhere"])
    }

    // MARK: - On disk

    func testBytesOnDiskReadEachCountrysFilesInEveryLayer() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("OfflineCountries-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        func write(_ directory: String, _ name: String, _ count: Int) throws {
            let dir = base.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(count: count).write(to: dir.appendingPathComponent(name))
        }
        try write("OpenAIPData", "airspaces_CH.json", 100)
        try write("OpenAIPNavaidData", "navaids_CH.json", 20)
        try write(OpenAIPAirportDataService.directoryName, "airports_FR.json", 30)
        try write("OpenAIPData", "metadata.json", 999)
        try write(OFMDataService.directoryName, "ofm_CH.json", 7)
        try write(OFMDataService.directoryName, "index.json", 999)

        let sizes = OfflineCountryCatalog.bytesOnDisk(base: base)
        XCTAssertEqual(sizes.aeronautical, ["CH": 120, "FR": 30])
        XCTAssertEqual(sizes.vfr, ["CH": 7])
    }
}
