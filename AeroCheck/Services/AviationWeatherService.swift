import Foundation
import CoreLocation

/// METAR, TAF and SIGMET from the AeroCheck weather proxy (which fronts NOAA's Aviation Weather
/// Center — a US Government work, so public domain).
///
/// Separate from `WindDataService` (MeteoSwiss) and `WindsAloftService` (Open-Meteo) rather than
/// folded into either: each speaks to a different upstream with a different failure mode, and the
/// choice BETWEEN them is `BriefingWindLadder`'s job, not a service's. Keeping the fetchers dumb is
/// what lets that decision be a pure, tested rule.
///
/// Every failure degrades to "no data" and is logged, never surfaced as a blocking error. A
/// briefing that cannot reach the network shows the sources it does have — which, before this
/// existed, was nothing outside Switzerland.
@MainActor
final class AviationWeatherService: ObservableObject {

    // MARK: - Published

    @Published private(set) var observations: [Metar] = []
    @Published private(set) var taf: Taf?
    @Published private(set) var sigmets: [Sigmet] = []
    @Published private(set) var lastFetch: Date?

    // MARK: - Models (mirror the proxy's normalised shape)

    struct Metar: Codable, Equatable, Identifiable {
        let icao: String
        let name: String?
        let lat: Double
        let lon: Double
        let elevationM: Double?
        let distanceNm: Double
        /// Null when the report says VRB. See `windVariable` — the two are not interchangeable.
        let windDirectionDeg: Int?
        let windVariable: Bool
        let windSpeedKt: Int?
        let windGustKt: Int?
        let temperatureC: Double?
        let dewpointC: Double?
        let altimeterHpa: Double?
        let flightCategory: String?
        let observedAt: Date?
        let raw: String?
        /// The raw report decoded by the proxy, whole, or nil: the words come from it (6.6.0, `WeatherWords`).
        var decoded: DecodedMetar? = nil

        var id: String { icao }
    }

    struct Taf: Codable, Equatable {
        let icao: String
        let forecasts: [Forecast]

        struct Forecast: Codable, Equatable {
            let icao: String
            let issuedAt: Date?
            let validFrom: Date?
            let validTo: Date?
            let raw: String?
            /// The position form only (`?lat=&lon=`): where the aerodrome is. Its distance is measured on the device:
            /// the proxy's is from the query snapped to its grid, up to 10 NM off. (6.5.0)
            var lat: Double?
            var lon: Double?
            /// The raw forecast decoded by the proxy, its periods in UTC, or nil. (6.6.0)
            var decoded: DecodedTaf? = nil
        }
    }

    struct Sigmet: Codable, Equatable, Identifiable {
        let firId: String?
        let firName: String?
        let hazard: String?
        let qualifier: String?
        let baseFt: Int?
        let topFt: Int?
        let validFrom: Date?
        let validTo: Date?
        /// Distance at FETCH time, measured to the nearest vertex. Kept for ordering when no
        /// position is available; `SigmetRelevance` recomputes it properly against live position.
        let distanceNm: Double
        let containsPoint: Bool
        /// The hazard polygon, so distance can be recomputed as the aircraft moves and the planned
        /// route can be tested against the area.
        let coords: [Coordinate]
        let raw: String?
        /// From the proxy since 6.6.0 (`workers/weather/src/sigmet.ts`), nil from an older one or where it can't be
        /// sure: "OBS" or "FCST", the levels as the text writes them, the movement and the change ("NC", "INTSF",
        /// "WKN"). The weather block's words come from these (`WeatherWords.sigmet`).
        var status: String? = nil
        var levels: Levels? = nil
        var movement: Movement? = nil
        var change: String? = nil

        /// "SFC/FL040" is a range from "SFC" to "FL040"; "TOP ABV FL390" a `topAbove` of "FL390".
        struct Levels: Encodable, Equatable {
            /// "range", "top", "topAbove", "topBelow", "above" or "below".
            var kind: String
            var base: String?
            var top: String?
        }

        struct Movement: Encodable, Equatable {
            /// A compass point as AWC writes it ("ENE"); nil when stationary.
            var direction: String?
            var speedKt: Int?
            var stationary = false
        }

        struct Coordinate: Codable, Equatable {
            let lat: Double
            let lon: Double
            var clLocation: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
        }

        var ring: [CLLocationCoordinate2D] { coords.map(\.clLocation) }

        /// With the status: an observed area and its forecast position are two records of one SIGMET, the same FIR,
        /// hazard and validity. (6.6.0)
        var id: String {
            "\(firId ?? "?")-\(hazard ?? "?")-\(validFrom?.timeIntervalSince1970 ?? 0)" + (status.map { "-" + $0 } ?? "")
        }
    }

