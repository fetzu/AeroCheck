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
            await self?.loadThreadsAsync()
            await self?.loadTrips()
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
        threads[index].countries = context.countries
        threads[index].homeCountry = context.homeCountry
        threads[index].tasks = ThreadTaskEngine.generate(context: context, existing: existing)

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
        guard threadIds.count >= 2 else { return nil }
        var trip = Trip(legIds: threadIds)

        if let firstIndex = threads.firstIndex(where: { $0.id == threadIds[0] }) {
            trip.sharedTasks = threads[firstIndex].tasks.filter { $0.key.scope == .trip }
        }
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
    func setSharedTaskState(_ state: ThreadTaskState, taskId: UUID, tripId: UUID) {
        guard let index = trips.firstIndex(where: { $0.id == tripId }),
              let taskIndex = trips[index].sharedTasks.firstIndex(where: { $0.id == taskId })
        else { return }
        trips[index].sharedTasks[taskIndex].state = state
        // Refreshing a stale briefing re-stamps it, which is what makes it cover the later legs.
        trips[index].sharedTasks[taskIndex].completedAt = (state == .done) ? Date() : nil
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

    private func saveTrips() {
        let snapshot = trips
        Task { await persistence.saveTripsOffMain(snapshot) }
    }

    private func loadTrips() async {
        trips = await persistence.loadTripsOffMain()
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
    func threadToCloseOut(flightId: UUID?, planId: UUID?, isCircuitMode: Bool = false) -> UUID? {
        if let flightId, let byFlight = threads.first(where: { $0.flightId == flightId && !$0.isFinished }) {
            return byFlight.id
        }
        if let planId, let byPlan = thread(forPlanId: planId) { return byPlan.id }
        if let current = currentThread, !current.isFinished, current.state != .closeOut,
           !(isCircuitMode && current.profile == .full) {
            return current.id
        }
        return nil
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

    /// Called by the flight-event detector when a full-stop landing is confirmed: arms the one
    /// reminder that matters. Safe to call more than once — scheduling replaces by identifier.
    func scheduleCloseReminderIfNeeded(threadId: UUID) {
        guard let thread = thread(withId: threadId), thread.hasOpenFlightPlan else { return }
        Task { [notifications] in
            await notifications.scheduleFlightPlanCloseReminder(threadId: thread.id,
                                                               routeLabel: thread.routeLabel)
        }
    }

    /// Mark the flight plan closed — from the banner, the task row, or the notification action.
    func markFlightPlanClosed(threadId: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
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
        threads.remove(at: index)
        lastPersisted[threadId] = nil
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
    private func saveThreads() {
        let changed = threads.filter { lastPersisted[$0.id] != $0 }
        guard !changed.isEmpty else { return }
        Task { [weak self] in
            let written = await self?.persistence.saveFlightThreadsOffMain(changed: changed) ?? []
            guard let self else { return }
            let confirmed = Set(written)
            for thread in changed where confirmed.contains(thread.id) {
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
