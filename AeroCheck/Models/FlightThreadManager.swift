import Foundation
import CoreLocation

/// Owns the flight threads: creation, task state, persistence and the two reminders.
///
/// Mirrors `FlightPlanManager`'s shape on purpose — `ObservableObject` + `@Published`, the collection
/// in files via `DataPersistenceManager`, the "which one am I following" pointer in `UserDefaults`,
/// and an injectable `defaults:` because the test host shares the app's bundle id (a test that wrote
/// to `.standard` once left a synthetic plan showing as ACTIVE in the real app on that simulator).
@MainActor
class FlightThreadManager: ObservableObject {

    // MARK: - Published Properties

    @Published var threads: [FlightThread] = []
    /// The thread currently being followed. At most one: a pilot flies one flight at a time, and a
    /// second "current" thread would make the Home strip ambiguous.
    @Published var currentThreadId: UUID?
    /// Set when a landing closes a thread that still has an open flight plan; drives the urgent
    /// banner. Cleared when the pilot acts on it.
    @Published var openFlightPlanNotice: OpenFlightPlanNotice?
    /// Set when a circuit session ends with no thread to close out; drives the offer banner. (v5.x)
    @Published var circuitCloseOutOffer: CircuitCloseOutOffer?
    /// Multi-leg trips. Few and small, so they load and save as one file. (v5.x)
    @Published var trips: [Trip] = []
    /// True once the on-disk threads have arrived.
    ///
    /// Load is async (iCloud), so before it finishes EVERY plan looks unfollowed. Anything that
    /// decides a plan's fate by "does a flight reference it" must wait for this, or it would strip
    /// the dates off flights that do exist. (v5.x)
    @Published private(set) var hasLoadedThreads = false

    /// True once the on-disk trips have arrived. Set independently of `hasLoadedThreads` because
    /// the two loads land at different times, and a leg is invisible in both lists while its trip
    /// is missing — so anything that renders the flights list needs to know about this one too.
    @Published private(set) var hasLoadedTrips = false

    // MARK: - Private Properties

    private let currentThreadKey = "currentFlightThreadId"
    private let persistence = DataPersistenceManager.shared
    private let defaults: UserDefaults
    private let notifications: NotificationService
    /// Mirrors `AppSettings.enableCostTracking`. Held here rather than reached for, because the task
    /// engine is pure and the manager is what owns the side of the app that knows about settings.
    /// The app keeps it in step; it defaults to on so a manager built in a test behaves normally.
    var tracksCost: Bool = true

    /// Snapshot of each thread as last persisted, for dirty detection (same idea as the plan manager).
    private var lastPersisted: [UUID: FlightThread] = [:]

    // MARK: - Initialization

    init(defaults: UserDefaults = .standard, notifications: NotificationService? = nil) {
        self.defaults = defaults
        self.notifications = notifications ?? NotificationService.shared
        loadCurrentThreadPointer()
        Task { [weak self] in
            // Trips FIRST: `hasLoadedThreads` is what the flights list waits on, and a leg whose
            // trip has not arrived yet appears in neither the standalone list nor the trip list.
            // Loading trips after it meant a window where the app said "loaded" and the legs were
            // simply absent. (review F10)
            await self?.loadTrips()
            await self?.loadThreadsAsync()
        }
    }

    // MARK: - Derived

    var currentThread: FlightThread? {
        guard let id = currentThreadId else { return nil }
        return threads.first { $0.id == id }
    }

