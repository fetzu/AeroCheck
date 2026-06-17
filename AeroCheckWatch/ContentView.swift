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
            if connectivityManager.flightData.hasActiveNavPlan {
                // With navigation plan: Navigation (chrono + nav data) · Flight (clock + phase) · Frequencies.
                TabView {
                    NavigationScreen()
                        .environmentObject(connectivityManager)

                    FlightScreen()
                        .environmentObject(connectivityManager)

                    FrequenciesScreen()
                        .environmentObject(connectivityManager)
                }
                .tabViewStyle(.verticalPage)
            } else {
                // No navigation plan: just the Flight screen.
                FlightScreen()
                    .environmentObject(connectivityManager)
            }
        } else {
            StandbyScreen()
                .environmentObject(connectivityManager)
        }
    }
}

/// Stage tint for a checklist phase, matching the iOS HUD's phase badge (FlightView.phaseBadgeColor):
/// ground prep = blue, departure = gold, airborne = green, arrival = orange, wrap-up = grey. Uses the
/// phase raw value the phone already sends, so no payload change is needed.
func phaseStageColor(_ rawValue: Int) -> Color {
    switch rawValue {
    case 0...5: return .altimeterBlue   // preflight … run-up
    case 6...7: return .aviationGold    // before departure, line up
    case 8...10: return .aviationGreen  // climb, cruise, descent
    case 11...12: return .orange        // approach, landing
    default: return .secondaryText      // after landing, shutdown, hangar
    }
}

/// Stage-tinted current-phase chip used on the Flight + Navigation screens.
struct PhaseBadge: View {
    let name: String
    let rawValue: Int
    var body: some View {
        let tint = phaseStageColor(rawValue)
        Text(name)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.18)))
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
        VStack(spacing: 6) {
            // Compact brand at the very top, leaving the clock the room to be the hero.
            HStack(spacing: 4) {
                Image(systemName: "airplane")
                    .font(.system(size: 14))
                Text("AeroCheck")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundColor(.aviationGold)
            .padding(.top, 2)

            Spacer()

            // Big current-time hero (with seconds).
            TimeDisplayView(
                time: currentTime,
                useUTC: connectivityManager.flightData.alwaysUseUTC,
                style: .hero
            )

            Spacer()

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
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(Color.black)
        .onReceive(timer) { time in
            currentTime = time
        }
    }
}

// MARK: - Flight Screen (Clock + Phase)

struct FlightScreen: View {
    @EnvironmentObject var connectivityManager: WatchConnectivityManager
    @State private var currentTime = Date()

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 4) {
            // Stage-tinted current phase, pinned left (clear of the system clock at top-right).
            HStack {
                PhaseBadge(
                    name: connectivityManager.flightData.currentPhaseName,
                    rawValue: connectivityManager.flightData.currentPhaseRawValue
                )
                Spacer()
            }

            // Wall clock — the Flight screen's hero.
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

            // Next phase — gold-accented card (matches the approved mockup).
            if let nextPhase = connectivityManager.flightData.nextPhaseName {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.right")
                        .foregroundColor(.aviationGold)
                        .font(.system(size: 12, weight: .bold))
                    Text("NEXT")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.5)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 4)
                    Text(nextPhase)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.aviationGold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 10).fill(Color.panelBackground)
                        Rectangle().fill(Color.aviationGold).frame(width: 3)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                )
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .background(Color.black)
        .onReceive(timer) { time in
            currentTime = time
        }
    }
}

// MARK: - Navigation Screen (Chronometer hero + nav data)

struct NavigationScreen: View {
    @EnvironmentObject var connectivityManager: WatchConnectivityManager

    var body: some View {
        VStack(spacing: 6) {
            // Waypoint + progress header.
            HStack {
                Text(connectivityManager.flightData.currentWaypointName ?? "---")
                    .font(.system(size: 15, weight: .bold))
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

            // Chronometer — the centerpiece in navigation mode.
            VStack(spacing: 1) {
                Text("CHRONO")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                Text(connectivityManager.formattedFlightTime)
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .foregroundColor(.aviationGreen)
            }
            .frame(maxWidth: .infinity)

            Divider()
                .background(Color.aviationGold.opacity(0.3))

            // Navigation data grid — existing cell styling.
            HStack(spacing: 12) {
                NavigationDataCell(
                    label: "HDG",
                    value: formatBearing(connectivityManager.flightData.bearingToWaypoint),
                    unit: nil
                )
                NavigationDataCell(
                    label: "DIST",
                    value: formatDistance(connectivityManager.flightData.distanceToWaypointNM),
                    unit: "NM"
                )
                NavigationDataCell(
                    label: "EET",
                    value: connectivityManager.formattedEET ?? "--:--",
                    unit: nil
                )
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

// MARK: - Frequencies Screen (its own page)

struct FrequenciesScreen: View {
    @EnvironmentObject var connectivityManager: WatchConnectivityManager

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11))
                Text("FREQUENCIES")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundColor(.aviationGold)

            Divider()
                .background(Color.aviationGold.opacity(0.3))

            // Current + next waypoint frequencies, then a few common ones.
            if let freq = connectivityManager.flightData.currentWaypointFrequency {
                FrequencyRow(name: "WPT", frequency: freq, isActive: true)
            }
            if let nextFreq = connectivityManager.flightData.nextWaypointFrequency {
                FrequencyRow(name: "NEXT", frequency: nextFreq, isActive: false)
            }
            if let commonFreqs = connectivityManager.flightData.commonFrequencies?.prefix(4) {
                ForEach(Array(commonFreqs)) { freq in
                    FrequencyRow(name: freq.name, frequency: freq.frequency, isActive: false)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Color.black)
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
                .font(.system(size: 11))
                .foregroundColor(isActive ? .aviationGold : .secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(frequency)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
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
        case hero    // Standby hero clock
        case large   // Flight screen clock
        case medium  // Compact
    }

    /// (hours/minutes, main colon, seconds + secondary colon) point sizes.
    private var sizes: (h: CGFloat, c: CGFloat, s: CGFloat) {
        switch style {
        case .hero:   return (40, 34, 24)
        case .large:  return (32, 28, 20)
        case .medium: return (28, 24, 18)
        }
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
                Text(timeComponents.hours)
                    .font(.system(size: sizes.h, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)

                Text(":")
                    .font(.system(size: sizes.c, weight: .bold, design: .monospaced))
                    .foregroundColor(.aviationGold)

                Text(timeComponents.minutes)
                    .font(.system(size: sizes.h, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)

                Text(":")
                    .font(.system(size: sizes.s, weight: .medium, design: .monospaced))
                    .foregroundColor(.aviationGold.opacity(0.7))

                // Seconds — slightly smaller and dimmer.
                Text(timeComponents.seconds)
                    .font(.system(size: sizes.s, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }

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
