import Foundation

// MARK: - Dry run (6.4.0): one under way

/// A dry run under way: its world, the flight its generator flies, and the clock both run on. Every fix is
/// fed in order as the clock reaches it, at whatever pace (one a second of the dry run's time, none skipped
/// at 10×), and the generator's questions are answered from what the pilot does in the world's Cockpit:
/// ENGINE START lets it go, READY FOR LINE UP takes it onto the runway, the card on final decides how the
/// final ends, the end of the after landing check sends it round again or to the parking. A Direct To or a
/// divert made in the Cockpit is what it flies next. When the world's flight ends, the dry run is over: its
/// summary is kept, the world dropped. (6.4.0)
@MainActor
final class DryRunSession: ObservableObject, Identifiable {
    enum State: Equatable {
        case flying
        case over(DryRunSummary)
    }

    let id = UUID()
    let world: DryRunWorld
    let generator: DryRunGenerator
    let setup: DryRunSetup
    /// The guided flight's coach; nil in free practice.
    let coach: DryRunCoach?
    /// An aerodrome the app's data gives, for a divert; nil without a runway to fly.
    var resolveAerodrome: (String) -> DryRunAerodrome? = { _ in nil }
    /// The guided flight flown to its end: the app's Today card then stops offering it (`DryRunCenter`).
    var onGuidedFinished: (() -> Void)?

    /// Times the wall clock's pace; paused or not, the pace it runs at.
    @Published private(set) var rate: Double
    /// Paused: the clock stopped, the aircraft where it is. The app leaving the foreground pauses it (D2).
    @Published private(set) var isPaused = false
    /// The aircraft waits for the pilot: the engine start, the line-up, after a full stop, parked.
    @Published private(set) var isWaiting = false
    /// On final, its end still the pilot's to choose (the card on final).
    @Published private(set) var isOnFinal = false
    /// How this final ends; a full stop at the start of each.
    @Published var finalChoice: DryRunGenerator.Landing = .fullStop
    /// Next check: the flight sped through until a check falls due, the aircraft waits, or the final.
    @Published private(set) var isSkipping = false
    /// The coach's step holds the flight until the pilot has done it, or read it.
    @Published private(set) var isCoachHolding = false
    @Published private(set) var state: State = .flying
    private(set) var hasEnded = false

    /// When it began, on its clock: fix `t` is due `t` seconds later.
    private(set) var start: Date?
    /// The next fix, decided and not due yet.
    private var pending: DryRunFix?
    private var timer: Timer?
    private var landings: [DryRunGenerator.Landing]

    // What the summary reads, kept as the flight goes: the phases' state is gone once it has ended.
    private var checksDone = 0
    private var diverted = false

    // The route as the Cockpit last left it.
    private var seenWaypointIndex: Int?
    private var seenDiversion: String?

    // Next check.
    private var skipFrom: (cues: CueMark, at: Date)?

    /// What Next check watches of the cues: a leg begun, a cue fired, a check owed. Not whether the detector
    /// has a field to time the checks from, which turns once on the ground.
    struct CueMark: Equatable {
        let legs: Int
        let fired: Set<FlightCue>
        let owed: Set<ChecklistPhase>

        init(_ cues: FlightCueState) {
            legs = cues.legs
            fired = Set(cues.fired.keys)
            owed = Set(cues.owed.keys)
        }
    }
    static let skipRate = 30.0
    /// Never longer than this of the dry run's time: a check that never falls due doesn't run it away.
    static let skipLimit: TimeInterval = 15 * 60

