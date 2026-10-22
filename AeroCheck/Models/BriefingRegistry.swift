import Foundation

// MARK: - The registry (briefing.json, schema v1)

/// `/data/briefing/v1/briefing.json` on the API host: for each European country the app can tell a route touches,
/// the official pages behind Prepare's tasks (weather, NOTAMs, airspace activity, area forecast, filing) and the
/// rule for closing an ATC flight plan after landing there. Built weekly in the AeroCheck server's private data job,
/// which curates every entry from the country's AIP and checks every link; the app only reads it, never derives a
/// fact of its own. Decoded leniently: a country, a link or a number the app can't read is left out, never the
/// file. (6.5.0)
struct BriefingRegistry: Codable, Equatable, Sendable {
    static let schema = 1

    let v: Int
    /// When the job last changed the file.
    let generated: String?
    let countries: [String: Country]

    /// Prepare's task kinds, as the registry names them.
    enum Category: String, CaseIterable, Codable, Sendable {
        case weather, notam, airspace, forecast, filing
    }

    /// What a link takes: `open` for anyone, a free `account`, a `paid` subscription, or `restricted` to authorised
    /// users (AEMET's AMA). A word this build doesn't know reads as nothing said.
    enum Access: String, Codable, Sendable {
        case open, account, paid, restricted
    }

    /// One official page.
    struct Link: Codable, Equatable, Sendable {
        /// The publisher, as its link must name it ("SOFIA-Briefing (DGAC)": the DGAC asks for its name).
        let name: String
        /// The publisher's own name in a language, where it has one ("MeteoSchweiz").
        var names: [String: String]?
        let url: URL
        var access: Access?
        /// A page by the flight's day: today's at `url`, tomorrow's at `tomorrow` from `from` (local, `tz`). The DABS.
        var byDay: ByDay?

        /// The name in `language`, else the registry's.
        func displayName(language: String = AppLanguage.current) -> String { names?[language] ?? name }

        /// In the type, not an extension, so it is the only one: beside the memberwise initializer, a call that
        /// leaves out `names` matched both.
        init(name: String, url: URL, access: Access? = .open, names: [String: String]? = nil, byDay: ByDay? = nil) {
            self.name = name
            self.url = url
            self.access = access
            self.names = names
            self.byDay = byDay
        }
    }

    struct ByDay: Codable, Equatable, Sendable {
        let tomorrow: URL
        /// "16:00", local time in `tz`, when tomorrow's page is published.
        let from: String
        let tz: String
    }

    /// A number to call, E.164 (`+41800437837`), and whose it is ("skyguide ARO").
    struct Phone: Codable, Equatable, Sendable {
        let number: String
        let name: String
    }

    /// What a landing at an aerodrome with air traffic services does to the plan: SERA.4020's rule (an observed
    /// landing closes it), `controlled` only at a controlled aerodrome (Germany), the `atsu` (the UK), or a `report`
    /// is always made (Belgium, Luxembourg).
    enum ATSClose: String, Codable, Sendable {
        case sera, controlled, atsu, report
    }

    struct Closing: Codable, Equatable, Sendable {
        var phones: [Phone] = []
        /// Search and rescue is alerted this long after the ETA, where the AIP ties alerting to a delay.
        var alertMinutes: Int?
        /// The arrival report is due within this long, where the AIP sets only a deadline.
        var reportMinutes: Int?
        var atsClose: ATSClose?
        var links: [Link] = []
        /// An aerodrome's own numbers, where the country has them per aerodrome (Spain's AROs).
        var aerodromes: [String: [Phone]] = [:]
    }

    struct Country: Codable, Equatable, Sendable {
        var weather: [Link] = []
        var notam: [Link] = []
        var airspace: [Link] = []
        var forecast: [Link] = []
        var filing: [Link] = []
        var closing = Closing()
        /// The categories filled with the generic links (an AIS start page, the EAUP), for the words beside them.
        var generic: [String] = []
        /// "no-ats": a plan filed from an aerodrome without ATS is activated by the pilot after take-off.
        var activation: String?
        /// Operations in the country's airspace are prohibited; the directive that says so.
        var prohibited: Link?
        /// When the entry was last checked by hand, "2026-10-18".
        var reviewed: String?

        func links(_ category: Category) -> [Link] {
            switch category {
            case .weather: return weather
            case .notam: return notam
            case .airspace: return airspace
            case .forecast: return forecast
            case .filing: return filing
            }
        }

        var activatesWithoutATS: Bool { activation == "no-ats" }
    }

    func country(_ code: String?) -> Country? {
        code.flatMap { countries[$0.uppercased()] }
    }

    /// The numbers to call after landing at `aerodrome` in `country`: the aerodrome's own where the registry has
    /// them, else the country's.
    func closingPhones(country code: String?, aerodrome: String?) -> [Phone] {
        guard let closing = country(code)?.closing else { return [] }
        if let aerodrome, let own = closing.aerodromes[aerodrome.uppercased()], !own.isEmpty { return own }
        return closing.phones
    }