    // MARK: - Envelopes

    private struct Envelope<T: Decodable>: Decodable {
        let success: Bool
        let data: T?
    }
    private struct MetarPayload: Decodable { let observations: [Metar] }
    private struct SigmetPayload: Decodable { let hazards: [Sigmet] }
    private struct NearbyTafPayload: Decodable { let forecasts: [Taf.Forecast] }
    /// `received` is the size of AWC's whole set: none along the route with 0 received means no data came.
    struct RouteSigmets: Decodable, Equatable {
        let received: Int
        let hazards: [Sigmet]
    }

    // MARK: - Config

    private var baseURL: String { APIConfig.weatherBaseURL }

    /// Matches the proxy's own METAR cache window. Re-asking faster cannot produce a newer report.
    private let minimumRefreshInterval: TimeInterval = 5 * 60

    /// Coordinate grid applied BEFORE a position leaves the device.
    ///
    /// The proxy snaps every incoming lat/lon to this same 0.25° grid (`GRID_DEGREES` in the weather
    /// worker) before it builds a cache key, an upstream URL, or a distance sort — so sending full
    /// precision changes nothing about the response. It only writes a live flight track into query
    /// strings that land in edge request logs. `WindsAloftService` already snaps client-side; this
    /// matches it. 0.25° is ~10-15 nm, well inside the 60 nm / 150 nm search radii below.
    nonisolated private static let gridDegrees = 0.25

    nonisolated static func snap(_ value: Double) -> Double {
        (value / gridDegrees).rounded() * gridDegrees
    }

