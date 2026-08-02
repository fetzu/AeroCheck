import Foundation
import CoreLocation

/// Answers "which countries is this point in, or near?" from bundled simplified national borders.
///
/// Replaces the bounding-box test that `RouteDataCalculator` used to decide which countries a route
/// needs data for. A bbox is a terrible model of a country: Switzerland's box also covers a slab of
/// France, Germany, Italy and Austria, so a flight that never left the Jura proposed downloading
/// Germany — and, once obstacles are in the bundle, Germany alone is ~30 000 records. The failure was
/// not cosmetic: it made "download the data for this trip" mean something a pilot could not predict.
///
/// **Deliberately biased toward inclusion.** Missing a country the aircraft actually enters means
/// flying without its airspace, obstacles and reporting points; including one it merely passes near
/// costs a download. So containment alone is not the test — a country counts if the route comes
/// within `bufferNm` of its border. That also absorbs the simplification error in the bundled
/// geometry, which is coarser than the buffer by design.
///
/// **Data:** Natural Earth 1:50m `admin_0_countries` (public domain), reduced to the ISO-2 codes
/// OpenAIP actually serves, outer rings only, Douglas–Peucker simplified with a tolerance scaled to
/// each country's extent (2 km for small countries, capped at ~9 km for continent-sized ones) and
/// rounded to 3 decimal places. 119 countries, ~24 500 vertices, ~350 KB.
///
/// Interior rings (holes) are dropped on purpose: a hole would only ever *exclude* a country, which
/// is the unsafe direction, and every enclave in the set is a microstate OpenAIP does not serve.
@MainActor
final class CountryBoundaries {
    static let shared = CountryBoundaries()

    /// One country's outer rings, each a flat `[lon, lat, lon, lat, …]` array, with the ring's own
    /// bounding box precomputed so the common case (point nowhere near this ring) is four compares.
    private struct Ring {
        let coords: [Double]
        let minLon: Double, maxLon: Double, minLat: Double, maxLat: Double

        init?(coords: [Double]) {
            guard coords.count >= 8, coords.count % 2 == 0 else { return nil }
            var minX = Double.infinity, maxX = -Double.infinity
            var minY = Double.infinity, maxY = -Double.infinity
            for i in stride(from: 0, to: coords.count, by: 2) {
                minX = min(minX, coords[i]);     maxX = max(maxX, coords[i])
                minY = min(minY, coords[i + 1]); maxY = max(maxY, coords[i + 1])
            }
            self.coords = coords
            self.minLon = minX; self.maxLon = maxX
            self.minLat = minY; self.maxLat = maxY
        }
    }

    private var ringsByCountry: [String: [Ring]] = [:]
    private var didLoad = false

    /// Countries with no bundled polygon fall back to their `OpenAIPConfig.countryBounds` box. Only
    /// Réunion is in that state today (Natural Earth files it under France), and an isolated island's
    /// box is a fair approximation of the island — unlike a landlocked country's.
    private(set) var countriesWithoutPolygons: Set<String> = []

    private init() {}

