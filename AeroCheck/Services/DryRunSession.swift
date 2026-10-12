import Foundation

// MARK: - Dry run (6.4.0): one under way

/// A dry run under way: its world, the flight its generator flies, and the clock both run on. Every fix is
/// fed in order as the clock reaches it, at whatever pace (one a second of the dry run's time, none skipped
/// at 10×), and the generator's questions are answered from what the pilot does in the world's Cockpit:
/// ENGINE START lets it go, READY FOR LINE UP takes it onto the runway, the end of the after landing check
/// sends it round again or to the parking. (6.4.0)
@MainActor
final class DryRunSession: ObservableObject, Identifiable {
    let id = UUID()
    let world: DryRunWorld
    let generator: DryRunGenerator
    let aerodrome: DryRunAerodrome
    let circuits: Bool

    /// Times the wall clock's pace; paused or not, the pace it runs at.
    @Published private(set) var rate: Double
    /// Paused: the clock stopped, the aircraft where it is. The app leaving the foreground pauses it (D2).
    @Published private(set) var isPaused = false
    @Published private(set) var hasEnded = false
    /// What the aircraft does at the end of each final, in order; a full stop once they're used.
    var landings: [DryRunGenerator.Landing] = []

    /// When it began, on its clock: fix `t` is due `t` seconds later.
    private(set) var start: Date?
    /// The next fix, decided and not due yet.
    private var pending: DryRunFix?
    private var timer: Timer?

    init(world: DryRunWorld, aerodrome: DryRunAerodrome, circuits: Bool, rate: Double,
         performance: DryRunPerformance = .wt9, seed: UInt64 = .random(in: 1...UInt64.max)) {
        self.world = world
        self.aerodrome = aerodrome
        self.circuits = circuits
        self.rate = rate
        generator = DryRunGenerator(departure: aerodrome, mission: .circuits, performance: performance, seed: seed)
        generator.pilot = DryRunGenerator.Pilot(
            mayGo: { [weak self] hold in
                guard let appState = self?.world.appState else { return false }
                return Self.mayGo(from: hold, engineStarted: appState.engineStartTime != nil,
                                  phase: appState.currentPhase)
            },
            landing: { [weak self] _ in
                guard let self, !landings.isEmpty else { return .fullStop }
                return landings.removeFirst()
            },
            afterFullStop: { [weak self] _ in
                guard let self else { return nil }
                return Self.afterFullStop(phase: world.appState.currentPhase, circuits: circuits)
            })
    }

    // MARK: The pilot's answers

    /// The generator may go on from `hold`: the engine started, or the pilot at the line-up check or past it.
    static func mayGo(from hold: DryRunGenerator.Hold, engineStarted: Bool, phase: ChecklistPhase) -> Bool {
        switch hold {
        case .engineStart: return engineStarted
        case .lineUp: return phase.rawValue >= ChecklistPhase.lineUp.rawValue && phase.rawValue < ChecklistPhase.landing.rawValue
        case .parked: return false
        }
    }

    /// Stopped on the runway after a full stop: round again once the pilot is at the check before departure
    /// (NEW CIRCUIT) or the line-up, off to the parking once at the engine shutdown (PARKING) or after; a
    /// flight that isn't circuits vacates at once. A check of the air still showing (the pilot didn't follow
    /// the circuit) waits for the pilot to catch up. Nil: not yet.
    static func afterFullStop(phase: ChecklistPhase, circuits: Bool) -> DryRunGenerator.AfterFullStop? {
        switch phase {
        case .beforeDeparture, .lineUp: return .goAgain
        case .shutdown, .hangar: return .vacate
        case .afterLanding: return circuits ? nil : .vacate
        default: return nil
        }
    }

    // MARK: Running

    /// Starts the clock at `rate` from `now` and the flight in the world, then feeds it. False if the world's
    /// AppState refused the flight (nothing then runs).
    @discardableResult
    func begin(airports: AirportDataService, now: Date = Date()) -> Bool {
        guard start == nil else { return true }
        start = now
        FlightClock.runVirtual(from: now, rate: rate)
        guard world.startFlight(circuits: circuits, aerodromes: [aerodrome.airport], airports: airports) else {
            end()
            return false
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.feedDueFixes(upTo: FlightClock.now) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        return true
    }

    /// Every fix due by `now`, in order, through the world's GPS; at most `cap` at once, so a stall catches up
    /// over a few ticks rather than in one.
    func feedDueFixes(upTo now: Date, cap: Int = 50) {
        guard let start, !hasEnded else { return }
        for _ in 0..<cap {
            let fix = pending ?? generator.nextFix()
            let due = start.addingTimeInterval(TimeInterval(fix.t))
            guard due <= now else {
                pending = fix
                return
            }
            pending = nil
            world.location.feedDryRunFix(fix.location(at: due))
        }
    }

    func setRate(_ newRate: Double) {
        rate = max(0.25, newRate)
        if !isPaused { FlightClock.setVirtualRate(rate) }
    }

    func pause() {
        guard !isPaused, !hasEnded else { return }
        isPaused = true
        FlightClock.setVirtualRate(0)
    }

    func resume() {
        guard isPaused, !hasEnded else { return }
        isPaused = false
        FlightClock.setVirtualRate(rate)
    }

    /// The end, whatever the flight was: the feed stopped, the world dropped, the wall clock back.
    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        timer?.invalidate()
        timer = nil
        world.tearDown()
        FlightClock.endVirtual()
    }
}

// MARK: - The one dry run

/// The dry run under way, if any: one at a time, never during a real flight, and no real flight during one
/// (`FlightLauncher`, the start-flight link). `ContentView` shows its Cockpit over the app. (6.4.0)
@MainActor
final class DryRunCenter: ObservableObject {
    static let shared = DryRunCenter()

    @Published private(set) var session: DryRunSession?
    /// What waits for the dry run to end (`whenNotRunning`).
    private var afterEnd: [() -> Void] = []

    var isRunning: Bool { session != nil }

    /// `action` now, or once the dry run under way has ended.
    func whenNotRunning(_ action: @escaping () -> Void) {
        if isRunning { afterEnd.append(action) } else { action() }
    }

    /// Circuits at `aerodrome` in a world of their own, on a clock at `rate`. False when a dry run or a real
    /// flight is already under way, or the flight didn't start.
    @discardableResult
    func beginCircuits(at aerodrome: DryRunAerodrome, settings: AppSettings, airports: AirportDataService,
                       isFlightActive: Bool, rate: Double, landings: [DryRunGenerator.Landing] = []) async -> Bool {
        guard session == nil, !isFlightActive else { return false }
        // Where the detector finds the aerodrome, and the map its frequencies (the GPS waits for none of it).
        await airports.ensureLoaded()
        guard session == nil else { return false }
        let session = DryRunSession(world: DryRunWorld(settings: settings), aerodrome: aerodrome,
                                    circuits: true, rate: rate)
        session.landings = landings
        guard session.begin(airports: airports) else { return false }
        self.session = session
        AppLog.general.publicLine("Dry run started")
        return true
    }

    func end() {
        guard let session else { return }
        session.end()
        self.session = nil
        AppLog.general.publicLine("Dry run ended")
        let waiting = afterEnd
        afterEnd = []
        waiting.forEach { $0() }
    }
}
