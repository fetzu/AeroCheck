import Foundation

// MARK: - The flight's page as blocks (6.6.0)
//
// The page shows one block per activity, each with one tick (the author's answers to the flight page's rounds 1 and
// 2, 22 and 24 Oct 2026): the weather is "Weather briefed" and every country's area forecast, NOTAMs and airspace is
// the NOTAMs and every country's airspace activity, the others one task each. The tasks underneath are the ones the
// app already stores, under the same keys, so iCloud and an older build read the flight as before.
//
// Everything here is pure: what the page shows, in which order, which chapters are open, what waits for the day of
// the flight, and what the status line under the title says. The words are the view's.

/// What a block is about. A task with a subject (a border, an aerodrome) makes one block per subject.
enum FlightBlockKind: Hashable, Sendable {
    case route, fuel, massAndBalance, aircraftReserved
    case weather, notamsAndAirspace, flightPlan
    case border(String)
    case ppr(String)
    case navLog
    case closeFlightPlan
    case fees(String)
    case logbook

    /// The block a task is ticked in. The debrief task of builds before 6.4.0 has none: the debrief is the
    /// flight's notes since, never counted.
    static func of(_ task: ThreadTask) -> FlightBlockKind? {
        switch task.key {
        case .routePlanned: return .route
        case .fuelPlanned: return .fuel
        case .massAndBalance: return .massAndBalance
        case .aircraftReserved: return .aircraftReserved
        case .weatherBriefed, .gaforChecked: return .weather
        case .notamChecked, .dabsChecked: return .notamsAndAirspace
        case .flightPlanFiled: return .flightPlan
        case .customsNotified: return .border(task.subject ?? "")
        case .pprObtained: return .ppr(task.subject ?? "")
        case .navLogReady: return .navLog
        case .flightPlanClosed: return .closeFlightPlan
        case .feesPaid: return .fees(task.subject ?? "")
        case .logbookEntry: return .logbook
        case .debriefWritten: return nil
        }
    }

    var chapter: ThreadChapter {
        switch self {
        case .route, .fuel, .massAndBalance, .aircraftReserved: return .plan
        case .weather, .notamsAndAirspace, .flightPlan, .border, .ppr, .navLog: return .prepare
        case .closeFlightPlan, .fees, .logbook: return .close
        }
    }

    /// The block's fixed place in its chapter: every block keeps it, whatever is done (round 2). Blocks of the same
    /// rank (two borders, two PPRs) keep the order their tasks have.
    var rank: Int {
        switch self {
        case .route: return 0
        case .fuel: return 1
        case .massAndBalance: return 2
        case .aircraftReserved: return 3
        case .weather: return 10
        case .notamsAndAirspace: return 11
        case .flightPlan: return 12
        case .border: return 13
        case .ppr: return 14
        case .navLog: return 15
        case .closeFlightPlan: return 20
        case .fees: return 21
        case .logbook: return 22
        }
    }

    /// What says nothing about the next day's flight before its day: today's reports, today's NOTAMs (f2 A).
    var waitsForTheDay: Bool { self == .weather || self == .notamsAndAirspace }

    /// The iPad's two columns (f3 A): on the left what changes by the hour, on the right the paperwork.
    var isHourly: Bool { waitsForTheDay }
}

/// Where a block stands: every task in it done (or set aside), still something to do, or nothing that applies.
enum FlightBlockState: Equatable, Sendable {
    case pending, done, notApplicable
}

/// One block of the page: its tasks, the flight's own and its trip's, as this leg sees them.
struct FlightBlock: Identifiable, Equatable, Sendable {
    let kind: FlightBlockKind
    let tasks: [ThreadTask]
    /// The tasks among `tasks` that live on the trip, ticked for every leg.
    let sharedIds: Set<UUID>
    /// Before the flight's day, a block that waits for it (f2 A). False once the day has come, or for an undated
    /// flight.
    let waitsForDay: Bool

    var id: FlightBlockKind { kind }
    var chapter: ThreadChapter { kind.chapter }

