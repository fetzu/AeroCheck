import Foundation
import CoreLocation

// MARK: - open flightmaps VFR data (schema v1)
//
// The files the weekly job publishes on aerocheck.app (`scripts/vfrdata/README.md` on the `website`
// branch): `index.json`, then one file per country with its traffic circuits, VFR arrival and departure
// routes (with their sector polygons), reporting points and runway designators, for one AIRAC cycle.
//
// Decoding is lossy and hardened, like the OpenAIP layers: a procedure, area, point or runway entry
// that doesn't make sense is dropped on its own and the file keeps the rest. Only what makes the whole
// file meaningless (no country, no AIRAC, no validity, another schema version) refuses it. (6.2.0)

/// One position, published as a `[lon, lat]` pair (GeoJSON order, five decimals). A pair that isn't two
/// finite numbers on the globe is refused, so the shape that holds it can drop it alone.
struct VFRCoordinate: Hashable, Sendable, Decodable {
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(from decoder: Decoder) throws {
        var pair = try decoder.unkeyedContainer()
        let longitude = try pair.decode(Double.self)
        let latitude = try pair.decode(Double.self)
        guard Self.isValid(latitude: latitude, longitude: longitude) else {
            throw DecodingError.dataCorruptedError(in: pair, debugDescription: "Not a position on the globe")
        }
        self.init(latitude: latitude, longitude: longitude)
    }

