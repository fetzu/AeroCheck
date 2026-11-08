import CoreLocation
import Foundation

// MARK: - NOTAMs, as the server publishes them

// The server keeps one file per country and an index, at `/data/notams/v1/` behind the app-client hurdle (the private
// server repository's jobs, the contract in the plan). The app reads the files and sorts them against the flight
// (`NotamSorter`); the fields here are the server's. Additive: a key the app doesn't know is ignored, a field it does
// know may be missing, and a NOTAM that can't be read is left out of its file, never the whole file.

/// `index.json`: which countries have a list, and which don't.
struct NotamIndex: Decodable, Equatable {
    static let schema = 1

    /// A country's own line, where a gap of a known kind was measured.
    struct Note: Decodable, Equatable {
        var en: String?
        var fr: String?
        var de: String?

        /// In the app's language, else English.
        func text(language: String = AppLanguage.current) -> String? {
            switch language {
            case "fr": return fr ?? en
            case "de": return de ?? en
            default: return en
            }
        }
    }

    struct Country: Decodable, Equatable {
        let file: String
        var count: Int?
        var updatedUtc: Date?
        var note: Note?

        init(file: String, count: Int? = nil, updatedUtc: Date? = nil, note: Note? = nil) {
            self.file = file
            self.count = count
            self.updatedUtc = updatedUtc
            self.note = note
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            file = try c.decode(String.self, forKey: .file)
            count = try? c.decodeIfPresent(Int.self, forKey: .count)
            updatedUtc = (try? c.decodeIfPresent(String.self, forKey: .updatedUtc)).flatMap { $0 }.flatMap(NotamTime.date)
            note = (try? c.decodeIfPresent(Note.self, forKey: .note)).flatMap { $0 }
        }

        private enum CodingKeys: String, CodingKey { case file, count, updatedUtc, note }
    }

    let v: Int
    var generatedUtc: Date?
    var countries: [String: Country]
    var noList: [String]

    init(v: Int = schema, generatedUtc: Date? = nil, countries: [String: Country] = [:], noList: [String] = []) {
        self.v = v
        self.generatedUtc = generatedUtc
        self.countries = countries
        self.noList = noList
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        generatedUtc = (try? c.decodeIfPresent(String.self, forKey: .generatedUtc)).flatMap { $0 }.flatMap(NotamTime.date)
        var read: [String: Country] = [:]
        if let entries = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: .countries) {
            for key in entries.allKeys {
                if let country = try? entries.decode(Country.self, forKey: key) { read[key.stringValue.uppercased()] = country }
            }
        }
        countries = read
        noList = (try? c.decodeIfPresent([String].self, forKey: .noList)).flatMap { $0 }?.map { $0.uppercased() } ?? []
    }

    private enum CodingKeys: String, CodingKey { case v, generatedUtc, countries, noList }

    private struct AnyKey: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    /// A country in `noList`, or in neither list, has none.
    func hasList(_ country: String) -> Bool {
        let code = country.uppercased()
        return countries[code] != nil && !noList.contains(code)
    }
}

/// `<cc>.json`.
struct NotamFile: Decodable, Equatable {
    let v: Int
    var country: String?
    var updatedUtc: Date?
    var notams: [Notam]

    init(v: Int = NotamIndex.schema, country: String? = nil, updatedUtc: Date? = nil, notams: [Notam] = []) {
        self.v = v
        self.country = country
        self.updatedUtc = updatedUtc
        self.notams = notams
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        country = try? c.decodeIfPresent(String.self, forKey: .country)
        updatedUtc = (try? c.decodeIfPresent(String.self, forKey: .updatedUtc)).flatMap { $0 }.flatMap(NotamTime.date)
        notams = ((try? c.decodeIfPresent(LossyNotams.self, forKey: .notams)) ?? nil)?.items ?? []
    }

    private enum CodingKeys: String, CodingKey { case v, country, updatedUtc, notams }

    /// A NOTAM that can't be read is left out, never the file.
    private struct LossyNotams: Decodable {
        let items: [Notam]

