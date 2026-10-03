import Foundation

// MARK: - The phase bar at END FLIGHT, kept on the flight (6.1)

/// How one check stood when the flight ended, as the phase bar drew it: done, done from memory, answered
/// on the landed card, skipped, nothing to do; the check the flight ended on, done or still open; those
/// after it, not reached.
///
/// The flight already keeps what went wrong (`CheckRecord`: owed and the cue that passed it, skipped,
/// done late, the landed card's answers) and the FREDAs. Those can't say "All checks done", nor tell a
/// check done from one done from memory or one with nothing to do, and a flight with no record looks like
/// a flight from before 6.1. This is the rest of the picture. (6.1, the checks in the debrief)
struct CheckOutcome: Codable, Equatable {
    enum Status: String, Codable, CaseIterable {
        /// Worked through.
        case done
        /// A memory check, confirmed with one tap.
        case doneFromMemory
        /// The landing check, "yes, it was done" on the landed card.
        case confirmedAfterLanding
        /// The landing check, "not sure" on the landed card.
        case notSure
        /// Left with items open, or deferred whole and never run.
        case skipped
        /// Its phase's own action (ENGINE START, ENGINE SHUTDOWN; READY FOR LINE UP on a flight recorded
        /// before 6.2) never pressed.
        case actionMissing
        /// Nothing in it to do, or no checklist loaded.
        case nothingToDo
        /// The check the flight ended on, not finished.
        case open
        /// After the check the flight ended on.
        case notReached
    }

    /// `ChecklistPhase.rawValue`, so an unknown phase never fails the flight's decode.
    let phaseRawValue: Int
    /// `Status.rawValue`, for the same reason: a newer build's status is read as nothing.
    let statusRawValue: String

    var phase: ChecklistPhase? { ChecklistPhase(rawValue: phaseRawValue) }
    var status: Status? { Status(rawValue: statusRawValue) }

    /// Sixteen checks; the bound only stops a synced or imported flight from carrying more.
    static let maxPerFlight = 32

    init(phase: ChecklistPhase, status: Status) {
        phaseRawValue = phase.rawValue
        statusRawValue = status.rawValue
    }

    /// What the phase bar recorded.
    init(phase: ChecklistPhase, recorded: PhaseCompletionStatus) {
        let status: Status
        switch recorded {
        case .completed: status = .done
        case .doneFromMemory: status = .doneFromMemory
        case .confirmedAfterLanding: status = .confirmedAfterLanding
        case .notSure: status = .notSure
        case .skipped: status = .skipped
        case .missingAction: status = .actionMissing
        case .empty: status = .nothingToDo
        case .notStarted: status = .notReached
        }
        self.init(phase: phase, status: status)
    }

    private enum CodingKeys: String, CodingKey {
        case phaseRawValue
        case statusRawValue = "status"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phaseRawValue = (try? c.decodeIfPresent(Int.self, forKey: .phaseRawValue)) ?? -1
        statusRawValue = (try? c.decodeIfPresent(String.self, forKey: .statusRawValue)) ?? ""
    }
}

// MARK: - One flight's checks, for the Flight Log

/// One flight's checks as the debrief shows them: each check with what was recorded, the cue that passed
/// an owed one and its time, and FREDA. Pure: built from the flight alone.
///
/// A flight from before 6.1 carries nothing and gets no debrief (`make` is nil), never a false "owed". One
/// recorded by a 6.1 build before the phase bar was kept (`Flight.checkOutcomes`) has only its exceptions:
/// they are listed, and nothing is said about the other checks.
struct CheckDebrief: Equatable {
    enum Status: Equatable {
        case done
        case doneFromMemory
        case confirmedAfterLanding
        /// Owed, then done.
        case doneLate
        /// Owed, and never done.
        case owed
        case notSure
        case skipped
        case actionMissing
        case nothingToDo
        case open
        case notReached

        /// Done, or nothing to do: what "All checks done" covers. Confirmed after landing is the way a
        /// landing check flown from memory is done, so it is settled too.
        var isSettled: Bool {
            switch self {
            case .done, .doneFromMemory, .confirmedAfterLanding, .nothingToDo: return true
            default: return false
            }
        }
    }