    private var inFlight = false

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dateDecoding
        return decoder
    }()

    /// The proxy's times, with or without milliseconds. The worker writes JavaScript's "2026-10-24T14:00:00.000Z", and
    /// the stock `.iso8601` strategy has rejected the fraction on older systems (not seen on iOS 27, where it reads
    /// both; no iOS 17 runtime to check). Either form reads here. (6.6.0)
    nonisolated static let dateDecoding = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        if let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text)) {
            return date
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an ISO 8601 time: \(text)")
    }

    // MARK: - Fetch

    /// Refresh observations (and hazards) around a position.
    ///
    /// `force` bypasses the interval for an explicit user action; the periodic path must not, or a
    /// briefing left open would poll the proxy far faster than the data can change.
    func refresh(near coordinate: CLLocationCoordinate2D, force: Bool = false) async {
        if !force, let lastFetch, Date().timeIntervalSince(lastFetch) < minimumRefreshInterval {
            return
        }
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        async let metars = fetchMetars(near: coordinate)
        async let hazards = fetchSigmets(near: coordinate)
        let (fetchedMetars, fetchedHazards) = await (metars, hazards)

        // Only overwrite on success: a transient network failure must not blank a briefing that is
        // already showing a valid observation.
        if let fetchedMetars { observations = fetchedMetars }
        if let fetchedHazards { sigmets = fetchedHazards }
        if fetchedMetars != nil || fetchedHazards != nil { lastFetch = Date() }
    }

    /// TAF for a specific aerodrome. Keyed by ICAO because a TAF is issued FOR a field — the
    /// nearest one to a coordinate is frequently not the field being flown to.
    func refreshTaf(icao: String) async {
        let code = icao.uppercased()
        guard code.count == 4, code.allSatisfy({ $0.isLetter || $0.isNumber }) else { return }
        guard let url = URL(string: "\(baseURL)/v1/taf?icao=\(code)") else { return }
        if let payload: Taf = await Self.get(url) { taf = payload }
    }

    // MARK: - For Prepare's weather card (6.5.0)
    //
    // `fresh`: past the device's cache (the proxy's answers carry max-age up to 30 min), for the card's refresh. Without
    // it, a refresh in airplane mode "worked" from the cache, quitting the app included (the author's v65-18).

    /// The observations within `radiusNm` of an aerodrome, nearest first. Snapped to the proxy's grid before it
    /// leaves, as the in-flight form is: the proxy snaps it anyway.
    static func metars(near coordinate: CLLocationCoordinate2D, radiusNm: Int = 60, fresh: Bool = false) async -> [Metar]? {
        guard let url = URL(string: "\(APIConfig.weatherBaseURL)/v1/metar?lat=\(snap(coordinate.latitude))"
                            + "&lon=\(snap(coordinate.longitude))&radius=\(radiusNm)") else { return nil }
        let payload: MetarPayload? = await get(url, fresh: fresh)
        return payload?.observations
    }

    /// An aerodrome's own TAF: none (an empty list) for most GA fields.
    static func tafs(icao: String, fresh: Bool = false) async -> [Taf.Forecast]? {
        let code = icao.uppercased()
        guard code.count == 4, code.allSatisfy({ $0.isLetter || $0.isNumber }),
              let url = URL(string: "\(APIConfig.weatherBaseURL)/v1/taf?icao=\(code)") else { return nil }
        let payload: Taf? = await get(url, fresh: fresh)
        return payload?.forecasts
    }

    /// The TAFs of the aerodromes nearest a field that has none, nearest first, each with its distance.
    static func nearestTafs(near coordinate: CLLocationCoordinate2D, radiusNm: Int = 60,
                            fresh: Bool = false) async -> [Taf.Forecast]? {
        guard let url = URL(string: "\(APIConfig.weatherBaseURL)/v1/taf?lat=\(snap(coordinate.latitude))"
                            + "&lon=\(snap(coordinate.longitude))&radius=\(radiusNm)") else { return nil }
        let payload: NearbyTafPayload? = await get(url, fresh: fresh)
        return payload?.forecasts
    }

    /// The SIGMETs within `radiusNm` of a planned route (2 to 30 points: a longer route is thinned, its ends kept).
    static func sigmets(along route: [CLLocationCoordinate2D], radiusNm: Int = 30, fresh: Bool = false) async -> RouteSigmets? {
        let points = thinned(route, to: 30)
        guard points.count >= 2 else { return nil }
        let path = points.map { String(format: "%.2f,%.2f", $0.latitude, $0.longitude) }.joined(separator: ";")
        var components = URLComponents(string: "\(APIConfig.weatherBaseURL)/v1/sigmet")
        components?.queryItems = [URLQueryItem(name: "route", value: path), URLQueryItem(name: "radius", value: "\(radiusNm)")]
        guard let url = components?.url else { return nil }
        return await get(url, fresh: fresh)
    }

    /// At most `limit` points, evenly picked, the first and the last always among them.
    nonisolated static func thinned(_ route: [CLLocationCoordinate2D], to limit: Int) -> [CLLocationCoordinate2D] {
        guard route.count > limit, limit >= 2 else { return route }
        return (0..<limit).map { route[Int((Double($0) * Double(route.count - 1) / Double(limit - 1)).rounded())] }
    }

    private func fetchMetars(near coordinate: CLLocationCoordinate2D) async -> [Metar]? {
        let lat = Self.snap(coordinate.latitude)
        let lon = Self.snap(coordinate.longitude)
        guard let url = URL(string:
            "\(baseURL)/v1/metar?lat=\(lat)&lon=\(lon)&radius=60"
        ) else { return nil }
        let payload: MetarPayload? = await Self.get(url)
        return payload?.observations
    }

    private func fetchSigmets(near coordinate: CLLocationCoordinate2D) async -> [Sigmet]? {
        let lat = Self.snap(coordinate.latitude)
        let lon = Self.snap(coordinate.longitude)
        guard let url = URL(string:
            "\(baseURL)/v1/sigmet?lat=\(lat)&lon=\(lon)&radius=150"
        ) else { return nil }
        let payload: SigmetPayload? = await Self.get(url)
        return payload?.hazards
    }

    /// One request shape for all three endpoints: same client header, same envelope, same
    /// degrade-to-nil on any failure.
    private static func get<T: Decodable>(_ url: URL, fresh: Bool = false) async -> T? {
        var request = URLRequest(url: url)
        if fresh { request.cachePolicy = .reloadIgnoringLocalCacheData }
        if let secret = APIConfig.weatherClientSecret {
            request.setValue(secret, forHTTPHeaderField: "X-AeroCheck-Client")
        }
        do {
            let (data, response) = try await ExternalRequest.data(for: request)
            guard response.statusCode == 200 else {
                AppLog.general.debugLine("Aviation weather \(url.lastPathComponent): HTTP \(response.statusCode)")
                return nil
            }
            let envelope = try Self.decoder.decode(Envelope<T>.self, from: data)
            guard envelope.success else { return nil }
            return envelope.data
        } catch {
            AppLog.general.debugLine("Aviation weather fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Ladder input

    /// The observations, shaped for `BriefingWindLadder`. Kept here so the ladder stays free of
    /// any transport type and remains testable without a network stub.
    var ladderCandidates: [BriefingWindLadder.MetarCandidate] {
        observations.map {
            .init(icao: $0.icao,
                  distanceNm: $0.distanceNm,
                  elevationM: $0.elevationM,
                  directionDeg: $0.windDirectionDeg,
                  isVariable: $0.windVariable,
                  speedKt: $0.windSpeedKt,
                  gustKt: $0.windGustKt,
                  observedAt: $0.observedAt)
        }
    }
}
