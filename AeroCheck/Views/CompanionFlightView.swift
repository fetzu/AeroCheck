import SwiftUI

/// Full-screen iPhone companion — the "wingman" second screen. Two glanceable modes the pilot swipes
/// between (NAV | CHECKLIST), defaulting by flight phase: CHECKLIST on the ground, NAV in the air.
/// Only shown once a flight is active on the iPad; otherwise a "start a flight" prompt.
/// - NAV: next checkpoint as a track-up turn arrow + bearing/distance/ETE, plan/freqs/chrono below.
/// - CHECKLIST: the SAME hero + rows as the iPad checklist; tap to advance + NEXT, driving the iPad.
struct CompanionFlightView: View {
    @EnvironmentObject var companionConnectivityManager: CompanionConnectivityManager

    enum Mode: Hashable { case nav, checklist }
    @State private var mode: Mode = .checklist
    @State private var userPickedMode = false
    @State private var autoSetting = false
    @State private var showFullPlan = false
    @State private var isHoldingExit = false
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var flightData: CompanionFlightData? { companionConnectivityManager.lastReceivedData }
    private var flightPlan: CompanionFlightPlanSnapshot? { companionConnectivityManager.lastFlightPlanSnapshot }
    private var checklist: CompanionChecklistSnapshot? { companionConnectivityManager.lastReceivedChecklist }

    private var isFlightActive: Bool { flightData?.isFlightActive == true }
    private var isAirborne: Bool {
        guard let d = flightData else { return false }
        return d.lineUpTime != nil && d.landingTime == nil
    }
    private var isConnected: Bool { companionConnectivityManager.connectionState == .connected }
    private var isDataStale: Bool {
        guard let d = flightData, d.isFlightActive else { return false }
        return now.timeIntervalSince(d.timestamp) > 5
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            if isFlightActive {
                modeSwitcher
                if isDataStale { staleBanner }
                TabView(selection: $mode) {
                    navMode.tag(Mode.nav)
                    checklistMode.tag(Mode.checklist)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                instrumentsStrip.opacity(isDataStale ? 0.4 : 1)
            } else {
                if companionConnectivityManager.connectionState == .reconnecting ||
                   companionConnectivityManager.connectionState == .disconnected {
                    disconnectedBanner
                }
                waitingScreen
            }
        }
        .background(Color.cockpitBackground)
        .preferredColorScheme(.dark)
        .onReceive(tick) { now = $0 }
        .onAppear { applyAutoMode() }
        .onChange(of: isAirborne) { applyAutoMode() }
        .onChange(of: mode) { if autoSetting { autoSetting = false } else { userPickedMode = true } }
    }

