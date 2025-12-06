import SwiftUI

/// Root content view that switches between home and flight views
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var locationManager: LocationManager
    @Environment(\.horizontalSizeClass) var horizontalSizeClass

    var body: some View {
        GeometryReader { geometry in
            let isCompactDevice = horizontalSizeClass == .compact
            let isLandscape = geometry.size.width > geometry.size.height

            ZStack {
                if appState.isFlightActive {
                    FlightView()
                        .transition(.opacity)
                } else {
                    HomeView()
                        .transition(.opacity)
                }

                // Show rotation prompt on iPhone in landscape
                if isCompactDevice && isLandscape {
                    RotateToPortraitView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: appState.isFlightActive)
            .animation(.easeInOut(duration: 0.2), value: isLandscape)
        }
        .onAppear {
            // Request location permission on app launch
            locationManager.requestAuthorization()

            // Apply screen setting
            UIApplication.shared.isIdleTimerDisabled = appState.settings.keepScreenOn
        }
    }
}

// MARK: - Rotate to Portrait View

/// Overlay shown on iPhone when in landscape mode
struct RotateToPortraitView: View {
    var body: some View {
        ZStack {
            // Solid background to hide content underneath
            Color.cockpitBackground
                .ignoresSafeArea()

            VStack(spacing: 24) {
                // Rotation icon
                Image(systemName: "rectangle.portrait.rotate")
                    .font(.system(size: 64))
                    .foregroundColor(.aviationGold)

                VStack(spacing: 8) {
                    Text("Rotate Your Device")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.primaryText)

                    Text("This app is designed for portrait mode on iPhone")
                        .font(.system(size: 16))
                        .foregroundColor(.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                // Visual hint with phone icon
                HStack(spacing: 20) {
                    // Current orientation (crossed out)
                    ZStack {
                        Image(systemName: "iphone.landscape")
                            .font(.system(size: 32))
                            .foregroundColor(.dimText)
                        Image(systemName: "xmark")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.aviationRed)
                    }

                    Image(systemName: "arrow.right")
                        .font(.system(size: 20))
                        .foregroundColor(.dimText)

                    // Desired orientation
                    Image(systemName: "iphone")
                        .font(.system(size: 32))
                        .foregroundColor(.aviationGreen)
                }
                .padding(.top, 16)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(LocationManager())
}
