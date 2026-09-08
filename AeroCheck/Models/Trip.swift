import Foundation

// MARK: - Trips (v5.x)
//
// A flight with a fuel stop is not one flight with a gap in it. It is TWO flights that happen to
// share their preparation.
//
// Each leg has its own block times, its own landing, its own filed flight plan and its own logbook
// line — AMC1 FCL.050 records one line per flight, and a stop makes two. Modelling a trip as one
// flight subdivided would mean teaching the logbook, the cost ledger and the flight recorder about
// sub-flights they have no reason to know about. So legs stay exactly what they already are, and a
// trip is a thin container above them holding only what they share.
//
// A trip is OPT-IN. `FlightThread.tripId` is nil until a flight stops being alone, so the
// overwhelmingly common case keeps the existing code path untouched by a feature that does not
// apply to it.

/// Whether a task is answered once for a whole trip, or separately for each leg.
///
/// The split follows one question: *would doing this again for the next leg produce a different
/// answer?* If yes, it is per leg.
enum TaskScope: String, Codable, Sendable {
    case trip
    case leg
}

extension ThreadTaskKey {

    var scope: TaskScope {
        switch self {
        // You book the aeroplane once, brief the route once, and reflect on the trip once.
        case .aircraftReserved, .weatherBriefed, .dabsChecked, .gaforChecked, .notamChecked,
             .debriefWritten:
            return .trip

        // Everything else changes leg by leg. Flight plans are filed and closed separately with
        // Eurocontrol; customs is per crossing; PPR and fees are per aerodrome; the nav log is the
        // sheet on the kneeboard for THIS leg; and the logbook takes one line per flight.
        //
        // MASS & BALANCE is the one that looks like trip preparation and is not: a fuel stop exists
        // precisely to change the aircraft's weight, so a trip-scoped tick would have the app
        // implying an envelope still holds after uplifting eighty litres — on exactly the flights
        // where it matters most.
        case .routePlanned, .fuelPlanned, .massAndBalance, .flightPlanFiled, .pprObtained,
             .customsNotified, .navLogReady, .flightPlanClosed, .feesPaid, .logbookEntry:
            return .leg
        }
    }

    /// Whether a trip-scoped tick expires. A booking does not; a briefing does.
    ///
    /// Nothing leg-scoped can go stale, because a leg is asked its own questions anyway.
    var goesStale: Bool {
        switch self {
        case .weatherBriefed, .dabsChecked, .gaforChecked, .notamChecked:
            return true
        default:
            return false
        }
    }
}

// MARK: - Freshness

/// When a shared tick stops covering the next leg.
///
/// A same-day fuel stop must not ask for the weather twice — that busywork is the whole reason trips
/// exist. A weekend tour absolutely must: yesterday's NOTAM briefing does not cover today, and an app
/// that implies it does is asserting something false about flight safety.
enum TripTaskFreshness {

    /// Six hours, or a new day, whichever comes first.
    static let window: TimeInterval = 6 * 3600

    /// UTC on purpose. Aviation days are UTC days, and a local calendar would make the same trip
    /// stale or fresh depending on which side of midnight the pilot's time zone happened to fall.
    static var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Whether a tick made at `tickedAt` still covers a leg departing at `departure`.
    ///
    /// BOTH halves of the rule are needed, and each catches what the other misses. Six hours alone
    /// would let an 06:00 tick cover a 23:00 leg on a long summer day. The same-day test alone would
    /// let a 23:50 tick cover a 00:10 departure ten minutes later.
    static func isStale(tickedAt: Date, forLegDeparting departure: Date) -> Bool {
        if !calendar.isDate(tickedAt, inSameDayAs: departure) { return true }
        return departure.timeIntervalSince(tickedAt) > window
    }

    /// The same rule with the leg's departure possibly missing, falling back to a trip-level
    /// reference date.
    ///
    /// This fallback is why the rule fires at all. `FlightCreator.createTrip` gives ONLY the first
    /// leg a departure time — deliberately, because the app cannot know when the earlier legs land
    /// and a guessed time would also drive the T-24h reminder. But the first leg is the one whose
    /// tick it is, so with no fallback every later leg answered "not stale" and yesterday's NOTAM
    /// briefing showed a green tick on today's flight. That is the exact assertion the file header
    /// says must never be made.
    ///
    /// The reference is the trip's own date, not an invented leg departure: it is a real number the
    /// pilot chose, it never pretends to be a departure, and it degrades to "the day the trip was
    /// planned", which is the right thing to measure a shared briefing against. (review F12)
    static func isStale(tickedAt: Date?, forLegDeparting departure: Date?, reference: Date? = nil) -> Bool {
        guard let tickedAt else { return false }
        guard let against = departure ?? reference else { return false }
        return isStale(tickedAt: tickedAt, forLegDeparting: against)
    }
}

// MARK: - Trip

/// An ordered set of flights sharing one preparation.
struct Trip: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()

    /// Thread ids, in the order they are flown. The single source of truth for leg order: a thread
    /// records only that it belongs to a trip, never where in it, so there is nothing to drift.
    var legIds: [UUID] = []

    /// The preparation the legs share. Their `completedAt` is what makes staleness work, so these
    /// live here rather than being duplicated onto each leg.
    var sharedTasks: [ThreadTask] = []

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var legCount: Int { legIds.count }

    /// What an undated leg measures a shared tick against.
    ///
    /// The trip's planned date when it has one, otherwise the day it was created. `scheduledStart`
    /// is written by `formTrip` from the first leg's departure, which is the one date in a trip the
    /// pilot actually chose.
    var freshnessReference: Date { scheduledStart ?? createdAt }

    /// The trip's own departure — the first leg's, captured when the trip forms. Optional because a
    /// trip can be built with no date at all.
    var scheduledStart: Date?

    /// A trip of one leg is just a flight. Used to decide when a trip has outlived its purpose and
    /// should be dissolved back into a standalone flight.
    var isDegenerate: Bool { legIds.count < 2 }

    func task(withId id: UUID) -> ThreadTask? { sharedTasks.first { $0.id == id } }

    /// Where a leg sits in the trip, one-based for display. Nil for a thread that is not in it.
    func legNumber(of threadId: UUID) -> Int? {
        legIds.firstIndex(of: threadId).map { $0 + 1 }
    }

    /// Shared tasks as this leg should see them: a staleable tick that no longer covers the leg's
    /// departure reads as pending again, carrying when it was last done so the pilot can tell a
    /// refresh from something they forgot.
    func tasks(forLegDeparting departure: Date?, legId: UUID? = nil) -> [ThreadTask] {
        sharedTasks.map { task in
            // A tick made from this very leg covers it, regardless of the clock. Without this a
            // stale row was untickable: the tap re-stamped `completedAt` to now, the rule measured
            // that against the SAME leg departure, and it read stale again. (review F13)
            if let legId, task.acknowledgedLegIds.contains(legId) { return task }
            guard task.key.goesStale, task.state == .done,
                  TripTaskFreshness.isStale(tickedAt: task.completedAt,
                                            forLegDeparting: departure,
                                            reference: freshnessReference)
            else { return task }
            var stale = task
            stale.state = .pending
            // `completedAt` is deliberately KEPT. It is what lets the row say "checked 08:12 —
            // re-check for this leg" rather than looking like a task nobody has touched.
            return stale
        }
    }

    mutating func touch() { updatedAt = Date() }
}
