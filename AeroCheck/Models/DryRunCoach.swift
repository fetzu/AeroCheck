import Foundation
import CoreLocation

// MARK: - Dry run (6.4.0): the guided flight, from the plan to the logbook

/// The guided dry run's parts: one flight, from the plan to the logbook ("Plan to Logbook", the author's Q1,
/// 16 Oct). Each can be taken on its own, the flight it needs flown to it behind the cover. (6.4.0)
enum DryRunPart: Int, CaseIterable, Comparable, Identifiable {
    case plan = 1, fly, closeOut, logbook

    var id: Int { rawValue }
    static func < (a: DryRunPart, b: DryRunPart) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .plan: return L10n.DryRunCoach.part1
        case .fly: return L10n.DryRunCoach.part2
        case .closeOut: return L10n.DryRunCoach.part3
        case .logbook: return L10n.DryRunCoach.part4
        }
    }

    var next: DryRunPart? { DryRunPart(rawValue: rawValue + 1) }

    /// The part's habit for the dry run's page; Fly's are its chapters'.
    var habit: String? {
        switch self {
        case .plan: return L10n.DryRunCoach.habitPlan
        case .fly: return nil
        case .closeOut: return L10n.DryRunCoach.habitClose
        case .logbook: return L10n.DryRunCoach.habitLogbook
        }
    }
}

/// Where a guided dry run starts: a part, and in Fly a chapter.
struct DryRunStart: Equatable {
    var part: DryRunPart
    /// Fly's chapter, 1 to 7.
    var chapter = 1

    static let story = DryRunStart(part: .plan)
}

/// One step of the guided flight: a card that says what to look at (a look step, Next goes on) or what to do
/// (a do step, done when the pilot has done it), shown when the Cockpit shows what it speaks of. Never on a
/// timer, and never on a cue the screen doesn't show yet: the approach check's card waits for the slot to name
/// the approach check (the device checks, 16 Oct, g-7). (6.4.0)
struct DryRunCoachStep: Equatable {
    /// A look step goes on with Next; a do step once done; a part's end is the page between two parts (on to
    /// the next, or stop there).
    enum Kind: Equatable { case look, act, partEnd }

