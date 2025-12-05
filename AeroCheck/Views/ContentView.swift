import SwiftUI

/// Root content view that switches between home and flight views
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var locationManager: LocationManager
    
    var body: some View {
        ZStack {
            if appState.isFlightActive {
                FlightView()
                    .transition(.opacity)
            } else {
                HomeView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.isFlightActive)
        .onAppear {
            // Request location permission on app launch
            locationManager.requestAuthorization()
            
            // Apply screen setting
            UIApplication.shared.isIdleTimerDisabled = appState.settings.keepScreenOn
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(LocationManager())
}
