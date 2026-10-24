import Foundation

// MARK: - A report, decoded (6.6.0)
//
// The weather proxy decodes each METAR and TAF from its raw text, whole or not at all, in the report's own units, and
// sends the fields beside the raw report (`decoded`, the server's `workers/weather/src/decode.ts`). The app only puts
// them in words (`WeatherWords`), never decodes a report itself (the author's f6 A, 24 Oct 2026). Read leniently: a
// field this build can't read is left out, never the report; a report without `decoded` shows raw, as before 6.6.0.

/// A wind group: "240° 8 kt, gusts 18", variable, calm, or more than the figure (P99KT).
struct DecodedWind: Equatable, Sendable {
    var dirDeg: Int?
    var variable = false
    var calm = false
    var speed: Int?
    var gust: Int?
    var speedAbove = false
    /// "kt", "mps", "kmh".
    var unit = "kt"
    var varFromDeg: Int?
    var varToDeg: Int?
}

/// A visibility in the report's unit: 9999 is 10000 m "atLeast"; P6SM 6 SM "moreThan".
struct DecodedVisibility: Equatable, Sendable {
    var value: Double
    /// "m" or "SM".
    var unit: String
    /// "atLeast", "moreThan", "lessThan".
    var qualifier: String?
}

struct DecodedMinimumVisibility: Equatable, Sendable {
    var value: Int
    var direction: String?
}

struct DecodedRVR: Equatable, Sendable {
    var runway: String
    var value: Int
    var qualifier: String?
    var maxValue: Int?
    var maxQualifier: String?
    var unit = "m"
    /// "up", "down", "steady".
    var trend: String?
}

/// A weather group as codes: intensity "light", "heavy", "vicinity"; a descriptor (SH, TS, FZ…); phenomena (RA, BR…).
struct DecodedWeatherGroup: Equatable, Sendable {
    var intensity: String?
    var descriptor: String?
    var phenomena: [String] = []
}

/// A cloud layer: FEW, SCT, BKN, OVC or VV (nil: an automatic station couldn't tell), its base, CB or TCU.
struct DecodedCloud: Equatable, Sendable {
    var cover: String?
    var baseFt: Int?
    var type: String?
}

/// What a report or a forecast period gives: only what changes, in a change group.
struct DecodedConditions: Equatable, Sendable {
    var wind: DecodedWind?
    var cavok = false
    var visibility: DecodedVisibility?
    var minimumVisibility: DecodedMinimumVisibility?
    var weather: [DecodedWeatherGroup] = []
    var noSignificantWeather = false
    var clouds: [DecodedCloud] = []
    /// NSC, NCD, SKC, CLR.
    var noCloud: String?

    var isEmpty: Bool {
        wind == nil && !cavok && visibility == nil && weather.isEmpty && !noSignificantWeather && clouds.isEmpty
            && noCloud == nil
    }
}

struct DecodedMetar: Equatable, Sendable {
    var conditions = DecodedConditions()
    var rvr: [DecodedRVR] = []
    var temperatureC: Double?
    var dewpointC: Double?
    var qnh: Double?
    /// "hPa" or "inHg".
    var qnhUnit = "hPa"
    var recentWeather: [DecodedWeatherGroup] = []
    var windShear: [String] = []
    var nosig = false
    var trends: [Trend] = []
    var remarks = false
    /// Groups the proxy understood without words for them (a colour state, a runway's surface).
    var extras: [String] = []

    struct Trend: Equatable, Sendable {
        /// "BECMG" or "TEMPO".
        var change: String
        var from: String?
        var until: String?
        var at: String?
        var conditions = DecodedConditions()
    }
}

struct DecodedTaf: Equatable, Sendable {
    var validFrom: Date
    var validTo: Date
    var periods: [Period] = []
    var remarks = false

    struct Period: Equatable, Sendable {
        /// "base", "FM", "BECMG", "TEMPO", "PROB", "INTER".
        var change: String
        var probability: Int?
        var tempo = false
        var from: Date
        var to: Date
        var conditions = DecodedConditions()
    }
}

// MARK: - Reading the proxy's fields, leniently