        init(from decoder: Decoder) throws {
            var list = try decoder.unkeyedContainer()
            var read: [Notam] = []
            while !list.isAtEnd {
                if let notam = try? list.decode(Notam.self) {
                    read.append(notam)
                } else if (try? list.decode(Skipped.self)) == nil {
                    break
                }
            }
            items = read
        }

        private struct Skipped: Decodable {}
    }
}

/// One NOTAM. Only `id`, `number`, `location` and `text` are needed to read one.
struct Notam: Decodable, Equatable, Hashable, Identifiable {
    enum Kind: String { case aerodrome, airspace, obstacle, nav, comms, procedure, other }

    let id: String
    let number: String
    let location: String
    var fir: String?
    var q: String?
    /// "V", "I", "IV" or "K".
    var traffic: String?
    var scope: String?
    var lowerFl: Int
    var upperFl: Int
    var start: Date?
    /// Nil: permanent.
    var end: Date?
    var estimated: Bool
    var schedule: String?
    /// Item E.
    var text: String
    /// The full ICAO form.
    var icao: String
    /// The abbreviations spelled out; nil when nothing changed.
    var plain: String?
    var lat: Double?
    var lon: Double?
    var radiusNm: Double?
    /// [[lon, lat]].
    var polygon: [[Double]]?
    var kind: Kind
    /// Only on a NOTAM that creates or activates an area: the server's reading of it (6.10.0).
    var activation: NotamActivation?

    init(id: String, number: String, location: String, fir: String? = nil, q: String? = nil, traffic: String? = "IV",
         scope: String? = nil, lowerFl: Int = 0, upperFl: Int = 999, start: Date? = nil, end: Date? = nil, estimated: Bool = false,
         schedule: String? = nil, text: String, icao: String = "", plain: String? = nil, lat: Double? = nil, lon: Double? = nil,
         radiusNm: Double? = nil, polygon: [[Double]]? = nil, kind: Kind = .other, activation: NotamActivation? = nil) {
        self.id = id
        self.number = number
        self.location = location
        self.fir = fir
        self.q = q
        self.traffic = traffic
        self.scope = scope
        self.lowerFl = lowerFl
        self.upperFl = upperFl
        self.start = start
        self.end = end
        self.estimated = estimated
        self.schedule = schedule
        self.text = text
        self.icao = icao
        self.plain = plain
        self.lat = lat
        self.lon = lon
        self.radiusNm = radiusNm
        self.polygon = polygon
        self.kind = kind
        self.activation = activation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        number = try c.decode(String.self, forKey: .number)
        location = try c.decode(String.self, forKey: .location).uppercased()
        text = try c.decode(String.self, forKey: .text)
        func optional<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? { (try? c.decodeIfPresent(type, forKey: key)).flatMap { $0 } }
        // The server writes "" for a string it doesn't have.
        func words(_ key: CodingKeys) -> String? { optional(String.self, key).flatMap { $0.isEmpty ? nil : $0 } }
        fir = words(.fir)
        q = words(.q)
        traffic = words(.traffic)
        scope = words(.scope)
        // Without its band a NOTAM counts from the ground up: a sort must never lose one for a missing number.
        lowerFl = optional(Int.self, .lowerFl) ?? 0
        upperFl = optional(Int.self, .upperFl) ?? 999
        start = optional(String.self, .start).flatMap(NotamTime.date)
        end = optional(String.self, .end).flatMap(NotamTime.date)
        estimated = optional(Bool.self, .estimated) ?? false
        schedule = words(.schedule)
        icao = optional(String.self, .icao) ?? ""
        plain = words(.plain)
        lat = optional(Double.self, .lat)
        lon = optional(Double.self, .lon)
        radiusNm = optional(Double.self, .radiusNm)
        polygon = optional([[Double]].self, .polygon)
        kind = optional(String.self, .kind).flatMap(Kind.init(rawValue:)) ?? .other
        // One that can't be read is a NOTAM without one: it stays in the list.
        activation = optional(NotamActivation.self, .activation)
    }