    /// Where the card shows: over the Cockpit, or over one of the ground's screens in the dry run's world.
    enum Screen: Hashable {
        case cockpit, today, planSheet, flightPage, fuelSheet, numbers, logbook, flightDetail
    }

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
        // The ground's (the story's Plan, Close out and Logbook parts).
        case planNewFlight
        case createFlight
        case chapterBar
        case prepareChip
        case nextCard
        case fuelRow
        case notamLink
        case notamTick
        case flightPlanRow
        case startFlight
        case flightCard
        case readiness
        case logbookRow
        case debriefTick
        case finish
        case logbookDashboard
        case logbookFlight
        case flightTrack
        case flightChecks
        case flightExport
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
        /// The ground's screen shown.
        case screen(Screen)
        /// The flight over, the ground's screens back.
        case onTheGround
        case tab(GroundTab)
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
        // The ground's.
        case screen(Screen)
        case screenClosed(Screen)
        case chipTapped
        case linkTapped
        case threadCreated
        case task(ThreadTaskKey, ThreadTaskState)
        case flightStarted
        case threadFinished
        case tab(GroundTab)
        /// The page between two parts: on to the next.
        case partEnd
    }

    /// Whether the step is for this flight at all.
    enum Requires: Equatable {
        case always
        /// The aircraft logs its engine hours and the counter before the start is still to give.
        case engineHoursBefore
        case engineHoursAfter
        /// The story began with the Plan part (or before the part it starts at): its flight was planned and
        /// started on the ground.
        case fromPlan
        /// Fly on its own: the dry run started the flight.
        case notFromPlan
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
    var part: DryRunPart = .fly
    var screen: Screen = .cockpit

    /// The part, or Fly's chapter, whose habit it counts toward.
    enum Segment: Hashable {
        case part(DryRunPart)
        case chapter(Int)

        var habit: String? {
            switch self {
            case .part(let part): return part.habit
            case .chapter(let chapter): return DryRunChapters.habit(chapter)
            }
        }
    }

    var segment: Segment { part == .fly ? .chapter(chapter) : .part(part) }
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
            // START FLIGHT on the flight's page (done for the pilot when Fly is on its own), then the Cockpit it
            // opened.
            S(id: "startFlight", chapter: 1, kind: .act, target: .startFlight, veils: true, holds: true, moment: .now,
              done: .flightStarted, title: T.startFlightTitle, body: T.startFlightBody,
              screen: .flightPage),
            S(id: "cockpitAfterPlan", chapter: 1, kind: .look, target: nil, veils: false, holds: true, moment: .now,
              done: .next, requires: .fromPlan, title: T.cockpitAfterPlanTitle, body: T.cockpitAfterPlanBody),
            // 1 · Before you go
            S(id: "cockpit", chapter: 1, kind: .look, target: nil, veils: false, holds: true, moment: .now, done: .next,
              requires: .notFromPlan, title: T.cockpitTitle, body: T.cockpitBody),
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
            // The go-around where the flight was going took up circuits (6.4.0, st-14): the approach check on
            // the downwind, and the landing check from memory, which no card asks about after a circuit's
            // full stop: a tap records it.
            S(id: "approachAgain", chapter: 6, kind: .act, target: .check, veils: false, holds: true,
              moment: .shows(.check(.approach)), done: .checkDone(.approach), title: T.approachAgainTitle,
              body: T.approachAgainBody, upcoming: T.approachAgainUpcoming),
            S(id: "fullStop", chapter: 6, kind: .act, target: .first, veils: false, holds: true, moment: .final(2),
              done: .checkDone(.landing), title: T.fullStopTitle, body: T.fullStopBody),
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

    /// The guided flight's route, a triangle from `field` (the proposal's Q8): the first turning point 6 NM out,
    /// ahead of the runway, so the departure is straight out; the second 2.5 NM outside where the aerodrome's way
    /// in begins (its published arrival that joins before the downwind, else a 45° join to it), so the aircraft
    /// comes home by it and flies the downwind; both at 1,500 ft over the circuit. Each turn under 135°, the two
    /// points at least 2.5 NM apart: the first point swung off the runway's line until they are.
    static func route(from field: DryRunAerodrome) -> FlightPlan {
        let entry = field.guidedEntry
        let second = DryRunGeo.destination(from: entry.point, bearing: entry.outward, distance: 2.5 * DryRunGeo.metresPerNM)
        func turn(_ a: Double, _ b: Double) -> Double { abs(DryRunGeo.angleDifference(from: a, to: b)) }
        func first(swung offset: Double) -> CLLocationCoordinate2D {
            DryRunGeo.destination(from: field.reference, bearing: field.runwayHeading + offset, distance: 6 * DryRunGeo.metresPerNM)
        }
        // Away from the circuit first, then toward it, further each time.
        let away = -field.circuitSide.sign
        let offsets = [0.0] + stride(from: 20.0, through: 100, by: 20).flatMap { [away * $0, -away * $0] }
        let point = offsets.lazy.map(first(swung:)).first { candidate in
            DryRunGeo.distance(candidate, second) >= 2.5 * DryRunGeo.metresPerNM
                && turn(DryRunGeo.bearing(from: field.reference, to: candidate), DryRunGeo.bearing(from: candidate, to: second)) <= 135
                && turn(DryRunGeo.bearing(from: candidate, to: second), DryRunGeo.bearing(from: second, to: entry.point)) <= 135
        } ?? first(swung: away * 40)
        func aerodrome() -> FlightPlanWaypoint {
            var waypoint = FlightPlanWaypoint(name: field.ident, coordinate: field.reference)
            waypoint.pointKind = .aerodrome
            waypoint.sourceId = field.ident
            return waypoint
        }
        let altitude = (field.patternAltitudeFt + 1500).rounded()
        let home = aerodrome(), back = aerodrome()
        let one = FlightPlanWaypoint(name: L10n.DryRunCoach.turningPointNumber(1), coordinate: point, altitude: altitude)
        let two = FlightPlanWaypoint(name: L10n.DryRunCoach.turningPointNumber(2), coordinate: second, altitude: altitude)
        var plan = FlightPlan(name: L10n.DryRunCoach.flightName, waypoints: [home, one, two, back])
        plan.calculateRouteData()
        return plan
    }
}

