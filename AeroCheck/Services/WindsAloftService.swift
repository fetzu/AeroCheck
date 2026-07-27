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

    /// Synchronous read used by `FlightPlan.windsAloftProvider`. Returns only what is already
    /// cached — route recalculation happens on every drag and must never block on the network.
    /// A miss schedules a fetch and returns nil, so the leg falls back to zero-wind until the
    /// forecast lands and the plan is recalculated.
    func wind(at coordinate: CLLocationCoordinate2D, altitudeFt: Double) -> FlightPlan.WindAloft? {
        let key = Self.cacheKey(lat: coordinate.latitude, lon: coordinate.longitude)
        guard let forecast = cache[key] else {
            Task { await prefetch(coordinate) }
            return nil
        }
        guard let level = Self.nearestLevel(in: forecast, toAltitudeFt: altitudeFt) else { return nil }
        return FlightPlan.WindAloft(directionDegTrue: level.directionDeg, speedKt: level.speedKt)
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

    /// Drop cached forecasts that belong to an earlier hour bucket.
    func pruneStale(now: Date = Date()) {
        let suffix = String(Self.cacheKey(lat: 0, lon: 0, now: now).split(separator: ",").last ?? "")
        cache = cache.filter { $0.key.hasSuffix(suffix) }
    }
}