    init(v: Int = BriefingRegistry.schema, generated: String? = nil, countries: [String: Country]) {
        self.v = v
        self.generated = generated
        self.countries = countries
    }

    // MARK: Decoding, leniently

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        generated = try? c.decodeIfPresent(String.self, forKey: .generated)
        var read: [String: Country] = [:]
        if let entries = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: .countries) {
            for key in entries.allKeys where key.stringValue.count == 2 {
                if let country = try? entries.decode(Country.self, forKey: key) {
                    read[key.stringValue.uppercased()] = country
                }
            }
        }
        countries = read
    }

    private enum CodingKeys: String, CodingKey { case v, generated, countries }

    struct AnyKey: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    // MARK: Which links are opened

    /// The publishers' domains (and their subdomains): a link anywhere else is not opened. The registry is ours, but
    /// a link that asks for a briefing account is exactly what a tampered file would forge, as for the chart links.
    /// A new publisher in the server's registry needs its domain here and an app release; until then its link is
    /// left out and its task stands without it.
    static let allowedDomains: Set<String> = [
        "aemet.es", "airnav.ge", "airnav.ie", "ais.fi", "aisro.ro", "albcontrol.al", "ans.lt", "apps.apple.com",
        "armats.am", "arso.gov.si", "austrocontrol.at", "avians.is", "aviation-civile.gouv.fr", "bhansa.gov.ba",
        "bulatsa.com", "chmi.cz", "crocontrol.hr", "dfs.de", "dhmi.gov.tr", "dom.org.cy", "ead-it.com", "eans.ee",
        "easa.europa.eu", "egafor.eu", "emy.gr", "enaire.es", "eurocontrol.int", "flightplanningonline.co.uk",
        "flugwetter.de", "homebriefing.com", "hungarocontrol.hu", "ilmailusaa.fi", "imgw.pl", "ipma.pt", "ippc.no",
        "ixosystem.eu", "knmi.nl", "lennuilm.ee", "lfv.se", "lgs.lv", "lps.sk", "luchtvaartmeteo.nl",
        "maltametoffice.com", "mcw.gov.cy", "met.hu", "meteo.fr", "meteoam.it", "meteolux.lu", "meteoswiss.admin.ch",
        "metoffice.gov.uk", "mgm.gov.tr", "moldatsa.md", "nats.co.uk", "nav.pt", "naviair.dk", "netbriefing.hu",
        "northavimet.com", "pansa.pl", "rlp.cz", "shmu.sk", "skeyes.be", "skybriefing.com", "sloveniacontrol.si",
        "smatsa.rs", "transport.gov.mt", "vedur.is",
    ]

    /// `url` is https on an allowed domain.
    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return allowedDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// "+41800437837": a plus, a country code that never starts with 0, 7 to 15 digits in all.
    static func isE164(_ number: String) -> Bool {
        number.range(of: #"^\+[1-9][0-9]{6,14}$"#, options: .regularExpression) != nil
    }
}

// The pieces decode leniently too: a link off the allowed domains, a number that isn't E.164 or an access word
// this build doesn't know is dropped, never the country around it.

extension BriefingRegistry.Link {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(URL.self, forKey: .url)
        guard !name.isEmpty, BriefingRegistry.isAllowed(url) else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: c, debugDescription: "not an allowed https link")
        }
        names = try? c.decodeIfPresent([String: String].self, forKey: .names)
        access = (try? c.decodeIfPresent(String.self, forKey: .access)).flatMap { $0.flatMap(BriefingRegistry.Access.init(rawValue:)) }
        byDay = (try? c.decodeIfPresent(BriefingRegistry.ByDay.self, forKey: .byDay)).flatMap { $0 }
            .flatMap { BriefingRegistry.isAllowed($0.tomorrow) ? $0 : nil }
    }
}

extension BriefingRegistry.Phone {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(String.self, forKey: .number)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        guard BriefingRegistry.isE164(number) else {
            throw DecodingError.dataCorruptedError(forKey: .number, in: c, debugDescription: "not E.164")
        }
    }
}