/// The guided dry run's whole story: the Plan part, the flight (`DryRunChapters.steps`), Close out and the
/// Logbook, with a page between two parts. (6.4.0)
enum DryRunStory {
    static var steps: [DryRunCoachStep] {
        typealias S = DryRunCoachStep
        typealias T = L10n.DryRunCoach.Step
        let plan: [S] = [
            S(id: "today", chapter: 0, kind: .act, target: .planNewFlight, veils: true, holds: true, moment: .now,
              done: .screen(.planSheet), title: T.todayTitle, body: T.todayBody, part: .plan, screen: .today),
            S(id: "planSheet", chapter: 0, kind: .act, target: .createFlight, veils: true, holds: true,
              moment: .screen(.planSheet), done: .threadCreated, title: T.planSheetTitle, body: T.planSheetBody,
              part: .plan, screen: .planSheet),
            S(id: "flightPage", chapter: 0, kind: .look, target: .chapterBar, veils: false, holds: true,
              moment: .screen(.flightPage), done: .next, title: T.flightPageTitle, body: T.flightPageBody,
              part: .plan, screen: .flightPage),
            S(id: "chip", chapter: 0, kind: .act, target: .prepareChip, veils: true, holds: true, moment: .now,
              done: .chipTapped, title: T.chipTitle, body: T.chipBody, part: .plan, screen: .flightPage),
            S(id: "nextCard", chapter: 0, kind: .look, target: .nextCard, veils: false, holds: true, moment: .now,
              done: .next, title: T.nextCardTitle, body: T.nextCardBody, part: .plan, screen: .flightPage),
            S(id: "fuelRow", chapter: 0, kind: .act, target: .fuelRow, veils: true, holds: true, moment: .now,
              done: .screen(.fuelSheet), title: T.fuelRowTitle, body: T.fuelRowBody, part: .plan, screen: .flightPage),
            S(id: "fuelSheet", chapter: 0, kind: .act, target: nil, veils: false, holds: true,
              moment: .screen(.fuelSheet), done: .screenClosed(.fuelSheet), title: T.fuelSheetTitle,
              body: T.fuelSheetBody, part: .plan, screen: .fuelSheet),
            S(id: "link", chapter: 0, kind: .act, target: .notamLink, veils: true, holds: true, moment: .now,
              done: .linkTapped, title: T.linkTitle, body: T.linkBody, part: .plan, screen: .flightPage),
            S(id: "tickNotam", chapter: 0, kind: .act, target: .notamTick, veils: false, holds: true, moment: .now,
              done: .task(.notamChecked, .done), title: T.tickNotamTitle, body: T.tickNotamBody, part: .plan,
              screen: .flightPage),
            S(id: "notApplicable", chapter: 0, kind: .act, target: .flightPlanRow, veils: false, holds: true,
              moment: .now, done: .task(.flightPlanFiled, .notApplicable), title: T.notApplicableTitle,
              body: T.notApplicableBody, part: .plan, screen: .flightPage),
            partEnd(.plan, screen: .flightPage),
        ]
        let close: [S] = [
            partEnd(.fly, screen: .today, moment: .onTheGround),
            S(id: "openFlightPage", chapter: 0, kind: .act, target: .flightCard, veils: true, holds: true,
              moment: .now, done: .screen(.flightPage), title: T.openFlightPageTitle, body: T.openFlightPageBody,
              part: .closeOut, screen: .today),
            S(id: "closeOut", chapter: 0, kind: .look, target: .readiness, veils: false, holds: true,
              moment: .screen(.flightPage), done: .next, title: T.closeOutTitle, body: T.closeOutBody,
              part: .closeOut, screen: .flightPage),
            S(id: "logbookLine", chapter: 0, kind: .act, target: .logbookRow, veils: true, holds: true, moment: .now,
              done: .screen(.numbers), title: T.logbookLineTitle, body: T.logbookLineBody, part: .closeOut,
              screen: .flightPage),
            S(id: "numbers", chapter: 0, kind: .act, target: nil, veils: false, holds: true,
              moment: .screen(.numbers), done: .screenClosed(.numbers), title: T.numbersTitle, body: T.numbersBody,
              part: .closeOut, screen: .numbers),
            S(id: "debrief", chapter: 0, kind: .act, target: .debriefTick, veils: false, holds: true, moment: .now,
              done: .task(.debriefWritten, .done), title: T.debriefTitle, body: T.debriefBody, part: .closeOut,
              screen: .flightPage),
            S(id: "finish", chapter: 0, kind: .act, target: .finish, veils: true, holds: true, moment: .now,
              done: .threadFinished, title: T.finishTitle, body: T.finishBody, part: .closeOut, screen: .flightPage),
            partEnd(.closeOut, screen: .today),
        ]
        let logbook: [S] = [
            S(id: "logbookTab", chapter: 0, kind: .act, target: nil, veils: false, holds: true, moment: .now,
              done: .tab(.logbook), title: T.logbookTabTitle, body: T.logbookTabBody, part: .logbook, screen: .today),
            S(id: "dashboard", chapter: 0, kind: .look, target: .logbookDashboard, veils: false, holds: true,
              moment: .tab(.logbook), done: .next, title: T.dashboardTitle, body: T.dashboardBody, part: .logbook,
              screen: .logbook),
            S(id: "openLoggedFlight", chapter: 0, kind: .act, target: .logbookFlight, veils: true, holds: true,
              moment: .now, done: .screen(.flightDetail), title: T.openLoggedFlightTitle,
              body: T.openLoggedFlightBody, part: .logbook, screen: .logbook),
            S(id: "track", chapter: 0, kind: .look, target: .flightTrack, veils: false, holds: true,
              moment: .screen(.flightDetail), done: .next, title: T.trackTitle, body: T.trackBody, part: .logbook,
              screen: .flightDetail),
            S(id: "checks", chapter: 0, kind: .look, target: .flightChecks, veils: false, holds: true, moment: .now,
              done: .next, title: T.checksTitle, body: T.checksBody, part: .logbook, screen: .flightDetail),
            S(id: "exports", chapter: 0, kind: .look, target: .flightExport, veils: false, holds: true, moment: .now,
              done: .next, title: T.exportsTitle, body: T.exportsBody, part: .logbook, screen: .flightDetail),
        ]
        return plan + DryRunChapters.steps + close + logbook
    }

