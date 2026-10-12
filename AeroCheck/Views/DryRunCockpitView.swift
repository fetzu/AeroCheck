import SwiftUI

// MARK: - Dry run (6.4.0): the Cockpit, in a dry run's world

private struct IsDryRunKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// A dry run's Cockpit: what would reach out of the app from a real flight's (the Companion toggle) it
    /// doesn't offer. (6.4.0)
    var isDryRun: Bool {
        get { self[IsDryRunKey.self] }
        set { self[IsDryRunKey.self] = newValue }
    }
}

/// The real Cockpit over the app, on the dry run's world: its AppState, GPS, plans, threads, detector, an inert
/// Companion manager and a radio that tells the Watch nothing. The data the app shares with every flight (the
/// airports, the maps, the weather) comes from the app's environment. The dry run ends with its flight: END
/// FLIGHT or abandoning it. The app leaving the foreground pauses it (D2). (6.4.0)
struct DryRunCockpitView: View {
    @ObservedObject var session: DryRunSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let world = session.world
        FlightView(radio: world.radio)
            .environment(world.appState)
            .environmentObject(world.location)
            .environmentObject(world.plans)
            .environmentObject(world.threads)
            .environmentObject(world.detector)
            .environmentObject(world.companion)
            .environment(\.isDryRun, true)
            .onChange(of: world.appState.isFlightActive) { _, flying in
                if !flying { DryRunCenter.shared.end() }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background: session.pause()
                // Back at once, until the dry run has controls of its own (PR 5: it waits for the pilot).
                case .active: session.resume()
                default: break
                }
            }
    }
}
