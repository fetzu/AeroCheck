import Combine
import SwiftUI

/// Main content view for the Apple Watch app
/// Uses a TabView for swipe navigation between screens
struct ContentView: View {
    @EnvironmentObject var connectivityManager: WatchConnectivityManager
    @State private var now = Date()
    private let staleTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        // Staleness is re-evaluated every second so frozen live data is never shown as live. (UX-05)
        let stale = connectivityManager.isDataStale(asOf: now)
        ZStack(alignment: .top) {
            screens
                .opacity(stale ? 0.35 : 1)

            if stale {
                StaleBanner()
                    .padding(.top, 2)
            }
        }
        .onReceive(staleTimer) { now = $0 }
    }

    @ViewBuilder
    private var screens: some View {
        if connectivityManager.flightData.isFlightActive {
            // Active flight: show relevant screens
            if connectivityManager.flightData.hasActiveNavPlan {
                // With navigation plan: Nav screen + Flight screen
                TabView {
                    NavigationScreen()
                        .environmentObject(connectivityManager)

                    FlightScreen()
                        .environmentObject(connectivityManager)
                }
                .tabViewStyle(.verticalPage)
            } else {
                // No navigation plan: just Flight screen
                FlightScreen()
                    .environmentObject(connectivityManager)
            }
        } else {
            // No active flight: show standby screen
            StandbyScreen()
                .environmentObject(connectivityManager)
        }
    }
}

/// Prominent "stale data" indicator shown over live screens when the phone link drops. (UX-05)
struct StaleBanner: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 11, weight: .bold))
            Text("NO DATA")
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundColor(.black)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.orange))
    }
}

// MARK: - Standby Screen (No active flight)

struct StandbyScreen: View {
    @EnvironmentObject var connectivityManager: WatchConnectivityManager
    @State private var currentTime = Date()

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            // App icon/branding
            Image(systemName: "airplane")
                .font(.system(size: 24))
                .foregroundColor(.aviationGold)

            Text("AeroCheck")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.aviationGold)

            Spacer()

            // Current time display
            TimeDisplayView(
                time: currentTime,
                useUTC: connectivityManager.flightData.alwaysUseUTC,
                style: .medium
            )

            Spacer()

            // Status
            HStack(spacing: 4) {
                Circle()
                    .fill(connectivityManager.isConnected ? Color.aviationGreen : Color.gray)
                    .frame(width: 8, height: 8)

                Text(connectivityManager.isConnected ? "Connected" : "Waiting...")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Text("Start flight on iPhone")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(Color.black)
        .onReceive(timer) { time in
            currentTime = time
        }
    }
}

// MARK: - Flight Screen (Time + Phase)

struct FlightScreen: View {
    @EnvironmentObject var connectivityManager: WatchConnectivityManager
    @State private var currentTime = Date()

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 4) {
            // Current time - large and prominent
            TimeDisplayView(
                time: currentTime,
                useUTC: connectivityManager.flightData.alwaysUseUTC,
                style: .large
            )

            Divider()
                .background(Color.aviationGold.opacity(0.5))
                .padding(.vertical, 2)

            // Flight time
            VStack(spacing: 2) {
                Text("FLIGHT TIME")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)

                Text(connectivityManager.formattedFlightTime)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(.aviationGreen)
            }

            Spacer()

            // Current and next phase
            VStack(spacing: 4) {
                // Current phase
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.aviationGreen)
                        .font(.system(size: 12))

                    Text(connectivityManager.flightData.currentPhaseName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                // Next phase
                if let nextPhase = connectivityManager.flightData.nextPhaseName {
                    HStack {
                        Image(systemName: "arrow.right.circle")
                            .foregroundColor(.aviationGold)
                            .font(.system(size: 10))

                        Text(nextPhase)
                            .font(.system(size: 10))
                            .foregroundColor(.aviationGold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.panelBackground)
            )
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .background(Color.black)
        .onReceive(timer) { time in
            currentTime = time
        }
    }
}

// MARK: - Navigation Screen

struct NavigationScreen: View {
    @EnvironmentObject var connectivityManager: WatchConnectivityManager

