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
        /// What the aircraft does at the end of this final: asked once, at the start of the final.
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

    // The route, when it flies one: the leg to `waypoints[legIndex]`, then the destination's circuit.
    private var waypoints: [CLLocationCoordinate2D] = []
    private var legIndex = 0
    private var destination: DryRunAerodrome?
    private var cruiseAltitudeFt = 0.0
    private var enRoutePrevious: Double?
    private var descending = false

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
        actions = [.hold(.engineStart), .park(45), .goTo(.taxi(to: departure.holdingPoint, speed: performance.taxi)),
                 .park(30), .hold(.lineUp), .park(20)] + lineUpAndTakeOff()
    }

    /// A Direct To: from now on the leg to waypoint `index` (the route's count: the destination).
    func directTo(waypointAt index: Int) {
        legIndex = min(max(0, index), waypoints.count)
        enRoutePrevious = nil
    }

    /// A divert: straight to `field`'s circuit, the rest of the route left; in the air at once, on the
    /// ground for the take-off to come.
    func divert(to field: DryRunAerodrome) {
        destination = field
        waypoints = []
        legIndex = 0
        enRoutePrevious = nil
        descending = false
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

    private enum Action {
        case hold(Hold)
        case park(Int)
        case goTo(GoTo)
        case climb(toFt: Double, speed: Double, toward: CLLocationCoordinate2D)
        /// On the runway's heading: the take-off roll to `speed`.
        case roll(toSpeed: Double)
        /// On the runway's heading, `count` seconds.
        case steps(count: Int, speed: Double, accel: Double, verticalSpeed: Double)
        case final(goAround: Bool)
        case flare
        case brake
        case enRoute
        case afterFullStop
        // No time of their own:
        case mark(String)
        case alignWithRunway
        case afterTakeOff
        case circuit(upwind: Bool)
        case onFinal
        case afterTouchdown(Landing)
        case vacate
    }

    private func lineUpAndTakeOff() -> [Action] {
        [.mark("lineUp"), .goTo(.taxi(to: aerodrome.lineUpPoint, speed: 6)), .alignWithRunway, .park(8),
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

        case .final(let goAround):
            // Final at ~3°: down to the touchdown point; a go-around climbs away from 250 ft above the field.
            let touchdown = field.touchdownPoint
            let d = DryRunGeo.distance(position, touchdown)
            let height = max(0, altitudeFt - field.elevationFt)
            if goAround, height <= 250 || d <= 40 {
                actions.removeFirst()
                actions.insert(contentsOf: [.mark("goAround"),
                                          .steps(count: 25, speed: performance.vy, accel: 1.5, verticalSpeed: 650),
                                          .circuit(upwind: true)], at: 0)
                return nil
            }
            guard d > 40 else { actions.removeFirst(); return nil }
            let groundSpeed = max(speedKt * DryRunGeo.metresPerSecondPerKnot, 1)
            let verticalSpeed = -min(420, max(120, height / max(d / groundSpeed, 1) * 60))
            return step(speed: performance.finalApproach, accel: 0.8, verticalSpeed: verticalSpeed,
                        heading: DryRunGeo.bearing(from: position, to: touchdown))

        case .flare:
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
                                          .circuit(upwind: true)], at: 0)
            case .vacate:
                actions.insert(.vacate, at: 0)
            }
            return nil

        case .mark(let name):
            marks.append((name, t))
            if name == "liftoff" { isAirborne = true }
            if name == "touchdown" { isAirborne = false }
            actions.removeFirst()
            return nil

        case .alignWithRunway:
            heading = field.runwayHeading
            actions.removeFirst()
            return nil

        case .afterTakeOff:
            actions.removeFirst()
            if destination == nil {
                // Circuits: straight on to 500 ft above the field, then the crosswind.
                actions.insert(contentsOf: [.climb(toFt: field.elevationFt + 500, speed: performance.vy,
                                                 toward: field.point(along: field.runwayLengthM / 2 + 2 * DryRunGeo.metresPerNM)),
                                          .mark("levelOff"), .circuit(upwind: true)], at: 0)
            } else {
                // A route: straight on to 800 ft above the field, then the legs, climbing to the cruise.
                actions.insert(contentsOf: [.climb(toFt: field.elevationFt + 800, speed: performance.vy,
                                                 toward: field.point(along: field.runwayLengthM / 2 + 1.5 * DryRunGeo.metresPerNM)),
                                          .enRoute], at: 0)
            }
            return nil

        case .circuit(let upwind):
            actions.removeFirst()
            let pattern = field.patternAltitudeFt
            var legs: [Action] = []
            if upwind {
                legs.append(.goTo(GoTo(point: field.crosswindPoint, speed: performance.vy, altitudeFt: pattern,
                                       verticalSpeed: 650)))
            }
            legs += [.goTo(GoTo(point: field.downwindStart, speed: performance.downwind, altitudeFt: pattern,
                                verticalSpeed: 650)),
                     .mark("downwind"),
                     .goTo(GoTo(point: field.downwindEnd, speed: performance.downwind, altitudeFt: pattern)),
                     .goTo(GoTo(point: field.basePoint, speed: performance.base, altitudeFt: field.elevationFt + 650)),
                     .mark("base"),
                     .goTo(GoTo(point: field.finalPoint, speed: performance.finalApproach, altitudeFt: field.elevationFt + 450)),
                     .mark("final"), .onFinal]
            actions.insert(contentsOf: legs, at: 0)
            return nil

        case .onFinal:
            actions.removeFirst()
            let landing = pilot.landing(field)
            if landing == .goAround {
                actions.insert(.final(goAround: true), at: 0)
            } else {
                actions.insert(contentsOf: [.final(goAround: false), .flare, .mark("touchdown"), .afterTouchdown(landing)], at: 0)
            }
            return nil

        case .afterTouchdown(let landing):
            actions.removeFirst()
            if landing == .touchAndGo {
                // On the wheels a few seconds, flaps up, power, and away.
                actions.insert(contentsOf: [.steps(count: 12, speed: performance.vr + 2, accel: 1.2, verticalSpeed: 0),
                                          .roll(toSpeed: performance.vr + 8), .mark("liftoff"),
                                          .steps(count: 20, speed: performance.vy, accel: 1.2, verticalSpeed: 550),
                                          .circuit(upwind: true)], at: 0)
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
            actions.insert(contentsOf: [.goTo(.taxi(to: exit, speed: 8)), .mark("vacated"),
                                      .goTo(.taxi(to: field.apron, speed: performance.taxi)), .mark("parked"),
                                      .hold(.parked)], at: 0)
            return nil
        }
    }

    /// The legs at the cruise, then the destination's circuit, joined at the start of its downwind: down to
    /// its altitude from 9 NM out, so the descent comes well before the approach.
    private func flyEnRoute() -> DryRunFix? {
        guard let field = destination else { actions.removeFirst(); return nil }
        let arriving = legIndex >= waypoints.count
        let target = arriving ? field.downwindStart : waypoints[legIndex]
        let d = DryRunGeo.distance(position, target)
        if arriving, d <= 9 * DryRunGeo.metresPerNM, !descending {
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
                actions.insert(.circuit(upwind: false), at: 0)
            } else {
                legIndex += 1
                marks.append(("wp\(legIndex)", t))
            }
            return nil
        }
        enRoutePrevious = d
        let gap = altitude - altitudeFt
        let maxVerticalSpeed = descending ? 550.0 : 700.0
        let verticalSpeed = max(-maxVerticalSpeed, min(maxVerticalSpeed, gap * 6))
        return step(speed: !descending && gap > 50 ? performance.vy : speed, verticalSpeed: verticalSpeed,
                    heading: DryRunGeo.bearing(from: position, to: target))
    }

    // MARK: - One second

    private func step(speed target: Double, accel: Double = 1.5, verticalSpeed: Double = 0,
                      heading targetHeading: Double? = nil, turnRate: Double = 3) -> DryRunFix {
        if let targetHeading {
            let turn = DryRunGeo.angleDifference(from: heading, to: targetHeading)
            heading = (heading + max(-turnRate, min(turnRate, turn)) + 360).truncatingRemainder(dividingBy: 360)
        }
        speedKt = speedKt < target ? min(target, speedKt + accel) : max(target, speedKt - accel)
        altitudeFt += verticalSpeed / 60
        position = DryRunGeo.destination(from: position, bearing: heading,
                                         distance: speedKt * DryRunGeo.metresPerSecondPerKnot)
        return emit()
    }

    /// The second's fix: where the aircraft is, as a GPS would put it.
    private func emit() -> DryRunFix {
        errorAltitudeM = 0.92 * errorAltitudeM + random.gaussian(0.6)
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