    /// The page after `part`: on to the next part, or stop there.
    private static func partEnd(_ part: DryRunPart, screen: DryRunCoachStep.Screen,
                                moment: DryRunCoachStep.Moment = .now) -> DryRunCoachStep {
        DryRunCoachStep(id: "end.\(part)", chapter: 0, kind: .partEnd, target: nil, veils: false, holds: true,
                        moment: moment, done: .partEnd, title: L10n.DryRunCoach.partDone(part.title),
                        body: part.next.map(Self.nextBody) ?? "", part: part, screen: screen)
    }

    private static func nextBody(_ part: DryRunPart) -> String {
        switch part {
        case .plan: return ""
        case .fly: return L10n.DryRunCoach.nextFly
        case .closeOut: return L10n.DryRunCoach.nextClose
        case .logbook: return L10n.DryRunCoach.nextLogbook
        }
    }

    /// Where `start` begins in `steps`: the part's first step, Fly's chapter's first over the Cockpit (the
    /// flight already started for it when Fly is on its own).
    static func startIndex(of start: DryRunStart, in steps: [DryRunCoachStep]) -> Int {
        switch start.part {
        case .plan:
            return 0
        case .fly:
            return steps.firstIndex { $0.part == .fly && $0.chapter == start.chapter && $0.screen == .cockpit
                && $0.requires != .fromPlan } ?? 0
        case .closeOut, .logbook:
            // After the page that ends the part before it.
            return steps.firstIndex { $0.part == start.part && $0.kind != .partEnd } ?? 0
        }
    }
}

/// The guided dry run under way: which step shows, and when the next one does. Ticked by the session after each
/// fix, and on the ground as the pilot goes; holds the flight while a step that holds shows. Started at a part
/// or a chapter, the flight is first taken there behind a cover, as fast as it can be flown, the earlier steps
/// done for the pilot as the pilot would (`actAsPilot`), nothing shown and nothing asked on the way; the start's
/// first step then shows (the proposal's Q6).
@MainActor
final class DryRunCoach: ObservableObject {
    let steps: [DryRunCoachStep]
    let start: DryRunStart
    /// Where `start` begins in `steps`.
    let startIndex: Int
    /// The story's flight was planned on the ground (the story began with the Plan part, or after it): not Fly
    /// on its own, whose flight the dry run starts.
    let fromPlan: Bool