private struct Keys: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private extension KeyedDecodingContainer where K == Keys {
    func value<T: Decodable>(_ key: String, _ type: T.Type = T.self) -> T? {
        (try? decodeIfPresent(T.self, forKey: Keys(key))).flatMap { $0 }
    }
    func list<T: Decodable>(_ key: String, _ type: T.Type = T.self) -> [T] {
        guard var items = try? nestedUnkeyedContainer(forKey: Keys(key)) else { return [] }
        var read: [T] = []
        while !items.isAtEnd {
            if let item = try? items.decode(T.self) { read.append(item) } else { _ = try? items.decode(Skip.self) }
        }
        return read
    }
    func flag(_ key: String) -> Bool { value(key, Bool.self) ?? false }
}

private struct Skip: Decodable {}

extension DecodedWind: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        dirDeg = c.value("dirDeg"); variable = c.flag("variable"); calm = c.flag("calm")
        speed = c.value("speed"); gust = c.value("gust"); speedAbove = c.flag("speedAbove")
        unit = c.value("unit") ?? "kt"; varFromDeg = c.value("varFromDeg"); varToDeg = c.value("varToDeg")
    }
}

extension DecodedVisibility: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let value: Double = c.value("value"), let unit: String = c.value("unit"), unit == "m" || unit == "SM" else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "visibility"))
        }
        self.value = value; self.unit = unit; qualifier = c.value("qualifier")
    }
}

extension DecodedMinimumVisibility: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let value: Int = c.value("value") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "minimum"))
        }
        self.value = value; direction = c.value("direction")
    }
}

extension DecodedRVR: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let runway: String = c.value("runway"), let value: Int = c.value("value") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "rvr"))
        }
        self.runway = runway; self.value = value; qualifier = c.value("qualifier"); maxValue = c.value("maxValue")
        maxQualifier = c.value("maxQualifier")
        unit = c.value("unit") ?? "m"; trend = c.value("trend")
    }
}

extension DecodedWeatherGroup: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        intensity = c.value("intensity"); descriptor = c.value("descriptor"); phenomena = c.list("phenomena")
    }
}

extension DecodedCloud: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        cover = c.value("cover"); baseFt = c.value("baseFt"); type = c.value("type")
    }
}

extension DecodedConditions {
    fileprivate init(_ c: KeyedDecodingContainer<Keys>) {
        wind = c.value("wind"); cavok = c.flag("cavok"); visibility = c.value("visibility")
        minimumVisibility = c.value("minimumVisibility"); weather = c.list("weather")
        noSignificantWeather = c.flag("noSignificantWeather"); clouds = c.list("clouds"); noCloud = c.value("noCloud")
    }
}

extension DecodedMetar.Trend: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let change: String = c.value("change") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "trend"))
        }
        self.change = change; from = c.value("from"); until = c.value("until"); at = c.value("at")
        conditions = DecodedConditions(c)
    }
}

extension DecodedMetar: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        conditions = DecodedConditions(c)
        rvr = c.list("rvr"); temperatureC = c.value("temperatureC"); dewpointC = c.value("dewpointC")
        if let qnh = try? c.nestedContainer(keyedBy: Keys.self, forKey: Keys("qnh")) {
            self.qnh = qnh.value("value"); qnhUnit = qnh.value("unit") ?? "hPa"
        }
        recentWeather = c.list("recentWeather"); windShear = c.list("windShear"); nosig = c.flag("nosig")
        trends = c.list("trends"); remarks = c.flag("remarks"); extras = c.list("extras")
    }
}

extension DecodedTaf.Period: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let change: String = c.value("change"), let from = DecodedTaf.date(c.value("from")),
              let to = DecodedTaf.date(c.value("to")) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "period"))
        }
        self.change = change; self.from = from; self.to = to
        probability = c.value("probability"); tempo = c.flag("tempo"); conditions = DecodedConditions(c)
    }
}

extension DecodedTaf: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let from = Self.date(c.value("validFrom")), let to = Self.date(c.value("validTo")) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "validity"))
        }
        validFrom = from; validTo = to; periods = c.list("periods"); remarks = c.flag("remarks")
    }

    /// The proxy's ISO 8601 times, with or without fractional seconds.
    fileprivate static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

// The decoded reports travel with the station they belong to, and with the forecasts' cache: encoding isn't needed
// beyond equality, so these stay decode-only, and a type that holds them encodes them as nothing.
extension DecodedMetar: Encodable { func encode(to encoder: Encoder) throws {} }
extension DecodedTaf: Encodable { func encode(to encoder: Encoder) throws {} }
