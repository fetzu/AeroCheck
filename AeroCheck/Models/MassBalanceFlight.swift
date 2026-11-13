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

/// The sheet as it was when the flight started, kept with the flight. (the author's m13)
///
/// It carries the figures it was worked with, not a pointer to them: the aircraft's data and its
/// empty mass can change afterwards, and what the pilot saw before this flight must not. The verdict
/// and the three points are kept as they were, and are never worked out again for display.
struct FlightMassBalance: Codable, Equatable, Sendable {
    var registration: String
    var load: MassBalanceLoad
    var data: AircraftMassBalance
    var empty: AircraftMassBalance.EmptyMass?
    /// Whether the figures were the pilot's own rather than the aircraft's file.
    var isPilots: Bool
    var isConfirmed: Bool
    var verdict: MassBalanceVerdict
    var takeoff: MassBalancePoint?
    var landing: MassBalancePoint?
    var emptyTanks: MassBalancePoint?
    /// When the sheet was last changed, and when it was kept: the start of the flight.
    var sheetAt: Date
    var keptAt: Date

    /// The state it reads as, in one line.
    var state: MassBalanceFlightState {
        switch verdict {
        case .outsideLimits: return .outsideLimits(at: sheetAt)
        case .incomplete: return .incomplete
        case .notConfirmed: return .notConfirmed
        case .lastTimesLoad: return .lastTimesLoad
        case .insideLimits: return .insideLimits(at: sheetAt)
        }
    }
}

enum MassBalanceFlight {

    /// What is kept with a flight at its start: the followed flight's own sheet; for a flight with
    /// no flight followed (circuits, a flight without a plan), the aircraft's sheet when it was
    /// worked that day and said to be the day's. Nil when there is no such sheet, or no figures to
    /// work it with. Nothing is made up for a flight nobody prepared a sheet for.
    static func record(thread: FlightThread?, registration: String, shipped: AircraftMassBalance?,
                       setup: MassBalanceSetup, plan: FlightPlan?, now: Date = Date(),
                       calendar: Calendar = .current) -> FlightMassBalance? {
        guard let basis = setup.basis(shipped: shipped, now: now) else { return nil }
        let load: MassBalanceLoad
        let sheetAt: Date
        if let thread {
            guard let own = ownLoad(of: thread),
                  own.registration.caseInsensitiveCompare(registration) == .orderedSame else { return nil }
            load = startingLoad(for: thread, setup: setup, plan: plan) ?? own.load
            sheetAt = own.updatedAt
        } else {
            guard let last = setup.lastLoad, !last.isBlank, last.isTodays, let day = setup.lastLoadDay,
                  calendar.isDate(day, inSameDayAs: now) else { return nil }
            load = last
            sheetAt = day
        }
        let result = MassBalanceCalculator.compute(data: basis.data, empty: basis.empty, load: load,
                                                   isConfirmed: basis.isConfirmed)
        return FlightMassBalance(registration: registration, load: load, data: basis.data, empty: basis.empty,
                                 isPilots: basis.source == .pilot, isConfirmed: basis.isConfirmed,
                                 verdict: result.verdict, takeoff: result.takeoff, landing: result.landing,
                                 emptyTanks: result.emptyTanks, sheetAt: sheetAt, keptAt: now)
    }

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
    ///
    /// Once the flight has started, the line is the kept sheet's and nothing else: the sheet of a
    /// running or flown flight is not worked again.
    static func state(for thread: FlightThread, shipped: AircraftMassBalance?, setup: MassBalanceSetup,
                      plan: FlightPlan?, kept: FlightMassBalance? = nil, now: Date = Date()) -> MassBalanceFlightState? {
        if thread.flightId != nil { return kept?.state }
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
