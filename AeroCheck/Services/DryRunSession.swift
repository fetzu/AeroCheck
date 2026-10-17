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
    /// The clock's pace as it runs now: 0 held or paused; in the guided flight, `guidedPace`.
    @Published private(set) var pace: Double = 0
    /// The guided flight's card folded to one line between two steps (`makeFoldedLine`); nil otherwise.
    @Published private(set) var foldedLine: String?
    @Published private(set) var state: State = .flying
    private(set) var hasEnded = false

    /// When it began, on its clock: fix `t` is due `t` seconds later.
    private(set) var start: Date?
    /// The next fix, decided and not due yet.
    private var pending: DryRunFix?
    /// The app's airports, for the world's flight and its END FLIGHT.
    private var airports: AirportDataService?
    /// Whether the dry run's flight has begun: free practice's at once, the guided one's from START FLIGHT.
    private(set) var hasFlown = false
    /// Ended from the Menu or a part's page: the page at once, whatever the story still had.
    private var stopRequested = false
    /// When the guided flight began its way to its chapter, on the wall clock (the log's measure).
    private var fastForwardBegan: Date?
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
    /// How near the waypoint the generator flies to a time over the app writes is its own passage, metres.
    static let passageRadius = 1.5 * DryRunGeo.metresPerNM
    /// The last of a final and the landing roll, in the guided flight.
    static let landingRate = 12.0
    /// The guided flight's paces (the proposal's Q3, "Plan to Logbook", tuned on the headless flight so that no
    /// stretch is longer than 13 s without a card or a tap, `DryRunGuidedTests`): what is worth seeing move at
    /// 5× (the taxi's first seconds, the take-off roll and the lift-off), a turning point's turn and the line-up
    /// at 10×, the last of a final and the landing roll at 12×, everything else at 30×. At 20× the legs out and
    /// back ran 16 to 22 s without anything for the pilot. Slowed only where something moves, and into it by
    /// steps: slowed 15 s ahead of a turning point and on the turn onto the downwind, it read as the app lagging
    /// (the author's fifth round, 17 Oct).
    static let watchRate = 5.0
    static let turnRate = 10.0
    static let flyOnRate = 30.0
    /// Fixes fed per tick of the timer while the guided flight is taken to its chapter, behind the cover.
    nonisolated static let fastForwardBudget = 400
    /// Never longer than this of the dry run's time: a check that never falls due doesn't run it away.
    static let skipLimit: TimeInterval = 15 * 60

    init(world: DryRunWorld, setup: DryRunSetup, performance: DryRunPerformance = .wt9,
         seed: UInt64 = .random(in: 1...UInt64.max)) {
        self.world = world
        self.setup = setup
        rate = setup.rate
        landings = setup.landings
        coach = setup.guided.map { DryRunCoach(start: $0) }
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
        self.airports = airports
        // The guided dry run's pace is the coach's, from its first step (which holds); on its way to where it
        // starts the clock is set fix by fix (`fastForward`). Its flight starts from its steps: START FLIGHT on
        // the ground, done for the pilot when it starts later. Free practice's flight starts at once.
        FlightClock.runVirtual(from: now, rate: coach == nil ? rate : 0)
        if coach == nil {
            guard world.startFlight(circuits: setup.isCircuits, aerodromes: setup.aerodromes.map(\.airport),
                                    airports: airports) else {
                end()
                return false
            }
            hasFlown = true
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.coach?.isFastForwarding == true {
                    self.fastForward()
                } else {
                    self.feedDueFixes(upTo: FlightClock.now)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        return true
    }

    /// Every fix due by `now`, in order, through the world's GPS; at most `cap` at once, so a stall catches up
    /// over a few ticks rather than in one. Then what the Cockpit did meanwhile.
    func feedDueFixes(upTo now: Date, cap: Int = 50) {
        guard let start, state == .flying else { return }
        // On the ground (the story before START FLIGHT and after END FLIGHT) there is no flight to feed.
        for _ in 0..<cap where world.appState.isFlightActive {
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

    /// The guided flight on its way to the chapter it starts at, behind the cover: fix after fix as fast as
    /// they can be fed, the clock set to each (as a ground replay's tests set it), the coach doing the earlier
    /// steps as the pilot would. At most `budget` fixes, so the cover keeps drawing; the chapter's first step
    /// ends it, and the clock runs on from there at the coach's pace.
    func fastForward(budget: Int = DryRunSession.fastForwardBudget) {
        guard let start, state == .flying, let coach else { return }
        let began = fastForwardBegan ?? Date()
        fastForwardBegan = began
        defer {
            if !coach.isFastForwarding {
                AppLog.general.publicLine("Dry run: at part \(coach.start.part.rawValue), chapter \(coach.start.chapter) in \(String(format: "%.1f", Date().timeIntervalSince(began))) s")
            }
        }
        for _ in 0..<budget where coach.isFastForwarding && state == .flying {
            // On the ground the steps are the pilot's on the ground: no fix, the coach does them.
            guard world.appState.isFlightActive else {
                let index = coach.index
                observe()
                if coach.index == index, !world.appState.isFlightActive { break }
                continue
            }
            let fix = pending ?? generator.nextFix()
            pending = nil
            let due = start.addingTimeInterval(TimeInterval(fix.t))
            FlightClock.virtual = FlightClock.Virtual(wallAnchor: Date(), virtualAnchor: due, rate: 0)
            world.location.feedDryRunFix(fix.location(at: due))
            observe()
            // Never longer than a flight could be: a step that can't come doesn't keep the cover up.
            if fix.t > 3 * 3600 {
                AppLog.general.publicLine("Dry run: the chapter's start never came")
                stop()
            }
        }
    }

    /// The Cockpit's side: the flight ended, the generator's state for the band and the card, the route
    /// changed, Next check reached its check, what the summary keeps.
    private func observe() {
        let appState = world.appState
        guard appState.isFlightActive else {
            // The story's ground, before START FLIGHT and after END FLIGHT: the coach goes on, the clock stands.
            // The dry run ends with its last step, or with Stop here; free practice with its flight.
            if let coach, !coach.isFinished, !stopRequested {
                if isOnFinal { isOnFinal = false }
                let hold = coach.tick(self)
                if hold != isCoachHolding { isCoachHolding = hold }
                if isWaiting { isWaiting = false }
                if foldedLine != nil { foldedLine = nil }
                applyRate()
                if coach.isFinished { finish() }
                return
            }
            finish()
            return
        }
        let onFinal = generator.isOnFinal
        if onFinal != isOnFinal {
            if onFinal { finalChoice = .fullStop }
            isOnFinal = onFinal
        }
        takeDetectedEvents()
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
        if coach != nil {
            let line = makeFoldedLine()
            if line != foldedLine { foldedLine = line }
        }
    }

    /// The clock's pace for where the dry run stands: stopped while paused or held by the coach (and on the
    /// guided flight's way to its chapter, where the clock is set fix by fix), the guided flight's pace for
    /// where the aircraft is, Next check's 30×, else the pace chosen.
    private func applyRate() {
        guard state == .flying else { return }
        let pace: Double
        if isPaused || isCoachHolding || coach?.isFastForwarding == true || !world.appState.isFlightActive {
            pace = 0
        } else if coach != nil {
            pace = Self.guidedPace(generator)
        } else if isSkipping {
            pace = Self.skipRate
        } else {
            pace = rate
        }
        if self.pace != pace { self.pace = pace }
        if FlightClock.virtual?.rate != pace { FlightClock.setVirtualRate(pace) }
    }

    /// No card in a dry run, whatever the pilot's setting (the author's fifth round, 17 Oct): what the app saw
    /// is taken at once, with UNDO, as a flight takes it by default.
    private func takeDetectedEvents() {
        world.appState.takeDetectedEvents(from: world.detector)
    }

    /// The guided flight's pace for what the aircraft is doing.
    static func guidedPace(_ generator: DryRunGenerator) -> Double {
        let since = generator.t - generator.activitySince
        let firstCircuit = generator.mark("goAround") == nil
        switch generator.activity {
        case .taxiing: return since < 10 ? watchRate : flyOnRate
        case .liningUp: return 10
        case .takeoffRoll: return watchRate
        // The lift-off, until the card that says the app saw it.
        case .climbingOut: return firstCircuit && since < 12 ? watchRate : flyOnRate
        // Not much slower for the landing: slowed down more, it read as the app stuttering (st-15).
        case .final: return generator.heightAboveFieldFt < 100 ? landingRate : flyOnRate
        case .landing: return landingRate
        case .climbing, .cruising, .descending:
            // The turn after a turning point at 10×, and into it from 7 s before the point, 30× to 10× by 2 s.
            if (generator.secondsSinceWaypoint ?? .max) < 60, generator.turnDegreesPerSecond > 0.5 { return turnRate }
            if let toGo = generator.secondsToWaypoint, toGo < 7 {
                return max(turnRate, min(flyOnRate, turnRate + (toGo - 2) * 4))
            }
            return flyOnRate
        default: return flyOnRate
        }
    }

    /// The guided flight's card folded between two steps: what the aircraft does, and the next thing for the
    /// pilot to do, if one is coming.
    private func makeFoldedLine() -> String? {
        guard let coach, coach.step == nil, !coach.isFastForwarding, state == .flying else { return nil }
        let doing: String
        switch generator.activity {
        case .parked: doing = L10n.DryRunCoach.Doing.parked
        case .taxiing: doing = L10n.DryRunCoach.Doing.taxiing
        case .holding: doing = L10n.DryRunCoach.Doing.holding
        case .liningUp: doing = L10n.DryRunCoach.Doing.liningUp
        case .takeoffRoll: doing = L10n.DryRunCoach.Doing.takeoffRoll
        case .climbingOut: doing = L10n.DryRunCoach.Doing.climbingOut
        case .climbing: doing = L10n.DryRunCoach.Doing.climbing
        case .cruising:
            let next = world.plans.activeFlightPlan?.nextWaypoint?.name
            doing = next.map(L10n.DryRunCoach.Doing.cruising) ?? L10n.DryRunCoach.Doing.climbing
        case .descending: doing = L10n.DryRunCoach.Doing.descending
        case .joining: doing = L10n.DryRunCoach.Doing.joining
        case .upwind: doing = L10n.DryRunCoach.Doing.upwind
        case .crosswind: doing = L10n.DryRunCoach.Doing.crosswind
        case .downwind: doing = L10n.DryRunCoach.Doing.downwind
        case .base: doing = L10n.DryRunCoach.Doing.base
        case .final: doing = L10n.DryRunCoach.Doing.final
        case .goingAround: doing = L10n.DryRunCoach.Doing.goingAround
        case .landing: doing = L10n.DryRunCoach.Doing.landing
        case .stopped: doing = L10n.DryRunCoach.Doing.stopped
        case .taxiingIn: doing = L10n.DryRunCoach.Doing.taxiingIn
        case .parkedEnd: doing = L10n.DryRunCoach.Doing.parkedEnd
        }
        guard let upcoming = coach.upcoming?.upcoming else { return doing }
        return "\(doing) \(L10n.DryRunCoach.nextForYou(upcoming))"
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
            // passage finds the generator there already, or about to be: the app writes a time over abeam,
            // which can come a second before the generator itself reaches the point. Only a jump further, or
            // from far off, is the pilot's (a Direct To). Taken for one, the generator lost its own passage,
            // and the guided flight waited for it for good (device check c-1, 16 Oct).
            let target = plan.currentWaypointIndex - 1
            let natural = target == generator.legIndex + 1
                && (generator.distance(toWaypointAt: generator.legIndex) ?? .infinity) < Self.passageRadius
            if seenWaypointIndex != nil, target > generator.legIndex, !natural {
                generator.directTo(waypointAt: target)
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

    /// Ended from the Menu, or Stop here on a part's page: the flight abandoned in the world if one runs, then
    /// the dry run's page.
    func stop() {
        guard state == .flying else { return }
        stopRequested = true
        if world.appState.isFlightActive {
            world.location.stopTracking()
            world.appState.cancelFlight()
        }
        observe()
    }

    // MARK: The story's ground

    /// The story's flight, as planned on the ground (the Plan sheet, or `planStoryFlight`).
    var storyThread: FlightThread? { world.threads.threads.first }

    /// Create flight, as Plan new flight does it from the dry run's route: a copy of the route for the flight,
    /// due in ten minutes, and the flight following it. For the pilot, on the way to a later part.
    func planStoryFlight() {
        guard storyThread == nil, let route = setup.plan else { return }
        var plan = FlightPlan(name: route.name, waypoints: route.waypoints)
        plan.flightOwned = true
        plan.plannedDepartureTime = FlightClock.now.addingTimeInterval(10 * 60)
        plan.calculateRouteData()
        world.plans.add(plan)
        let bundled = AircraftType.wt9Dynamic
        world.threads.createThread(from: plan, profile: .full,
                                   aircraftRegistration: world.aircraft?.registration ?? bundled.registration)
    }

    func setStoryTask(_ key: ThreadTaskKey, to state: ThreadTaskState) {
        guard let thread = storyThread, let task = thread.tasks.first(where: { $0.key == key }) else { return }
        world.threads.setTaskState(state, taskId: task.id, threadId: thread.id)
    }

    /// START FLIGHT on the ground (the flight's page, Today), and for the pilot on the way to a later part: the
    /// story's flight with its plan armed, attached to its page, the generator on its way. The app's own start
    /// (`FlightLauncher`) is a real flight's, which a dry run never starts. False when the world refused it.
    @discardableResult
    func startFlightFromGround() -> Bool {
        guard state == .flying, !hasFlown, !world.appState.isFlightActive, let airports else { return false }
        if let planId = storyThread?.flightPlanId,
           let plan = world.plans.flightPlans.first(where: { $0.id == planId }) {
            world.plans.activateFlightPlan(plan)
        }
        guard world.startFlight(circuits: false, aerodromes: setup.aerodromes.map(\.airport), airports: airports) else {
            AppLog.general.publicLine("Dry run: the flight didn't start")
            return false
        }
        hasFlown = true
        if let thread = storyThread, let flightId = world.appState.currentFlight?.id {
            world.threads.attachFlight(flightId, toThreadId: thread.id)
        }
        return true
    }

    /// The rest of Plan and Prepare, done for the pilot as START FLIGHT's card shows: the fuel on board for the
    /// fuel plan's AUTO row, every other task ticked. Close out then shows its own tasks alone (st-16).
    func settleStoryPreflight() {
        guard let thread = storyThread else { return }
        if let planId = thread.flightPlanId, var plan = world.plans.flightPlans.first(where: { $0.id == planId }),
           let required = plan.fuelRequired, (plan.fuelOnBoard ?? 0) < required {
            plan.fuelOnBoard = (required / 10).rounded(.up) * 10 + 10
            world.plans.updateFlightPlan(plan)
            world.threads.regenerateTasks(threadId: thread.id, plan: plan)
        }
        for task in storyThread?.tasks ?? [] where task.state == .pending && task.kind != .auto
            && (task.chapter == .plan || task.chapter == .prepare) {
            world.threads.setTaskState(.done, taskId: task.id, threadId: thread.id)
        }
    }

    /// END FLIGHT as the Cockpit's button does it (`FlightEnder`), on the world's objects: for the pilot, on the
    /// way to a later part.
    func endFlight() {
        guard world.appState.isFlightActive, let airports else { return }
        FlightEnder(appState: world.appState, locationManager: world.location, airportDataService: airports,
                    flightPlanManager: world.plans, threadManager: world.threads).end()
    }

    func finishStoryThread() {
        guard let thread = storyThread, thread.state != .done else { return }
        world.threads.finishThread(threadId: thread.id)
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
            summary.habits = coach.segmentsDone.compactMap(\.habit)
            summary.isStory = true
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
    /// The guided dry run asked for, from where it starts: the presenter starts it (`dryRunPresenter`).
    @Published var guidedRequest: GuidedRequest?

    struct GuidedRequest: Identifiable {
        let id = UUID()
        let start: DryRunStart
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

    /// Asks `presenter` (the app's root by default) for the guided dry run, from `start`.
    func requestGuided(_ start: DryRunStart = .story, presenter: String = DryRunCenter.rootPresenter) {
        guard !isRunning, prepared == nil, !isStarting else { return }
        self.presenter = presenter
        guidedRequest = GuidedRequest(start: start)
    }

    /// The guided dry run: the WT9 from the home aerodrome (LSZQ when there is none, or no runway for it),
    /// round the triangle and back, the coach from `start`.
    @discardableResult
    func beginGuided(_ start: DryRunStart, settings: @escaping () -> AppSettings, airports: AirportDataService,
                     aircraftData: AircraftDataService, isFlightActive: Bool) async -> Outcome {
        await airports.ensureLoaded()
        await OFMDataService.shared.ensureLoaded()
        let home = settings().homeAerodromeIdent.flatMap { Self.aerodrome($0, airports: airports) } ?? .lszq
        let setup = DryRunSetup(mission: .route(DryRunChapters.route(from: home), departure: home, destination: home),
                                guided: start)
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
    ///
    /// The pilot's settings for the world: the guided dry run teaches with every item shown. With the memory
    /// items hidden, a check's card waited for a slot that named it "from memory" (the author's second run,
    /// 16 Oct). Its card on the Menu shows where to hide them, in the world only.
    static func worldSettings(_ settings: AppSettings, guided: Bool) -> AppSettings {
        var settings = settings
        if guided { settings.learningMode = true }
        return settings
    }

    func prepare(_ setup: DryRunSetup, settings: @escaping () -> AppSettings, airports: AirportDataService,
                 aircraftData: AircraftDataService, isFlightActive: Bool) async -> Outcome {
        guard session == nil, prepared == nil, !isStarting, !isFlightActive else { return .busy }
        isStarting = true
        defer { isStarting = false }
        services = (settings, airports, aircraftData)
        // Where the detector finds the aerodromes, and the map their frequencies.
        await airports.ensureLoaded()
        let world = DryRunWorld(settings: Self.worldSettings(settings(), guided: setup.isGuided), aircraft: setup.aircraft)
        guard await world.loadChecklist(aircraftDataService: aircraftData) else {
            world.tearDown()
            return .checklistUnavailable
        }
        if let plan = setup.plan {
            if setup.isGuided {
                // The guided dry run's route, among the world's routes for Plan new flight; armed when its flight
                // starts. Its logbook, five made-up flights before it, for the Logbook part.
                await world.keep(plan)
                await world.seedLogbook(at: setup.departure, now: Date())
            } else {
                await world.arm(plan)
            }
        }
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
