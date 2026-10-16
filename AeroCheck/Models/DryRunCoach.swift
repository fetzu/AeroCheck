import Foundation
import CoreLocation

// MARK: - Dry run (6.4.0): the guided flight

/// One step of the guided flight: a card that says what to look at (a look step, Next goes on) or what to do
/// (a do step, done when the pilot has done it), shown when the Cockpit shows what it speaks of. Never on a
/// timer, and never on a cue the screen doesn't show yet: the approach check's card waits for the slot to name
/// the approach check (the device checks, 16 Oct, g-7). (6.4.0)
struct DryRunCoachStep: Equatable {
    enum Kind: Equatable { case look, act }

    /// Where the card points: the control rung, live, under the veil (a do step that is one tap), or just rung.
    /// A ring is only ever on a control that shows what the card names: a step that sends the pilot through
    /// the checks first rings CHECK, and the next step rings the control once the band shows it.
    enum Target: String, Equatable {
        /// The act band's first slot: the check slot, ENGINE START, ENGINE SHUTDOWN.
        case first
        /// CHECK, then NEXT, READY FOR LINE UP, END FLIGHT.
        case primary
        /// Where a check goes on from: the first slot on MAP and ROUTE (it names the check), CHECK or NEXT on
        /// CHECKLIST. Resolved by the coach; no control says it of itself.
        case check
        case deferItem
        case deferredChip
        case pageMap
        case pageRoute
        case readBand
        case menu
        case finalCard
        case landedCard
        /// CONFIRM on a detected event's card (the go-around).
        case eventConfirm
    }

    /// What the act band shows, as the coach reads it.
    enum Slot: Equatable {
        /// The check slot names this check (`CockpitCheckSlot.slot(for:)`).
        case check(ChecklistPhase)
        case engineStart
        case engineShutdown
        /// The check before departure done: READY FOR LINE UP.
        case readyForLineUp
        /// The last check done: END FLIGHT.
        case endFlight
    }

    /// The engine hours' prompt, over the Cockpit.
    enum HourMeterPrompt: Equatable { case beforeStart, afterStop }

    /// When it shows.
    enum Moment: Equatable {
        case now
        case shows(Slot)
        /// Parked at the end, and the band shows it.
        case parkedAndShows(Slot)
        case hourMeter(HourMeterPrompt)
        /// At the holding point, waiting for READY FOR LINE UP.
        case holdingPoint
        /// The app saw the take-off roll, and the aircraft is climbing away.
        case airborne
        /// The app wrote the time over of the route's waypoint `n` (1: the first after the departure).
        case timeOver(Int)
        /// The landing check shown, from circuit height.
        case landingShown
        /// The `n`th final (1: the first).
        case final(Int)
        /// The detector's go-around card.
        case goAroundCard
        /// The LANDED card.
        case landedCard
    }

    /// What finishes it.
    enum Done: Equatable {
        case next
        /// The band shows it: the pilot worked through the checks to it.
        case shows(Slot)
        /// The engine hours' prompt answered or skipped.
        case hourMeterClosed
        case itemChecked
        case engineStarted
        case deferred
        case linedUp
        case page(CockpitPage)
        /// The check worked through (or left behind).
        case checkDone(ChecklistPhase)
        case finalChoice(DryRunGenerator.Landing)
        case goAroundAnswered
        case landedAnswered
        case engineShutdown
        case flightEnded
    }

    /// Whether the step is for this flight at all.
    enum Requires: Equatable {
        case always
        /// The aircraft logs its engine hours and the counter before the start is still to give.
        case engineHoursBefore
        case engineHoursAfter
    }

