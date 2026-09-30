import Foundation
import CoreLocation

/// Something on the chart a route can go through: an aerodrome, a navaid or a VFR reporting point.
/// The route builder turns one into a waypoint when a dropped or dragged point snaps to it, when the
/// pilot taps "+" in its callout, and when a search result is picked. Pure: the caller looks up what
/// needs a service (the aerodrome's contact frequency, the reporting point's label). (6.0.1)
enum RoutePoint {
    case aerodrome(Airport)
    case navaid(Navaid)
    case reportingPoint(ReportingPoint, ReportingPointLabel)

    var coordinate: CLLocationCoordinate2D {
        switch self {
        case .aerodrome(let airport): return airport.coordinate
        case .navaid(let navaid): return navaid.coordinate
        case .reportingPoint(let point, _): return point.coordinate
        }
    }

    /// Makes `waypoint` this point: its name, position and kind. What an earlier snap wrote goes
    /// (`replacing`: the call sign and frequency of the point the waypoint was made from), since a
    /// frequency for LSGC means nothing at WITZWIL and the nav log prints a waypoint frequency as the
    /// station to call (`RouteRadioPlanner`). What the pilot typed stays. An aerodrome brings its own
    /// ident and contact frequency, as it always did. (6.0.1, author decision 2026-09-29)
    ///
    /// - Parameters:
    ///   - asEndpoint: the waypoint is the departure or the destination, where the aircraft is on the
    ///     ground, so an unplanned altitude takes the elevation. Mid-route it would be a planned
    ///     altitude along the terrain.
    ///   - contactFrequency: the aerodrome's contact frequency (TWR, AFIS, INFO...), which becomes the
    ///     waypoint's; ignored for the other kinds.
    ///   - replacing: what a snap onto the point the waypoint was made from wrote (`snapValues`), found
    ///     with `origin(of:among:)`; nothing for a new waypoint or the pilot's own.
    func apply(to waypoint: inout FlightPlanWaypoint, asEndpoint: Bool, contactFrequency: String? = nil,
               replacing earlier: SnapValues = .none) {
        if earlier.wrote(callSign: waypoint.callSign) { waypoint.callSign = nil }
        if earlier.wrote(frequency: waypoint.frequency) { waypoint.frequency = nil }
        waypoint.coordinate = coordinate
        let elevation: Int?
        switch self {
        case .aerodrome(let airport):
            waypoint.name = airport.ident
            waypoint.callSign = airport.ident
            waypoint.frequency = contactFrequency
            waypoint.pointKind = .aerodrome
            waypoint.sourceId = airport.ident
            waypoint.code = nil
            waypoint.aerodromeICAO = nil
            elevation = airport.elevation
        case .navaid(let navaid):
            // Named by its ident, and nothing in the radio fields: the navaid's own frequency is a NAV
            // frequency (112.050, or an NDB's kHz), which the nav log printed as the station to call,
            // and its ident is no call sign. The chart has both.
            waypoint.name = navaid.identifier
            waypoint.pointKind = .navaid
            waypoint.sourceId = navaid.id
            waypoint.code = nil
            waypoint.aerodromeICAO = nil
            elevation = navaid.elevationFeet
        case .reportingPoint(let point, let label):
            // The plain name ("E"): each surface qualifies it where it has room (`routeName(_:)`).
            if let name = label.name { waypoint.name = name }
            waypoint.pointKind = .vrp
            waypoint.sourceId = point.id
            waypoint.code = point.code
            waypoint.aerodromeICAO = label.name == nil ? nil : label.aerodrome?.icao
            elevation = point.elevationFeetMSL
        }
        if waypoint.altitude == nil, asEndpoint, let elevation { waypoint.altitude = Double(elevation) }
    }

    /// A new waypoint for this point.
    func waypoint(asEndpoint: Bool, contactFrequency: String? = nil) -> FlightPlanWaypoint {
        var waypoint = FlightPlanWaypoint(coordinate: coordinate)
        apply(to: &waypoint, asEndpoint: asEndpoint, contactFrequency: contactFrequency)
        return waypoint
    }

