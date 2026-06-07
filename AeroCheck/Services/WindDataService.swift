import Foundation
import CoreLocation
import Combine

/// Wind data from a MeteoSwiss weather station
struct WindData {
    let stationName: String
    let speedKmh: Double // Wind speed in km/h
    let directionDegrees: Double // Wind direction in degrees (0-359)
    let timestamp: Date
    let stationCoordinate: CLLocationCoordinate2D
    let distanceMeters: Double // Distance from aircraft to station
}

/// Service for fetching wind data from MeteoSwiss Open Data API
/// Note: This is an experimental feature that only works in Switzerland
class WindDataService: ObservableObject {
    // MARK: - Published Properties

    @Published var currentWindData: WindData?
    @Published var lastFetchTime: Date?
    @Published var fetchError: String?
    @Published var isWithinSwitzerland: Bool = false

    // MARK: - Private Properties

    private var fetchTimer: Timer?
    private let minimumFetchInterval: TimeInterval = 60 // 1 minute minimum between fetches

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
    /// UX-03: deliberately the mean-wind dataset, NOT the peak-gust feed (boeenspitze) —
    /// using a 10-minute gust peak as steady wind overstated the headwind correction and could
    /// suppress a real stall warning (error in the dangerous direction).
    private let windDataURL = "https://data.geo.admin.ch/ch.meteoschweiz.messwerte-wind-geschwindigkeit-kmh-10min/ch.meteoschweiz.messwerte-wind-geschwindigkeit-kmh-10min_en.json"

    /// Maximum age of a wind reading before it is considered stale and no longer used for
    /// airspeed estimation (the readout falls back to ground speed). (UX-04)
    private let maxWindAgeSeconds: TimeInterval = 20 * 60

    // MARK: - Public Methods

    /// Start fetching wind data at regular intervals
    func startFetching(locationManager: LocationManager) {
        stopFetching()

        // Initial fetch
        Task {
            await fetchWindData(for: locationManager.getCurrentCoordinate())
        }

        // Schedule periodic fetches (every minute)
        fetchTimer = Timer.scheduledTimer(withTimeInterval: minimumFetchInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.fetchWindData(for: locationManager.getCurrentCoordinate())
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

    /// Calculate estimated indicated airspeed from ground speed and wind
    /// Returns nil if wind data is not available or aircraft is outside Switzerland
    func calculateEstimatedAirspeed(groundSpeedKnots: Double, trackDegrees: Double, coordinate: CLLocationCoordinate2D?) -> Double? {
        guard let windData = currentWindData,
              isInSwitzerland(coordinate) else {
            return nil
        }

        // Stale wind must not drive the stall/airspeed readout — fall back to ground speed. (UX-04)
        guard Date().timeIntervalSince(windData.timestamp) <= maxWindAgeSeconds else {
            return nil
        }

        // Convert wind speed from km/h to knots
        let windSpeedKnots = windData.speedKmh * 0.539957

        // Wind direction is where wind comes FROM, we need where it's going TO
        let windToDirection = (windData.directionDegrees + 180).truncatingRemainder(dividingBy: 360)

        // Calculate headwind/tailwind component
        // Positive = headwind, Negative = tailwind
        let trackRadians = trackDegrees * .pi / 180
        let windToRadians = windToDirection * .pi / 180
        let angleDifference = trackRadians - windToRadians

        // Component of the wind blowing ALONG the ground track. angleDifference is
        // (track − windToDirection), so cos() is +1 when the wind blows in the direction of
        // travel (a tailwind) and −1 when it opposes travel (a headwind).
        let alongTrackWindComponent = windSpeedKnots * cos(angleDifference)

        // Ground velocity = air velocity + wind velocity, so TAS = ground speed − tailwind
        // component. A headwind (negative component) therefore correctly INCREASES the
        // estimated airspeed; a tailwind decreases it. (Previously this added the component,
        // which inverted the correction — overstating airspeed in a tailwind, the dangerous
        // direction. Caught by WindDataServiceTests.testHeadwindIncreasesAirspeed.)
        let estimatedAirspeed = groundSpeedKnots - alongTrackWindComponent

        return max(0, estimatedAirspeed)
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

    private func fetchWindData(for coordinate: CLLocationCoordinate2D?) async {
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

            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                throw WindFetchError.invalidResponse
            }

            let windData = try parseWindData(data, nearCoordinate: coordinate)

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

    /// Parse GeoJSON wind data and find nearest station
    private func parseWindData(_ data: Data, nearCoordinate: CLLocationCoordinate2D) throws -> WindData {
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

            // Parse timestamp
            let dateFormatter = ISO8601DateFormatter()
            guard let timestamp = dateFormatter.date(from: timestampStr) else {
                continue
            }

            // Convert Swiss coordinates (EPSG:2056) to WGS84
            let swissCoord = (x: coordinates[0], y: coordinates[1])
            let wgs84Coord = convertSwissToWGS84(x: swissCoord.x, y: swissCoord.y)

            // Calculate distance
            let stationLocation = CLLocation(latitude: wgs84Coord.latitude, longitude: wgs84Coord.longitude)
            let aircraftLocation = CLLocation(latitude: nearCoordinate.latitude, longitude: nearCoordinate.longitude)
            let distance = aircraftLocation.distance(from: stationLocation)

            if distance < nearestDistance {
                nearestDistance = distance
                nearestStation = WindData(
                    stationName: stationName,
                    speedKmh: speedValue,
                    directionDegrees: directionDegrees,
                    timestamp: timestamp,
                    stationCoordinate: wgs84Coord,
                    distanceMeters: distance
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
