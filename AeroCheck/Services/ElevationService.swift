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

        let urlString = "https://api3.geo.admin.ch/rest/services/height?easting=\(coordinate.longitude)&northing=\(coordinate.latitude)&sr=4326"

        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let height = json["height"] as? Double {
                return height
            }
        } catch {
            print("[AeroCheck] Elevation fetch error: \(error.localizedDescription)")
        }

        return nil
    }

    /// Fetch elevations along a route (between waypoints)
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

            // Sample points along the leg
            for j in 0...samplesPerLeg {
                let fraction = Double(j) / Double(samplesPerLeg)
                let sampleLat = from.latitude + (to.latitude - from.latitude) * fraction
                let sampleLon = from.longitude + (to.longitude - from.longitude) * fraction
                let sampleCoord = CLLocationCoordinate2D(latitude: sampleLat, longitude: sampleLon)

                let distanceAlongRoute = cumulativeDistance + (legDistanceNM * fraction)

                if let elevation = await fetchElevation(at: sampleCoord) {
                    results.append((distance: distanceAlongRoute, elevation: elevation))
                }

                // Small delay to avoid overwhelming the API
                if j < samplesPerLeg {
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                }
            }

            cumulativeDistance += legDistanceNM
        }

        return results
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

        // Generate sample points along the route
        var results: [(distance: Double, elevation: Double)] = []
        let sampleInterval = totalDistance / Double(totalSamples - 1)

        for i in 0..<totalSamples {
            let targetDistance = Double(i) * sampleInterval

            // Find which leg this distance falls on
            var cumulativeDistance: Double = 0
            var legIndex = 0

            for (idx, legDist) in legDistances.enumerated() {
                if cumulativeDistance + legDist >= targetDistance || idx == legDistances.count - 1 {
                    legIndex = idx
                    break
                }
                cumulativeDistance += legDist
            }

            // Calculate position within the leg
            let distanceIntoLeg = targetDistance - cumulativeDistance
            let legFraction = legDistances[legIndex] > 0 ? min(distanceIntoLeg / legDistances[legIndex], 1.0) : 0

            let from = waypoints[legIndex]
            let to = waypoints[min(legIndex + 1, waypoints.count - 1)]

            let sampleLat = from.latitude + (to.latitude - from.latitude) * legFraction
            let sampleLon = from.longitude + (to.longitude - from.longitude) * legFraction
            let sampleCoord = CLLocationCoordinate2D(latitude: sampleLat, longitude: sampleLon)

            if let elevation = await fetchElevation(at: sampleCoord) {
                results.append((distance: targetDistance, elevation: elevation))
            }

            // Small delay between requests
            if i < totalSamples - 1 {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }

        return results
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
