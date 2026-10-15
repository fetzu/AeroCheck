import Foundation
import CoreLocation

// MARK: - Dry run (6.4.0): the guided flight

/// One step of the guided flight: a card that says what to look at (a look step, Next goes on) or what to do
/// (a do step, done when the pilot has done it), shown when the flight gets to its moment. The flight waits at
/// every step and runs at its pace in between (the proposal's Q4). (6.4.0)
struct DryRunCoachStep: Equatable {
    enum Kind: Equatable { case look, act }

    /// Where the card points: the control rung, live, under the veil (a do step that is one tap), or just rung.
    enum Target: String, Equatable {
        /// The act band's first slot: the check slot, ENGINE START, ENGINE SHUTDOWN.
        case first
        /// CHECK, then NEXT, READY FOR LINE UP, END FLIGHT.
        case primary
        case deferItem
        case deferredChip
        case pageBar
        case readBand
        case menu
        case finalCard
    }

    /// When it shows.
    enum Moment: Equatable {
        case now
        case engineStarted
        /// At the holding point, waiting for READY FOR LINE UP.
        case holdingPoint
        /// A while after the lift-off.
        case airborne
        case cue(FlightCue)
        /// Over the route's waypoint `n` (1: the first after the departure).
        case waypoint(Int)
        /// The `n`th final (1: the first).
        case final(Int)
        case goneAround
        case stopped
        case parked
    }

    /// What finishes it.
    enum Done: Equatable {
        case next
        case itemChecked
        case engineStarted
        case deferred
        case phaseAtLeast(ChecklistPhase)
        case linedUp
        case page(CockpitPage)
        case finalChoice(DryRunGenerator.Landing)
        case engineShutdown
        case flightEnded
    }

    let chapter: Int
    let kind: Kind
    let target: Target?
    /// The rest of the screen veiled: one control to tap. Not where the pilot works through the checks.
    let veils: Bool
    let moment: Moment
    let done: Done
    let title: String
    let body: String
}

/// The guided flight's chapters, each ending on one habit the summary keeps.
enum DryRunChapters {
    static let count = 7

    static func title(_ chapter: Int) -> String {
        switch chapter {
        case 1: return L10n.DryRunCoach.chapter1
        case 2: return L10n.DryRunCoach.chapter2
        case 3: return L10n.DryRunCoach.chapter3
        case 4: return L10n.DryRunCoach.chapter4
        case 5: return L10n.DryRunCoach.chapter5
        case 6: return L10n.DryRunCoach.chapter6
        default: return L10n.DryRunCoach.chapter7
        }
    }

    static func habit(_ chapter: Int) -> String {
        switch chapter {
        case 1: return L10n.DryRunCoach.habit1
        case 2: return L10n.DryRunCoach.habit2
        case 3: return L10n.DryRunCoach.habit3
        case 4: return L10n.DryRunCoach.habit4
        case 5: return L10n.DryRunCoach.habit5
        case 6: return L10n.DryRunCoach.habit6
        default: return L10n.DryRunCoach.habit7
        }
    }

    /// The phase a chapter flown on its own starts in, the earlier checks taken as done.
    static func startPhase(_ chapter: Int) -> ChecklistPhase? {
        switch chapter {
        case 4: return .climb
        case 5: return .cruise
        case 6: return .approach
        case 7: return .afterLanding
        default: return nil
        }
    }

