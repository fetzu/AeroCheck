import Foundation
import CoreLocation

// MARK: - Times from the track (v5.2)
//
// The times a logbook and a club invoice are built from — block off, take-off, block on — measured
// from the recorded GPS track once the flight is over, with hindsight the live detection does not
// have. PURE: a track and two checklist timestamps in, times out.
//
// Why not the live values. Measured against six real flights (LSZQ, LSZG, LSZS, LSZE, LSPV,
// September 2026):
// - Take-off was the checklist's Line Up tap plus a fixed 2 minutes: off by −8 s to +2 min 10 s.
// - Block off needed two samples at ≥ 4 kt, but aircraft leave parking at walking pace (2–4 kt,
//   10–13 m per sample): 5–21 s late, enough to change the logged minute.
// - Block on took the first stop of ≥ 2 samples below 4 kt: the after-landing stop at the runway
//   exit (2 min 9 s early on one flight), or the slow roll into the parking spot.
//
// What the track looks like. The tracker records a fix every ~6 s while the aircraft moves and NOTHING
// while it stands still (a 5 m distance filter). So a parked aircraft is an absence of fixes, a fix
// is itself evidence of movement, and the first and last fixes of a flight are where it left and
// reached its parking spot.

enum TrackTimes {

    struct Result: Equatable {
        var blockOff: Date?
        var blockOffCoordinate: CLLocationCoordinate2D?
        var takeoff: Date?
        var blockOn: Date?
        var blockOnCoordinate: CLLocationCoordinate2D?

        static func == (a: Result, b: Result) -> Bool {
            a.blockOff == b.blockOff && a.takeoff == b.takeoff && a.blockOn == b.blockOn
        }
    }

    /// Moving: ~1.5 kt. Taxiing out of and into a parking spot happens at walking pace, which the
    /// live detection's 4 kt called standing still.
    static let movingSpeed = 0.75
    /// Fixes further apart than this are not one continuous movement: the aircraft stood still in
    /// between (run-up, holding point, a stop after landing).
    static let maxGap: TimeInterval = 20
    /// Positions this accurate can show movement by displacement when the Doppler speed reads low.
    static let displacementAccuracy = 10.0
    /// The first movement that counts as leaving the parking spot: taxi speed, or 20 m covered.
    static let leavingSpeedKt = 5.0
    static let leavingDistance = 20.0
    /// The engine checklist is tapped by hand, a little before or after the fact.
    static let checklistTolerance: TimeInterval = 60
    /// A take-off roll: faster than this…
    static let rollSpeedKt = 25.0
    /// …climbing this far above the runway within 90 s of the roll's start.
    static let climbAwayFt = 100.0
    /// Airborne: this far above the runway…
    static let airborneFt = 25.0
    /// …with the liftoff placed where the climb crosses this height, interpolated between fixes.
    static let liftoffFt = 10.0

    /// - Parameters:
    ///   - engineStart, engineShutdown: the checklist taps. Movement before engine start (pushed out
    ///     of the hangar) and after shutdown (pushed back in) is not block time.
    ///   - rotateKt: the aircraft's Vr; a roll that never reaches it is not a take-off.
    static func analyze(track: [GPSPoint], engineStart: Date?, engineShutdown: Date?,
                        rotateKt: Double = 45) -> Result {
        let fixes = track
            .filter { point in
                if let engineStart, point.timestamp < engineStart.addingTimeInterval(-checklistTolerance) { return false }
                if let engineShutdown, point.timestamp > engineShutdown.addingTimeInterval(checklistTolerance) { return false }
                return true
            }
            .sorted { $0.timestamp < $1.timestamp }
        guard fixes.count >= 2 else { return Result() }

        var result = Result()
        let runs = movementRuns(fixes)

        // Block off: the first movement that leaves the parking spot.
        if let leaving = runs.first(where: { run in
            maxSpeedKt(fixes, run) >= leavingSpeedKt || pathLength(fixes, run) >= leavingDistance
        }) {
            result.blockOff = fixes[leaving.lowerBound].timestamp
            result.blockOffCoordinate = coordinate(fixes[leaving.lowerBound])
        }

        // Block on: where the last movement ended. The fix after it, when there is one close by, is
        // the aircraft seen standing; otherwise the last fix is (it moved less than 5 m after it).
        if let last = runs.last {
            let end = last.upperBound
            let stop = end + 1 < fixes.count
                && fixes[end + 1].timestamp.timeIntervalSince(fixes[end].timestamp) <= maxGap ? end + 1 : end
            result.blockOn = fixes[stop].timestamp
            result.blockOnCoordinate = coordinate(fixes[stop])
        }

        result.takeoff = takeoff(in: fixes, rotateKt: rotateKt)
        return result
    }

