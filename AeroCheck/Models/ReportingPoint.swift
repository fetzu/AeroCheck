import Foundation
import CoreLocation
import MapKit

/// A VFR reporting point (mandatory or on-request) from OpenAIP's keyless per-country GeoJSON export
/// (`{cc}_rpp.geojson`). Read-only nav-map markers (and, later, briefing context). (v4.1.0)
struct ReportingPoint: Codable, Identifiable, Equatable {
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

/// The aerodrome a reporting point belongs to, from OpenAIP's airport layer.
struct ReportingPointAerodrome: Equatable, Sendable {
    let icao: String?
    /// OpenAIP's name, which is in capitals ("LES EPLATURES").
    let name: String

    /// "Les Eplatures": OpenAIP's capitals set in title case, a name in mixed case left alone.
    var displayName: String {
        name == name.uppercased() ? name.capitalized(with: Locale(identifier: "en_US_POSIX")) : name
    }

    /// "LSGC Les Eplatures", or the name alone for a field without an ICAO code.
    var displayLine: String {
        guard let icao, !icao.isEmpty else { return displayName }
        return "\(icao) \(displayName)"
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

    init(point: ReportingPoint, aerodrome: ReportingPointAerodrome?) {
        let trimmed = point.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        name = (trimmed?.isEmpty ?? true) ? nil : trimmed
        title = name ?? String(localized: "Reporting point")
        status = point.compulsory ? L10n.Briefing.compulsory : L10n.Briefing.onRequest
        self.aerodrome = aerodrome
        note = ReportingPointRemarks.informativeNote(point.remarkNote, aerodromeName: aerodrome?.name)
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

    /// Labelled with the aerodrome OpenAIP gives the point, when its airport layer is on the device.
    @MainActor
    convenience init(point: ReportingPoint) {
        self.init(point: point, label: OpenAIPAirportDataService.shared.label(for: point))
    }

    var coordinate: CLLocationCoordinate2D { point.coordinate }
    var title: String? { label.title }
    var subtitle: String? { label.subtitle }

    /// Changes whenever a label could: new points (a refresh that added their aerodromes) or new
    /// aerodromes. Both counters only grow, so their sum does too.
    @MainActor
    static var labelRevision: Int {
        OpenAIPReportingPointDataService.shared.pointsRevision &+ OpenAIPAirportDataService.shared.aerodromeIndexRevision
    }

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

    /// A callout shows one subtitle line, so a note ("MAX 3500") needs the detail view, which then
    /// carries the subtitle too. Nil without a note: the plain subtitle is enough. Each map's
    /// delegate sets it on the (reused) view.
    func calloutDetailView() -> UIView? {
        guard let note = label.note else { return nil }
        let text = NSMutableAttributedString(
            string: label.subtitle + "\n",
            attributes: [.font: UIFont.aero(size: 12), .foregroundColor: UIColor.secondaryLabel])
        text.append(NSAttributedString(
            string: note,
            attributes: [.font: UIFont.aero(size: 12, weight: .semibold), .foregroundColor: UIColor.label]))
        let view = UILabel()
        view.numberOfLines = 4
        view.lineBreakMode = .byTruncatingTail
        view.attributedText = text
        return view
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
