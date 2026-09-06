import Foundation

// MARK: - Flight Thread (v5.0.0)
//
// A "thread" is one flight followed end to end: PLAN → PREPARE → FLY → CLOSE. The FLY chapter is the
// existing 16-phase checklist flight and is deliberately NOT modelled here — the thread only holds the
// admin work that brackets it. Everything in this file is data; the rules that produce tasks live in
// `ThreadTaskEngine` (pure, testable) and the copy lives in the view layer.
//
// Design constraint that shapes the whole file: a thread is OPTIONAL. START FLIGHT works exactly as it
// always has with no thread in sight, and a flight that ran without one is never retro-fitted with a
// close-out it didn't ask for.

/// The four chapters of a followed flight. `fly` is the existing app; the other three are the admin
/// bracket this feature adds.
enum ThreadChapter: String, Codable, CaseIterable, Identifiable, Sendable {
    case plan
    case prepare
    case fly
    case close

    var id: String { rawValue }

    /// Chapters that carry tasks. `fly` is the checklist flight and owns no thread tasks.
    static var taskBearing: [ThreadChapter] { [.plan, .prepare, .close] }
}

/// How a task reaches its done state. This drives affordances, not layout: an `auto` task shows a
/// computed value and cannot be ticked by hand, a `check` task is the pilot's to tick, a `reminder`
/// additionally schedules a local notification.
enum ThreadTaskKind: String, Codable, Sendable {
    case auto
    case check
    case reminder
}

enum ThreadTaskState: String, Codable, Sendable {
    case pending
    case done
    /// Explicitly dismissed as not applicable to this flight (e.g. no PPR needed after all). Kept
    /// distinct from `done` so the readiness count doesn't claim work that never happened.
    case notApplicable
}

/// Stable identifiers for the tasks the engine can produce. Stored as the raw string on the task, so
/// renaming a case here is a data migration — add a new case instead.
///
/// The key carries no copy: titles, subtitles, icons and links are resolved for display in
/// `ThreadTaskPresentation`. That keeps a persisted thread language-agnostic (switching the app to
/// French re-renders old threads correctly) and lets the wording change without touching stored data.
enum ThreadTaskKey: String, Codable, CaseIterable, Sendable {
    // PLAN
    case routePlanned       = "plan.route"
    case fuelPlanned        = "plan.fuel"
    case massAndBalance     = "plan.massBalance"
    case aircraftReserved   = "plan.reservation"

    // PREPARE
    case weatherBriefed     = "prepare.weather"
    case dabsChecked        = "prepare.dabs"
    case gaforChecked       = "prepare.gafor"
    case notamChecked       = "prepare.notam"
    case flightPlanFiled    = "prepare.fpl"
    case pprObtained        = "prepare.ppr"
    case customsNotified    = "prepare.customs"
    case navLogReady        = "prepare.navlog"

    // CLOSE
    case flightPlanClosed   = "close.fpl"
    case feesPaid           = "close.fees"
    case logbookEntry       = "close.logbook"
    case debriefWritten     = "close.debrief"

    var chapter: ThreadChapter {
        switch self {
        case .routePlanned, .fuelPlanned, .massAndBalance, .aircraftReserved:
            return .plan
        case .weatherBriefed, .dabsChecked, .gaforChecked, .notamChecked,
             .flightPlanFiled, .pprObtained, .customsNotified, .navLogReady:
            return .prepare
        case .flightPlanClosed, .feesPaid, .logbookEntry, .debriefWritten:
            return .close
        }
    }
}

/// One item of admin work on a thread.
///
/// `subject` qualifies a task that can legitimately appear more than once — PPR and landing fees are
/// per-aerodrome, so the pair (key, subject) is the real identity. Regeneration matches on that pair
/// so a pilot's tick survives a route edit that leaves the aerodrome in place.
struct ThreadTask: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    let key: ThreadTaskKey
    /// ICAO ident, ISO country code, or nil for a task that exists once per thread.
    var subject: String?
    var kind: ThreadTaskKind
    var state: ThreadTaskState = .pending
    var completedAt: Date?
    /// Free text the pilot attached (a PPR confirmation number, who they spoke to, a fee amount).
    var note: String?
    /// Auto tasks carry their computed one-line result, so the row reads without recomputing.
    var detail: String?
    /// Raised by the engine for work that has become time-critical — today only the unclosed flight
    /// plan after landing, which is the one item with a real-world consequence for forgetting it.
    var isUrgent: Bool = false

    var chapter: ThreadChapter { key.chapter }
    var isSettled: Bool { state != .pending }

    /// Identity for regeneration: the same key for the same subject is the same task.
    var matchToken: String { "\(key.rawValue)#\(subject ?? "")" }
}

/// Where a thread is in its life. Advancing is monotonic apart from `closeOut → done`, which the pilot
/// can reopen by leaving an item unticked.
enum FlightThreadState: String, Codable, Sendable {
    case planned
    case ready
    case flying
    case closeOut
    case done
}

/// How much admin a thread carries. A circuit session gets `local`: weather and DABS to prepare, the
/// logbook line to close, and nothing about customs or flight plans.
enum ThreadProfile: String, Codable, Sendable {
    case full
    case local
}

