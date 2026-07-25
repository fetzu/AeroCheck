//
//  SafeNumeric.swift
//  AeroCheck
//
//  Trap-free numeric conversion and aviation plausibility bounds for values that arrive from
//  outside the app: network feeds, paired devices, imported files, restored checkpoints. (SEC-C14)
//

import Foundation

/// `Int(someDouble)` is an unconditional **runtime trap** in Swift — not a thrown error — for NaN,
/// ±Infinity, or any magnitude outside `Int`'s range. A trap is a process kill, and it is *not*
/// catchable by an enclosing `do`/`catch`, so wrapping the decode in `try` does nothing.
///
/// The app converts externally-supplied Doubles to Int in a lot of places: OpenAIP elevations and
/// runway dimensions, the grid-cell keys computed from feed coordinates, and the knots/feet values
/// rendered on the live instruments from a GPS fix — including a fix borrowed from a paired
/// companion device. Any one of those was a single crafted or corrupt value away from killing the
/// app mid-flight.
extension Double {
    /// Converts to `Int`, or returns nil when the value is not finite or not representable.
    /// Use instead of `Int(x)` for anything derived from outside the app.
    var safeInt: Int? {
        guard isFinite,
              self >= Double(Int.min),
              self <= Double(Int.max)
        else { return nil }
        return Int(self)
    }

    /// Converts to `Int`, substituting `fallback` when the value cannot be represented.
    func safeInt(or fallback: Int) -> Int {
        safeInt ?? fallback
    }

    /// Rounds then converts, or returns nil if not representable.
    func safeRoundedInt(_ rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> Int? {
        guard isFinite else { return nil }
        return rounded(rule).safeInt
    }

    /// Rounds then converts, substituting `fallback` when not representable.
    func safeRoundedInt(_ rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero, or fallback: Int) -> Int {
        safeRoundedInt(rule) ?? fallback
    }
}

/// Plausibility envelopes for aviation quantities.
///
/// Finiteness alone is not enough: a value can be finite, in range for its type, and still
/// physically impossible — 50 km of altitude, Mach 9 in a light aircraft, an airport 200 000 ft
/// above sea level. Those pass every `isFinite` check and then drive an instrument, an AGL
/// threshold, or an exported flight plan. The bounds below are deliberately far outside any real
/// light-aircraft envelope, so they reject nonsense without ever clipping legitimate data.
enum PlausibleRange {
    /// Altitude MSL in metres. Lower bound clears the Dead Sea; upper clears any piston aircraft.
    static let altitudeMeters: ClosedRange<Double> = -500...15_000
    /// Altitude MSL in feet, for the many call sites that work in feet.
    static let altitudeFeet: ClosedRange<Double> = -1_500...50_000
    /// Ground/air speed in metres per second (0…~389 kt).
    static let speedMPS: ClosedRange<Double> = 0...200
    /// Course/track in degrees true.
    static let courseDegrees: ClosedRange<Double> = 0...360
    /// Airport/field elevation in feet MSL (Daocheng Yading is ~14 500 ft).
    static let fieldElevationFeet: ClosedRange<Double> = -1_500...20_000

    /// True when `value` is finite and inside `range`.
    static func isPlausible(_ value: Double, in range: ClosedRange<Double>) -> Bool {
        value.isFinite && range.contains(value)
    }
}
