import Foundation
import CoreLocation

// MARK: - Dry run (6.4.0): the flight generator

/// The aircraft's numbers in a dry run, knots: the WT9's, as its bundled checklist gives them, or another
/// aircraft's, scaled from what the app knows of it. (6.4.0)
struct DryRunPerformance: Equatable {
    var vso: Double
    var vr: Double
    var vy: Double
    var cruise: Double
    var descent: Double
    var downwind: Double
    var base: Double
    var finalApproach: Double
    var touchdown: Double
    var taxi: Double

    static let wt9 = DryRunPerformance(vso: 33, vr: 40, vy: 70, cruise: 100, descent: 105, downwind: 80, base: 70,
                                       finalApproach: 63, touchdown: 50, taxi: 9)

    /// Another aircraft, from its Vso, Vr and cruise speed: the climb and the circuit's speeds as the WT9's in
    /// proportion to Vso (its final at 1.9 Vso flies at 1.9 Vso), the downwind kept under the cruise.
    static func scaled(vso: Double, vr: Double, cruise: Double) -> DryRunPerformance {
        let k = vso / wt9.vso
        return DryRunPerformance(vso: vso, vr: vr, vy: (wt9.vy * k).rounded(), cruise: cruise, descent: cruise + 5,
                                 downwind: min((wt9.downwind * k).rounded(), (cruise * 0.9).rounded()),
                                 base: (wt9.base * k).rounded(), finalApproach: (wt9.finalApproach * k).rounded(),
                                 touchdown: (wt9.touchdown * k).rounded(), taxi: wt9.taxi)
    }
}

/// One GPS fix of a dry run, a second after the one before, as CoreLocation delivers them.
struct DryRunFix: Equatable {
    /// Seconds since the dry run began.
    let t: Int
    let latitude: Double
    let longitude: Double
    /// Metres above sea level, with a GPS's bias and wander.
    let altitudeM: Double
    /// Metres per second.
    let speedMS: Double
    let horizontalAccuracyM: Double
    /// Degrees true; -1 below 2 kt, as CoreLocation has no course standing still.
    let course: Double

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    /// As a satellite fix (a speed accuracy), stamped `timestamp`: the flight's clock, not the wall's.
    func location(at timestamp: Date) -> CLLocation {
        CLLocation(coordinate: coordinate, altitude: altitudeM, horizontalAccuracy: horizontalAccuracyM,
                   verticalAccuracy: 6, course: course, courseAccuracy: course < 0 ? -1 : 5, speed: speedMS,
                   speedAccuracy: 0.5, timestamp: timestamp)
    }
}

/// The flight a dry run flies, one GPS fix a second, decided as it goes: the model of scripts/flightsim
/// (the ground replays' flights) made live. The route can change under it (a Direct To, a divert), and the
/// pilot answers it where a pilot decides: the engine start and the line-up it waits for, what the aircraft
/// does at the end of each final, whether it goes again after a full stop. Pure: no clock and no app state;
/// whoever runs the dry run asks for the next fix and answers through `pilot`. (6.4.0)
final class DryRunGenerator {
    /// Where it waits, parked, until the pilot lets it go on.
    enum Hold: Equatable {
        case engineStart
        /// At the holding point, or stopped on the runway after a full stop: the checks to the line-up.
        case lineUp
        /// Off the runway at the end, for good.
        case parked
    }

    enum Landing: Equatable { case fullStop, touchAndGo, goAround }
    enum AfterFullStop: Equatable { case goAgain, vacate }

    /// What the generator asks, where a pilot decides.
    struct Pilot {
        /// May it go on from `hold`? Asked every second while it waits.
        var mayGo: (Hold) -> Bool = { _ in true }
        /// What the aircraft does at the end of this final: asked once, at 250 ft above the field (where a
        /// go-around climbs away), so the pilot can choose on the way down.
        var landing: (DryRunAerodrome) -> Landing = { _ in .fullStop }
        /// Stopped on the runway after a full stop: go again from there, off the runway, or not yet (nil).
        /// Asked every second until it has an answer.
        var afterFullStop: (DryRunAerodrome) -> AfterFullStop? = { _ in .vacate }
    }

    /// What the flight is: circuits where it takes off, or a route to another aerodrome.
    enum Mission {
        case circuits
        case route(waypoints: [CLLocationCoordinate2D], destination: DryRunAerodrome, cruiseAltitudeFt: Double)
    }

