import Foundation

// MARK: - FREDA in cruise (6.1, "Checks in flight" Q6)
//
// The cruise check (the aircraft's own read-do list) is run once, at level-off. From then on the cruise
// is checked with the FREDA flow (fuel, radio, engine, direction, altimeter): from memory, no list. It
// comes due every ten minutes, or at a waypoint passed five minutes or more after the last one,
// whichever comes first. The UK CAA's text is "at significant turning points of the route or
// approximately every 10 minutes" (Safety Sense 05); the waypoints the flight marks (the ATO catch-up,
// or MARK) stand for the turning points, and the five minutes keep two close waypoints from asking twice.
//
// It shows in the check slot on the map and in the FREDA button of the checklist's thumb bar, and one
// tap records it done, with the usual six seconds of undo. It never changes the pane, never beeps and
// never vibrates. It replaces a fixed 15-minute re-run of the cruise list that nothing showed until it
// was due, and which then took the map away by itself.

/// When FREDA is due. Pure: the clock and the waypoints come in as values, so every rule is tested
/// without a flight.
struct FredaSchedule: Equatable {
    /// "Approximately every 10 minutes."
    static let interval: TimeInterval = 10 * 60
    /// A waypoint makes it due only this long after the last FREDA (or the cruise check).
    static let waypointFloor: TimeInterval = 5 * 60

    /// What the count runs from.
    enum Since: Equatable {
        case cruiseCheck
        case freda
    }

    struct Due: Equatable {
        /// When it came due: the ten minutes up, or the waypoint's passage.
        let since: Date
        /// The waypoint passed that made it due; nil for the ten minutes.
        let waypoint: String?
    }

    /// When the count started: the cruise check done, or the last FREDA. Nil while it doesn't run
    /// (outside cruise, and in cruise until its check is done).
    private(set) var anchor: Date?
    private(set) var since: Since = .cruiseCheck
    private(set) var due: Due?

    var isRunning: Bool { anchor != nil }

    /// When the ten minutes are up; nil while it doesn't run.
    var nextDueAt: Date? { anchor?.addingTimeInterval(Self.interval) }

    /// Time left until the ten minutes are up, never below zero.
    func remaining(now: Date) -> TimeInterval? {
        nextDueAt.map { max(0, $0.timeIntervalSince(now)) }
    }

    /// The count starts (again) from `date`: the cruise check just done, or a FREDA.
    mutating func start(at date: Date, after since: Since) {
        anchor = date
        self.since = since
        due = nil
    }

    /// Cruise left (or the flight ended): the count stops. Returns the FREDA that was due and not done,
    /// which the flight records as missed.
    @discardableResult
    mutating func stop() -> Due? {
        let missed = due
        self = FredaSchedule()
        return missed
    }

    /// Due once the ten minutes are up, or at a waypoint passed at least five minutes after the anchor,
    /// whichever came first. Returns true when it has just come due. Once due, it stays due until done.
    @discardableResult
    mutating func evaluate(now: Date, lastPassage: FredaWaypointPassage?) -> Bool {
        guard let anchor, due == nil else { return false }
        var candidates: [Due] = []
        let tenMinutes = anchor.addingTimeInterval(Self.interval)
        if now >= tenMinutes { candidates.append(Due(since: tenMinutes, waypoint: nil)) }
        if let passage = lastPassage, passage.at >= anchor.addingTimeInterval(Self.waypointFloor) {
            candidates.append(Due(since: passage.at, waypoint: passage.name))
        }
        guard let first = candidates.min(by: { $0.since < $1.since }) else { return false }
        due = first
        return true
    }
}

/// A waypoint the flight has passed: its name and its ATO.
struct FredaWaypointPassage: Equatable {
    let name: String
    let at: Date
}

extension FredaWaypointPassage {
    /// The last waypoint of `plan` passed so far, by its ATO: marked by the flight on its own or with
    /// MARK. The departure is left out (its time is the take-off). The time filter in `evaluate` keeps
    /// an ATO from an earlier flight of the same route from counting.
    static func latest(in plan: FlightPlan?) -> FredaWaypointPassage? {
        guard let plan else { return nil }
        let passed = plan.waypoints.enumerated().dropFirst().compactMap { index, waypoint -> FredaWaypointPassage? in
            guard let at = waypoint.actualTimeOver else { return nil }
            let name = waypoint.routeName(.compact)
            return FredaWaypointPassage(name: name.isEmpty ? "WPT \(index + 1)" : name, at: at)
        }
        return passed.max { $0.at < $1.at }
    }
}

/// One FREDA of the flight, kept on the flight for the debrief: done (and when it had come due, if it
/// had), or missed (due, and cruise left without it). (6.1)
struct FredaCheck: Codable, Equatable, Identifiable {
    enum Outcome: String, Codable {
        case done
        case missed
    }

    let id: UUID
    let outcome: Outcome
    /// When it came due; nil for one done before it was due.
    let dueAt: Date?
    /// The waypoint that made it due; nil for the ten minutes (or done before it was due).
    let waypoint: String?
    /// When it was done; nil when missed.
    let doneAt: Date?

    /// A flight keeps at most this many (ten minutes apart, that is over a day of cruise): a bound on
    /// what a synced or imported record can carry.
    static let maxPerFlight = 200

    init(id: UUID = UUID(), outcome: Outcome, dueAt: Date?, waypoint: String?, doneAt: Date?) {
        self.id = id
        self.outcome = outcome
        self.dueAt = dueAt
        self.waypoint = waypoint
        self.doneAt = doneAt
    }

    static func done(at date: Date, due: FredaSchedule.Due?) -> FredaCheck {
        FredaCheck(outcome: .done, dueAt: due?.since, waypoint: due?.waypoint, doneAt: date)
    }

    static func missed(_ due: FredaSchedule.Due) -> FredaCheck {
        FredaCheck(outcome: .missed, dueAt: due.since, waypoint: due.waypoint, doneAt: nil)
    }

    /// Tolerant, as a flight file must be: a record from a newer build with an outcome this build
    /// doesn't know reads as missed (to look at), and a missing id gets a new one, rather than failing
    /// the whole flight.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let raw = try c.decodeIfPresent(String.self, forKey: .outcome) ?? ""
        outcome = Outcome(rawValue: raw) ?? .missed
        dueAt = try c.decodeIfPresent(Date.self, forKey: .dueAt)
        waypoint = try c.decodeIfPresent(String.self, forKey: .waypoint)
        doneAt = try c.decodeIfPresent(Date.self, forKey: .doneAt)
    }
}