    /// The step showing, if any.
    @Published private(set) var step: DryRunCoachStep?
    /// The parts and Fly's chapters gone through, in order, for their habits.
    @Published private(set) var segmentsDone: [DryRunCoachStep.Segment] = []
    /// Getting to where it starts, behind the cover.
    @Published private(set) var isFastForwarding: Bool
    /// "Show me again": the ring pulses once more.
    @Published private(set) var pulse = 0
    /// The engine hours' prompt over the Cockpit, as `FlightView` shows it.
    @Published var hourMeter: DryRunCoachStep.HourMeterPrompt?
    /// The ground's screens on show, as they say so (`dryRunCoachScreen`).
    @Published private(set) var screens: Set<DryRunCoachStep.Screen> = []
    /// The Cockpit's page, from `FlightView`.
    var page: CockpitPage = .checklist

    private(set) var index = 0
    private var finalsSeen = 0
    private var wasOnFinal = false
    /// Where a do step's count starts: the items checked, the checks deferred, the taps.
    private var baseline = 0
    /// The step's prompt came up: its closing finishes the step.
    private var hourMeterSeen = false
    /// The step's screen came up: its closing finishes the step.
    private var screenSeen = false
    private var chipTaps = 0
    private var linkTaps = 0

    init(start: DryRunStart = .story, steps: [DryRunCoachStep] = DryRunStory.steps) {
        self.steps = steps
        self.start = start
        startIndex = DryRunStory.startIndex(of: start, in: steps)
        fromPlan = start.part != .fly
        isFastForwarding = startIndex > 0
    }

    var isFinished: Bool { index >= steps.count }

    /// The next step for the pilot to do, while none shows: what the folded card names after "Next for you".
    var upcoming: DryRunCoachStep? {
        guard step == nil else { return nil }
        return steps[min(index, steps.count)...].first { $0.kind == .act && $0.upcoming != nil }
    }

    /// Next, on a look step or a part's end.
    func next() {
        guard let step, step.kind != .act else { return }
        complete(step)
    }

    func showAgain() { pulse += 1 }

    /// The part the story is in: the step's, or between two steps the one ahead's.
    var part: DryRunPart {
        step?.part ?? (index < steps.count ? steps[index].part : steps.last?.part) ?? .plan
    }

    // MARK: The ground's screens and taps

    func show(_ screen: DryRunCoachStep.Screen) {
        if !screens.contains(screen) { screens.insert(screen) }
    }

    func hide(_ screen: DryRunCoachStep.Screen) {
        if screens.contains(screen) { screens.remove(screen) }
    }

    /// A chapter's chip tapped on the flight's page.
    func noteChip(_ chapter: ThreadChapter) {
        if chapter == .prepare { chipTaps += 1 }
    }

    /// A link the dry run kept from opening.
    func noteLink() { linkTaps += 1 }

