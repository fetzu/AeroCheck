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
            let (data, httpResponse) = try await ExternalRequest.data(from: url)

            guard httpResponse.statusCode == 200 else {
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
            AppLog.general.debugLine("Elevation fetch error: \(error.localizedDescription)")
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

            // The caller (the flight-plan route profile) only invokes this when every waypoint is in
            // Switzerland, so a nil leg here is always a fetch failure — not legitimately-absent
            // data. Fail the whole profile rather than drawing a continuous fill across the gap that
            // would hide an unfetched (possibly mountainous) segment. (PERF-16)
            guard let legProfile = await fetchLegProfileWithSamples(from: from, to: to, samples: legSamples) else {
                return []
            }

            // Calculate the leg's total distance in meters for proper scaling
            let legDistanceMeters = legDistanceNM * 1852.0

            for point in legProfile {
                // Scale the profile distance to NM and add cumulative offset
                let fractionAlongLeg = legDistanceMeters > 0 ? point.distance / legDistanceMeters : 0
                let distanceNM = cumulativeDistanceNM + (legDistanceNM * fractionAlongLeg)
                results.append((distance: distanceNM, elevation: point.elevation))
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
            let (data, httpResponse) = try await ExternalRequest.data(from: url)

            guard httpResponse.statusCode == 200 else {
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
            AppLog.general.debugLine("Profile fetch error: \(error.localizedDescription)")
        }

        return nil
    }

    // MARK: - GPS Track Terrain Profile (for Share Card)

    /// Fetch ground elevation along a recorded GPS track for terrain visualization.
    /// Returns an array of (timestamp, ground elevation in meters) aligned to the GPS track timestamps.
    /// Uses swisstopo for Swiss flights and Open-Meteo for flights elsewhere.
    func fetchTrackTerrainProfile(
        gpsTrack: [(coordinate: CLLocationCoordinate2D, timestamp: Date)],
        targetSamples: Int = 80
    ) async -> [(time: Date, elevationMeters: Double)] {
        guard gpsTrack.count >= 2 else { return [] }

        // Determine if flight is in Switzerland by checking first and last points
        let firstCoord = gpsTrack.first!.coordinate
        let lastCoord = gpsTrack.last!.coordinate
        let flightIsSwiss = isInSwitzerland(firstCoord) && isInSwitzerland(lastCoord)

        if flightIsSwiss {
            return await fetchTrackTerrainViaSwisstopo(gpsTrack: gpsTrack, targetSamples: targetSamples)
        } else {
            return await fetchTrackTerrainViaOpenMeteo(gpsTrack: gpsTrack, targetSamples: targetSamples)
        }
    }

    // MARK: - Swisstopo Track Terrain (POST with multi-coordinate LineString)

    /// Fetch terrain profile along a GPS track using swisstopo profile API via POST.
    /// Sends a simplified version of the track as a multi-coordinate LineString.
    private func fetchTrackTerrainViaSwisstopo(
        gpsTrack: [(coordinate: CLLocationCoordinate2D, timestamp: Date)],
        targetSamples: Int
    ) async -> [(time: Date, elevationMeters: Double)] {
        // Simplify the track: sample evenly to keep the LineString manageable
        // Max ~200 coordinates in the geometry to stay well within the 5000 limit
        let maxGeomPoints = min(200, gpsTrack.count)
        let sampledTrack = strideSample(gpsTrack, count: maxGeomPoints)

        // Convert sampled coordinates to LV95 for the LineString
        let lv95Coords = sampledTrack.map { wgs84ToLV95($0.coordinate) }

        // SEC-C39: round to whole metres. LV95 is metre-based, so the fractional part is
        // sub-metre detail of the pilot's actual route being sent to a third party for no benefit —
        // the terrain profile is sampled at a far coarser resolution than that.
        let coordStrings = lv95Coords.map { "[\(Int($0.easting.rounded())),\(Int($0.northing.rounded()))]" }
        let geom = "{\"type\":\"LineString\",\"coordinates\":[\(coordStrings.joined(separator: ","))]}"

        // Use POST to avoid URL length limits
        guard let url = URL(string: "https://api3.geo.admin.ch/rest/services/profile.json") else { return [] }

        // Request nb_points aligned with our target samples
        let nbPoints = min(targetSamples, 500)
        let body = "geom=\(geom)&sr=2056&nb_points=\(nbPoints)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        do {
            let (data, httpResponse) = try await ExternalRequest.data(for: request)

            guard (200...203).contains(httpResponse.statusCode) else {
                AppLog.general.debugLine("Swisstopo profile POST failed: \(String(describing: (try? JSONSerialization.jsonObject(with: data))))")
                return []
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

            // Parse distance-based elevation points
            let profilePoints: [(dist: Double, elevation: Double)] = json.compactMap { point in
                guard let dist = point["dist"] as? Double,
                      let alts = point["alts"] as? [String: Any],
                      let elevation = alts["COMB"] as? Double else { return nil }
                return (dist: dist, elevation: elevation)
            }

            guard !profilePoints.isEmpty else { return [] }

            // Map distance-based results back to timestamps
            return mapProfileToTimestamps(profilePoints: profilePoints, gpsTrack: gpsTrack)
        } catch {
            AppLog.general.debugLine("Swisstopo track terrain error: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Open-Meteo Track Terrain (batch coordinate queries)

    /// Fetch terrain profile along a GPS track using the Open-Meteo Elevation API.
    /// Batches coordinates into requests of up to 100 points each.
    /// Parses an Open-Meteo `/v1/elevation` response into the elevation array, returning nil (never
    /// a zero-filled placeholder) on malformed JSON, a missing `elevation` field, or a count
    /// mismatch — so a failed/partial response can never masquerade as flat sea-level terrain.
    /// (PERF-15 / SEC-14)
    nonisolated static func parseOpenMeteoElevations(_ data: Data, expectedCount: Int) -> [Double]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elevations = json["elevation"] as? [Double],
              elevations.count == expectedCount else {
            return nil
        }
        return elevations
    }

    private func fetchTrackTerrainViaOpenMeteo(
        gpsTrack: [(coordinate: CLLocationCoordinate2D, timestamp: Date)],
        targetSamples: Int
    ) async -> [(time: Date, elevationMeters: Double)] {
        // Sample the track to the target number of points
        let sampled = strideSample(gpsTrack, count: targetSamples)

        // Open-Meteo accepts up to 100 coordinates per request
        let batchSize = 100
        let batches = stride(from: 0, to: sampled.count, by: batchSize).map {
            Array(sampled[$0..<min($0 + batchSize, sampled.count)])
        }

        var allElevations: [Double] = []

        // SAFETY (PERF-15 / SEC-14): never coerce a missing/failed elevation reading to 0 m — a flat
        // sea-level band drawn under the altitude trace falsely implies huge ground clearance. On any
        // failure (URL, non-200, parse, count mismatch, network) return [] so the caller honestly
        // shows "no terrain" instead of a fabricated flat band.
        for batch in batches {
            // SEC-C39: ~1 m precision (%.5f) is far more than a terrain-profile graph needs, and
            // this is the RECORDED FLIGHT TRACK — departure and arrival are inferable from its
            // endpoints — going to a third party. %.3f is ~100 m, which changes no pixel of the
            // rendered profile while materially coarsening what leaves the device.
            let lats = batch.map { String(format: "%.3f", $0.coordinate.latitude) }.joined(separator: ",")
            let lons = batch.map { String(format: "%.3f", $0.coordinate.longitude) }.joined(separator: ",")

            guard let url = URL(string: "https://api.open-meteo.com/v1/elevation?latitude=\(lats)&longitude=\(lons)") else {
                return []
            }

            do {
                let (data, httpResponse) = try await ExternalRequest.data(from: url)
                guard httpResponse.statusCode == 200,
                      let elevations = Self.parseOpenMeteoElevations(data, expectedCount: batch.count) else {
                    return []
                }
                allElevations.append(contentsOf: elevations)
            } catch {
                AppLog.general.debugLine("Open-Meteo elevation error: \(error.localizedDescription)")
                return []
            }
        }

        // Pair elevations with timestamps from sampled points
        guard allElevations.count == sampled.count else { return [] }

        return zip(sampled, allElevations).map { (point, elevation) in
            (time: point.timestamp, elevationMeters: elevation)
        }
    }

    // MARK: - Helpers

    /// Evenly sample N points from an array, always including first and last
    private func strideSample<T>(_ array: [T], count: Int) -> [T] {
        guard array.count > count, count >= 2 else { return array }
        var result: [T] = [array.first!]
        let step = Double(array.count - 1) / Double(count - 1)
        for i in 1..<(count - 1) {
            let index = Int(round(Double(i) * step))
            result.append(array[index])
        }
        result.append(array.last!)
        return result
    }

    /// Map distance-based profile points back to GPS track timestamps.
    /// Walks the track cumulatively to match each profile distance to the nearest timestamp.
    private func mapProfileToTimestamps(
        profilePoints: [(dist: Double, elevation: Double)],
        gpsTrack: [(coordinate: CLLocationCoordinate2D, timestamp: Date)]
    ) -> [(time: Date, elevationMeters: Double)] {
        guard gpsTrack.count >= 2 else { return [] }

        // Build cumulative distance array along the GPS track (in meters)
        var cumulativeDistances: [Double] = [0]
        for i in 1..<gpsTrack.count {
            let prev = CLLocation(latitude: gpsTrack[i - 1].coordinate.latitude, longitude: gpsTrack[i - 1].coordinate.longitude)
            let curr = CLLocation(latitude: gpsTrack[i].coordinate.latitude, longitude: gpsTrack[i].coordinate.longitude)
            cumulativeDistances.append(cumulativeDistances.last! + prev.distance(from: curr))
        }

        let totalTrackDistance = cumulativeDistances.last!
        let totalProfileDistance = profilePoints.last?.dist ?? 1

        guard totalTrackDistance > 0, totalProfileDistance > 0 else { return [] }

        var results: [(time: Date, elevationMeters: Double)] = []
        var trackIndex = 0

        for point in profilePoints {
            // Scale profile distance to track distance (they may differ slightly)
            let scaledDist = (point.dist / totalProfileDistance) * totalTrackDistance

            // Advance the track index to find the closest position
            while trackIndex < cumulativeDistances.count - 1 &&
                  cumulativeDistances[trackIndex + 1] < scaledDist {
                trackIndex += 1
            }

            // Interpolate timestamp between trackIndex and trackIndex+1
            if trackIndex < gpsTrack.count - 1 {
                let d0 = cumulativeDistances[trackIndex]
                let d1 = cumulativeDistances[trackIndex + 1]
                let segmentLength = d1 - d0
                let fraction = segmentLength > 0 ? (scaledDist - d0) / segmentLength : 0

                let t0 = gpsTrack[trackIndex].timestamp.timeIntervalSince1970
                let t1 = gpsTrack[trackIndex + 1].timestamp.timeIntervalSince1970
                let interpolatedTime = t0 + fraction * (t1 - t0)

                results.append((time: Date(timeIntervalSince1970: interpolatedTime), elevationMeters: point.elevation))
            } else {
                results.append((time: gpsTrack.last!.timestamp, elevationMeters: point.elevation))
            }
        }

        return results
    }
}

