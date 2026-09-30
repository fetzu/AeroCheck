import Foundation
import CoreLocation
import Combine

/// Forecast winds aloft for FLIGHT PLANNING, fetched from `wx.aerocheck.app`.
///
/// WHY THIS IS SEPARATE FROM `WindDataService`
///
/// They answer different questions and are fit for different jobs, which is the whole point:
///
///   * `WindDataService` reads MeteoSwiss SURFACE stations. Right for departure and approach
///     briefings, because those happen at the surface next to an airfield. Switzerland only.
///   * This service reads model winds at pressure levels. Right for computing a leg's ground speed
///     and ETA *before* the flight. Worldwide.
///
/// Neither drives anything in flight. The in-flight speed readout is GPS ground speed and nothing
/// else — see `SpeedIndicatorView.annunciationState` for why the previous wind-derived airspeed
/// estimate and its stall annunciation were removed.
///
/// WHY IT GOES THROUGH OUR OWN WORKER RATHER THAN CALLING OPEN-METEO DIRECTLY
///
/// Open-Meteo's hosted API is free for non-commercial use only; the commercial plan is
/// authenticated. Routing through `wx.aerocheck.app` means that key never has to ship inside the
/// app binary, where it would be extractable (same reasoning as the OpenAIP key note in CLAUDE.md).
/// The worker also caches per (0.25° cell, hour), so many pilots planning in the same region cost
/// one upstream call rather than one each.
@MainActor
final class WindsAloftService: ObservableObject {

    /// One forecast level. Heights are geopotential, in feet AMSL.
    struct Level: Decodable, Equatable {
        let pressureHPa: Int
        let heightFt: Int
        let directionDeg: Double
        let speedKt: Double
    }

    struct Forecast: Decodable, Equatable {
        let lat: Double
        let lon: Double
        let validAt: String
        let levels: [Level]
        /// Model 10 m wind, when the proxy supplied one. Optional because it is absent whenever
        /// the upstream omitted a component — never zero-filled, since 000/00 is a real reading.
        ///
        /// `var` with a default purely so the synthesized memberwise initialiser keeps this
        /// parameter optional: every existing construction site describes a forecast's LEVELS, and
        /// a genuinely additive field should not force each of them to say `surface: nil`.
        /// Decoding is unaffected — `init(from:)` populates it from JSON when the key is present.
        var surface: Surface? = nil
    }

    /// Model surface wind. NOT an observation: a 2-11 km cell measured 154 degrees out on
    /// direction against the MeteoSwiss station at Sion. Only ever the last rung of the ladder.
    struct Surface: Decodable, Equatable {
        let speedKt: Int
        let directionDeg: Int
        let gustKt: Int?
        let validAt: String?
    }

    private struct Envelope: Decodable {
        let success: Bool
        let data: Forecast?
    }

    @Published private(set) var isFetching = false
    @Published private(set) var lastError: String?

    /// Cache keyed exactly like the worker's, so the two agree on what "the same request" means.
    private var cache: [String: Forecast] = [:]
    private var inFlight: Set<String> = []

    /// Must match the worker's `GRID_DEGREES`. Snapping client-side means panning the route builder
    /// a few hundred metres does not produce a fresh request.
    nonisolated private static let gridDegrees = 0.25

    private var baseURL: String { APIConfig.weatherBaseURL }

    // MARK: - Cache key

    nonisolated static func snap(_ value: Double) -> Double {
        (value / gridDegrees).rounded() * gridDegrees
    }

    nonisolated static func cacheKey(lat: Double, lon: Double, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "\(snap(lat)),\(snap(lon)),\(formatter.string(from: now))"
    }

    // MARK: - Lookup

    /// The forecasts a leg flown at `flownAt` may read, best first, as (cache key, the hour it stands
    /// for): the hour the leg is flown, then the current hour, as before, unless the leg's hour is
    /// already past (the forecast for now describes other weather than the one it was flown in).
    /// Without a time (a route with no date), the current hour. PURE. (6.1)
    ///
    /// The worker serves the current hour only, so the leg's own hour is there when the app fetched
    /// during it: planning on the day, or in flight.
    nonisolated static func forecastCandidates(lat: Double, lon: Double, flownAt: Date?,
                                               now: Date = Date()) -> [(key: String, hour: Date)] {
        let current = (key: cacheKey(lat: lat, lon: lon, now: now), hour: hourStart(now))
        guard let flownAt else { return [current] }
        let flown = (key: cacheKey(lat: lat, lon: lon, now: flownAt), hour: hourStart(flownAt))
        if flown.key == current.key { return [current] }
        return flown.hour < current.hour ? [flown] : [flown, current]
    }

