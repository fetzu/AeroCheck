import Foundation

// MARK: - The laps of a circuits flight (6.3.0)
//
// A circuits flight loops two ways (PLAN-6.3.0, the author's Q1 to Q3, 11 Oct). A touch-and-go or a
// go-around goes back to the climb check, as before. A full stop goes on to the after landing check, and at
// its end NEW CIRCUIT goes back to the check before departure (taxi and run-up are flown once, on the first
// lap), while the check slot's PARKING CHECK ends the circuits. A full stop is counted once per lap: the
// detector card's CONFIRM, LANDED, or else the choice made at the end of the after landing check.

/// Where a circuits flight stands in its laps: the loop that started the lap being flown, the circuits
/// started again from a full stop, and when the lap began. `AppState` keeps one and the crash checkpoint
/// carries it; the counts themselves stay on the flight. Pure, so its rules are tested without a flight.
struct CircuitLaps: Equatable, Codable {
    enum Loop: String, Codable {
        /// Climb to landing: a touch-and-go, or a go-around.
        case touchAndGo
        /// Before departure to after landing: a full stop, then NEW CIRCUIT.
        case fullStop
    }

    /// The loop that started the lap being flown; nil on the first lap.
    var lastLoop: Loop?
    /// NEW CIRCUIT taps: the full stops the flight went on from.
    var newCircuits = 0
    /// When the lap being flown began: the touch-and-go's touchdown, the go-around, the NEW CIRCUIT tap.
    /// Nil on the first lap.
    var lapStartedAt: Date?

    /// Whether a landing at `time` belongs to the lap being flown, not to one before it.
    func isThisLap(_ time: Date) -> Bool {
        guard let lapStartedAt else { return true }
        return time > lapStartedAt
    }

    /// A touch-and-go or a go-around at `time`: the climb check next, on a new lap.
    mutating func tookTouchAndGo(at time: Date) {
        lastLoop = .touchAndGo
        lapStartedAt = time
    }

    /// NEW CIRCUIT at `time`: the check before departure next, on a new lap.
    mutating func tookNewCircuit(at time: Date) {
        lastLoop = .fullStop
        newCircuits += 1
        lapStartedAt = time
    }
}
