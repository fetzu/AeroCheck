import Foundation
import CoreLocation

/// How close a hazard actually is, recomputed on-device.
///
/// The proxy's `distanceNm` is measured to the nearest polygon VERTEX and frozen at fetch time.
/// Both are wrong in ways a pilot would notice: a long thin area's nearest edge can be far closer
/// than its nearest corner, and a hazard reading "42 nm" keeps reading 42 nm all the way in — at
/// 120 kt that is 10 nm of drift across one 5-minute refresh window.
///
/// With the polygon in hand the app can do better on both counts, so it does. Pure geometry, so it
/// is tested rather than trusted.
enum SigmetRelevance {

    /// Distance from a point to a polygon: 0 inside, otherwise the nearest EDGE (not vertex).
    static func distanceNm(
        from point: CLLocationCoordinate2D,
        toPolygon ring: [CLLocationCoordinate2D]
    ) -> Double? {
        guard ring.count >= 3 else { return nil }
        if contains(point, ring) { return 0 }

        var nearest = Double.greatestFiniteMagnitude
        for index in ring.indices {
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            nearest = min(nearest, distanceNm(from: point, toSegment: a, b))
        }
        return nearest
    }

    /// Nearest distance from a point to the great-circle-ish segment `a`–`b`.
    ///
    /// Worked in a local equirectangular projection around the point rather than in raw degrees:
    /// a degree of longitude is not a degree of latitude anywhere but the equator, and at 47°N the
    /// error from ignoring that is ~32%. Fine over a segment of a few hundred miles, which is what
    /// SIGMET polygons are.
    static func distanceNm(
        from point: CLLocationCoordinate2D,
        toSegment a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D
    ) -> Double {
        let scale = cos(point.latitude * .pi / 180)
        // x in "latitude-equivalent" degrees so both axes share one scale.
        func project(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            (x: c.longitude * scale, y: c.latitude)
        }
        let p = project(point), pa = project(a), pb = project(b)

        let dx = pb.x - pa.x, dy = pb.y - pa.y
        let lengthSquared = dx * dx + dy * dy

        // Degenerate segment (repeated vertex) — fall back to the endpoint.
        guard lengthSquared > 0 else {
            return haversineNm(point, a)
        }

        // Projection parameter, clamped to the segment so the nearest point is never off the end.
        let t = max(0, min(1, ((p.x - pa.x) * dx + (p.y - pa.y) * dy) / lengthSquared))
        let closest = CLLocationCoordinate2D(
            latitude: pa.y + t * dy,
            longitude: (pa.x + t * dx) / (scale == 0 ? 1 : scale)
        )
        return haversineNm(point, closest)
    }

    /// Ray-casting containment. Polygons are FIR-scale, so planar is adequate.
    static func contains(_ point: CLLocationCoordinate2D, _ ring: [CLLocationCoordinate2D]) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let yi = ring[i].latitude, xi = ring[i].longitude
            let yj = ring[j].latitude, xj = ring[j].longitude
            if (yi > point.latitude) != (yj > point.latitude),
               point.longitude < (xj - xi) * (point.latitude - yi) / (yj - yi) + xi {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    static func haversineNm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let earthRadiusNm = 3440.065
        let toRad = { (d: Double) in d * .pi / 180 }
        let dLat = toRad(b.latitude - a.latitude)
        let dLon = toRad(b.longitude - a.longitude)
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(toRad(a.latitude)) * cos(toRad(b.latitude)) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusNm * asin(min(1, sqrt(h)))
    }

    /// A hazard's live relevance to the aircraft AND to the planned route.
    struct Assessment: Equatable {
        /// Distance from the aircraft's CURRENT position, recomputed. 0 when inside.
        let distanceNm: Double
        let containsAircraft: Bool
        /// True when any planned leg passes through the area — the case a position-only query
        /// misses entirely until you are nearly in it.
        let intersectsRoute: Bool
        /// Distance from the nearest point of the route, when a route was supplied.
        let routeDistanceNm: Double?

        /// Ordering: what you are inside first, then what your route crosses, then by distance.
        /// A hazard over the destination outranks a closer one you will never reach.
        var severityRank: Int {
            if containsAircraft { return 0 }
            if intersectsRoute { return 1 }
            return 2
        }
    }

    /// Assess a hazard against the aircraft position and, when there is one, the planned route.
    ///
    /// - Parameter route: the planned track as ordered coordinates. Sampled along each leg rather
    ///   than only at the waypoints — a leg can pass straight through an area with both of its
    ///   endpoints comfortably outside it, which endpoint-only testing would miss.
    static func assess(
        polygon ring: [CLLocationCoordinate2D],
        aircraft: CLLocationCoordinate2D,
        route: [CLLocationCoordinate2D] = []
    ) -> Assessment? {
        guard let distance = distanceNm(from: aircraft, toPolygon: ring) else { return nil }
        let inside = distance == 0

        guard route.count >= 2 else {
            return Assessment(distanceNm: distance, containsAircraft: inside,
                              intersectsRoute: false, routeDistanceNm: nil)
        }

        var nearestOnRoute = Double.greatestFiniteMagnitude
        var crosses = false
        for index in 0..<(route.count - 1) {
            for sample in sampleLeg(from: route[index], to: route[index + 1]) {
                guard let d = distanceNm(from: sample, toPolygon: ring) else { continue }
                nearestOnRoute = min(nearestOnRoute, d)
                if d == 0 { crosses = true; break }
            }
            if crosses { break }
        }

        return Assessment(
            distanceNm: distance,
            containsAircraft: inside,
            intersectsRoute: crosses,
            routeDistanceNm: nearestOnRoute == .greatestFiniteMagnitude ? nil : nearestOnRoute
        )
    }

    /// Points along a leg at roughly `legSampleIntervalNm`, endpoints included.
    ///
    /// Bounded: a very long leg would otherwise generate thousands of samples and this runs while a
    /// view is being built. 10 nm resolves any SIGMET polygon worth worrying about.
    static let legSampleIntervalNm: Double = 10
    static let maxSamplesPerLeg = 60

    static func sampleLeg(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> [CLLocationCoordinate2D] {
        let length = haversineNm(a, b)
        let steps = min(maxSamplesPerLeg, max(1, Int((length / legSampleIntervalNm).rounded(.up))))
        return (0...steps).map { step in
            let t = Double(step) / Double(steps)
            return CLLocationCoordinate2D(
                latitude: a.latitude + (b.latitude - a.latitude) * t,
                longitude: a.longitude + (b.longitude - a.longitude) * t
            )
        }
    }
}
