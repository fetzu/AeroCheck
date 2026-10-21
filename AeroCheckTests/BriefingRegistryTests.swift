import XCTest
@testable import AeroCheck

/// The briefing registry the server builds (`/data/briefing/v1/briefing.json`) and the app only reads: decoded
/// leniently, links only on the publishers' domains, numbers only in E.164, the shipped copy for a first launch
/// offline, the DABS by the flight's day. (6.5.0)
@MainActor
final class BriefingRegistryTests: XCTestCase {

    /// A registry as the job writes it, with the faults a lenient reader must survive: a link off the allowed
    /// domains, an http link, a number that isn't E.164, an access word from a later schema, a country that
    /// isn't an object.
    private let sample = """
    {"v": 1, "generated": "2026-10-20T17:29:53Z", "countries": {
      "CH": {"weather": [{"name": "skybriefing", "url": "https://www.skybriefing.com/services/weather-briefing", "access": "paid"},
                         {"name": "MeteoSwiss", "names": {"fr": "MétéoSuisse", "de": "MeteoSchweiz"},
                          "url": "https://www.meteoswiss.admin.ch/services-and-publications/aviation-weather.html", "access": "open"}],
             "notam": [{"name": "skybriefing", "url": "https://www.skybriefing.com/services/notam-briefing", "access": "paid"},
                       {"name": "Elsewhere", "url": "https://phishing.example/notam", "access": "open"},
                       {"name": "Plain", "url": "http://www.skybriefing.com/notam", "access": "open"}],
             "airspace": [{"name": "DABS", "url": "https://www.skybriefing.com/o/dabs?today", "access": "open",
                           "byDay": {"tomorrow": "https://www.skybriefing.com/o/dabs?tomorrow", "from": "16:00", "tz": "Europe/Zurich"}}],
             "forecast": [], "filing": [{"name": "skybriefing", "url": "https://www.skybriefing.com/services/flightplan-services", "access": "someday"}],
             "closing": {"phones": [{"number": "+41800437837", "name": "skyguide ARO"}, {"number": "0800 437 837", "name": "local"}],
                         "alertMinutes": 30, "atsClose": "sera",
                         "links": [{"name": "Swiss SAR Alerts (FOCA)", "url": "https://apps.apple.com/ch/app/swiss-sar-alerts/id1496031677", "access": "open"}]},
             "generic": [], "reviewed": "2026-10-18"},
      "ES": {"weather": [], "notam": [], "airspace": [{"name": "EUROCONTROL EAUP", "url": "https://www.public.nm.eurocontrol.int/PUBPORTAL/gateway/spec/index.html", "access": "open"}],
             "forecast": [], "filing": [],
             "closing": {"phones": [], "atsClose": "sera",
                         "aerodromes": {"LEIG": {"phones": [{"number": "+34918603561", "name": "Centralised ARO, area 6"}]}}},
             "generic": ["airspace"]},
      "SE": {"weather": [], "notam": [], "airspace": [], "forecast": [], "filing": [],
             "closing": {"phones": [{"number": "+46858554505", "name": "Stockholm ACC"}], "reportMinutes": 30}, "activation": "no-ats"},
      "BY": {"weather": [], "notam": [], "airspace": [], "forecast": [], "filing": [], "closing": {"phones": []},
             "prohibited": {"name": "EASA SD-2021-02", "url": "https://ad.easa.europa.eu/ad/SD-2021-02", "access": "open"}},
      "XX": "not an object"
    }, "flags": []}
    """

    private func decoded() throws -> BriefingRegistry {
        try JSONDecoder().decode(BriefingRegistry.self, from: Data(sample.utf8))
    }