    let performance: DryRunPerformance
    var pilot: Pilot
    /// Seconds flown so far: the next fix's `t`.
    private(set) var t = 0
    /// Where things happened, for the tests and the coach: "liftoff", "touchdown", "stopped"…, in order.
    private(set) var marks: [(name: String, t: Int)] = []
    /// The aerodrome it's at, or flying the circuit of.
    private(set) var aerodrome: DryRunAerodrome
    private(set) var isAirborne = false
    /// Parked off the runway at the end, for good.
    var isParkedForGood: Bool { if case .hold(.parked)? = actions.first { return true } else { return false } }

    /// On final, its end not decided yet: what the pilot can still choose.
    var isOnFinal: Bool {
        switch actions.first {
        case .onFinal?, .final(nil)?: return true
        default: return false
        }
    }
    /// What the aircraft is doing, for the guided flight's folded card and its pace. (6.4.0)
    enum Activity: Equatable {
        case parked, taxiing, holding, liningUp, takeoffRoll, climbingOut, climbing, cruising, descending, joining
        case upwind, crosswind, downwind, base, final, goingAround, landing, stopped, taxiingIn, parkedEnd
    }
    private(set) var activity: Activity = .parked
    /// When `activity` began, in the flight's seconds.
    private(set) var activitySince = 0
    /// How fast it turned in its last second, degrees: a turn under way.
    private(set) var turnDegreesPerSecond = 0.0

    /// Feet above the aerodrome flown at (or to).
    var heightAboveFieldFt: Double { altitudeFt - aerodrome.elevationFt }

    /// Seconds to the route's waypoint flown to, and since the last one passed: around a turning point.
    var secondsToWaypoint: Double? {
        guard case .enRoute? = actions.first, legIndex < waypoints.count, speedKt > 1 else { return nil }
        return DryRunGeo.distance(position, waypoints[legIndex]) / (speedKt * DryRunGeo.metresPerSecondPerKnot)
    }
    var secondsSinceWaypoint: Int? {
        marks.last { $0.name.hasPrefix("wp") }.map { t - $0.t }
    }

    /// Metres to the route's waypoint `index` (its legs: 0 is the first after the departure).
    func distance(toWaypointAt index: Int) -> Double? {
        waypoints.indices.contains(index) ? DryRunGeo.distance(position, waypoints[index]) : nil
    }

    /// Where it waits for the pilot, if it does: the engine start, the holding point (or on the runway after a
    /// full stop, for the line-up), parked at the end.
    var waitingAt: Hold? {
        if case .hold(let hold)? = actions.first { return hold }
        return nil
    }

    /// Waiting for the pilot: the engine start, the line-up, after a full stop, or parked at the end.
    var isWaiting: Bool {
        switch actions.first {
        case .hold?, .afterFullStop?: return true
        default: return false
        }
    }

    // The route, when it flies one: the leg to `waypoints[legIndex]`, then the destination's circuit.
    private var waypoints: [CLLocationCoordinate2D] = []
    /// The leg flown: to `waypoints[legIndex]`, or the destination's circuit at the route's count.
    private(set) var legIndex = 0
    private var destination: DryRunAerodrome?
    private var cruiseAltitudeFt = 0.0
    private var enRoutePrevious: Double?
    private var descending = false
    /// The destination's way in, chosen as the arrival begins.
    private var wayIn: (points: [CLLocationCoordinate2D], legs: [DryRunAerodrome.Leg?])?

    // The aircraft, as it really is (feet, knots, degrees true).
    private var position: CLLocationCoordinate2D
    private var altitudeFt: Double
    private var speedKt = 0.0
    private var heading: Double

    // The GPS's errors: a bias, and noise that wanders from one second to the next (AR(1)), as a phone's.
    private var random: DryRunRandom
    private var errorAltitudeM = 0.0
    private var errorNorthM = 0.0
    private var errorEastM = 0.0
    private let altitudeBiasM = 3.5

    private var actions: [Action] = []

