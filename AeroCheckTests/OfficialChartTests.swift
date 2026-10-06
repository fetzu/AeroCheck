import XCTest
import MapKit
import SwiftUI
@testable import AeroCheck

/// The official chart of an aerodrome (6.2.0): the links the registry builds per country (DE's page
/// table, FR's template in the AIRAC folder, CH's SkyBriefing page behind a login, AT's eAIP, none for
/// IT or an unknown country), the registry's cache and staleness, the callouts that offer the chart
/// beside Divert or "+" and send each tap to the right one, the VFR callout, and the thread's links.
@MainActor
final class OfficialChartTests: XCTestCase {

    // MARK: - Fixtures

    /// The live file of 2 October 2026 in miniature: the same shape, three of DFS's 444 pages.
    private let registryJSON = """
    {
      "v": 1,
      "generated": "2026-10-02T00:08:48Z",
      "countries": {
        "DE": { "kind": "dfs-basicvfr", "base": "https://aip.dfs.de/BasicVFR/pages/",
                "pages": { "EDDS": "C01AD3", "EDNY": "C019CA", "EDTF": "C019C9" } },
        "FR": { "kind": "sia-vac",
                "template": "https://www.sia.aviation-civile.gouv.fr/media/dvd/eAIP_01_OCT_2026/Atlas-VAC/PDF_AIPparSSection/VAC/AD/AD-2.{icao}.pdf",
                "airac": "2610" },
        "CH": { "kind": "skybriefing-vfr-manual", "url": "https://www.skybriefing.com/en/evfr-manual", "login": true },
        "AT": { "kind": "eaip", "url": "https://eaip.austrocontrol.at/" }
      },
      "flags": []
    }
    """

    private func registry(_ json: String? = nil) throws -> OfficialChartRegistry {
        try JSONDecoder().decode(OfficialChartRegistry.self, from: Data((json ?? registryJSON).utf8))
    }

    /// 2 October 2026, 12:00 UTC: AIRAC 2610 (1 to 28 October).
    private let october2 = Date(timeIntervalSince1970: 1_790_942_400)
    private let day: TimeInterval = 24 * 60 * 60

    private func utc(_ year: Int, _ month: Int, _ dayOfMonth: Int, _ hour: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = dayOfMonth
        components.hour = hour
        return OFMSchema.utcCalendar.date(from: components)!
    }

    private func airport(_ ident: String, _ type: AirportType = .smallAirport, country: String = "CH",
                         lat: Double = 47.4247, lon: Double = 7.1869) -> Airport {
        Airport(id: 1, ident: ident, type: type, name: "\(ident) field", latitude: lat, longitude: lon, elevation: 1000,
                continent: "EU", isoCountry: country, isoRegion: "\(country)-XX", municipality: nil,
                scheduledService: false, gpsCode: ident, iataCode: nil, localCode: nil)
    }

    private var savedRegistry: OfficialChartRegistry?
    private var savedFetch: Date?

    override func setUp() async throws {
        try await super.setUp()
        savedRegistry = OfficialChartService.shared.registry
        savedFetch = OfficialChartService.shared.lastFetch
        OfficialChartService.shared.seedForTesting(try registry())
    }

    override func tearDown() async throws {
        OfficialChartService.shared.seedForTesting(savedRegistry, fetchedAt: savedFetch)
        try await super.tearDown()
    }

    // MARK: - Links per country

    func testGermanyLinksTheDFSPageOfTheAerodrome() throws {
        let charts = try registry()
        XCTAssertEqual(charts.countries.keys.sorted(), ["AT", "CH", "DE", "FR"])
        let link = try XCTUnwrap(charts.link(for: "EDNY", type: .mediumAirport, now: october2))
        XCTAssertEqual(link.url.absoluteString, "https://aip.dfs.de/BasicVFR/pages/C019CA.html")
        XCTAssertEqual(link.country, "DE")
        XCTAssertEqual(link.publisher, "DFS")
        XCTAssertFalse(link.requiresLogin)
        XCTAssertEqual(link.title, "Official chart")
        // The table names the aerodromes: without a type, as with one; a German code DFS doesn't list, nothing.
        XCTAssertEqual(charts.link(for: "EDTF", type: nil, now: october2)?.url.lastPathComponent, "C019C9.html")
        XCTAssertNil(charts.link(for: "EDXX", type: .smallAirport, now: october2))
    }

    func testFranceFillsTheTemplateInTheCyclesFolder() throws {
        let charts = try registry()
        let link = try XCTUnwrap(charts.link(for: "LFGA", type: .smallAirport, now: october2))
        XCTAssertEqual(link.url.absoluteString,
                       "https://www.sia.aviation-civile.gouv.fr/media/dvd/eAIP_01_OCT_2026/Atlas-VAC/PDF_AIPparSSection/VAC/AD/AD-2.LFGA.pdf")
        XCTAssertEqual(link.publisher, "SIA")
        XCTAssertFalse(link.requiresLogin)
        XCTAssertNotNil(charts.link(for: "LFSB", type: .largeAirport, now: october2))
        XCTAssertNotNil(charts.link(for: "LFJL", type: .mediumAirport, now: october2))
    }

