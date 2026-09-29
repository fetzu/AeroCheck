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

    /// Makes `waypoint` this point: its name, position and kind. What belonged to what the waypoint
    /// was before goes with it: a frequency or call sign for LSGC means nothing at WITZWIL, and a
    /// waypoint frequency is printed on the nav log as the station to call (`RouteRadioPlanner`).
    ///
    /// - Parameters:
    ///   - asEndpoint: the waypoint is the departure or the destination, where the aircraft is on the
    ///     ground, so an unplanned altitude takes the elevation. Mid-route it would be a planned
    ///     altitude along the terrain.
    ///   - contactFrequency: the aerodrome's contact frequency (TWR, AFIS, INFO...), which becomes the
    ///     waypoint's; ignored for the other kinds.
    func apply(to waypoint: inout FlightPlanWaypoint, asEndpoint: Bool, contactFrequency: String? = nil) {
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
            waypoint.name = navaid.identifier
            waypoint.callSign = navaid.identifier
            // Never the navaid's own frequency: it is a NAV frequency (112.050, or an NDB's kHz), and
            // the nav log printed it as the station to call. The ident is the name; the chart has it.
            waypoint.frequency = nil
            waypoint.pointKind = .navaid
            waypoint.sourceId = navaid.id
            waypoint.code = nil
            waypoint.aerodromeICAO = nil
            elevation = navaid.elevationFeet
        case .reportingPoint(let point, let label):
            // The plain name ("E"): each surface qualifies it where it has room (`routeName(_:)`).
            if let name = label.name { waypoint.name = name }
            waypoint.callSign = nil
            waypoint.frequency = nil
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
