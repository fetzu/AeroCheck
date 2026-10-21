import Foundation
import CoreLocation

/// Prepare's weather, above the tasks (the author's q1, 22 Oct 2026): the METAR and TAF of the departure, the
/// destination and the alternates, for a field without a TAF the nearest that has one, and the SIGMETs along the
/// route, from the AeroCheck weather proxy in front of NOAA's Aviation Weather Center (a US Government work, so
/// public domain). Free, outside Pro: what a pilot reads before the official briefing, never instead of it. (6.5.0)
struct PrepareWeather: Equatable {
    enum Role: Equatable {
        case departure, destination, alternate
        /// A field the route doesn't land at: the nearest TAF for one of them.
        case nearest
    }

    /// One aerodrome's reports, in the card's order.
    struct Station: Equatable, Identifiable {
        let ident: String
        /// A local flight's field is departure and destination at once: one row, both words.
        var roles: [Role]
        var metar: String?
        var taf: String?
        /// For a field without a TAF of its own: the nearest that has one.
        var nearest: Nearest?

        var id: String { ident }
    }

    struct Nearest: Equatable {
        let ident: String
        /// From the field, in NM.
        let distanceNm: Int
        /// Its reports are a row higher up the card already: said "(above)" rather than twice.
        var shownAbove = false
    }

    var stations: [Station]
    /// Nil when the SIGMETs couldn't be fetched.
    var sigmets: AviationWeatherService.RouteSigmets?
    var fetchedAt: Date

    /// An aerodrome the route names, where it is, and as what.
    struct Field: Equatable {
        let ident: String
        let coordinate: CLLocationCoordinate2D
        let role: Role

        static func == (a: Field, b: Field) -> Bool {
            a.ident == b.ident && a.role == b.role
                && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
        }
    }

    /// What was fetched for one field: the observations around it (nearest first), its own TAF, and, when it has
    /// none, the TAFs nearest it.
    struct Fetched {
        var metars: [AviationWeatherService.Metar] = []
        var ownTaf: String?
        var nearbyTafs: [AviationWeatherService.Taf.Forecast] = []
    }

    /// The card's rows: each field once, in the route's order (departure, destination, alternates), a field that
    /// has no TAF followed by the nearest that has one (its NEAREST row), unless that one is a row already (above)
    /// or a field of the route further down. Pure, for the tests.
    static func assemble(fields: [Field], fetched: [String: Fetched], sigmets: AviationWeatherService.RouteSigmets?,
                         at date: Date) -> PrepareWeather {
        let route = Set(fields.map(\.ident))
        var stations: [Station] = []
        for field in fields {
            if let index = stations.firstIndex(where: { $0.ident == field.ident }) {
                if !stations[index].roles.contains(field.role) { stations[index].roles.append(field.role) }
                continue
            }
            let data = fetched[field.ident] ?? Fetched()
            var station = Station(ident: field.ident, roles: [field.role],
                                  metar: data.metars.first { $0.icao == field.ident }?.raw, taf: data.ownTaf)
            var nearestRow: Station?
            if station.taf == nil,
               let nearby = data.nearbyTafs.first(where: { $0.icao != field.ident && $0.raw != nil }) {
                let distance = nearby.lat.flatMap { lat in nearby.lon.map { lon in
                    CLLocation(latitude: lat, longitude: lon)
                        .distance(from: CLLocation(latitude: field.coordinate.latitude, longitude: field.coordinate.longitude)) / 1852
                } } ?? 0
                let above = stations.contains { $0.ident == nearby.icao }
                station.nearest = Nearest(ident: nearby.icao, distanceNm: Int(distance.rounded()), shownAbove: above)
                if !above && !route.contains(nearby.icao) {
                    nearestRow = Station(ident: nearby.icao, roles: [.nearest],
                                         metar: data.metars.first { $0.icao == nearby.icao }?.raw, taf: nearby.raw)
                }
            }
            stations.append(station)
            if let nearestRow { stations.append(nearestRow) }
        }
        return PrepareWeather(stations: stations, sigmets: sigmets, fetchedAt: date)
    }