    init(departure: DryRunAerodrome, mission: Mission, performance: DryRunPerformance = .wt9, seed: UInt64,
         pilot: Pilot = Pilot()) {
        self.performance = performance
        self.pilot = pilot
        aerodrome = departure
        random = DryRunRandom(seed: seed)
        position = departure.apron
        altitudeFt = departure.elevationFt
        heading = (departure.runwayHeading + 90).truncatingRemainder(dividingBy: 360)
        if case .route(let points, let field, let cruise) = mission {
            waypoints = points
            destination = field
            cruiseAltitudeFt = cruise
        }
        // Parked; after ENGINE START, the taxi to the holding point, the run-up, the line-up the pilot calls.
        actions = [.hold(.engineStart), .park(45), .doing(.taxiing),
                   .goTo(.taxi(to: departure.holdingPoint, speed: performance.taxi)), .doing(.holding),
                   .park(30), .hold(.lineUp), .park(2)] + lineUpAndTakeOff()
    }

    /// A Direct To: from now on the leg to waypoint `index` (the route's count: the destination).
    func directTo(waypointAt index: Int) {
        legIndex = min(max(0, index), waypoints.count)
        enRoutePrevious = nil
        wayIn = nil
    }

    /// A divert: straight to `field`'s circuit, the rest of the route left; in the air at once, on the
    /// ground for the take-off to come.
    func divert(to field: DryRunAerodrome) {
        destination = field
        waypoints = []
        legIndex = 0
        enRoutePrevious = nil
        descending = false
        wayIn = nil
        if isAirborne { actions = [.enRoute] }
    }

    /// The route again after a divert (the Cockpit's resume), from the leg to waypoint `index`.
    func follow(route points: [CLLocationCoordinate2D], to field: DryRunAerodrome, from index: Int) {
        destination = field
        waypoints = points
        legIndex = min(max(0, index), points.count)
        enRoutePrevious = nil
        descending = false
        wayIn = nil
        if isAirborne { actions = [.enRoute] }
    }

    /// The next second of the flight.
    func nextFix() -> DryRunFix {
        // Each pass either emits the second's fix or finishes an action that took no time; a few at most.
        for _ in 0..<64 {
            if actions.isEmpty { actions = [.hold(.parked)] }
            if let fix = performFirstAction() { return fix }
        }
        speedKt = 0
        return emit()
    }

    func mark(_ name: String) -> Int? { marks.first { $0.name == name }?.t }

    // MARK: - The actions

    private struct GoTo {
        var point: CLLocationCoordinate2D
        var speed: Double
        var altitudeFt: Double?
        var verticalSpeed = 500.0
        var accel = 1.5
        var arriveM: Double?
        var turnRate = 3.0
        /// The speed while more than 50 ft below `altitudeFt` (the climb at Vy).
        var climbSpeed: Double?
        /// Taxiing: stopped where it arrives.
        var stops = false
        var previous: Double?

        static func taxi(to point: CLLocationCoordinate2D, speed: Double) -> GoTo {
            GoTo(point: point, speed: speed, accel: 1.0, arriveM: 8, turnRate: 12, stops: true)
        }
    }

    /// A line flown point after point, each turn begun before its point as a pilot begins it: the circuit as
    /// drawn, the way into it (a published arrival, or a 45° join to the downwind), a published departure.
    /// (6.4.0, the published circuit: the author's device check g-7, "it should enter the downwind and follow
    /// the pattern".)
    private struct Line {
        enum Kind: Equatable {
            case circuit
            case departure(cruiseFt: Double)
        }

        var points: [CLLocationCoordinate2D]
        /// Each segment's leg of the circuit, `points[i]` to `points[i + 1]`; nil where the line isn't the
        /// circuit (yet).
        var legs: [DryRunAerodrome.Leg?]
        var kind: Kind
        /// The height above the field the base comes down to, feet: a 3° final from where the final begins.
        var baseHeightFt: Double
        /// The point flown to, along the segment from `points[index - 1]`.
        var index = 1
        /// The leg last noted (its mark, the activity), none yet.
        var noted: DryRunAerodrome.Leg?? = .none

        static func circuit(_ points: [CLLocationCoordinate2D], legs: [DryRunAerodrome.Leg?]) -> Line {
            var finalM = 0.0
            for (i, leg) in legs.enumerated() where leg == .final {
                finalM += DryRunGeo.distance(points[i], points[i + 1])
            }
            let height = finalM * tan(3 * Double.pi / 180) / DryRunGeo.metresPerFoot
            return Line(points: points, legs: legs, kind: .circuit, baseHeightFt: min(700, max(300, height)))
        }
    }