/// One flight, followed from the first reminder to the last logbook line.
struct FlightThread: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()

    /// The plan this thread follows. Nil for a thread started without one (a local hop).
    var flightPlanId: UUID?
    /// Set when the flight actually starts, so the close-out can read the recorded flight back.
    var flightId: UUID?

    var profile: ThreadProfile = .full
    var state: FlightThreadState = .planned

    /// Route label captured at creation ("LSZQ → LSGY"), so the thread still reads correctly after the
    /// plan it came from is edited or deleted.
    var routeLabel: String
    var aircraftRegistration: String?
    var scheduledDeparture: Date?

    /// ISO-2 countries the route actually touches, recorded when the tasks are generated.
    ///
    /// Stored rather than recomputed because a regeneration triggered by something other than a plan
    /// edit has no plan to measure. Reconstructing it from the customs tasks — which only name
    /// FOREIGN countries — meant adding the home country back by hand, and that is what silently put
    /// Switzerland on a Slovakia → Germany flight and conjured DABS and GAFOR onto it.
    ///
    /// `nil` on threads written before v5.0.0: not recorded, which is treated as "unknown" and
    /// therefore as no country-specific products at all. It refills on the next regeneration.
    var countries: [String]?

    /// The trip this flight is a leg of, when it is not alone. Nil for a standalone flight, which
    /// is the overwhelmingly common case and keeps the pre-trip code path exactly.
    ///
    /// Optional, and the ONLY trip field on a thread. Leg ORDER lives in `Trip.legIds` and is not
    /// mirrored here: a duplicated index is a second source of truth that drifts the first time a leg
    /// is inserted or removed. It is also why this is the only field — a non-optional `legIndex` with
    /// a default would make the synthesised decoder reject every thread persisted before this
    /// release, which does not fail loudly; it silently loses them. (v5.x)
    var tripId: UUID?

    /// The country this flight departs FROM — what decides which of `countries` are foreign.
    /// Recorded for the same reason as `countries`: a regeneration with no plan cannot measure it,
    /// and falling back to the device's region would tell a Slovak pilot to clear customs into
    /// Slovakia.
    var homeCountry: String?

    var tasks: [ThreadTask] = []

    /// Set when the pilot ticks "flight plan filed". This is what arms the close reminder — a thread
    /// with no filed plan never nags after landing, which is what keeps circuits quiet.
    var flightPlanFiledAt: Date?
    var flightPlanClosedAt: Date?

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // MARK: - Derived

    func tasks(in chapter: ThreadChapter) -> [ThreadTask] {
        tasks.filter { $0.chapter == chapter }
    }

    /// Readiness over the pre-flight chapters only — the number Home shows. Tasks marked not
    /// applicable leave the denominator, so dismissing a PPR that turned out not to apply moves the
    /// ring to 100% rather than stranding it at 9/10.
    var preFlightProgress: (done: Int, total: Int) {
        let relevant = tasks.filter {
            ($0.chapter == .plan || $0.chapter == .prepare) && $0.state != .notApplicable
        }
        return (relevant.filter { $0.state == .done }.count, relevant.count)
    }

    var closeOutProgress: (done: Int, total: Int) {
        let relevant = tasks.filter { $0.chapter == .close && $0.state != .notApplicable }
        return (relevant.filter { $0.state == .done }.count, relevant.count)
    }

    /// The single next thing to do, in chapter order — what the Home strip advertises.
    var nextTask: ThreadTask? {
        for chapter in ThreadChapter.taskBearing {
            // Before the flight, the close chapter isn't the pilot's problem yet.
            if chapter == .close && state != .closeOut && state != .done { continue }
            if let task = tasks(in: chapter).first(where: { $0.state == .pending }) { return task }
        }
        return nil
    }

    /// True while a filed flight plan has not been closed. Drives the urgent banner and the landing
    /// notification; deliberately independent of the task's own state so a stale tick can't mute it.
    var hasOpenFlightPlan: Bool {
        flightPlanFiledAt != nil && flightPlanClosedAt == nil
    }

    var isFinished: Bool { state == .done }

    mutating func touch() { updatedAt = Date() }

    // MARK: - Mutation

    /// Set a task's state, stamping completion and keeping the flight-plan filed/closed markers in
    /// sync — those two live on the thread as well as on their task because the notification and the
    /// banner read them without walking the task list.
    mutating func setState(_ newState: ThreadTaskState, forTaskWithId taskId: UUID, now: Date = Date()) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[index].state = newState
        tasks[index].completedAt = (newState == .done) ? now : nil

        switch tasks[index].key {
        case .flightPlanFiled:
            flightPlanFiledAt = (newState == .done) ? now : nil
            // Un-filing a plan can't leave a close timestamp behind.
            if newState != .done { flightPlanClosedAt = nil }
        case .flightPlanClosed:
            flightPlanClosedAt = (newState == .done) ? now : nil
        default:
            break
        }
        touch()
    }

    mutating func setNote(_ note: String?, forTaskWithId taskId: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[index].note = (note?.isEmpty == true) ? nil : note
        touch()
    }
}