    /// The start of the UTC hour `date` falls in.
    nonisolated static func hourStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }

    /// The forecast's own "valid at" ("2026-09-29T09:00Z", as the worker writes it), when it reads.
    nonisolated static func validDate(_ forecast: Forecast) -> Date? {
        for format in ["yyyy-MM-dd'T'HH:mm'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'"] {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let date = formatter.date(from: forecast.validAt) { return date }
        }
        return nil
    }

    /// Synchronous read used by `FlightPlan.windsAloftProvider`. Returns only what is already
    /// cached — route recalculation happens on every drag and must never block on the network.
    /// A miss schedules a fetch of the current hour and returns nil, so the leg keeps the wind it was
    /// planned with (zero wind if it has none) until the forecast lands and the plan is recalculated.
    ///
    /// `flownAt`: when the leg is flown, for the forecast of that hour (`forecastCandidates`). (6.1)
    func wind(at coordinate: CLLocationCoordinate2D, altitudeFt: Double, flownAt: Date? = nil,
              now: Date = Date()) -> FlightPlan.WindAloft? {
        let candidates = Self.forecastCandidates(lat: coordinate.latitude, lon: coordinate.longitude,
                                                 flownAt: flownAt, now: now)
        guard let (hour, forecast) = candidates.lazy.compactMap({ c in self.cache[c.key].map { (c.hour, $0) } }).first
        else {
            // Only the current hour can be fetched, and a leg flown in an hour already past has no
            // use for it.
            if candidates.contains(where: { $0.hour == Self.hourStart(now) }) {
                Task { await prefetch(coordinate) }
            }
            return nil
        }
        guard let level = Self.nearestLevel(in: forecast, toAltitudeFt: altitudeFt) else { return nil }
        return FlightPlan.WindAloft(directionDegTrue: level.directionDeg, speedKt: level.speedKt,
                                    validAt: Self.validDate(forecast) ?? hour)
    }

    /// Put a forecast in the cache as a fetch during `hour` would. For the tests: the cache is
    /// otherwise only filled from the network.
    func seed(_ forecast: Forecast, at coordinate: CLLocationCoordinate2D, hour: Date) {
        cache[Self.cacheKey(lat: coordinate.latitude, lon: coordinate.longitude, now: hour)] = forecast
    }

    /// The level whose geopotential height is closest to the planned altitude.
    ///
    /// Deliberately NOT interpolated. The levels are ~2,500 ft apart and a forecast wind carries far
    /// more uncertainty than that spacing, so interpolation would add false precision without adding
    /// accuracy. Picking the nearest level keeps the reported wind traceable to something the model
    /// actually produced.
    nonisolated static func nearestLevel(in forecast: Forecast, toAltitudeFt altitudeFt: Double) -> Level? {
        forecast.levels
            .filter { $0.heightFt >= 0 } // -1 marks a level whose height the model omitted
            .min { abs(Double($0.heightFt) - altitudeFt) < abs(Double($1.heightFt) - altitudeFt) }
    }

    /// The model surface wind for a coordinate, shaped for `BriefingWindLadder`.
    ///
    /// Reads the cache only — deliberately does NOT trigger a fetch. The ladder runs while a
    /// briefing view is being built, and a briefing must not fire network requests as a side
    /// effect of rendering. Winds aloft are already prefetched for route planning, so in practice
    /// the entry is usually warm; when it is not, the ladder simply has one fewer rung.
    func surfaceCandidate(near coordinate: CLLocationCoordinate2D?) -> BriefingWindLadder.ModelCandidate? {
        guard let coordinate else { return nil }
        let key = Self.cacheKey(lat: coordinate.latitude, lon: coordinate.longitude)
        guard let surface = cache[key]?.surface else { return nil }
        return .init(
            directionDeg: surface.directionDeg,
            speedKt: surface.speedKt,
            gustKt: surface.gustKt,
            validAt: surface.validAt.flatMap(ISO8601DateFormatter().date(from:))
        )
    }

    // MARK: - Fetch

    /// Warm the cache for a coordinate. Safe to call repeatedly: an already-cached or already
    /// in-flight cell is a no-op, so dragging a route does not spawn a request per frame.
    func prefetch(_ coordinate: CLLocationCoordinate2D) async {
        let key = Self.cacheKey(lat: coordinate.latitude, lon: coordinate.longitude)
        guard cache[key] == nil, !inFlight.contains(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        let lat = Self.snap(coordinate.latitude)
        let lon = Self.snap(coordinate.longitude)
        guard let url = URL(string: "\(baseURL)/v1/winds-aloft?lat=\(lat)&lon=\(lon)") else { return }

        isFetching = true
        defer { isFetching = false }

        do {
            var request = URLRequest(url: url)
            if let secret = APIConfig.weatherClientSecret {
                request.setValue(secret, forHTTPHeaderField: "X-AeroCheck-Client")
            }
            let (data, response) = try await ExternalRequest.data(for: request)
            guard response.statusCode == 200 else {
                lastError = "Winds aloft unavailable (\(response.statusCode))"
                return
            }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.success, let forecast = envelope.data, !forecast.levels.isEmpty else {
                lastError = "Winds aloft unavailable"
                return
            }
            cache[key] = forecast
            lastError = nil
        } catch {
            // A planning aid that cannot be fetched degrades to zero-wind timing, which is what the
            // app did before this existed. Never surfaced as a blocking error.
            lastError = error.localizedDescription
            AppLog.general.debugLine("Winds aloft fetch failed: \(error.localizedDescription)")
        }
    }

    /// Warm every cell a route passes through, so leg timing is wind-corrected end to end.
    func prefetchRoute(_ coordinates: [CLLocationCoordinate2D]) async {
        var seen = Set<String>()
        for coordinate in coordinates {
            let key = Self.cacheKey(lat: coordinate.latitude, lon: coordinate.longitude)
            guard seen.insert(key).inserted else { continue }
            await prefetch(coordinate)
        }
    }
}