    private enum Action {
        case hold(Hold)
        case park(Int)
        case goTo(GoTo)
        case climb(toFt: Double, speed: Double, toward: CLLocationCoordinate2D)
        /// On the runway's heading: the take-off roll to `speed`.
        case roll(toSpeed: Double)
        /// On the runway's heading, `count` seconds.
        case steps(count: Int, speed: Double, accel: Double, verticalSpeed: Double)
        /// Down the final; its end decided at 250 ft above the field (nil until then).
        case final(Landing?)
        case flare
        case brake
        case enRoute
        case afterFullStop
        // No time of their own:
        case mark(String)
        case alignWithRunway
        case afterTakeOff
        /// The circuit from its start (the runway's far end): its line flown to the final.
        case circuit
        case followLine(Line)
        case onFinal
        case afterTouchdown(Landing)
        case vacate
        /// What the aircraft does from here (`activity`).
        case doing(Activity)
    }

    private func lineUpAndTakeOff() -> [Action] {
        // Onto the runway briskly once READY FOR LINE UP is pressed: the pilot waited long enough at the holding
        // point (the author's sixth round, 17 Oct: a long wait before the take-off, at 4× or even 10×).
        [.mark("lineUp"), .goTo(.taxi(to: aerodrome.lineUpPoint, speed: 12)), .alignWithRunway, .park(3),
         .mark("takeoffRoll"), .roll(toSpeed: performance.vr + 6), .mark("liftoff"),
         .steps(count: 20, speed: performance.vy, accel: 1.2, verticalSpeed: 550), .afterTakeOff]
    }

