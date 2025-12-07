import SwiftUI

/// Main application entry point
@main
struct AeroCheckApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var locationManager = LocationManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(locationManager)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(locationManager)
                .preferredColorScheme(.dark)
        }
        #endif
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "aerocheck" else { return }

        switch url.host {
        case "start-flight":
            // Parse aircraft from query parameters
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let aircraft = components.queryItems?.first(where: { $0.name == "aircraft" })?.value {
                appState.startFlight(withAircraft: aircraft)
            }
        case "flight-log":
            appState.showFlightLog = true
        default:
            break
        }
    }
}