    /// Stable: the strings' key, the tests'.
    let id: String
    let chapter: Int
    let kind: Kind
    let target: Target?
    /// The rest of the screen veiled: one control to tap. Not where the pilot works through the checks.
    let veils: Bool
    /// The flight waits while it shows. Not where the pilot works through checks on the ground: the aircraft
    /// waits there by itself (the engine start, the holding point, parked), or taxis on (to the parking).
    let holds: Bool
    let moment: Moment
    let done: Done
    var requires: Requires = .always
    let title: String
    let body: String
    /// What the folded card says comes next for the pilot while this step is the next one to do ("the climb
    /// check, at 500 ft"); nil where nothing waits for them.
    var upcoming: String? = nil
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

    /// Every step, in the order the flight meets them (the proposal's table, "Plan to Logbook", 16 Oct).
    static var steps: [DryRunCoachStep] {
        typealias S = DryRunCoachStep
        typealias T = L10n.DryRunCoach.Step
        return [
            // 1 · Before you go
            S(id: "cockpit", chapter: 1, kind: .look, target: nil, veils: false, holds: true, moment: .now, done: .next,
              title: T.cockpitTitle, body: T.cockpitBody),
            S(id: "checkOnce", chapter: 1, kind: .act, target: .primary, veils: true, holds: true, moment: .now,
              done: .itemChecked, title: T.checkOnceTitle, body: T.checkOnceBody),
            S(id: "memoryTest", chapter: 1, kind: .look, target: .menu, veils: false, holds: true, moment: .now,
              done: .next, title: T.memoryTestTitle, body: T.memoryTestBody),
            // 2 · Engine and taxi
            S(id: "toEngineStart", chapter: 2, kind: .act, target: .primary, veils: false, holds: false, moment: .now,
              done: .shows(.engineStart), title: T.toEngineStartTitle, body: T.toEngineStartBody),
            S(id: "hoursBefore", chapter: 2, kind: .act, target: nil, veils: false, holds: true,
              moment: .hourMeter(.beforeStart), done: .hourMeterClosed, requires: .engineHoursBefore,
              title: T.hoursBeforeTitle, body: T.hoursBeforeBody),
            S(id: "engineStart", chapter: 2, kind: .act, target: .first, veils: true, holds: true,
              moment: .shows(.engineStart), done: .engineStarted, title: T.engineStartTitle, body: T.engineStartBody),
            S(id: "defer", chapter: 2, kind: .act, target: .deferItem, veils: true, holds: true, moment: .now,
              done: .deferred, title: T.deferTitle, body: T.deferBody),
            S(id: "deferredChip", chapter: 2, kind: .look, target: .deferredChip, veils: false, holds: true,
              moment: .now, done: .next, title: T.deferredChipTitle, body: T.deferredChipBody),
            // 3 · Line-up
            S(id: "toBeforeDeparture", chapter: 3, kind: .act, target: .primary, veils: false, holds: false,
              moment: .holdingPoint, done: .shows(.readyForLineUp), title: T.toBeforeDepartureTitle,
              body: T.toBeforeDepartureBody, upcoming: T.toBeforeDepartureUpcoming),
            S(id: "readyForLineUp", chapter: 3, kind: .act, target: .primary, veils: true, holds: true,
              moment: .shows(.readyForLineUp), done: .linedUp, title: T.readyForLineUpTitle, body: T.readyForLineUpBody),
            S(id: "lineUpCheck", chapter: 3, kind: .act, target: .check, veils: false, holds: true, moment: .now,
              done: .checkDone(.lineUp), title: T.lineUpCheckTitle, body: T.lineUpCheckBody),
            S(id: "mapTakeoff", chapter: 3, kind: .act, target: .pageMap, veils: true, holds: true, moment: .now,
              done: .page(.map), title: T.mapTakeoffTitle, body: T.mapTakeoffBody),
            // 4 · Take-off and climb
            S(id: "airborne", chapter: 4, kind: .look, target: nil, veils: false, holds: true, moment: .airborne,
              done: .next, title: T.airborneTitle, body: T.airborneBody),
            S(id: "climbCheck", chapter: 4, kind: .act, target: .check, veils: false, holds: true,
              moment: .shows(.check(.climb)), done: .checkDone(.climb), title: T.climbCheckTitle,
              body: T.climbCheckBody, upcoming: T.climbCheckUpcoming),
            S(id: "readBand", chapter: 4, kind: .look, target: .readBand, veils: false, holds: true, moment: .now,
              done: .next, title: T.readBandTitle, body: T.readBandBody),
            // 5 · On the route
            S(id: "cruiseCheck", chapter: 5, kind: .act, target: .check, veils: false, holds: true,
              moment: .shows(.check(.cruise)), done: .checkDone(.cruise), title: T.cruiseCheckTitle,
              body: T.cruiseCheckBody, upcoming: T.cruiseCheckUpcoming),
            S(id: "routePage", chapter: 5, kind: .act, target: .pageRoute, veils: true, holds: true, moment: .now,
              done: .page(.route), title: T.routePageTitle, body: T.routePageBody),
            S(id: "timeOver", chapter: 5, kind: .look, target: nil, veils: false, holds: true, moment: .timeOver(1),
              done: .next, title: T.timeOverTitle, body: T.timeOverBody),
            S(id: "descentCheck", chapter: 5, kind: .act, target: .check, veils: false, holds: true,
              moment: .shows(.check(.descent)), done: .checkDone(.descent), title: T.descentCheckTitle,
              body: T.descentCheckBody, upcoming: T.descentCheckUpcoming),
            // 6 · Back to land
            S(id: "approachCheck", chapter: 6, kind: .act, target: .check, veils: false, holds: true,
              moment: .shows(.check(.approach)), done: .checkDone(.approach), title: T.approachCheckTitle,
              body: T.approachCheckBody, upcoming: T.approachCheckUpcoming),
            S(id: "landingShown", chapter: 6, kind: .look, target: .first, veils: false, holds: true,
              moment: .landingShown, done: .next, title: T.landingShownTitle, body: T.landingShownBody),
            S(id: "goAround", chapter: 6, kind: .act, target: .finalCard, veils: true, holds: true, moment: .final(1),
              done: .finalChoice(.goAround), title: T.goAroundTitle, body: T.goAroundBody, upcoming: T.goAroundUpcoming),
            S(id: "goAroundCard", chapter: 6, kind: .act, target: .eventConfirm, veils: false, holds: true,
              moment: .goAroundCard, done: .goAroundAnswered, title: T.goAroundCardTitle, body: T.goAroundCardBody),
            S(id: "climbAgain", chapter: 6, kind: .act, target: .check, veils: false, holds: true,
              moment: .shows(.check(.climb)), done: .checkDone(.climb), title: T.climbAgainTitle,
              body: T.climbAgainBody, upcoming: T.climbAgainUpcoming),
            S(id: "fullStop", chapter: 6, kind: .look, target: .finalCard, veils: false, holds: true, moment: .final(2),
              done: .next, title: T.fullStopTitle, body: T.fullStopBody),
            S(id: "landed", chapter: 6, kind: .act, target: .landedCard, veils: false, holds: true, moment: .landedCard,
              done: .landedAnswered, title: T.landedTitle, body: T.landedBody, upcoming: T.landedUpcoming),
            // 7 · After landing
            S(id: "toShutdown", chapter: 7, kind: .act, target: .primary, veils: false, holds: false, moment: .now,
              done: .shows(.engineShutdown), title: T.toShutdownTitle, body: T.toShutdownBody),
            S(id: "engineShutdown", chapter: 7, kind: .act, target: .first, veils: true, holds: true,
              moment: .parkedAndShows(.engineShutdown), done: .engineShutdown, title: T.engineShutdownTitle,
              body: T.engineShutdownBody, upcoming: T.engineShutdownUpcoming),
            S(id: "hoursAfter", chapter: 7, kind: .act, target: nil, veils: false, holds: true,
              moment: .hourMeter(.afterStop), done: .hourMeterClosed, requires: .engineHoursAfter,
              title: T.hoursAfterTitle, body: T.hoursAfterBody),
            S(id: "toEndFlight", chapter: 7, kind: .act, target: .primary, veils: false, holds: false, moment: .now,
              done: .shows(.endFlight), title: T.toEndFlightTitle, body: T.toEndFlightBody),
            S(id: "endFlight", chapter: 7, kind: .act, target: .primary, veils: true, holds: true,
              moment: .shows(.endFlight), done: .flightEnded, title: T.endFlightTitle, body: T.endFlightBody),
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
/// fix; holds the flight while a step that holds shows. Started at a chapter, the flight is first taken there
/// behind a cover, as fast as it can be flown, the earlier steps done for the pilot as the pilot would
/// (`perform`), nothing shown and nothing asked on the way; the chapter's first step then shows over the
/// Cockpit (the proposal's Q6).
@MainActor
final class DryRunCoach: ObservableObject {
    let steps: [DryRunCoachStep]
    let startChapter: Int

    /// The step showing, if any.
    @Published private(set) var step: DryRunCoachStep?
    /// The chapters gone through, for their habits.
    @Published private(set) var chaptersDone: [Int] = []
    /// Getting to the chapter it starts at, behind the cover.
    @Published private(set) var isFastForwarding: Bool
    /// "Show me again": the ring pulses once more.
    @Published private(set) var pulse = 0
    /// The engine hours' prompt over the Cockpit, as `FlightView` shows it.
    @Published var hourMeter: DryRunCoachStep.HourMeterPrompt?
    /// The Cockpit's page, from `FlightView`.
    var page: CockpitPage = .checklist

    private(set) var index = 0
    private var finalsSeen = 0
    private var wasOnFinal = false
    /// Where a do step's count starts: the items checked, the checks deferred.
    private var baseline = 0
    /// The step's prompt came up: its closing finishes the step.
    private var hourMeterSeen = false

    init(startChapter: Int = 1, steps: [DryRunCoachStep] = DryRunChapters.steps) {
        self.steps = steps
        self.startChapter = max(1, min(startChapter, DryRunChapters.count))
        isFastForwarding = self.startChapter > 1
        chaptersDone = Array(1..<self.startChapter)
    }

    var isFinished: Bool { index >= steps.count }

    /// The next step for the pilot to do, while none shows: what the folded card names after "Next for you".
    var upcoming: DryRunCoachStep? {
        guard step == nil else { return nil }
        return steps[min(index, steps.count)...].first { $0.kind == .act && $0.upcoming != nil }
    }

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
        for _ in 0...steps.count {
            if let step {
                if hourMeter != nil { hourMeterSeen = true }
                if isDone(step, session) { complete(step) } else { return step.holds }
            }
            guard index < steps.count else { return false }
            let candidate = steps[index]
            guard applies(candidate, session) else {
                index += 1
                continue
            }
            guard reached(candidate.moment, session) else { return false }
            if isFastForwarding {
                if candidate.chapter < startChapter {
                    // Before the chapter flown: done for the pilot, at once, as the pilot would.
                    actAsPilot(candidate, session, onTheWay: true)
                    index += 1
                    continue
                }
                isFastForwarding = false
            }
            // A do step already done when its moment comes (the slot showed ENGINE SHUTDOWN before the card
            // could ask for the checks to it) has nothing to ask.
            if candidate.kind == .act, Self.isStateDone(candidate.done), isDone(candidate, session) {
                index += 1
                continue
            }
            baseline = count(for: candidate, session)
            hourMeterSeen = hourMeter != nil
            step = candidate
        }
        return step?.holds ?? false
    }

    /// Where the step's ring goes, as the Cockpit stands: `.check` is the first slot on MAP and ROUTE (it
    /// names the check), CHECK or NEXT on CHECKLIST.
    func resolvedTarget(of step: DryRunCoachStep) -> DryRunCoachStep.Target? {
        guard step.target == .check else { return step.target }
        return page == .checklist ? .primary : .first
    }

    private func complete(_ done: DryRunCoachStep) {
        step = nil
        index += 1
        let chapterEnds = index >= steps.count || steps[index].chapter != done.chapter
        if chapterEnds, !chaptersDone.contains(done.chapter) { chaptersDone.append(done.chapter) }
    }

    // MARK: Moments and what finishes a step

    private func applies(_ step: DryRunCoachStep, _ session: DryRunSession) -> Bool {
        let appState = session.world.appState
        switch step.requires {
        case .always:
            return true
        case .engineHoursBefore:
            // The prompt is the Cockpit's: never on the way to a chapter, where no Cockpit shows.
            return !isFastForwarding && appState.settings.logEngineHours && appState.currentFlight?.engineHourStart == nil
        case .engineHoursAfter:
            return !isFastForwarding && appState.settings.logEngineHours && appState.currentFlight?.engineHourEnd == nil
        }
    }

    private func reached(_ moment: DryRunCoachStep.Moment, _ session: DryRunSession) -> Bool {
        let appState = session.world.appState
        let generator = session.generator
        switch moment {
        case .now: return true
        case .shows(let slot): return Self.shows(slot, appState)
        case .parkedAndShows(let slot): return generator.isParkedForGood && Self.shows(slot, appState)
        case .hourMeter(let prompt): return hourMeter == prompt
        case .holdingPoint:
            // At the holding point itself: not the engine start's wait, which a card held at the parking
            // still shows (the autopilot found it on the simulator, 16 Oct).
            return generator.waitingAt == .lineUp && generator.mark("lineUp") == nil
        case .airborne:
            guard appState.flightCues.legs > 0, let liftoff = generator.mark("liftoff") else { return false }
            return generator.t - liftoff >= 8
        case .timeOver(let n):
            guard let plan = session.world.plans.activeFlightPlan, plan.waypoints.indices.contains(n) else { return false }
            return plan.waypoints[n].actualTimeOver != nil
        case .landingShown: return appState.landingCheckShown
        case .final(let n): return session.isOnFinal && finalsSeen >= n
        case .goAroundCard: return session.world.detector.pendingGoAround != nil
        case .landedCard: return appState.landedCard != nil
        }
    }

    /// What the band shows. `CockpitCheckSlot.slot(for:)` is the slot's own reading; the primary's is
    /// `ActChecklistPrimary`'s (READY FOR LINE UP, END FLIGHT once the check is done).
    static func shows(_ slot: DryRunCoachStep.Slot, _ appState: AppState) -> Bool {
        let phase = appState.currentPhase
        switch slot {
        case .check(let check):
            // Named as due (or owed): "next" alone, before its cue, is not the check asked for yet.
            let shown = CockpitCheckSlot.slot(for: appState)
            return shown.title == .check && shown.phase == check && !shown.readiesForLineUp
                && (shown.tone == .due || shown.tone == .owed)
        case .engineStart: return phase.showsEngineStartButton && appState.engineStartTime == nil
        case .engineShutdown: return phase.showsEngineShutdownButton && appState.engineShutdownTime == nil
        case .readyForLineUp: return phase.readiesForLineUp && appState.currentCheckIsDone
        case .endFlight: return appState.isLastPhase && appState.currentCheckIsDone
        }
    }

    /// A done that reads the flight's state (rather than a tap counted from the step's start).
    private static func isStateDone(_ done: DryRunCoachStep.Done) -> Bool {
        switch done {
        case .shows, .engineStarted, .linedUp, .checkDone, .engineShutdown: return true
        default: return false
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
        case .shows(let slot): return Self.shows(slot, appState)
        case .hourMeterClosed: return hourMeterSeen && hourMeter == nil
        case .itemChecked, .deferred: return count(for: step, session) > baseline
        case .engineStarted: return appState.engineStartTime != nil
        case .linedUp: return appState.lineUpTime != nil
        case .page(let page): return self.page == page
        case .checkDone(let check):
            return appState.currentPhase.rawValue > check.rawValue
                || (appState.currentPhase == check && appState.currentCheckIsDone)
                || appState.getPhaseStatus(check) == .completed
        case .finalChoice(let landing): return session.finalChoice == landing
        case .goAroundAnswered: return session.world.detector.pendingGoAround == nil
        case .landedAnswered: return appState.landedCard == nil
        case .engineShutdown: return appState.engineShutdownTime != nil
        case .flightEnded: return !appState.isFlightActive
        }
    }

    /// What the pilot does for `step`: for a step before the chapter flown, and for the tests and the DEBUG
    /// autopilot, which fly the whole guided flight. The checks worked through as a pilot works through them
    /// (so nothing is deferred or owed), the controls tapped, the cards answered. Not Next on a look step, nor
    /// the engine hours, typed in the Cockpit's own prompt. `onTheWay`: on the way to a chapter, where nothing
    /// is deferred (the chapter starts with nothing left behind).
    func actAsPilot(_ step: DryRunCoachStep, _ session: DryRunSession, onTheWay: Bool = false) {
        let appState = session.world.appState
        switch step.done {
        case .shows(let slot):
            // Through the checks to it, each worked through and gone on from with NEXT.
            for _ in 0..<ChecklistPhase.allCases.count {
                if Self.shows(slot, appState) { break }
                Self.workThroughCurrentCheck(appState)
                if Self.shows(slot, appState) { break }
                let before = appState.currentPhase
                appState.nextPhase()
                if appState.currentPhase == before { break }
            }
        case .engineStarted:
            appState.recordEngineStart()
        case .linedUp:
            // NEXT out of the check before departure: READY FOR LINE UP, its time noted.
            Self.workThroughCurrentCheck(appState)
            appState.nextPhase()
        case .checkDone(let check):
            // On to it if the Cockpit isn't there yet (the slot's tap), then through it.
            if appState.currentPhase.rawValue < check.rawValue {
                Self.workThroughCurrentCheck(appState)
                appState.goToPhase(check, skipped: .alreadyDone)
            }
            if appState.currentPhase == check { Self.workThroughCurrentCheck(appState) }
        case .page(let page):
            self.page = page
        case .itemChecked:
            Self.checkItem(appState)
        case .deferred:
            if !onTheWay { appState.deferHighlightedItem() }
        case .flightEnded:
            session.world.location.stopTracking()
            appState.endFlight()
        case .finalChoice(let landing):
            session.finalChoice = landing
        case .goAroundAnswered:
            if let event = session.world.detector.pendingGoAround {
                FlightEventConfirmationOverlay.confirm(event, appState: appState, detector: session.world.detector)
            }
        case .landedAnswered:
            if appState.landedCard != nil { appState.answerLandedCard(.yes) }
        case .engineShutdown:
            appState.recordEngineShutdown()
        case .next, .hourMeterClosed:
            break
        }
    }

    /// The current check's items checked, or a memory check confirmed. False when it can't be (nothing tracks
    /// the items without step-by-step highlighting: then NEXT alone goes on).
    @discardableResult
    static func workThroughCurrentCheck(_ appState: AppState) -> Bool {
        if appState.currentCheckAwaitsConfirmation {
            appState.confirmMemoryCheck()
            return true
        }
        for _ in 0..<200 where !appState.currentCheckIsDone { checkItem(appState) }
        return appState.currentCheckIsDone
    }

    /// CHECK, as the Cockpit's button does it: the highlight on to the next item, past the last one at the end.
    static func checkItem(_ appState: AppState) {
        let learning = appState.effectiveLearningMode
        let count = appState.activeChecklist.visibleItemCount(for: appState.currentPhase, learningMode: learning)
        if appState.getHighlightedItem(for: appState.currentPhase) >= count - 1 {
            appState.markLastItemComplete(learningMode: learning)
        } else {
            appState.advanceHighlightedItem(learningMode: learning)
        }
    }
}