    /// The first action's second, or nil when it took none (done, or turned into others).
    private func performFirstAction() -> DryRunFix? {
        let field = aerodrome
        switch actions[0] {
        case .hold(let hold):
            if hold != .parked, pilot.mayGo(hold) { actions.removeFirst(); return nil }
            speedKt = 0
            return emit()

        case .park(let seconds):
            guard seconds > 0 else { actions.removeFirst(); return nil }
            actions[0] = .park(seconds - 1)
            speedKt = 0
            return emit()

        case .goTo(var leg):
            let d = DryRunGeo.distance(position, leg.point)
            let arrive = leg.arriveM ?? max(15, leg.speed * DryRunGeo.metresPerSecondPerKnot * 1.2)
            // In the air a point is passed rather than hit: within 0.4 NM, and the distance opening again.
            let passing = leg.speed > 30 ? 0.4 * DryRunGeo.metresPerNM : 0
            if d <= arrive || (leg.previous.map { d < passing && d > $0 } ?? false) {
                actions.removeFirst()
                if leg.stops { speedKt = 0 }
                return nil
            }
            leg.previous = d
            actions[0] = .goTo(leg)
            var verticalSpeed = 0.0
            var speed = leg.speed
            if let target = leg.altitudeFt {
                let gap = target - altitudeFt
                // Eases into the level over the last ~80 ft.
                verticalSpeed = max(-leg.verticalSpeed, min(leg.verticalSpeed, gap * 6))
                if let climb = leg.climbSpeed, gap > 50 { speed = climb }
            }
            return step(speed: speed, accel: leg.accel, verticalSpeed: verticalSpeed,
                        heading: DryRunGeo.bearing(from: position, to: leg.point), turnRate: leg.turnRate)

        case .climb(let target, let speed, let toward):
            guard altitudeFt < target - 5 else {
                if abs(altitudeFt - target) < 5 { altitudeFt = target }
                actions.removeFirst()
                return nil
            }
            let verticalSpeed = max(150, min(700, (target - altitudeFt) * 6))
            return step(speed: speed, verticalSpeed: verticalSpeed, heading: DryRunGeo.bearing(from: position, to: toward))

        case .roll(let target):
            guard speedKt < target else { actions.removeFirst(); return nil }
            return step(speed: target, accel: 2.4, heading: field.runwayHeading)

        case .steps(let count, let speed, let accel, let verticalSpeed):
            guard count > 0 else { actions.removeFirst(); return nil }
            actions[0] = .steps(count: count - 1, speed: speed, accel: accel, verticalSpeed: verticalSpeed)
            return step(speed: speed, accel: accel, verticalSpeed: verticalSpeed, heading: field.runwayHeading)

        case .final(let decided):
            // Final at ~3°: down to the touchdown point. At 250 ft above the field the pilot's choice is
            // taken: a go-around climbs away from there.
            let touchdown = field.touchdownPoint
            let d = DryRunGeo.distance(position, touchdown)
            let height = max(0, altitudeFt - field.elevationFt)
            if decided == nil, height <= 250 || d <= 40 {
                let landing = pilot.landing(field)
                actions.removeFirst()
                if landing == .goAround {
                    actions.insert(contentsOf: [.mark("goAround"),
                                              .steps(count: 25, speed: performance.vy, accel: 1.5, verticalSpeed: 650),
                                              .circuit], at: 0)
                } else {
                    actions.insert(.final(landing), at: 0)
                }
                return nil
            }
            guard d > 40 else {
                actions.removeFirst()
                actions.insert(contentsOf: [.flare, .mark("touchdown"), .afterTouchdown(decided ?? .fullStop)], at: 0)
                return nil
            }
            // Down to the touchdown point whatever height the final began at: a final begun high (a route's
            // arrival) still passes 250 ft before the runway, so a go-around climbs away from where the app
            // sees one (the author's fifth round, a-2: the first go-around at a route's end went unseen).
            let groundSpeed = max(speedKt * DryRunGeo.metresPerSecondPerKnot, 1)
            let verticalSpeed = -min(900, max(120, height / max(d / groundSpeed, 1) * 60))
            return step(speed: performance.finalApproach, accel: 0.8, verticalSpeed: verticalSpeed,
                        heading: DryRunGeo.bearing(from: position, to: touchdown))

        case .flare:
            set(.landing)
            guard altitudeFt > field.elevationFt + 0.5 else {
                altitudeFt = field.elevationFt
                actions.removeFirst()
                return nil
            }
            return step(speed: performance.touchdown, verticalSpeed: -max(60, (altitudeFt - field.elevationFt) * 20),
                        heading: field.runwayHeading)

        case .brake:
            guard speedKt > 0.5 else { speedKt = 0; actions.removeFirst(); return nil }
            return step(speed: 0, accel: 3, heading: field.runwayHeading)

        case .enRoute:
            return flyEnRoute()

        case .afterFullStop:
            guard let answer = pilot.afterFullStop(field) else { speedKt = 0; return emit() }
            actions.removeFirst()
            switch answer {
            case .goAgain:
                // A stop-and-go: the checks to the line-up done again on the runway, then the roll from there.
                actions.insert(contentsOf: [.hold(.lineUp), .mark("takeoffRoll"), .roll(toSpeed: performance.vr + 6),
                                          .mark("liftoff"),
                                          .steps(count: 20, speed: performance.vy, accel: 1.2, verticalSpeed: 550),
                                          .circuit], at: 0)
            case .vacate:
                actions.insert(.vacate, at: 0)
            }
            return nil

        case .mark(let name):
            marks.append((name, t))
            if let doing = Self.activity(at: name) { set(doing) }
            if name == "liftoff" { isAirborne = true }
            if name == "touchdown" { isAirborne = false }
            actions.removeFirst()
            return nil

        case .doing(let doing):
            set(doing)
            actions.removeFirst()
            return nil

        case .alignWithRunway:
            heading = field.runwayHeading
            actions.removeFirst()
            return nil

        case .afterTakeOff:
            actions.removeFirst()
            if destination == nil {
                // Circuits: on along the circuit's upwind, climbing to its altitude; the turn onto the crosswind
                // begins about 500 ft above the field, where the upwind ends.
                actions.insert(.circuit, at: 0)
            } else {
                // A route: straight on to 800 ft above the field, then the published departure toward the
                // route's first point if there is one, then the legs, climbing to the cruise.
                var next: [Action] = [.climb(toFt: field.elevationFt + 800, speed: performance.vy,
                                             toward: field.point(along: field.runwayLengthM / 2 + 1.5 * DryRunGeo.metresPerNM))]
                if let first = waypoints.first ?? destination?.reference,
                   let departure = field.departure(toward: DryRunGeo.bearing(from: field.reference, to: first)),
                   departure.line.count >= 2 {
                    next.append(.followLine(Line(points: departure.line,
                                                 legs: Array(repeating: nil, count: departure.line.count - 1),
                                                 kind: .departure(cruiseFt: cruiseAltitudeFt), baseHeightFt: 0)))
                }
                next.append(.enRoute)
                actions.insert(contentsOf: next, at: 0)
            }
            return nil

        case .circuit:
            actions.removeFirst()
            actions.insert(.followLine(.circuit(field.circuitLine, legs: field.circuitLegs.map(Optional.some))), at: 0)
            return nil

        case .followLine(var line):
            return followLine(&line, field: field)

        case .onFinal:
            actions.removeFirst()
            actions.insert(.final(nil), at: 0)
            return nil

        case .afterTouchdown(let landing):
            actions.removeFirst()
            if landing == .touchAndGo {
                // On the wheels a few seconds, flaps up, power, and away.
                actions.insert(contentsOf: [.mark("touchAndGo"), .steps(count: 12, speed: performance.vr + 2, accel: 1.2, verticalSpeed: 0),
                                          .roll(toSpeed: performance.vr + 8), .mark("liftoff"),
                                          .steps(count: 20, speed: performance.vy, accel: 1.2, verticalSpeed: 550),
                                          .circuit], at: 0)
            } else {
                actions.insert(contentsOf: [.brake, .mark("stopped"), .afterFullStop], at: 0)
            }
            return nil

        case .vacate:
            actions.removeFirst()
            // Off the runway beside where it stopped, then to the apron.
            let centre = field.runwayCentre
            let along = DryRunGeo.distance(centre, position)
                * (abs(DryRunGeo.angleDifference(from: field.runwayHeading, to: DryRunGeo.bearing(from: centre, to: position))) < 90 ? 1 : -1)
            let exit = field.point(along: along, right: -field.circuitSide.sign * 60)
            actions.insert(contentsOf: [.doing(.taxiingIn), .goTo(.taxi(to: exit, speed: 8)), .mark("vacated"),
                                      .goTo(.taxi(to: field.apron, speed: performance.taxi)), .mark("parked"),
                                      .hold(.parked)], at: 0)
            return nil
        }
    }