    static func isValid(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

/// A latitude/longitude box: the extent of a shape, or the part of the map a query covers.
struct VFRBounds: Equatable, Sendable {
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    init(minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
        self.minLatitude = minLatitude
        self.maxLatitude = maxLatitude
        self.minLongitude = minLongitude
        self.maxLongitude = maxLongitude
    }

    /// The box around `coordinates`; nil when there are none.
    init?(_ coordinates: [VFRCoordinate]) {
        guard let first = coordinates.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for point in coordinates.dropFirst() {
            minLat = min(minLat, point.latitude); maxLat = max(maxLat, point.latitude)
            minLon = min(minLon, point.longitude); maxLon = max(maxLon, point.longitude)
        }
        self.init(minLatitude: minLat, maxLatitude: maxLat, minLongitude: minLon, maxLongitude: maxLon)
    }

    func intersects(_ other: VFRBounds) -> Bool {
        minLatitude <= other.maxLatitude && other.minLatitude <= maxLatitude
            && minLongitude <= other.maxLongitude && other.minLongitude <= maxLongitude
    }

    func contains(_ point: VFRCoordinate) -> Bool {
        (minLatitude...maxLatitude).contains(point.latitude) && (minLongitude...maxLongitude).contains(point.longitude)
    }
}

/// A sector drawn with a procedure: an arrival corridor ("VFR Corridor"), an Austrian noise-abatement
/// area, or an untyped area. Published as an open ring; the map closes it.
struct VFRArea: Equatable, Sendable, Decodable {
    enum Kind: String, Sendable {
        case corridor, noise, area
    }

    let kind: Kind
    let polygon: [VFRCoordinate]
    /// Where the sector's letter goes, as the weekly job computed it on OFM's full ring (its pole of
    /// inaccessibility, `label`); nil in files from before it did, and the app works it out itself.
    let labelPoint: VFRCoordinate?

    private enum CodingKeys: String, CodingKey { case kind, poly, label }

    init(kind: Kind, polygon: [VFRCoordinate], labelPoint: VFRCoordinate? = nil) {
        self.kind = kind
        self.polygon = polygon
        self.labelPoint = labelPoint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A kind this build doesn't know is still an area: drawn plain rather than lost.
        let rawKind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        kind = rawKind.flatMap(Kind.init(rawValue:)) ?? .area
        polygon = try container.decode([OFMLossy<VFRCoordinate>].self, forKey: .poly).compactMap(\.value)
        guard polygon.count >= 3 else {
            throw DecodingError.dataCorruptedError(forKey: .poly, in: container, debugDescription: "An area needs three points")
        }
        labelPoint = (try? container.decodeIfPresent(VFRCoordinate.self, forKey: .label)) ?? nil
    }
}

/// A traffic circuit, or a VFR arrival or departure route, of one aerodrome.
struct VFRProcedure: Identifiable, Equatable, Sendable, Decodable {
    enum Kind: String, CaseIterable, Sendable {
        case circuit
        case arrival = "arr"
        case departure = "dep"
    }

    /// Which aircraft the procedure is for. OFM's own usage only knows fixed wing and helicopter; the
    /// rest comes from the procedure's name (extractor rules). A plain powered circuit has no category in
    /// the file; `heavy` is the multi-engine / retractable / turbine variant.
    enum Category: String, CaseIterable, Sendable {
        case powered
        case heavy
        case glider
        case ultralight = "ul"
        case gyro
        case helicopter = "heli"
    }

    enum Usage: String, Sendable {
        case fixedWing = "fw"
        case helicopter = "heli"
    }

    /// Unique in the app: `<country>:<kind>:<OFM id>`, with `#2`, `#3`… for a repeat in the same file.
    /// OFM's ids are not unique: an arrival and a departure can share one (LSZH "ECHO (REGA)"), and so
    /// can two circuits of the same field (LOXN, EDVIN). Set by `OFMRegionFile`.
    fileprivate(set) var id: String
    /// OFM's own id, to quote in an error report.
    let ofmId: String
    /// The aerodrome's code as OFM has it: an ICAO code, or OFM's own for a field without one
    /// ("EDAGA", "LKBANO").
    let aerodrome: String
    let kind: Kind
    let name: String
    let usage: Usage?
    /// One category, or two for a circuit flown by both ("glider+ul").
    let categories: Set<Category>
    /// Circuit altitude in ft MSL, only when OFM publishes a plausible one (the extractor checks it
    /// against the aerodrome elevation). Nil: "see chart".
    let altitudeFt: Int?
    let line: [VFRCoordinate]
    /// Drawn from OFM's straight skeleton because it has no curve: the shape is indicative only.
    let isApproximate: Bool
    let areas: [VFRArea]
    /// The extent of the line and the areas.
    let bounds: VFRBounds
    /// An arrival's or departure's direction as the weekly job read it from the name (`dir`: "N", "NE"…);
    /// nil in older files, and the app reads the name itself (`VFRSectorGeometry.direction(inName:)`).
    let direction: String?
    /// The part of `line` not flown along one of the aerodrome's circuits (`offCircuit`, inclusive
    /// indices), as the weekly job found it; nil when it didn't, and the app works it out itself.
    let offCircuit: ClosedRange<Int>?

    /// Whether the procedure is for any of `categories`.
    func isFor(any categories: Set<Category>) -> Bool {
        !self.categories.isDisjoint(with: categories)
    }

    private enum CodingKeys: String, CodingKey {
        case id, ad, kind, name, use, cat, alt, line, approx, areas, dir, offCircuit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ofmId = try container.decode(String.self, forKey: .id)
        let aerodrome = try container.decode(String.self, forKey: .ad).trimmingCharacters(in: .whitespaces)
        guard !ofmId.isEmpty, !aerodrome.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "No id or aerodrome")
        }
        // A kind this build doesn't know (a transit, a hold) is not drawn as something it isn't.
        guard let kind = Kind(rawValue: try container.decode(String.self, forKey: .kind)) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown kind")
        }
        let usage = ((try? container.decodeIfPresent(String.self, forKey: .use)) ?? nil).flatMap(Usage.init(rawValue:))
        let rawCategory = (try? container.decodeIfPresent(String.self, forKey: .cat)) ?? nil
        guard let categories = Self.categories(from: rawCategory, usage: usage) else {
            // An app that doesn't know who a procedure is for can't decide whether to draw it.
            throw DecodingError.dataCorruptedError(forKey: .cat, in: container, debugDescription: "Unknown category")
        }
        let line = try container.decode([OFMLossy<VFRCoordinate>].self, forKey: .line).compactMap(\.value)
        guard line.count >= 2 else {
            throw DecodingError.dataCorruptedError(forKey: .line, in: container, debugDescription: "A line needs two points")
        }
        let areas = ((try? container.decodeIfPresent([OFMLossy<VFRArea>].self, forKey: .areas)) ?? nil)?
            .compactMap(\.value) ?? []
        let altitude = (try? container.decodeIfPresent(Double.self, forKey: .alt)) ?? nil

