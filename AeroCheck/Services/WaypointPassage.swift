import Foundation
import CoreLocation

// MARK: - Waypoint passage (actual times over)

/// When the aircraft passed each waypoint of a route, reconstructed from its GPS track. PURE.
///
/// A pilot rarely flies over a waypoint: the turn is started early, a CTR clearance moves the track,
/// a reporting point is passed a mile to the side. So "passed" does not mean "came within a radius"
/// (the in-flight 500 m trigger missed most of a real Bressaucourt–Samedan flight, and once it missed
/// the departure it never advanced at all). It means the aircraft went ABEAM the waypoint: its
/// progress along the planned route reached the waypoint's along-route distance, while it was within
/// `toleranceNM` of the route. That is also the moment a pilot writes the ATO on the kneeboard.
///
/// Progress only moves forward, and each GPS fix is matched against the leg it is on and the next
/// two, so a later leg passing near an earlier waypoint cannot rewrite history. A waypoint the
/// aircraft never came abeam of within the tolerance (a skipped corner, a diversion) stays nil.
///
/// The departure takes the takeoff time and the destination the landing time, each only when the
/// aircraft was actually there.
enum WaypointPassage {

    struct Fix: Equatable {
        let time: Date
        let coordinate: CLLocationCoordinate2D
        /// Metres per second, as `GPSPoint.speed`.
        let speed: Double

        static func == (a: Fix, b: Fix) -> Bool {
            a.time == b.time && a.coordinate.latitude == b.coordinate.latitude
                && a.coordinate.longitude == b.coordinate.longitude && a.speed == b.speed
        }
    }

    /// How far off the route a passage still counts. The widest real offset on the test flight was
    /// 1.9 NM (Ilanz, route flown along the valley).
    static let toleranceNM = 2.5
    /// Fixes further than this from every candidate leg are ignored (a detour, a hold elsewhere).
    static let corridorNM = 5.0
    /// Without a recorded takeoff, the first fix at this speed or above counts as airborne (~40 kt).
    static let airborneSpeed = 20.0

    /// One time per waypoint, nil where the passage cannot be established.
    ///
    /// - Parameters:
    ///   - takeoff: the takeoff time (the app records line-up); nil → first fix at `airborneSpeed`.
    ///   - landing: the final landing, or nil while still flying (then the destination stays nil).
    static func timesOver(route: [CLLocationCoordinate2D], track: [Fix], takeoff: Date?, landing: Date?,
                          toleranceNM: Double = toleranceNM) -> [Date?] {
        var times = [Date?](repeating: nil, count: route.count)
        guard route.count >= 2, !track.isEmpty else { return times }

        let fixes = track.sorted { $0.time < $1.time }
        guard let start = takeoff ?? fixes.first(where: { $0.speed >= airborneSpeed })?.time else { return times }
        let end = landing ?? fixes.last!.time
        let geometry = RouteGeometry(route: route)
        let points = geometry.points
        let cum = geometry.cumulative

        // Departure and destination: where the aircraft was at takeoff and landing.
        if let at = fix(nearest: start, in: fixes), geometry.distanceNM(at.coordinate, route[0]) <= toleranceNM {
            times[0] = start
        }
        if let landing, let at = fix(nearest: landing, in: fixes),
           geometry.distanceNM(at.coordinate, route[route.count - 1]) <= toleranceNM {
            times[route.count - 1] = landing
        }

        // En route: the moment progress along the route reaches each waypoint.
        var leg = 0
        var previous: (s: Double, time: Date)?
        for fix in fixes where fix.time >= start && fix.time <= end {
            let p = geometry.xy(fix.coordinate)
            var best: (s: Double, offset: Double, leg: Int)?
            for k in leg..<min(leg + 3, points.count - 1) {
                let (s, offset) = geometry.project(p, onto: k)
                if best == nil || offset < best!.offset { best = (s, offset, k) }
            }
            guard let match = best, match.offset <= corridorNM else { continue }
            leg = max(leg, match.leg)
            let s = max(previous?.s ?? match.s, match.s)
            if let prev = previous, s > prev.s {
                for i in 1..<(route.count - 1) where times[i] == nil && prev.s < cum[i] && cum[i] <= s {
                    guard match.offset <= toleranceNM else { continue }
                    let fraction = (cum[i] - prev.s) / (s - prev.s)
                    times[i] = prev.time.addingTimeInterval(fix.time.timeIntervalSince(prev.time) * fraction)
                }
            }
            previous = (s, fix.time)
        }
        return times
    }

    private static func fix(nearest time: Date, in fixes: [Fix]) -> Fix? {
        fixes.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
    }
}

// MARK: - Filling a plan from a flight

extension FlightPlan {
    /// The plan with every waypoint that has no ATO given one from the flight's GPS track. A time
    /// recorded in flight (a tap on the waypoint, the proximity trigger) is never replaced.
    func withActualTimesOver(fromTrack track: [GPSPoint], takeoff: Date?, landing: Date?) -> FlightPlan {
        let fixes = track.map {
            WaypointPassage.Fix(time: $0.timestamp,
                                coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                                speed: $0.speed)
        }
        let times = WaypointPassage.timesOver(route: waypoints.map(\.coordinate), track: fixes,
                                              takeoff: takeoff, landing: landing)
        var plan = self
        for i in plan.waypoints.indices where plan.waypoints[i].actualTimeOver == nil {
            plan.waypoints[i].actualTimeOver = times[i]
        }
        return plan
    }

    /// `withActualTimesOver(fromTrack:…)` for a recorded flight: takeoff = line-up (the time the app
    /// records and flight time is measured from), landing = the final landing.
    func withActualTimesOver(from flight: Flight) -> FlightPlan {
        withActualTimesOver(fromTrack: flight.gpsTrack, takeoff: flight.lineUpTime, landing: flight.landingTime)
    }
}