    /// Where the flight is: a step's moment come, a step done. Returns whether the flight should wait.
    @discardableResult
    func tick(_ session: DryRunSession) -> Bool {
        let fullStopCard = session.world.detector.pendingFullStop != nil
        if fullStopCard != fullStopCardUp { fullStopCardUp = fullStopCard }
        if session.isOnFinal, !wasOnFinal { finalsSeen += 1 }
        wasOnFinal = session.isOnFinal
        for _ in 0...steps.count {
            if let step {
                if hourMeter != nil { hourMeterSeen = true }
                if case .screenClosed(let screen) = step.done, screens.contains(screen) { screenSeen = true }
                if isDone(step, session) { complete(step) } else { return step.holds }
            }
            guard index < steps.count else { return false }
            let candidate = steps[index]
            guard applies(candidate, session) else {
                index += 1
                continue
            }
            if isFastForwarding, index < startIndex, candidate.kind == .partEnd {
                index += 1
                continue
            }
            guard reached(candidate.moment, session) else { return false }
            if isFastForwarding {
                if index < startIndex {
                    // Before where it starts: done for the pilot, at once, as the pilot would.
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
            screenSeen = false
            step = candidate
        }
        return step?.holds ?? false
    }

    /// Where the step's ring goes, as the Cockpit stands: `.check` is the first slot on MAP and ROUTE (it
    /// names the check), CHECK or NEXT on CHECKLIST.
    func resolvedTarget(of step: DryRunCoachStep) -> DryRunCoachStep.Target? {
        if step.target == .landedCard, fullStopCardUp { return .eventConfirm }
        guard step.target == .check else { return step.target }
        return page == .checklist ? .primary : .first
    }

    /// The detector's full-stop card is up (circuits, or circuits taken up): the landing's card is that one.
    private(set) var fullStopCardUp = false

    private func complete(_ done: DryRunCoachStep) {
        step = nil
        index += 1
        guard done.kind != .partEnd else { return }
        let next = steps[index...].first { $0.kind != .partEnd }
        if next?.segment != done.segment, !segmentsDone.contains(done.segment) { segmentsDone.append(done.segment) }
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
        case .fromPlan: return fromPlan
        case .notFromPlan: return !fromPlan
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
        // The LANDED card on a route flight; the full stop's card once circuits were taken up (a go-around
        // where the flight was going, 6.4.0).
        case .landedCard: return appState.landedCard != nil || session.world.detector.pendingFullStop != nil
        // On the way to where it starts, no screen shows: the ground's moments come as the steps are done.
        case .screen(let screen): return isFastForwarding || screens.contains(screen)
        case .onTheGround: return session.hasFlown && !appState.isFlightActive
        case .tab(let tab): return isFastForwarding || appState.groundTab == tab
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
        case .chipTapped:
            return chipTaps
        case .linkTapped:
            return linkTaps
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
        case .itemChecked, .deferred, .chipTapped, .linkTapped: return count(for: step, session) > baseline
        case .engineStarted: return appState.engineStartTime != nil
        case .linedUp: return appState.lineUpTime != nil
        case .page(let page): return self.page == page
        case .checkDone(let check):
            return appState.currentPhase.rawValue > check.rawValue
                || (appState.currentPhase == check && appState.currentCheckIsDone)
                || appState.getPhaseStatus(check) == .completed
        case .finalChoice(let landing): return session.finalChoice == landing
        case .goAroundAnswered: return session.world.detector.pendingGoAround == nil
        case .landedAnswered: return appState.landedCard == nil && session.world.detector.pendingFullStop == nil
        case .engineShutdown: return appState.engineShutdownTime != nil
        case .flightEnded: return !appState.isFlightActive
        case .screen(let screen): return screens.contains(screen)
        case .screenClosed(let screen): return screenSeen && !screens.contains(screen)
        case .threadCreated: return session.storyThread != nil
        case .task(let key, let state): return session.storyThread?.tasks.first { $0.key == key }?.state == state
        case .flightStarted: return appState.isFlightActive || session.hasFlown
        case .threadFinished: return session.storyThread?.state == .done
        case .tab(let tab): return appState.groundTab == tab
        case .partEnd: return false
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
            session.endFlight()
        case .finalChoice(let landing):
            session.finalChoice = landing
        case .goAroundAnswered:
            if let event = session.world.detector.pendingGoAround {
                FlightEventConfirmationOverlay.confirm(event, appState: appState, detector: session.world.detector)
            }
        case .landedAnswered:
            if appState.landedCard != nil {
                appState.answerLandedCard(.yes)
            } else if let event = session.world.detector.pendingFullStop {
                FlightEventConfirmationOverlay.confirm(event, appState: appState, detector: session.world.detector)
            }
        case .engineShutdown:
            appState.recordEngineShutdown()
        case .threadCreated:
            session.planStoryFlight()
        case .task(let key, let state):
            session.setStoryTask(key, to: state)
        case .flightStarted:
            session.startFlightFromGround()
        case .threadFinished:
            session.finishStoryThread()
        case .tab(let tab):
            appState.groundTab = tab
        case .next, .hourMeterClosed, .screen, .screenClosed, .chipTapped, .linkTapped, .partEnd:
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
