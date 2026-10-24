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
        /// The two decoded, for the words first (6.6.0); nil shows the raw report alone.
        var metarDecoded: DecodedMetar?
        var tafDecoded: DecodedTaf?
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
        var ownTafDecoded: DecodedTaf?
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
            let own = data.metars.first { $0.icao == field.ident }
            var station = Station(ident: field.ident, roles: [field.role], metar: own?.raw, taf: data.ownTaf,
                                  metarDecoded: own?.decoded, tafDecoded: data.ownTafDecoded)
            var nearestRow: Station?
            // The nearest by the device's own measure: the proxy sorts from its grid point, up to 10 NM off, and put
            // Basel-Mulhouse (24 NM) before Grenchen (20 NM) for Bressaucourt. (6.5.0, the device check's live probe)
            let here = CLLocation(latitude: field.coordinate.latitude, longitude: field.coordinate.longitude)
            let candidates = data.nearbyTafs.compactMap { taf -> (taf: AviationWeatherService.Taf.Forecast, nm: Double)? in
                guard taf.icao != field.ident, taf.raw != nil, let lat = taf.lat, let lon = taf.lon else { return nil }
                return (taf, CLLocation(latitude: lat, longitude: lon).distance(from: here) / 1852)
            }
            if station.taf == nil, let (nearby, distance) = candidates.min(by: { $0.nm < $1.nm }) {
                let above = stations.contains { $0.ident == nearby.icao }
                station.nearest = Nearest(ident: nearby.icao, distanceNm: Int(distance.rounded()), shownAbove: above)
                if !above && !route.contains(nearby.icao) {
                    let metar = data.metars.first { $0.icao == nearby.icao }
                    nearestRow = Station(ident: nearby.icao, roles: [.nearest], metar: metar?.raw, taf: nearby.raw,
                                         metarDecoded: metar?.decoded, tafDecoded: nearby.decoded)
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

    /// What one fetch brought back: each field's reports, the SIGMETs, and whether anything answered at all.
    struct Outcome {
        var fetched: [String: PrepareWeather.Fetched] = [:]
        var sigmets: AviationWeatherService.RouteSigmets?
        var anything = false
    }

    typealias Fetcher = @Sendable (_ fields: [PrepareWeather.Field], _ route: [CLLocationCoordinate2D],
                                   _ fresh: Bool) async -> Outcome

    @Published private(set) var states: [UUID: State] = [:]
    /// Flights whose refresh failed while their last reports stay on the card, said so beside them. (6.5.0)
    @Published private(set) var refreshFailed: Set<UUID> = []
    private var keys: [UUID: [PrepareWeather.Field]] = [:]
    /// Each flight's latest fetch: an older one that comes back late is dropped.
    private var generations: [UUID: Int] = [:]
    private let fetcher: Fetcher

    init(fetcher: @escaping Fetcher = { fields, route, fresh in await PrepareWeatherService.fetch(fields, route, fresh: fresh) }) {
        self.fetcher = fetcher
    }

    /// The reports are ten minutes old at most at the proxy: asking again sooner gives the same answer.
    static let maxAge: TimeInterval = 10 * 60

    func state(for threadId: UUID) -> State? { states[threadId] }

    /// Fetch for `fields` and the route, unless the same fields were fetched less than ten minutes ago, or are on their
    /// way. `force`, the card's refresh, asks the network again, past the device's cache; if that fails, the last
    /// reports stay with "could not refresh" beside them, as the in-flight briefing keeps its own.
    ///
    /// The fetch runs in the service's own task, not the caller's: the card's `.task` is cancelled whenever the page
    /// redraws or closes (a flight just created does both), and its cancelled requests read as "The weather could not
    /// be fetched", with the next load turned away because the first was still loading (the author's device check,
    /// 23 Oct 2026).
    func load(threadId: UUID, fields: [PrepareWeather.Field], route: [CLLocationCoordinate2D], force: Bool = false,
              now: Date = FlightClock.displayNow) async {
        guard !fields.isEmpty else { states[threadId] = nil; return }
        if !force, keys[threadId] == fields, case .loaded(let weather)? = states[threadId],
           now.timeIntervalSince(weather.fetchedAt) < Self.maxAge { return }
        if states[threadId] == .loading, keys[threadId] == fields { return }
        let shown: PrepareWeather? = { if case .loaded(let weather)? = states[threadId] { return weather }; return nil }()
        states[threadId] = .loading
        keys[threadId] = fields
        let generation = (generations[threadId] ?? 0) + 1
        generations[threadId] = generation

        let fetcher = self.fetcher
        let outcome = await Task { await fetcher(fields, route, force) }.value
        guard generations[threadId] == generation else { return }
        if outcome.anything || outcome.sigmets != nil {
            states[threadId] = .loaded(PrepareWeather.assemble(fields: fields, fetched: outcome.fetched,
                                                               sigmets: outcome.sigmets, at: FlightClock.displayNow))
            refreshFailed.remove(threadId)
        } else if let shown {
            states[threadId] = .loaded(shown)
            refreshFailed.insert(threadId)
        } else {
            states[threadId] = .failed
            refreshFailed.remove(threadId)
        }
    }

    /// Every field at once, each with its METARs, its own TAF and the TAFs nearest it (used only when it has none: asked
    /// together rather than after, a round trip less), and the SIGMETs beside them. A cold proxy takes seconds per
    /// answer from NOAA; one field after the other made it 5 s and more (the author's device check). Once more after a
    /// second when nothing answered. `fresh` asks past the device's cache.
    nonisolated static func fetch(_ fields: [PrepareWeather.Field], _ route: [CLLocationCoordinate2D],
                                  fresh: Bool) async -> Outcome {
        var outcome = await fetchOnce(fields, route, fresh: fresh)
        if !outcome.anything, outcome.sigmets == nil, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            outcome = await fetchOnce(fields, route, fresh: true)
        }
        return outcome
    }

    private nonisolated static func fetchOnce(_ fields: [PrepareWeather.Field], _ route: [CLLocationCoordinate2D],
                                              fresh: Bool) async -> Outcome {
        var unique: [PrepareWeather.Field] = []
        for field in fields where !unique.contains(where: { $0.ident == field.ident }) { unique.append(field) }
        async let sigmets = AviationWeatherService.sigmets(along: route, fresh: fresh)
        var outcome = Outcome()
        await withTaskGroup(of: (String, PrepareWeather.Fetched, Bool).self) { group in
            for field in unique {
                group.addTask {
                    async let metars = AviationWeatherService.metars(near: field.coordinate, fresh: fresh)
                    async let own = AviationWeatherService.tafs(icao: field.ident, fresh: fresh)
                    async let nearby = AviationWeatherService.nearestTafs(near: field.coordinate, fresh: fresh)
                    let (fetchedMetars, ownTafs, nearbyTafs) = await (metars, own, nearby)
                    var data = PrepareWeather.Fetched()
                    data.metars = fetchedMetars ?? []
                    let ownTaf = ownTafs?.first { $0.raw != nil }
                    data.ownTaf = ownTaf?.raw
                    data.ownTafDecoded = ownTaf?.decoded
                    if data.ownTaf == nil { data.nearbyTafs = nearbyTafs ?? [] }
                    return (field.ident, data, fetchedMetars != nil || ownTafs != nil)
                }
            }
            for await (ident, data, answered) in group {
                outcome.fetched[ident] = data
                outcome.anything = outcome.anything || answered
            }
        }
        outcome.sigmets = await sigmets
        return outcome
    }
}
