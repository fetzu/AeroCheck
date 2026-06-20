import Foundation
import CoreLocation

/// Computes which countries a planned route crosses, by sampling the route at a fixed interval and
/// testing each sample against OpenAIP's coarse per-country bounding boxes. Used by trip-aware prefetch
/// to offer downloading the data layers a trip needs. Coarse by design (bbox test) — a border point may
/// match more than one country, which is the safe side for a "download this too" suggestion. (v4.1.0)
struct RouteDataCalculator {
    /// Sample spacing along each leg, in nautical miles.
    static let sampleSpacingNm = 10.0

    /// ISO-2 country codes whose bounding box contains any point of the route (waypoints + interpolated
    /// samples), sorted. Empty when fewer than one waypoint or no bbox matches (e.g. mid-ocean).
    static func countries(crossing waypoints: [CLLocationCoordinate2D]) -> [String] {
        let samples = sampledPoints(for: waypoints)
        guard !samples.isEmpty else { return [] }
        var found = Set<String>()
        for p in samples {
            for (code, b) in OpenAIPConfig.countryBounds where
                p.latitude >= b.minLat && p.latitude <= b.maxLat &&
                p.longitude >= b.minLon && p.longitude <= b.maxLon {
                found.insert(code)
            }
        }
        return found.sorted()
    }

    /// Route densified to ~`sampleSpacingNm` spacing (waypoints + interpolated points).
    static func sampledPoints(for waypoints: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard waypoints.count > 1 else { return waypoints }
        var samples: [CLLocationCoordinate2D] = []
        for i in 0..<(waypoints.count - 1) {
            let a = waypoints[i], b = waypoints[i + 1]
            let steps = max(1, Int((distanceNm(a, b) / sampleSpacingNm).rounded(.up)))
            for s in 0..<steps {
                let t = Double(s) / Double(steps)
                samples.append(CLLocationCoordinate2D(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t))
            }
        }
        samples.append(waypoints[waypoints.count - 1])
        return samples
    }

    private static func distanceNm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) / 1852.0
    }
}
