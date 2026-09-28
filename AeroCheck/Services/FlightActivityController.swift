import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Which of the app's Live Activities belongs on screen. Pure, so it is tested without ActivityKit.
enum LiveActivityTriage {
    struct Item: Equatable {
        /// The flight the activity was started for; nil for one started before activities carried it.
        let flightId: UUID?
        /// Still running (active or stale), as opposed to ended or dismissed.
        let isLive: Bool
    }

    /// Keep the first live activity of the current flight, if there is one; end everything else:
    /// a previous flight's, an ended one still on screen, a duplicate, one from an older build.
    /// With no flight in progress, nothing is kept.
    static func decide(_ items: [Item], currentFlightId: UUID?) -> (keep: Int?, end: [Int]) {
        let keep = currentFlightId.flatMap { id in
            items.firstIndex { $0.flightId == id && $0.isLive }
        }
        return (keep, items.indices.filter { $0 != keep })
    }
}

/// Starts, updates and ends the in-flight Live Activity (Lock Screen + Dynamic Island). (UX-25)
///
/// Updates are event-driven and deduplicated: `sync(from:)` is cheap to call often (it diffs the
/// content state and no-ops when nothing changed), and the elapsed-time clock in the activity UI
/// is a self-ticking `Text(timerInterval:)` — the system is never asked for per-second updates,
/// staying far inside ActivityKit's update budget.
///
/// There is only ever one activity, the current flight's. Each activity carries its flight's id, and
/// whenever the flight changes (a launch, a new flight, the end of one) the controller goes through
/// everything ActivityKit holds for the app and ends what isn't that flight's. It used to adopt the
/// first activity it found and end others only once per launch, and to leave an ended flight's on the
/// Lock Screen for 15 minutes with its clock still running. A flight started in those 15 minutes
/// showed two, a launch without a flight to resume cleaned up nothing, and a quit app left its
/// flight's activity running. (Live Activities, 6.0)
@MainActor
final class FlightActivityController {
    static let shared = FlightActivityController()
    private init() {}

    /// Supplies the active flight plan's next-waypoint name. Wired once at startup (AeroCheckApp) —
    /// AppState deliberately has no FlightPlanManager reference, so the dependency stays inverted.
    var nextWaypointProvider: (() -> String?)?

    #if canImport(ActivityKit)
    private var activity: Activity<FlightActivityAttributes>?
    private var lastState: FlightActivityAttributes.ContentState?
    /// The flight the app's activities were last put in order for; `hasReconciled` false until the
    /// first time. Reconciling again only when the flight changes keeps the per-fix `sync` cheap.
    private var reconciledFlightId: UUID?
    private var hasReconciled = false

    /// How long a Live Activity may keep showing its last values before the system marks it stale.
    ///
    /// `staleDate` was nil, meaning never stale. On a Lock Screen widget showing phase, elapsed time
    /// and landing counts, that is the app promising the numbers are current when updates may have
    /// stopped minutes ago — the same failure class as showing a cached wind as live. Ten minutes is
    /// comfortably longer than any normal gap between phase changes, and short enough that a
    /// backgrounded-out or crashed app stops looking authoritative.
    private static let staleAfter: TimeInterval = 10 * 60

    private func content(_ state: FlightActivityAttributes.ContentState)
        -> ActivityContent<FlightActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
    }

    private static func isLive(_ state: ActivityState) -> Bool {
        switch state {
        case .active, .stale: return true
        default: return false
        }
    }

    /// Put the app's activities in order for `flightId` (nil: no flight in progress): adopt the
    /// flight's own if it is still running, end every other one at once.
    ///
    /// The in-memory `activity` reference does not survive the process: after a force-quit, a crash
    /// or an OS termination mid-flight, the system activity lives on with nothing pointing at it.
    /// The restored flight adopts it here; any other is ended.
    private func reconcile(for flightId: UUID?) {
        guard !hasReconciled || reconciledFlightId != flightId else { return }
        hasReconciled = true
        reconciledFlightId = flightId

        let all = Activity<FlightActivityAttributes>.activities
        let decision = LiveActivityTriage.decide(
            all.map { .init(flightId: $0.attributes.flightId, isLive: Self.isLive($0.activityState)) },
            currentFlightId: flightId
        )
        activity = decision.keep.map { all[$0] }
        // Pushes a fresh update to an adopted activity rather than diffing against a state this
        // process never observed.
        lastState = nil
        for index in decision.end {
            let orphan = all[index]
            Task { await orphan.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Reflect the current flight into the Live Activity: starts one when a flight is active,
    /// pushes an update when the observable state changed, ends it when the flight is over.
    /// Also called once at launch, which tidies up after a process that didn't end its own.
    func sync(from appState: AppState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard appState.isFlightActive, let flight = appState.currentFlight else {
            end()
            return
        }
        reconcile(for: flight.id)

        let state = FlightActivityAttributes.ContentState(
            phaseName: appState.currentPhase.title,
            startTime: appState.engineStartTime ?? flight.startTime,
            nextWaypointName: nextWaypointProvider?(),
            touchAndGoCount: flight.touchAndGoCount,
            fullStopCount: flight.fullStopCount,
            isCircuitMode: appState.isCircuitMode
        )

        if let activity {
            // Not re-requested once the pilot has swiped it away: this flight had its activity.
            guard state != lastState else { return }
            lastState = state
            Task { [content = content(state)] in await activity.update(content) }
        } else {
            let attributes = FlightActivityAttributes(
                aircraftName: flight.displayName,
                registration: flight.aircraftRegistration ?? flight.airplane,
                flightId: flight.id
            )
            // A denied/failed request is silently tolerated — the activity is a convenience
            // surface, never load-bearing for the flight itself.
            activity = try? Activity.request(attributes: attributes, content: content(state))
            lastState = activity != nil ? state : nil
        }
    }

    /// The flight is over: every activity the app has goes, at once. The flight's summary is in the
    /// app; one kept on the Lock Screen with its clock still running read as a flight in progress.
    func end() {
        activity = nil
        lastState = nil
        hasReconciled = true
        reconciledFlightId = nil
        for leftover in Activity<FlightActivityAttributes>.activities {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// The app is being quit: nothing will update the activity any more, so it goes now, flight or
    /// not. A flight restored at the next launch gets a new one. This is the only chance there is,
    /// so it waits up to two seconds for ActivityKit; a system kill never gets here, and the next
    /// launch tidies up instead.
    func endAllBeforeTermination() {
        let all = Activity<FlightActivityAttributes>.activities
        guard !all.isEmpty else { return }
        activity = nil
        lastState = nil
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for leftover in all { await leftover.end(nil, dismissalPolicy: .immediate) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }
    #endif
}