    // MARK: Take-off

    /// The first liftoff: a roll through `rollSpeedKt` that reaches Vr and climbs away, with the
    /// liftoff where the altitude leaves the runway. Barometric altitude when the device recorded
    /// it (±1 ft), GPS otherwise.
    static func takeoff(in fixes: [GPSPoint], rotateKt: Double) -> Date? {
        let useBaro = fixes.allSatisfy { $0.baroAltitude != nil }
        func altitudeFt(_ point: GPSPoint) -> Double { (useBaro ? point.baroAltitude! : point.altitude) / 0.3048 }

        for i in fixes.indices where knots(fixes[i].speed) > rollSpeedKt {
            let window = fixes[i...].prefix { $0.timestamp.timeIntervalSince(fixes[i].timestamp) <= 90 }
            let groundSamples = fixes[max(0, i - 2)...i].map(altitudeFt).sorted()
            let runway = groundSamples[groundSamples.count / 2]
            guard window.contains(where: { knots($0.speed) >= rotateKt }),
                  window.contains(where: { altitudeFt($0) - runway >= climbAwayFt })
            else { continue }
            for k in (i + 1)..<fixes.count where altitudeFt(fixes[k]) - runway >= airborneFt {
                let before = altitudeFt(fixes[k - 1]), after = altitudeFt(fixes[k])
                let target = runway + liftoffFt
                guard before < target, after > before else { return fixes[k - 1].timestamp }
                let fraction = (target - before) / (after - before)
                let span = fixes[k].timestamp.timeIntervalSince(fixes[k - 1].timestamp)
                return fixes[k - 1].timestamp.addingTimeInterval(fraction * span)
            }
            return nil
        }
        return nil
    }

    // MARK: Movement

    /// Runs of consecutive moving fixes (at least two), no further apart than `maxGap`.
    static func movementRuns(_ fixes: [GPSPoint]) -> [ClosedRange<Int>] {
        var moving = [Bool](repeating: false, count: fixes.count)
        for i in fixes.indices {
            if fixes[i].speed >= movingSpeed { moving[i] = true; continue }
            // A low Doppler speed with a real displacement is still movement.
            guard i > 0, (fixes[i].horizontalAccuracy ?? .infinity) <= displacementAccuracy else { continue }
            let dt = fixes[i].timestamp.timeIntervalSince(fixes[i - 1].timestamp)
            if dt > 0, dt <= maxGap, distance(fixes[i - 1], fixes[i]) / dt >= movingSpeed { moving[i] = true }
        }
        var runs: [ClosedRange<Int>] = []
        var i = 0
        while i < fixes.count {
            guard moving[i] else { i += 1; continue }
            var j = i
            while j + 1 < fixes.count, moving[j + 1],
                  fixes[j + 1].timestamp.timeIntervalSince(fixes[j].timestamp) <= maxGap { j += 1 }
            if j > i { runs.append(i...j) }
            i = j + 1
        }
        return runs
    }

    private static func maxSpeedKt(_ fixes: [GPSPoint], _ run: ClosedRange<Int>) -> Double {
        knots(fixes[run].map(\.speed).max() ?? 0)
    }

    private static func pathLength(_ fixes: [GPSPoint], _ run: ClosedRange<Int>) -> Double {
        zip(fixes[run], fixes[run].dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    private static func distance(_ a: GPSPoint, _ b: GPSPoint) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private static func coordinate(_ point: GPSPoint) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }

    private static func knots(_ metresPerSecond: Double) -> Double { max(0, metresPerSecond) * 1.94384 }
}