    private enum CodingKeys: String, CodingKey {
        case id, number, location, fir, q, traffic, scope, lowerFl, upperFl, start, end, estimated, schedule, text, icao, plain
        case lat, lon, radiusNm, polygon, kind, activation
    }

    /// The same NOTAM repeated for another place on its line A. Numbers repeat between countries, not their text.
    var sameNotamKey: String { number + "\n" + text }

    /// Items F and G as written, when the NOTAM has them: "SFC" and "3300FT AMSL". The Q line's levels are the same limits
    /// rounded to a flight level, which 5000 ft AMSL isn't.
    var writtenLimits: (lower: String, upper: String)? {
        guard let match = icao.matches(of: /(?m)\bF\)\s*(.+?)\s+G\)\s*(.+?)\s*$/).last else { return nil }
        return (String(match.1), String(match.2))
    }

    /// From this radius on a NOTAM means its whole region, not a place.
    static let wholeRegionRadiusNm = 999.0
    /// The same for one that names several regions, "LFXX" on its Q line: France's five come to 460 NM. Under this one it
    /// can still be a place, like a crane on a border.
    static let severalRegionsRadiusNm = 200.0

    /// Whether the radius says a whole region: it never counts as a place, on the map or against the route.
    var isWholeRegion: Bool {
        let radius = radiusNm ?? 0
        return radius >= Self.wholeRegionRadiusNm || (radius >= Self.severalRegionsRadiusNm && fir?.hasSuffix("XX") == true)
    }

    /// A list of a series' numbers, for the offices' books: nothing a pilot reads, so it's left out (the author, 6 Nov 2026).
    var isChecklist: Bool { q?.uppercased().hasPrefix("QKK") == true }

    /// Item E, or the full form when the server has no item E.
    var shownText: String { text.isEmpty ? icao : text }
    /// The server spelled its abbreviations out: the reader's switch has something to switch to.
    var hasPlain: Bool { !(plain ?? "").isEmpty }

    /// "I": for IFR flights only. "IV", "V" and "K" concern a VFR flight.
    var isIFROnly: Bool { traffic?.uppercased() == "I" }

    /// A point, or nil where the data has none or an impossible one.
    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lon, abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// The circle a NOTAM is sorted by: its centre and radius, a whole-region radius counted as none. A shape without a
    /// centre gives the circle around its corners.
    var circle: (centre: CLLocationCoordinate2D, radiusNm: Double)? {
        if let coordinate { return (coordinate, isWholeRegion ? 0 : max(radiusNm ?? 0, 0)) }
        let corners = (polygon ?? []).compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil }
        guard !corners.isEmpty else { return nil }
        let centre = CLLocationCoordinate2D(latitude: corners.map(\.latitude).reduce(0, +) / Double(corners.count),
                                            longitude: corners.map(\.longitude).reduce(0, +) / Double(corners.count))
        return (centre, corners.map { NotamGeometry.distanceNm(centre, $0) }.max() ?? 0)
    }

    /// Whether it applies at some moment between two dates.
    func overlaps(from: Date, to: Date) -> Bool {
        (start ?? .distantPast) <= to && (end ?? .distantFuture) >= from
    }

    /// Goes from the ground to the top of the sky, as most at an aerodrome do: its band says nothing.
    var isWholeBand: Bool { lowerFl <= 0 && upperFl >= 999 }
}

/// What a NOTAM that creates or activates an area says of it, as the server read it (step 4 of the NOTAM plan, the author's
/// answers of 7 Nov 2026): the areas it names, the shapes it draws, when and how high. The server reads the NOTAM; the app
/// only checks the clock. Outside Switzerland, where nothing like the DABS exists.
struct NotamActivation: Decodable, Equatable, Hashable {
    /// R also stands for a temporary restricted area; TRA for a reserved one (TRA or TSA); M for a military area.
    enum Kind: String { case restricted = "R", danger = "D", prohibited = "P", reserved = "TRA", military = "M" }

