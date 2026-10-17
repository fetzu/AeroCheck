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

    /// The lap being flown, from 1: one more than the laps the flight looped from, a touch-and-go or a
    /// go-around (the flight's own counts) or NEW CIRCUIT. The phone's badge, "↻ 4". (6.3.0)
    func lap(touchAndGoes: Int, goArounds: Int) -> Int {
        1 + touchAndGoes + goArounds + newCircuits
    }

    /// The loop the phase bar draws full: from the after landing check on, the full stop's, whatever started
    /// the lap; before it, the loop that started the lap, none on the first. The other is drawn faint.
    func currentLoop(at phase: ChecklistPhase) -> Loop? {
        phase.rawValue >= ChecklistPhase.afterLanding.rawValue ? .fullStop : lastLoop
    }

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

/// What the phase bar draws of a circuits flight's two loops (6.3.0, the author's picks of 11 Oct): the
/// touch-and-go loop over the bar, from the climb check to the landing check; the full-stop loop under it,
/// from the check before departure to the after landing check; each with its count, the current lap's drawn
/// full and the other faint. On the phone, the lap ("↻ 4") in the phase button and marks under the current
/// loop's segments.
struct CircuitLoopMarks: Equatable {
    /// The touch-and-go loop's laps: its touch-and-goes and go-arounds.
    var touchAndGoes: Int
    var fullStops: Int
    var current: CircuitLaps.Loop?
    var lap: Int

    /// The checks a loop flies again, in flight order.
    static func span(of loop: CircuitLaps.Loop) -> ClosedRange<Int> {
        switch loop {
        case .touchAndGo: return ChecklistPhase.climb.rawValue...ChecklistPhase.landing.rawValue
        case .fullStop: return ChecklistPhase.beforeDeparture.rawValue...ChecklistPhase.afterLanding.rawValue
        }
    }

    /// `loop`'s checks among `phases` (the bar's, cruise and descent left out).
    static func phases(of loop: CircuitLaps.Loop, in phases: [ChecklistPhase]) -> [ChecklistPhase] {
        phases.filter { span(of: loop).contains($0.rawValue) }
    }

    /// The count a loop shows: its touch-and-goes and go-arounds, or its full stops.
    func count(of loop: CircuitLaps.Loop) -> Int {
        loop == .touchAndGo ? touchAndGoes : fullStops
    }
}