        self.id = ofmId
        self.ofmId = ofmId
        self.aerodrome = aerodrome
        self.kind = kind
        self.name = ((try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? ""
        self.usage = usage
        self.categories = categories
        self.altitudeFt = altitude.flatMap(Self.plausibleAltitude)
        self.line = line
        self.isApproximate = ((try? container.decodeIfPresent(Bool.self, forKey: .approx)) ?? nil) ?? false
        self.areas = areas
        // `line` has two points, so the box exists.
        self.bounds = VFRBounds(line + areas.flatMap(\.polygon))!
        let direction = ((try? container.decodeIfPresent(String.self, forKey: .dir)) ?? nil)?.uppercased()
        self.direction = direction.flatMap { VFRSectorGeometry.directions.contains($0) ? $0 : nil }
        let range = ((try? container.decodeIfPresent([Int].self, forKey: .offCircuit)) ?? nil) ?? []
        self.offCircuit = range.count == 2 && range[0] >= 0 && range[0] < range[1] && range[1] < line.count
            ? range[0]...range[1] : nil
    }

    /// `null` is a plain powered procedure (or a helicopter one, by its usage); otherwise one or more
    /// known tokens joined by `+`. Nil when a token is unknown.
    static func categories(from raw: String?, usage: Usage?) -> Set<Category>? {
        guard let raw, !raw.isEmpty else { return usage == .helicopter ? [.helicopter] : [.powered] }
        let tokens = raw.lowercased().split(separator: "+").map { Category(rawValue: String($0)) }
        guard !tokens.isEmpty, tokens.allSatisfy({ $0 != nil && $0 != .powered }) else { return nil }
        return Set(tokens.compactMap { $0 })
    }

    /// An altitude a circuit can have, in whole feet; nil otherwise.
    static func plausibleAltitude(_ feet: Double) -> Int? {
        guard feet.isFinite, feet > 0, feet < 18_000 else { return nil }
        return Int(feet.rounded())
    }
}

/// A VFR reporting point from OFM. Most are in OpenAIP too (`inOpenAIP`, computed by the extractor and
/// checked again by the app before it shows one).
struct VFRPoint: Identifiable, Equatable, Sendable, Decodable {
    enum Kind: String, CaseIterable, Sendable {
        case onRequest = "rp"
        case compulsory = "mrp"
        case enRoute = "enr"
        case helicopter = "heli"
        case glider = "gld"
    }

    /// OFM's id (`mid`), or `leg-<hash>` for a point OFM only has inside a procedure leg.
    let id: String
    let name: String
    let kind: Kind
    /// The aerodrome the point belongs to, when OFM says so.
    let aerodrome: String?
    let position: VFRCoordinate
    let inOpenAIP: Bool

    private enum CodingKeys: String, CodingKey { case id, name, kind, ad, lat, lon, inOpenAIP }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        guard !id.isEmpty, !name.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "No id or name")
        }
        guard let kind = Kind(rawValue: try container.decode(String.self, forKey: .kind)) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown kind")
        }
        self.kind = kind
        let latitude = try container.decode(Double.self, forKey: .lat)
        let longitude = try container.decode(Double.self, forKey: .lon)
        guard VFRCoordinate.isValid(latitude: latitude, longitude: longitude) else {
            throw DecodingError.dataCorruptedError(forKey: .lat, in: container, debugDescription: "Not a position on the globe")
        }
        position = VFRCoordinate(latitude: latitude, longitude: longitude)
        let aerodrome = (try? container.decodeIfPresent(String.self, forKey: .ad)) ?? nil
        self.aerodrome = aerodrome?.isEmpty == false ? aerodrome : nil
        inOpenAIP = ((try? container.decodeIfPresent(Bool.self, forKey: .inOpenAIP)) ?? nil) ?? false
    }
}

// MARK: - Files

/// One country's file (`<cc>.json`): one AIRAC cycle of one OFM region.
struct OFMRegionFile: Sendable, Decodable {
    let version: Int?
    let source: String?
    let attribution: String?
    /// OFM's region (`LSAS`, `LOVV`, `ED`, `LKAA`).
    let region: String?
    /// ISO 3166-1 alpha-2 (`CH`).
    let country: String
    /// The cycle, `YYNN` (`2610`).
    let airac: String
    /// The cycle's first day, 00:00 UTC.
    let validFrom: Date
    /// The next cycle's first day, 00:00 UTC: the data is current until then.
    let validTo: Date
    let ofmCreated: String?
    let procedures: [VFRProcedure]
    let points: [VFRPoint]
    /// Runway designators per aerodrome, as OFM has them (`["05/23"]`).
    let runways: [String: [String]]
    /// Runway thresholds per aerodrome, as OFM has them (`thresholds`), for the approach view's
    /// extended centreline; empty in older files.
    let thresholds: [String: [VFRThreshold]]
    /// How many procedures the lossy decode dropped, for the log.
    let droppedProcedures: Int

