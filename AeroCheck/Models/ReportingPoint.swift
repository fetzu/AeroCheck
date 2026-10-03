import Foundation
import CoreLocation
import MapKit

/// Where a reporting point comes from. (6.2.0)
enum ReportingPointSource: String, Codable, Sendable {
    /// OpenAIP's per-country export: the primary source, every point the app showed before 6.2.0.
    case openAIP
    /// open flightmaps, for the points OpenAIP lacks (`ReportingPointCatalog`).
    case openFlightmaps
}

/// A VFR reporting point (mandatory or on-request) from OpenAIP's keyless per-country GeoJSON export
/// (`{cc}_rpp.geojson`), or, since 6.2.0, one of the points OpenAIP lacks from open flightmaps
/// (`ReportingPointCatalog`). Read-only map markers, briefing rows and route waypoints. (v4.1.0)
struct ReportingPoint: Codable, Identifiable, Equatable {
    /// OpenAIP's `_id`, or `ofm:<OFM id>` for an open flightmaps point. A route waypoint keeps it as its
    /// `sourceId`, so neither form ever changes meaning.
    let id: String
    let name: String?
    let compulsory: Bool
    let elevationFeetMSL: Int?
    let remarks: String?
    let latitude: Double
    let longitude: Double
    /// OpenAIP `_id`s of the aerodromes the point belongs to (OpenAIP's `airports`), the same ids as
    /// `OpenAIPAirport.id`. This is what says that "E" is Les Eplatures' E: the nearest aerodrome
    /// would say Courtelary (5.5 NM, where LSGC is 8.1).
    ///
    /// Optional because a cache written before 6.0.1 has no such key. A point parsed from OpenAIP
    /// always has an array, empty when it names no aerodrome, so nil means "old cache", which
    /// `OpenAIPReportingPointDataService` refreshes once. (6.0.1)
    let airports: [String]?
    /// Where the point comes from. A cache written before 6.2.0 has no such key: OpenAIP. (6.2.0)
    let source: ReportingPointSource
    /// The ICAO code of the aerodrome the point belongs to, when the source says so by code rather
    /// than by OpenAIP id (open flightmaps). Names it "E (LSGC)" where `airports` can't. (6.2.0)
    let aerodromeICAO: String?
    /// The AIRAC cycle of an open flightmaps point ("2610"); nil for OpenAIP. (6.2.0)
    let airac: String?

    init(id: String, name: String?, compulsory: Bool, elevationFeetMSL: Int? = nil, remarks: String? = nil,
         latitude: Double, longitude: Double, airports: [String]? = [], source: ReportingPointSource = .openAIP,
         aerodromeICAO: String? = nil, airac: String? = nil) {
        self.id = id
        self.name = name
        self.compulsory = compulsory
        self.elevationFeetMSL = elevationFeetMSL
        self.remarks = remarks
        self.latitude = latitude
        self.longitude = longitude
        self.airports = airports
        self.source = source
        self.aerodromeICAO = aerodromeICAO
        self.airac = airac
    }

    /// The OpenAIP cache stores points as encoded here; one written before 6.2.0 has no `source`,
    /// `aerodromeICAO` or `airac`, and one before 6.0.1 no `airports`. Each new key is read
    /// tolerantly: a value this build can't read is its default, never a lost cache.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        compulsory = try container.decode(Bool.self, forKey: .compulsory)
        elevationFeetMSL = try container.decodeIfPresent(Int.self, forKey: .elevationFeetMSL)
        remarks = try container.decodeIfPresent(String.self, forKey: .remarks)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        airports = try container.decodeIfPresent([String].self, forKey: .airports)
        source = ((try? container.decodeIfPresent(ReportingPointSource.self, forKey: .source)) ?? nil) ?? .openAIP
        aerodromeICAO = (try? container.decodeIfPresent(String.self, forKey: .aerodromeICAO)) ?? nil
        airac = (try? container.decodeIfPresent(String.self, forKey: .airac)) ?? nil
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    /// The ident some OpenAIP contributors put in braces at the end of the remark ("ELESE" in
    /// "Les Eplatures VRP - E {ELESE}"). Unofficial: not an ICAO 5LNC and not a skyguide
    /// designator, so it is never shown as one, and never goes where ATC would read it.
    var code: String? { ReportingPointRemarks.code(in: remarks) }