    /// The legs at the cruise, then the destination's way in (its published arrival, or a 45° join to its
    /// downwind) and its circuit: down to its altitude from 9 NM before the way in, so the descent comes well
    /// before the approach.
    private func flyEnRoute() -> DryRunFix? {
        guard let field = destination else { actions.removeFirst(); return nil }
        let arriving = legIndex >= waypoints.count
        // The way in, chosen as the arrival begins: the published arrival from the side it comes from.
        if arriving, wayIn == nil { wayIn = field.wayIn(from: position) }
        let target = arriving ? wayIn?.points.first ?? field.downwindStart : waypoints[legIndex]
        let d = DryRunGeo.distance(position, target)
        // The descent begins 9 NM before the way in. From a cruise far too high to lose after the last
        // waypoint (half as much again as 550 ft a minute loses there), it begins on the last leg, where 500 ft
        // a minute gets it down, so the circuit is joined at its altitude (a-2).
        let mps = performance.descent * DryRunGeo.metresPerSecondPerKnot
        let toLoseFt = max(0, altitudeFt - field.patternAltitudeFt)
        let descentNeedsM = toLoseFt / 500 * 60 * mps + 2 * DryRunGeo.metresPerNM
        let afterLastM = DryRunGeo.distance(target, field.reference)
        let tooHigh = !arriving && legIndex == waypoints.count - 1
            && toLoseFt > 1.5 * (afterLastM / mps / 60 * 550) && d + afterLastM <= descentNeedsM
        if (arriving && d <= max(9 * DryRunGeo.metresPerNM, descentNeedsM)) || tooHigh, !descending {
            descending = true
            marks.append(("topOfDescent", t))
        }
        let speed = descending ? performance.descent : performance.cruise
        let altitude = descending ? field.patternAltitudeFt : cruiseAltitudeFt
        let arrive = max(15, speed * DryRunGeo.metresPerSecondPerKnot * 1.2)
        if d <= arrive || (enRoutePrevious.map { d < 0.4 * DryRunGeo.metresPerNM && d > $0 } ?? false) {
            enRoutePrevious = nil
            if arriving {
                actions.removeFirst()
                aerodrome = field
                destination = nil
                descending = false
                if let way = wayIn {
                    actions.insert(.followLine(.circuit(way.points, legs: way.legs)), at: 0)
                } else {
                    actions.insert(.circuit, at: 0)
                }
                wayIn = nil
            } else {
                legIndex += 1
                marks.append(("wp\(legIndex)", t))
            }
            return nil
        }
        enRoutePrevious = d
        let gap = altitude - altitudeFt
        set(descending ? .descending : gap > 50 ? .climbing : .cruising)
        let maxVerticalSpeed = descending ? 550.0 : 700.0
        let verticalSpeed = max(-maxVerticalSpeed, min(maxVerticalSpeed, gap * 6))
        return step(speed: !descending && gap > 50 ? performance.vy : speed, verticalSpeed: verticalSpeed,
                    heading: DryRunGeo.bearing(from: position, to: target))
    }