    func testTheRegistryDecodesLenientlyAndKeepsOnlyAllowedLinks() throws {
        let registry = try decoded()
        XCTAssertEqual(Set(registry.countries.keys), ["CH", "ES", "SE", "BY"], "a country that isn't an object is left out")
        let ch = try XCTUnwrap(registry.country("ch"))
        XCTAssertEqual(ch.notam.map(\.name), ["skybriefing"], "a link off the publishers' domains, or in http, is left out")
        XCTAssertEqual(ch.weather.map(\.access), [.paid, .open])
        XCTAssertNil(ch.filing.first?.access, "an access word this build doesn't know says nothing")
        XCTAssertEqual(ch.weather[1].displayName(language: "de"), "MeteoSchweiz")
        XCTAssertEqual(ch.weather[1].displayName(language: "en"), "MeteoSwiss")
        XCTAssertEqual(ch.closing.phones, [.init(number: "+41800437837", name: "skyguide ARO")], "only E.164 numbers")
        XCTAssertEqual(ch.closing.alertMinutes, 30)
        XCTAssertEqual(ch.closing.atsClose, .sera)
        XCTAssertEqual(ch.closing.links.map(\.name), ["Swiss SAR Alerts (FOCA)"])
        XCTAssertEqual(registry.country("SE")?.closing.reportMinutes, 30)
        XCTAssertEqual(registry.country("SE")?.activatesWithoutATS, true)
        XCTAssertEqual(registry.country("BY")?.prohibited?.name, "EASA SD-2021-02")
        XCTAssertNil(registry.country("IT"))
    }

    func testSpainsAerodromesHaveTheirOwnARO() throws {
        let registry = try decoded()
        XCTAssertEqual(registry.closingPhones(country: "ES", aerodrome: "leig").map(\.number), ["+34918603561"])
        XCTAssertEqual(registry.closingPhones(country: "ES", aerodrome: "LEBL"), [], "no number of the country's own")
        XCTAssertEqual(registry.closingPhones(country: "CH", aerodrome: "LSZQ").map(\.number), ["+41800437837"])
    }

    /// Today's DABS for a flight today; tomorrow's for a flight tomorrow once published at 16:00 Zurich time, and
    /// before that today's with the task saying when tomorrow's comes.
    func testTheDABSFollowsTheFlightsDay() throws {
        let dabs = try XCTUnwrap(decoded().country("CH")?.airspace.first)
        var zurich = Calendar(identifier: .gregorian)
        zurich.timeZone = TimeZone(identifier: "Europe/Zurich")!
        func at(_ day: Int, _ hour: Int) -> Date { zurich.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }
        let today = URL(string: "https://www.skybriefing.com/o/dabs?today")!
        let tomorrow = URL(string: "https://www.skybriefing.com/o/dabs?tomorrow")!
        XCTAssertEqual(dabs.url(forFlightOn: at(23, 10), now: at(23, 8)), today, "a flight today")
        XCTAssertEqual(dabs.url(forFlightOn: at(24, 10), now: at(23, 15)), today, "tomorrow's isn't out before 16:00")
        XCTAssertTrue(dabs.tomorrowNotYetOut(forFlightOn: at(24, 10), now: at(23, 15)))
        XCTAssertEqual(dabs.url(forFlightOn: at(24, 10), now: at(23, 17)), tomorrow, "tomorrow's, from 16:00")
        XCTAssertFalse(dabs.tomorrowNotYetOut(forFlightOn: at(24, 10), now: at(23, 17)))
        XCTAssertEqual(dabs.url(forFlightOn: nil, now: at(23, 17)), today, "no date: today's")
    }

    func testTheAllowListAndTheNumbers() {
        XCTAssertTrue(BriefingRegistry.isAllowed(URL(string: "https://secais.dfs.de/pilotservice/home.jsp")!))
        XCTAssertTrue(BriefingRegistry.isAllowed(URL(string: "https://dfs.de/")!))
        XCTAssertFalse(BriefingRegistry.isAllowed(URL(string: "https://notdfs.de/")!), "a suffix isn't a subdomain")
        XCTAssertFalse(BriefingRegistry.isAllowed(URL(string: "http://www.skybriefing.com/")!))
        XCTAssertTrue(BriefingRegistry.isE164("+41800437837"))
        XCTAssertFalse(BriefingRegistry.isE164("0800437837"))
        XCTAssertFalse(BriefingRegistry.isE164("+0123456789"))
    }

