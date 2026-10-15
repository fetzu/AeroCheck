import Foundation

#if DEBUG
/// DEV-ONLY: a dry run flown with no hand on the screen, for a check or a capture (`AEROCHECK_DRYRUN`, launched
/// by `ContentView`). It does what the pilot would: ENGINE START, READY FOR LINE UP at the holding point, round
/// again after a full stop (circuits) or to the parking. `stop`: where it stops and leaves the dry run as it
/// is: "final" (paused on the first final, the card up), "cruise" (paused a minute after the take-off), "over"
/// (the dry run's page after the first full stop). (6.4.0)
@MainActor
final class DryRunAutopilot {
    enum Stop: String {
        case final, cruise, over
    }

    /// The one flying, held while it does.
    static var current: DryRunAutopilot?

    private let stop: Stop?
    private var timer: Timer?
    private var airborneSince: Date?

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
            timer?.invalidate()
            return
        }
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
#endif