    /// Parse the bundled asset. Cheap enough to do on demand (~350 KB of JSON numbers) and done once;
    /// callers need not pre-warm.
    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let url = Bundle.main.url(forResource: "country-boundaries", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: [[Double]]].self, from: data) else {
            AppLog.general.debugLine("Country boundaries asset missing or unreadable — falling back to bounding boxes")
            countriesWithoutPolygons = Set(OpenAIPConfig.countryBounds.keys)
            return
        }
        ringsByCountry = raw.compactMapValues { rings in
            let parsed = rings.compactMap(Ring.init(coords:))
            return parsed.isEmpty ? nil : parsed
        }
        countriesWithoutPolygons = Set(OpenAIPConfig.countryBounds.keys).subtracting(ringsByCountry.keys)
    }

    /// Countries containing `coordinate`, or whose border is within `bufferNm` of it.
    func countries(near coordinate: CLLocationCoordinate2D, bufferNm: Double) -> Set<String> {
        loadIfNeeded()
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return [] }

        // A degree of latitude is ~60 nm everywhere; a degree of longitude shrinks with latitude, and
        // near the poles cos(lat) → 0, so the guard keeps the longitude margin finite.
        let latMargin = bufferNm / 60.0
        let cosLat = max(0.01, cos(coordinate.latitude * .pi / 180))
        let lonMargin = bufferNm / (60.0 * cosLat)

        var found: Set<String> = []
        for (code, rings) in ringsByCountry {
            for ring in rings {
                guard coordinate.longitude >= ring.minLon - lonMargin,
                      coordinate.longitude <= ring.maxLon + lonMargin,
                      coordinate.latitude >= ring.minLat - latMargin,
                      coordinate.latitude <= ring.maxLat + latMargin else { continue }
                if contains(coordinate, ring) || distanceNm(from: coordinate, to: ring) <= bufferNm {
                    found.insert(code)
                    break
                }
            }
        }

        // Countries we have no polygon for keep the old box test rather than silently disappearing.
        for code in countriesWithoutPolygons {
            guard let box = OpenAIPConfig.countryBounds[code] else { continue }
            if coordinate.latitude >= box.minLat - latMargin, coordinate.latitude <= box.maxLat + latMargin,
               coordinate.longitude >= box.minLon - lonMargin, coordinate.longitude <= box.maxLon + lonMargin {
                found.insert(code)
            }
        }
        return found
    }

    // MARK: - Geometry

    /// Standard ray-casting containment test on a flat `[lon, lat, …]` ring.
    private func contains(_ point: CLLocationCoordinate2D, _ ring: Ring) -> Bool {
        let c = ring.coords
        let n = c.count / 2
        var inside = false
        var j = n - 1
        for i in 0..<n {
            let xi = c[2 * i], yi = c[2 * i + 1]
            let xj = c[2 * j], yj = c[2 * j + 1]
            if (yi > point.latitude) != (yj > point.latitude) {
                let denominator = yj - yi
                if denominator != 0,
                   point.longitude < (xj - xi) * (point.latitude - yi) / denominator + xi {
                    inside.toggle()
                }
            }
            j = i
        }
        return inside
    }

    /// Shortest distance from the point to the ring's edges, in nautical miles.
    ///
    /// Works in a local equirectangular projection (longitude scaled by cos(lat)), which is accurate
    /// to well under a percent over the tens of nautical miles this is ever asked about — and far
    /// inside the error already baked into the simplified geometry.
    private func distanceNm(from point: CLLocationCoordinate2D, to ring: Ring) -> Double {
        let cosLat = max(0.01, cos(point.latitude * .pi / 180))
        let px = point.longitude * cosLat, py = point.latitude
        let c = ring.coords
        let n = c.count / 2
        var best = Double.infinity
        var j = n - 1
        for i in 0..<n {
            let ax = c[2 * j] * cosLat, ay = c[2 * j + 1]
            let bx = c[2 * i] * cosLat, by = c[2 * i + 1]
            best = min(best, pointToSegmentDegrees(px: px, py: py, ax: ax, ay: ay, bx: bx, by: by))
            if best == 0 { break }
            j = i
        }
        return best * 60.0   // degrees → nautical miles
    }

    private func pointToSegmentDegrees(px: Double, py: Double,
                                       ax: Double, ay: Double,
                                       bx: Double, by: Double) -> Double {
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return ((px - ax) * (px - ax) + (py - ay) * (py - ay)).squareRoot() }
        let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / lengthSquared))
        let cx = ax + t * dx, cy = ay + t * dy
        return ((px - cx) * (px - cx) + (py - cy) * (py - cy)).squareRoot()
    }

    #if DEBUG
    /// Test seam: a SEPARATE instance holding synthetic rings, so the geometry can be pinned against
    /// a shape whose distances are obvious without touching `shared`. Deliberately not a mutator on
    /// the singleton — one test seeding it would leave every later test in the run looking at an empty
    /// world, and the failure would surface as an unrelated test "randomly" finding no countries.
    static func makeForTesting(rings: [String: [[Double]]],
                               countriesWithoutPolygons: Set<String> = []) -> CountryBoundaries {
        let boundaries = CountryBoundaries()
        boundaries.didLoad = true
        boundaries.ringsByCountry = rings.compactMapValues { $0.compactMap(Ring.init(coords:)) }
        boundaries.countriesWithoutPolygons = countriesWithoutPolygons
        return boundaries
    }
    #endif
}