    /// Threads still owing the pilot something, newest first — what the Home strip counts.
    var unfinishedThreads: [FlightThread] {
        threads.filter { !$0.isFinished }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The most recent thread waiting on close-out work.
    var threadAwaitingCloseOut: FlightThread? {
        threads
            .filter { $0.state == .closeOut }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    func thread(withId id: UUID) -> FlightThread? { threads.first { $0.id == id } }

    func thread(forFlightId flightId: UUID) -> FlightThread? { threads.first { $0.flightId == flightId } }

    func thread(forPlanId planId: UUID) -> FlightThread? {
        threads.first { $0.flightPlanId == planId && !$0.isFinished }
    }

    // MARK: - Creation

    /// Start following a flight. Returns the new thread, and makes it the current one.
    ///
    /// `profile` decides how much admin the thread carries: `.local` is the circuit-session version
    /// (weather, DABS, logbook, debrief) and `.full` is the cross-country bracket.
    @discardableResult
    func createThread(from plan: FlightPlan?,
                      profile: ThreadProfile = .full,
                      routeLabel: String? = nil,
                      aircraftRegistration: String? = nil,
                      pprIdents: [String]? = nil,
                      destinationFuels: [String]? = nil) -> FlightThread {
        var thread = FlightThread(
            flightPlanId: plan?.id,
            profile: profile,
            routeLabel: routeLabel ?? Self.routeLabel(for: plan),
            aircraftRegistration: aircraftRegistration ?? plan?.aircraftRegistration,
            scheduledDeparture: plan?.plannedDepartureTime
        )
        var context = Self.context(for: plan, profile: profile)
        context.tracksCost = tracksCost
        context.pprIdents = pprIdents ?? Self.pprIdents(on: plan, fallingBackTo: [])
        context.destinationFuels = destinationFuels ?? Self.destinationFuels(on: plan)
        thread.countries = context.countries
        thread.homeCountry = context.homeCountry
        thread.tasks = ThreadTaskEngine.generate(context: context)

        threads.insert(thread, at: 0)
        currentThreadId = thread.id
        saveCurrentThreadPointer()
        saveThreads()

        if let departure = thread.scheduledDeparture {
            Task { [notifications] in
                await notifications.schedulePreparationReminder(threadId: thread.id,
                                                                routeLabel: thread.routeLabel,
                                                                departure: departure)
            }
        }
        return thread
    }

    /// Rebuild from the plan as it is NOW, preserving everything the pilot has ticked.
    ///
    /// `weatherSummary` and `pprIdents` used to be the caller's to supply, and defaulted to
    /// nil/empty — so any caller that did not know to pass them would have silently erased the
    /// weather detail and every PPR row. Both are derivable, so this derives them: from the route
    /// for PPR and the destination's fuel grades, and from the existing task for the weather summary
    /// the pilot's own briefing produced. A regeneration can now never lose context.
    func regenerateTasks(threadId: UUID,
                         plan: FlightPlan?,
                         weatherSummary: String? = nil,
                         pprIdents: [String]? = nil) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        let existing = threads[index].tasks
        var context = Self.context(for: plan, profile: threads[index].profile)
        context.tracksCost = tracksCost
        context.isLeg = threads[index].tripId != nil
        context.weatherSummary = weatherSummary
            ?? existing.first { $0.key == .weatherBriefed }?.detail
        context.pprIdents = pprIdents
            ?? Self.pprIdents(on: plan, fallingBackTo: existing)
        context.destinationFuels = Self.destinationFuels(on: plan)
        context.flightPlanFiled = threads[index].flightPlanFiledAt != nil
        let regenerated = ThreadTaskEngine.generate(context: context, existing: existing)

        // Bail out when nothing actually changed.
        //
        // Regeneration runs on every plan publish and on the flight screen's appearance, and it used
        // to rewrite the task array and `touch()` the thread REGARDLESS — so a screen the pilot was
        // reading had its list replaced, and `unfinishedThreads` (sorted by `updatedAt`) reordered,
        // for no change at all. Replacing rows underneath a finger is a plausible cause of the crash
        // reported when ticking a task on a freshly created flight, and it is churn worth removing
        // either way. (device pass)
        guard regenerated != existing
                || threads[index].countries != context.countries
                || threads[index].homeCountry != context.homeCountry
                || (plan != nil && plan?.plannedDepartureTime != threads[index].scheduledDeparture)
        else { return }

        threads[index].countries = context.countries
        threads[index].homeCountry = context.homeCountry
        threads[index].tasks = regenerated

        // The cached departure drives "is this today?" and the preparation reminder. Left stale it
        // reads a date the plan no longer has, which is how a flight moved to tomorrow kept being
        // offered as today's. (device pass)
        let previousDeparture = threads[index].scheduledDeparture
        if let plan, plan.plannedDepartureTime != previousDeparture {
            threads[index].scheduledDeparture = plan.plannedDepartureTime
            reschedulePreparationReminder(at: index, from: previousDeparture)
        }
        threads[index].touch()
        saveThreads()
    }

    /// Re-derive every unfinished flight's AUTO rows from the plans as they now stand.
    ///
    /// Cheap: the engine is pure, the thread count is small, and `saveThreads` is dirty-diffed, so a
    /// regeneration that changes nothing writes nothing.
    func refreshTasks(from plans: [FlightPlan]) {
        let byId = Dictionary(plans.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for thread in threads where !thread.isFinished {
            guard let planId = thread.flightPlanId, let plan = byId[planId] else { continue }
            regenerateTasks(threadId: thread.id, plan: plan)
        }
    }

    private func reschedulePreparationReminder(at index: Int, from previous: Date?) {
        let thread = threads[index]
        notifications.cancelPreparationReminder(threadId: thread.id)
        guard let departure = thread.scheduledDeparture, thread.state == .planned || thread.state == .ready
        else { return }
        Task { [notifications] in
            await notifications.schedulePreparationReminder(threadId: thread.id,
                                                            routeLabel: thread.routeLabel,
                                                            departure: departure)
        }
    }

    /// Aerodromes on the route that OpenAIP flags as PPR. Falls back to the rows already on the
    /// thread when the airport layer is not loaded — an undownloaded dataset must never delete a
    /// requirement the pilot has already been shown, let alone one they have ticked.
    static func pprIdents(on plan: FlightPlan?, fallingBackTo existing: [ThreadTask]) -> [String] {
        let previous = existing.filter { $0.key == .pprObtained }.compactMap(\.subject)
        guard let plan else { return previous }
        let onRoute = Set(plan.waypoints.map(\.name).filter(looksLikeICAO))
        guard !onRoute.isEmpty else { return previous }
        let loaded = OpenAIPAirportDataService.shared.allLoadedAirports()
        guard !loaded.isEmpty else { return previous }
        return loaded.filter { $0.isPPR }.compactMap(\.icaoCode).filter(onRoute.contains)
    }

    /// Fuel grades the destination reports, so the fuel row can answer "can I fill up at the far
    /// end". Empty is "not stated", never "none available".
    static func destinationFuels(on plan: FlightPlan?) -> [String] {
        guard let plan,
              let arrival = plan.waypoints.map(\.name).last(where: looksLikeICAO)
        else { return [] }
        return OpenAIPAirportDataService.shared.allLoadedAirports()
            .first { $0.icaoCode == arrival }?
            .fuelTypes.map(\.label) ?? []
    }

    // MARK: - Trips (v5.x)

    func trip(withId id: UUID) -> Trip? { trips.first { $0.id == id } }

    func trip(forThreadId id: UUID) -> Trip? {
        guard let tripId = thread(withId: id)?.tripId else { return nil }
        return trip(withId: tripId)
    }

    /// Legs of a trip, in flying order. Reads the order off the trip, which owns it.
    func legs(of trip: Trip) -> [FlightThread] {
        trip.legIds.compactMap { id in threads.first { $0.id == id } }
    }

    /// Threads that are not a leg of anything — what the Flights list shows alongside trip rows.
    var standaloneUnfinishedThreads: [FlightThread] {
        unfinishedThreads.filter { $0.tripId == nil }
    }

    /// Make `threads` into one trip, moving their trip-scoped tasks up to it.
    ///
    /// The shared tasks are taken from the FIRST leg and stripped from every leg, so a tick made
    /// before the trip existed is carried up rather than lost — this is the path a standalone flight
    /// takes when a second leg is added to it, and its preparation should survive that.
    @discardableResult
    func formTrip(from threadIds: [UUID]) -> Trip? {
        // De-duplicate and keep only ids that actually resolve, in the order given. Without this a
        // repeated or unknown id still landed in `legIds`, producing a "trip" that is not
        // `isDegenerate` but has fewer real legs than it claims — the dangling state, at birth.
        var seen = Set<UUID>()
        let resolved = threadIds.filter { id in
            guard seen.insert(id).inserted else { return false }
            guard let index = threads.firstIndex(where: { $0.id == id }) else { return false }
            // A flight already under way, already closed out, or already in another trip is not
            // something to fold into a new one. (review F-formTrip)
            return threads[index].tripId == nil
                && threads[index].state != .flying
                && !threads[index].isFinished
        }
        guard resolved.count >= 2 else { return nil }
        let threadIds = resolved
        var trip = Trip(legIds: threadIds)
        // The one date in a trip the pilot actually chose: the first leg's departure. It is what an
        // undated later leg measures a shared tick against. (review F12)
        trip.scheduledStart = threads.first { $0.id == threadIds[0] }?.scheduledDeparture

        // Every leg's trip-scoped rows are candidates, not just leg 1's, and the most-settled
        // version of each row wins. Taking leg 1 alone deleted whatever the other legs had recorded
        // — and worse, a row leg 1 never needed (a France-only first leg emits no DABS) could not
        // be produced by any later leg either, because `generate` filters trip-scoped specs off a
        // leg. The row then existed nowhere on a trip that does enter Swiss airspace. (review F15)
        var promoted: [String: ThreadTask] = [:]
        for id in threadIds {
            guard let index = threads.firstIndex(where: { $0.id == id }) else { continue }
            for task in threads[index].tasks where task.key.scope == .trip {
                if let existing = promoted[task.matchToken], existing.isSettled, !task.isSettled {
                    continue
                }
                promoted[task.matchToken] = task
            }
        }
        trip.sharedTasks = promoted.values.sorted { $0.key.rawValue < $1.key.rawValue }
        for id in threadIds {
            guard let index = threads.firstIndex(where: { $0.id == id }) else { continue }
            threads[index].tripId = trip.id
            threads[index].tasks.removeAll { $0.key.scope == .trip }
            threads[index].touch()
        }
        trips.append(trip)
        saveThreads()
        saveTrips()
        return trip
    }

    /// Tick a shared task. Reached from whichever leg the pilot happens to be looking at — the state
    /// lives on the trip, so all of them see it at once.
    /// `fromLegId` is the leg the pilot was looking at when they ticked. A tick made there covers
    /// that leg outright — see `ThreadTask.acknowledgedLegIds` for why the timestamp alone could
    /// not. (review F13)
    func setSharedTaskState(_ state: ThreadTaskState, taskId: UUID, tripId: UUID, fromLegId: UUID? = nil) {
        guard let index = trips.firstIndex(where: { $0.id == tripId }),
              let taskIndex = trips[index].sharedTasks.firstIndex(where: { $0.id == taskId })
        else { return }
        trips[index].sharedTasks[taskIndex].state = state
        // Refreshing a stale briefing re-stamps it, which is what makes it cover the later legs.
        trips[index].sharedTasks[taskIndex].completedAt = (state == .done) ? Date() : nil
        if state == .done {
            if let fromLegId { trips[index].sharedTasks[taskIndex].acknowledgedLegIds.insert(fromLegId) }
        } else {
            // Un-ticking retracts the acknowledgement everywhere, or the row would stay green on
            // the leg it was ticked from while reading pending on every other leg.
            trips[index].sharedTasks[taskIndex].acknowledgedLegIds = []
        }
        trips[index].touch()
        saveTrips()
    }

    /// Remove a leg, and dissolve the trip when it stops being one.
    ///
    /// A trip of one leg is just a flight, so the survivor gets its shared tasks back and becomes
    /// standalone again — otherwise its preparation would vanish with the container.
    func removeLeg(threadId: UUID) {
        guard let tripIndex = trips.firstIndex(where: { $0.legIds.contains(threadId) }) else {
            deleteThread(threadId: threadId)
            return
        }
        trips[tripIndex].legIds.removeAll { $0 == threadId }
        deleteThread(threadId: threadId)

        if trips[tripIndex].isDegenerate {
            let shared = trips[tripIndex].sharedTasks
            if let survivor = trips[tripIndex].legIds.first,
               let index = threads.firstIndex(where: { $0.id == survivor }) {
                threads[index].tripId = nil
                threads[index].tasks.append(contentsOf: shared)
                threads[index].touch()
            }
            trips.remove(at: tripIndex)
            saveThreads()
        } else {
            trips[tripIndex].touch()
        }
        saveTrips()
    }

    /// Serialises trip writes. `saveTripsOffMain` writes the WHOLE file from a detached task, and
    /// detached tasks have no ordering, so two quick ticks in the trip band could land out of order
    /// and leave the file holding the older array. Threads self-heal from that via their dirty-diff;
    /// trips have no such tracking, so a lost tick simply came back unticked. Chaining each write
    /// onto the previous one gives them the FIFO order the shape assumed. (review F-trips-order)
    private var tripWriteChain: Task<Void, Never>?

    private func saveTrips() {
        let snapshot = trips
        let previous = tripWriteChain
        tripWriteChain = Task { [persistence] in
            await previous?.value
            await persistence.saveTripsOffMain(snapshot)
        }
    }

    /// Merge rather than assign, exactly as `loadThreadsAsync` does and for the same reason: this
    /// lands AFTER the iCloud-backed thread load, seconds into the session, and a trip the pilot
    /// formed in that window was overwritten out of memory while both its legs kept `tripId` — so
    /// `trip(forThreadId:)` found nothing (no trip band) and `context.isLeg` stayed true (the
    /// trip-scoped rows filtered off the legs). The preparation existed in neither place, and
    /// `saveTrips` then made the truncated file permanent. (review F10)
    private func loadTrips() async {
        let loaded = await persistence.loadTripsOffMain()
        let existingIds = Set(trips.map(\.id))
        trips = trips + loaded.filter { !existingIds.contains($0.id) }
        hasLoadedTrips = true
    }

    // MARK: - Task mutation

    func setTaskState(_ state: ThreadTaskState, taskId: UUID, threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        let wasOpen = threads[index].hasOpenFlightPlan
        threads[index].setState(state, forTaskWithId: taskId)

        let task = threads[index].tasks.first { $0.id == taskId }

        // Filing a plan adds the close-out task that only makes sense once there is something to
        // close; un-filing removes it again.
        if task?.key == .flightPlanFiled {
            regenerateAfterFilingChange(at: index)
        }

        // Closing the plan retires the reminder and the banner.
        if threads[index].hasOpenFlightPlan == false && wasOpen {
            notifications.cancelFlightPlanCloseReminder(threadId: threadId)
            if openFlightPlanNotice?.threadId == threadId { openFlightPlanNotice = nil }
        }

        saveThreads()
    }

    func setTaskNote(_ note: String?, taskId: UUID, threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[index].setNote(note, forTaskWithId: taskId)
        saveThreads()
    }

    /// Regenerate in place after the filed flag flipped, so the close-out task appears or disappears.
    private func regenerateAfterFilingChange(at index: Int) {
        var context = Self.context(for: nil, profile: threads[index].profile)
        context.flightPlanFiled = threads[index].flightPlanFiledAt != nil
        // A leg's trip-scoped rows live on the TRIP. `regenerateTasks` sets this and this path did
        // not, so `isLeg` defaulted to false and ticking "flight plan filed" on a leg re-created
        // weather/DABS/GAFOR/NOTAM/booking/debrief on it as pending duplicates of rows already
        // ticked in the trip band — dropping the leg from 6/6 to 6/11 and diverting START to the
        // outstanding-tasks prompt. (review F5)
        context.isLeg = threads[index].tripId != nil
        // Keep the route-derived parts of the existing tasks by regenerating from the tasks we have:
        // only the close-out task set depends on the filing flag, so a minimal context is enough to
        // decide it, and `generate` carries every other task's state across unchanged.
        let existing = threads[index].tasks
        context.hasRoute = existing.contains { $0.key == .routePlanned && $0.state == .done }
        let enriched = enrich(context, from: threads[index])
        threads[index].tasks = ThreadTaskEngine.generate(context: enriched, existing: existing)
        threads[index].touch()
    }

    /// Rebuild the subject-bearing parts of a context (PPR aerodromes, fee aerodromes, countries)
    /// from tasks that already exist, so a regeneration triggered by something other than a plan edit
    /// does not drop them.
    private func enrich(_ context: ThreadTaskEngine.Context,
                        from thread: FlightThread) -> ThreadTaskEngine.Context {
        var result = context
        let tasks = thread.tasks
        // Both route-derived facts come from the thread's own record. Re-deriving either one here
        // would mean guessing, and the guess that used to live here was "Switzerland".
        if let home = thread.homeCountry, !home.isEmpty { result.homeCountry = home }
        result.pprIdents = tasks.filter { $0.key == .pprObtained }.compactMap(\.subject)
        result.feeIdents = tasks.filter { $0.key == .feesPaid }.compactMap(\.subject)
        // The thread's own record, never a reconstruction. The customs tasks name only FOREIGN
        // countries, so rebuilding the list from them required adding the home country back — and
        // with home hard-coded to CH that put Switzerland on every route in the world, which is
        // exactly how a Slovakia → Germany flight grew a DABS task and a "Swiss side" link.
        result.countries = thread.countries ?? []
        // Keep the computed auto-task details rather than recomputing them from a context that no
        // longer has the plan.
        if let fuel = tasks.first(where: { $0.key == .fuelPlanned }), fuel.state == .done {
            result.fuelRequiredLitres = 1
            result.fuelOnBoardLitres = 1
        }
        if let weather = tasks.first(where: { $0.key == .weatherBriefed }) {
            result.weatherSummary = weather.detail
        }
        return result
    }

    // MARK: - Lifecycle

    /// Which followed flight, if any, the flight now starting is being flown for.
    ///
    /// Deliberately has NO "current thread" fallback, unlike `threadToCloseOut`. Attaching states a
    /// fact — and once stated, `threadToCloseOut`'s first branch trusts it absolutely, so a guess
    /// made here would be cemented rather than re-examined at the end. Only two signals are exact
    /// enough: the pilot pressed START FLIGHT inside a followed flight, or a plan is armed and one
    /// of them follows it. A flight with neither is left to resolve at the end, where the looser
    /// rule at least knows the flight actually happened.
    func threadToAttach(explicitThreadId: UUID?, planId: UUID?) -> UUID? {
        if let explicitThreadId,
           let explicit = thread(withId: explicitThreadId), !explicit.isFinished {
            return explicit.id
        }
        if let planId, let byPlan = thread(forPlanId: planId) { return byPlan.id }
        return nil
    }

    /// Link a followed flight to the flight that just started, and move it into FLY.
    func attachFlight(_ flightId: UUID, toThreadId threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        // Finishing a thread is optional, so a thread that already flew and closed out is still
        // `!isFinished` and `thread(forPlanId:)` will hand it back when the pilot re-arms the same
        // saved route. Carrying the previous flight's filing latches into the new one made
        // `hasOpenFlightPlan` false for a plan that was genuinely open — no banner, no reminder,
        // on the second flight. A new flight is a new chapter. (review F4)
        if threads[index].state == .closeOut || threads[index].flightId != nil {
            threads[index].beginNewChapter()
        }
        threads[index].flightId = flightId
        threads[index].state = .flying
        threads[index].touch()
        notifications.cancelPreparationReminder(threadId: threadId)
        saveThreads()
    }

    /// Undo `attachFlight` for a flight the pilot abandoned.
    ///
    /// An abandoned flight did not happen, so the followed flight goes back to where it was: no
    /// flight id, and out of FLY. It returns to READY rather than PLANNED — the preparation was
    /// genuinely done, and making the pilot re-tick a briefing they really did perform would be the
    /// app lying in the other direction. (v5.x)
    func detachAbandonedFlight(_ flightId: UUID) {
        guard let index = threads.firstIndex(where: { $0.flightId == flightId && $0.state == .flying })
        else { return }
        threads[index].flightId = nil
        threads[index].state = .ready
        threads[index].touch()
        // The flight is off again, so the preparation nudge is due again if it has not passed.
        reschedulePreparationReminder(at: index, from: nil)
        saveThreads()
    }

    /// Move a thread into close-out when its flight ends. Returns the thread if it has work left.
    @discardableResult
    func beginCloseOut(threadId: UUID, flightId: UUID?) -> FlightThread? {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return nil }
        if let flightId { threads[index].flightId = flightId }
        threads[index].state = .closeOut
        threads[index].touch()

        // The banner and the reminder only exist when there is a filed plan still open — which is what
        // keeps a circuit session, or a flight that was never filed, completely quiet.
        if threads[index].hasOpenFlightPlan {
            openFlightPlanNotice = OpenFlightPlanNotice(threadId: threadId,
                                                        routeLabel: threads[index].routeLabel)
            scheduleCloseReminderIfNeeded(threadId: threadId)
        }
        saveThreads()
        return threads[index]
    }

    /// Which thread, if any, should go into close-out for a flight that just ended.
    ///
    /// Resolved from the flight and its plan rather than from a link made at flight start, so a flight
    /// launched from the widget or a deep link closes out its thread just like one started from Home.
    ///
    /// That last fallback is the loose one, and it has to be: a widget launch carries neither a thread
    /// nor a plan, so "the thread the pilot is currently following" is the only signal left. What it
    /// cannot see on its own is that the flight just flown was a DIFFERENT flight from the one in the
    /// list — and a circuit session is exactly that case, every time. Circuits are flown with no plan
    /// (`FlightLauncher` drops it), so without this guard a session of touch-and-gos would push a
    /// cross-country thread planned for Saturday into close-out, complete with its close-your-flight-
    /// plan banner for a flight that has not happened.
    ///
    /// A `.local` thread is still adopted: a planned circuit session IS this flight.
    func threadToCloseOut(flightId: UUID?, planId: UUID?,
                          isCircuitMode: Bool = false,
                          isUnplanned: Bool = false) -> UUID? {
        if let flightId, let byFlight = threads.first(where: { $0.flightId == flightId && !$0.isFinished }) {
            return byFlight.id
        }
        if let planId, let byPlan = thread(forPlanId: planId) { return byPlan.id }
        // "Fly without a plan" is the pilot stepping deliberately around a flight they had planned.
        // Adopting it here would close out the very flight they chose not to fly.
        if !isUnplanned,
           let current = currentThread, !current.isFinished, current.state != .closeOut,
           !(isCircuitMode && current.profile == .full),
           Self.isPlausiblyToday(current) {
            return current.id
        }
        return nil
    }

    /// Whether a thread could be the flight that was just flown, judged by its date alone.
    ///
    /// The fallback's whole problem is that it cannot see WHICH flight was flown, so the one thing
    /// it can still check is that the candidate is not scheduled for some other day. Without this a
    /// Thursday evening hop closed out Saturday's cross-country: the pilot got a close-your-flight-
    /// plan banner for a flight that had not happened, and — if they obeyed it — Saturday's real
    /// flight then reported `hasOpenFlightPlan == false` and raised no banner and no reminder at
    /// all. Guarding the circuits case alone was not enough, because Home offers no "not this one"
    /// button on a day with no hero flight. (review F2)
    ///
    /// A thread with NO scheduled departure stays eligible: that is the widget/deep-link case the
    /// fallback exists for, and it carries no date to contradict.
    static func isPlausiblyToday(_ thread: FlightThread, now: Date = Date()) -> Bool {
        guard let departure = thread.scheduledDeparture else { return true }
        return Calendar.current.isDate(departure, inSameDayAs: now)
    }

    /// The followed flight START FLIGHT should be about, if any.
    ///
    /// A flight already in FLY comes first — that is a session the pilot left and is coming back to,
    /// and offering to arm tomorrow's plan instead of resuming it is how the app ended up talking
    /// about the wrong flight entirely. Otherwise the one scheduled for today. (v5.x)
    var startableFlightToday: FlightThread? {
        if let flying = threads.first(where: { $0.state == .flying }) { return flying }
        let calendar = Calendar.current
        return threads
            .filter { !$0.isFinished && $0.state != .closeOut }
            .filter { thread in
                guard let departure = thread.scheduledDeparture else { return false }
                return calendar.isDateInToday(departure)
            }
            .min { ($0.scheduledDeparture ?? .distantFuture) < ($1.scheduledDeparture ?? .distantFuture) }
    }

    // MARK: - Circuits (v5.x)

    /// Offer to close out a circuit session that ran without a thread.
    ///
    /// Circuits are start-now-only by design — there is no way to plan one, so a session of
    /// touch-and-gos reaches END FLIGHT with nothing to resolve and used to get no close-out at all:
    /// no logbook line, no debrief. That is exactly the `.local` profile's job.
    ///
    /// An OFFER rather than a thread created behind the pilot's back. A thread is optional
    /// throughout, and putting unearned admin in front of a student who just flew six circuits is
    /// what that rule exists to prevent. Silence is dismissible; a spawned thread is a chore.
    func offerCircuitCloseOut(flightId: UUID, departureIdent: String?, aircraftRegistration: String?) {
        let ident = departureIdent?.trimmingCharacters(in: .whitespaces).uppercased()
        circuitCloseOutOffer = CircuitCloseOutOffer(
            flightId: flightId,
            routeLabel: (ident?.isEmpty == false)
                ? L10n.Flights.circuitsAt(ident!)
                : L10n.Button.circuits,
            aircraftRegistration: aircraftRegistration
        )
    }

    /// Accept the offer: a `.local` thread already in close-out, holding the session's own tasks.
    @discardableResult
    func acceptCircuitCloseOut(_ offer: CircuitCloseOutOffer) -> FlightThread {
        let thread = createThread(from: nil,
                                  profile: .local,
                                  routeLabel: offer.routeLabel,
                                  aircraftRegistration: offer.aircraftRegistration)
        circuitCloseOutOffer = nil
        // Straight to CLOSE: the flying already happened, so PLAN and PREPARE have nothing to ask.
        beginCloseOut(threadId: thread.id, flightId: offer.flightId)
        return thread
    }

    /// Arm the one reminder that matters. Safe to call more than once — scheduling replaces by
    /// identifier, so repeated full-stops in a circuit session just move it.
    ///
    /// `delay` distinguishes the two arming points. END FLIGHT uses the short one: the pilot has the
    /// app open and the in-app banner is already up. A confirmed full-stop landing uses the long
    /// one, and is the case that actually needs a notification — the pilot who lands, shuts down and
    /// walks away without pressing anything used to get NO prompt at all before Skyguide's RCC
    /// alerted at ETA+30, because this was only ever called from `beginCloseOut` despite the comment
    /// here claiming the detector called it. (review F6)
    func scheduleCloseReminderIfNeeded(threadId: UUID,
                                       delay: TimeInterval = NotificationService.postFlightDelay) {
        guard let thread = thread(withId: threadId), thread.hasOpenFlightPlan else { return }
        Task { [notifications] in
            await notifications.scheduleFlightPlanCloseReminder(threadId: thread.id,
                                                               routeLabel: thread.routeLabel,
                                                               delay: delay)
        }
    }

    /// A full-stop landing was confirmed for the running flight: arm the close reminder on whatever
    /// thread that flight belongs to, without waiting for END FLIGHT.
    ///
    /// Resolution is deliberately narrower than `threadToCloseOut`'s: only an EXACT `flightId`
    /// match, never the `currentThread` fallback. Arming a reminder is cheap to get right and
    /// expensive to get wrong, and this fires automatically with nothing the pilot can see or
    /// correct — so it must not guess. (review F6)
    func noteFullStopLanding(flightId: UUID) {
        guard let thread = threads.first(where: { $0.flightId == flightId && !$0.isFinished }) else { return }
        scheduleCloseReminderIfNeeded(threadId: thread.id, delay: NotificationService.landingDelay)
    }

    /// A close requested before the threads finished loading, replayed once they have.
    ///
    /// The notification action can arrive at cold launch, while `loadThreadsAsync` is still reading
    /// an iCloud-backed directory. Returning silently from an empty array meant the pilot confirmed
    /// the plan was closed and the app kept the thread open, then re-raised the banner. (review F17)
    private var deferredCloseRequests: Set<UUID> = []

    /// Mark the flight plan closed — from the banner, the task row, or the notification action.
    func markFlightPlanClosed(threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else {
            if !hasLoadedThreads { deferredCloseRequests.insert(threadId) }
            return
        }
        threads[index].flightPlanClosedAt = Date()
        if let task = threads[index].tasks.first(where: { $0.key == .flightPlanClosed }) {
            threads[index].setState(.done, forTaskWithId: task.id)
        }
        threads[index].touch()
        notifications.cancelFlightPlanCloseReminder(threadId: threadId)
        if openFlightPlanNotice?.threadId == threadId { openFlightPlanNotice = nil }
        saveThreads()
    }

    /// Finish a thread. Anything still pending stays pending — the thread simply stops asking.
    func finishThread(threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        threads[index].state = .done
        threads[index].touch()
        notifications.cancelAll(threadId: threadId)
        if currentThreadId == threadId {
            currentThreadId = nil
            saveCurrentThreadPointer()
        }
        if openFlightPlanNotice?.threadId == threadId { openFlightPlanNotice = nil }
        saveThreads()
    }

    func deleteThread(threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        let thread = threads[index]
        // Backstop for any caller that is not `removeLeg`: never leave a trip holding an id whose
        // thread no longer exists. `removeLeg` has already done this (and handles dissolving the
        // trip properly); this only catches a leg deleted by some other path. (review F14)
        for tripIndex in trips.indices where trips[tripIndex].legIds.contains(threadId) {
            trips[tripIndex].legIds.removeAll { $0 == threadId }
            trips[tripIndex].touch()
            saveTrips()
        }
        threads.remove(at: index)
        lastPersisted[threadId] = nil
        deletedThreadIds.insert(threadId)
        persistence.deleteFlightThread(thread)
        notifications.cancelAll(threadId: threadId)
        if currentThreadId == threadId {
            currentThreadId = nil
            saveCurrentThreadPointer()
        }
        if openFlightPlanNotice?.threadId == threadId { openFlightPlanNotice = nil }
    }

    func setCurrentThread(_ threadId: UUID?) {
        currentThreadId = threadId
        saveCurrentThreadPointer()
    }

    /// A thread whose flight plan was filed and never closed after landing.
    struct OpenFlightPlanNotice: Equatable {
        let threadId: UUID
        let routeLabel: String
    }

    /// A circuit session that ended without a thread, and the offer to close it out. (v5.x)
    struct CircuitCloseOutOffer: Equatable {
        let flightId: UUID
        let routeLabel: String
        let aircraftRegistration: String?
    }

    // MARK: - Context building

    /// Build the engine context from a plan, resolving the countries the route crosses.
    ///
    /// Main-actor because the border test reads `CountryBoundaries.shared`; the pure work lives in the
    /// `countries:` overload below so tests (and any off-main caller) can drive it directly.
    @MainActor
    static func context(for plan: FlightPlan?,
                        profile: ThreadProfile,
                        homeCountry: String? = nil) -> ThreadTaskEngine.Context {
        let crossed: [String] = plan.map { plan in
            RouteDataCalculator.countries(crossing: plan.waypoints.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            })
        } ?? []
        return context(for: plan,
                       profile: profile,
                       homeCountry: homeCountry ?? departureCountry(of: plan) ?? deviceCountry(),
                       countries: crossed)
    }

