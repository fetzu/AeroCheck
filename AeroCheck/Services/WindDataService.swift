import Foundation
import CoreLocation
import Combine

/// Wind data from a MeteoSwiss weather station.
///
/// This is a SURFACE observation (10 m above ground at the station's own elevation), which makes it
/// the right instrument for briefing a departure or an approach — both of which happen at the
/// surface, near an airfield. It is NOT a wind aloft: over land the surface wind runs roughly half
/// the 2000 ft wind and backed ~30°, so it must not be used to reason about conditions at altitude.
struct WindData {
    let stationName: String
    let speedKmh: Double // Wind speed in km/h
    let directionDegrees: Double // Wind direction in degrees (0-359)
    let timestamp: Date
    let stationCoordinate: CLLocationCoordinate2D
    let distanceMeters: Double // Distance from aircraft to station
    let stationAltitudeMeters: Double // Station elevation AMSL — provenance, and how it was selected

    var speedKnots: Double { speedKmh * 0.539957 }
}

/// Service for fetching wind data from MeteoSwiss Open Data API
/// Note: This is an experimental feature that only works in Switzerland
///
/// `@MainActor` because every other `ObservableObject` service in the app is, and this was the one
/// exception — its `@Published` properties were mutated from async fetch code with only hand-written
/// `MainActor.run` hops to keep that correct. The project builds in Swift 5 language mode with no
/// `SWIFT_STRICT_CONCURRENCY` flag, so nothing was checking that by hand-audit alone. Annotating the
/// class makes the existing hops redundant-but-harmless and gains the compiler enforcement the rest
/// of the codebase already has. (CQ-07)
@MainActor
class WindDataService: ObservableObject {
    // MARK: - Published Properties

    @Published var currentWindData: WindData?
    @Published var lastFetchTime: Date?
    @Published var fetchError: String?
    @Published var isWithinSwitzerland: Bool = false

    // MARK: - Private Properties

    private var fetchTimer: Timer?

    /// Matched to the data's own cadence: the feed is a 10-MINUTE MEAN, republished every 10
    /// minutes, so anything faster re-downloads a byte-identical 191 KB payload. The old 60 s
    /// interval existed for the live airspeed readout, which no longer exists — at 1 flight/1.5 h
    /// it pulled ~17 MB per user per flight from a free public endpoint for ~1.7 MB of new data.
    private let minimumFetchInterval: TimeInterval = 10 * 60

    /// Switzerland bounding box with ~5 NM margin (approximately 9.26 km)
    /// Original: 45.82° - 47.81° N, 5.96° - 10.49° E
    /// With margin: 45.74° - 47.89° N, 5.84° - 10.61° E
    private let switzerlandBounds = (
        minLat: 45.74,
        maxLat: 47.89,
        minLon: 5.84,
        maxLon: 10.61
    )

    /// MeteoSwiss MEAN-wind endpoint (GeoJSON: 10-minute mean wind speed + direction).
    /// UX-03: deliberately the mean-wind dataset, NOT the peak-gust feed (boeenspitze) — a
    /// 10-minute gust peak is not the steady wind a pilot briefs a runway against.
    ///
    /// The dataset id was `messwerte-wind-geschwindigkeit-kmh-10min` until MeteoSwiss renamed it to
    /// `messwerte-windgeschwindigkeit-kmh-10min` (one word). The old id now returns 404 NoSuchKey,
    /// which this service handled by silently reporting "no wind available" — so the wind went
    /// missing from the briefings with no error surfaced anywhere. If wind stops appearing again,
    /// check this URL FIRST.
    private let windDataURL = "https://data.geo.admin.ch/ch.meteoschweiz.messwerte-windgeschwindigkeit-kmh-10min/ch.meteoschweiz.messwerte-windgeschwindigkeit-kmh-10min_en.json"

    /// Maximum age of a wind reading before it is considered stale and no longer shown. (UX-04)
    private let maxWindAgeSeconds: TimeInterval = 20 * 60

    /// Reject stations further away than this. The network is dense enough in the lowlands that a
    /// nearest station beyond this radius means there is no representative observation — better to
    /// say "not available" than to brief a runway against a wind measured 60 km away.
    private let maxStationDistanceMeters: Double = 30_000

    /// Reject stations whose own altitude differs from the aircraft's by more than this. SwissMetNet
    /// spans 213 m (Magadino) to 3581 m (Jungfraujoch), and 23% of stations sit above 1500 m, so a
    /// pure nearest-by-distance search in the Alps can select a ridge-top station whose wind has
    /// nothing to do with conditions in the valley below it.
    private let maxStationAltitudeDeltaMeters: Double = 500

