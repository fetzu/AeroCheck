import SwiftUI

/// Full-screen iPhone companion — the "wingman" second screen. Two glanceable modes the pilot swipes
/// between (NAV | CHECKLIST), defaulting by flight phase: CHECKLIST on the ground, NAV in the air.
/// Only shown once a flight is active on the iPad; otherwise a "start a flight" prompt.
/// - NAV: next checkpoint as a track-up turn arrow + bearing/distance/ETE, plan/freqs/chrono below.
/// - CHECKLIST: the SAME hero + rows as the iPad checklist; tap to advance + NEXT, driving the iPad.
///
/// Theming: the view renders in the MASTER's resolved day/sunlight/night cockpit theme (streamed in the
/// flight data), overriding this device's own theme so the two screens match. (companion v2)
struct CompanionFlightView: View {
    @EnvironmentObject var companionConnectivityManager: CompanionConnectivityManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Mode: Hashable { case nav, checklist }
    @State private var mode: Mode = .checklist
    @State private var userPickedMode = false
    @State private var showFullPlan = false
    @State private var isHoldingExit = false
    @State private var showExitConfirm = false
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
        return now.timeIntervalSince(d.timestamp) > CompanionTiming.streamStaleAfter
    }

    // MARK: - Theme parity (mirror the iPad's day/sunlight/night cockpit theme)

    private var themeMode: CockpitThemeMode {
        CockpitThemeMode(rawValue: flightData?.cockpitThemeMode ?? "day") ?? .day
    }
    private var theme: CockpitTheme { CockpitTheme.resolve(themeMode) }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            if isFlightActive {
                modeSwitcher
                // A mid-flight link drop keeps the last (frozen) flight data, so isFlightActive stays true.
                // Surface the "connection lost / switch to standalone" escape here too — not only on the
                // not-flying screen — falling back to the amber stale banner when merely connected-but-stale.
                if companionConnectivityManager.connectionState == .reconnecting ||
                   companionConnectivityManager.connectionState == .disconnected {
                    disconnectedBanner
                } else if isDataStale {
                    staleBanner
                }
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
        .background(theme.background)
        .preferredColorScheme(.dark)
        // Render the reused checklist hero/rows in the SAME theme as the iPad, not this device's theme.
        .environment(\.cockpitTheme, theme)
        .environment(\.isNightMode, themeMode == .night)
        .onReceive(tick) { now = $0 }
        .onAppear { applyAutoMode() }
        .onChange(of: isAirborne) { applyAutoMode() }
        .alert(L10n.Companion.exitConfirmTitle, isPresented: $showExitConfirm) {
            Button(L10n.Companion.exitConfirmLeave, role: .destructive) {
                companionConnectivityManager.switchToStandalone()
            }
            Button(L10n.Button.cancel, role: .cancel) { }
        } message: {
            Text(L10n.Companion.exitConfirmMessage)
        }
    }

    private func applyAutoMode() {
        guard !userPickedMode else { return }
        let target: Mode = isAirborne ? .nav : .checklist
        if mode != target { withAnimation(reduceMotion ? nil : .default) { mode = target } } // (UX-18)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(alignment: .top) {
            HStack(spacing: 7) {
                Text("COMPANION")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.actionText)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(theme.action)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .scaleEffect(isHoldingExit ? 0.9 : 1.0)
                    .opacity(isHoldingExit ? 0.6 : 1.0)
                    .onLongPressGesture(minimumDuration: 1.0, pressing: { p in
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { isHoldingExit = p } // (UX-18)
                    }, perform: {
                        isHoldingExit = false
                        showExitConfirm = true
                    })
                    .accessibilityLabel(L10n.Companion.companionMode)
                    .accessibilityHint(L10n.Companion.holdToExit)

                Text(flightData?.aircraftRegistration ?? "---")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.textPrimary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                gpsChip
                connectionStatusRow
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(theme.background.opacity(0.95))
    }

    /// Connection status using the app's StatusIndicator design language + the connected device name.
    private var connectionStatusRow: some View {
        HStack(spacing: 5) {
            if let name = companionConnectivityManager.connectedDeviceName {
                Text(name).font(.system(size: 11)).foregroundColor(theme.textSecondary)
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
            Text("GPS").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(theme.textSecondary)
            Text(gpsSourceLabel).font(.system(size: 11, design: .monospaced)).foregroundColor(theme.textPrimary)
            Circle().fill(gpsColor).frame(width: 8, height: 8)
        }
        // Merge the fragments so VoiceOver reads "GPS <source>" as one element instead of three. (v4.1.0)
        .accessibilityElement(children: .combine)
        // Signal quality was an 8 pt COLOURED DOT and nothing else — invisible to VoiceOver, and
        // green/amber/red is the worst possible palette for a colour vision deficiency. Speak it.
        // (UX-10)
        .accessibilityValue(gpsQualityLabel)
    }

    /// On the viewer: "own" = the iPad's GPS, "peer" = THIS iPhone's GPS borrowed by the iPad.
    private var gpsSourceLabel: String {
        switch flightData?.gpsSource {
        case "peer": return "iPhone"
        case "own": return "iPad"
        default: return "—"
        }
    }

    /// Spoken counterpart to `gpsColor`. Same four states, in words.
    private var gpsQualityLabel: String {
        switch flightData?.gpsSignalStatus {
        case "good":     return L10n.Accessibility.gpsGood
        case "degraded": return L10n.Accessibility.gpsDegraded
        case "lost":     return L10n.Accessibility.gpsLost
        default:         return L10n.Accessibility.gpsUnknown
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
                .font(.system(size: 52)).foregroundColor(theme.action.opacity(0.85))
            let name = companionConnectivityManager.connectedDeviceName ?? L10n.Companion.masterDevice
            if isConnected {
                Text(String(format: L10n.Companion.connectedWith, name))
                    .font(.system(size: 17, weight: .semibold)).foregroundColor(theme.textPrimary)
                Text(String(format: L10n.Companion.startFlightOnMaster, name))
                    .font(.subheadline).foregroundColor(theme.textSecondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 36)
            } else {
                Text(String(format: L10n.Companion.connectingTo, name))
                    .font(.system(size: 16)).foregroundColor(theme.textSecondary)
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
        // Tapping either mode is a deliberate manual choice — latch it directly (even when re-selecting the
        // already-active mode, which wouldn't fire an .onChange) so auto-by-phase stops overriding the pilot.
        Button { userPickedMode = true; withAnimation(reduceMotion ? nil : .default) { mode = m } } label: { // (UX-18)
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            .foregroundColor(mode == m ? theme.actionText : theme.textSecondary)
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .background(mode == m ? theme.action : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        // Invisible hit-area expansion to the HIG 44pt minimum, without growing the visual chip. (UX-16)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityAddTraits(mode == m ? .isSelected : [])
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

    /// True geographic bearing (0–360°) from the current GPS position to the waypoint, or nil with no fix.
    private func bearingToWaypoint(_ wp: CompanionWaypoint) -> Double? {
        guard let lat1 = flightData?.latitude, let lon1 = flightData?.longitude else { return nil }
        let lat1r = lat1 * .pi / 180, lat2r = wp.latitude * .pi / 180
        let dLon = (wp.longitude - lon1) * .pi / 180
        let y = sin(dLon) * cos(lat2r)
        let x = cos(lat1r) * sin(lat2r) - sin(lat1r) * cos(lat2r) * cos(dLon)
        let brng = atan2(y, x) * 180 / .pi
        return (brng + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Arrow rotation for the track-up turn arrow: where the waypoint is relative to the direction of
    /// travel. Computed from the real bearing-to-waypoint (so it actually points at the checkpoint)
    /// minus the current track. Falls back to the planned leg course when there is no position fix.
    /// (item 2 — the arrow was stuck pointing up because it used leg-course − track.)
    private func arrowRotation(_ wp: CompanionWaypoint) -> Double {
        if let brg = bearingToWaypoint(wp) {
            let track = flightData?.courseDegrees ?? 0
            var rel = brg - track
            while rel > 180 { rel -= 360 }
            while rel < -180 { rel += 360 }
            return rel
        }
        // No fix: best-effort using the planned magnetic course vs current track.
        guard let mc = wp.magneticCourse, let track = flightData?.courseDegrees else { return 0 }
        var rel = mc - track
        while rel > 180 { rel -= 360 }
        while rel < -180 { rel += 360 }
        return rel
    }

    private func nextWaypointHero(index: Int, waypoint wp: CompanionWaypoint) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(theme.action, lineWidth: 2).frame(width: 72, height: 72)
                Image(systemName: "arrow.up").font(.system(size: 34, weight: .semibold)).foregroundColor(theme.action)
                    .rotationEffect(.degrees(arrowRotation(wp)))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: arrowRotation(wp)) // (UX-18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("NEXT").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(theme.textSecondary)
                Text(wp.name.isEmpty ? "WP\(index + 1)" : wp.name)
                    .font(.system(size: 28, weight: .bold, design: .monospaced)).foregroundColor(theme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let mc = wp.magneticCourse {
                    Text(String(format: "%03.0f° mag", mc)).font(.system(size: 13, design: .monospaced)).foregroundColor(theme.action)
                }
            }
            Spacer()
        }
        .padding(14).background(theme.action.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
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
            Text(label).font(.system(size: 10, design: .monospaced)).foregroundColor(theme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundColor(theme.textPrimary)
                if !unit.isEmpty { Text(unit).font(.system(size: 10, design: .monospaced)).foregroundColor(theme.textSecondary) }
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(Color.black.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var planSection: some View {
        Group {
            if let plan = flightPlan {
                VStack(spacing: 0) {
                    Button { withAnimation(reduceMotion ? nil : .default) { showFullPlan.toggle() } } label: { // (UX-18)
                        HStack {
                            Text("PLAN").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(theme.action)
                            Spacer()
                            Image(systemName: showFullPlan ? "chevron.up" : "chevron.down").font(.system(size: 11)).foregroundColor(theme.textSecondary)
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
                Text("—").font(.system(size: 12, design: .monospaced)).foregroundColor(theme.textSecondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            } else {
                ForEach(Array(upcoming), id: \.element.id) { i, wp in
                    HStack {
                        Text("\(i + 1) · \(wp.name.isEmpty ? "WP" : wp.name)").lineLimit(1)
                        Spacer()
                        Text(wp.magneticCourse.map { String(format: "%03.0f°", $0) } ?? "---")
                        Text(wp.distance.map { String(format: "%.1f NM", $0) } ?? "---").frame(width: 70, alignment: .trailing)
                    }
                    .font(.system(size: 12, design: .monospaced)).foregroundColor(theme.textPrimary.opacity(0.85))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                }
            }
        }
    }

    private var freqChronoRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                // FREQ + a descriptor of WHAT the frequency is (the waypoint it belongs to, or GUARD for
                // the 121.50 emergency fallback). (item 3)
                HStack(spacing: 4) {
                    Text("FREQ").font(.system(size: 10, design: .monospaced)).foregroundColor(theme.textSecondary)
                    Text(freqDescriptor).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(theme.action).lineLimit(1)
                }
                Text(freqValue).font(.system(size: 14, design: .monospaced)).foregroundColor(theme.textPrimary)
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
                        Image(systemName: "stopwatch").font(.system(size: 10)).foregroundColor(theme.action)
                        Text("CHRONO").font(.system(size: 10, design: .monospaced)).foregroundColor(theme.textSecondary)
                    }
                    Text(formattedChronometer).font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundColor(theme.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(Color.black.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// What the FREQ box's frequency is: the next waypoint's name, or GUARD for the 121.50 fallback.
    private var freqDescriptor: String {
        if let wp = nextWaypoint?.wp, let f = wp.frequency, !f.isEmpty {
            return wp.name.isEmpty ? "WPT" : wp.name
        }
        return "GUARD"
    }

    private var freqValue: String {
        if let f = nextWaypoint?.wp.frequency, !f.isEmpty { return f }
        return "121.50"
    }

    /// Whether the current waypoint can take an ATO: a waypoint exists at the current index and hasn't
    /// been timed yet. Drives both the action guard and the button's enabled/visual state. (v4.1.0)
    private var canRecordATO: Bool {
        guard let plan = flightPlan, let idx = flightData?.currentWaypointIndex,
              plan.waypoints.indices.contains(idx) else { return false }
        return plan.waypoints[idx].actualTimeOver == nil
    }

    private var recordATOButton: some View {
        Button {
            if canRecordATO, let idx = flightData?.currentWaypointIndex {
                companionConnectivityManager.sendCommand(.recordATO(waypointIndex: idx))
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.checkmark").font(.system(size: 14))
                Text(L10n.Companion.recordATO).font(.system(size: 14, weight: .bold))
            }
            .foregroundColor(theme.actionText).frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(theme.action).clipShape(RoundedRectangle(cornerRadius: 10))
        }
        // No ButtonStyle here, so .disabled() alone won't dim the inline background — dim explicitly so a
        // no-op tap (ATO already recorded / no active waypoint) reads as disabled. (v4.1.0)
        .disabled(!canRecordATO)
        .opacity(canRecordATO ? 1.0 : 0.45)
    }

    // MARK: - CHECKLIST mode (mirrors the iPad checklist: hero + rows + tap-to-advance + NEXT)

    /// Whether the current phase is fully worked through (so the NEXT button gets the attention pulse,
    /// like the iPad). Same condition that shows the green completion text.
    private var phaseComplete: Bool {
        guard let cl = checklist else { return false }
        return cl.visibleCount > 0 && cl.completedCount >= cl.visibleCount
    }

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
                                // Hidden (memorizable) content placeholder, mirroring the iPad. Hold to
                                // reveal — reveals on BOTH devices. (item 1c)
                                if cl.hiddenItemCount > 0 {
                                    hiddenContentPlaceholder(count: cl.hiddenItemCount)
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
                            withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(idx, anchor: UnitPoint(x: 0.5, y: 0.12)) } // (UX-18)
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
                    Image(systemName: "checklist").font(.system(size: 40)).foregroundColor(theme.textSecondary)
                    Text(L10n.Companion.checklistUnavailable).font(.subheadline).foregroundColor(theme.textSecondary)
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
                // 34x30 was below Apple's 28x28 floor on one axis and well under the 44x44
                // recommendation on both. Padding grows the target without moving the chevron.
                Button { companionConnectivityManager.sendCommand(.previousChecklistPhase) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 15)).foregroundColor(theme.action)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.Accessibility.previousPhase)
                Spacer()
                Text(cl.phaseTitle).font(.system(size: 16, weight: .bold)).foregroundColor(theme.action)
                    .textCase(.uppercase).tracking(1).lineLimit(1)
                Spacer()
                Button { companionConnectivityManager.sendCommand(.nextChecklistPhase) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 15)).foregroundColor(theme.action).frame(width: 34, height: 30)
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "hand.tap.fill").font(.system(size: 9))
                Text(L10n.ChecklistAction.tapToAdvance).font(.system(size: 10))
            }
            .foregroundColor(theme.textDim)
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

    /// "Hidden Checklist Content" placeholder — matches the iPad's learning-mode indicator. Hold to
    /// reveal; the reveal command flips the master's reveal state, which streams the items to BOTH.
    private func hiddenContentPlaceholder(count: Int) -> some View {
        VStack(spacing: 8) {
            Rectangle().fill(Color.aviationAmber.opacity(0.3)).frame(height: 1).padding(.top, 12)
            HStack(spacing: 10) {
                Image(systemName: "eye.slash.fill").font(.system(size: 18)).foregroundColor(.aviationAmber)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.ChecklistAction.hiddenItemsTitle)
                        .font(.system(size: 13, weight: .bold)).foregroundColor(.aviationAmber)
                    Text(L10n.ChecklistAction.hiddenItemsCount(count, count == 1 ? "" : "s"))
                        .font(.system(size: 11)).foregroundColor(theme.textSecondary)
                }
                Spacer()
                Text(L10n.Companion.holdToReveal).font(.system(size: 10, weight: .medium)).foregroundColor(theme.textDim)
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(Color.aviationAmber.opacity(0.1))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.aviationAmber.opacity(0.3), lineWidth: 1))
            )
            .onLongPressGesture(minimumDuration: 0.4) {
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                companionConnectivityManager.sendCommand(.revealHiddenItems)
            }
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
            .foregroundColor(theme.actionText).frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(theme.action).clipShape(RoundedRectangle(cornerRadius: 12))
        }
        // Pulse the NEXT button once the phase is complete, exactly like the iPad checklist. (item 1b)
        .modifier(PulseModifier(isActive: phaseComplete))
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
                if let idx = flightData?.currentWaypointIndex { withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(idx, anchor: .center) } } // (UX-18)
            }
        }
    }

    private func routeTableRow(index: Int, waypoint wp: CompanionWaypoint, plan: CompanionFlightPlanSnapshot) -> some View {
        let currentIdx = flightData?.currentWaypointIndex ?? plan.currentWaypointIndex
        let isCurrent = index == currentIdx
        let isPast = index < currentIdx
        let textColor: Color = isPast ? theme.textSecondary : theme.textPrimary.opacity(isCurrent ? 1 : 0.8)
        return HStack(spacing: 0) {
            Group {
                if isPast { Image(systemName: "checkmark").font(.system(size: 9)).foregroundColor(.aviationGreen) }
                else if isCurrent { Image(systemName: "arrowtriangle.right.fill").font(.system(size: 9)).foregroundColor(theme.action) }
                else { Text("\(index + 1)").font(.system(size: 10, design: .monospaced)).foregroundColor(theme.textSecondary) }
            }.frame(width: 24)
            Text(wp.name.isEmpty ? "WP\(index)" : wp.name).font(.system(size: 12, weight: isCurrent ? .bold : .regular, design: .monospaced)).foregroundColor(textColor).lineLimit(1).frame(width: 64, alignment: .leading)
            Text(wp.magneticCourse.map { String(format: "%03.0f", $0) } ?? "---").font(.system(size: 11, design: .monospaced)).foregroundColor(textColor).frame(width: 40)
            Text(wp.distance.map { String(format: "%.1f", $0) } ?? "---").font(.system(size: 11, design: .monospaced)).foregroundColor(textColor).frame(width: 46)
            Text(formattedTime(wp.estimatedTimeOver)).font(.system(size: 11, design: .monospaced)).foregroundColor(textColor).frame(width: 48)
            Button {
                if wp.actualTimeOver == nil { companionConnectivityManager.sendCommand(.recordATO(waypointIndex: index)) }
            } label: {
                Text(formattedTime(wp.actualTimeOver)).font(.system(size: 11, weight: wp.actualTimeOver != nil ? .bold : .regular, design: .monospaced)).foregroundColor(wp.actualTimeOver != nil ? .aviationGreen : theme.textSecondary).frame(width: 48)
            }.disabled(wp.actualTimeOver != nil)
        }
        .padding(.vertical, 6)
        .background(isCurrent ? theme.action.opacity(0.1) : Color.clear)
    }

    // MARK: - Shared chrome

    private var noFlightPlanContent: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 36)).foregroundColor(theme.textSecondary)
            Text(L10n.Companion.noFlightPlan).font(.subheadline).foregroundColor(theme.textSecondary)
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
            Text(label).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundColor(theme.textSecondary)
            Text(value).font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundColor(theme.textPrimary)
            Text(unit).font(.system(size: 10, design: .monospaced)).foregroundColor(theme.textSecondary)
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

    // Cached formatters — formattedTime is called per route-table row while the view re-renders at 1 Hz,
    // and allocating a DateFormatter each call is among the most expensive Foundation allocations. (efficiency)
    private static let timeFormatterLocal: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let timeFormatterUTC: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = TimeZone(identifier: "UTC"); return f
    }()

    private func formattedTime(_ date: Date?) -> String {
        guard let date else { return "--:--" }
        let f = flightData?.alwaysUseUTC == true ? Self.timeFormatterUTC : Self.timeFormatterLocal
        return f.string(from: date)
    }
}