    /// Every step, in the order the flight meets them.
    static var steps: [DryRunCoachStep] {
        typealias S = DryRunCoachStep
        typealias T = L10n.DryRunCoach
        return [
            S(chapter: 1, kind: .look, target: nil, veils: false, moment: .now, done: .next, title: T.c1s1Title, body: T.c1s1Body),
            S(chapter: 1, kind: .act, target: .primary, veils: true, moment: .now, done: .itemChecked, title: T.c1s2Title, body: T.c1s2Body),
            S(chapter: 1, kind: .look, target: .menu, veils: false, moment: .now, done: .next, title: T.c1s3Title, body: T.c1s3Body),
            S(chapter: 2, kind: .act, target: .first, veils: false, moment: .now, done: .engineStarted, title: T.c2s1Title, body: T.c2s1Body),
            S(chapter: 2, kind: .act, target: .deferItem, veils: true, moment: .engineStarted, done: .deferred, title: T.c2s2Title, body: T.c2s2Body),
            S(chapter: 2, kind: .look, target: .deferredChip, veils: false, moment: .now, done: .next, title: T.c2s3Title, body: T.c2s3Body),
            S(chapter: 3, kind: .act, target: nil, veils: false, moment: .holdingPoint, done: .phaseAtLeast(.beforeDeparture), title: T.c3s1Title, body: T.c3s1Body),
            S(chapter: 3, kind: .act, target: .primary, veils: true, moment: .now, done: .linedUp, title: T.c3s2Title, body: T.c3s2Body),
            S(chapter: 4, kind: .look, target: .first, veils: false, moment: .airborne, done: .next, title: T.c4s1Title, body: T.c4s1Body),
            S(chapter: 4, kind: .look, target: .readBand, veils: false, moment: .now, done: .next, title: T.c4s2Title, body: T.c4s2Body),
            S(chapter: 5, kind: .act, target: .pageBar, veils: true, moment: .cue(.levelOff), done: .page(.map), title: T.c5s1Title, body: T.c5s1Body),
            S(chapter: 5, kind: .act, target: .pageBar, veils: true, moment: .now, done: .page(.route), title: T.c5s2Title, body: T.c5s2Body),
            S(chapter: 5, kind: .look, target: nil, veils: false, moment: .waypoint(1), done: .next, title: T.c5s3Title, body: T.c5s3Body),
            S(chapter: 6, kind: .look, target: .first, veils: false, moment: .cue(.approach), done: .next, title: T.c6s1Title, body: T.c6s1Body),
            S(chapter: 6, kind: .act, target: .finalCard, veils: true, moment: .final(1), done: .finalChoice(.goAround), title: T.c6s2Title, body: T.c6s2Body),
            S(chapter: 6, kind: .look, target: nil, veils: false, moment: .goneAround, done: .next, title: T.c6s3Title, body: T.c6s3Body),
            S(chapter: 6, kind: .look, target: .finalCard, veils: false, moment: .final(2), done: .next, title: T.c6s4Title, body: T.c6s4Body),
            S(chapter: 6, kind: .act, target: nil, veils: false, moment: .stopped, done: .phaseAtLeast(.afterLanding), title: T.c6s5Title, body: T.c6s5Body),
            S(chapter: 7, kind: .act, target: .first, veils: false, moment: .parked, done: .engineShutdown, title: T.c7s1Title, body: T.c7s1Body),
            S(chapter: 7, kind: .act, target: .primary, veils: true, moment: .now, done: .flightEnded, title: T.c7s2Title, body: T.c7s2Body),
        ]
    }

    /// The guided flight's route: from `field`, out to a turning point 8 NM away (ahead of the runway, away
    /// from its circuit) and back, at 1,500 ft over the circuit.
    static func route(from field: DryRunAerodrome) -> FlightPlan {
        let bearing = (field.runwayHeading - field.circuitSide.sign * 40 + 360).truncatingRemainder(dividingBy: 360)
        let turn = DryRunGeo.destination(from: field.reference, bearing: bearing, distance: 8 * DryRunGeo.metresPerNM)
        func aerodrome() -> FlightPlanWaypoint {
            var waypoint = FlightPlanWaypoint(name: field.ident, coordinate: field.reference)
            waypoint.pointKind = .aerodrome
            waypoint.sourceId = field.ident
            return waypoint
        }
        let home = aerodrome(), back = aerodrome()
        let point = FlightPlanWaypoint(name: L10n.DryRunCoach.turningPoint, coordinate: turn,
                                       altitude: (field.patternAltitudeFt + 1500).rounded())
        var plan = FlightPlan(name: L10n.DryRunCoach.flightName, waypoints: [home, point, back])
        plan.calculateRouteData()
        return plan
    }
}

/// The guided flight under way: which step shows, and when the next one does. Ticked by the session after each
/// fix; holds the flight while a step shows. Started at a chapter, the earlier steps are done for the pilot,
/// at Next check's pace, until that chapter's first step (the aircraft placed where the chapter starts).
@MainActor
final class DryRunCoach: ObservableObject {
    let steps: [DryRunCoachStep]
    let startChapter: Int

    /// The step showing, if any.
    @Published private(set) var step: DryRunCoachStep?
    /// The chapters gone through, for their habits.
    @Published private(set) var chaptersDone: [Int] = []
    /// Getting to the chapter it starts at.
    @Published private(set) var isPreluding: Bool
    /// "Show me again": the ring pulses once more.
    @Published private(set) var pulse = 0
    /// The Cockpit's page, from `FlightView`.
    var page: CockpitPage = .checklist

    private(set) var index = 0
    private var finalsSeen = 0
    private var wasOnFinal = false
    /// Where a do step's count starts: the items checked, the checks deferred.
    private var baseline = 0

    init(startChapter: Int = 1, steps: [DryRunCoachStep] = DryRunChapters.steps) {
        self.steps = steps
        self.startChapter = max(1, min(startChapter, DryRunChapters.count))
        isPreluding = self.startChapter > 1
        chaptersDone = Array(1..<self.startChapter)
    }

