import Foundation
import CoreLocation

/// Service for fetching terrain elevation data
/// Uses swisstopo API for locations within Switzerland
actor ElevationService {
    // Swiss boundaries (approximate)
    private let swissBounds = (
        minLat: 45.8,
        maxLat: 47.9,
        minLon: 5.9,
        maxLon: 10.5
    )

    // MARK: - Swiss Coordinate Conversion (WGS84 to LV95)
    // Based on official swisstopo formulas: https://www.swisstopo.admin.ch/en/knowledge-facts/surveying-geodesy/reference-frames/local/lv95.html

    /// Convert WGS84 coordinates to Swiss LV95 (CH1903+)
    /// Returns (easting, northing) in meters
    private func wgs84ToLV95(_ coordinate: CLLocationCoordinate2D) -> (easting: Double, northing: Double) {
        // Convert to sexagesimal seconds
        let latSec = coordinate.latitude * 3600
        let lonSec = coordinate.longitude * 3600

        // Auxiliary values (differences from Bern in 10000")
        let latAux = (latSec - 169028.66) / 10000
        let lonAux = (lonSec - 26782.5) / 10000

        // Calculate easting (E)
        let easting = 2600072.37
            + 211455.93 * lonAux
            - 10938.51 * lonAux * latAux
            - 0.36 * lonAux * pow(latAux, 2)
            - 44.54 * pow(lonAux, 3)

        // Calculate northing (N)
        let northing = 1200147.07
            + 308807.95 * latAux
            + 3745.25 * pow(lonAux, 2)
            + 76.63 * pow(latAux, 2)
            - 194.56 * pow(lonAux, 2) * latAux
            + 119.79 * pow(latAux, 3)

        return (easting, northing)
    }

    /// Check if a coordinate is within Switzerland
    func isInSwitzerland(_ coordinate: CLLocationCoordinate2D) -> Bool {
        return coordinate.latitude >= swissBounds.minLat &&
               coordinate.latitude <= swissBounds.maxLat &&
               coordinate.longitude >= swissBounds.minLon &&
               coordinate.longitude <= swissBounds.maxLon
    }

    /// Fetch elevation for a single point (in meters)
    /// Returns nil if outside Switzerland or on error
    func fetchElevation(at coordinate: CLLocationCoordinate2D) async -> Double? {
        guard isInSwitzerland(coordinate) else { return nil }

        // Convert WGS84 to LV95
        let lv95 = wgs84ToLV95(coordinate)

        let urlString = "https://api3.geo.admin.ch/rest/services/height?easting=\(lv95.easting)&northing=\(lv95.northing)&sr=2056"

        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Height can be returned as Double or String
                if let height = json["height"] as? Double {
                    return height
                } else if let heightStr = json["height"] as? String,
                          let height = Double(heightStr) {
                    return height
                }
            }
        } catch {
            print("[AéroCheck] Elevation fetch error: \(error.localizedDescription)")
        }

        return nil
    }

    /// Fetch elevations along a route using the profile API (more efficient)
    /// Returns array of (distance from start in NM, elevation in meters)
    func fetchRouteElevations(waypoints: [CLLocationCoordinate2D], samplesPerLeg: Int = 10) async -> [(distance: Double, elevation: Double)] {
        guard waypoints.count >= 2 else { return [] }

        var results: [(distance: Double, elevation: Double)] = []
        var cumulativeDistance: Double = 0

        for i in 0..<(waypoints.count - 1) {
            let from = waypoints[i]
            let to = waypoints[i + 1]

            // Calculate leg distance
            let fromLocation = CLLocation(latitude: from.latitude, longitude: from.longitude)
            let toLocation = CLLocation(latitude: to.latitude, longitude: to.longitude)
            let legDistanceMeters = fromLocation.distance(from: toLocation)
            let legDistanceNM = legDistanceMeters / 1852.0

            // Fetch profile for this leg
            if let legProfile = await fetchLegProfile(from: from, to: to) {
                for point in legProfile {
                    // Convert distance from meters to NM and add cumulative
                    let distanceNM = cumulativeDistance + (point.distance / 1852.0)
                    results.append((distance: distanceNM, elevation: point.elevation))
                }
            }

            cumulativeDistance += legDistanceNM
        }

        return results
    }

    /// Fetch elevation profile for a single leg using the profile API
    private func fetchLegProfile(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> [(distance: Double, elevation: Double)]? {
        guard isInSwitzerland(from) && isInSwitzerland(to) else { return nil }

        // Convert to LV95
        let fromLV95 = wgs84ToLV95(from)
        let toLV95 = wgs84ToLV95(to)

        // Build GeoJSON LineString
        let geom = """
        {"type":"LineString","coordinates":[[\(fromLV95.easting),\(fromLV95.northing)],[\(toLV95.easting),\(toLV95.northing)]]}
        """

        guard let encodedGeom = geom.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api3.geo.admin.ch/rest/services/profile.json?geom=\(encodedGeom)&sr=2056&nb_points=20") else {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            if let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return json.compactMap { point -> (distance: Double, elevation: Double)? in
                    guard let dist = point["dist"] as? Double,
                          let alts = point["alts"] as? [String: Any],
                          let elevation = alts["COMB"] as? Double else {
                        return nil
                    }
                    return (distance: dist, elevation: elevation)
                }
            }
        } catch {
            print("[AéroCheck] Profile fetch error: \(error.localizedDescription)")
        }

        return nil
    }

    /// Fetch elevations with caching and batching for better performance
    func fetchRouteElevationsOptimized(waypoints: [CLLocationCoordinate2D], totalSamples: Int = 50) async -> [(distance: Double, elevation: Double)] {
        guard waypoints.count >= 2 else { return [] }

        // Calculate total route distance
        var totalDistance: Double = 0
        var legDistances: [Double] = []

        for i in 0..<(waypoints.count - 1) {
            let from = CLLocation(latitude: waypoints[i].latitude, longitude: waypoints[i].longitude)
            let to = CLLocation(latitude: waypoints[i + 1].latitude, longitude: waypoints[i + 1].longitude)
            let legDistance = from.distance(from: to) / 1852.0 // Convert to NM
            legDistances.append(legDistance)
            totalDistance += legDistance
        }

        guard totalDistance > 0 else { return [] }

        // Use profile API for each leg - more efficient than individual point requests
        var results: [(distance: Double, elevation: Double)] = []
        var cumulativeDistanceNM: Double = 0

        for i in 0..<(waypoints.count - 1) {
            let from = waypoints[i]
            let to = waypoints[i + 1]
            let legDistanceNM = legDistances[i]

            // Determine number of samples for this leg proportional to its length
            let legSamples = max(5, Int(Double(totalSamples) * (legDistanceNM / totalDistance)))

            if let legProfile = await fetchLegProfileWithSamples(from: from, to: to, samples: legSamples) {
                // Calculate the leg's total distance in meters for proper scaling
                let legDistanceMeters = legDistanceNM * 1852.0

                for point in legProfile {
                    // Scale the profile distance to NM and add cumulative offset
                    let fractionAlongLeg = legDistanceMeters > 0 ? point.distance / legDistanceMeters : 0
                    let distanceNM = cumulativeDistanceNM + (legDistanceNM * fractionAlongLeg)
                    results.append((distance: distanceNM, elevation: point.elevation))
                }
            }

            cumulativeDistanceNM += legDistanceNM
        }

        return results
    }

    /// Fetch elevation profile for a single leg with specified number of samples
    private func fetchLegProfileWithSamples(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, samples: Int) async -> [(distance: Double, elevation: Double)]? {
        guard isInSwitzerland(from) && isInSwitzerland(to) else { return nil }

        // Convert to LV95
        let fromLV95 = wgs84ToLV95(from)
        let toLV95 = wgs84ToLV95(to)

        // Build GeoJSON LineString
        let geom = """
        {"type":"LineString","coordinates":[[\(fromLV95.easting),\(fromLV95.northing)],[\(toLV95.easting),\(toLV95.northing)]]}
        """

        guard let encodedGeom = geom.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api3.geo.admin.ch/rest/services/profile.json?geom=\(encodedGeom)&sr=2056&nb_points=\(samples)") else {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            if let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return json.compactMap { point -> (distance: Double, elevation: Double)? in
                    guard let dist = point["dist"] as? Double,
                          let alts = point["alts"] as? [String: Any],
                          let elevation = alts["COMB"] as? Double else {
                        return nil
                    }
                    return (distance: dist, elevation: elevation)
                }
            }
        } catch {
            print("[AéroCheck] Profile fetch error: \(error.localizedDescription)")
        }

        return nil
    }
}

// MARK: - Terrain Profile Data

struct TerrainProfileData {
    let points: [(distance: Double, elevation: Double)]
    let waypoints: [(distance: Double, name: String, altitude: Double?)]
    let maxElevation: Double
    let minElevation: Double
    let totalDistance: Double

    var isAvailable: Bool {
        !points.isEmpty
    }

    /// Convert elevation to feet
    func elevationInFeet(_ meters: Double) -> Double {
        meters * 3.28084
    }
}
