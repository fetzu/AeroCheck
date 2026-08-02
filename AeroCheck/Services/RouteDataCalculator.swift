import Foundation
import CoreLocation

/// Computes which countries a planned route crosses, by sampling the route at a fixed interval and
/// testing each sample against real national borders. Used by trip-aware prefetch to offer downloading
/// the data layers a trip needs. (v4.1.0; border test added v4.4.0)
///
/// **This used to be a bounding-box test, and a box is a terrible model of a country.** Switzerland's
/// box also covers slabs of France, Germany, Italy and Austria, so a Jura circuit that never left
/// Swiss airspace proposed downloading Germany — ~30 000 obstacle records — and no amount of reading
/// the banner would tell a pilot why. It now tests against simplified polygons
/// (`CountryBoundaries`), which is both smaller and more honest.
///
/// **Still biased toward inclusion, on purpose.** The test is "within `borderBufferNm` of the border",
/// not "inside it". Missing a country the aircraft enters means flying without its airspace,
/// obstacles and reporting points; including one it merely skirts costs a download. Near a frontier
/// the answer should be *both* countries, and 10 nm is roughly the distance a light aircraft covers
/// in four minutes — comfortably more than any navigational slop or geometry simplification.
struct RouteDataCalculator {
    /// Sample spacing along each leg, in nautical miles.
    static let sampleSpacingNm = 10.0

    /// How close to a border counts as "crossing it". See the note above on the inclusion bias.
    static let borderBufferNm = 10.0

    /// ISO-2 country codes the route enters or passes within `borderBufferNm` of, sorted. Empty for a
    /// route with no waypoints, or one entirely over international water.
    @MainActor
    static func countries(crossing waypoints: [CLLocationCoordinate2D]) -> [String] {
        let samples = sampledPoints(for: waypoints)
        guard !samples.isEmpty else { return [] }
        var found = Set<String>()
        for p in samples {
            found.formUnion(CountryBoundaries.shared.countries(near: p, bufferNm: borderBufferNm))
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