    struct Row: Equatable, Identifiable {
        let phase: ChecklistPhase
        let status: Status
        /// The moment of the flight that passed the check open (the last one, if more than once).
        let cue: FlightCue?
        let owedAt: Date?
        /// How many times the flight passed it open: more than once only in circuits, one per circuit.
        let owedCount: Int
        /// When it was done late, skipped, or answered on the landed card.
        let at: Date?

        var id: Int { phase.rawValue }

        /// Worth a line of its own: anything but done or nothing to do. Confirmed after landing is listed
        /// too, so the debrief keeps the distinction the phase bar's outline makes.
        var isNoted: Bool {
            switch status {
            case .done, .doneFromMemory, .nothingToDo: return owedCount > 0
            default: return true
            }
        }
    }

    struct Freda: Equatable {
        /// In the order they were done.
        let done: [FredaCheck]
        /// In the order they came due.
        let missed: [FredaCheck]
    }

    /// One per check flown, in flight order (circuits: no cruise, no descent).
    let rows: [Row]
    let freda: Freda?
    /// The phase bar was kept at END FLIGHT, so every check is known.
    let isComplete: Bool

    /// Nothing to look at: every check done (or nothing to do) and no FREDA missed. The section then says
    /// one line.
    var allDone: Bool {
        isComplete && !rows.isEmpty && rows.allSatisfy { $0.status.isSettled && $0.owedCount == 0 }
            && (freda?.missed.isEmpty ?? true)
    }

    /// The checks with a line of their own, in flight order.
    var noted: [Row] { rows.filter(\.isNoted) }

    /// The others: done, done from memory, or nothing to do.
    var othersCount: Int { rows.count - noted.count }

    static func make(for flight: Flight) -> CheckDebrief? {
        var seen = Set<ChecklistPhase>()
        let outcomes: [(ChecklistPhase, CheckOutcome.Status)] = (flight.checkOutcomes ?? [])
            .compactMap { outcome in
                guard let phase = outcome.phase, let status = outcome.status else { return nil }
                return (phase, status)
            }
            .filter { seen.insert($0.0).inserted }
            .sorted { $0.0.rawValue < $1.0.rawValue }
        let records = (flight.checkRecords ?? []).filter { $0.phase != nil }.sorted { $0.at < $1.at }
        let fredas = flight.fredaChecks ?? []
        guard !outcomes.isEmpty || !records.isEmpty || !fredas.isEmpty else { return nil }

        let byPhase = Dictionary(grouping: records) { $0.phase ?? .preflight }
        let rows: [Row]
        if outcomes.isEmpty {
            rows = byPhase.keys.sorted { $0.rawValue < $1.rawValue }
                .map { row($0, outcome: nil, records: byPhase[$0] ?? []) }
        } else {
            rows = outcomes.map { row($0.0, outcome: $0.1, records: byPhase[$0.0] ?? []) }
        }
        let freda = fredas.isEmpty ? nil : Freda(
            done: fredas.filter { $0.outcome == .done }.sorted { ($0.doneAt ?? .distantPast) < ($1.doneAt ?? .distantPast) },
            missed: fredas.filter { $0.outcome == .missed }.sorted { ($0.dueAt ?? .distantPast) < ($1.dueAt ?? .distantPast) })
        return CheckDebrief(rows: rows, freda: freda, isComplete: !outcomes.isEmpty)
    }

    /// A check's status: what the phase bar ended on, read with what the flight recorded on the way.
    private static func row(_ phase: ChecklistPhase, outcome: CheckOutcome.Status?, records: [CheckRecord]) -> Row {
        let owed = records.filter { $0.kind == .owed }
        let doneLate = records.last { $0.kind == .doneLate }
        let skipped = records.last { $0.kind == .skipped }
        let answered = records.last { $0.kind == .confirmedAfterLanding || $0.kind == .notSure }
        let status: Status
        var at: Date?
        switch outcome {
        case .confirmedAfterLanding?:
            status = .confirmedAfterLanding
            at = answered?.at
        case .notSure?:
            status = .notSure
            at = answered?.at
        case .done?, .doneFromMemory?:
            // Owed on the way and done in the end (in circuits, possibly on a later circuit): done late.
            if doneLate != nil || !owed.isEmpty {
                status = .doneLate
                at = doneLate?.at
            } else {
                status = outcome == .done ? .done : .doneFromMemory
            }
        case .skipped?, .actionMissing?, .open?, .notReached?:
            at = skipped?.at
            if !owed.isEmpty {
                status = .owed
            } else {
                switch outcome {
                case .actionMissing?: status = .actionMissing
                case .open?: status = .open
                case .notReached?: status = .notReached
                default: status = .skipped
                }
            }
        case .nothingToDo?:
            status = .nothingToDo
        case nil:
            // Records only (a flight recorded before the phase bar was kept): only what they say.
            if let answered {
                status = answered.kind == .notSure ? .notSure : .confirmedAfterLanding
                at = answered.at
            } else if let doneLate, owed.last.map({ doneLate.at >= $0.at }) ?? true {
                status = .doneLate
                at = doneLate.at
            } else if !owed.isEmpty {
                status = .owed
                at = skipped?.at
            } else {
                status = .skipped
                at = skipped?.at
            }
        }
        return Row(phase: phase, status: status, cue: owed.last?.cue, owedAt: owed.last?.at,
                   owedCount: owed.count, at: at)
    }
}

