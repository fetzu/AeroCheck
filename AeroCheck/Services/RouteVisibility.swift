import Foundation
import CoreLocation
import MapKit

/// Whether a planned route is anywhere on the map, and where to look when it isn't.
///
/// The nav map opens on the aircraft. Until you have flown to the route, the route is somewhere else
/// — so an armed plan could be entirely off-screen with the only trace a "WPT 1/5 LSGG" label in the
/// bottom bar, indistinguishable from having no plan loaded at all. This computes the fact the map
/// needs in order to say otherwise. (v4.4.0, device-test feedback)
///
/// Pure and `nonisolated`: the map's job is to draw the answer, not to work it out.
enum RouteVisibility {

    /// Where the route is, relative to the centre of what the map is showing.
    struct OffScreenHint: Equatable {
        /// Great-circle distance from the map centre to the nearest point ON the route, in NM.
        let distanceNm: Double
        /// True bearing from the map centre to that point, 0..<360.
        let bearingDegrees: Double

        /// `"264"` — a three-digit bearing, the form a pilot reads everywhere else in the app.
        var bearingLabel: String { String(format: "%03.0f", bearingDegrees) }
    }

    /// nil when any part of the route is inside `region` — there is then nothing to point at, and the
    /// map must not nag. Also nil for a route with fewer than two points, which has no line to miss.
    ///
    /// Tests SEGMENTS, not sampled points. A route sampled every 10 NM can step straight over a
    /// zoomed-in viewport and report "off screen" while the line is drawn across the middle of it.
    static func offScreenHint(route: [CLLocationCoordinate2D],
                              region: MKCoordinateRegion) -> OffScreenHint? {
        let points = route.filter { CLLocationCoordinate2DIsValid($0) }
        guard points.count >= 2 else { return nil }
        guard region.span.latitudeDelta > 0, region.span.longitudeDelta > 0 else { return nil }

        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2

        for i in 0..<(points.count - 1) {
            if segmentIntersectsRect(points[i], points[i + 1],
                                     minLat: minLat, maxLat: maxLat,
                                     minLon: minLon, maxLon: maxLon) {
                return nil
            }
        }

        // Off screen: aim at the nearest point on the LINE, not the nearest waypoint — on a long leg
        // the closest thing to you is usually somewhere in the middle of it.
        var best: CLLocationCoordinate2D?
        var bestDistance = Double.infinity
        for i in 0..<(points.count - 1) {
            let candidate = nearestPointOnSegment(to: region.center, a: points[i], b: points[i + 1])
            let distance = distanceNm(region.center, candidate)
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        guard let target = best, bestDistance.isFinite else { return nil }
        return OffScreenHint(distanceNm: bestDistance,
                             bearingDegrees: bearing(from: region.center, to: target))
    }

    // MARK: - Geometry

    /// Cohen–Sutherland outcodes: if both endpoints share an outside region the segment cannot cross
    /// the rectangle, which rejects almost every segment in one comparison.
    private static func segmentIntersectsRect(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
                                              minLat: Double, maxLat: Double,
                                              minLon: Double, maxLon: Double) -> Bool {
        func outcode(_ p: CLLocationCoordinate2D) -> Int {
            var code = 0
            if p.longitude < minLon { code |= 1 }
            if p.longitude > maxLon { code |= 2 }
            if p.latitude < minLat { code |= 4 }
            if p.latitude > maxLat { code |= 8 }
            return code
        }
        var codeA = outcode(a), codeB = outcode(b)
        var ax = a.longitude, ay = a.latitude
        var bx = b.longitude, by = b.latitude

        // Bounded: each iteration clips one endpoint onto an edge, which clears at least one bit.
        for _ in 0..<8 {
            if codeA | codeB == 0 { return true }       // both inside
            if codeA & codeB != 0 { return false }      // both outside the same edge

            let outside = codeA != 0 ? codeA : codeB
            var x = 0.0, y = 0.0
            if outside & 8 != 0 {         // above
                x = ax + (bx - ax) * (maxLat - ay) / (by - ay); y = maxLat
            } else if outside & 4 != 0 {  // below
                x = ax + (bx - ax) * (minLat - ay) / (by - ay); y = minLat
            } else if outside & 2 != 0 {  // right
                y = ay + (by - ay) * (maxLon - ax) / (bx - ax); x = maxLon
            } else {                      // left
                y = ay + (by - ay) * (minLon - ax) / (bx - ax); x = minLon
            }
            guard x.isFinite, y.isFinite else { return false }

            if outside == codeA {
                ax = x; ay = y; codeA = outcode(CLLocationCoordinate2D(latitude: ay, longitude: ax))
            } else {
                bx = x; by = y; codeB = outcode(CLLocationCoordinate2D(latitude: by, longitude: bx))
            }
        }
        return false
    }

    /// Closest point on segment a–b to `p`, in a local equirectangular frame (longitude scaled by
    /// cos(lat)) so "closest" means closest on the ground rather than in degrees.
    private static func nearestPointOnSegment(to p: CLLocationCoordinate2D,
                                              a: CLLocationCoordinate2D,
                                              b: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let k = max(0.01, cos(p.latitude * .pi / 180))
        let px = p.longitude * k, py = p.latitude
        let ax = a.longitude * k, ay = a.latitude
        let bx = b.longitude * k, by = b.latitude
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return a }
        let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / lengthSquared))
        return CLLocationCoordinate2D(latitude: ay + t * dy, longitude: (ax + t * dx) / k)
    }

    private static func distanceNm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1852.0
    }

    /// Initial great-circle bearing, degrees true.
    private static func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let φ1 = from.latitude * .pi / 180, φ2 = to.latitude * .pi / 180
        let Δλ = (to.longitude - from.longitude) * .pi / 180
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees.truncatingRemainder(dividingBy: 360) < 0 ? degrees + 360 : degrees
    }
}
