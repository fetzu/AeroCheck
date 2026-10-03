import Foundation
import CoreLocation

// MARK: - The leg being flown

/// The one live estimate of the leg being flown, to the navigation target (the next waypoint, or the
/// diversion field): what the NEXT cell, the phone's next line and the DEST line all read, so the
/// DEST ETE's first term is exactly the ETE beside NEXT. Pure: distance and ground speed in, times out.
/// (6.2.0)
///
/// It is today's map rule (`NavigationMapView.nextLegLive`, `FlightPlanManager.etaToNextWaypoint`)
/// taken out of the view, to the same arithmetic: nothing below 30 kt, where taxiing at 8 kt the
/// 12 NM to the first waypoint would read as an hour and a half.
struct NextLegLive: Equatable {
    /// Knots. Below it there is no ETE, no ETA and no Δ.
    static let minimumGroundSpeed = 30.0

    /// Seconds to the target at the current ground speed.
    let ete: TimeInterval
    /// The clock time over the target: `now` plus the ETE.
    let eta: Date

    /// Nil with no fix (no distance), or below `minimumGroundSpeed`.
    init?(distanceNM: Double?, groundSpeedKnots: Double, now: Date = FlightClock.now) {
        guard let ete = Self.ete(distanceNM: distanceNM, groundSpeedKnots: groundSpeedKnots) else { return nil }
        self.ete = ete
        self.eta = now.addingTimeInterval(ete)
    }

    /// The ETE alone: distance over ground speed, in seconds (as `etaToNextWaypoint` computes it).
    static func ete(distanceNM: Double?, groundSpeedKnots: Double) -> TimeInterval? {
        guard let distanceNM, distanceNM.isFinite, distanceNM >= 0,
              groundSpeedKnots.isFinite, groundSpeedKnots >= minimumGroundSpeed else { return nil }
        return (distanceNM / groundSpeedKnots) * 3600
    }
}

// MARK: - The DEST line

/// What the DEST line is computed from: the plan's legs as the leg rows read them, and the live
/// figures of the leg being flown. Built from the active plan by `init(plan:location:groundSpeedKnots:now:)`;
/// the memberwise form is for the tests (and a Companion adapter to come). (6.2.0)
struct DestinationInput: Equatable {
    /// The waypoints' names, departure first. Two or more, or there is no DEST line.
    var names: [String]
    /// `[i]` = the planned distance of the leg ARRIVING at waypoint `i` (`legArriving(at:)`); `[0]` is nil.
    var legDistanceNM: [Double?]
    /// `[i]` = the planned EET of the leg arriving at `i`, the departure allowance included on leg 1;
    /// nil where the leg has no EET. `[0]` is nil. The arrival allowance is on no leg: excluded.
    var legEET: [TimeInterval?]
    /// The waypoint flown to (`currentWaypointIndex`): 0 until the take-off marks the departure, the
    /// count once the destination is marked.
    var nextIndex: Int
    /// The plan's time over the destination: the take-off plus the cumulative EET to over the field,
    /// without the arrival allowance. What Δ is taken against.
    var plannedOverDestination: Date?
    /// The Flight Log's DEST ETO (`estimatedTimeOver(at: last)`, with the arrival allowance). Carried
    /// through for the UI tests' hook (`dest.line`'s value); the line never shows it.
    var plannedDestinationETO: Date?
    /// The destination's ATO, once marked.
    var destinationATO: Date?
    /// The field diverted to, while diverting.
    var diversionIdent: String?
    /// NM to the navigation target (the next waypoint, or the diversion field); nil with no fix.
    var liveDistanceNM: Double?
    /// Knots, as the NEXT cell reads it (`LocationManager.currentSpeedKnots`).
    var groundSpeedKnots: Double
    var now: Date
}

extension DestinationInput {
    /// The active plan, as the leg rows and the Flight Log read it:
    /// - the leg data on its departure waypoint (`legArriving(at:)`), its EET with `legEETExtra`, so leg 1
    ///   carries the departure allowance and no leg carries the arrival allowance;
    /// - the time over the destination on the waypoint before it (`waypoints[last - 1].estimatedTimeOver`
    ///   is the end of the last leg); the destination's own `estimatedTimeOver` adds the arrival allowance;
    /// - the live distance to `navigationTarget`, measured as `FlightPlanManager.distanceToNextWaypoint`
    ///   measures it.
    init(plan: FlightPlan, location: CLLocation?, groundSpeedKnots: Double, now: Date = FlightClock.now) {
        let waypoints = plan.waypoints
        let last = waypoints.count - 1
        names = waypoints.enumerated().map { index, waypoint in
            waypoint.name.isEmpty ? "WPT \(index + 1)" : waypoint.name
        }
        legDistanceNM = waypoints.indices.map { plan.legArriving(at: $0)?.distance }
        // `totalLegEET` reads a missing EET as 0; here a missing EET stays missing.
        legEET = waypoints.indices.map { index in
            plan.legArriving(at: index).flatMap { leg in
                leg.estimatedElapsedTime.map { $0 + (leg.legEETExtra ?? 0) }
            }
        }
        nextIndex = plan.currentWaypointIndex
        plannedOverDestination = last >= 1 ? waypoints[last - 1].estimatedTimeOver : nil
        plannedDestinationETO = last >= 1 ? plan.estimatedTimeOver(at: last) : nil
        destinationATO = waypoints.last?.actualTimeOver
        diversionIdent = plan.diversion?.ident
        liveDistanceNM = location.flatMap { location in
            plan.navigationTarget.map {
                location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) / 1852.0
            }
        }
        self.groundSpeedKnots = groundSpeedKnots
        self.now = now
    }
}