    /// The atlas has VACs for aerodromes only and the registry doesn't list its codes: a heliport, a
    /// seaplane base, a closed field, an unknown type or a private field's non-ICAO ident get no link.
    func testFranceOnlyForAerodromeTypesWithAnICAOCode() throws {
        let charts = try registry()
        for type in [AirportType.heliport, .seaplaneBase, .closed, .balloonport] {
            XCTAssertNil(charts.link(for: "LFGA", type: type, now: october2), "\(type)")
        }
        XCTAssertNil(charts.link(for: "LFGA", type: nil, now: october2), "a type is needed in France")
        XCTAssertNil(charts.link(for: "LF51", type: .smallAirport, now: october2))
        XCTAssertNil(charts.link(for: "FR-0098", type: .smallAirport, now: october2))
    }

    /// The registry of 2 October 2026 on: SIA's own list of the atlas (419 codes in 2610). With it the list
    /// decides, whatever the type; without it (an older file, or the list unavailable that week), the type.
    func testFranceFollowsTheAtlassListWhenTheRegistryHasOne() throws {
        let withCodes = try registry(registryJSON.replacingOccurrences(
            of: "\"airac\": \"2610\" },", with: "\"airac\": \"2610\", \"codes\": [\"LFGA\", \"LFSB\", \"LFXX\"] },"))
        XCTAssertEqual(withCodes.countries["FR"]?.codes, ["LFGA", "LFSB", "LFXX"])
        XCTAssertNotNil(withCodes.link(for: "LFGA", type: .smallAirport, now: october2))
        XCTAssertNotNil(withCodes.link(for: "LFSB", type: nil, now: october2), "the list needs no type")
        XCTAssertNotNil(withCodes.link(for: "LFXX", type: .heliport, now: october2), "the list decides")
        XCTAssertNil(withCodes.link(for: "LFBM", type: .mediumAirport, now: october2),
                     "an air base OurAirports calls an airport, without a VAC: the 404 the type rule let through")
        XCTAssertNil(withCodes.link(for: "LFGA", type: .closed, now: october2))
        XCTAssertNil(withCodes.link(for: "LFGA", type: nil, now: utc(2026, 10, 29, 3)), "the folder still has to be current")

        // An empty list is no list.
        XCTAssertTrue(OfficialChartRegistry.hasVAC("LFBM", codes: [], type: .mediumAirport))
        XCTAssertFalse(OfficialChartRegistry.hasVAC("LFBM", codes: nil, type: nil))
        // A list that isn't a list of strings is no list either: the type rule.
        let broken = try registry(registryJSON.replacingOccurrences(
            of: "\"airac\": \"2610\" },", with: "\"airac\": \"2610\", \"codes\": [1, 2] },"))
        XCTAssertNil(broken.countries["FR"]?.codes)
        XCTAssertNotNil(broken.link(for: "LFBM", type: .mediumAirport, now: october2))
        XCTAssertNil(broken.link(for: "LFGA", type: nil, now: october2))
    }

    /// SIA takes a cycle's folder down when the next one starts: a template of an older cycle is only
    /// used when the job checked it during the cycle in force.
    func testFranceDropsAFolderOfAPastCycle() throws {
        let charts = try registry()
        let nextCycle = utc(2026, 10, 29, 3)   // AIRAC 2611, before the weekly job
        XCTAssertNil(charts.link(for: "LFGA", type: .smallAirport, now: nextCycle))
        XCTAssertNotNil(charts.link(for: "EDNY", type: .smallAirport, now: nextCycle), "only France's links name a cycle")

        // The job ran in 2611 but SIA hadn't put the new folder online: it kept 2610's, which answered.
        let fallback = try registry(registryJSON.replacingOccurrences(of: "2026-10-02T00:08:48Z", with: "2026-10-29T05:04:00Z"))
        XCTAssertNotNil(fallback.link(for: "LFGA", type: .smallAirport, now: nextCycle))
        // A file of a newer cycle than the device's clock says is in force.
        XCTAssertNotNil(charts.link(for: "LFGA", type: .smallAirport, now: utc(2026, 9, 30, 12)))
    }

    func testSwitzerlandIsSkyBriefingsVFRManualBehindALogin() throws {
        let charts = try registry()
        let link = try XCTUnwrap(charts.link(for: "LSZQ", type: .smallAirport, now: october2))
        XCTAssertEqual(link.url.absoluteString, "https://www.skybriefing.com/en/evfr-manual")
        XCTAssertTrue(link.requiresLogin)
        XCTAssertEqual(link.publisher, "SkyBriefing")
        XCTAssertEqual(link.title, "Official chart · SkyBriefing (subscription)")
        XCTAssertEqual(link.note, "SkyBriefing (subscription)")
        XCTAssertEqual(link.accessibilityHint, "Opens SkyBriefing in the browser")
        // One page for every Swiss code, whatever the type, except a closed field.
        XCTAssertEqual(charts.link(for: "LSGC", type: nil, now: october2)?.url, link.url)
        XCTAssertEqual(charts.link(for: "LSXB", type: .heliport, now: october2)?.url, link.url)
        XCTAssertNil(charts.link(for: "LSZQ", type: .closed, now: october2))
        // Lower case and spaces, as an ident typed in a plan can be.
        XCTAssertEqual(charts.link(for: " lszq ", type: nil, now: october2)?.icao, "LSZQ")
    }