// MARK: - The trend, across the last flights (Logbook)

/// What keeps coming back across the last flights: a check owed, skipped or answered "not sure" on two
/// flights or more, and FREDAs missed. Patterns only: a single occurrence is not one, and with fewer than
/// three flights to read there is nothing to say yet. Pure.
struct CheckTrend: Equatable {
    enum Kind: Equatable {
        case owed
        case skipped
        case notSure
    }

    struct Pattern: Equatable, Identifiable {
        enum Subject: Equatable {
            case check(ChecklistPhase, Kind)
            /// FREDAs missed, counted one by one.
            case fredaMissed
        }

        let subject: Subject
        /// The flights it happened on; for FREDA, the FREDAs missed.
        let count: Int

        var id: String {
            switch subject {
            case .check(let phase, let kind): return "\(phase.rawValue)-\(kind)"
            case .fredaMissed: return "freda"
            }
        }
    }

    /// The flights read: the last ones that carry checks, at most `window`.
    let flights: Int
    /// The most frequent first.
    let patterns: [Pattern]

    /// The last ten flights: a count a pilot reads as "3 of 10" whatever the season, where the last
    /// ninety days would be three flights for one pilot and thirty for another.
    static let window = 10
    /// Fewer flights than this say nothing yet.
    static let minimumFlights = 3
    /// Twice is a pattern; once is a flight.
    static let minimumOccurrences = 2

    /// `flights` newest first, as the Logbook lists them. Flights from before 6.1 carry no checks and are
    /// passed over, so the window is the last flights that can say something. Nil when there is no
    /// pattern.
    static func make(_ flights: [Flight], window: Int = window) -> CheckTrend? {
        var debriefs: [CheckDebrief] = []
        for flight in flights {
            guard debriefs.count < window else { break }
            if let debrief = CheckDebrief.make(for: flight) { debriefs.append(debrief) }
        }
        guard debriefs.count >= minimumFlights else { return nil }

        var counts: [ChecklistPhase: [Kind: Int]] = [:]
        var fredaMissed = 0
        for debrief in debriefs {
            for row in debrief.rows {
                var kinds: [Kind] = []
                if row.owedCount > 0 { kinds.append(.owed) }
                switch row.status {
                case .skipped, .actionMissing: kinds.append(.skipped)
                case .notSure: kinds.append(.notSure)
                default: break
                }
                for kind in kinds { counts[row.phase, default: [:]][kind, default: 0] += 1 }
            }
            fredaMissed += debrief.freda?.missed.count ?? 0
        }

        var patterns: [Pattern] = []
        for phase in ChecklistPhase.allCases {
            for kind in [Kind.owed, .skipped, .notSure] {
                let count = counts[phase]?[kind] ?? 0
                if count >= minimumOccurrences { patterns.append(Pattern(subject: .check(phase, kind), count: count)) }
            }
        }
        if fredaMissed >= minimumOccurrences { patterns.append(Pattern(subject: .fredaMissed, count: fredaMissed)) }
        guard !patterns.isEmpty else { return nil }
        // The most frequent first; ties keep the flight's order (FREDA, en route, after the checks).
        let ordered = patterns.enumerated().sorted { a, b in
            a.element.count != b.element.count ? a.element.count > b.element.count : a.offset < b.offset
        }.map(\.element)
        return CheckTrend(flights: debriefs.count, patterns: ordered)
    }
}