    var body: some View {
        VStack(spacing: 6) {
            // Waypoint name and progress
            HStack {
                Text(connectivityManager.flightData.currentWaypointName ?? "---")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.aviationGold)
                    .lineLimit(1)

                Spacer()

                if let current = connectivityManager.flightData.currentWaypointIndex,
                   let total = connectivityManager.flightData.totalWaypoints {
                    Text("\(current + 1)/\(total)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Divider()
                .background(Color.aviationGold.opacity(0.3))

            // Navigation data grid
            HStack(spacing: 12) {
                // Heading/Bearing
                NavigationDataCell(
                    label: "HDG",
                    value: formatBearing(connectivityManager.flightData.bearingToWaypoint),
                    unit: nil
                )

                // Distance
                NavigationDataCell(
                    label: "DIST",
                    value: formatDistance(connectivityManager.flightData.distanceToWaypointNM),
                    unit: "NM"
                )

                // EET
                NavigationDataCell(
                    label: "EET",
                    value: connectivityManager.formattedEET ?? "--:--",
                    unit: nil
                )
            }

            Divider()
                .background(Color.aviationGold.opacity(0.3))

            // Frequencies section
            VStack(spacing: 4) {
                Text("FREQUENCIES")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)

                // Current waypoint frequency
                if let freq = connectivityManager.flightData.currentWaypointFrequency {
                    FrequencyRow(name: "WPT", frequency: freq, isActive: true)
                }

                // Next waypoint frequency
                if let nextFreq = connectivityManager.flightData.nextWaypointFrequency {
                    FrequencyRow(name: "NEXT", frequency: nextFreq, isActive: false)
                }

                // Show a couple common frequencies
                if let commonFreqs = connectivityManager.flightData.commonFrequencies?.prefix(2) {
                    ForEach(Array(commonFreqs)) { freq in
                        FrequencyRow(name: freq.name, frequency: freq.frequency, isActive: false)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(Color.black)
    }

    private func formatBearing(_ bearing: Double?) -> String {
        guard let b = bearing else { return "---" }
        return String(format: "%03.0f", b)
    }

    private func formatDistance(_ distance: Double?) -> String {
        guard let d = distance else { return "--.-" }
        if d < 10 {
            return String(format: "%.1f", d)
        } else {
            return String(format: "%.0f", d)
        }
    }
}

// MARK: - Supporting Views

struct NavigationDataCell: View {
    let label: String
    let value: String
    let unit: String?

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)

            HStack(spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)

                if let unit = unit {
                    Text(unit)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct FrequencyRow: View {
    let name: String
    let frequency: String
    let isActive: Bool

    var body: some View {
        HStack {
            Text(name)
                .font(.system(size: 10))
                .foregroundColor(isActive ? .aviationGold : .secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(frequency)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(isActive ? .aviationGold : .white)
        }
    }
}

// MARK: - Time Display View

struct TimeDisplayView: View {
    let time: Date
    let useUTC: Bool
    let style: TimeDisplayStyle

    enum TimeDisplayStyle {
        case large   // For main display
        case medium  // For standby screen
    }

    private var timeComponents: (hours: String, minutes: String, seconds: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        if useUTC {
            formatter.timeZone = TimeZone(identifier: "UTC")
        }
        let timeString = formatter.string(from: time)
        let parts = timeString.split(separator: ":")
        return (
            hours: String(parts[0]),
            minutes: String(parts[1]),
            seconds: String(parts[2])
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                // Hours
                Text(timeComponents.hours)
                    .font(.system(size: style == .large ? 32 : 28, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)

                Text(":")
                    .font(.system(size: style == .large ? 28 : 24, weight: .bold, design: .monospaced))
                    .foregroundColor(.aviationGold)

                // Minutes
                Text(timeComponents.minutes)
                    .font(.system(size: style == .large ? 32 : 28, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)

                Text(":")
                    .font(.system(size: style == .large ? 20 : 18, weight: .medium, design: .monospaced))
                    .foregroundColor(.aviationGold.opacity(0.7))

                // Seconds - slightly smaller and dimmer
                Text(timeComponents.seconds)
                    .font(.system(size: style == .large ? 20 : 18, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }

            // UTC indicator
            Text(useUTC ? "UTC" : "LOCAL")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(useUTC ? .aviationAmber : .secondary)
        }
    }
}

// MARK: - Watch Colors — now from Shared/DesignTokens.swift.

#Preview {
    ContentView()
        .environmentObject(WatchConnectivityManager())
}
