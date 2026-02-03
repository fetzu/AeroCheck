import SwiftUI

/// Root content view that switches between home and flight views
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var windDataService: WindDataService
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.scenePhase) var scenePhase
    @State private var showMarketingControls: Bool = false
    @ObservedObject private var marketingProvider = MarketingLocationProvider.shared

    var body: some View {
        GeometryReader { geometry in
            let isCompactDevice = horizontalSizeClass == .compact
            let isLandscape = geometry.size.width > geometry.size.height

            ZStack {
                if !appState.settings.hasCompletedOnboarding {
                    OnboardingView()
                        .transition(.opacity)
                } else if appState.isFlightActive {
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

                // Marketing controls overlay (shown when shaking with marketing mode enabled)
                if showMarketingControls && appState.settings.marketingMode {
                    VStack {
                        HStack {
                            Spacer()
                            MarketingControlsView()
                                .padding(.top, 50)
                                .padding(.trailing, 16)
                        }
                        Spacer()
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: appState.settings.hasCompletedOnboarding)
            .animation(.easeInOut(duration: 0.3), value: appState.isFlightActive)
            .animation(.easeInOut(duration: 0.2), value: isLandscape)
            .animation(.easeInOut(duration: 0.3), value: showMarketingControls)
        }
        .onAppear {
            // Request location permission on app launch
            locationManager.requestAuthorization()

            // Apply screen setting
            UIApplication.shared.isIdleTimerDisabled = appState.settings.keepScreenOn
        }
        .onShake {
            // Toggle marketing controls when shaking (only if marketing mode is enabled)
            if appState.settings.marketingMode {
                showMarketingControls.toggle()
            }
        }
        .onChange(of: marketingProvider.currentLocation) { _, newLocation in
            // Inject marketing location into LocationManager when active
            if appState.settings.marketingMode && marketingProvider.isActive {
                if let location = newLocation {
                    locationManager.currentLocation = location
                    // Also override GPS status to show as good
                    locationManager.overrideGPSStatus(.good)
                }
            }
        }
        .onChange(of: marketingProvider.isActive) { _, isActive in
            // When marketing mode stops, clear the GPS status override
            if !isActive {
                locationManager.clearGPSStatusOverride()
            }
        }
        .sheet(isPresented: $appState.showFlightLog) {
            FlightLogView()
                .environmentObject(appState)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background, .inactive:
                // Save flight state when app goes to background or becomes inactive
                if appState.isFlightActive {
                    appState.saveActiveFlightState()
                }
                // Stop wind data fetching in background to save battery
                windDataService.stopFetching()
            case .active:
                // On app start, deactivate flight plan if no flight is in progress
                // This is handled after flight state restoration, so if a flight was
                // restored, isFlightActive will be true and we keep the flight plan
                if !appState.isFlightActive {
                    flightPlanManager.deactivateFlightPlan()
                }
                // Resume wind data fetching if flight is active and estimated airspeed is enabled
                if appState.isFlightActive && appState.settings.showEstimatedAirspeed {
                    windDataService.startFetching(locationManager: locationManager)
                }
            @unknown default:
                break
            }
        }
    }
}

// MARK: - Shake Gesture Detection

/// Notification name for shake gesture
extension NSNotification.Name {
    static let deviceDidShake = NSNotification.Name("deviceDidShake")
}

/// UIWindow extension to detect shake gestures
extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
    }
}

/// View modifier to handle shake gestures
struct ShakeGestureModifier: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
                action()
            }
    }
}

extension View {
    /// Adds an action to perform when the device is shaken
    func onShake(perform action: @escaping () -> Void) -> some View {
        modifier(ShakeGestureModifier(action: action))
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
                    Text(L10n.ContentViewStrings.rotateDevice)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.primaryText)

                    Text(L10n.ContentViewStrings.portraitMode)
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
        .environmentObject(FlightPlanManager())
}