    /// The remark without that ident and without stray braces, nil when nothing is left.
    var remarkNote: String? { ReportingPointRemarks.note(in: remarks) }

    func distanceNM(from coord: CLLocationCoordinate2D) -> Double {
        let here = CLLocation(latitude: latitude, longitude: longitude)
        let there = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        return here.distance(from: there) / 1852.0
    }

    /// Parse OpenAIP's per-country reporting-point GeoJSON export into `[ReportingPoint]`.
    static func parse(geoJSON data: Data) throws -> [ReportingPoint] {
        let collection = try JSONDecoder().decode(RPFeatureCollection.self, from: data)
        return collection.features.compactMap { ReportingPoint(feature: $0) }
    }

    fileprivate init?(feature: RPFeatureCollection.Feature) {
        guard feature.geometry.coordinates.count >= 2,
              CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: feature.geometry.coordinates[1],
                                                                   longitude: feature.geometry.coordinates[0])) else { return nil }
        let p = feature.properties
        self.id = p.oaipId
        self.name = p.name
        self.compulsory = p.compulsory ?? false
        self.elevationFeetMSL = p.elevation?.asFeetMSL
        self.remarks = p.remarks
        self.longitude = feature.geometry.coordinates[0]   // GeoJSON is [lon, lat]
        self.latitude = feature.geometry.coordinates[1]
        self.airports = p.airports ?? []
        self.source = .openAIP
        self.aerodromeICAO = nil
        self.airac = nil
    }
}

// MARK: - Remarks

/// OpenAIP's `remarks` on a reporting point is free text. In Switzerland it says one of three things:
/// the aerodrome in prose with an unofficial ident ("Les Eplatures VRP - E {ELESE}", "Sion airport"),
/// a limit ("MAX 3500"), or nothing. Elsewhere it is a note ("UL reporting point"), a bearing list,
/// or junk (three French points have a lone "}"). This takes it apart, so a label can show the
/// aerodrome once, as data, and keep only what the remark adds. Pure. (6.0.1)
enum ReportingPointRemarks {