    /// The country you are departing FROM, which is what decides which of the crossed countries are
    /// foreign. Hard-coding this to CH meant a Slovak pilot leaving Slovakia was told to clear
    /// customs into their own country, and that Switzerland was somehow involved.
    static func departureCountry(of plan: FlightPlan?) -> String? {
        guard let first = plan?.waypoints.first else { return nil }
        let at = CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude)
        return RouteDataCalculator.countries(crossing: [at]).first
    }

    /// Last resort for a thread with no route at all — circuits with no plan, typically flown at
    /// home. The device's own region is a far better guess than a constant, and it is the same
    /// signal onboarding already uses to propose which data to download.
    nonisolated static func deviceCountry() -> String {
        Locale.current.region?.identifier ?? ""
    }

    /// Pure context builder. `countries` is supplied by the caller because deciding which countries a
    /// route crosses needs the main actor, and everything else here does not.
    nonisolated static func context(for plan: FlightPlan?,
                                    profile: ThreadProfile,
                                    homeCountry: String = "CH",
                                    countries: [String]) -> ThreadTaskEngine.Context {
        var context = ThreadTaskEngine.Context(profile: profile, homeCountry: homeCountry)
        guard let plan, !plan.waypoints.isEmpty else {
            // No route at all — a circuit session, flown at home by definition. Assuming the home
            // country here is reasonable; assuming it for a route we simply failed to measure is not,
            // which is why the two cases are separated.
            context.countries = countries.isEmpty ? [homeCountry].filter({ !$0.isEmpty }) : countries
            return context
        }

        context.hasRoute = plan.waypoints.count >= 2
        let idents = plan.waypoints.map(\.name).map { $0.trimmingCharacters(in: .whitespaces) }
        context.departureIdent = idents.first
        context.arrivalIdent = idents.last

        // Only landings AWAY from the departure field can attract a fee. Waypoint names are free
        // text (they can be "JORAT VOR"), so restrict this to things shaped like an ICAO ident.
        if let arrival = context.arrivalIdent,
           arrival != context.departureIdent,
           Self.looksLikeICAO(arrival) {
            context.feeIdents = [arrival]
        }

        // A route we could not resolve to any country is UNKNOWN, not "at home". Substituting the
        // home country here is what put Swiss products on flights that never approach Switzerland;
        // an empty list simply produces no country-specific tasks, which is the honest outcome.
        context.countries = countries

        // A plan with no fuel figures entered leaves the fuel task pending rather than claiming a
        // zero-litre flight is adequately fuelled.
        context.fuelRequiredLitres = plan.fuelRequired ?? 0
        context.fuelOnBoardLitres = plan.fuelOnBoard ?? 0
        return context
    }

    /// Four letters, all uppercase — good enough to tell "LSGY" from "JORAT VOR" without an airport
    /// lookup, and a wrong guess only costs a task the pilot can dismiss.
    nonisolated static func looksLikeICAO(_ value: String) -> Bool {
        value.count == 4 && value.allSatisfy { $0.isLetter && $0.isUppercase }
    }

    nonisolated static func routeLabel(for plan: FlightPlan?) -> String {
        guard let plan else { return L10n.Thread.untitledFlight }
        let names = plan.waypoints.map(\.name).filter { !$0.isEmpty }
        if names.count >= 2, let first = names.first, let last = names.last { return "\(first) → \(last)" }
        return plan.name.isEmpty ? (names.first ?? L10n.Thread.untitledFlight) : plan.name
    }

    // MARK: - Persistence

    /// Persist only the threads that changed, off the main actor — same dirty-diff shape the plan
    /// manager uses, for the same reason (this is called on every task tick).
    /// Threads deleted while a save was in flight.
    ///
    /// `deleteThread` removes the file synchronously on the main actor while `saveThreads` writes
    /// from a detached utility task. Tick a task and then delete that flight in the next touch
    /// event, and the late write could re-create the file — resurrecting a thread the pilot
    /// deleted, with `lastPersisted` already cleared so nothing ever noticed. (review, concurrency)
    private var deletedThreadIds: Set<UUID> = []

    private func saveThreads() {
        let changed = threads.filter { lastPersisted[$0.id] != $0 }
        guard !changed.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            // Re-read on the main actor AFTER the hop: anything deleted in the meantime is dropped.
            let live = changed.filter { !self.deletedThreadIds.contains($0.id) }
            guard !live.isEmpty else { return }
            let written = await self.persistence.saveFlightThreadsOffMain(changed: live)
            let confirmed = Set(written)
            for thread in live where confirmed.contains(thread.id) && !self.deletedThreadIds.contains(thread.id) {
                self.lastPersisted[thread.id] = thread
            }
        }
    }

    private func loadThreadsAsync() async {
        let loaded = await persistence.loadFlightThreadsOffMain()
        let existingIds = Set(threads.map(\.id))
        let merged = threads + loaded.filter { !existingIds.contains($0.id) }
        threads = merged.sorted { $0.createdAt > $1.createdAt }
        for thread in loaded where lastPersisted[thread.id] == nil {
            lastPersisted[thread.id] = thread
        }
        // A pointer to a thread that no longer exists would leave Home advertising nothing.
        if let current = currentThreadId, !threads.contains(where: { $0.id == current }) {
            currentThreadId = nil
            saveCurrentThreadPointer()
        }
        hasLoadedThreads = true
        // Replay anything the pilot confirmed while this load was still in flight.
        let deferred = deferredCloseRequests
        deferredCloseRequests = []
        for threadId in deferred { markFlightPlanClosed(threadId: threadId) }
    }

    private func saveCurrentThreadPointer() {
        if let id = currentThreadId {
            defaults.set(id.uuidString, forKey: currentThreadKey)
        } else {
            defaults.removeObject(forKey: currentThreadKey)
        }
    }

    private func loadCurrentThreadPointer() {
        guard let raw = defaults.string(forKey: currentThreadKey) else { return }
        currentThreadId = UUID(uuidString: raw)
    }
}

// MARK: - Helpers

private extension Array where Element: Hashable {
    /// Order-preserving de-duplication.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