    func testAustriaIsTheEAIPStartPage() throws {
        let link = try XCTUnwrap(try registry().link(for: "LOWI", type: .mediumAirport, now: october2))
        XCTAssertEqual(link.url.absoluteString, "https://eaip.austrocontrol.at/")
        XCTAssertEqual(link.publisher, "Austro Control")
        XCTAssertFalse(link.requiresLogin)
    }

    func testItalyAndUnknownCountriesHaveNone() throws {
        let charts = try registry()
        XCTAssertNil(charts.link(for: "LIMJ", type: .mediumAirport, now: october2), "ENAV forbids deep links")
        XCTAssertNil(charts.link(for: "LIPB", type: .smallAirport, now: october2))
        XCTAssertNil(charts.link(for: "EGLL", type: .largeAirport, now: october2))
        XCTAssertNil(charts.link(for: "KJFK", type: .largeAirport, now: october2))
        XCTAssertNil(charts.link(for: "", type: nil, now: october2))
        XCTAssertNil(OfficialChartService.shared.link(for: "LIMJ", type: .mediumAirport))
    }

    /// A link off its publisher's domain, not HTTPS, or a page id that could leave DFS's folder is
    /// never built: a forged "SkyBriefing" sign-in page is what a tampered file would want.
    func testALinkOffThePublishersSiteIsNotOpened() throws {
        let hostile = try registry("""
        { "v": 1, "countries": {
            "CH": { "kind": "skybriefing-vfr-manual", "url": "https://www.skybriefing.com.evil.example/login", "login": true },
            "AT": { "kind": "eaip", "url": "http://eaip.austrocontrol.at/" },
            "DE": { "kind": "dfs-basicvfr", "base": "https://aip.dfs.de/BasicVFR/pages/", "pages": { "EDNY": "../../x", "EDTF": "C019C9" } },
            "FR": { "kind": "sia-vac", "template": "https://sia.example.com/AD-2.{icao}.pdf", "airac": "2610" } } }
        """)
        XCTAssertNil(hostile.link(for: "LSZQ", type: .smallAirport, now: october2))
        XCTAssertNil(hostile.link(for: "LOWI", type: .smallAirport, now: october2))
        XCTAssertNil(hostile.link(for: "EDNY", type: .smallAirport, now: october2))
        XCTAssertNotNil(hostile.link(for: "EDTF", type: .smallAirport, now: october2))
        XCTAssertNil(hostile.link(for: "LFGA", type: .smallAirport, now: october2))
        // A subdomain of the publisher is its own.
        XCTAssertNotNil(OfficialChartRegistry.publisherURL("https://eaip.austrocontrol.at/x", country: "AT"))
        XCTAssertNil(OfficialChartRegistry.publisherURL("https://notaustrocontrol.at/", country: "AT"))
    }

    /// A country the app can't read is skipped, never the file; flags are the job's business.
    func testTheRegistryDecodesLeniently() throws {
        let charts = try registry("""
        { "v": 1, "generated": null, "countries": {
            "CH": { "kind": "skybriefing-vfr-manual", "url": "https://www.skybriefing.com/en/evfr-manual", "login": true },
            "FR": { "kind": 7 },
            "SI": { "kind": "something-new", "url": "https://www.sloveniacontrol.si/" },
            "DE": { "kind": "dfs-basicvfr", "base": "https://aip.dfs.de/BasicVFR/pages/", "pages": { "EDNY": 12 } } },
          "flags": [ { "country": "FR", "url": "https://x", "status": 404, "detail": "folder" } ] }
        """)
        XCTAssertEqual(charts.countries.keys.sorted(), ["CH", "DE", "SI"])
        XCTAssertNotNil(charts.link(for: "LSZQ", type: nil, now: october2))
        XCTAssertNil(charts.link(for: "LJLJ", type: .largeAirport, now: october2), "a kind and a country the app doesn't know")
        XCTAssertNil(charts.link(for: "EDNY", type: nil, now: october2), "an unreadable page table is no table")
    }

    func testTheSymbolsExist() throws {
        let charts = try registry()
        for icao in ["LSZQ", "EDNY"] {
            let link = try XCTUnwrap(charts.link(for: icao, type: .smallAirport, now: october2))
            XCTAssertNotNil(UIImage(systemName: link.symbolName), link.symbolName)
        }
    }

    // MARK: - AIRAC

    func testTheAIRACCycleInForce() {
        XCTAssertEqual(AIRACCycle.inForce(on: utc(2020, 1, 2)).ident, "2001")
        XCTAssertEqual(AIRACCycle.inForce(on: utc(2026, 1, 22)).ident, "2601")
        XCTAssertEqual(AIRACCycle.inForce(on: utc(2026, 9, 30, 23)).ident, "2609")
        let october = AIRACCycle.inForce(on: utc(2026, 10, 1))
        XCTAssertEqual(october.ident, "2610")
        XCTAssertEqual(october.validFrom, utc(2026, 10, 1))
        XCTAssertEqual(AIRACCycle.inForce(on: october2).ident, "2610")
        XCTAssertEqual(AIRACCycle.inForce(on: utc(2026, 12, 31)).ident, "2613")
        XCTAssertEqual(AIRACCycle.inForce(on: utc(2027, 1, 21)).ident, "2701")
    }

    // MARK: - Cache and staleness