    /// The fields of a plan: its first waypoint, its last, and its alternates (item 16, one or two ICAO codes).
    /// A waypoint that isn't an aerodrome in the app's data (a VRP, a turning point) is left out.
    @MainActor
    static func fields(of plan: FlightPlan, airports: AirportDataService) -> [Field] {
        func field(_ ident: String, _ role: Role) -> Field? {
            let code = ident.trimmingCharacters(in: .whitespaces).uppercased()
            guard FlightThreadManager.looksLikeICAO(code), let airport = airports.findAirport(byIdent: code) else { return nil }
            return Field(ident: code, coordinate: CLLocationCoordinate2D(latitude: airport.latitude, longitude: airport.longitude),
                         role: role)
        }
        var result: [Field] = []
        if let first = plan.waypoints.first, let f = field(first.name, .departure) { result.append(f) }
        if plan.waypoints.count >= 2, let last = plan.waypoints.last, let f = field(last.name, .destination) { result.append(f) }
        for alternate in (plan.alternateAerodrome ?? "").split(whereSeparator: { $0 == " " || $0 == "," }).prefix(2) {
            if let f = field(String(alternate), .alternate) { result.append(f) }
        }
        return result
    }
}

/// Fetches Prepare's weather for a flight's page and keeps the last of each flight for ten minutes, the METARs'
/// cadence: going back to the page reads it again without asking again. Nothing is stored. (6.5.0)
@MainActor
final class PrepareWeatherService: ObservableObject {
    static let shared = PrepareWeatherService()

    enum State: Equatable {
        case loading
        case loaded(PrepareWeather)
        /// Nothing came: offline, or the proxy didn't answer.
        case failed
    }

    @Published private(set) var states: [UUID: State] = [:]
    private var keys: [UUID: [PrepareWeather.Field]] = [:]

    /// The reports are ten minutes old at most at the proxy: asking again sooner gives the same answer.
    static let maxAge: TimeInterval = 10 * 60

    func state(for threadId: UUID) -> State? { states[threadId] }

    /// Fetch for `fields` and the route, unless the same fields were fetched less than ten minutes ago (`force`, the
    /// card's refresh, asks anyway).
    func load(threadId: UUID, fields: [PrepareWeather.Field], route: [CLLocationCoordinate2D], force: Bool = false,
              now: Date = Date()) async {
        guard !fields.isEmpty else { states[threadId] = nil; return }
        if !force, keys[threadId] == fields, case .loaded(let weather)? = states[threadId],
           now.timeIntervalSince(weather.fetchedAt) < Self.maxAge { return }
        if states[threadId] == .loading { return }
        states[threadId] = .loading
        keys[threadId] = fields

        var fetched: [String: PrepareWeather.Fetched] = [:]
        var anything = false
        for field in fields where fetched[field.ident] == nil {
            async let metars = AviationWeatherService.metars(near: field.coordinate)
            async let own = AviationWeatherService.tafs(icao: field.ident)
            var data = PrepareWeather.Fetched()
            let (fetchedMetars, ownTafs) = await (metars, own)
            data.metars = fetchedMetars ?? []
            data.ownTaf = ownTafs?.first { $0.raw != nil }?.raw
            if data.ownTaf == nil {
                data.nearbyTafs = await AviationWeatherService.nearestTafs(near: field.coordinate) ?? []
            }
            anything = anything || fetchedMetars != nil || ownTafs != nil
            fetched[field.ident] = data
        }
        let sigmets = await AviationWeatherService.sigmets(along: route)
        guard anything || sigmets != nil else { states[threadId] = .failed; return }
        states[threadId] = .loaded(PrepareWeather.assemble(fields: fields, fetched: fetched, sigmets: sigmets, at: Date()))
    }
}
