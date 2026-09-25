import Foundation
import CoreLocation

// MARK: - Divert (v5.1)
//
// The in-flight half of stops: "the valley ahead is closing, where do I go". The list has to be
// readable in a glance and chosen in two taps, so this decides everything the sheet shows — what
// counts as ahead, what is soonest, what is listed at all — and the sheet only draws it. PURE: a
// position, a track, a speed and some aerodromes in; sections out.

enum DivertPlanner {

    /// One aerodrome the aircraft could go to, from where it is now.
    struct Option: Equatable {
        let aerodrome: TripPlanner.Aerodrome
        /// True bearing from the aircraft.
        let bearing: Double
        let distanceNM: Double
        /// Time to go, in minutes, at the ground speed achievable on that bearing.
        let minutes: Double
        /// Within 90° of the current track, so no turn back is involved.
        let isAhead: Bool
        /// In another country than the one the flight is in: customs and a flight plan to think about.
        let crossesBorder: Bool
    }

    /// What the sheet lists, in its order.
    struct Sections: Equatable {
        /// The end of the route (going there is "direct to", not a diversion).
        var destination: Option?
        /// The planned alternate, when there is one.
        var alternate: Option?
        /// Soonest first.
        var ahead: [Option]
        /// Soonest first: turning back.
        var behind: [Option]
    }

    static let rangeNM = 60.0
    static let maxAhead = 5
    static let maxBehind = 2
    /// Below this the aircraft is on the ground or barely moving: no meaningful track.
    static let movingKt = 30.0

    /// The diversion list from the aircraft's position.
    ///
    /// - Parameters:
    ///   - track: true track over the ground, nil when unknown (then nothing is "behind").
    ///   - groundSpeedKt: current ground speed; below `movingKt` the plan's cruise speed is used.
    ///   - wind: forecast wind at the aircraft's level, when the app has one. Each bearing's time then
    ///     uses the ground speed the aircraft will actually make on it, which is what separates a
    ///     field 12 NM upwind from one 12 NM downwind.
    ///   - country: where the aircraft is, for the border flag.
    static func sections(from position: CLLocationCoordinate2D,
                         track: Double?,
                         groundSpeedKt: Double,
                         cruiseKt: Double,
                         wind: FlightPlan.WindAloft?,
                         aerodromes: [TripPlanner.Aerodrome],
                         destination: TripPlanner.Aerodrome?,
                         alternate: TripPlanner.Aerodrome?,
                         pinned: TripPlanner.Aerodrome? = nil,
                         country: String?) -> Sections {
        let moving = groundSpeedKt >= movingKt
        let heading = moving ? track : nil
        let airspeed = trueAirspeed(groundSpeedKt: moving ? groundSpeedKt : cruiseKt, track: heading, wind: wind)

        func option(_ aerodrome: TripPlanner.Aerodrome) -> Option {
            let bearing = position.bearing(to: aerodrome.coordinate)
            let distance = CLLocation(latitude: position.latitude, longitude: position.longitude)
                .distance(from: CLLocation(latitude: aerodrome.latitude, longitude: aerodrome.longitude)) / 1852
            let speed = wind.flatMap {
                FlightPlan.windCorrectedGroundSpeed(trueAirspeedKt: airspeed, trueCourseDeg: bearing, wind: $0)
            } ?? (moving ? groundSpeedKt : cruiseKt)
            let ahead = heading.map { angle(between: bearing, and: $0) <= 90 } ?? true
            let border = country.flatMap { here in aerodrome.country.map { $0 != here } } ?? false
            return Option(aerodrome: aerodrome, bearing: bearing, distanceNM: distance,
                          minutes: speed > 0 ? distance / speed * 60 : .infinity,
                          isAhead: ahead, crossesBorder: border)
        }

        let reserved = Set([destination?.ident, alternate?.ident, pinned?.ident].compactMap { $0 })
        let nearby = aerodromes
            .filter { !reserved.contains($0.ident) }
            .map(option)
            .filter { $0.distanceNM <= rangeNM }
            .sorted { $0.minutes < $1.minutes }
        var ahead = Array(nearby.filter(\.isAhead).prefix(maxAhead))
        var behind = Array(nearby.filter { !$0.isAhead }.prefix(maxBehind))
        // A field the pilot pointed at on the map is listed whatever its rank, first in its section.
        if let pinned, pinned.ident != destination?.ident, pinned.ident != alternate?.ident {
            let chosen = option(pinned)
            if chosen.isAhead { ahead.insert(chosen, at: 0) } else { behind.insert(chosen, at: 0) }
        }
        return Sections(destination: destination.map(option),
                        alternate: alternate.map(option),
                        ahead: ahead,
                        behind: behind)
    }

    /// The airspeed the aircraft is flying at, recovered from its ground vector and the wind: the
    /// air vector is the ground vector minus the wind. Without a wind or a track, the ground speed is
    /// the best estimate there is.
    static func trueAirspeed(groundSpeedKt: Double, track: Double?, wind: FlightPlan.WindAloft?) -> Double {
        guard let track, let wind, wind.speedKt > 0 else { return groundSpeedKt }
        let t = track * .pi / 180
        // The wind blows FROM its direction, so its vector points the other way.
        let w = (wind.directionDegTrue + 180) * .pi / 180
        let x = groundSpeedKt * sin(t) - wind.speedKt * sin(w)
        let y = groundSpeedKt * cos(t) - wind.speedKt * cos(w)
        return hypot(x, y)
    }

    /// The smaller angle between two bearings, 0…180.
    static func angle(between a: Double, and b: Double) -> Double {
        let d = abs((a - b).truncatingRemainder(dividingBy: 360))
        return d > 180 ? 360 - d : d
    }
}
