import Foundation
import CoreLocation

// MARK: - Times from the track (v5.2)
//
// The times a logbook and a club invoice are built from — block off, take-off, landing, block on —
// measured from the recorded GPS track once the flight is over, with hindsight the live detection
// does not have. PURE: a track and two checklist timestamps in, times out.
//
// Why not the live values. Measured against six real flights (LSZQ, LSZG, LSZS, LSZE, LSPV,
// September 2026):
// - Take-off was the checklist's Line Up tap plus a fixed 2 minutes: off by −8 s to +2 min 10 s.
// - Block off needed two samples at ≥ 4 kt, but aircraft leave parking at walking pace (2–4 kt,
//   10–13 m per sample): 5–21 s late, enough to change the logged minute.
// - Block on took the first stop of ≥ 2 samples below 4 kt: the after-landing stop at the runway
//   exit (2 min 9 s early on one flight), or the slow roll into the parking spot.
// - Landing was the event detector's first fix on the runway: the touchdown happened in the 6 s
//   before it, which moved the logged minute on two of the six flights.
//
// What the track looks like. The tracker records a fix every ~6 s while the aircraft moves and NOTHING
// while it stands still (a 5 m distance filter). So a parked aircraft is an absence of fixes, a fix
// is itself evidence of movement, and the first and last fixes of a flight are where it left and
// reached its parking spot.
//
// Altitude is GPS, not the barometer. On the same flights the cabin barometer lags by 2–3 s and reads
// high with airspeed (+8–10 ft at 48 kt on the runway): at the first fix on the runway after
// touchdown it still read +28 ft, which put its landings 4–12 s late. GPS altitude is noisier
// (±5 ft), which the median runway level and the two-fix confirmations below absorb.

enum TrackTimes {

    struct Result: Equatable {
        var blockOff: Date?
        var blockOffCoordinate: CLLocationCoordinate2D?
        var takeoff: Date?
        var landing: Date?
        var blockOn: Date?
        var blockOnCoordinate: CLLocationCoordinate2D?

        static func == (a: Result, b: Result) -> Bool {
            a.blockOff == b.blockOff && a.takeoff == b.takeoff && a.landing == b.landing && a.blockOn == b.blockOn
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
    /// Down on the runway: within GPS noise of its level. Lower than `liftoffFt` because a landing
    /// ends in a flare, a few seconds spent a few feet above the runway.
    static let touchdownFt = 5.0

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
        result.landing = landing(in: fixes, rotateKt: rotateKt)
        return result
    }

    // MARK: Take-off and landing

    /// The first liftoff: a roll through `rollSpeedKt` that reaches Vr and climbs away, with the
    /// liftoff where the altitude leaves the runway.
    static func takeoff(in fixes: [GPSPoint], rotateKt: Double) -> Date? {
        for i in fixes.indices where knots(fixes[i].speed) > rollSpeedKt {
            let window = fixes[i...].prefix { $0.timestamp.timeIntervalSince(fixes[i].timestamp) <= 90 }
            let runway = median(fixes[max(0, i - 2)...i].map(altitudeFt))
            guard window.contains(where: { knots($0.speed) >= rotateKt }),
                  window.contains(where: { altitudeFt($0) - runway >= climbAwayFt })
            else { continue }
            // Airborne, and still airborne at the next fix: one GPS jump on the roll is not a liftoff.
            guard let up = ((i + 1)..<fixes.count).first(where: { k in
                altitudeFt(fixes[k]) - runway >= airborneFt
                    && (k + 1 == fixes.count || altitudeFt(fixes[k + 1]) - runway >= airborneFt)
            }) else { return nil }
            // The liftoff is where the climb passed `liftoffFt`, which may be a fix or two earlier.
            var k = up
            while k - 1 > i, altitudeFt(fixes[k - 1]) - runway >= liftoffFt { k -= 1 }
            return crossing(fixes[k - 1], fixes[k], altitudeFt: runway + liftoffFt)
        }
        return nil
    }

    /// The final touchdown: after the last fix flying at Vr or faster, where the altitude came down
    /// to the runway the aircraft then rolled out on. Fixes are ~6 s apart on final; the touchdown is
    /// placed inside that interval instead of at its end, where the live detector stamps it.
    static func landing(in fixes: [GPSPoint], rotateKt: Double) -> Date? {
        // The final roll-out ends with the last fix faster than a take-off roll; the last fix at Vr or
        // faster before it is in the air or just down.
        guard let rollOut = fixes.lastIndex(where: { knots($0.speed) > rollSpeedKt }),
              let lastFast = fixes[...rollOut].lastIndex(where: { knots($0.speed) >= rotateKt })
        else { return nil }
        let rolling = fixes[(lastFast + 1)...].prefix(3)
        guard !rolling.isEmpty else { return nil }          // the track ends in the air
        let runway = median(rolling.map(altitudeFt))
        // Came from the air, not a fast taxi: surely airborne, and 100 ft up in the 90 s before.
        guard let air = fixes[...lastFast].lastIndex(where: { altitudeFt($0) - runway >= airborneFt }),
              fixes[...air].contains(where: {
                  fixes[air].timestamp.timeIntervalSince($0.timestamp) <= 90 && altitudeFt($0) - runway >= climbAwayFt
              })
        else { return nil }
        // Down, and still down at the next fix: one low GPS reading on final is not a touchdown.
        guard let down = ((air + 1)..<fixes.count).first(where: { k in
            altitudeFt(fixes[k]) - runway <= touchdownFt
                && (k + 1 == fixes.count || altitudeFt(fixes[k + 1]) - runway <= touchdownFt)
        }) else { return nil }
        return crossing(fixes[down - 1], fixes[down], altitudeFt: runway + touchdownFt)
    }

    /// When the altitude passed `target` between two fixes, linearly.
    private static func crossing(_ a: GPSPoint, _ b: GPSPoint, altitudeFt target: Double) -> Date {
        let from = altitudeFt(a), to = altitudeFt(b)
        guard from != to else { return b.timestamp }
        let fraction = min(max((target - from) / (to - from), 0), 1)
        return a.timestamp.addingTimeInterval(fraction * b.timestamp.timeIntervalSince(a.timestamp))
    }

    private static func altitudeFt(_ point: GPSPoint) -> Double { point.altitude / 0.3048 }

    private static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

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
