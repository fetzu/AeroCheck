import SwiftUI

/// Full-screen iPhone companion view — digital navigation log
/// Shows route table with live ETOs, ATO recording, instrument data from the master iPad
struct CompanionFlightView: View {
    @EnvironmentObject var companionConnectivityManager: CompanionConnectivityManager

    @State private var editingGSWaypointIndex: Int? = nil
    @State private var gsEditText: String = ""
    @State private var now = Date()
    private let staleTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var flightData: CompanionFlightData? {
        companionConnectivityManager.lastReceivedData
    }

    /// True when an active flight's live data hasn't refreshed within the stale window — i.e. the
    /// link is nominally connected but the values are frozen. Re-evaluated each second. (UX-05)
    private var isDataStale: Bool {
        guard let data = flightData, data.isFlightActive else { return false }
        return now.timeIntervalSince(data.timestamp) > 5
    }

    private var flightPlan: CompanionFlightPlanSnapshot? {
        companionConnectivityManager.lastFlightPlanSnapshot
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            statusStrip

            if companionConnectivityManager.connectionState == .reconnecting ||
               companionConnectivityManager.connectionState == .disconnected {
                disconnectedBanner
            } else if isDataStale {
                staleBanner
            }

            if let plan = flightPlan {
                routeTable(plan)
            } else {
                noFlightPlanContent
            }

            nextWaypointSummary
            actionBar
            instrumentsStrip
                .opacity(isDataStale ? 0.4 : 1)
        }
        .background(Color.cockpitBackground)
        .preferredColorScheme(.dark)
        .onReceive(staleTimer) { now = $0 }
    }

    /// Shown when the link is connected but live data has gone stale (frozen). (UX-05)
    private var staleBanner: some View {
        HStack {
            Image(systemName: "wifi.exclamationmark")
            Text(L10n.Companion.dataStale)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .foregroundColor(.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.aviationAmber)
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        VStack(spacing: 2) {
            HStack {
                Text("COMPANION")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.cockpitBackground)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.aviationGold)
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Text(flightData?.aircraftRegistration ?? "---")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.primaryText)

                Spacer()

                gpsIndicator
            }

            if let deviceName = companionConnectivityManager.connectedDeviceName {
                HStack {
                    Image(systemName: "link")
                        .font(.system(size: 9))
                    Text(deviceName)
                        .font(.system(size: 11))
                    Spacer()
                }
                .foregroundColor(.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.cockpitBackground.opacity(0.95))
    }

    private var gpsIndicator: some View {
        HStack(spacing: 4) {
            Text("GPS")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondaryText)
            Circle()
                .fill(gpsColor)
                .frame(width: 8, height: 8)
        }
    }

    private var gpsColor: Color {
        guard let status = flightData?.gpsSignalStatus else { return .gray }
        switch status {
        case "good": return .aviationGreen
        case "degraded": return .orange
        case "lost": return .aviationRed
        default: return .gray
        }
    }

    // MARK: - Status Strip

    private var statusStrip: some View {
        HStack {
            Text(flightData?.currentPhase ?? "---")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.aviationGold)

            Spacer()

            HStack(spacing: 4) {
                Text("FLT")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondaryText)
                Text(formattedFlightTime)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.primaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.3))
    }

    private var formattedFlightTime: String {
        guard let lineUp = flightData?.lineUpTime else { return "--:--:--" }
        let elapsed = Date().timeIntervalSince(lineUp)
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        let seconds = Int(elapsed) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    // MARK: - Disconnected Banner

    private var disconnectedBanner: some View {
        HStack {
            Image(systemName: "wifi.slash")
            Text(L10n.Companion.connectionLost)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(L10n.Companion.switchToStandalone) {
                companionConnectivityManager.switchToStandalone()
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange)
    }

    // MARK: - Route Table

    private func routeTable(_ plan: CompanionFlightPlanSnapshot) -> some View {
        VStack(spacing: 0) {
            routeTableHeader

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(plan.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                            routeTableRow(index: index, waypoint: waypoint, plan: plan)
                                .id(index)
                        }
                    }
                }
                .onAppear {
                    proxy.scrollTo(plan.currentWaypointIndex, anchor: .center)
                }
                .onChange(of: flightData?.currentWaypointIndex) {
                    if let idx = flightData?.currentWaypointIndex {
                        withAnimation {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var routeTableHeader: some View {
        HStack(spacing: 0) {
            tableHeaderCell("#", width: 28)
            tableHeaderCell("WPT", width: 70, alignment: .leading)
            tableHeaderCell("MC", width: 40)
            tableHeaderCell("DIST", width: 45)
            tableHeaderCell("EET", width: 42)
            tableHeaderCell("ETO", width: 48)
            tableHeaderCell("ATO", width: 48)
        }
        .background(Color.aviationGold.opacity(0.15))
    }

    private func tableHeaderCell(_ text: String, width: CGFloat, alignment: Alignment = .center) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(.aviationGold)
            .frame(width: width, alignment: alignment)
            .padding(.vertical, 4)
    }

    private func routeTableRow(index: Int, waypoint: CompanionWaypoint, plan: CompanionFlightPlanSnapshot) -> some View {
        let currentIdx = flightData?.currentWaypointIndex ?? plan.currentWaypointIndex
        let isCurrent = index == currentIdx
        let isPast = index < currentIdx
        let textColor: Color = isPast ? .secondaryText : (isCurrent ? .primaryText : .primaryText.opacity(0.8))

        return HStack(spacing: 0) {
            // Status indicator
            Group {
                if isPast {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9))
                        .foregroundColor(.aviationGreen)
                } else if isCurrent {
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.aviationGold)
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondaryText)
                }
            }
            .frame(width: 28)

            // Waypoint name
            Text(waypoint.name.isEmpty ? "WP\(index)" : waypoint.name)
                .font(.system(size: 12, weight: isCurrent ? .bold : .regular, design: .monospaced))
                .foregroundColor(textColor)
                .lineLimit(1)
                .frame(width: 70, alignment: .leading)

            // MC
            Text(waypoint.magneticCourse.map { String(format: "%03.0f", $0) } ?? "---")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(textColor)
                .frame(width: 40)

            // Distance
            Text(waypoint.distance.map { String(format: "%.1f", $0) } ?? "---")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(textColor)
                .frame(width: 45)

            // EET
            Text(formattedEET(waypoint))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(textColor)
                .frame(width: 42)

            // ETO
            Text(formattedTime(waypoint.estimatedTimeOver))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(textColor)
                .frame(width: 48)

            // ATO — tappable to record
            Button(action: {
                if waypoint.actualTimeOver == nil {
                    companionConnectivityManager.sendCommand(.recordATO(waypointIndex: index))
                }
            }) {
                Text(formattedTime(waypoint.actualTimeOver))
                    .font(.system(size: 11, weight: waypoint.actualTimeOver != nil ? .bold : .regular, design: .monospaced))
                    .foregroundColor(waypoint.actualTimeOver != nil ? .aviationGreen : .secondary)
                    .frame(width: 48)
            }
            .disabled(waypoint.actualTimeOver != nil)
        }
        .padding(.vertical, 6)
        .background(
            isCurrent
                ? Color.aviationGold.opacity(0.1)
                : (isPast ? Color.black.opacity(0.1) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isCurrent {
                Rectangle()
                    .fill(Color.aviationGold)
                    .frame(width: 3)
            }
        }
    }

    // MARK: - No Flight Plan Content

    private var noFlightPlanContent: some View {
        VStack {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondaryText)
            Text(L10n.Companion.noFlightPlan)
                .font(.subheadline)
                .foregroundColor(.secondaryText)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Next Waypoint Summary

    private var nextWaypointSummary: some View {
        Group {
            if let plan = flightPlan {
                let currentIdx = flightData?.currentWaypointIndex ?? plan.currentWaypointIndex
                if currentIdx < plan.waypoints.count {
                    let wp = plan.waypoints[currentIdx]
                    HStack {
                        Text("NEXT")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.aviationGold)
                        Text(wp.name.isEmpty ? "WP\(currentIdx)" : wp.name)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.primaryText)
                        Spacer()
                        if let mc = wp.magneticCourse {
                            Text(String(format: "%03.0f°", mc))
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.primaryText)
                        }
                        if let dist = wp.distance {
                            Text(String(format: "%.1f NM", dist))
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.primaryText)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.aviationGold.opacity(0.08))
                }
            }
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            // Chronometer
            HStack(spacing: 6) {
                Image(systemName: "stopwatch")
                    .font(.system(size: 14))
                    .foregroundColor(.aviationGold)
                Text(formattedChronometer)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.primaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture {
                if flightData?.chronometerStartTime != nil || (flightData?.chronometerElapsed ?? 0) > 0 {
                    companionConnectivityManager.sendCommand(.resetChronometer)
                } else {
                    companionConnectivityManager.sendCommand(.startChronometer)
                }
            }

            // Record ATO button
            Button(action: {
                if let plan = flightPlan, let currentIdx = flightData?.currentWaypointIndex,
                   currentIdx < plan.waypoints.count,
                   plan.waypoints[currentIdx].actualTimeOver == nil {
                    companionConnectivityManager.sendCommand(.recordATO(waypointIndex: currentIdx))
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.badge.checkmark")
                        .font(.system(size: 14))
                    Text(L10n.Companion.recordATO)
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundColor(.cockpitBackground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.aviationGold)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var formattedChronometer: String {
        let elapsed = flightData?.chronometerElapsed ?? 0
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        let seconds = Int(elapsed) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    // MARK: - Instruments Strip

    private var instrumentsStrip: some View {
        HStack {
            instrumentItem(label: "GS", value: formattedSpeed, unit: "kt")
            Divider().frame(height: 20)
            instrumentItem(label: "ALT", value: formattedAltitude, unit: "ft")
            Divider().frame(height: 20)
            instrumentItem(label: "TRK", value: formattedTrack, unit: "°")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.4))
    }

    private func instrumentItem(label: String, value: String, unit: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondaryText)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(.primaryText)
            Text(unit)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    private var formattedSpeed: String {
        guard let speedMPS = flightData?.speedMPS else { return "---" }
        let knots = speedMPS * 1.94384
        return String(format: "%.0f", knots)
    }

    private var formattedAltitude: String {
        guard let alt = flightData?.altitudeFeet else { return "---" }
        return String(format: "%.0f", alt)
    }

    private var formattedTrack: String {
        guard let course = flightData?.courseDegrees else { return "---" }
        return String(format: "%03.0f", course)
    }

    // MARK: - Formatting Helpers

    private func formattedEET(_ waypoint: CompanionWaypoint) -> String {
        let hasLegEET = waypoint.estimatedElapsedTime != nil && waypoint.estimatedElapsedTime! > 0
        let hasExtra = waypoint.legEETExtra != nil && waypoint.legEETExtra! > 0

        if !hasLegEET && !hasExtra { return "---" }

        let minutes = hasLegEET ? Int(waypoint.estimatedElapsedTime! / 60) : 0
        if hasExtra {
            let extra = Int(waypoint.legEETExtra! / 60)
            if hasLegEET {
                return "\(minutes)+\(extra)"
            } else {
                return "+\(extra)"
            }
        }
        return "\(minutes)"
    }

    private func formattedTime(_ date: Date?) -> String {
        guard let date else { return "--:--" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        if flightData?.alwaysUseUTC == true {
            formatter.timeZone = TimeZone(identifier: "UTC")
        }
        return formatter.string(from: date)
    }
}