    /// The first `{…}` holding 2–7 capital letters or digits: "ELESE", "SLUGA", "GEGEN".
    static func code(in remarks: String?) -> String? {
        guard let remarks else { return nil }
        var rest = Substring(remarks)
        while let open = rest.firstIndex(of: "{") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else { return nil }
            let candidate = rest[afterOpen..<close].trimmingCharacters(in: .whitespaces)
            if (2...7).contains(candidate.count),
               candidate.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) || ("0"..."9").contains($0) }) {
                return candidate
            }
            rest = rest[rest.index(after: close)...]
        }
        return nil
    }

    /// The remark with every `{…}` group and stray brace removed, each line trimmed of spaces and of
    /// the separators the removal leaves ("Les Eplatures VRP - E {ELESE}" → "Les Eplatures VRP - E").
    /// Nil when nothing is left ("}").
    static func note(in remarks: String?) -> String? {
        guard let remarks else { return nil }
        var text = ""
        var depth = 0
        for character in remarks {
            switch character {
            case "{": depth += 1
            case "}": depth = max(0, depth - 1)
            default: if depth == 0 { text.append(character) }
            }
        }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { trimSeparators(String($0).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// What the note adds once the label already names the aerodrome: nil when it only says which
    /// aerodrome the point belongs to ("Sion airport", "Les Eplatures VRP - E"), the rest when it
    /// starts with the aerodrome's name ("Geneva Helicopter VRP - Palexpo" → "Helicopter VRP -
    /// Palexpo"), and the note as it is otherwise ("MAX 3500"). Without an aerodrome the note is
    /// the only place that names it, so it stays whole.
    static func informativeNote(_ note: String?, aerodromeName: String?) -> String? {
        guard let note else { return nil }
        guard let aerodromeName else { return note }
        let rest = trimSeparators(strippingLeadingWords(of: aerodromeName, from: note) ?? note)
        guard !rest.isEmpty, !isAerodromeBoilerplate(folded(rest)) else { return nil }
        return rest
    }

    // MARK: Helpers

    private static let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-–—·,;:/"))

    private static func trimSeparators(_ text: String) -> String {
        text.trimmingCharacters(in: separators)
    }

    /// Lower case, no accents, every run of non-alphanumerics one space: "St. Gallen-Altenrhein" →
    /// "st gallen altenrhein".
    static func folded(_ text: String) -> String {
        words(in: text).map(\.folded).joined(separator: " ")
    }

    private static func words(in text: String) -> [(folded: String, range: Range<String.Index>)] {
        var result: [(String, Range<String.Index>)] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let isWordCharacter = text[index].isLetter || text[index].isNumber
            if isWordCharacter, start == nil { start = index }
            if !isWordCharacter, let s = start {
                result.append((fold(text[s..<index]), s..<index))
                start = nil
            }
            index = text.index(after: index)
        }
        if let s = start { result.append((fold(text[s..<text.endIndex]), s..<text.endIndex)) }
        return result
    }

    private static func fold(_ word: Substring) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// The note after the aerodrome's name when it starts with all of its words, else nil.
    private static func strippingLeadingWords(of name: String, from note: String) -> String? {
        let nameWords = words(in: name).map(\.folded)
        let noteWords = words(in: note)
        guard !nameWords.isEmpty, noteWords.count >= nameWords.count,
              zip(nameWords, noteWords).allSatisfy({ $0 == $1.folded }) else { return nil }
        return String(note[noteWords[nameWords.count - 1].range.upperBound...])
    }

    private static let aerodromeWords: Set<String> = [
        "airport", "aerodrome", "airfield", "aeroport", "flugplatz", "flughafen", "aeroporto",
    ]

    /// "vrp", "vrp e", "vfr reporting point", "sion airport", "st gallen altenrhein airport".
    private static func isAerodromeBoilerplate(_ folded: String) -> Bool {
        let words = folded.split(separator: " ").map(String.init)
        guard let first = words.first, let last = words.last else { return true }
        if ["vrp", "vpr", "rp"].contains(first) {
            // "VRP" alone, or "VRP - E": the point's own short name after it.
            return words.count == 1 || (words.count == 2 && words[1].count <= 3)
        }
        if folded == "vfr reporting point" || folded == "reporting point" { return true }
        return aerodromeWords.contains(last) && words.count <= 4
    }
}

// MARK: - Label

/// The aerodrome a reporting point belongs to, from OpenAIP's airport layer (or, for an open
/// flightmaps point whose aerodrome that layer doesn't have, its ICAO code alone).
struct ReportingPointAerodrome: Equatable, Sendable {
    let icao: String?
    /// OpenAIP's name, which is in capitals ("LES EPLATURES"); empty when only the code is known.
    let name: String

    /// "Les Eplatures": OpenAIP's capitals set in title case, a name in mixed case left alone.
    var displayName: String {
        name == name.uppercased() ? name.capitalized(with: Locale(identifier: "en_US_POSIX")) : name
    }

    /// "LSGC Les Eplatures", the name alone for a field without an ICAO code, the code alone for a
    /// field known only by its code ("LSZF").
    var displayLine: String {
        guard let icao, !icao.isEmpty else { return displayName }
        return name.isEmpty ? icao : "\(icao) \(displayName)"
    }
}

/// What a reporting point is called on the maps and in the briefing. Title "E" (what the VAC prints
/// and ATC says), subtitle "LSGC Les Eplatures · on request", and a note only for what the remark
/// adds ("MAX 3500"). The unofficial ident ("ELESE") is not part of it. Pure. (6.0.1)
struct ReportingPointLabel: Equatable {
    /// The point's own name, trimmed; nil when OpenAIP gives none.
    let name: String?
    let title: String
    /// "On request" or "Compulsory".
    let status: String
    let note: String?
    let aerodrome: ReportingPointAerodrome?
    /// Where an open flightmaps point comes from, "open flightmaps · AIRAC 2610"; nil for OpenAIP's,
    /// which every point was before 6.2.0. (6.2.0)
    let source: String?

    init(point: ReportingPoint, aerodrome: ReportingPointAerodrome?) {
        let trimmed = point.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        name = (trimmed?.isEmpty ?? true) ? nil : trimmed
        title = name ?? String(localized: "Reporting point")
        status = point.compulsory ? L10n.Briefing.compulsory : L10n.Briefing.onRequest
        self.aerodrome = aerodrome
        let aerodromeName = aerodrome.flatMap { $0.name.isEmpty ? nil : $0.name }
        note = ReportingPointRemarks.informativeNote(point.remarkNote, aerodromeName: aerodromeName)
        source = Self.sourceLine(of: point)
    }

    /// "open flightmaps · AIRAC 2610" (a brand and an abbreviation: the same in French).
    static func sourceLine(of point: ReportingPoint) -> String? {
        guard point.source == .openFlightmaps else { return nil }
        guard let airac = point.airac, !airac.isEmpty else { return "open flightmaps" }
        return "open flightmaps · AIRAC \(airac)"
    }

    /// "LSGC Les Eplatures · on request"; the status alone when the aerodrome is not known.
    var subtitle: String {
        guard let aerodrome else { return status }
        return "\(aerodrome.displayLine) · \(status.localizedLowercase)"
    }

    /// The point's name in a route, in the form a surface has room for (`RouteNameForm`); nil for a
    /// point without a name.
    func routeName(_ form: RouteNameForm) -> String? {
        name.map { Self.routeName($0, aerodromeICAO: aerodrome?.icao, form: form) }
    }

    /// The one place that decides how a reporting point is named in a route. Ten Swiss points are
    /// called "E", so a short name (one to three characters: "E", "NE") takes its aerodrome where
    /// there is room: "E (LSGC)". A fixed in-flight slot keeps the plain name ("E (LSGC)" needs 250 pt
    /// of the Cockpit's 192.6 pt NEXT cell in iPad portrait, and cuts off the ETE on the phone's
    /// next-waypoint line). A named point is plain everywhere ("WITZWIL"), and so is a point whose
    /// aerodrome has no ICAO code. (6.0.1, author decision 2026-09-29)
    static func routeName(_ name: String, aerodromeICAO: String?, form: RouteNameForm) -> String {
        let icao = aerodromeICAO?.trimmingCharacters(in: .whitespaces) ?? ""
        let length = name.trimmingCharacters(in: .whitespaces).count
        guard form == .full, !icao.isEmpty, (1...3).contains(length) else { return name }
        return "\(name) (\(icao))"
    }

    /// The briefing row's value: "LSGC · On request". The section already sits under an aerodrome,
    /// so its name would repeat; its code still tells a neighbour's points apart.
    var briefingValue: String {
        guard let icao = aerodrome?.icao, !icao.isEmpty else { return status }
        return "\(icao) · \(status)"
    }
}

/// MapKit annotation wrapper for a reporting point (read-only nav-map marker). Mirrors `NavaidAnnotation`.
final class ReportingPointAnnotation: NSObject, MKAnnotation {
    let point: ReportingPoint
    let label: ReportingPointLabel

    init(point: ReportingPoint, label: ReportingPointLabel) {
        self.point = point
        self.label = label
    }

    /// Labelled with the aerodrome its source gives the point, when OpenAIP's airport layer is on the
    /// device (an open flightmaps point's ICAO code otherwise).
    @MainActor
    convenience init(point: ReportingPoint) {
        self.init(point: point, label: ReportingPointCatalog.shared.label(for: point))
    }

    var coordinate: CLLocationCoordinate2D { point.coordinate }
    var title: String? { label.title }
    var subtitle: String? { label.subtitle }

    /// Changes whenever a label could: new points (a refresh that added their aerodromes, a new
    /// open flightmaps cycle) or new aerodromes. Every counter only grows, so their sum does too.
    @MainActor
    static var labelRevision: Int { ReportingPointCatalog.shared.labelRevision }

    /// Brings a map's reporting-point markers to `points`: the markers of points no longer shown go,
    /// new ones come. Nothing moves while the visible set and `labelRevision` stay the same (PERF-27);
    /// every marker is rebuilt when the revision changed, so a label never outlives its data. The
    /// three maps (the two nav maps and the builder) keep `revision` in their coordinator. (6.0.1)
    @MainActor
    static func sync(_ points: [ReportingPoint], on mapView: MKMapView, revision: inout Int) {
        var existing = mapView.annotations.compactMap { $0 as? ReportingPointAnnotation }
        let current = labelRevision
        if revision != current {
            mapView.removeAnnotations(existing)
            existing = []
            revision = current
        }
        let existingIds = Set(existing.map { $0.point.id })
        let newIds = Set(points.map { $0.id })
        guard existingIds != newIds else { return }
        mapView.removeAnnotations(existing.filter { !newIds.contains($0.point.id) })
        for point in points where !existingIds.contains(point.id) {
            mapView.addAnnotation(ReportingPointAnnotation(point: point))
        }
    }

    /// A callout shows one subtitle line, so a note ("MAX 3500") or an open flightmaps point's
    /// source ("open flightmaps · AIRAC 2610") needs the detail view, which then carries the
    /// subtitle too. Nil for an OpenAIP point without a note: the plain subtitle is enough. Each
    /// map's delegate sets it on the (reused) view.
    func calloutDetailView() -> UIView? {
        guard let text = Self.calloutDetailText(label) else { return nil }
        let view = UILabel()
        view.numberOfLines = 5
        view.lineBreakMode = .byTruncatingTail
        view.attributedText = text
        return view
    }

    /// The detail view's text: the subtitle, the note in semibold, then the source in a smaller,
    /// quieter line (6.2.0). Nil when there is neither a note nor a source.
    static func calloutDetailText(_ label: ReportingPointLabel) -> NSAttributedString? {
        guard label.note != nil || label.source != nil else { return nil }
        let text = NSMutableAttributedString(
            string: label.subtitle,
            attributes: [.font: UIFont.aero(size: 12), .foregroundColor: UIColor.secondaryLabel])
        if let note = label.note {
            text.append(NSAttributedString(
                string: "\n" + note,
                attributes: [.font: UIFont.aero(size: 12, weight: .semibold), .foregroundColor: UIColor.label]))
        }
        if let source = label.source {
            text.append(NSAttributedString(
                string: "\n" + source,
                attributes: [.font: UIFont.aero(size: 11), .foregroundColor: UIColor.secondaryLabel]))
        }
        return text
    }
}

/// Wraps a `Decodable` element so a single malformed element in an array decodes to `nil` instead of
/// aborting the whole array decode. The element boundary is still consumed (the wrapper's own decode
/// always succeeds), so per-feature failures are skipped rather than throwing. (v4.1.0 pre-tag fix — M1)
private struct FailableDecodable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?
    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Wrapped.self)
    }
}