    /// Which of the three a dropped point snaps to. By kind first, each already within its own
    /// radius: an aerodrome, then a navaid (an aerodrome wins a tie by distance), and a reporting
    /// point only when neither is in range, not merely because it is closer. (review #3)
    static func snapTarget(near coordinate: CLLocationCoordinate2D, aerodrome: Airport?, navaid: Navaid?,
                           reportingPoint: (ReportingPoint, ReportingPointLabel)?) -> RoutePoint? {
        if let aerodrome, aerodrome.distance(from: coordinate) <= (navaid?.distanceNM(from: coordinate) ?? .infinity) {
            return .aerodrome(aerodrome)
        }
        if let navaid { return .navaid(navaid) }
        if let (point, label) = reportingPoint { return .reportingPoint(point, label) }
        return nil
    }

    // MARK: - What an earlier snap wrote (6.0.1, author decision 2026-09-29)

    /// How far a waypoint may sit from the point it was snapped to and still count as made from it.
    /// A snap puts it exactly there; the waypoint editor makes a waypoint moved more than 100 m the
    /// pilot's own.
    static let originToleranceNM = 0.1

    /// What a snap onto this point writes in the radio fields, now or in an older build: an
    /// aerodrome its ident and one of its frequencies (its contact frequency; its ATIS before 6.0),
    /// a navaid its ident and, before 6.0.1, its own NAV frequency. A reporting point writes nothing.
    ///
    /// - Parameter aerodromeFrequencies: the aerodrome's published frequencies, from the airport data.
    func snapValues(aerodromeFrequencies: [String] = []) -> SnapValues {
        switch self {
        case .aerodrome(let airport): return SnapValues(callSign: airport.ident, frequencies: aerodromeFrequencies)
        case .navaid(let navaid): return SnapValues(callSign: navaid.identifier, frequencies: [navaid.frequencyValue].compactMap { $0 })
        case .reportingPoint: return .none
        }
    }

    /// The point `waypoint` was snapped to, among `candidates` (what lies at its position): by the kind
    /// and source this build records, else, for a waypoint an older build snapped (it recorded
    /// neither), the aerodrome or navaid it is named after and sits on. Nil for the pilot's own point,
    /// and for a reporting point, which wrote nothing to take back.
    static func origin(of waypoint: FlightPlanWaypoint, among candidates: [RoutePoint]) -> RoutePoint? {
        let here = waypoint.coordinate
        let near = candidates.filter { $0.distanceNM(from: here) <= originToleranceNM }
        switch waypoint.pointKind {
        case .aerodrome?, .navaid?:
            return near.first { $0.kind == waypoint.pointKind && $0.sourceId == waypoint.sourceId }
        case nil:
            let name = waypoint.name.trimmingCharacters(in: .whitespaces)
            return near.first { $0.kind != .vrp && $0.ident.caseInsensitiveCompare(name) == .orderedSame }
        case .vrp?, .user?:
            return nil
        }
    }

    /// The kind the waypoint records for this point.
    var kind: WaypointPointKind {
        switch self {
        case .aerodrome: return .aerodrome
        case .navaid: return .navaid
        case .reportingPoint: return .vrp
        }
    }

    /// What the waypoint records as its source: the aerodrome's code, the OpenAIP `_id` otherwise.
    var sourceId: String {
        switch self {
        case .aerodrome(let airport): return airport.ident
        case .navaid(let navaid): return navaid.id
        case .reportingPoint(let point, _): return point.id
        }
    }

    /// The name an older build's snap gave the waypoint: the aerodrome's or the navaid's ident.
    var ident: String {
        switch self {
        case .aerodrome(let airport): return airport.ident
        case .navaid(let navaid): return navaid.identifier
        case .reportingPoint(_, let label): return label.title
        }
    }

    func distanceNM(from coordinate: CLLocationCoordinate2D) -> Double {
        switch self {
        case .aerodrome(let airport): return airport.distance(from: coordinate)
        case .navaid(let navaid): return navaid.distanceNM(from: coordinate)
        case .reportingPoint(let point, _): return point.distanceNM(from: coordinate)
        }
    }
}

/// The call sign and the frequencies a snap may have written on a waypoint (`RoutePoint.snapValues`).
/// A value equal to one of them was the snap's, and goes when the waypoint becomes another point; any
/// other value is the pilot's, and stays. (6.0.1)
struct SnapValues: Equatable {
    var callSign: String?
    var frequencies: [String]

    static let none = SnapValues(callSign: nil, frequencies: [])

    func wrote(callSign value: String?) -> Bool {
        guard let callSign, let value else { return false }
        return value.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(callSign) == .orderedSame
    }