    // MARK: - Public Methods

    /// Start fetching wind data at regular intervals
    func startFetching(locationManager: LocationManager) {
        stopFetching()

        // Initial fetch
        Task {
            await fetchWindData(for: locationManager.getCurrentCoordinate(),
                                aircraftAltitudeMeters: locationManager.currentAltitudeMeters)
        }

        // Schedule periodic fetches (every minute)
        fetchTimer = Timer.scheduledTimer(withTimeInterval: minimumFetchInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.fetchWindData(for: locationManager.getCurrentCoordinate(),
                                          aircraftAltitudeMeters: locationManager.currentAltitudeMeters)
            }
        }
    }

    /// Stop fetching wind data
    func stopFetching() {
        fetchTimer?.invalidate()
        fetchTimer = nil
        currentWindData = nil
        lastFetchTime = nil
    }

    /// Check if a coordinate is within Switzerland (with margin)
    func isInSwitzerland(_ coordinate: CLLocationCoordinate2D?) -> Bool {
        guard let coordinate = coordinate else { return false }
        return coordinate.latitude >= switzerlandBounds.minLat &&
               coordinate.latitude <= switzerlandBounds.maxLat &&
               coordinate.longitude >= switzerlandBounds.minLon &&
               coordinate.longitude <= switzerlandBounds.maxLon
    }

    /// Whether the current reading is fresh enough to show. (UX-04)
    var hasFreshWind: Bool {
        guard let w = currentWindData else { return false }
        return Date().timeIntervalSince(w.timestamp) <= maxWindAgeSeconds
    }

    /// Age of the current wind reading in seconds, if any (for provenance display).
    var windDataAgeSeconds: TimeInterval? {
        guard let w = currentWindData else { return nil }
        return Date().timeIntervalSince(w.timestamp)
    }

    /// True if we hold a wind reading that has aged past the usable window.
    var isWindDataStale: Bool {
        guard let age = windDataAgeSeconds else { return false }
        return age > maxWindAgeSeconds
    }

    // MARK: - Private Methods

    private func fetchWindData(for coordinate: CLLocationCoordinate2D?,
                               aircraftAltitudeMeters: Double?) async {
        // Check if within Switzerland
        let inSwitzerland = isInSwitzerland(coordinate)
        await MainActor.run {
            self.isWithinSwitzerland = inSwitzerland
        }

        guard inSwitzerland, let coordinate = coordinate else {
            await MainActor.run {
                self.currentWindData = nil
                self.fetchError = coordinate == nil ? "No GPS position" : "Outside Switzerland"
            }
            return
        }

        do {
            guard let url = URL(string: windDataURL) else {
                throw WindFetchError.invalidURL
            }

            // Routed through ExternalRequest for a descriptive User-Agent, a short timeout, and
            // retry/backoff on transient 429/5xx (MeteoSwiss). (SEC-15 / PERF-23)
            let (data, httpResponse) = try await ExternalRequest.data(from: url)

            guard httpResponse.statusCode == 200 else {
                throw WindFetchError.invalidResponse
            }

            let windData = try parseWindData(data, nearCoordinate: coordinate,
                                             aircraftAltitudeMeters: aircraftAltitudeMeters)

            await MainActor.run {
                self.currentWindData = windData
                self.lastFetchTime = Date()
                self.fetchError = nil
            }

        } catch {
            await MainActor.run {
                // Age out the last reading on a failed fetch so stale wind is never shown as live. (UX-04)
                self.currentWindData = nil
                self.fetchError = error.localizedDescription
            }
        }
    }

    /// Parse the GeoJSON and pick the most REPRESENTATIVE station, which is not simply the nearest.
    ///
    /// SwissMetNet spans 213 m (Magadino) to 3581 m (Jungfraujoch) and 23% of its 155 stations sit
    /// above 1500 m. A pure nearest-by-distance search in the Alps therefore happily returns a
    /// ridge-top station whose wind describes the ridge, not the valley airfield below it — so
    /// candidates are filtered on both horizontal distance and altitude difference before the
    /// nearest is taken. If nothing qualifies we report no wind rather than a misleading one.
    private func parseWindData(_ data: Data,
                               nearCoordinate: CLLocationCoordinate2D,
                               aircraftAltitudeMeters: Double?) throws -> WindData {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else {
            throw WindFetchError.parseError
        }

        var nearestStation: WindData?
        var nearestDistance: Double = .infinity

        for feature in features {
            guard let properties = feature["properties"] as? [String: Any],
                  let geometry = feature["geometry"] as? [String: Any],
                  let coordinates = geometry["coordinates"] as? [Double],
                  coordinates.count >= 2 else {
                continue
            }

            // Get wind data
            guard let speedValue = properties["value"] as? Double,
                  let directionDegrees = properties["wind_direction"] as? Double,
                  let stationName = properties["station_name"] as? String,
                  let timestampStr = properties["reference_ts"] as? String else {
                continue
            }

            // Reject implausible / non-finite readings. JSONSerialization decodes an overflow
            // exponent (e.g. 1e400) to ±inf, which would pass the `as? Double` cast above, flow into
            // calculateEstimatedAirspeed, and trap at Int(displaySpeed) on the live speed indicator.
            guard speedValue.isFinite, directionDegrees.isFinite,
                  speedValue >= 0, speedValue <= 250,
                  directionDegrees >= 0, directionDegrees <= 360 else {
                continue
            }

            // Parse timestamp
            let dateFormatter = ISO8601DateFormatter()
            guard let timestamp = dateFormatter.date(from: timestampStr) else {
                continue
            }

            // Convert Swiss coordinates (EPSG:2056) to WGS84
            let swissCoord = (x: coordinates[0], y: coordinates[1])
            let wgs84Coord = convertSwissToWGS84(x: swissCoord.x, y: swissCoord.y)

            // Station elevation AMSL. Serialized as a STRING in the feed ("1888.00"), not a number.
            let stationAltitude = (properties["altitude"] as? String).flatMap(Double.init)
                ?? (properties["altitude"] as? Double)

            // Calculate distance
            let stationLocation = CLLocation(latitude: wgs84Coord.latitude, longitude: wgs84Coord.longitude)
            let aircraftLocation = CLLocation(latitude: nearCoordinate.latitude, longitude: nearCoordinate.longitude)
            let distance = aircraftLocation.distance(from: stationLocation)

            // Too far to describe the air where the aircraft is.
            guard distance <= maxStationDistanceMeters else { continue }

            // Too far above or below us to be representative. Skipped when either altitude is
            // unknown — an unfiltered station is still better than no wind at all, and the
            // distance bound above already excludes the worst cases.
            if let stationAltitude, let aircraftAltitudeMeters,
               abs(stationAltitude - aircraftAltitudeMeters) > maxStationAltitudeDeltaMeters {
                continue
            }

            if distance < nearestDistance {
                nearestDistance = distance
                nearestStation = WindData(
                    stationName: stationName,
                    speedKmh: speedValue,
                    directionDegrees: directionDegrees,
                    timestamp: timestamp,
                    stationCoordinate: wgs84Coord,
                    distanceMeters: distance,
                    stationAltitudeMeters: stationAltitude ?? .nan
                )
            }
        }

        guard let result = nearestStation else {
            throw WindFetchError.noStationsFound
        }

        return result
    }

    /// Convert Swiss LV95 coordinates (EPSG:2056) to WGS84
    /// Based on approximate transformation formulas
    private func convertSwissToWGS84(x: Double, y: Double) -> CLLocationCoordinate2D {
        // LV95 to LV03 (subtract false origin)
        let y_aux = (x - 2_600_000) / 1_000_000
        let x_aux = (y - 1_200_000) / 1_000_000

        // Calculate longitude
        let lambda = 2.6779094
            + 4.728982 * y_aux
            + 0.791484 * y_aux * x_aux
            + 0.1306 * y_aux * x_aux * x_aux
            - 0.0436 * y_aux * y_aux * y_aux

        // Calculate latitude
        let phi = 16.9023892
            + 3.238272 * x_aux
            - 0.270978 * y_aux * y_aux
            - 0.002528 * x_aux * x_aux
            - 0.0447 * y_aux * y_aux * x_aux
            - 0.0140 * x_aux * x_aux * x_aux

        // Convert to decimal degrees
        let longitude = lambda * 100 / 36
        let latitude = phi * 100 / 36

        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Errors

enum WindFetchError: LocalizedError {
    case invalidURL
    case invalidResponse
    case parseError
    case noStationsFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid MeteoSwiss API URL"
        case .invalidResponse:
            return "Invalid response from MeteoSwiss"
        case .parseError:
            return "Failed to parse wind data"
        case .noStationsFound:
            return "No weather stations found"
        }
    }
}