    func testStaleness() throws {
        let charts = try registry()
        XCTAssertTrue(OfficialChartService.isStale(registry: nil, fetchedAt: october2, now: october2))
        XCTAssertTrue(OfficialChartService.isStale(registry: charts, fetchedAt: nil, now: october2))
        XCTAssertFalse(OfficialChartService.isStale(registry: charts, fetchedAt: october2, now: october2 + 6 * day))
        XCTAssertTrue(OfficialChartService.isStale(registry: charts, fetchedAt: october2, now: october2 + 7 * day))
        XCTAssertTrue(OfficialChartService.isStale(registry: charts, fetchedAt: october2 + day, now: october2),
                      "a clock that went back")
        // A new cycle while the file names 2610's French folder: once an hour until the job's new file.
        let cycleStart = utc(2026, 10, 29)
        XCTAssertFalse(OfficialChartService.isStale(registry: charts, fetchedAt: cycleStart + 600, now: cycleStart + 1800))
        XCTAssertTrue(OfficialChartService.isStale(registry: charts, fetchedAt: cycleStart + 600, now: cycleStart + 2 * 3600))
        XCTAssertTrue(OfficialChartService.isStale(registry: charts, fetchedAt: october2, now: cycleStart + 600))
        // Without France, a cycle means nothing.
        let noFrance = OfficialChartRegistry(generated: charts.generated, countries: charts.countries.filter { $0.key != "FR" })
        XCTAssertFalse(OfficialChartService.isStale(registry: noFrance, fetchedAt: cycleStart - day, now: cycleStart + 600))
        XCTAssertTrue(OfficialChartService.isStale(registry: charts, fetchedAt: cycleStart - day, now: cycleStart + 600))
    }

    private final class Box<T> { var value: T; init(_ value: T) { self.value = value } }

