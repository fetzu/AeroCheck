import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Starts, updates and ends the in-flight Live Activity (Lock Screen + Dynamic Island). (UX-25)
///
/// Updates are event-driven and deduplicated: `sync(from:)` is cheap to call often (it diffs the
/// content state and no-ops when nothing changed), and the elapsed-time clock in the activity UI
/// is a self-ticking `Text(timerInterval:)` — the system is never asked for per-second updates,
/// staying far inside ActivityKit's update budget.
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

    /// Adopt whatever ActivityKit already has running before deciding to start anything.
    ///
    /// The in-memory `activity` reference does NOT survive the process. A force-quit, a crash, or an
    /// OS termination while a flight was active left the system Activity alive with nothing pointing
    /// at it — so the next `sync` saw `activity == nil` and requested a SECOND one. The pilot ended
    /// up with duplicate Live Activities, one of them frozen at the moment the app died and
    /// unendable because no reference to it existed.
    ///
    /// Runs once per launch. Adopts the first activity and ends any extras, so a device that already
    /// accumulated duplicates converges back to one.
    private func reconcileWithSystem() {
        guard !hasReconciled else { return }
        hasReconciled = true

        let existing = Activity<FlightActivityAttributes>.activities
        guard let first = existing.first else { return }
        activity = first
        // lastState stays nil so the next sync pushes a fresh update rather than diffing against a
        // state this process never observed.
        for orphan in existing.dropFirst() {
            Task { await orphan.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// Reflect the current flight into the Live Activity: starts one when a flight is active,
    /// pushes an update when the observable state changed, ends it when the flight is over.
    func sync(from appState: AppState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        reconcileWithSystem()
        guard appState.isFlightActive, let flight = appState.currentFlight else {
            end()
            return
        }

        let state = FlightActivityAttributes.ContentState(
            phaseName: appState.currentPhase.title,
            startTime: appState.engineStartTime ?? flight.startTime,
            nextWaypointName: nextWaypointProvider?(),
            touchAndGoCount: flight.touchAndGoCount,
            fullStopCount: flight.fullStopCount,
            isCircuitMode: appState.isCircuitMode
        )

        if let activity {
            guard state != lastState else { return }
            lastState = state
            Task { [content = content(state)] in await activity.update(content) }
        } else {
            let attributes = FlightActivityAttributes(
                aircraftName: flight.displayName,
                registration: flight.aircraftRegistration ?? flight.airplane
            )
            // A denied/failed request is silently tolerated — the activity is a convenience
            // surface, never load-bearing for the flight itself.
            activity = try? Activity.request(attributes: attributes, content: content(state))
            lastState = activity != nil ? state : nil
        }
    }

    /// End the activity, keeping the final state visible briefly before the system removes it.
    func end() {
        // Reconcile first: ending only the reference this process happens to hold would leave an
        // activity adopted from a previous launch running forever.
        reconcileWithSystem()
        guard let activity else { return }
        let finalContent = lastState.map { content($0) }
        self.activity = nil
        lastState = nil
        Task {
            await activity.end(finalContent, dismissalPolicy: .after(Date(timeIntervalSinceNow: 15 * 60)))
        }
    }
    #else
    func sync(from appState: AppState) {}
    func end() {}
    #endif
}