    /// "112.05" is the "112.050" a snap wrote: numbers compare as numbers, text as text.
    func wrote(frequency value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return false }
        return frequencies.contains { written in
            let written = written.trimmingCharacters(in: .whitespaces)
            if let a = Double(value), let b = Double(written) { return abs(a - b) < 0.0005 }
            return value.caseInsensitiveCompare(written) == .orderedSame
        }
    }
}

// MARK: - Route names (6.0.1, author decision 2026-09-29)

/// How much room a surface gives a waypoint's name, which decides whether a short reporting point
/// is qualified with its aerodrome (`ReportingPointLabel.routeName(_:aerodromeICAO:form:)`). Each
/// surface asks for its own form by name below, so the list of who shows what is in one place.
///
/// Everywhere else a waypoint goes by its plain `name`, the compact form: the other in-flight places
/// (the legs list, MARK and its toast, the route's labels on the maps, the Watch, the wingman), and
/// the ATC flight plan, whose route field takes the name as the chart prints it.
enum RouteNameForm: Equatable {
    /// The plain name, "E".
    case compact
    /// With the aerodrome, "E (LSGC)".
    case full

    /// The Cockpit strip's NEXT cell: 48 pt in a cell of 192.6 pt in iPad portrait.
    static let cockpitNext = RouteNameForm.compact
    /// The phone's next-waypoint line over the map, where the name shares a line with the figures.
    static let phoneNextLine = RouteNameForm.compact
    /// The iPad map's next-waypoint card: "E (LSGC)" on its one row, ETA included, in portrait. The
    /// card falls back to the plain name where the long one would cost a figure (in landscape beside
    /// the Cockpit's column, "NE (LSGC)" would push the ETA out), before anything else gives way.
    static let mapCard = RouteNameForm.full
    /// The route builder's list of waypoints.
    static let routeList = RouteNameForm.full
    /// The nav log, on screen (Flight Log, Set altitudes) and in its PDF and XLSX exports.
    static let navLog = RouteNameForm.full
    /// The flight share card's route strip, where each name has its own column over its time. (6.1)
    static let shareCard = RouteNameForm.full
}

extension FlightPlanWaypoint {
    /// The waypoint's name in `form`: a short reporting point's is qualified with its aerodrome where
    /// there is room ("E (LSGC)"); any other waypoint is called what it is called.
    func routeName(_ form: RouteNameForm) -> String {
        guard pointKind == .vrp else { return name }
        return ReportingPointLabel.routeName(name, aerodromeICAO: aerodromeICAO, form: form)
    }
}

extension FlightPlan {
    /// What the next-waypoint displays show: the diversion's field while diverting, else the next
    /// waypoint's name in `form` ("WPT 3" when it has none). Nil past the last waypoint.
    func nextWaypointName(_ form: RouteNameForm) -> String? {
        if let diversion { return diversion.ident }
        guard let next = nextWaypoint else { return nil }
        let name = next.routeName(form)
        return name.isEmpty ? "WPT \(currentWaypointIndex + 1)" : name
    }
}

// MARK: - Search ("Via")

/// The builder's "Via" search: reporting points and navaids by name, aerodrome or ident ("WITZWIL",
/// "LSGC E", "ELESE", "CVA"), ranked, with their distance from the route. A linear scan over what is
/// loaded (about 1 300 points for CH, FR, DE and AT, and their navaids): fine per keystroke, behind
/// the field's debounce. Aerodromes are From and To's business, not this one's. Pure. (6.0.1)
enum RoutePointSearch {

    enum Kind: Equatable { case reportingPoint(compulsory: Bool), navaid }

    struct Result: Identifiable {
        let id: String
        let point: RoutePoint
        let kind: Kind
        /// "E", "CVA".
        let title: String
        /// "LSGC Les Eplatures", "VOR/DME · CORVATSCH".
        let subtitle: String?
        /// From the route (the nearest leg), or from `reference` for a route of fewer than two points.
        let distanceNM: Double?
        /// 0 = the name (or navaid ident) itself, 1 = it starts so, 2 = by its aerodrome or navaid
        /// name, 3 = by the unofficial ident, which is the least a pilot would type.
        let tier: Int
    }