/// The DEST line's figures. (6.2.0)
struct DestinationEstimate: Equatable {
    enum Kind: Equatable {
        /// On the route: the destination at its end.
        case route
        /// Diverting: the field, straight there.
        case diversion
        /// The destination is marked.
        case completed
    }

    let kind: Kind
    /// The destination's name, or the diversion field's ident.
    let ident: String
    /// NM still to fly; nil when diverting with no fix.
    let remainingNM: Double?
    /// Seconds to over the destination; nil below 30 kt, with no fix, or with a planned EET missing.
    let ete: TimeInterval?
    let eta: Date?
    /// The plan's time over the destination, shown as "ETO hh:mm" when there is no live ETA. Nil when
    /// diverting: the plan says nothing about the field.
    let plannedETO: Date?
    /// The Flight Log's DEST ETO, for the UI tests' hook only (see `DestinationInput`).
    let plannedDestinationETO: Date?
    /// `plannedETO − eta` (once the destination is marked, `plannedETO − ATO`): above 0 ahead (▲), below 0
    /// behind (▼).
    let delta: TimeInterval?
    /// The route drawn to scale; nil while diverting, or for a route with no length.
    let track: RouteTrack?
    /// The waypoint flown to, the track's magenta notch, for "12 of 83 NM flown, next LSGC"; nil when
    /// diverting or once the destination is marked.
    var nextIdent: String? = nil
}

/// The DEST line: remaining distance, ETE, ETA and Δ to over the destination. (6.2.0)
///
/// ETE = the NEXT cell's live ETE to the next waypoint (`NextLegLive`) + the planned EETs of the legs
/// after it, to OVER the destination, without the arrival allowance; Δ against the plan's time over
/// the destination, with the leg rows' sign convention. Diverting, DEST is the field, straight there.
enum DestinationEstimator {
    static func estimate(_ input: DestinationInput) -> DestinationEstimate? {
        let count = input.names.count
        guard count >= 2 else { return nil }
        let last = count - 1

        // Diverting: the field, straight there. Adding the rest of the route would describe no flight
        // at all, and the plan has no time for the field to be ahead of or behind.
        if let field = input.diversionIdent {
            let live = NextLegLive(distanceNM: input.liveDistanceNM, groundSpeedKnots: input.groundSpeedKnots,
                                   now: input.now)
            return DestinationEstimate(kind: .diversion, ident: field, remainingNM: input.liveDistanceNM,
                                       ete: live?.ete, eta: live?.eta, plannedETO: nil,
                                       plannedDestinationETO: input.plannedDestinationETO, delta: nil, track: nil)
        }

        // The destination marked: nothing left, and the final ▲/▼ is the ATO against the plan.
        if input.nextIndex > last {
            return DestinationEstimate(kind: .completed, ident: input.names[last], remainingNM: 0,
                                       ete: nil, eta: nil, plannedETO: input.plannedOverDestination,
                                       plannedDestinationETO: input.plannedDestinationETO,
                                       delta: delta(planned: input.plannedOverDestination, actual: input.destinationATO),
                                       track: RouteTrack.make(legDistanceNM: input.legDistanceNM, nextIndex: count,
                                                              remainingNM: 0, diverting: false))
        }

        let next = max(0, input.nextIndex)
        let after = stride(from: next + 1, through: last, by: 1)

        // Live to NEXT plus the planned legs after it. With no fix, the leg to NEXT counts whole.
        let plannedAfter = after.reduce(0.0) { $0 + (Self.value(input.legDistanceNM, $1) ?? 0) }
        let remaining = input.liveDistanceNM.map { $0 + plannedAfter }
            ?? (Self.value(input.legDistanceNM, next) ?? 0) + plannedAfter

        // A leg after NEXT without an EET leaves the sum unknown, not short.
        let eetAfter = after.reduce(TimeInterval?.some(0)) { sum, index in
            sum.flatMap { total in Self.value(input.legEET, index).map { total + $0 } }
        }
        let nextETE = NextLegLive.ete(distanceNM: input.liveDistanceNM, groundSpeedKnots: input.groundSpeedKnots)
        let ete = nextETE.flatMap { next in eetAfter.map { next + $0 } }
        let eta = ete.map { input.now.addingTimeInterval($0) }

        return DestinationEstimate(kind: .route, ident: input.names[last], remainingNM: remaining,
                                   ete: ete, eta: eta, plannedETO: input.plannedOverDestination,
                                   plannedDestinationETO: input.plannedDestinationETO,
                                   delta: delta(planned: input.plannedOverDestination, actual: eta),
                                   track: RouteTrack.make(legDistanceNM: input.legDistanceNM, nextIndex: next,
                                                          remainingNM: input.liveDistanceNM == nil ? nil : remaining,
                                                          diverting: false),
                                   nextIdent: input.names[next])
    }

