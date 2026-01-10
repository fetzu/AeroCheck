import SwiftUI
import WatchConnectivity

@main
struct AeroCheckWatchApp: App {
    @StateObject private var connectivityManager = WatchConnectivityManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connectivityManager)
        }
    }
}