    static func search(_ query: String,
                       reportingPoints: [ReportingPoint],
                       aerodromes: [String: ReportingPointAerodrome],
                       navaids: [Navaid],
                       route: [CLLocationCoordinate2D],
                       reference: CLLocationCoordinate2D? = nil,
                       limit: Int = 8) -> [Result] {
        let tokens = ReportingPointRemarks.folded(query).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        var results: [Result] = []

        for point in reportingPoints {
            let field = point.airports?.lazy.compactMap { aerodromes[$0] }.first
            guard let tier = tier(tokens, name: point.name, qualifiers: [field?.icao, field?.name],
                                  ident: point.code) else { continue }
            let label = ReportingPointLabel(point: point, aerodrome: field)
            results.append(Result(id: "rp:" + point.id, point: .reportingPoint(point, label),
                                  kind: .reportingPoint(compulsory: point.compulsory), title: label.title,
                                  subtitle: field?.displayLine,
                                  distanceNM: distance(point.coordinate, route: route, reference: reference),
                                  tier: tier))
        }
        for navaid in navaids {
            guard let tier = tier(tokens, name: navaid.identifier, qualifiers: [navaid.name], ident: nil) else { continue }
            results.append(Result(id: "nav:" + navaid.id, point: .navaid(navaid), kind: .navaid,
                                  title: navaid.identifier, subtitle: "\(navaid.type.shortLabel) · \(navaid.name)",
                                  distanceNM: distance(navaid.coordinate, route: route, reference: reference),
                                  tier: tier))
        }

        return Array(results.sorted {
            ($0.tier, $0.distanceNM ?? .infinity, $0.title) < ($1.tier, $1.distanceNM ?? .infinity, $1.title)
        }.prefix(limit))
    }

    /// How well the tokens name the point, or nil when one of them fits nothing. Every token has to
    /// fit: the name (exactly or as its start), a qualifier (the aerodrome's code, a word of the
    /// aerodrome's or navaid's name) or the ident. Qualifiers and idents take three characters
    /// before they match a start, so "E" doesn't bring up every point of Les Eplatures.
    static func tier(_ tokens: [String], name: String?, qualifiers: [String?], ident: String?) -> Int? {
        let folded = name.map(ReportingPointRemarks.folded) ?? ""
        let qualifierWords = qualifiers.compactMap { $0 }.flatMap { ReportingPointRemarks.folded($0).split(separator: " ") }
        let foldedIdent = ident.map(ReportingPointRemarks.folded)
        var best = Int.max
        for token in tokens {
            if token == folded {
                best = min(best, 0)
            } else if folded.hasPrefix(token) {
                best = min(best, 1)
            } else if qualifierWords.contains(where: { $0 == token || (token.count >= 3 && $0.hasPrefix(token)) }) {
                best = min(best, 2)
            } else if let foldedIdent, foldedIdent == token || (token.count >= 3 && foldedIdent.hasPrefix(token)) {
                best = min(best, 3)
            } else if !folded.isEmpty, tokens.count > 1, folded == tokens.joined(separator: " ") {
                // A name of several words ("ABM AVENCHES") typed whole.
                return 0
            } else {
                return nil
            }
        }
        // The best token decides: in "LSGC E" the aerodrome narrows and the name ranks.
        return best
    }

    /// Nautical miles from the nearest leg of the route, or from `reference` when there is no leg.
    static func distance(_ coordinate: CLLocationCoordinate2D, route: [CLLocationCoordinate2D],
                         reference: CLLocationCoordinate2D?) -> Double? {
        guard route.count >= 2 else {
            let from = route.first ?? reference
            return from.map { nm(coordinate, $0) }
        }
        return zip(route, route.dropFirst()).map { crossTrackNM(coordinate, $0, $1) }.min()
    }

    private static func nm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1852
    }

    /// Distance to the segment a–b on a local flat projection: good to a tenth of a mile over a leg.
    private static func crossTrackNM(_ p: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D,
                                     _ b: CLLocationCoordinate2D) -> Double {
        let k = cos(p.latitude * .pi / 180)
        func xy(_ c: CLLocationCoordinate2D) -> (Double, Double) { (c.longitude * 60 * k, c.latitude * 60) }
        let (px, py) = xy(p), (ax, ay) = xy(a), (bx, by) = xy(b)
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared > 0 ? max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / lengthSquared)) : 0
        let cx = ax + t * dx - px, cy = ay + t * dy - py
        return (cx * cx + cy * cy).squareRoot()
    }
}