    /// `array[index]`, or nil past its end: the input's arrays are as long as `names` from the adapter,
    /// not necessarily from elsewhere.
    private static func value<T>(_ array: [T?], _ index: Int) -> T? {
        array.indices.contains(index) ? array[index] : nil
    }

    /// Planned less actual (or estimated): above 0 ahead.
    private static func delta(planned: Date?, actual: Date?) -> TimeInterval? {
        guard let planned, let actual else { return nil }
        return planned.timeIntervalSince(actual)
    }
}

// MARK: - The route to scale

/// The route drawn to scale under the DEST line: a notch per waypoint at its distance along the route,
/// and the part flown. Fractions of the planned total, 0…1. (6.2.0)
///
/// The flown part is the total less the remaining distance, held between the waypoints the aircraft
/// flies between: so flown + remaining = total whenever it is between them, and the bar and the
/// numbers agree.
struct RouteTrack: Equatable {
    /// One per waypoint: 0 for the departure, 1 for the destination.
    let notches: [Double]
    /// The waypoint flown to (drawn magenta and taller); nil once the destination is marked.
    let nextIndex: Int?
    /// The part flown.
    let flown: Double
    /// NM, the planned legs added up.
    let totalNM: Double
    /// A leg without a planned distance, drawn with no length: the track is not quite to scale.
    let isPartial: Bool

    /// NM flown, for "12 of 83 NM flown".
    var flownNM: Double { flown * totalNM }

    /// Nil while diverting (the track hides) or for a route with no length. `remainingNM` nil = no fix:
    /// the aircraft is shown at the waypoint it last passed.
    static func make(legDistanceNM: [Double?], nextIndex n: Int, remainingNM: Double?,
                     diverting: Bool) -> RouteTrack? {
        let count = legDistanceNM.count
        guard !diverting, count >= 2 else { return nil }

        var cumulative = [0.0]
        var isPartial = false
        for index in 1..<count {
            let leg = legDistanceNM[index].flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            if leg == nil { isPartial = true }
            cumulative.append(cumulative[index - 1] + (leg ?? 0))
        }
        let total = cumulative[count - 1]
        guard total > 0, total.isFinite else { return nil }

        let flownNM: Double
        if n <= 0 {
            flownNM = 0
        } else if n >= count {
            flownNM = total
        } else if let remainingNM {
            flownNM = min(max(total - remainingNM, cumulative[n - 1]), cumulative[n])
        } else {
            flownNM = cumulative[n - 1]
        }

        return RouteTrack(notches: cumulative.map { $0 / total },
                          nextIndex: n < count ? max(n, 0) : nil,
                          flown: flownNM / total,
                          totalNM: total,
                          isPartial: isPartial)
    }
}

// MARK: - The line's values

/// The DEST line's values as text. Pure; the view puts each in a widest-template cell. (6.2.0)
enum DestinationFormat {
    /// "83 NM", as the DEST summary always wrote it.
    static func distance(_ nauticalMiles: Double) -> String {
        String(format: "%.0f NM", nauticalMiles)
    }

    /// The ETE as the NEXT cell writes it: "42" min, or "1:07" h past the hour.
    static func eteValue(_ ete: TimeInterval) -> String { NextWaypointReadout.eteValue(ete) }
    static func eteUnit(_ ete: TimeInterval) -> String { NextWaypointReadout.eteUnit(ete) }

    /// A clock time (the ETA, or the plan's ETO), as the NEXT cell writes its ETA.
    static func clock(_ date: Date) -> String { NextWaypointReadout.eta(date) }

    /// What colour Δ takes: the theme's `onTarget`, `warning` or `textSecondary`.
    enum Tone: Equatable {
        case ahead
        case behind
        case even
    }

    /// Δ in whole minutes, the leg rows' convention: "▲3" ahead, "▼4" behind, "±0" on time.
    static func delta(_ seconds: TimeInterval) -> (text: String, tone: Tone) {
        let minutes = (seconds / 60).safeRoundedInt(or: 0)
        if minutes > 0 { return ("▲\(minutes)", .ahead) }
        if minutes < 0 { return ("▼\(-minutes)", .behind) }
        return ("±0", .even)
    }
}
