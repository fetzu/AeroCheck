import Foundation

// MARK: - Altitude planner ("Set altitudes")

/// Proposes planned altitudes for many waypoints at once: a fixed altitude, or a clearance above the
/// terrain. PURE: waypoints and a terrain profile in, altitudes and per-leg clearances out.
///
/// **Why "highest terrain on the legs either side" is the default basis.** The route profile is a
/// straight line between waypoint altitudes, so what matters is the terrain BETWEEN the waypoints, not
/// under them. On a Bressaucourt–Samedan route, "ground at the waypoint + 1000 ft" left eight legs
/// below terrain (ETIXO → PINAM by 2000 ft); the adjacent-legs basis gives every inner leg at least the
/// requested clearance, because both ends of each leg are raised over its highest point.
enum AltitudePlanner {

    enum Basis: String, CaseIterable, Identifiable {
        case highestOnAdjacentLegs
        case groundAtWaypoint
        var id: String { rawValue }
    }

    enum Mode: Equatable {
        case fixed(feet: Double)
        case aboveTerrain(clearanceFt: Double, basis: Basis, roundToFt: Double)
    }

    struct TerrainSample: Equatable {
        let distanceNM: Double
        let elevationFt: Double
    }

    /// Cumulative along-track distance per waypoint, in the same NM as the route profile.
    static func cumulativeNM(_ waypoints: [FlightPlanWaypoint]) -> [Double] {
        RouteAltitudeProfile(waypoints).cumNM
    }

    /// Terrain from `ElevationService` (metres, its own NM) mapped onto the route's NM in feet.
    static func samples(fromMetres terrain: [(distance: Double, elevation: Double)], routeNM: Double) -> [TerrainSample] {
        guard let span = terrain.last?.distance, span > 0 else { return [] }
        return terrain.map { TerrainSample(distanceNM: $0.distance / span * routeNM, elevationFt: $0.elevation * 3.28084) }
    }

    /// Highest terrain on each leg `k → k+1`; nil where no sample falls on the leg.
    static func legMaxTerrain(cumNM: [Double], terrain: [TerrainSample]) -> [Double?] {
        guard cumNM.count >= 2 else { return [] }
        return (0..<(cumNM.count - 1)).map { k in
            terrain.filter { $0.distanceNM >= cumNM[k] && $0.distanceNM <= cumNM[k + 1] }.map(\.elevationFt).max()
        }
    }

    /// Ground under each waypoint: the terrain sample nearest its along-track position.
    static func groundAtWaypoints(cumNM: [Double], terrain: [TerrainSample]) -> [Double?] {
        cumNM.map { d in terrain.min { abs($0.distanceNM - d) < abs($1.distanceNM - d) }?.elevationFt }
    }

    /// Altitudes for every waypoint. Indices in `selected` get the mode's value; everything else,
    /// including the departure and destination, keeps its altitude. A selected waypoint with no terrain
    /// to measure against keeps its altitude too, rather than being given a made-up one.
    static func proposedAltitudes(for waypoints: [FlightPlanWaypoint], selected: Set<Int>, mode: Mode,
                                  terrain: [TerrainSample]) -> [Double?] {
        let n = waypoints.count
        let cum = cumulativeNM(waypoints)
        let legMax = legMaxTerrain(cumNM: cum, terrain: terrain)
        let ground = groundAtWaypoints(cumNM: cum, terrain: terrain)
        return (0..<n).map { i in
            let current = waypoints[i].altitude
            guard selected.contains(i), i > 0, i < n - 1 else { return current }
            switch mode {
            case .fixed(let feet):
                return feet
            case .aboveTerrain(let clearance, let basis, let step):
                let base: Double?
                switch basis {
                case .highestOnAdjacentLegs:
                    base = [legMax[i - 1], legMax[i]].compactMap { $0 }.max()
                case .groundAtWaypoint:
                    base = ground[i]
                }
                guard let base else { return current }
                let rounding = max(1, step)
                return ((base + clearance) / rounding).rounded(.up) * rounding
            }
        }
    }

    /// Lowest clearance (ft) of the straight-line profile over the terrain on each leg; nil where the
    /// leg has no terrain sample or its ends have no altitude.
    static func legClearances(for waypoints: [FlightPlanWaypoint], altitudes: [Double?],
                              terrain: [TerrainSample]) -> [Double?] {
        guard waypoints.count >= 2 else { return [] }
        var withAltitudes = waypoints
        for i in withAltitudes.indices where i < altitudes.count { withAltitudes[i].altitude = altitudes[i] }
        let profile = RouteAltitudeProfile(withAltitudes)
        let cum = profile.cumNM
        guard profile.hasUsableProfile else { return Array(repeating: nil, count: waypoints.count - 1) }
        return (0..<(waypoints.count - 1)).map { k in
            guard altitudes[k] != nil, altitudes[k + 1] != nil else { return nil }
            return terrain.filter { $0.distanceNM >= cum[k] && $0.distanceNM <= cum[k + 1] }
                .compactMap { s in profile.altitude(atNM: s.distanceNM).map { $0 - s.elevationFt } }
                .min()
        }
    }
}