extension BriefingRegistry.Closing {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phones = c.lossy([BriefingRegistry.Phone].self, .phones)
        alertMinutes = (try? c.decodeIfPresent(Int.self, forKey: .alertMinutes)).flatMap { $0 }.flatMap { $0 > 0 ? $0 : nil }
        reportMinutes = (try? c.decodeIfPresent(Int.self, forKey: .reportMinutes)).flatMap { $0 }.flatMap { $0 > 0 ? $0 : nil }
        atsClose = (try? c.decodeIfPresent(String.self, forKey: .atsClose)).flatMap { $0.flatMap(BriefingRegistry.ATSClose.init(rawValue:)) }
        links = c.lossy([BriefingRegistry.Link].self, .links)
        var own: [String: [BriefingRegistry.Phone]] = [:]
        if let entries = try? c.nestedContainer(keyedBy: BriefingRegistry.AnyKey.self, forKey: .aerodromes) {
            for key in entries.allKeys {
                guard let aerodrome = try? entries.nestedContainer(keyedBy: AerodromeKeys.self, forKey: key) else { continue }
                let phones = aerodrome.lossy([BriefingRegistry.Phone].self, .phones)
                if !phones.isEmpty { own[key.stringValue.uppercased()] = phones }
            }
        }
        aerodromes = own
    }

    /// Written as the server writes it, `{"LEIG": {"phones": […]}}`, for the cache, which `init(from:)` reads back.
    /// The synthesised encoding wrote `{"LEIG": […]}`, which came back empty: after the first download, a relaunch had
    /// lost Spain's 119 AROs. (6.5.0)
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(phones, forKey: .phones)
        try c.encodeIfPresent(alertMinutes, forKey: .alertMinutes)
        try c.encodeIfPresent(reportMinutes, forKey: .reportMinutes)
        try c.encodeIfPresent(atsClose, forKey: .atsClose)
        try c.encode(links, forKey: .links)
        var own = c.nestedContainer(keyedBy: BriefingRegistry.AnyKey.self, forKey: .aerodromes)
        for (icao, phones) in aerodromes {
            guard let key = BriefingRegistry.AnyKey(stringValue: icao) else { continue }
            var aerodrome = own.nestedContainer(keyedBy: AerodromeKeys.self, forKey: key)
            try aerodrome.encode(phones, forKey: .phones)
        }
    }

    /// Declared since both directions are written by hand, which leaves nothing for Swift to synthesise them from.
    enum CodingKeys: String, CodingKey { case phones, alertMinutes, reportMinutes, atsClose, links, aerodromes }

    private enum AerodromeKeys: String, CodingKey { case phones }
}

extension BriefingRegistry.Country {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weather = c.lossy([BriefingRegistry.Link].self, .weather)
        notam = c.lossy([BriefingRegistry.Link].self, .notam)
        airspace = c.lossy([BriefingRegistry.Link].self, .airspace)
        forecast = c.lossy([BriefingRegistry.Link].self, .forecast)
        filing = c.lossy([BriefingRegistry.Link].self, .filing)
        closing = (try? c.decodeIfPresent(BriefingRegistry.Closing.self, forKey: .closing)).flatMap { $0 } ?? .init()
        generic = (try? c.decodeIfPresent([String].self, forKey: .generic)).flatMap { $0 } ?? []
        activation = (try? c.decodeIfPresent(String.self, forKey: .activation)).flatMap { $0 }
        prohibited = (try? c.decodeIfPresent(BriefingRegistry.Link.self, forKey: .prohibited)).flatMap { $0 }
        reviewed = (try? c.decodeIfPresent(String.self, forKey: .reviewed)).flatMap { $0 }
    }
}

private struct LossyList<Element: Decodable>: Decodable {
    let items: [Element]
    init(from decoder: Decoder) throws {
        var list = try decoder.unkeyedContainer()
        var read: [Element] = []
        while !list.isAtEnd {
            if let item = try? list.decode(Element.self) { read.append(item) } else { _ = try? list.decode(Skipped.self) }
        }
        items = read
    }
    private struct Skipped: Decodable {}
}

private extension KeyedDecodingContainer {
    /// An array of `Element`, each one that fails left out; empty when the key is missing or isn't an array.
    func lossy<Element: Decodable>(_ type: [Element].Type, _ key: Key) -> [Element] {
        ((try? decodeIfPresent(LossyList<Element>.self, forKey: key)) ?? nil)?.items ?? []
    }
}

// MARK: - A page by the flight's day

extension BriefingRegistry.Link {
    /// The page for a flight on `day`: tomorrow's once it is published (from `byDay.from`, local), today's
    /// otherwise. Without a day, or for a link with one page, `url`.
    func url(forFlightOn day: Date?, now: Date = Date()) -> URL {
        guard let byDay, let day, Self.isTomorrow(day, now: now, tz: byDay.tz),
              Self.isPast(byDay.from, now: now, tz: byDay.tz) else { return url }
        return byDay.tomorrow
    }

    /// True when tomorrow's page is for this flight but not out yet: the task says when it comes.
    func tomorrowNotYetOut(forFlightOn day: Date?, now: Date = Date()) -> Bool {
        guard let byDay, let day else { return false }
        return Self.isTomorrow(day, now: now, tz: byDay.tz) && !Self.isPast(byDay.from, now: now, tz: byDay.tz)
    }

    private static func calendar(_ tz: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tz) ?? .current
        return calendar
    }

    static func isTomorrow(_ day: Date, now: Date, tz: String) -> Bool {
        let calendar = calendar(tz)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return false }
        return calendar.isDate(day, inSameDayAs: tomorrow)
    }

    static func isPast(_ time: String, now: Date, tz: String) -> Bool {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return false }
        let calendar = calendar(tz)
        let current = calendar.dateComponents([.hour, .minute], from: now)
        return (current.hour ?? 0, current.minute ?? 0) >= (parts[0], parts[1])
    }
}