    private enum CodingKeys: String, CodingKey {
        case v, source, attribution, region, country, airac, validFrom, validTo, ofmCreated
        case procedures, points, runways, thresholds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(Int.self, forKey: .v)) ?? nil
        guard version == nil || version == OFMSchema.version else {
            throw DecodingError.dataCorruptedError(forKey: .v, in: container, debugDescription: "Another schema version")
        }
        let country = try container.decode(String.self, forKey: .country).uppercased()
        let airac = try container.decode(String.self, forKey: .airac)
        guard OFMSchema.isCountryCode(country), OFMSchema.isAIRAC(airac),
              let validFrom = OFMSchema.day(try container.decode(String.self, forKey: .validFrom)),
              let validTo = OFMSchema.day(try container.decode(String.self, forKey: .validTo)),
              validFrom < validTo else {
            throw DecodingError.dataCorruptedError(forKey: .airac, in: container, debugDescription: "No usable country, cycle or validity")
        }
        self.country = country
        self.airac = airac
        self.validFrom = validFrom
        self.validTo = validTo
        source = (try? container.decodeIfPresent(String.self, forKey: .source)) ?? nil
        attribution = (try? container.decodeIfPresent(String.self, forKey: .attribution)) ?? nil
        region = (try? container.decodeIfPresent(String.self, forKey: .region)) ?? nil
        ofmCreated = (try? container.decodeIfPresent(String.self, forKey: .ofmCreated)) ?? nil

        let rawProcedures = ((try? container.decodeIfPresent([OFMLossy<VFRProcedure>].self, forKey: .procedures)) ?? nil) ?? []
        var decoded = rawProcedures.compactMap(\.value)
        droppedProcedures = rawProcedures.count - decoded.count
        // Unique ids, stable from one download of the same file to the next (the file's order is).
        var seen: [String: Int] = [:]
        for index in decoded.indices {
            let base = "\(country):\(decoded[index].kind.rawValue):\(decoded[index].ofmId)"
            let count = seen[base, default: 0] + 1
            seen[base] = count
            decoded[index].id = count == 1 ? base : "\(base)#\(count)"
        }
        procedures = decoded
        points = (((try? container.decodeIfPresent([OFMLossy<VFRPoint>].self, forKey: .points)) ?? nil) ?? [])
            .compactMap(\.value)
        let rawRunways = ((try? container.decodeIfPresent([String: OFMLossy<[String]>].self, forKey: .runways)) ?? nil) ?? [:]
        runways = rawRunways.compactMapValues { entry -> [String]? in
            let designators = (entry.value ?? []).filter { !$0.isEmpty }
            return designators.isEmpty ? nil : designators
        }
        let rawThresholds = ((try? container.decodeIfPresent([String: [OFMLossy<VFRThreshold>]].self,
                                                             forKey: .thresholds)) ?? nil) ?? [:]
        thresholds = rawThresholds.reduce(into: [:]) { result, entry in
            let ends = entry.value.compactMap(\.value)
            if !ends.isEmpty { result[entry.key.uppercased()] = ends }
        }
    }
}

/// One runway end as OFM publishes it: its designator, its threshold, its true bearing. (6.2.0)
struct VFRThreshold: Equatable, Sendable, Decodable {
    let runway: String
    let position: VFRCoordinate
    let trueBearing: Double?

    private enum CodingKeys: String, CodingKey { case rwy, pos, trueBrg }

    init(runway: String, position: VFRCoordinate, trueBearing: Double?) {
        self.runway = runway
        self.position = position
        self.trueBearing = trueBearing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runway = try container.decode(String.self, forKey: .rwy).trimmingCharacters(in: .whitespaces)
        guard !runway.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .rwy, in: container, debugDescription: "No designator")
        }
        position = try container.decode(VFRCoordinate.self, forKey: .pos)
        let bearing = (try? container.decodeIfPresent(Double.self, forKey: .trueBrg)) ?? nil
        trueBearing = bearing.flatMap { $0.isFinite && (0...360).contains($0) ? $0 : nil }
    }
}

/// `index.json`: what the app reads first. One entry per country, the attribution, and where OFM takes
/// error reports (both can change without an app release).
struct OFMIndex: Sendable, Decodable {
    struct Region: Equatable, Sendable, Decodable {
        let airac: String
        let validFrom: Date?
        let validTo: Date?
        /// Where the file is, absolute or relative to `index.json`.
        let url: String
        /// Lower-case hex SHA-256 of the file's bytes.
        let sha256: String
        let bytes: Int64?
        let procedures: Int?
        let points: Int?

