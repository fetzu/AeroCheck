import Foundation
import CoreLocation

/// Analyzes flight plan routes against airspace data to detect conflicts.
///
/// Detection is geometric and fail-safe:
///  - PERF-01: transit is detected by exact segment/polygon intersection (endpoint
///    containment + segment-edge crossing), so a leg that clips a small CTR corner between
///    former sample points can no longer slip through. Proximity uses distance-based
///    sampling capped for performance.
///  - PERF-08: when an airspace's vertical limits are AGL/FL-referenced (or the leg has no
///    planned altitude), the conflict is NOT silently dropped — it is reported with
///    `altitudeUncertain = true` so the pilot verifies the vertical separation.
///  - PERF-19: the worst interaction per airspace across ALL legs is kept (transit beats
///    proximity), instead of first-leg-wins.
enum AirspaceAnalyzer {

    /// Proximity threshold: within 1 NM of a boundary.
    private static let proximityMeters: Double = 1852.0
    /// Distance-based leg sampling for proximity (~0.5 NM), capped per leg for performance.
    private static let sampleSpacingMeters: Double = 926.0
    private static let maxSamplesPerLeg: Int = 600

    static func analyzeRoute(
        waypoints: [(coordinate: CLLocationCoordinate2D, altitude: Double?)],
        airspaces: [Airspace]
    ) -> [AirspaceConflict] {
        guard waypoints.count >= 2 else { return [] }

        // Worst interaction per airspace across all legs (PERF-19).
        var worstByAirspace: [String: AirspaceConflict] = [:]

        for legIndex in 0..<(waypoints.count - 1) {
            let from = waypoints[legIndex]
            let to = waypoints[legIndex + 1]
            let legAltitude = from.altitude ?? to.altitude

            for airspace in airspaces {
                // Skip FIR/UIR (too large, not actionable for VFR pilots)
                if airspace.airspaceType == .fir || airspace.airspaceType == .uir { continue }

                let polygon = airspace.polygonCoordinates
                guard polygon.count >= 3 else { continue }

                // Vertical interaction (datum-aware, fail-safe) — PERF-08.
                let vertical = verticalInteraction(airspace: airspace, altitude: legAltitude)
                guard vertical.interacts else { continue }

                // Horizontal interaction — PERF-01.
                let conflictType: AirspaceConflict.ConflictType
                if legIntersectsPolygon(from: from.coordinate, to: to.coordinate, polygon: polygon) {
                    conflictType = .transit
                } else if legMinDistanceToPolygon(from: from.coordinate, to: to.coordinate, polygon: polygon) < proximityMeters {
                    conflictType = .proximity
                } else {
                    continue
                }

                let candidate = AirspaceConflict(
                    airspace: airspace,
                    legIndex: legIndex,
                    conflictType: conflictType,
                    plannedAltitude: legAltitude,
                    altitudeUncertain: vertical.uncertain
                )

                // Keep the most severe interaction per airspace (transit > proximity) — PERF-19.
                if let existing = worstByAirspace[airspace.id] {
                    if rank(conflictType) > rank(existing.conflictType) {
                        worstByAirspace[airspace.id] = candidate
                    }
                } else {
                    worstByAirspace[airspace.id] = candidate
                }
            }
        }

        // Sort by severity (high first), then by leg index.
        return worstByAirspace.values.sorted { a, b in
            if a.severity != b.severity {
                return severityOrder(a.severity) < severityOrder(b.severity)
            }
            return a.legIndex < b.legIndex
        }
    }

    // MARK: - Vertical (datum-aware, fail-safe) — PERF-08

    private static func verticalInteraction(
        airspace: Airspace,
        altitude: Double?
    ) -> (interacts: Bool, uncertain: Bool) {
        guard let alt = altitude else {
            // No planned altitude — cannot rule the airspace out vertically; flag to verify.
            return (true, true)
        }
        if airspace.altitudeIsUncertain {
            // AGL/FL limits without terrain/QNH — never silently drop; flag to verify.
            return (true, true)
        }
        // MSL-referenced limits: a precise comparison is meaningful.
        return (airspace.containsAltitude(alt), false)
    }

    // MARK: - Horizontal geometry — PERF-01

    /// True if the leg enters the polygon: either endpoint inside, or the segment crosses
    /// any polygon edge (exact — no sampling gaps).
    private static func legIntersectsPolygon(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D,
        polygon: [CLLocationCoordinate2D]
    ) -> Bool {
        if pointInPolygon(a, polygon) || pointInPolygon(b, polygon) { return true }
        for i in 0..<polygon.count {
            let j = (i + 1) % polygon.count
            if segmentsIntersect(a, b, polygon[i], polygon[j]) { return true }
        }
        return false
    }