    /// A second along `line`, steered as a pilot follows a line on a chart: toward the point a turn's radius
    /// ahead along it (pure pursuit), so each turn begins before its corner, however the corner is drawn (open
    /// flightmaps draws most with two points). The segment it is on is the first whose end it hasn't passed;
    /// the final is handed to the final's own action.
    private func followLine(_ line: inout Line, field: DryRunAerodrome) -> DryRunFix? {
        while line.index < line.points.count,
              Self.fraction(of: position, along: line.points[line.index - 1], line.points[line.index]) >= 1 {
            line.index += 1
        }
        guard line.index < line.points.count else {
            actions.removeFirst()
            return nil
        }
        let leg = line.legs[line.index - 1]
        if leg == .final, line.kind == .circuit {
            // The final is the final's own: down to the runway, the pilot's choice at 250 ft.
            actions.removeFirst()
            actions.insert(contentsOf: [.mark("final"), .onFinal], at: 0)
            return nil
        }
        if line.noted != .some(leg) {
            line.noted = .some(leg)
            switch leg {
            case nil: set(line.kind == .circuit ? .joining : .climbing)
            case .upwind?: set(.upwind)
            case .crosswind?: set(.crosswind)
            case .downwind?:
                marks.append(("downwind", t))
                set(.downwind)
            case .base?:
                marks.append(("base", t))
                set(.base)
            case .final?: break
            }
        }
        actions[0] = .followLine(line)
        // A circuit's turns at a circuit's bank (25 to 30°, about 4.5° a second at its speeds); a departure's
        // at rate one. The turn's radius at that rate and the speed flown.
        let turnRate = line.kind == .circuit ? 4.5 : 3
        let radius = max(speedKt, 40) * DryRunGeo.metresPerSecondPerKnot / (turnRate * Double.pi / 180)
        let target = Self.point(ahead: max(250, 0.8 * radius), of: position, on: line.points, from: line.index)
        let pattern = field.patternAltitudeFt
        var speed = performance.downwind
        var altitude = pattern
        var maxVerticalSpeed = 650.0
        switch line.kind {
        case .departure(let cruise):
            speed = performance.vy
            altitude = cruise
            maxVerticalSpeed = 700
        case .circuit:
            switch leg {
            case nil: maxVerticalSpeed = 550
            case .upwind?, .crosswind?: if altitudeFt < pattern - 50 { speed = performance.vy }
            case .downwind?: break
            case .base?, .final?:
                speed = performance.base
                altitude = field.elevationFt + line.baseHeightFt
                maxVerticalSpeed = 700
            }
        }
        let verticalSpeed = max(-maxVerticalSpeed, min(maxVerticalSpeed, (altitude - altitudeFt) * 6))
        return step(speed: speed, verticalSpeed: verticalSpeed, heading: DryRunGeo.bearing(from: position, to: target),
                    turnRate: turnRate)
    }

    /// How far along `a`→`b` `point` is abeam: 0 at `a`, 1 at `b` (a local flat projection, plenty within a
    /// circuit).
    private static func fraction(of point: CLLocationCoordinate2D, along a: CLLocationCoordinate2D,
                                 _ b: CLLocationCoordinate2D) -> Double {
        let k = cos(a.latitude * .pi / 180)
        let bx = (b.longitude - a.longitude) * k, by = b.latitude - a.latitude
        let px = (point.longitude - a.longitude) * k, py = point.latitude - a.latitude
        let length = bx * bx + by * by
        return length > 0 ? (px * bx + py * by) / length : 1
    }

