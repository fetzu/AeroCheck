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

    /// Where it was asked to stop: no more steps, and the screenshot tour told the dry run holds there.
    private func hold() {
        timer?.invalidate()
        CaptureSignal.post()
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
            hold()
            return
        case .cruise? where airborneSince.map({ FlightClock.now.timeIntervalSince($0) > 60 }) == true:
            session.pause()
            hold()
            return
        case .over? where generator.mark("stopped") != nil:
            session.stop()
            hold()
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
                hold()
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
                hold()
                return
            }
            if DryRunFrames.current?.holds(step, coach: coach, appState: appState) == true { return }
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
        } else if appState.currentPhase == .lineUp, !appState.currentCheckIsDone {
            DryRunCoach.workThroughCurrentCheck(appState)
        } else if generator.mark("stopped") != nil, session.setup.isCircuits {
            appState.goToPhase(.beforeDeparture)
        }
    }
}

/// DEV-ONLY: the guided flight captured card by card, for the website's dry run (`AEROCHECK_DRYRUN_FRAMES=<folder>`,
/// `AEROCHECK_DRYRUN_FRAMES_ONLY=<step ids, in order>`, with the autopilot flying). At each named card the autopilot
/// waits; the app writes `<nn>-<id>.json` (the card's words, where its ring is, in the screen's points) and
/// `<nn>-<id>.want`, and goes on once the host has answered with `<nn>-<id>.done`. The card itself is left out of the
/// frame: the page sets its words beside the screen, at a size a visitor can read. The veil and the ring stay. (6.10.0)
@MainActor
final class DryRunFrames {
    static let current: DryRunFrames? = {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["AEROCHECK_DRYRUN_FRAMES"], !path.isEmpty else { return nil }
        let only = (env["AEROCHECK_DRYRUN_FRAMES_ONLY"] ?? "").split(separator: ",").map(String.init)
        return DryRunFrames(folder: URL(fileURLWithPath: path, isDirectory: true), only: only)
    }()

    /// The card's opacity in a frame.
    nonisolated static var cardOpacity: Double {
        ProcessInfo.processInfo.environment["AEROCHECK_DRYRUN_FRAMES"] == nil ? 1 : 0
    }

    private let folder: URL
    private let only: [String]
    private var rings: [String: CGRect] = [:]
    private var taken: Set<String> = []
    private var current: (id: String, since: Date, name: String?)?

    private init(folder: URL, only: [String]) {
        self.folder = folder
        self.only = only
    }

    /// The ring as the veil draws it, in the window: `nil` for a card that rings nothing.
    func note(_ id: String, ring: CGRect?) {
        rings[id] = ring
    }

    /// Whether the autopilot waits on this card: until its frame is taken.
    func holds(_ step: DryRunCoachStep, coach: DryRunCoach, appState: AppState) -> Bool {
        guard let index = only.firstIndex(of: step.id), !taken.contains(step.id) else { return false }
        guard let shown = current, shown.id == step.id else {
            current = (step.id, Date(), nil)
            return true
        }
        guard let name = shown.name else {
            // The screen settled: the sheet up, the ring in place, the map's tiles drawn.
            guard Date().timeIntervalSince(shown.since) >= (step.screen == .cockpit ? 2.5 : 1.5) else { return true }
            let name = String(format: "%02d-%@", index + 1, step.id)
            write(step, appState: appState, name: name)
            current = (step.id, shown.since, name)
            return true
        }
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(name).done").path) else { return true }
        taken.insert(step.id)
        current = nil
        return false
    }

    private func write(_ step: DryRunCoachStep, appState: AppState, name: String) {
        let screen = UIScreen.main.bounds.size
        var record: [String: Any] = [
            "id": step.id, "part": step.part.rawValue, "partTitle": step.part.title, "title": step.title,
            "body": step.text(appState), "kind": "\(step.kind)", "width": screen.width, "height": screen.height,
        ]
        if let ring = rings[step.id] {
            record["ring"] = ["x": ring.minX, "y": ring.minY, "width": ring.width, "height": ring.height]
        }
        let json = (try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        try? json.write(to: folder.appendingPathComponent("\(name).json"))
        FileManager.default.createFile(atPath: folder.appendingPathComponent("\(name).want").path, contents: Data())
    }
}

extension View {
    /// What the DEBUG autopilot taps on this screen (`DryRunAutopilot.Tap`).
    func dryRunAutopilotTap(_ perform: @escaping (DryRunAutopilot.Tap) -> Void) -> some View {
        onReceive(DryRunAutopilot.taps) { perform($0) }
    }
}
#endif