    enum Shape: Equatable, Hashable {
        case circle(latitude: Double, longitude: Double, radiusNm: Double)
        /// One closed ring of [lon, lat].
        case polygon([[Double]])
    }

    struct Window: Equatable, Hashable {
        let start: Date
        let end: Date
    }

    let kind: Kind
    /// Letters and digits only, as `Airspace.designatorKey` reads an OpenAIP name: "LFR68A".
    var areas: [String]
    var shapes: [Shape]
    var windows: [Window]
    /// False: the server couldn't read item D, and the one window is the NOTAM's whole span.
    var exact: Bool
    var lower: ActivationFile.Limit
    var upper: ActivationFile.Limit

    init(kind: Kind, areas: [String] = [], shapes: [Shape] = [], windows: [Window], exact: Bool = true,
         lower: ActivationFile.Limit, upper: ActivationFile.Limit) {
        self.kind = kind
        self.areas = areas
        self.shapes = shapes
        self.windows = windows
        self.exact = exact
        self.lower = lower
        self.upper = upper
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let kind = Kind(rawValue: try c.decode(String.self, forKey: .kind)) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "an area kind the app doesn't know")
        }
        self.kind = kind
        areas = ((try? c.decodeIfPresent([String].self, forKey: .areas)) ?? nil)?.map { $0.uppercased() } ?? []
        shapes = ((try? c.decodeIfPresent([RawShape].self, forKey: .shapes)) ?? nil)?.compactMap(\.shape) ?? []
        windows = try c.decode([[String]].self, forKey: .windowsUtc).compactMap { pair in
            guard pair.count == 2, let start = NotamTime.date(pair[0]), let end = NotamTime.date(pair[1]), end > start else { return nil }
            return Window(start: start, end: end)
        }
        // A NOTAM's area with no window would never be active: no activation at all, the NOTAM stays in the list
        guard !windows.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .windowsUtc, in: c, debugDescription: "no window")
        }
        exact = ((try? c.decodeIfPresent(Bool.self, forKey: .exact)) ?? nil) ?? false
        lower = try c.decode(ActivationFile.Limit.self, forKey: .lower)
        upper = try c.decode(ActivationFile.Limit.self, forKey: .upper)
    }

    private enum CodingKeys: String, CodingKey { case kind, areas, shapes, windowsUtc, exact, lower, upper }

    private struct RawShape: Decodable {
        var centre: [Double]?
        var radiusNm: Double?
        var polygon: [[Double]]?

        var shape: Shape? {
            if let centre, centre.count == 2, abs(centre[0]) <= 90, abs(centre[1]) <= 180, let radiusNm, radiusNm > 0 {
                return .circle(latitude: centre[0], longitude: centre[1], radiusNm: radiusNm)
            }
            if let polygon, polygon.count >= 4, polygon.allSatisfy({ $0.count >= 2 }) { return .polygon(polygon) }
            return nil
        }
    }

    /// Active at `moment`, or within `lead` of it.
    func isActive(at moment: Date, lead: TimeInterval = 0) -> Bool {
        windows.contains { $0.start <= moment.addingTimeInterval(lead) && moment <= $0.end }
    }

    /// Whether it has a window between two moments.
    func overlaps(from: Date, to: Date) -> Bool {
        windows.contains { $0.start <= to && $0.end >= from }
    }
}

/// The contract's times: ISO 8601, with or without fractions.
enum NotamTime {
    static func date(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text) ?? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: text)
        }()
    }

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    /// "07:15".
    static func clock(_ date: Date) -> String {
        let parts = utc.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

/// Distances near a route, flat over the few NM that count here.
enum NotamGeometry {
    static func distanceNm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let (x, y) = offsetNm(from: a, to: b)
        return hypot(x, y)
    }

    /// `b` from `a` in NM, east and north.
    static func offsetNm(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        let meanLat = (a.latitude + b.latitude) / 2 * .pi / 180
        return ((b.longitude - a.longitude) * 60 * cos(meanLat), (b.latitude - a.latitude) * 60)
    }
}