    private func applyAutoMode() {
        guard !userPickedMode else { return }
        let target: Mode = isAirborne ? .nav : .checklist
        if mode != target { autoSetting = true; mode = target }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(alignment: .top) {
            HStack(spacing: 7) {
                Text("COMPANION")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.cockpitBackground)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.aviationGold)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .scaleEffect(isHoldingExit ? 0.9 : 1.0)
                    .opacity(isHoldingExit ? 0.6 : 1.0)
                    .onLongPressGesture(minimumDuration: 1.0, pressing: { p in
                        withAnimation(.easeInOut(duration: 0.15)) { isHoldingExit = p }
                    }, perform: {
                        isHoldingExit = false
                        companionConnectivityManager.switchToStandalone()
                    })
                    .accessibilityLabel(L10n.Companion.companionMode)
                    .accessibilityHint(L10n.Companion.holdToExit)

                Text(flightData?.aircraftRegistration ?? "---")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.primaryText)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                gpsChip
                connectionStatusRow
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.cockpitBackground.opacity(0.95))
    }

    /// Connection status using the app's StatusIndicator design language + the connected device name.
    private var connectionStatusRow: some View {
        HStack(spacing: 5) {
            if let name = companionConnectivityManager.connectedDeviceName {
                Text(name).font(.system(size: 11)).foregroundColor(.secondaryText)
            }
            StatusIndicator(connectionStatus, size: 8)
        }
    }

    private var connectionStatus: StatusIndicator.Status {
        switch companionConnectivityManager.connectionState {
        case .connected: return .active
        case .connecting, .reconnecting, .pairing: return .warning
        case .disconnected: return .error
        }
    }

    /// GPS chip — shows WHICH device's GPS the flight is on (iPad's own, or this iPhone's borrowed) and
    /// the signal status, in the app's design language. (companion v2 — GPS clarity)
    private var gpsChip: some View {
        HStack(spacing: 5) {
            Text("GPS").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(.secondaryText)
            Text(gpsSourceLabel).font(.system(size: 11, design: .monospaced)).foregroundColor(.primaryText)
            Circle().fill(gpsColor).frame(width: 8, height: 8)
        }
    }

    /// On the viewer: "own" = the iPad's GPS, "peer" = THIS iPhone's GPS borrowed by the iPad.
    private var gpsSourceLabel: String {
        switch flightData?.gpsSource {
        case "peer": return "iPhone"
        case "own": return "iPad"
        default: return "—"
        }
    }

    private var gpsColor: Color {
        switch flightData?.gpsSignalStatus {
        case "good": return .aviationGreen
        case "degraded": return .orange
        case "lost": return .aviationRed
        default: return .gray
        }
    }

    // MARK: - Waiting (connected, no flight yet)

    private var waitingScreen: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: isConnected ? "airplane.circle" : "antenna.radiowaves.left.and.right")
                .font(.system(size: 52)).foregroundColor(.aviationGold.opacity(0.85))
            let name = companionConnectivityManager.connectedDeviceName ?? L10n.Companion.masterDevice
            if isConnected {
                Text(String(format: L10n.Companion.connectedWith, name))
                    .font(.system(size: 17, weight: .semibold)).foregroundColor(.primaryText)
                Text(String(format: L10n.Companion.startFlightOnMaster, name))
                    .font(.subheadline).foregroundColor(.secondaryText)
                    .multilineTextAlignment(.center).padding(.horizontal, 36)
            } else {
                Text(String(format: L10n.Companion.connectingTo, name))
                    .font(.system(size: 16)).foregroundColor(.secondaryText)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Mode switcher

    private var modeSwitcher: some View {
        HStack(spacing: 4) {
            modeButton(.nav, "NAV", "location.north.line")
            modeButton(.checklist, "CHECKLIST", "checklist")
        }
        .padding(3).background(Color.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func modeButton(_ m: Mode, _ title: String, _ icon: String) -> some View {
        Button { withAnimation { mode = m } } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            .foregroundColor(mode == m ? .cockpitBackground : .secondaryText)
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .background(mode == m ? Color.aviationGold : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - NAV mode

    private var navMode: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let (idx, wp) = nextWaypoint {
                    nextWaypointHero(index: idx, waypoint: wp)
                    metricsRow(waypoint: wp)
                } else {
                    noFlightPlanContent.frame(height: 160)
                }
                planSection
                freqChronoRow
                recordATOButton
            }
            .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 12)
        }
    }

    private var nextWaypoint: (index: Int, wp: CompanionWaypoint)? {
        guard let plan = flightPlan else { return nil }
        let idx = flightData?.currentWaypointIndex ?? plan.currentWaypointIndex
        guard plan.waypoints.indices.contains(idx) else { return nil }
        return (idx, plan.waypoints[idx])
    }

    private func relativeBearing(_ wp: CompanionWaypoint) -> Double {
        guard let mc = wp.magneticCourse, let track = flightData?.courseDegrees else { return 0 }
        var rel = mc - track
        while rel > 180 { rel -= 360 }
        while rel < -180 { rel += 360 }
        return rel
    }

    private func nextWaypointHero(index: Int, waypoint wp: CompanionWaypoint) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.aviationGold, lineWidth: 2).frame(width: 72, height: 72)
                Image(systemName: "arrow.up").font(.system(size: 34, weight: .semibold)).foregroundColor(.aviationGold)
                    .rotationEffect(.degrees(relativeBearing(wp)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("NEXT").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.secondaryText)
                Text(wp.name.isEmpty ? "WP\(index + 1)" : wp.name)
                    .font(.system(size: 28, weight: .bold, design: .monospaced)).foregroundColor(.primaryText)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let mc = wp.magneticCourse {
                    Text(String(format: "%03.0f° mag", mc)).font(.system(size: 13, design: .monospaced)).foregroundColor(.aviationGold)
                }
            }
            Spacer()
        }
        .padding(14).background(Color.aviationGold.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func metricsRow(waypoint wp: CompanionWaypoint) -> some View {
        HStack(spacing: 8) {
            metricCell("DIST", wp.distance.map { String(format: "%.1f", $0) } ?? "---", "NM")
            metricCell("ETE", formattedEET(wp), "")
            metricCell("ETO", formattedTime(wp.estimatedTimeOver), "")
        }
    }

    private func metricCell(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundColor(.primaryText)
                if !unit.isEmpty { Text(unit).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondaryText) }
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(Color.black.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var planSection: some View {
        Group {
            if let plan = flightPlan {
                VStack(spacing: 0) {
                    Button { withAnimation { showFullPlan.toggle() } } label: {
                        HStack {
                            Text("PLAN").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(.aviationGold)
                            Spacer()
                            Image(systemName: showFullPlan ? "chevron.up" : "chevron.down").font(.system(size: 11)).foregroundColor(.secondaryText)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                    }
                    if showFullPlan { routeTable(plan).frame(maxHeight: 260) } else { upcomingStrip(plan) }
                }
                .background(Color.black.opacity(0.2)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func upcomingStrip(_ plan: CompanionFlightPlanSnapshot) -> some View {
        let start = (flightData?.currentWaypointIndex ?? plan.currentWaypointIndex) + 1
        let upcoming = Array(plan.waypoints.enumerated()).filter { $0.offset >= start }.prefix(2)
        return VStack(spacing: 0) {
            if upcoming.isEmpty {
                Text("—").font(.system(size: 12, design: .monospaced)).foregroundColor(.secondaryText)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            } else {
                ForEach(Array(upcoming), id: \.element.id) { i, wp in
                    HStack {
                        Text("\(i + 1) · \(wp.name.isEmpty ? "WP" : wp.name)").lineLimit(1)
                        Spacer()
                        Text(wp.magneticCourse.map { String(format: "%03.0f°", $0) } ?? "---")
                        Text(wp.distance.map { String(format: "%.1f NM", $0) } ?? "---").frame(width: 70, alignment: .trailing)
                    }
                    .font(.system(size: 12, design: .monospaced)).foregroundColor(.primaryText.opacity(0.85))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                }
            }
        }
    }

    private var freqChronoRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("FREQ").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondaryText)
                Text(nextWaypoint?.wp.frequency?.isEmpty == false ? nextWaypoint!.wp.frequency! : "121.50")
                    .font(.system(size: 14, design: .monospaced)).foregroundColor(.primaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(Color.black.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius: 8))

            Button {
                if flightData?.chronometerStartTime != nil || (flightData?.chronometerElapsed ?? 0) > 0 {
                    companionConnectivityManager.sendCommand(.resetChronometer)
                } else {
                    companionConnectivityManager.sendCommand(.startChronometer)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "stopwatch").font(.system(size: 10)).foregroundColor(.aviationGold)
                        Text("CHRONO").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondaryText)
                    }
                    Text(formattedChronometer).font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundColor(.primaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(Color.black.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var recordATOButton: some View {
        Button {
            if let plan = flightPlan, let idx = flightData?.currentWaypointIndex,
               plan.waypoints.indices.contains(idx), plan.waypoints[idx].actualTimeOver == nil {
                companionConnectivityManager.sendCommand(.recordATO(waypointIndex: idx))
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.checkmark").font(.system(size: 14))
                Text(L10n.Companion.recordATO).font(.system(size: 14, weight: .bold))
            }
            .foregroundColor(.cockpitBackground).frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(Color.aviationGold).clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - CHECKLIST mode (mirrors the iPad checklist: hero + rows + tap-to-advance + NEXT)

    private var checklistMode: some View {
        Group {
            if let cl = checklist {
                VStack(spacing: 0) {
                    checklistPhaseHeader(cl)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(cl.items.enumerated()), id: \.element.id) { index, item in
                                    checklistRow(cl, index: index, item: item).id(index)
                                }
                                if let completion = phaseCompletionText(cl), !completion.isEmpty {
                                    Rectangle().fill(Color.subtleOverlay(0.12)).frame(height: 1).padding(.vertical, 12)
                                    HStack { Spacer()
                                        Text(completion).font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundColor(.aviationGreen)
                                        Spacer() }
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                        }
                        .onChange(of: cl.highlightedIndex) { _, idx in
                            withAnimation { proxy.scrollTo(idx, anchor: UnitPoint(x: 0.5, y: 0.12)) }
                        }
                    }
                    // Tap anywhere on the list to advance the highlighted item (mirrors the iPad).
                    .contentShape(Rectangle())
                    .onTapGesture { companionConnectivityManager.sendCommand(.advanceChecklistItem) }

                    nextButton
                }
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "checklist").font(.system(size: 40)).foregroundColor(.secondaryText)
                    Text(L10n.Companion.checklistUnavailable).font(.subheadline).foregroundColor(.secondaryText)
                        .multilineTextAlignment(.center).padding(.horizontal, 30)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func checklistPhaseHeader(_ cl: CompanionChecklistSnapshot) -> some View {
        VStack(spacing: 2) {
            HStack {
                Button { companionConnectivityManager.sendCommand(.previousChecklistPhase) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 15)).foregroundColor(.aviationGold).frame(width: 34, height: 30)
                }
                Spacer()
                Text(cl.phaseTitle).font(.system(size: 16, weight: .bold)).foregroundColor(.aviationGold)
                    .textCase(.uppercase).tracking(1).lineLimit(1)
                Spacer()
                Button { companionConnectivityManager.sendCommand(.nextChecklistPhase) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 15)).foregroundColor(.aviationGold).frame(width: 34, height: 30)
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "hand.tap.fill").font(.system(size: 9))
                Text(L10n.ChecklistAction.tapToAdvance).font(.system(size: 10))
            }
            .foregroundColor(.dimText)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    @ViewBuilder
    private func checklistRow(_ cl: CompanionChecklistSnapshot, index: Int, item: CompanionChecklistItem) -> some View {
        if index == cl.highlightedIndex {
            CockpitHeroChecklistItem(
                challenge: item.challenge,
                response: item.response,
                progressText: "\(index + 1) / \(cl.items.count)",
                showAdvanceHint: false,
                isCompact: true
            ).padding(.vertical, 4)
        } else {
            ChecklistItemRow(
                item: ChecklistItem(challenge: item.challenge, response: item.response, isHeader: item.isHeader),
                showSeparator: index < cl.items.count - 1,
                isHighlighted: false,
                isCompleted: index < cl.highlightedIndex,
                isCompact: true
            )
        }
    }

    private func phaseCompletionText(_ cl: CompanionChecklistSnapshot) -> String? {
        guard cl.completedCount >= cl.visibleCount, cl.visibleCount > 0,
              let phase = ChecklistPhase(rawValue: cl.phaseRawValue) else { return nil }
        return phase.completionText
    }

    private var nextButton: some View {
        Button { companionConnectivityManager.sendCommand(.nextChecklistPhase) } label: {
            HStack(spacing: 8) {
                Text("NEXT").font(.system(size: 16, weight: .bold))
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold))
            }
            .foregroundColor(.cockpitBackground).frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Color.aviationGold).clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    // MARK: - Route table (full plan, inside the PLAN disclosure)

    private func routeTable(_ plan: CompanionFlightPlanSnapshot) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(plan.waypoints.enumerated()), id: \.element.id) { index, wp in
                        routeTableRow(index: index, waypoint: wp, plan: plan).id(index)
                    }
                }
            }
            .onChange(of: flightData?.currentWaypointIndex) {
                if let idx = flightData?.currentWaypointIndex { withAnimation { proxy.scrollTo(idx, anchor: .center) } }
            }
        }
    }

    private func routeTableRow(index: Int, waypoint wp: CompanionWaypoint, plan: CompanionFlightPlanSnapshot) -> some View {
        let currentIdx = flightData?.currentWaypointIndex ?? plan.currentWaypointIndex
        let isCurrent = index == currentIdx
        let isPast = index < currentIdx
        let textColor: Color = isPast ? .secondaryText : .primaryText.opacity(isCurrent ? 1 : 0.8)
        return HStack(spacing: 0) {
            Group {
                if isPast { Image(systemName: "checkmark").font(.system(size: 9)).foregroundColor(.aviationGreen) }
                else if isCurrent { Image(systemName: "arrowtriangle.right.fill").font(.system(size: 9)).foregroundColor(.aviationGold) }
                else { Text("\(index + 1)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondaryText) }
            }.frame(width: 24)
            Text(wp.name.isEmpty ? "WP\(index)" : wp.name).font(.system(size: 12, weight: isCurrent ? .bold : .regular, design: .monospaced)).foregroundColor(textColor).lineLimit(1).frame(width: 64, alignment: .leading)
            Text(wp.magneticCourse.map { String(format: "%03.0f", $0) } ?? "---").font(.system(size: 11, design: .monospaced)).foregroundColor(textColor).frame(width: 40)
            Text(wp.distance.map { String(format: "%.1f", $0) } ?? "---").font(.system(size: 11, design: .monospaced)).foregroundColor(textColor).frame(width: 46)
            Text(formattedTime(wp.estimatedTimeOver)).font(.system(size: 11, design: .monospaced)).foregroundColor(textColor).frame(width: 48)
            Button {
                if wp.actualTimeOver == nil { companionConnectivityManager.sendCommand(.recordATO(waypointIndex: index)) }
            } label: {
                Text(formattedTime(wp.actualTimeOver)).font(.system(size: 11, weight: wp.actualTimeOver != nil ? .bold : .regular, design: .monospaced)).foregroundColor(wp.actualTimeOver != nil ? .aviationGreen : .secondary).frame(width: 48)
            }.disabled(wp.actualTimeOver != nil)
        }
        .padding(.vertical, 6)
        .background(isCurrent ? Color.aviationGold.opacity(0.1) : Color.clear)
    }

    // MARK: - Shared chrome

    private var noFlightPlanContent: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 36)).foregroundColor(.secondaryText)
            Text(L10n.Companion.noFlightPlan).font(.subheadline).foregroundColor(.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var disconnectedBanner: some View {
        HStack {
            Image(systemName: "wifi.slash")
            Text(L10n.Companion.connectionLost).font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(L10n.Companion.switchToStandalone) { companionConnectivityManager.switchToStandalone() }
                .font(.system(size: 12, weight: .medium)).foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.white.opacity(0.2)).clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .foregroundColor(.white).padding(.horizontal, 12).padding(.vertical, 8).background(Color.orange)
    }

    private var staleBanner: some View {
        HStack {
            Image(systemName: "wifi.exclamationmark")
            Text(L10n.Companion.dataStale).font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .foregroundColor(.black).padding(.horizontal, 12).padding(.vertical, 8).background(Color.aviationAmber)
    }

    private var instrumentsStrip: some View {
        HStack {
            instrumentItem("GS", formattedSpeed, "kt")
            Divider().frame(height: 20)
            instrumentItem("ALT", formattedAltitude, "ft")
            Divider().frame(height: 20)
            instrumentItem("TRK", formattedTrack, "°")
        }
        .padding(.horizontal, 12).padding(.vertical, 8).background(Color.black.opacity(0.4))
    }

    private func instrumentItem(_ label: String, _ value: String, _ unit: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(.secondaryText)
            Text(value).font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundColor(.primaryText)
            Text(unit).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Formatting

    private var formattedSpeed: String {
        guard let s = flightData?.speedMPS else { return "---" }
        return String(format: "%.0f", s * 1.94384)
    }
    private var formattedAltitude: String {
        guard let a = flightData?.altitudeFeet else { return "---" }
        return String(format: "%.0f", a)
    }
    private var formattedTrack: String {
        guard let c = flightData?.courseDegrees else { return "---" }
        return String(format: "%03.0f", c)
    }
    private var formattedChronometer: String {
        let e = flightData?.chronometerElapsed ?? 0
        return String(format: "%02d:%02d:%02d", Int(e) / 3600, (Int(e) % 3600) / 60, Int(e) % 60)
    }

    private func formattedEET(_ wp: CompanionWaypoint) -> String {
        let hasLeg = (wp.estimatedElapsedTime ?? 0) > 0
        let hasExtra = (wp.legEETExtra ?? 0) > 0
        if !hasLeg && !hasExtra { return "---" }
        let minutes = hasLeg ? Int(wp.estimatedElapsedTime! / 60) : 0
        if hasExtra {
            let extra = Int(wp.legEETExtra! / 60)
            return hasLeg ? "\(minutes)+\(extra)" : "+\(extra)"
        }
        return "\(minutes)"
    }

    private func formattedTime(_ date: Date?) -> String {
        guard let date else { return "--:--" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        if flightData?.alwaysUseUTC == true { f.timeZone = TimeZone(identifier: "UTC") }
        return f.string(from: date)
    }
}