    /// Ray-casting point-in-polygon test (planar lon/lat).
    private static func pointInPolygon(_ p: CLLocationCoordinate2D, _ polygon: [CLLocationCoordinate2D]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let xi = polygon[i].longitude, yi = polygon[i].latitude
            let xj = polygon[j].longitude, yj = polygon[j].latitude
            if ((yi > p.latitude) != (yj > p.latitude)) &&
                (p.longitude < (xj - xi) * (p.latitude - yi) / (yj - yi) + xi) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Segment-segment intersection using orientation tests (planar lon/lat; fine for the
    /// short legs and CTR-sized polygons involved).
    private static func segmentsIntersect(
        _ p1: CLLocationCoordinate2D, _ p2: CLLocationCoordinate2D,
        _ p3: CLLocationCoordinate2D, _ p4: CLLocationCoordinate2D
    ) -> Bool {
        func orient(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ c: CLLocationCoordinate2D) -> Double {
            (b.longitude - a.longitude) * (c.latitude - a.latitude) -
            (b.latitude - a.latitude) * (c.longitude - a.longitude)
        }
        func onSegment(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ c: CLLocationCoordinate2D) -> Bool {
            min(a.longitude, b.longitude) <= c.longitude && c.longitude <= max(a.longitude, b.longitude) &&
            min(a.latitude, b.latitude) <= c.latitude && c.latitude <= max(a.latitude, b.latitude)
        }
        let d1 = orient(p3, p4, p1)
        let d2 = orient(p3, p4, p2)
        let d3 = orient(p1, p2, p3)
        let d4 = orient(p1, p2, p4)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
           ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
            return true
        }
        if d1 == 0 && onSegment(p3, p4, p1) { return true }
        if d2 == 0 && onSegment(p3, p4, p2) { return true }
        if d3 == 0 && onSegment(p1, p2, p3) { return true }
        if d4 == 0 && onSegment(p1, p2, p4) { return true }
        return false
    }

    /// Minimum distance (m) from the leg to the polygon, via distance-based sampling of the
    /// leg (spacing ~0.5 NM, capped). Used for proximity only.
    private static func legMinDistanceToPolygon(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D,
        polygon: [CLLocationCoordinate2D]
    ) -> Double {
        let aLoc = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let bLoc = CLLocation(latitude: b.latitude, longitude: b.longitude)
        let legLength = aLoc.distance(from: bLoc)
        let steps = max(1, min(maxSamplesPerLeg, Int((legLength / sampleSpacingMeters).rounded(.up))))

        var minDistance = Double.infinity
        for k in 0...steps {
            let f = Double(k) / Double(steps)
            let p = CLLocationCoordinate2D(
                latitude: a.latitude + (b.latitude - a.latitude) * f,
                longitude: a.longitude + (b.longitude - a.longitude) * f
            )
            minDistance = min(minDistance, minimumDistanceToPolygon(point: p, polygon: polygon))
            if minDistance == 0 { break }
        }
        return minDistance
    }

    /// Minimum distance from a point to any edge of a polygon (in meters).
    private static func minimumDistanceToPolygon(point: CLLocationCoordinate2D, polygon: [CLLocationCoordinate2D]) -> Double {
        guard polygon.count >= 2 else { return .infinity }
        let pointLocation = CLLocation(latitude: point.latitude, longitude: point.longitude)
        var minDistance = Double.infinity
        for i in 0..<polygon.count {
            let j = (i + 1) % polygon.count
            let edgeStart = CLLocation(latitude: polygon[i].latitude, longitude: polygon[i].longitude)
            let edgeEnd = CLLocation(latitude: polygon[j].latitude, longitude: polygon[j].longitude)
            minDistance = min(minDistance, distanceToSegment(point: pointLocation, segStart: edgeStart, segEnd: edgeEnd))
        }
        return minDistance
    }

    /// Distance from a point to the nearest point on a line segment.
    private static func distanceToSegment(point: CLLocation, segStart: CLLocation, segEnd: CLLocation) -> Double {
        let dx = segEnd.coordinate.longitude - segStart.coordinate.longitude
        let dy = segEnd.coordinate.latitude - segStart.coordinate.latitude
        if dx == 0 && dy == 0 {
            return point.distance(from: segStart)
        }
        let t = max(0, min(1, (
            (point.coordinate.longitude - segStart.coordinate.longitude) * dx +
            (point.coordinate.latitude - segStart.coordinate.latitude) * dy
        ) / (dx * dx + dy * dy)))
        let projLat = segStart.coordinate.latitude + t * dy
        let projLon = segStart.coordinate.longitude + t * dx
        let projection = CLLocation(latitude: projLat, longitude: projLon)
        return point.distance(from: projection)
    }

    // MARK: - Ordering

    /// Interaction rank for "worst wins" (higher = more severe).
    private static func rank(_ type: AirspaceConflict.ConflictType) -> Int {
        switch type {
        case .transit: return 1
        case .proximity: return 0
        }
    }

    /// Severity ordering (lower = more severe) for display sorting.
    private static func severityOrder(_ severity: AirspaceConflict.ConflictSeverity) -> Int {
        switch severity {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }
}