    var state: FlightBlockState {
        let live = tasks.filter { $0.state != .notApplicable }
        if live.isEmpty { return .notApplicable }
        return live.allSatisfy { $0.state == .done } ? .done : .pending
    }

    /// Computed from the plan (route, fuel): it ticks itself, the pilot can't.
    var isAuto: Bool { !tasks.isEmpty && tasks.allSatisfy { $0.kind == .auto } }

    /// Every task in it is the trip's: "for the whole trip".
    var isShared: Bool { !tasks.isEmpty && tasks.allSatisfy { sharedIds.contains($0.id) } }

    /// When it was done: the main task's tick (the weather's "Weather briefed"), else the latest.
    var completedAt: Date? { tasks.first?.completedAt ?? tasks.compactMap(\.completedAt).max() }

    /// A trip's briefing ticked for an earlier leg that no longer covers this one: when it was done. Nil when the
    /// block isn't open again for that reason.
    var recheckSince: Date? {
        guard state == .pending else { return nil }
        return tasks.filter { sharedIds.contains($0.id) && $0.state == .pending }.compactMap(\.completedAt).max()
    }

    var isUrgent: Bool { tasks.contains { $0.isUrgent && $0.state == .pending } }

    /// Its task, for a block of one.
    var task: ThreadTask? { tasks.first }
}

/// How a chapter shows: open with its blocks, one line once done, one line when what's left waits for the day, one
/// line for CLOSE before the landing, and FLY's card.
enum FlightChapterShape: Equatable, Sendable {
    case open
    case done
    case waiting
    case notYet
    case fly
}

/// The status line under the title, as facts (the view has the words, the same on Today, f9 A).
enum FlightPageStatus: Equatable, Sendable {
    /// Before the flight: when it leaves (nil for an undated flight), and the blocks left, those for now and those
    /// that wait for the day, in page order. Ready when nothing is left.
    case before(departure: Date?, now: [FlightBlockKind], onTheDay: [FlightBlockKind])
    case flying(since: Date?)
    /// After the landing: where and when, and what's owed.
    case landed(at: String?, time: Date?, left: [FlightBlockKind])
    case closed(takeoff: Date?, landing: Date?)

    var isReady: Bool {
        if case .before(_, let now, let day) = self { return now.isEmpty && day.isEmpty }
        return false
    }
}

/// The flight's page: its blocks in order, how each chapter shows, the status line and the counts. (6.6.0)
struct FlightPage: Equatable, Sendable {
    let blocks: [FlightBlock]
    let state: FlightThreadState

    /// What the flight recorded, for the status line after it.
    struct Flown: Equatable, Sendable {
        var takeoff: Date?
        var landing: Date?
        var landedIdent: String?
    }

    /// - Parameters:
    ///   - shared: the leg's trip tasks as it sees them (`Trip.tasks(forLegDeparting:legId:)`); none for a flight
    ///     on its own.
    ///   - departure: the flight's departure, or a later leg's estimate; nil for an undated flight.
    static func make(thread: FlightThread, shared: [ThreadTask] = [], departure: Date?, now: Date = Date(),
                     calendar: Calendar = .current) -> FlightPage {
        let sharedIds = Set(shared.map(\.id))
        let beforeTheDay: Bool = {
            guard let departure, thread.state == .planned || thread.state == .ready else { return false }
            return calendar.startOfDay(for: departure) > calendar.startOfDay(for: now)
        }()
        var order: [FlightBlockKind] = []
        var grouped: [FlightBlockKind: [ThreadTask]] = [:]
        for task in thread.tasks + shared {
            guard let kind = FlightBlockKind.of(task) else { continue }
            if grouped[kind] == nil { order.append(kind) }
            grouped[kind, default: []].append(task)
        }
        // Stable within a rank: the tasks' own order (two borders, two PPRs).
        let ranked = order.enumerated().sorted { a, b in
            a.element.rank != b.element.rank ? a.element.rank < b.element.rank : a.offset < b.offset
        }.map(\.element)
        let blocks = ranked.map { kind -> FlightBlock in
            // The block's main task first: "Weather briefed" before the area forecasts, the NOTAMs before the
            // airspace activity.
            let tasks = (grouped[kind] ?? []).enumerated().sorted { a, b in
                let ka = Self.mainFirst(a.element.key), kb = Self.mainFirst(b.element.key)
                return ka != kb ? ka < kb : a.offset < b.offset
            }.map(\.element)
            return FlightBlock(kind: kind, tasks: tasks, sharedIds: sharedIds,
                               waitsForDay: beforeTheDay && kind.waitsForTheDay)
        }
        return FlightPage(blocks: blocks, state: thread.state)
    }

