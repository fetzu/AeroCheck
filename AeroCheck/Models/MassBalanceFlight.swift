import Foundation

// MARK: - One flight's mass and balance (6.11.0)
//
// A flight being prepared keeps its own load, on its thread. Two flights with the same aircraft, a
// solo one tomorrow and one with a passenger on Saturday, must not read each other's sheet: a load
// kept only per aircraft would show Saturday's flight "inside limits" for tomorrow's load.
//
// The fuel is the plan's fuel on board: one figure for one fact. The sheet opens with it and writes
// it back, and the state shown on the flight's page follows a change made in the plan.

/// The load of one flight being prepared, kept on its thread.
struct ThreadMassBalance: Codable, Equatable, Sendable {
    /// The aircraft it was worked for. A thread whose aircraft changes starts again.
    var registration: String
    var load: MassBalanceLoad
    var updatedAt: Date
}

/// The sheet's last state for a flight, in one line on its page and on Today. (the author's m12)
enum MassBalanceFlightState: Equatable, Sendable {
    /// No load for this flight, and none of an earlier flight to start from.
    case notDone
    /// Only an earlier flight's load: nothing is said of this one yet.
    case lastTimesLoad
    case incomplete
    case notConfirmed
    case outsideLimits(at: Date)
    case insideLimits(at: Date)
}

enum MassBalanceFlight {

    /// The thread's own load, when it was worked for the aircraft the thread has now.
    static func ownLoad(of thread: FlightThread) -> ThreadMassBalance? {
        guard let kept = thread.massBalance, let registration = thread.aircraftRegistration,
              kept.registration.caseInsensitiveCompare(registration) == .orderedSame else { return nil }
        return kept
    }

    /// The load a flight's sheet opens with, nil for a sheet started from nothing.
    ///
    /// The flight's own load as it was left; otherwise the aircraft's last load, which belonged to
    /// another flight and is never this one's until the pilot says so, whatever the day. With a
    /// plan, the fuel is the plan's fuel on board (unset while the plan has none) and the trip fuel
    /// the route's.
    static func startingLoad(for thread: FlightThread, setup: MassBalanceSetup, plan: FlightPlan?) -> MassBalanceLoad? {
        var load: MassBalanceLoad?
        if let own = ownLoad(of: thread) {
            load = own.load
        } else if let last = setup.lastLoad, !last.isBlank {
            load = last.carriedOver(from: setup.lastLoadDay ?? Date())
        }
        guard let plan else { return load }
        let trip = plan.tripFuel.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        guard load != nil || plan.fuelOnBoard != nil || trip != nil else { return nil }
        var withFuel = load ?? MassBalanceLoad(isTodays: true)
        withFuel.fuelLitres = plan.fuelOnBoard
        if let trip { withFuel.tripLitres = trip }
        return withFuel
    }

    /// The line for the flight's page and Today. Nil where there is nothing to say: no aircraft on
    /// the flight, or no data to compute with (the 5.0.0 calculator keeps no state).
    static func state(for thread: FlightThread, shipped: AircraftMassBalance?, setup: MassBalanceSetup,
                      plan: FlightPlan?, now: Date = Date()) -> MassBalanceFlightState? {
        guard thread.aircraftRegistration?.isEmpty == false,
              let basis = setup.basis(shipped: shipped, now: now) else { return nil }
        guard let own = ownLoad(of: thread) else {
            return (setup.lastLoad.map { !$0.isBlank } ?? false) ? .lastTimesLoad : .notDone
        }
        // With the plan's fuel as it is now, not as it was when the sheet was closed.
        let load = startingLoad(for: thread, setup: setup, plan: plan) ?? own.load
        let result = MassBalanceCalculator.compute(data: basis.data, empty: basis.empty, load: load,
                                                   isConfirmed: basis.isConfirmed)
        switch result.verdict {
        case .outsideLimits: return .outsideLimits(at: own.updatedAt)
        case .incomplete: return .incomplete
        case .notConfirmed: return .notConfirmed
        case .lastTimesLoad: return .lastTimesLoad
        case .insideLimits: return .insideLimits(at: own.updatedAt)
        }
    }
}
