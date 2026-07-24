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

    #if canImport(ActivityKit)
    private var activity: Activity<FlightActivityAttributes>?
    private var lastState: FlightActivityAttributes.ContentState?

    /// Reflect the current flight into the Live Activity: starts one when a flight is active,
    /// pushes an update when the observable state changed, ends it when the flight is over.
    func sync(from appState: AppState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard appState.isFlightActive, let flight = appState.currentFlight else {
            end()
            return
        }

        let state = FlightActivityAttributes.ContentState(
            phaseName: appState.currentPhase.title,
            startTime: appState.engineStartTime ?? flight.startTime,
            touchAndGoCount: flight.touchAndGoCount,
            fullStopCount: flight.fullStopCount,
            isCircuitMode: appState.isCircuitMode
        )

        if let activity {
            guard state != lastState else { return }
            lastState = state
            let content = ActivityContent(state: state, staleDate: nil)
            Task { await activity.update(content) }
        } else {
            let attributes = FlightActivityAttributes(
                aircraftName: flight.displayName,
                registration: flight.aircraftRegistration ?? flight.airplane
            )
            // A denied/failed request is silently tolerated — the activity is a convenience
            // surface, never load-bearing for the flight itself.
            activity = try? Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil)
            )
            lastState = activity != nil ? state : nil
        }
    }

    /// End the activity, keeping the final state visible briefly before the system removes it.
    func end() {
        guard let activity else { return }
        let finalContent = lastState.map { ActivityContent(state: $0, staleDate: nil) }
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
