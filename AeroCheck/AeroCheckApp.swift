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
        }
    }
}
