import Foundation
import Combine
import SwiftUI

#if DEBUG
/// DEV-ONLY: a dry run flown with no hand on the screen, for a check or a capture (`AEROCHECK_DRYRUN`, launched
/// by `ContentView`). It does what the pilot would: ENGINE START, READY FOR LINE UP at the holding point, round
/// again after a full stop (circuits) or to the parking; in the guided flight, what each step asks. `stop`: where it stops and leaves the dry run as it
/// is: "final" (paused on the first final, the card up), "cruise" (paused a minute after the take-off), "over"
/// (the dry run's page after the first full stop); in the guided flight "step:<id>" (its card up, left for the
/// hand) and "after:<id>" (the step done, then paused a few seconds on, the folded card showing). (6.4.0)
@MainActor
final class DryRunAutopilot {
    enum Stop: Equatable {
        case final, cruise, over
        case step(String)
        case after(String)

        init?(_ text: String) {
            switch text {
            case "final": self = .final
            case "cruise": self = .cruise
            case "over": self = .over
            default:
                if text.hasPrefix("step:") { self = .step(String(text.dropFirst(5))) }
                else if text.hasPrefix("after:") { self = .after(String(text.dropFirst(6))) }
                else { return nil }
            }
        }
    }

    /// The one flying, held while it does.
    static var current: DryRunAutopilot?

    /// What the autopilot does on the ground in place of a tap: the screens hear it (`dryRunAutopilotTap`).
    enum Tap: Equatable {
        case open(DryRunCoachStep.Screen)
        case close(DryRunCoachStep.Screen)
        case createFlight
    }

    static let taps = PassthroughSubject<Tap, Never>()

    private let stop: Stop?
    private var timer: Timer?
    private var airborneSince: Date?
    private var sawSession = false
    /// "after:<id>": when the step was done, on the wall clock.
    private var doneAt: Date?
    /// The step on show, and since when (wall clock).
    private var stepId: String?
    private var stepSince = Date()

    init(stop: Stop?) {
        self.stop = stop
    }

    func fly() {
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Self.current = self
    }

    private func step() {
        guard let session = DryRunCenter.shared.session, session.state == .flying else {
            // The guided flight is asked for, then begun by its presenter: not there yet is not over.
            if sawSession || DryRunCenter.shared.session != nil { timer?.invalidate() }
            return
        }
        sawSession = true
        let appState = session.world.appState
        let generator = session.generator
        if generator.isAirborne, airborneSince == nil { airborneSince = FlightClock.now }

        switch stop {
        case .final? where session.isOnFinal:
            session.pause()
            timer?.invalidate()
            return
        case .cruise? where airborneSince.map({ FlightClock.now.timeIntervalSince($0) > 60 }) == true:
            session.pause()
            timer?.invalidate()
            return
        case .over? where generator.mark("stopped") != nil:
            session.stop()
            timer?.invalidate()
            return
        default:
            break
        }

        // The guided flight: what each step asks, as the pilot would (the engine hours' prompt left out: a guided
        // dry run flown by the autopilot doesn't log them).
        if let coach = session.coach {
            // The engine hours' prompt is the Cockpit's, for a hand: off, unless the stop is at its card.
            if stop != .step("hoursBefore"), stop != .step("hoursAfter") { appState.settings.logEngineHours = false }
            if let doneAt, Date().timeIntervalSince(doneAt) > 3 {
                session.pause()
                timer?.invalidate()
                return
            }
            guard doneAt == nil, let step = coach.step, !session.isPaused else {
                // The screen the app would open by itself (the flight's page once created): open.
                if coach.step == nil, coach.index < coach.steps.count,
                   case .screen(let screen) = coach.steps[coach.index].moment, !coach.screens.contains(screen) {
                    Self.taps.send(.open(screen))
                }
                return
            }
            if case .step(let id)? = stop, step.id == id {
                timer?.invalidate()
                return
            }
            if step.id != stepId {
                stepId = step.id
                stepSince = Date()
            }
            // A sheet still coming up ignores the tap that closes it (and its state, already nil, never closes
            // it after): on the ground the autopilot waits a second, as a hand would.
            if step.screen != .cockpit, Date().timeIntervalSince(stepSince) < 1 { return }
            switch step.done {
            case .next, .partEnd: coach.next()
            case .screen(let screen): Self.taps.send(.open(screen))
            case .screenClosed(let screen): Self.taps.send(.close(screen))
            case .threadCreated: Self.taps.send(.createFlight)
            case .chipTapped: coach.noteChip(.prepare)
            case .linkTapped: coach.noteLink()
            case .fullTanksTapped: coach.noteFullTanks()
            case .threadFinished:
                coach.actAsPilot(step, session)
                Self.taps.send(.close(.flightPage))
            default:
                if step.kind == .look { coach.next() } else { coach.actAsPilot(step, session) }
            }
            if case .after(let id)? = stop, step.id == id { doneAt = Date() }
            return
        }

        // A route's landing: the after landing check, so the aircraft leaves the runway.
        if !session.setup.isCircuits, !generator.isAirborne, generator.mark("touchdown") != nil,
           appState.currentPhase.rawValue < ChecklistPhase.afterLanding.rawValue {
            appState.goToPhase(.afterLanding)
        }
        guard generator.isWaiting, !session.isPaused else { return }
        if appState.engineStartTime == nil {
            appState.recordEngineStart()
        } else if appState.currentPhase.rawValue < ChecklistPhase.lineUp.rawValue {
            appState.goToPhase(.beforeDeparture)
            appState.nextPhase()
        } else if generator.mark("stopped") != nil, session.setup.isCircuits {
            appState.goToPhase(.beforeDeparture)
        }
    }
}

extension View {
    /// What the DEBUG autopilot taps on this screen (`DryRunAutopilot.Tap`).
    func dryRunAutopilotTap(_ perform: @escaping (DryRunAutopilot.Tap) -> Void) -> some View {
        onReceive(DryRunAutopilot.taps) { perform($0) }
    }
}
#endif
