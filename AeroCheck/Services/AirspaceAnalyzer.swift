import Foundation
import CoreLocation

/// Analyzes flight plan routes against airspace data to detect conflicts
enum AirspaceAnalyzer {
    /// Analyze a flight plan route against loaded airspaces
    /// - Parameters:
    ///   - waypoints: Flight plan waypoints with coordinates and optional altitudes
    ///   - airspaces: Available airspace data to check against
    /// - Returns: Array of conflicts found along the route
    static func analyzeRoute(
        waypoints: [(coordinate: CLLocationCoordinate2D, altitude: Double?)],
        airspaces: [Airspace]
    ) -> [AirspaceConflict] {
        guard waypoints.count >= 2 else { return [] }

        var conflicts: [AirspaceConflict] = []
        var seenAirspaceIds: Set<String> = []

        // Check each leg of the route
        for legIndex in 0..<(waypoints.count - 1) {
            let from = waypoints[legIndex]
            let to = waypoints[legIndex + 1]

            // Sample points along the leg for intersection testing
            let samplePoints = interpolatePoints(from: from.coordinate, to: to.coordinate, count: 10)
            let legAltitude = from.altitude ?? to.altitude

            for airspace in airspaces {
                // Skip if we already flagged this airspace for a previous leg
                guard !seenAirspaceIds.contains(airspace.id) else { continue }

                // Skip FIR/UIR (too large, not actionable for VFR pilots)
                if airspace.airspaceType == .fir || airspace.airspaceType == .uir { continue }

                // Check if any sample point falls within the airspace polygon
                let polygon = airspace.polygonCoordinates
                guard polygon.count >= 3 else { continue }

                let intersects = samplePoints.contains { point in
                    pointInPolygon(point: point, polygon: polygon)
                }

                if intersects {
                    // Check altitude if available
                    if let alt = legAltitude {
                        guard airspace.containsAltitude(alt) else { continue }
                    }

                    seenAirspaceIds.insert(airspace.id)
                    conflicts.append(AirspaceConflict(
                        airspace: airspace,
                        legIndex: legIndex,
                        conflictType: .transit,
                        plannedAltitude: legAltitude
                    ))
                } else {
                    // Check proximity (within ~1 NM of boundary)
                    let isNearby = samplePoints.contains { point in
                        minimumDistanceToPolygon(point: point, polygon: polygon) < 1852 // 1 NM in meters
                    }

                    if isNearby {
                        if let alt = legAltitude {
                            guard airspace.containsAltitude(alt) else { continue }
                        }

                        seenAirspaceIds.insert(airspace.id)
                        conflicts.append(AirspaceConflict(
                            airspace: airspace,
                            legIndex: legIndex,
                            conflictType: .proximity,
                            plannedAltitude: legAltitude
                        ))
                    }
                }
            }
        }

        // Sort by severity (high first), then by leg index
        return conflicts.sorted { a, b in
            if a.severity != b.severity {
                return severityOrder(a.severity) < severityOrder(b.severity)
            }
            return a.legIndex < b.legIndex
        }
    }

    // MARK: - Geometry Helpers

    /// Interpolate points along a great-circle path between two coordinates
    private static func interpolatePoints(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        count: Int
    ) -> [CLLocationCoordinate2D] {
        var points: [CLLocationCoordinate2D] = [from]
        for i in 1..<count {
            let fraction = Double(i) / Double(count)
            let lat = from.latitude + (to.latitude - from.latitude) * fraction
            let lon = from.longitude + (to.longitude - from.longitude) * fraction
            points.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        points.append(to)
        return points
    }

    /// Point-in-polygon test using ray casting algorithm
    private static func pointInPolygon(point: CLLocationCoordinate2D, polygon: [CLLocationCoordinate2D]) -> Bool {
        var inside = false
        var j = polygon.count - 1

        for i in 0..<polygon.count {
            let xi = polygon[i].longitude, yi = polygon[i].latitude
            let xj = polygon[j].longitude, yj = polygon[j].latitude

            let intersect = ((yi > point.latitude) != (yj > point.latitude)) &&
                (point.longitude < (xj - xi) * (point.latitude - yi) / (yj - yi) + xi)

            if intersect {
                inside = !inside
            }
            j = i
        }

        return inside
    }

    /// Minimum distance from a point to any edge of a polygon (in meters)
    private static func minimumDistanceToPolygon(point: CLLocationCoordinate2D, polygon: [CLLocationCoordinate2D]) -> Double {
        guard polygon.count >= 2 else { return .infinity }

        let pointLocation = CLLocation(latitude: point.latitude, longitude: point.longitude)
        var minDistance = Double.infinity

        for i in 0..<polygon.count {
            let j = (i + 1) % polygon.count
            let edgeStart = CLLocation(latitude: polygon[i].latitude, longitude: polygon[i].longitude)
            let edgeEnd = CLLocation(latitude: polygon[j].latitude, longitude: polygon[j].longitude)

            // Distance to nearest point on edge segment
            let d = distanceToSegment(point: pointLocation, segStart: edgeStart, segEnd: edgeEnd)
            minDistance = min(minDistance, d)
        }

        return minDistance
    }

    /// Distance from a point to the nearest point on a line segment
    private static func distanceToSegment(point: CLLocation, segStart: CLLocation, segEnd: CLLocation) -> Double {
        let dx = segEnd.coordinate.longitude - segStart.coordinate.longitude
        let dy = segEnd.coordinate.latitude - segStart.coordinate.latitude

        if dx == 0 && dy == 0 {
            return point.distance(from: segStart)
        }

        // Project point onto segment
        let t = max(0, min(1, (
            (point.coordinate.longitude - segStart.coordinate.longitude) * dx +
            (point.coordinate.latitude - segStart.coordinate.latitude) * dy
        ) / (dx * dx + dy * dy)))

        let projLat = segStart.coordinate.latitude + t * dy
        let projLon = segStart.coordinate.longitude + t * dx
        let projection = CLLocation(latitude: projLat, longitude: projLon)

        return point.distance(from: projection)
    }

    /// Severity ordering (lower = more severe)
    private static func severityOrder(_ severity: AirspaceConflict.ConflictSeverity) -> Int {
        switch severity {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }
}