private struct RPFeatureCollection: Decodable {
    let features: [Feature]

    // Lossy per-feature decode: one malformed feature must be SKIPPED, not abort the whole-country
    // decode (which would yield zero reporting points for the country). (v4.1.0 pre-tag fix — M1)
    private enum CodingKeys: String, CodingKey { case features }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lossy = try container.decodeIfPresent([FailableDecodable<Feature>].self, forKey: .features) ?? []
        features = lossy.compactMap(\.value)
    }

    struct Feature: Decodable {
        let properties: Properties
        let geometry: Geometry
    }
    struct Properties: Decodable {
        let oaipId: String
        let name: String?
        let compulsory: Bool?
        let elevation: MeasuredValue?
        let remarks: String?
        let airports: [String]?
        enum CodingKeys: String, CodingKey {
            case oaipId = "_id"
            case name, compulsory, elevation, remarks, airports
        }

        /// `airports` decoded leniently: a malformed list is dropped, not the point. (6.0.1)
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            oaipId = try c.decode(String.self, forKey: .oaipId)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            compulsory = try c.decodeIfPresent(Bool.self, forKey: .compulsory)
            elevation = try c.decodeIfPresent(MeasuredValue.self, forKey: .elevation)
            remarks = try c.decodeIfPresent(String.self, forKey: .remarks)
            airports = try? c.decodeIfPresent([String].self, forKey: .airports)
        }
    }
    struct Geometry: Decodable { let coordinates: [Double] }

    /// OpenAIP `{value, unit, ...}` measure. `unit == 0` is meters; else feet.
    struct MeasuredValue: Decodable {
        let value: Double
        let unit: Int
        var asFeetMSL: Int { unit == 0 ? Int((value * 3.28084).rounded()) : Int(value.rounded()) }
    }
}