    private static func mainFirst(_ key: ThreadTaskKey) -> Int {
        key == .gaforChecked || key == .dabsChecked ? 1 : 0
    }

    func blocks(in chapter: ThreadChapter) -> [FlightBlock] { blocks.filter { $0.chapter == chapter } }

    func block(_ kind: FlightBlockKind) -> FlightBlock? { blocks.first { $0.kind == kind } }

    private var isBefore: Bool { state == .planned || state == .ready }
    private var isAfter: Bool { state == .closeOut || state == .done }

    /// How `chapter` shows (f1 A): every chapter with open work that can be done now is open; a finished one is a
    /// line; CLOSE is a line until the landing; PLAN and PREPARE are lines after it.
    func shape(of chapter: ThreadChapter) -> FlightChapterShape {
        if chapter == .fly { return .fly }
        if chapter == .close && !isAfter { return .notYet }
        if chapter != .close && !isBefore { return .done }
        let pending = blocks(in: chapter).filter { $0.state == .pending }
        if pending.isEmpty { return .done }
        return pending.allSatisfy(\.waitsForDay) ? .waiting : .open
    }

    /// The blocks left before the flight (PLAN and PREPARE), after it (CLOSE).
    private var left: [FlightBlock] {
        blocks.filter { $0.state == .pending && ($0.chapter == .close ? isAfter : isBefore) }
    }

    /// The status line's facts.
    func status(flown: Flown = Flown(), departure: Date?) -> FlightPageStatus {
        switch state {
        case .planned, .ready:
            let left = self.left
            return .before(departure: departure, now: left.filter { !$0.waitsForDay }.map(\.kind),
                           onTheDay: left.filter(\.waitsForDay).map(\.kind))
        case .flying:
            return .flying(since: flown.takeoff)
        case .closeOut:
            return .landed(at: flown.landedIdent, time: flown.landing, left: left.map(\.kind))
        case .done:
            return .closed(takeoff: flown.takeoff, landing: flown.landing)
        }
    }

    /// Done against all, in blocks, for what is open now: before the flight PLAN and PREPARE, after it CLOSE. What
    /// Today's ring shows (f9 A). A block that doesn't apply leaves both counts.
    var progress: (done: Int, total: Int) {
        let counted = blocks.filter { ($0.chapter == .close ? isAfter : !isAfter) && $0.state != .notApplicable }
        return (counted.filter { $0.state == .done }.count, counted.count)
    }
}

// MARK: - Deadlines (6.6.0, f7 A)

enum FlightBlockDeadline {
    /// The departure country's lead time for this flight: its domestic one when the route never leaves the country
    /// (`countries` the departure's alone) and the AIP sets one, else the one across a border.
    static func leadMinutes(_ country: BriefingRegistry.Country?, countries: [String], departureCountry: String?) -> Int? {
        guard let country else { return nil }
        if let domestic = country.filingLeadMinutesDomestic, let home = departureCountry, countries == [home] {
            return domestic
        }
        return country.filingLeadMinutes
    }

    /// When the ATC flight plan must be filed: `leadMinutes` before off-block, from the departure country's AIP
    /// (the briefing registry's `filingLeadMinutes`). Nil without a departure or a lead time: the head then says
    /// "file before off-block", never a time the app made up.
    static func fileBy(departure: Date?, leadMinutes: Int?) -> Date? {
        guard let departure, let leadMinutes, leadMinutes > 0 else { return nil }
        return departure.addingTimeInterval(-TimeInterval(leadMinutes) * 60)
    }
}