        private enum CodingKeys: String, CodingKey {
            case airac, validFrom, validTo, url, sha256, bytes, procedures, points
        }

        init(airac: String, validFrom: Date?, validTo: Date?, url: String, sha256: String,
             bytes: Int64?, procedures: Int?, points: Int?) {
            self.airac = airac
            self.validFrom = validFrom
            self.validTo = validTo
            self.url = url
            self.sha256 = sha256
            self.bytes = bytes
            self.procedures = procedures
            self.points = points
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            airac = try container.decode(String.self, forKey: .airac)
            url = try container.decode(String.self, forKey: .url)
            sha256 = try container.decode(String.self, forKey: .sha256).lowercased()
            guard OFMSchema.isAIRAC(airac), !url.isEmpty, OFMSchema.isSHA256(sha256) else {
                throw DecodingError.dataCorruptedError(forKey: .sha256, in: container, debugDescription: "No usable cycle, URL or checksum")
            }
            validFrom = ((try? container.decodeIfPresent(String.self, forKey: .validFrom)) ?? nil).flatMap(OFMSchema.day)
            validTo = ((try? container.decodeIfPresent(String.self, forKey: .validTo)) ?? nil).flatMap(OFMSchema.day)
            bytes = (try? container.decodeIfPresent(Int64.self, forKey: .bytes)) ?? nil
            procedures = (try? container.decodeIfPresent(Int.self, forKey: .procedures)) ?? nil
            points = (try? container.decodeIfPresent(Int.self, forKey: .points)) ?? nil
        }
    }

    /// OFM's "Open flightmaps error reporting" form and the field that takes the description.
    struct ReportForm: Equatable, Sendable, Decodable {
        let url: URL
        let field: String
    }

    let version: Int?
    let generated: String?
    /// ISO-2 country → its file.
    let regions: [String: Region]
    let attribution: String?
    let reportForm: ReportForm?
    let reportMail: String?

    /// The countries OFM data is published for, sorted.
    var countries: [String] { regions.keys.sorted() }

    private enum CodingKeys: String, CodingKey {
        case v, generated, regions, attribution, reportForm, reportMail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decodeIfPresent(Int.self, forKey: .v)) ?? nil
        guard version == nil || version == OFMSchema.version else {
            throw DecodingError.dataCorruptedError(forKey: .v, in: container, debugDescription: "Another schema version")
        }
        let raw = try container.decode([String: OFMLossy<Region>].self, forKey: .regions)
        var regions: [String: Region] = [:]
        for (country, entry) in raw {
            let code = country.uppercased()
            guard OFMSchema.isCountryCode(code), let entry = entry.value else { continue }
            regions[code] = entry
        }
        self.regions = regions
        generated = (try? container.decodeIfPresent(String.self, forKey: .generated)) ?? nil
        attribution = (try? container.decodeIfPresent(String.self, forKey: .attribution)) ?? nil
        reportForm = (try? container.decodeIfPresent(ReportForm.self, forKey: .reportForm)) ?? nil
        reportMail = (try? container.decodeIfPresent(String.self, forKey: .reportMail)) ?? nil
    }
}

// MARK: - Schema helpers

enum OFMSchema {
    /// The schema this build reads (the `v1/` in the URL).
    static let version = 1

    /// `YYYY-MM-DD` as 00:00 UTC that day: AIRAC cycles change at midnight UTC.
    static func day(_ text: String) -> Date? {
        let parts = text.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = utcCalendar.date(from: components),
              utcCalendar.component(.day, from: date) == day else { return nil }   // no 31 February
        return date
    }

    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static func isAIRAC(_ text: String) -> Bool {
        text.count == 4 && text.allSatisfy(\.isASCIIDigit)
    }

    /// Whether cycle `a` comes after cycle `b` (`2701` after `2613`).
    static func isCycle(_ a: String, newerThan b: String) -> Bool {
        guard let a = Int(a), let b = Int(b) else { return false }
        return a > b
    }

    static func isCountryCode(_ text: String) -> Bool {
        text.count == 2 && text.allSatisfy { $0.isASCII && $0.isUppercase }
    }

    static func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy(\.isHexDigit)
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// One element of a lossy array or dictionary: nil instead of a thrown error, so a bad one is dropped
/// on its own.
private struct OFMLossy<Wrapped: Decodable>: Decodable {
    let value: Wrapped?
    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Wrapped.self)
    }
}