    init(world: DryRunWorld, setup: DryRunSetup, performance: DryRunPerformance = .wt9,
         seed: UInt64 = .random(in: 1...UInt64.max)) {
        self.world = world
        self.setup = setup
        rate = setup.rate
        landings = setup.landings
        coach = setup.guidedChapter.map { DryRunCoach(startChapter: $0) }
        generator = DryRunGenerator(departure: setup.departure, mission: setup.generatorMission,
                                    performance: performance, seed: seed)
        generator.pilot = DryRunGenerator.Pilot(
            mayGo: { [weak self] hold in
                guard let appState = self?.world.appState else { return false }
                return Self.mayGo(from: hold, engineStarted: appState.engineStartTime != nil,
                                  phase: appState.currentPhase)
            },
            landing: { [weak self] _ in
                guard let self else { return .fullStop }
                return landings.isEmpty ? finalChoice : landings.removeFirst()
            },
            afterFullStop: { [weak self] _ in
                guard let self else { return nil }
                return Self.afterFullStop(phase: self.world.appState.currentPhase, circuits: self.setup.isCircuits)
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

    /// Stopped on the runway after a full stop: in circuits, round again once the pilot is at the check before
    /// departure (NEW CIRCUIT) or the line-up; off to the parking once at the engine shutdown (PARKING) or
    /// after, or at the after landing check of a flight that isn't circuits. A check still showing from
    /// before (the pilot didn't follow the flight) waits for the pilot to catch up. Nil: not yet.
    static func afterFullStop(phase: ChecklistPhase, circuits: Bool) -> DryRunGenerator.AfterFullStop? {
        switch phase {
        case .beforeDeparture, .lineUp: return circuits ? .goAgain : nil
        case .shutdown, .hangar: return .vacate
        case .afterLanding: return circuits ? nil : .vacate
        default: return nil
        }
    }

    // MARK: Running

    /// Starts the clock at the setup's pace from `now` and the flight in the world, then feeds it. False if
    /// the world's AppState refused the flight (nothing then runs).
    @discardableResult
    func begin(airports: AirportDataService, now: Date = Date()) -> Bool {
        guard start == nil else { return true }
        start = now
        FlightClock.runVirtual(from: now, rate: coach?.isPreluding == true ? Self.skipRate : rate)
        guard world.startFlight(circuits: setup.isCircuits, aerodromes: setup.aerodromes.map(\.airport),
                                airports: airports) else {
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
    /// over a few ticks rather than in one. Then what the Cockpit did meanwhile.
    func feedDueFixes(upTo now: Date, cap: Int = 50) {
        guard let start, state == .flying else { return }
        for _ in 0..<cap {
            let fix = pending ?? generator.nextFix()
            let due = start.addingTimeInterval(TimeInterval(fix.t))
            guard due <= now else {
                pending = fix
                break
            }
            pending = nil
            world.location.feedDryRunFix(fix.location(at: due))
        }
        observe()
    }

    /// The Cockpit's side: the flight ended, the generator's state for the band and the card, the route
    /// changed, Next check reached its check, what the summary keeps.
    private func observe() {
        let appState = world.appState
        guard appState.isFlightActive else {
            finish()
            return
        }
        let onFinal = generator.isOnFinal
        if onFinal != isOnFinal {
            if onFinal { finalChoice = .fullStop }
            isOnFinal = onFinal
        }
        checksDone = ChecklistPhase.allCases.filter { appState.getPhaseStatus($0) == .completed }.count
        followRoute()
        stepSkip()
        if let coach {
            let hold = coach.tick(self)
            if hold != isCoachHolding { isCoachHolding = hold }
        }
        let waiting = generator.isWaiting || isCoachHolding
        if waiting != isWaiting { isWaiting = waiting }
        applyRate()
    }

    /// The clock's pace for where the dry run stands: stopped while paused or held by the coach, Next
    /// check's or the guided flight's way to its chapter at 30×, else the pace chosen.
    private func applyRate() {
        guard state == .flying else { return }
        let pace: Double
        if isPaused || isCoachHolding {
            pace = 0
        } else if isSkipping || coach?.isPreluding == true {
            pace = Self.skipRate
        } else {
            pace = rate
        }
        if FlightClock.virtual?.rate != pace { FlightClock.setVirtualRate(pace) }
    }

    /// A Direct To or a divert made in the Cockpit, for the generator: a jump ahead on the route, a diversion
    /// to an aerodrome the app has a runway for, back onto the route after one.
    private func followRoute() {
        guard case .route(let original, _, let destination) = setup.mission,
              let plan = world.plans.activeFlightPlan else { return }
        let diversion = plan.diversion?.ident
        if diversion != seenDiversion {
            if let diversion {
                if let field = resolveAerodrome(diversion) {
                    generator.divert(to: field)
                    diverted = true
                } else {
                    AppLog.general.debugLine("Dry run: no runway for \(diversion), the route goes on")
                }
            } else {
                generator.follow(route: DryRunSetup.enRoutePoints(of: original), to: destination,
                                 from: max(0, plan.currentWaypointIndex - 1))
            }
            seenDiversion = diversion
        }
        guard diversion == nil else { return }
        if plan.currentWaypointIndex != seenWaypointIndex {
            // The plan's waypoint i is the generator's leg i - 1 (its legs start after the departure). A natural
            // passage finds the generator there already; only a jump ahead is the pilot's.
            if seenWaypointIndex != nil, plan.currentWaypointIndex - 1 > generator.legIndex {
                generator.directTo(waypointAt: plan.currentWaypointIndex - 1)
            }
            seenWaypointIndex = plan.currentWaypointIndex
        }
    }

    func setRate(_ newRate: Double) {
        if isSkipping { stopSkip() }
        rate = max(0.25, newRate)
        applyRate()
    }

    func pause() {
        guard !isPaused, state == .flying else { return }
        if isSkipping { stopSkip() }
        isPaused = true
        applyRate()
    }

    func resume() {
        guard isPaused, state == .flying else { return }
        isPaused = false
        applyRate()
    }

    /// On to the next check: the flight sped through (30×) until a check falls due (a cue), the aircraft waits
    /// for the pilot, or the final, at most 15 minutes of it.
    func skipToNextCheck() {
        guard !isSkipping, state == .flying, !generator.isWaiting else { return }
        isPaused = false
        isSkipping = true
        skipFrom = (CueMark(world.appState.flightCues), FlightClock.now)
        applyRate()
    }

    private func stepSkip() {
        guard isSkipping, let from = skipFrom else { return }
        if CueMark(world.appState.flightCues) != from.cues || generator.isWaiting || generator.isOnFinal
            || FlightClock.now.timeIntervalSince(from.at) > Self.skipLimit {
            stopSkip()
        }
    }

    private func stopSkip() {
        isSkipping = false
        skipFrom = nil
        applyRate()
    }

    /// Ended from the Menu: the flight abandoned in the world, then the dry run's page.
    func stop() {
        guard state == .flying else { return }
        world.location.stopTracking()
        world.appState.cancelFlight()
        observe()
    }

    /// "WT9 · F-HVXA".
    var aircraftLabel: String {
        let bundled = AircraftType.wt9Dynamic
        return "\(world.aircraft?.aircraftType ?? bundled.rawValue) · \(world.aircraft?.registration ?? bundled.registration)"
    }

    /// The world's flight has ended (END FLIGHT, abandoned): its summary kept, the world dropped, the wall
    /// clock back.
    private func finish() {
        guard state == .flying else { return }
        let end = FlightClock.now
        // The coach's last step is the flight's end: it counts, with its chapter.
        coach?.tick(self)
        var summary = DryRunSummary.make(title: setup.title, aircraft: aircraftLabel, checksDone: checksDone,
                                         wasCircuits: setup.isCircuits, diverted: diverted,
                                         marks: generator.marks, seconds: end.timeIntervalSince(start ?? end))
        if let coach {
            summary.habits = coach.chaptersDone.sorted().map(DryRunChapters.habit)
            if coach.isFinished { onGuidedFinished?() }
        }
        state = .over(summary)
        self.end()
    }

    /// The end, whatever the flight was: the feed stopped, the world dropped, the wall clock back.
    func end() {
        guard !hasEnded else { return }
        hasEnded = true
        isSkipping = false
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

    enum Outcome: Equatable {
        case started
        /// A dry run or a real flight is under way.
        case busy
        /// The aircraft's checklist can't be had (no Pro, or no connection and no copy).
        case checklistUnavailable
        case refused
    }

    /// The start sheet's request: free practice, or the route given.
    struct StartRequest: Identifiable {
        let id = UUID()
        let route: FlightPlan?
    }

    /// The app's root, which shows the start sheet and the Cockpit unless a screen over it asked
    /// (`dryRunPresenter`): the route editor is itself a cover, and over a flight's page.
    nonisolated static let rootPresenter = "root"

    @Published private(set) var session: DryRunSession?
    /// Starting one: the aircraft's checklist loading, the route armed.
    @Published private(set) var isStarting = false
    @Published var startRequest: StartRequest?
    /// The guided flight asked for, from this chapter: the presenter starts it (`dryRunPresenter`).
    @Published var guidedRequest: GuidedRequest?

    struct GuidedRequest: Identifiable {
        let id = UUID()
        let chapter: Int
    }

    /// Device-local (D7): Today's card put away with Not now, and the guided flight flown to its end.
    nonisolated static let todayCardDismissedKey = "dryRun.todayCardDismissed"
    nonisolated static let guidedFlownKey = "dryRun.guidedFlown"
    /// Which screen shows the start sheet and the Cockpit (`dryRunPresenter`).
    @Published private(set) var presenter = DryRunCenter.rootPresenter
    /// Ready, waiting for the sheet that prepared it to go (`launchPrepared`).
    private var prepared: DryRunSession?
    /// What waits for the dry run to end (`whenNotRunning`).
    private var afterEnd: [() -> Void] = []
    /// What "Fly it again" starts again with.
    private var services: (settings: () -> AppSettings, airports: AirportDataService, aircraftData: AircraftDataService)?

    var isRunning: Bool { session != nil }

    /// `action` now, or once the dry run under way has ended.
    func whenNotRunning(_ action: @escaping () -> Void) {
        if isRunning { afterEnd.append(action) } else { action() }
    }

    /// Asks `presenter` (the app's root by default) for the start sheet: free practice, or `route`. Nothing
    /// during a dry run.
    func requestStart(route: FlightPlan? = nil, presenter: String = DryRunCenter.rootPresenter) {
        guard !isRunning, prepared == nil, !isStarting else { return }
        self.presenter = presenter
        startRequest = StartRequest(route: route)
    }

    /// Asks `presenter` (the app's root by default) for the guided flight, from `chapter`.
    func requestGuided(chapter: Int = 1, presenter: String = DryRunCenter.rootPresenter) {
        guard !isRunning, prepared == nil, !isStarting else { return }
        self.presenter = presenter
        guidedRequest = GuidedRequest(chapter: chapter)
    }

    /// The guided flight: the WT9 from the home aerodrome (LSZQ when there is none, or no runway for it), out
    /// to a turning point and back, the coach from `chapter`.
    @discardableResult
    func beginGuided(chapter: Int, settings: @escaping () -> AppSettings, airports: AirportDataService,
                     aircraftData: AircraftDataService, isFlightActive: Bool) async -> Outcome {
        await airports.ensureLoaded()
        await OFMDataService.shared.ensureLoaded()
        let home = settings().homeAerodromeIdent.flatMap { Self.aerodrome($0, airports: airports) } ?? .lszq
        let setup = DryRunSetup(mission: .route(DryRunChapters.route(from: home), departure: home, destination: home),
                                guidedChapter: chapter)
        return await begin(setup, settings: settings, airports: airports, aircraftData: aircraftData,
                           isFlightActive: isFlightActive, presenter: presenter)
    }

    /// `setup` in a world of its own, begun at once. `settings`: the pilot's, read now and again for "Fly it
    /// again".
    @discardableResult
    func begin(_ setup: DryRunSetup, settings: @escaping () -> AppSettings, airports: AirportDataService,
               aircraftData: AircraftDataService, isFlightActive: Bool,
               presenter: String = DryRunCenter.rootPresenter) async -> Outcome {
        guard !isRunning else { return .busy }
        self.presenter = presenter
        let outcome = await prepare(setup, settings: settings, airports: airports, aircraftData: aircraftData,
                                    isFlightActive: isFlightActive)
        guard outcome == .started else { return outcome }
        return launchPrepared(from: presenter) ? .started : .refused
    }

    /// Builds `setup`'s world and loads its aircraft's checklist, without beginning: the start sheet waits for
    /// this, then goes, and the Cockpit covers the app once it has (`launchPrepared`).
    func prepare(_ setup: DryRunSetup, settings: @escaping () -> AppSettings, airports: AirportDataService,
                 aircraftData: AircraftDataService, isFlightActive: Bool) async -> Outcome {
        guard session == nil, prepared == nil, !isStarting, !isFlightActive else { return .busy }
        isStarting = true
        defer { isStarting = false }
        services = (settings, airports, aircraftData)
        // Where the detector finds the aerodromes, and the map their frequencies.
        await airports.ensureLoaded()
        let world = DryRunWorld(settings: settings(), aircraft: setup.aircraft)
        guard await world.loadChecklist(aircraftDataService: aircraftData) else {
            world.tearDown()
            return .checklistUnavailable
        }
        if let plan = setup.plan { await world.arm(plan) }
        guard session == nil, prepared == nil else {
            world.tearDown()
            return .busy
        }
        let session = DryRunSession(world: world, setup: setup,
                                    performance: Self.performance(of: world, settings: settings()))
        session.resolveAerodrome = { Self.aerodrome($0, airports: airports) }
        if setup.isGuided {
            session.onGuidedFinished = { UserDefaults.standard.set(true, forKey: Self.guidedFlownKey) }
        }
        prepared = session
        return .started
    }

    /// Begins what `prepare` built for `presenter`. False when there is none, or its flight didn't start.
    @discardableResult
    func launchPrepared(from presenter: String = DryRunCenter.rootPresenter) -> Bool {
        guard presenter == self.presenter, let session = prepared, let services else { return false }
        prepared = nil
        guard self.session == nil, session.begin(airports: services.airports) else {
            session.end()
            return false
        }
        self.session = session
        AppLog.general.publicLine("Dry run started")
        return true
    }

    /// What `prepare` built, dropped unflown (the sheet closed another way).
    func discardPrepared() {
        prepared?.end()
        prepared = nil
    }

    /// The same dry run again, from the start.
    func again() async {
        guard let setup = session?.setup, let services else { return }
        let presenter = self.presenter
        end()
        await begin(setup, settings: services.settings, airports: services.airports,
                    aircraftData: services.aircraftData, isFlightActive: false, presenter: presenter)
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

    /// The WT9's numbers, or another aircraft's from its checklist's Vso and Vr and the pilot's cruise speed
    /// for it (else 100 kt).
    static func performance(of world: DryRunWorld, settings: AppSettings) -> DryRunPerformance {
        guard let aircraft = world.aircraft, aircraft.bundledType != .wt9Dynamic else { return .wt9 }
        let checklist = world.appState.activeChecklist
        let speeds = AircraftSpeedConfig(speeds: checklist.speeds, stallSpeed: checklist.stallSpeed)
        guard speeds.vsoKts > 0, speeds.vrKts > speeds.vsoKts else { return .wt9 }
        let cruise = settings.cruiseSpeedKIAS[aircraft.registration].map(Double.init) ?? CruiseSpeedModel.standardKIAS
        return .scaled(vso: speeds.vsoKts, vr: speeds.vrKts, cruise: max(cruise, speeds.vrKts * 1.6))
    }

    /// An aerodrome to fly at: LSZQ as bundled; any other as the app's data has it (open flightmaps'
    /// thresholds and circuit when loaded). Nil without a runway.
    static func aerodrome(_ ident: String, airports: AirportDataService) -> DryRunAerodrome? {
        let code = ident.uppercased()
        if code == DryRunAerodrome.lszq.ident { return .lszq }
        guard let airport = airports.findAirport(byIdent: code) else { return nil }
        return DryRunAerodrome.make(airport: airport, runways: airports.getRunways(for: code),
                                    thresholds: OFMDataService.shared.thresholds(forAerodrome: code),
                                    circuits: OFMDataService.shared.procedures(forAerodrome: code))
    }
}