    /// The copy the app ships with is read in full: every country, every link on an allowed domain. A registry with
    /// a new publisher fails here at the release's sync, which is when its domain joins the allow-list.
    func testTheShippedCopyIsReadWhole() throws {
        let data = try XCTUnwrap(BriefingRegistryService.shippedData(), "AeroCheck/Resources/briefing-registry.json")
        let shipped = try XCTUnwrap(BriefingRegistryService.decodeShipped(data))
        XCTAssertGreaterThanOrEqual(shipped.countries.count, 42)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let countries = try XCTUnwrap(raw["countries"] as? [String: [String: Any]])
        for (code, entry) in countries {
            let decoded = try XCTUnwrap(shipped.country(code), code)
            for category in BriefingRegistry.Category.allCases {
                let links = entry[category.rawValue] as? [[String: Any]] ?? []
                XCTAssertEqual(decoded.links(category).count, links.count,
                               "\(code) \(category.rawValue): a link left out, its domain not allowed? \(links.map { $0["url"] ?? "" })")
            }
            let closing = entry["closing"] as? [String: Any] ?? [:]
            XCTAssertEqual(decoded.closing.phones.count, (closing["phones"] as? [Any])?.count ?? 0, "\(code) phones")
            XCTAssertEqual(decoded.closing.links.count, (closing["links"] as? [Any])?.count ?? 0, "\(code) closing links")
            XCTAssertEqual(decoded.prohibited != nil, entry["prohibited"] != nil, "\(code) prohibited")
        }
        XCTAssertEqual(shipped.country("CH")?.closing.phones.first?.number, "+41800437837")
        XCTAssertEqual(shipped.country("IT")?.notam, [], "Italy: nothing may be linked")
    }

    // MARK: The service

    private func cacheURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("briefing-\(UUID().uuidString).json")
    }

    func testWithoutADownloadTheShippedCopyIsRead() throws {
        let service = BriefingRegistryService(cacheURL: cacheURL(), bundled: Data(sample.utf8),
                                              fetch: { _ in throw URLError(.notConnectedToInternet) })
        XCTAssertEqual(service.registry?.countries.count, 4)
        XCTAssertTrue(service.isStale, "the shipped copy is always refreshed when the network allows")
    }

    func testADownloadReplacesTheShippedCopyAndIsCached() async throws {
        var newer = try JSONSerialization.jsonObject(with: Data(sample.utf8)) as! [String: Any]
        var countries = newer["countries"] as! [String: Any]
        countries.removeValue(forKey: "BY")
        newer["countries"] = countries
        let body = try JSONSerialization.data(withJSONObject: newer)
        let cache = cacheURL()
        var asked: [URL] = []
        let service = BriefingRegistryService(cacheURL: cache, bundled: Data(sample.utf8),
                                              fetch: { url in asked.append(url); return body })
        await service.refresh()
        XCTAssertEqual(asked, [BriefingRegistryService.registryURL])
        XCTAssertNil(service.registry?.country("BY"))
        XCTAssertFalse(service.isStale)
        // A relaunch reads the cache, not the shipped copy.
        let relaunched = BriefingRegistryService(cacheURL: cache, bundled: Data(sample.utf8), fetch: { _ in Data() })
        XCTAssertNil(relaunched.registry?.country("BY"))
        XCTAssertFalse(relaunched.isStale)
    }

    func testAFailedOrEmptyDownloadKeepsWhatItHad() async throws {
        let empty = try JSONSerialization.data(withJSONObject: ["v": 1, "countries": [String: Any]()])
        let service = BriefingRegistryService(cacheURL: cacheURL(), bundled: Data(sample.utf8), fetch: { _ in empty })
        await service.refresh()
        XCTAssertEqual(service.registry?.countries.count, 4, "an empty registry is never taken")
        let later = try JSONSerialization.data(withJSONObject: ["v": 2, "countries": ["CH": [String: Any]()]])
        let other = BriefingRegistryService(cacheURL: cacheURL(), bundled: Data(sample.utf8), fetch: { _ in later })
        await other.refresh()
        XCTAssertEqual(other.registry?.countries.count, 4, "a later schema is not read")
    }
}