    var isFinished: Bool { index >= steps.count }

    /// Next, on a look step.
    func next() {
        guard let step, step.kind == .look else { return }
        complete(step)
    }

    func showAgain() { pulse += 1 }

    /// Where the flight is: a step's moment come, a step done. Returns whether the flight should wait.
    @discardableResult
    func tick(_ session: DryRunSession) -> Bool {
        if session.isOnFinal, !wasOnFinal { finalsSeen += 1 }
        wasOnFinal = session.isOnFinal
        for _ in 0..<steps.count {
            if let step {
                if isDone(step, session) { complete(step) } else { return true }
            }
            guard index < steps.count else { return false }
            let candidate = steps[index]
            guard reached(candidate.moment, session) else { return false }
            if isPreluding, candidate.chapter < startChapter {
                // Before the chapter flown: done for the pilot, at once.
                act(for: candidate, session)
                index += 1
                continue
            }
            if isPreluding {
                isPreluding = false
                if let phase = DryRunChapters.startPhase(startChapter) {
                    session.world.appState.goToPhase(phase, skipped: .alreadyDone)
                }
            }
            baseline = count(for: candidate, session)
            step = candidate
        }
        return step != nil
    }

    private func complete(_ done: DryRunCoachStep) {
        step = nil
        index += 1
        let chapterEnds = index >= steps.count || steps[index].chapter != done.chapter
        if chapterEnds, !chaptersDone.contains(done.chapter) { chaptersDone.append(done.chapter) }
    }

    // MARK: Moments and what finishes a step

    private func reached(_ moment: DryRunCoachStep.Moment, _ session: DryRunSession) -> Bool {
        let appState = session.world.appState
        let generator = session.generator
        switch moment {
        case .now: return true
        case .engineStarted: return appState.engineStartTime != nil
        case .holdingPoint:
            return generator.isWaiting && appState.engineStartTime != nil && generator.mark("lineUp") == nil
        case .airborne:
            guard let liftoff = generator.mark("liftoff") else { return false }
            return generator.t - liftoff >= 25
        case .cue(let cue): return appState.flightCues.fired[cue] != nil
        case .waypoint(let n): return generator.mark("wp\(n)") != nil
        case .final(let n): return session.isOnFinal && finalsSeen >= n
        case .goneAround: return generator.mark("goAround") != nil
        case .stopped: return generator.mark("stopped") != nil
        case .parked: return generator.isParkedForGood
        }
    }

    private func count(for step: DryRunCoachStep, _ session: DryRunSession) -> Int {
        let appState = session.world.appState
        switch step.done {
        case .itemChecked:
            return ChecklistPhase.allCases.reduce(0) { $0 + appState.getHighlightedItem(for: $1) }
                + ChecklistPhase.allCases.filter { appState.getPhaseStatus($0) == .completed }.count
        case .deferred:
            return appState.deferredChecks.count + appState.deferredItemCount
        default:
            return 0
        }
    }

    private func isDone(_ step: DryRunCoachStep, _ session: DryRunSession) -> Bool {
        let appState = session.world.appState
        switch step.done {
        case .next: return false
        case .itemChecked, .deferred: return count(for: step, session) > baseline
        case .engineStarted: return appState.engineStartTime != nil
        case .phaseAtLeast(let phase): return appState.currentPhase.rawValue >= phase.rawValue
        case .linedUp: return appState.lineUpTime != nil
        case .page(let page): return self.page == page
        case .finalChoice(let landing): return session.finalChoice == landing
        case .engineShutdown: return appState.engineShutdownTime != nil
        case .flightEnded: return !appState.isFlightActive
        }
    }

    /// What the pilot would have done, for a step before the chapter flown.
    private func act(for step: DryRunCoachStep, _ session: DryRunSession) {
        let appState = session.world.appState
        switch step.done {
        case .engineStarted:
            appState.recordEngineStart()
            appState.goToPhase(.taxi, skipped: .alreadyDone)
        case .phaseAtLeast(let phase):
            if appState.currentPhase.rawValue < phase.rawValue { appState.goToPhase(phase, skipped: .alreadyDone) }
        case .linedUp:
            // Not NEXT, which would defer the check's open items: the line-up reached as done, its time noted.
            appState.goToPhase(.lineUp, skipped: .alreadyDone)
            appState.recordLineUpTime()
        case .finalChoice(let landing):
            session.finalChoice = landing
        case .engineShutdown:
            appState.goToPhase(.shutdown, skipped: .alreadyDone)
            appState.recordEngineShutdown()
        case .next, .itemChecked, .deferred, .page, .flightEnded:
            break
        }
    }
}