    private func temporaryCache() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OfficialChartTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("official-charts.json")
    }

    func testItFetchesFromTheAPICachesOnDiskAndRefreshesWhenAWeekOld() async throws {
        let cache = try temporaryCache()
        let clock = Box(october2)
        let requests = Box([URL]())
        let body = Box(Data(registryJSON.utf8))
        let fetch: (URL) async throws -> Data = { url in
            await MainActor.run { requests.value.append(url) }
            return await MainActor.run { body.value }
        }
        let service = OfficialChartService(cacheURL: cache, fetch: fetch, now: { clock.value })
        XCTAssertNil(service.registry)
        XCTAssertTrue(service.isStale)

        await service.refreshIfNeeded()
        XCTAssertEqual(requests.value.map(\.absoluteString), [APIConfig.baseURL + "/data/charts/v1/charts.json"])
        XCTAssertEqual(service.registry, try registry())
        XCTAssertEqual(service.link(for: "LSZQ", type: nil)?.requiresLogin, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))

        // Fresh: no second request. A new instance (a relaunch) reads the disk, offline.
        await service.refreshIfNeeded()
        XCTAssertEqual(requests.value.count, 1)
        let relaunched = OfficialChartService(cacheURL: cache, fetch: { _ in throw URLError(.notConnectedToInternet) },
                                              now: { clock.value })
        XCTAssertEqual(relaunched.registry, try registry())
        XCTAssertEqual(relaunched.lastFetch.map { Int($0.timeIntervalSince1970) }, Int(october2.timeIntervalSince1970))
        XCTAssertFalse(relaunched.isStale)

        // A week later: stale, fetched again. A failure keeps what it had.
        clock.value = october2 + 7 * day + 60
        XCTAssertTrue(relaunched.isStale)
        await relaunched.refreshIfNeeded()
        XCTAssertEqual(relaunched.registry, try registry(), "silent failure: the old file stays")
        await service.refreshIfNeeded()
        XCTAssertEqual(requests.value.count, 2)
    }

    func testANewSchemaAnOversizedOrABrokenFileIsNotTaken() async throws {
        let body = Box(Data(registryJSON.utf8))
        let service = OfficialChartService(cacheURL: try temporaryCache(), fetch: { _ in await MainActor.run { body.value } },
                                           now: { self.october2 })
        await service.refresh()
        let good = try registry()
        XCTAssertEqual(service.registry, good)

        body.value = Data(registryJSON.replacingOccurrences(of: "\"v\": 1", with: "\"v\": 2").utf8)
        await service.refresh()
        XCTAssertEqual(service.registry, good, "schema 2 is another app's")
        body.value = Data("{ \"v\": 1, \"countries\": [".utf8)
        await service.refresh()
        XCTAssertEqual(service.registry, good)
        body.value = Data(repeating: 0x20, count: OfficialChartService.maxBytes + 1)
        await service.refresh()
        XCTAssertEqual(service.registry, good)
        let api = try XCTUnwrap(URL(string: APIConfig.baseURL)?.host?.lowercased())
        XCTAssertEqual(OfficialChartService.allowedHosts, [api], "the API host this build talks to, only")
        XCTAssertEqual(OfficialChartService.registryURL.host, api)
    }

    /// A fetch that started before a seed doesn't land after it (the app's launch refresh, while a test
    /// has seeded the shared service).
    func testAFetchStartedBeforeASeedDoesntOverwriteIt() async throws {
        let seeded = OfficialChartRegistry(countries: ["AT": .init(kind: "eaip", url: "https://eaip.austrocontrol.at/")])
        let holder = Box<OfficialChartService?>(nil)
        let json = registryJSON
        let service = OfficialChartService(cacheURL: try temporaryCache(), fetch: { _ in
            await MainActor.run { holder.value?.seedForTesting(seeded) }
            return Data(json.utf8)
        }, now: { self.october2 })
        holder.value = service
        await service.refresh()
        XCTAssertEqual(service.registry, seeded)
    }

    // MARK: - The airport callout on the navigation maps

    private func tap(_ control: UIView?, on view: MKAnnotationView, map: MKMapView,
                     with coordinator: MKMapViewDelegate) throws {
        let control = try XCTUnwrap(control as? UIControl)
        coordinator.mapView?(map, annotationView: view, calloutAccessoryControlTapped: control)
    }

    /// The chart on the left, Divert on the right, and each tap to its own: before 6.2.0 any control
    /// of the callout meant Divert.
    func testTheAirportCalloutSendsEachTapToItsControl() throws {
        var plan = FlightPlan(name: "Test")
        plan.waypoints = [FlightPlanWaypoint(name: "LSZQ", coordinate: CLLocationCoordinate2D(latitude: 47.42, longitude: 7.18), altitude: 3000)]
        let state = SharedMapState()
        var diverts: [String] = []
        var charts: [URL] = []
        let native = NativeMapViewUIKit(selectedLayer: .standard, mapState: state, currentLocation: nil, gpsTrack: [],
                                        isFollowingAircraft: .constant(true), activeFlightPlan: plan,
                                        onAirportDivert: { diverts.append($0) },
                                        onOpenOfficialChart: { charts.append($0) }, isInFlight: true).makeCoordinator()
        let swiss = SwissMapView(layerType: .icao, mapState: state, currentLocation: nil, gpsTrack: [],
                                 isFollowingAircraft: .constant(true), forceICAOLayer: false, activeFlightPlan: plan,
                                 onAirportDivert: { diverts.append($0) },
                                 onOpenOfficialChart: { charts.append($0) }, isInFlight: true).makeCoordinator()
        let maps: [(String, MKMapViewDelegate)] = [("NativeMapViewUIKit", native), ("SwissMapView", swiss)]
        for (name, coordinator) in maps {
            diverts = []
            charts = []
            let map = MKMapView()
            let annotation = AirportAnnotation(airport: airport("LSZQ"))
            let view = try XCTUnwrap(coordinator.mapView?(map, viewFor: annotation), name)
            let chart = try XCTUnwrap(view.leftCalloutAccessoryView as? OfficialChartControl, name)
            XCTAssertEqual(chart.link?.url.host, "www.skybriefing.com", name)
            XCTAssertEqual(chart.accessibilityLabel, "Official chart · SkyBriefing (subscription)", name)
            XCTAssertGreaterThanOrEqual(chart.frame.height, CockpitTarget.control, "\(name): in flight, the Cockpit's size")
            XCTAssertGreaterThanOrEqual(chart.frame.width, CockpitTarget.control, name)
            let divert = try XCTUnwrap(view.rightCalloutAccessoryView as? UIButton, name)
            XCTAssertFalse(divert is OfficialChartControl, name)
            XCTAssertGreaterThanOrEqual(divert.frame.height, CockpitTarget.control, name)

            try tap(chart, on: view, map: map, with: coordinator)
            XCTAssertEqual(charts.map(\.absoluteString), ["https://www.skybriefing.com/en/evfr-manual"], name)
            XCTAssertEqual(diverts, [], "\(name): the chart is not a diversion")

            try tap(divert, on: view, map: map, with: coordinator)
            XCTAssertEqual(diverts, ["LSZQ"], name)
            XCTAssertEqual(charts.count, 1, name)
        }
    }

    /// On the ground (Plan › Map): the chart alone, at 44 pt; no chart without a way to open it, or
    /// for a field without one.
    func testTheAirportCalloutOnTheGround() throws {
        let state = SharedMapState()
        var charts: [URL] = []
        let ground = NativeMapViewUIKit(selectedLayer: .standard, mapState: state, currentLocation: nil, gpsTrack: [],
                                        isFollowingAircraft: .constant(true),
                                        onOpenOfficialChart: { charts.append($0) }).makeCoordinator()
        let map = MKMapView()
        let view = try XCTUnwrap(ground.mapView(map, viewFor: AirportAnnotation(airport: airport("EDNY", country: "DE"))))
        let chart = try XCTUnwrap(view.leftCalloutAccessoryView as? OfficialChartControl)
        XCTAssertGreaterThanOrEqual(chart.frame.height, 44)
        XCTAssertGreaterThanOrEqual(chart.frame.width, 44)
        XCTAssertNil(view.rightCalloutAccessoryView, "no Divert on the ground")
        try tap(chart, on: view, map: map, with: ground)
        XCTAssertEqual(charts.map(\.lastPathComponent), ["C019CA.html"])

        let italian = try XCTUnwrap(ground.mapView(map, viewFor: AirportAnnotation(airport: airport("LIMJ", .mediumAirport, country: "IT"))))
        XCTAssertNil(italian.leftCalloutAccessoryView)

        let noOpener = NativeMapViewUIKit(selectedLayer: .standard, mapState: state, currentLocation: nil, gpsTrack: [],
                                          isFollowingAircraft: .constant(true)).makeCoordinator()
        XCTAssertNil(try XCTUnwrap(noOpener.mapView(map, viewFor: AirportAnnotation(airport: airport("LSZQ")))).leftCalloutAccessoryView)
    }

    func testAirportCalloutControlsTellTheTapsApart() throws {
        let link = try XCTUnwrap(try registry().link(for: "LOWI", type: .smallAirport, now: october2))
        let lowi = airport("LOWI", country: "AT")
        let view = MKAnnotationView(annotation: AirportAnnotation(airport: lowi), reuseIdentifier: nil)
        AirportCalloutControls.configure(view, chart: link, divert: true, metrics: .ground, tint: .systemBlue)
        let left = try XCTUnwrap(view.leftCalloutAccessoryView as? UIControl)
        let right = try XCTUnwrap(view.rightCalloutAccessoryView as? UIControl)
        XCTAssertEqual(AirportCalloutControls.action(for: left, airport: lowi), .officialChart(link.url))
        XCTAssertEqual(AirportCalloutControls.action(for: right, airport: lowi), .divert("LOWI"))
        AirportCalloutControls.configure(view, chart: nil, divert: false, metrics: .ground, tint: .systemBlue)
        XCTAssertNil(view.leftCalloutAccessoryView)
        XCTAssertNil(view.rightCalloutAccessoryView)
    }

    /// The route builder: the chart on the left, "+" on the right; the chart adds nothing.
    func testTheBuilderCalloutOpensTheChartWithoutAddingThePoint() throws {
        var added: [RoutePoint] = []
        var charts: [URL] = []
        let builder = RouteBuilderMapView(waypoints: [], mapLayer: .icao, airports: [], fitRouteToken: 0,
                                          region: .constant(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 47.4, longitude: 7.0),
                                                                               span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5))),
                                          onPointAdd: { added.append($0) },
                                          onOpenOfficialChart: { charts.append($0) }).makeCoordinator()
        let map = MKMapView()
        let view = try XCTUnwrap(builder.mapView(map, viewFor: AirportAnnotation(airport: airport("LSZQ"))))
        let chart = try XCTUnwrap(view.leftCalloutAccessoryView as? OfficialChartControl)
        XCTAssertGreaterThanOrEqual(chart.frame.height, 44)
        try tap(chart, on: view, map: map, with: builder)
        XCTAssertEqual(charts.count, 1)
        XCTAssertTrue(added.isEmpty, "the chart is not \"+\"")
        try tap(view.rightCalloutAccessoryView, on: view, map: map, with: builder)
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(charts.count, 1)
    }

    // MARK: - Callouts and the chrome over the chart

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    /// While a callout is open, the scale bar and the off-screen route pill step aside (they covered the
    /// callout's title and its first button on the phone's Cockpit MAP), and come back when it closes.
    /// The coordinators keep the flag from MapKit's selection, on both navigation maps.
    func testAnOpenCalloutIsTrackedForTheChrome() throws {
        let lszq = AirportAnnotation(airport: airport("LSZQ", lat: 47.40, lon: 7.03))
        let withCallout = MKAnnotationView(annotation: lszq, reuseIdentifier: nil)
        withCallout.canShowCallout = true
        let waypoint = FlightPlanWaypointAnnotation(coordinate: lszq.coordinate, name: "LSZQ", index: 0, currentIndex: 0)
        let withoutCallout = MKAnnotationView(annotation: waypoint, reuseIdentifier: nil)
        XCTAssertTrue(MapCallout.isOpen(selected: [lszq], view: { _ in withCallout }))
        XCTAssertFalse(MapCallout.isOpen(selected: [waypoint], view: { _ in withoutCallout }), "a marker without a callout")
        XCTAssertFalse(MapCallout.isOpen(selected: [lszq], view: { _ in nil }), "no view on the map, nothing open")
        XCTAssertFalse(MapCallout.isOpen(selected: [], view: { _ in withCallout }))

        let makers: [(String, (SharedMapState) -> MKMapViewDelegate)] = [
            ("NativeMapViewUIKit", { NativeMapViewUIKit(selectedLayer: .standard, mapState: $0, currentLocation: nil, gpsTrack: [],
                                                        isFollowingAircraft: .constant(true)).makeCoordinator() }),
            ("SwissMapView", { SwissMapView(layerType: .icao, mapState: $0, currentLocation: nil, gpsTrack: [],
                                            isFollowingAircraft: .constant(true), forceICAOLayer: false).makeCoordinator() }),
        ]
        for (name, make) in makers {
            let state = SharedMapState()
            let coordinator = make(state)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 820, height: 1_180))
            window.isHidden = false
            defer { window.isHidden = true }
            let map = MKMapView(frame: window.bounds)
            map.delegate = coordinator
            window.addSubview(map)
            map.setRegion(MKCoordinateRegion(center: lszq.coordinate,
                                             span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)), animated: false)
            map.addAnnotation(lszq)
            XCTAssertTrue(waitUntil { map.view(for: lszq) != nil }, "\(name): the marker is on the map")
            XCTAssertFalse(state.isCalloutOpen, name)

            map.selectAnnotation(lszq, animated: false)
            XCTAssertTrue(waitUntil { state.isCalloutOpen }, "\(name): the aerodrome's callout is open")
            map.deselectAnnotation(lszq, animated: false)
            XCTAssertTrue(waitUntil { !state.isCalloutOpen }, "\(name): closed, the chrome comes back")

            // Taken off the map while open (the region moved past it): MapKit says nothing, the next
            // region change reads the selection again.
            map.selectAnnotation(lszq, animated: false)
            XCTAssertTrue(waitUntil { state.isCalloutOpen }, name)
            map.removeAnnotation(lszq)
            coordinator.mapView?(map, regionDidChangeAnimated: false)
            XCTAssertTrue(waitUntil { !state.isCalloutOpen }, "\(name): nothing selected any more")
            map.removeFromSuperview()
        }
    }

    // MARK: - The VFR procedure callout

    private func circuitAtLSZQ() throws -> VFRMapItem {
        let json = """
        { "v": 1, "region": "LSAS", "country": "CH", "airac": "2610", "validFrom": "2026-10-01", "validTo": "2026-10-29",
          "procedures": [
            {"id": "f2fbd4ca-1edb-354d-414d-28863037c1ea", "ad": "LSZQ", "kind": "circuit", "name": "TC", "use": "fw", "cat": null, "alt": 2900,
             "line": [[7.03373, 47.39356], [7.05466, 47.39851], [7.04636, 47.41809], [6.98485, 47.40447], [6.99369, 47.38507], [7.02427, 47.39125]]}
          ] }
        """
        let procedure = try XCTUnwrap(try JSONDecoder().decode(OFMRegionFile.self, from: Data(json.utf8)).procedures.first)
        return VFRMapItem(procedure: procedure, arrow: .none, labelText: VFRMapItem.labelText(for: procedure),
                          labelAnchor: VFRLabelPlacement.circuitAnchor(procedure.line),
                          country: "CH", region: "LSAS", airac: "2610")
    }

    private func allSubviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }

    /// #258's marked slot: the official chart first, then Report an error; it opens the aerodrome's link.
    func testTheVFRCalloutOffersTheChartFirst() throws {
        let lszq = try circuitAtLSZQ()
        var opened: [URL] = []
        let view = VFRProcedureCallout.detailView(for: lszq, at: lszq.labelAnchor.coordinate,
                                                  metrics: .flight, openChart: { opened.append($0) })
        let buttons = allSubviews(of: view).compactMap { $0 as? UIButton }
        XCTAssertEqual(buttons.compactMap { $0.configuration?.title }, [L10n.OfficialChart.title, L10n.VFRMap.reportError])
        let chart = try XCTUnwrap(buttons.first as? OfficialChartControl)
        XCTAssertEqual(chart.configuration?.subtitle, "SkyBriefing (subscription)")
        XCTAssertEqual(chart.link?.icao, "LSZQ")
        chart.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(opened.map(\.host), ["www.skybriefing.com"])

        // Laid out as the callout lays it out: by its constraints, in at most 300 pt.
        let size = view.systemLayoutSizeFitting(CGSize(width: 300, height: 0),
                                                withHorizontalFittingPriority: .fittingSizeLevel,
                                                verticalFittingPriority: .fittingSizeLevel)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        XCTAssertLessThanOrEqual(size.width, 300)
        for button in buttons {
            XCTAssertGreaterThanOrEqual(button.frame.height, CockpitTarget.control - 0.5, "in flight, the Cockpit's size")
        }

        // MapKit ends the bubble at the detail view's last baseline: the view's bottom, never the last
        // button's title (which cut 14 pt off Report an error in flight).
        XCTAssertTrue(view.forLastBaselineLayout === view)

        XCTAssertFalse(CalloutMetrics.flight(.kneeboard).sideBySide, "the iPad keeps them stacked")
        XCTAssertEqual(CalloutMetrics.flight(.kneeboard).target, 64)

        // Without a way to open it (and so in #258's tests), the callout is as it was.
        let plain = VFRProcedureCallout.detailView(for: lszq, at: lszq.labelAnchor.coordinate)
        XCTAssertEqual(allSubviews(of: plain).compactMap { ($0 as? UIButton)?.configuration?.title }, [L10n.VFRMap.reportError])
    }

    /// On the phone's Cockpit MAP, the two buttons side by side, a symbol and a short word each, at least
    /// 50 pt tall and within the callout's width; VoiceOver still reads the whole titles.
    func testOnThePhoneInFlightTheCalloutsButtonsSitSideBySide() throws {
        let lszq = try circuitAtLSZQ()
        let phone = CalloutMetrics.flight(.phone)
        XCTAssertTrue(phone.sideBySide)
        XCTAssertEqual(phone.target, 50)
        XCTAssertEqual(phone.fontSize, 17)
        XCTAssertFalse(CalloutMetrics.ground.sideBySide, "Plan › Map on the phone has the room")
        var opened: [URL] = []
        let view = VFRProcedureCallout.detailView(for: lszq, at: lszq.labelAnchor.coordinate,
                                                  metrics: phone, openChart: { opened.append($0) })
        let buttons = allSubviews(of: view).compactMap { $0 as? UIButton }
        XCTAssertEqual(buttons.compactMap { $0.configuration?.title }, [L10n.OfficialChart.short, L10n.VFRMap.reportShort])
        XCTAssertEqual(buttons.first?.configuration?.subtitle, "Subscription", "the subscription still says so, short")
        // The source on one line: the advice to check the official chart is the button under it.
        let texts = allSubviews(of: view).compactMap { ($0 as? UILabel)?.text }
        XCTAssertTrue(texts.contains("open flightmaps · AIRAC 2610 · indicative"), "\(texts)")
        XCTAssertFalse(texts.contains { $0.contains("check the official chart") })
        XCTAssertEqual(buttons.map(\.accessibilityLabel), ["Official chart · SkyBriefing (subscription)", "Report an error"])
        let row = try XCTUnwrap(buttons.first?.superview as? UIStackView)
        XCTAssertEqual(row.axis, .horizontal)

        let size = view.systemLayoutSizeFitting(CGSize(width: 300, height: 0),
                                                withHorizontalFittingPriority: .fittingSizeLevel,
                                                verticalFittingPriority: .fittingSizeLevel)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        XCTAssertLessThanOrEqual(size.width, 300)
        let chart = try XCTUnwrap(buttons.first), report = try XCTUnwrap(buttons.last)
        for button in buttons {
            XCTAssertGreaterThanOrEqual(button.frame.height, 50 - 0.5)
        }
        XCTAssertEqual(chart.frame.width, report.frame.width, accuracy: 1, "two equal halves")
        XCTAssertEqual(chart.frame.minY, report.frame.minY, accuracy: 0.5, "on one line")
        XCTAssertLessThan(chart.frame.maxX, report.frame.minX)
        // Shorter than the stacked callout of the iPad's sizes, which hid half the phone's chart.
        let stacked = VFRProcedureCallout.detailView(for: lszq, at: lszq.labelAnchor.coordinate,
                                                     metrics: .flight(.kneeboard), openChart: { _ in })
        XCTAssertLessThan(size.height, stacked.systemLayoutSizeFitting(CGSize(width: 300, height: 0),
                                                                       withHorizontalFittingPriority: .fittingSizeLevel,
                                                                       verticalFittingPriority: .fittingSizeLevel).height - 40)
        (chart as? OfficialChartControl)?.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(opened.map(\.host), ["www.skybriefing.com"])

        // Alone (no chart for the field), Report an error keeps its whole title, and the source its advice.
        let alone = VFRProcedureCallout.detailView(for: lszq, at: lszq.labelAnchor.coordinate, metrics: phone)
        XCTAssertEqual(allSubviews(of: alone).compactMap { ($0 as? UIButton)?.configuration?.title }, [L10n.VFRMap.reportError])
        XCTAssertTrue(allSubviews(of: alone).contains { ($0 as? UILabel)?.text == VFRProcedureCallout.sourceLine(for: lszq) })
    }

    // MARK: - The flight thread

    func testTheThreadOffersTheChartOnPPRAndFeeTasks() throws {
        let charts = try registry()
        let lszq = try XCTUnwrap(charts.link(for: "LSZQ", type: .smallAirport, now: october2))
        let tariff = URL(string: "https://www.example.ch/tarifs")!

        let fees = ThreadTask(key: .feesPaid, subject: "LSZQ", kind: .check)
        let withBoth = ThreadTaskPresentation.links(for: fees, tariffURL: tariff, chartLink: lszq)
        XCTAssertEqual(withBoth.map { $0.label }, [L10n.Cost.openTariff, "Official chart · SkyBriefing (subscription)"],
                       "next to the landing-fee link")
        XCTAssertEqual(withBoth.map { $0.url }, [tariff, lszq.url])
        XCTAssertEqual(ThreadTaskPresentation.links(for: fees, chartLink: lszq).map { $0.url }, [lszq.url])
        XCTAssertEqual(ThreadTaskPresentation.links(for: fees, tariffURL: tariff).map { $0.url }, [tariff])

        let ppr = ThreadTask(key: .pprObtained, subject: "EDNY", kind: .check)
        let edny = try XCTUnwrap(charts.link(for: "EDNY", type: .mediumAirport, now: october2))
        XCTAssertEqual(ThreadTaskPresentation.links(for: ppr, chartLink: edny).map { $0.label }, ["Official chart"])
        XCTAssertTrue(ThreadTaskPresentation.links(for: ppr).isEmpty)

        // A task that isn't about an aerodrome doesn't take one.
        let notam = ThreadTask(key: .notamChecked, kind: .check)
        XCTAssertFalse(ThreadTaskPresentation.links(for: notam, chartLink: lszq).contains { $0.url == lszq.url })
    }

    // MARK: - Strings

    func testTheNewStringsHaveTheirFrench() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "fr", ofType: "lproj"))
        let french = try XCTUnwrap(Bundle(path: path))
        let missing = "\u{1}missing"
        let expected = [
            "Official chart": "Carte officielle",
            "%@ (subscription)": "%@ (abonnement)",
            "Chart": "Carte",
            "Opens %@ in the browser": "Ouvre %@ dans le navigateur",
            "Report": "Signaler",
            "Subscription": "Abonnement",
            "open flightmaps · indicative": "open flightmaps · indicatif",
            "open flightmaps · AIRAC %@ · indicative": "open flightmaps · AIRAC %@ · indicatif",
        ]
        for (key, value) in expected {
            XCTAssertEqual(french.localizedString(forKey: key, value: missing, table: nil), value, key)
        }
        XCTAssertEqual(L10n.OfficialChart.subscription("SkyBriefing"), "SkyBriefing (subscription)")
    }
}