    /// The point `distance` metres along `points` beyond where `position` is abeam on the segment ending at
    /// `points[index]`; the line's end when it is nearer.
    private static func point(ahead distance: Double, of position: CLLocationCoordinate2D,
                              on points: [CLLocationCoordinate2D], from index: Int) -> CLLocationCoordinate2D {
        let a = points[index - 1], b = points[index]
        let t = max(0, min(1, fraction(of: position, along: a, b)))
        var from = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                          longitude: a.longitude + (b.longitude - a.longitude) * t)
        var remaining = distance
        for next in points[index...] {
            let d = DryRunGeo.distance(from, next)
            if d >= remaining { return DryRunGeo.destination(from: from, bearing: DryRunGeo.bearing(from: from, to: next), distance: remaining) }
            remaining -= d
            from = next
        }
        return points[points.count - 1]
    }

    private func set(_ doing: Activity) {
        guard doing != activity else { return }
        activity = doing
        activitySince = t
    }

    /// What a mark starts.
    private static func activity(at mark: String) -> Activity? {
        switch mark {
        case "lineUp": return .liningUp
        case "takeoffRoll": return .takeoffRoll
        case "liftoff": return .climbingOut
        case "downwind": return .downwind
        case "base": return .base
        case "final": return .final
        case "goAround": return .goingAround
        case "touchdown": return .landing
        case "stopped": return .stopped
        case "parked": return .parkedEnd
        default: return nil
        }
    }

    // MARK: - One second

    private func step(speed target: Double, accel: Double = 1.5, verticalSpeed: Double = 0,
                      heading targetHeading: Double? = nil, turnRate: Double = 3) -> DryRunFix {
        if let targetHeading {
            let turn = max(-turnRate, min(turnRate, DryRunGeo.angleDifference(from: heading, to: targetHeading)))
            heading = (heading + turn + 360).truncatingRemainder(dividingBy: 360)
            turnDegreesPerSecond = abs(turn)
        } else {
            turnDegreesPerSecond = 0
        }
        speedKt = speedKt < target ? min(target, speedKt + accel) : max(target, speedKt - accel)
        altitudeFt += verticalSpeed / 60
        position = DryRunGeo.destination(from: position, bearing: heading,
                                         distance: speedKt * DryRunGeo.metresPerSecondPerKnot)
        return emit()
    }

    /// The second's fix: where the aircraft is, as a GPS would put it.
    private func emit() -> DryRunFix {
        // On the ground the altitude holds still: its wander read as the aircraft bobbing before the take-off
        // (the author's checks, 17 Oct). The draw is still made, so a seed flies the same track as before.
        let altitudeDrift = random.gaussian(0.6)
        errorAltitudeM = isAirborne ? 0.92 * errorAltitudeM + altitudeDrift : 0
        errorNorthM = 0.9 * errorNorthM + random.gaussian(0.45)
        errorEastM = 0.9 * errorEastM + random.gaussian(0.45)
        let reported = DryRunGeo.destination(from: DryRunGeo.destination(from: position, bearing: 0, distance: errorNorthM),
                                             bearing: 90, distance: errorEastM)
        let speed = speedKt > 0.3
            ? max(0, speedKt * DryRunGeo.metresPerSecondPerKnot + random.gaussian(0.15))
            : (abs(random.gaussian(0.05)) * 100).rounded() / 100
        let accuracy = ((3.5 + abs(random.gaussian(0.8)) + (speedKt < 1 ? 1.5 : 0)) * 10).rounded() / 10
        let fix = DryRunFix(t: t, latitude: reported.latitude, longitude: reported.longitude,
                            altitudeM: altitudeFt * DryRunGeo.metresPerFoot + altitudeBiasM + errorAltitudeM,
                            speedMS: speed, horizontalAccuracyM: accuracy,
                            course: speedKt >= 2 ? (heading * 10).rounded() / 10 : -1)
        t += 1
        return fix
    }
}

/// A seeded generator (SplitMix64) with normal draws (Box-Muller): the same seed flies the same flight.
struct DryRunRandom {
    private var state: UInt64
    private var spare: Double?

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// In [0, 1).
    mutating func uniform() -> Double { Double(next() >> 11) * 0x1.0p-53 }

    mutating func gaussian(_ sigma: Double) -> Double {
        if let spare {
            self.spare = nil
            return spare * sigma
        }
        var u = uniform()
        while u <= .ulpOfOne { u = uniform() }
        let r = (-2 * log(u)).squareRoot()
        let angle = 2 * Double.pi * uniform()
        spare = r * sin(angle)
        return r * cos(angle) * sigma
    }
}
