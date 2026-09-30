import Combine
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
    /// NEXT's review of the items still open, as on the Cockpit. (v6.0 review, decision 2)
    @State private var openItemsReview: CompanionOpenItemsReview?
    @State private var showDeferredList = false
    /// The deferred check being run from the list, by phase. (v6.0 review, J1)
    @State private var runningCheck: Int?
    /// ✓ DONE just sent for a memory check, offered back for six seconds as on the iPad. (6.1)
    @State private var memoryUndo: NavUndoOffer?
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
        // The landed card, as on the iPad, answered from here too. (6.1, M4)
        .overlay { landedCardOverlay }
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
                    .font(.aero(size: CockpitType.label, weight: .bold, design: .monospaced))
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
                    .font(.aero(size: CockpitType.label, weight: .bold, design: .monospaced))
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
                Text(name).font(.aero(size: CockpitType.label)).foregroundColor(theme.textSecondary).lineLimit(1)
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
            Text("GPS").font(.aero(size: CockpitType.label, weight: .medium, design: .monospaced)).foregroundColor(theme.textSecondary)
            Text(gpsSourceLabel).font(.aero(size: CockpitType.label, design: .monospaced)).foregroundColor(theme.textPrimary)
            Circle().fill(gpsColor).frame(width: 10, height: 10)
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
        // The theme's tokens, which follow day, night and sunlight; the fixed colours stayed at full
        // brightness at night. (v6.0 review)
        case "good": return theme.onTarget
        case "degraded": return theme.warning
        case "lost": return theme.danger
        default: return .gray
        }
    }

    // MARK: - Waiting (connected, no flight yet)

    private var waitingScreen: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: isConnected ? "airplane.circle" : "antenna.radiowaves.left.and.right")
                .font(.aero(size: 52)).foregroundColor(theme.action.opacity(0.85))
            let name = companionConnectivityManager.connectedDeviceName ?? L10n.Companion.masterDevice
            if isConnected {
                Text(String(format: L10n.Companion.connectedWith, name))
                    .font(.aero(size: 17, weight: .semibold)).foregroundColor(theme.textPrimary)
                Text(String(format: L10n.Companion.startFlightOnMaster, name))
                    .font(.aero(.subheadline)).foregroundColor(theme.textSecondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 36)
            } else {
                Text(String(format: L10n.Companion.connectingTo, name))
                    .font(.aero(size: 16)).foregroundColor(theme.textSecondary)
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
                Image(systemName: icon).font(.aero(size: CockpitType.label))
                Text(title).font(.aero(size: CockpitType.label, weight: .bold, design: .monospaced))
            }
            .foregroundColor(mode == m ? theme.actionText : theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: CockpitTarget.control - 6)
            .background(mode == m ? theme.action : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        // A Cockpit control's height, as the Cockpit's own pane switch. (v6.0 review)
        .frame(minHeight: CockpitTarget.control)
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
        // The iPad's check slot at the foot, where the thumb is, as on the iPad's map. (6.1, cues)
        .safeAreaInset(edge: .bottom, spacing: 0) { companionCheckSlot }
    }

    /// The iPad's check slot, from its snapshot: the same name, line and colour, and its tap sent back.
    /// Only from an iPad that sends it; nothing otherwise, as before 6.1.
    @ViewBuilder
    private var companionCheckSlot: some View {
        if let cl = checklist, cl.supportsFlightCues, let data = cl.checkSlotData,
           let slot = try? JSONDecoder().decode(CheckSlot.self, from: data) {
            CheckSlotButton(slot: slot, prominent: true) { tapCheckSlot(slot) }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(theme.background)
                .overlay(alignment: .top) {
                    if let offer = memoryUndo {
                        NavUndoToast(offer: offer) { memoryUndo = nil }
                            .padding(.horizontal, 12)
                            .offset(y: -CockpitTarget.control - 8)
                    }
                }
        }
    }

    /// The slot's tap: CHECKLIST is this phone's own mode; everything else is the iPad's, sent there. A
    /// confirmation is offered back for six seconds, as on the iPad.
    private func tapCheckSlot(_ slot: CheckSlot) {
        if slot.action == .showChecklist {
            userPickedMode = true
            withAnimation(reduceMotion ? nil : .default) { mode = .checklist }
            return
        }
        companionConnectivityManager.sendCommand(.checkSlotTap(phaseRawValue: slot.phase.rawValue,
                                                               action: slot.action.rawValue))
        if slot.action == .confirmFromMemory || slot.action == .advanceAndConfirm {
            let raw = slot.phase.rawValue
            memoryUndo = NavUndoOffer(message: L10n.Cockpit.doneFromMemoryToast(slot.phase.shortTitle), style: .outlined) {
                companionConnectivityManager.sendCommand(.undoMemoryCheck(phaseRawValue: raw))
            }
        }
    }

    /// The landed card over the phone's screen while it is up on the iPad; an answer from here is the
    /// iPad's. The backdrop ignores taps, as there.
    @ViewBuilder
    private var landedCardOverlay: some View {
        if let cl = checklist, cl.supportsFlightCues, let card = cl.landedCard {
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                LandedCardView(aerodrome: card.aerodrome, time: formattedTime(card.touchdown),
                               landingCheckSettled: card.landingCheckSettled) { answer in
                    companionConnectivityManager.sendCommand(.answerLandedCard(cardId: card.id, answer: answer.rawValue))
                }
            }
        }
    }

    private var nextWaypoint: (index: Int, wp: CompanionWaypoint)? {
        guard let plan = flightPlan else { return nil }
        let idx = flightData?.currentWaypointIndex ?? plan.currentWaypointIndex
        // Diverted on the master: the second screen points where the aircraft is going. (v5.1)
        if let diversion = plan.diversion { return (idx, diversion) }
        guard plan.waypoints.indices.contains(idx) else { return nil }
        return (idx, plan.waypoints[idx])
    }

    /// True geographic bearing (0–360°) from the current GPS position to the waypoint, or nil with no fix.
    private func bearingToWaypoint(_ wp: CompanionWaypoint) -> Double? {
        guard let lat1 = flightData?.latitude, let lon1 = flightData?.longitude, wp.hasValidCoordinate else { return nil }
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
            return Self.signedAngle(brg - (flightData?.courseDegrees ?? 0))
        }
        // No fix: best-effort using the planned magnetic course vs current track.
        guard let mc = wp.magneticCourse, let track = flightData?.courseDegrees else { return 0 }
        return Self.signedAngle(mc - track)
    }

    /// An angle folded into -180…180°. In one step: the `while rel > 180 { rel -= 360 }` it replaces
    /// never ended on a course of 1e300 from the master (subtracting 360 changes nothing at that
    /// magnitude), freezing the phone. The wire bounds the course now; this holds without them.
    static func signedAngle(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var r = degrees.truncatingRemainder(dividingBy: 360)
        if r > 180 { r -= 360 } else if r < -180 { r += 360 }
        return r
    }

    private func nextWaypointHero(index: Int, waypoint wp: CompanionWaypoint) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(theme.action, lineWidth: 2).frame(width: 84, height: 84)
                Image(systemName: "arrow.up").font(.aero(size: 40, weight: .semibold)).foregroundColor(theme.action)
                    .rotationEffect(.degrees(arrowRotation(wp)))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: arrowRotation(wp)) // (UX-18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.Nav.next.uppercased()).font(.aero(size: CockpitType.label, weight: .bold, design: .monospaced)).foregroundColor(theme.textSecondary)
                // The next waypoint in the route's colour, as on the Cockpit's card.
                Text(wp.name.isEmpty ? "WP\(index + 1)" : wp.name)
                    .font(.aero(size: CockpitType.item, weight: .bold, design: .monospaced)).foregroundColor(theme.route)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let mc = wp.magneticCourse {
                    Text(String(format: "%03.0f° mag", mc)).font(.aero(size: CockpitType.label, design: .monospaced)).foregroundColor(theme.textSecondary)
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
            Text(label).font(.aero(size: CockpitType.label, design: .monospaced)).foregroundColor(theme.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.aero(size: CockpitType.button, weight: .bold, design: .monospaced)).foregroundColor(theme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if !unit.isEmpty { Text(unit).font(.aero(size: CockpitType.label, design: .monospaced)).foregroundColor(theme.textSecondary) }
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
                            Text("PLAN").font(.aero(size: CockpitType.label, weight: .bold, design: .monospaced)).foregroundColor(theme.action)
                            Spacer()
                            Image(systemName: showFullPlan ? "chevron.up" : "chevron.down").font(.aero(size: CockpitType.label)).foregroundColor(theme.action)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: CockpitTarget.control)
                        .contentShape(Rectangle())
                    }
                    if showFullPlan { routeTable(plan).frame(maxHeight: 320) } else { upcomingStrip(plan) }
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
                Text("—").font(.aero(size: CockpitType.label, design: .monospaced)).foregroundColor(theme.textSecondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            } else {
                ForEach(Array(upcoming), id: \.element.id) { i, wp in
                    HStack {
                        Text("\(i + 1) · \(wp.name.isEmpty ? "WP" : wp.name)").lineLimit(1)
                        Spacer()
                        Text(wp.magneticCourse.map { String(format: "%03.0f°", $0) } ?? "---")
                        Text(wp.distance.map { String(format: "%.1f NM", $0) } ?? "---").frame(width: 96, alignment: .trailing)
                    }
                    .font(.aero(size: CockpitType.label, design: .monospaced)).foregroundColor(theme.textPrimary.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 6)
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
                    Text("FREQ").font(.aero(size: CockpitType.label, design: .monospaced)).foregroundColor(theme.textSecondary)
                    Text(freqDescriptor).font(.aero(size: CockpitType.label, weight: .semibold, design: .monospaced)).foregroundColor(theme.textPrimary).lineLimit(1)
                }
                Text(freqValue).font(.aero(size: CockpitType.row, weight: .bold, design: .monospaced)).foregroundColor(theme.textPrimary)
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
                        Image(systemName: "stopwatch").font(.aero(size: CockpitType.label)).foregroundColor(theme.action)
                        Text("CHRONO").font(.aero(size: CockpitType.label, design: .monospaced)).foregroundColor(theme.action)
                    }
                    Text(formattedChronometer).font(.aero(size: CockpitType.row, weight: .bold, design: .monospaced)).foregroundColor(theme.textPrimary)
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
                Image(systemName: "clock.badge.checkmark").font(.aero(size: CockpitType.response, weight: .bold))
                Text(L10n.Companion.recordATO).font(.aero(size: CockpitType.button, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            // The thumb bar's height, as MARK on the Cockpit. (v6.0 review)
            .foregroundColor(theme.actionText).frame(maxWidth: .infinity, minHeight: CockpitTarget.thumb)
            .background(theme.action).clipShape(RoundedRectangle(cornerRadius: 10))
        }
        // No ButtonStyle here, so .disabled() alone won't dim the inline background — dim explicitly so a
        // no-op tap (ATO already recorded / no active waypoint) reads as disabled. (v4.1.0)
        .disabled(!canRecordATO)
        .opacity(canRecordATO ? 1.0 : 0.45)
    }

    // MARK: - CHECKLIST mode
    //
    // The phone Cockpit's checklist, driven over the link: the list at the Cockpit's scale, CHECK and
    // DEFER in a thumb bar, NEXT listing what is still open before leaving the phase, and the deferred
    // list checked from here. Every action is the iPad's own, sent as a command; the iPad stays the
    // source of truth and its snapshot redraws this. A tap on the list still checks, as on the phone
    // (I2). (v6.0 review, decision 2)

    /// Everything on the list reached: CHECK gives way to NEXT, as on the Cockpit. A memory check, once
    /// confirmed. (6.1)
    private var phaseComplete: Bool {
        guard let cl = checklist else { return false }
        if awaitsMemoryConfirmation(cl) { return false }
        return cl.visibleCount == 0 || cl.completedCount >= cl.visibleCount
    }

    /// The iPad's current check is a memory check still to confirm, and it takes the confirmation from
    /// here. An older iPad counts it done and says nothing: NEXT, as before. (6.1)
    private func awaitsMemoryConfirmation(_ cl: CompanionChecklistSnapshot) -> Bool {
        cl.supportsMemoryConfirm && cl.memoryCheck && !cl.memoryCheckDone
    }

    /// ✓ DONE: the iPad records it, and this screen offers it back for six seconds. `andNext`: the same
    /// tap goes on to the next check, as on the iPad's checklist pane, and UNDO takes both back. (6.1)
    private func confirmMemoryCheck(_ cl: CompanionChecklistSnapshot, phaseRawValue: Int, andNext: Bool = false) {
        companionConnectivityManager.sendCommand(andNext ? .confirmMemoryCheckAndNext(phaseRawValue: phaseRawValue)
                                                         : .confirmMemoryCheck(phaseRawValue: phaseRawValue))
        let title = ChecklistPhase(rawValue: phaseRawValue)?.shortTitle ?? cl.phaseTitle
        memoryUndo = NavUndoOffer(message: L10n.Cockpit.doneFromMemoryToast(title), style: .outlined) {
            companionConnectivityManager.sendCommand(.undoMemoryCheck(phaseRawValue: phaseRawValue))
        }
    }

    private var checklistMode: some View {
        Group {
            if let cl = checklist {
                VStack(spacing: 0) {
                    checklistPhaseHeader(cl)
                    if cl.deferredItemCount > 0 || !cl.deferredChecks.isEmpty {
                        deferredItemsEntry(cl)
                    }
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
                                    Rectangle().fill(theme.panelStroke).frame(height: 1).padding(.vertical, 12)
                                    HStack { Spacer()
                                        Text(completion).font(.aero(size: CockpitType.label, weight: .bold, design: .monospaced)).foregroundColor(theme.onTarget)
                                        Spacer() }
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                        }
                        .onChange(of: cl.highlightedIndex) { _, idx in
                            withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(idx, anchor: UnitPoint(x: 0.5, y: 0.12)) } // (UX-18)
                        }
                        // And on arriving in this mode, so the current item isn't left under the thumb bar.
                        .onAppear { proxy.scrollTo(cl.highlightedIndex, anchor: UnitPoint(x: 0.5, y: 0.12)) }
                    }
                    // A tap on the list checks the highlighted item, as on the phone Cockpit (I2).
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !phaseComplete && !awaitsMemoryConfirmation(cl) {
                            companionConnectivityManager.sendCommand(.advanceChecklistItem)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let offer = memoryUndo {
                            NavUndoToast(offer: offer) { memoryUndo = nil }
                                .padding(.horizontal, 12)
                                .padding(.bottom, 8)
                        }
                    }

                    thumbBar(cl)
                }
                .sheet(item: $openItemsReview) { review in
                    OpenItemsReviewSheet(
                        phase: review.phase, items: review.items, openCount: review.count,
                        memoryCheck: review.memoryCheck,
                        onBack: { openItemsReview = nil },
                        onContinue: {
                            openItemsReview = nil
                            companionConnectivityManager.sendCommand(.nextChecklistPhase)
                        })
                    .environment(\.cockpitTheme, theme)
                }
                .sheet(isPresented: $showDeferredList, onDismiss: { runningCheck = nil }) {
                    deferredSheet
                        .environment(\.cockpitTheme, theme)
                }
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "checklist").font(.aero(size: 40)).foregroundColor(theme.textSecondary)
                    Text(L10n.Companion.checklistUnavailable).font(.aero(size: CockpitType.label)).foregroundColor(theme.textSecondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 30)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func checklistPhaseHeader(_ cl: CompanionChecklistSnapshot) -> some View {
        HStack(spacing: 6) {
            Button { companionConnectivityManager.sendCommand(.previousChecklistPhase) } label: {
                Image(systemName: "chevron.left").font(.aero(size: CockpitType.row, weight: .semibold))
                    .foregroundColor(theme.action)
                    .frame(width: CockpitTarget.control, height: CockpitTarget.control)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.Accessibility.previousPhase)
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Text(cl.phaseTitle).font(.aero(size: CockpitType.label, weight: .bold)).foregroundColor(theme.textPrimary)
                    .textCase(.uppercase).lineLimit(1).minimumScaleFactor(0.7)
                if cl.visibleCount > 0 {
                    Text("\(min(cl.completedCount, cl.visibleCount)) / \(cl.visibleCount)")
                        .font(.aero(size: CockpitType.label, design: .monospaced)).foregroundColor(theme.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            // The next phase, through the same review as NEXT when items are still open.
            Button { requestNextPhase(cl) } label: {
                Image(systemName: "chevron.right").font(.aero(size: CockpitType.row, weight: .semibold))
                    .foregroundColor(theme.action)
                    .frame(width: CockpitTarget.control, height: CockpitTarget.control)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.Accessibility.nextPhase)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
    }

    @ViewBuilder
    private func checklistRow(_ cl: CompanionChecklistSnapshot, index: Int, item: CompanionChecklistItem) -> some View {
        let isDeferred = index < cl.highlightedIndex && cl.deferredItemIds.contains(item.id)
        if index < cl.highlightedIndex && !item.isHeader && cl.supportsDefer {
            // A tap on a checked row reopens that item alone; on an open one, checks it. As on the
            // iPad, and over the list's own tap, which checks the current item. (v6.0 review, K-C)
            Button {
                companionConnectivityManager.sendCommand(.toggleChecklistItem(phaseRawValue: cl.phaseRawValue, itemId: item.id))
            } label: {
                ChecklistItemRow(
                    item: ChecklistItem(challenge: item.challenge, response: item.response, isHeader: item.isHeader),
                    showSeparator: index < cl.items.count - 1,
                    isHighlighted: false,
                    isCompleted: !isDeferred,
                    isDeferred: isDeferred
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isDeferred ? L10n.Cockpit.checkAgainHint : L10n.Cockpit.reopenHint)
        } else if index == cl.highlightedIndex {
            CockpitHeroChecklistItem(
                challenge: item.challenge,
                response: item.response,
                progressText: "\(index + 1) / \(cl.items.count)",
                showAdvanceHint: false
            ).padding(.vertical, 4)
        } else {
            // Passed over with DEFER on the iPad: drawn deferred, as there, not ticked as done.
            // (v6.0 review, B2)
            ChecklistItemRow(
                item: ChecklistItem(challenge: item.challenge, response: item.response, isHeader: item.isHeader),
                showSeparator: index < cl.items.count - 1,
                isHighlighted: false,
                isCompleted: index < cl.highlightedIndex && !isDeferred,
                isDeferred: isDeferred
            )
        }
    }

    /// The Cockpit's deferred-items row. It opens the list when the iPad sent it (a viewer entitled to
    /// the text); otherwise it only says how many, as the list would have nothing to show.
    @ViewBuilder
    private func deferredItemsEntry(_ cl: CompanionChecklistSnapshot) -> some View {
        if cl.supportsDefer && (!cl.deferredGroups.isEmpty || cl.deferredChecks.contains { !$0.items.isEmpty }
                                || (cl.supportsMemoryConfirm && cl.deferredChecks.contains { $0.fromMemory })) {
            DeferredItemsChip(checks: cl.deferredChecks.count, count: cl.deferredItemCount) { showDeferredList = true }
                .padding(.horizontal, 12).padding(.bottom, 4)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(L10n.Deferred.summary(checks: cl.deferredChecks.count, items: cl.deferredItemCount))
                Spacer(minLength: 0)
            }
            .font(.aero(size: CockpitType.label, weight: .semibold))
            .foregroundColor(theme.warning)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: CockpitTarget.control)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.warning.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.warning.opacity(0.6), lineWidth: 1))
            .padding(.horizontal, 12).padding(.bottom, 4)
            .accessibilityElement(children: .combine)
        }
    }

    /// The iPad's deferred list, or the check being run from it, from the snapshot. Every action is
    /// sent; the next snapshot redraws this. (v6.0 review, decision 2 and J1)
    @ViewBuilder
    private var deferredSheet: some View {
        let checks = checklist?.deferredChecks ?? []
        if let raw = runningCheck, let check = checks.first(where: { $0.phaseRawValue == raw }), !check.items.isEmpty {
            DeferredCheckRunView(
                title: check.phaseTitle,
                backTitle: checklist.flatMap { ChecklistPhase(rawValue: $0.phaseRawValue)?.shortTitle } ?? "",
                rows: check.items.map { .init(id: $0.id, item: ChecklistItem(challenge: $0.challenge, response: $0.response, isHeader: $0.isHeader)) },
                highlightedIndex: check.highlightedIndex,
                deferredIds: Set(check.deferredItemIds),
                onCheck: { companionConnectivityManager.sendCommand(.checkInDeferredCheck(phaseRawValue: raw)) },
                onDefer: { companionConnectivityManager.sendCommand(.deferInDeferredCheck(phaseRawValue: raw)) },
                onBack: { runningCheck = nil })
        } else {
            let confirmsFromMemory = checklist?.supportsMemoryConfirm == true
            DeferredItemsList(
                checks: checks.filter { !$0.items.isEmpty || ($0.fromMemory && confirmsFromMemory) }.map {
                    .init(phaseRawValue: $0.phaseRawValue, title: $0.phaseTitle, remaining: $0.remaining, total: $0.total,
                          fromMemory: $0.fromMemory && confirmsFromMemory)
                },
                groups: deferredListGroups,
                onRun: { runningCheck = $0 },
                onConfirmFromMemory: { raw in
                    companionConnectivityManager.sendCommand(.confirmMemoryCheck(phaseRawValue: raw))
                },
                onCheck: { id, phaseRawValue in
                    companionConnectivityManager.sendCommand(.checkDeferredItem(phaseRawValue: phaseRawValue, itemId: id))
                },
                onClose: { showDeferredList = false })
        }
    }

    private var deferredListGroups: [DeferredItemsList.Group] {
        (checklist?.deferredGroups ?? []).map { group in
            DeferredItemsList.Group(
                phaseRawValue: group.phaseRawValue, title: group.phaseTitle,
                items: group.items.map { .init(id: $0.id, item: ChecklistItem(challenge: $0.challenge, response: $0.response)) })
        }
    }

    /// The thumb bar: DEFER and CHECK (which names the item) while items are open, then NEXT, as on the
    /// Cockpit. DEFER only when this iPad takes it: an older one would drop the command.
    private func thumbBar(_ cl: CompanionChecklistSnapshot) -> some View {
        HStack(spacing: 8) {
            if awaitsMemoryConfirmation(cl) {
                // As the iPad's: the memory check confirmed from memory and, where the iPad says it
                // goes on, the next check opened, one tap. (6.1)
                let next = cl.memoryCheckNextRawValue.flatMap { ChecklistPhase(rawValue: $0) }
                CockpitThumbButton(title: L10n.Cockpit.memoryCheckDone(
                                        ChecklistPhase(rawValue: cl.phaseRawValue)?.shortTitle ?? cl.phaseTitle),
                                   subtitle: next.map { L10n.Cockpit.fromMemoryThenNext($0.shortTitle) }
                                       ?? L10n.Cockpit.fromMemory,
                                   icon: "checkmark",
                                   style: .filled(fill: theme.action, text: theme.actionText)) {
                    confirmMemoryCheck(cl, phaseRawValue: cl.phaseRawValue, andNext: next != nil)
                }
            } else if !phaseComplete {
                if cl.supportsDefer {
                    CockpitThumbButton(title: L10n.Cockpit.deferItem, subtitle: L10n.Cockpit.deferHint,
                                       style: .outlined(tint: theme.warning)) {
                        companionConnectivityManager.sendCommand(.deferChecklistItem)
                    }
                    .frame(maxWidth: 112)
                }
                CockpitThumbButton(title: L10n.Cockpit.check, subtitle: currentChallenge(cl), icon: "checkmark",
                                   style: .filled(fill: theme.action, text: theme.actionText)) {
                    companionConnectivityManager.sendCommand(.advanceChecklistItem)
                }
            } else {
                let deferred = cl.deferredItemIds.count
                let next = ChecklistPhase(rawValue: cl.phaseRawValue)?.nextNavigable(circuitMode: flightData?.isCircuitMode == true)
                CockpitThumbButton(title: next.map { L10n.Cockpit.next($0.shortTitle) } ?? L10n.Button.next,
                                   subtitle: deferred > 0 ? L10n.Deferred.count(deferred) : L10n.Cockpit.allChecked,
                                   icon: "chevron.right",
                                   style: .filled(fill: theme.action, text: theme.actionText)) {
                    requestNextPhase(cl)
                }
                .modifier(PulseModifier(isActive: phaseComplete))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(theme.panelStroke).frame(height: 1) }
    }

    private func currentChallenge(_ cl: CompanionChecklistSnapshot) -> String? {
        cl.items.indices.contains(cl.highlightedIndex) ? cl.items[cl.highlightedIndex].challenge : nil
    }

    /// NEXT: with items still open, list them before leaving the phase, as the iPad does (v6.0 · B2).
    /// A viewer without the items' text gets the count.
    private func requestNextPhase(_ cl: CompanionChecklistSnapshot) {
        // A memory check not confirmed: reviewed, then deferred whole by the iPad, as there. (6.1)
        if awaitsMemoryConfirmation(cl), let phase = ChecklistPhase(rawValue: cl.phaseRawValue) {
            openItemsReview = CompanionOpenItemsReview(phase: phase, items: [], count: 0, memoryCheck: true)
            return
        }
        guard cl.openItemCount > 0, let phase = ChecklistPhase(rawValue: cl.phaseRawValue) else {
            companionConnectivityManager.sendCommand(.nextChecklistPhase)
            return
        }
        let open = cl.items.enumerated()
            .filter { $0.offset >= cl.highlightedIndex && !$0.element.isHeader }
            .map { ChecklistItem(challenge: $0.element.challenge, response: $0.element.response) }
        openItemsReview = CompanionOpenItemsReview(phase: phase, items: open, count: cl.openItemCount)
    }

    /// "Hidden Checklist Content" placeholder — matches the iPad's learning-mode indicator. Hold to
    /// reveal; the reveal command flips the master's reveal state, which streams the items to BOTH.
    private func hiddenContentPlaceholder(count: Int) -> some View {
        VStack(spacing: 8) {
            Rectangle().fill(theme.warning.opacity(0.3)).frame(height: 1).padding(.top, 12)
            HStack(spacing: 10) {
                Image(systemName: "eye.slash.fill").font(.aero(size: CockpitType.row)).foregroundColor(theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.ChecklistAction.hiddenItemsTitle)
                        .font(.aero(size: CockpitType.label, weight: .bold)).foregroundColor(theme.warning)
                    Text(L10n.ChecklistAction.hiddenItemsCount(count, count == 1 ? "" : "s"))
                        .font(.aero(size: CockpitType.label)).foregroundColor(theme.textSecondary)
                }
                Spacer()
                Text(L10n.Companion.holdToReveal).font(.aero(size: CockpitType.label, weight: .medium)).foregroundColor(theme.textDim)
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            .frame(minHeight: CockpitTarget.control)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(theme.warning.opacity(0.1))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.warning.opacity(0.3), lineWidth: 1))
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
                if isPast { Image(systemName: "checkmark").font(.aero(size: CockpitType.label)).foregroundColor(theme.onTarget) }
                else if isCurrent { Image(systemName: "arrowtriangle.right.fill").font(.aero(size: CockpitType.label)).foregroundColor(theme.route) }
                else { Text("\(index + 1)").font(.aero(size: CockpitType.label, design: .monospaced)).foregroundColor(theme.textSecondary) }
            }.frame(width: 28)
            // The Cockpit's label size throughout: the name takes what the four figures leave. (v6.0 review)
            Text(wp.name.isEmpty ? "WP\(index)" : wp.name).font(.aero(size: CockpitType.label, weight: isCurrent ? .bold : .regular, design: .monospaced)).foregroundColor(isCurrent ? theme.route : textColor).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity, alignment: .leading)
            Text(wp.magneticCourse.map { String(format: "%03.0f", $0) } ?? "---").font(.aero(size: CockpitType.label, design: .monospaced)).foregroundColor(textColor).frame(width: 44)
            Text(wp.distance.map { String(format: "%.1f", $0) } ?? "---").font(.aero(size: CockpitType.label, design: .monospaced)).foregroundColor(textColor).frame(width: 52)
            Text(formattedTime(wp.estimatedTimeOver)).font(.aero(size: CockpitType.label, design: .monospaced)).foregroundColor(textColor).frame(width: 60)
            Button {
                if wp.actualTimeOver == nil { companionConnectivityManager.sendCommand(.recordATO(waypointIndex: index)) }
            } label: {
                Text(formattedTime(wp.actualTimeOver)).font(.aero(size: CockpitType.label, weight: wp.actualTimeOver != nil ? .bold : .regular, design: .monospaced)).foregroundColor(wp.actualTimeOver != nil ? theme.onTarget : theme.action).frame(width: 60)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }.disabled(wp.actualTimeOver != nil)
        }
        .padding(.vertical, 2)
        .background(isCurrent ? theme.action.opacity(0.1) : Color.clear)
    }

    // MARK: - Shared chrome

    private var noFlightPlanContent: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass").font(.aero(size: 36)).foregroundColor(theme.textSecondary)
            Text(L10n.Companion.noFlightPlan).font(.aero(.subheadline)).foregroundColor(theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var disconnectedBanner: some View {
        HStack {
            Image(systemName: "wifi.slash")
            Text(L10n.Companion.connectionLost).font(.aero(size: CockpitType.label, weight: .semibold))
            Spacer()
            Button(L10n.Companion.switchToStandalone) { companionConnectivityManager.switchToStandalone() }
                .font(.aero(size: CockpitType.label, weight: .semibold)).foregroundColor(.black)
                .padding(.horizontal, 10).frame(minHeight: 44)
                .background(Color.black.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 4))
        }
        // The caution colour of the theme, dark text on it as on the stale-data banner below; white on
        // a fixed orange was both off the contract and hard to read. (v6.0 review)
        .foregroundColor(.black).padding(.horizontal, 12).padding(.vertical, 8).background(theme.warning)
    }

    private var staleBanner: some View {
        HStack {
            Image(systemName: "wifi.exclamationmark")
            Text(L10n.Companion.dataStale).font(.aero(size: CockpitType.label, weight: .semibold))
            Spacer()
        }
        .foregroundColor(.black).padding(.horizontal, 12).padding(.vertical, 8).background(theme.warning)
    }

    private var instrumentsStrip: some View {
        HStack {
            instrumentItem("GS", formattedSpeed, "kt")
            Divider().frame(height: 20)
            instrumentItem("ALT", formattedAltitude, "ft")
            Divider().frame(height: 20)
            instrumentItem("TRK", formattedTrack, "°")
        }
        .padding(.horizontal, 12).padding(.vertical, 10).background(theme.panel)
    }

    private func instrumentItem(_ label: String, _ value: String, _ unit: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.aero(size: CockpitType.label, weight: .medium, design: .monospaced)).foregroundColor(theme.textSecondary)
            Text(value).font(.aero(size: CockpitType.row, weight: .bold, design: .monospaced)).foregroundColor(theme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(unit).font(.aero(size: CockpitType.label, design: .monospaced)).foregroundColor(theme.textSecondary)
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
        // The master's number: bounded at the wire (CompanionWireLimits), and `safeInt` all the
        // same, since `Int(e)` on an unrepresentable value is a trap, not an error.
        let e = max(0, (flightData?.chronometerElapsed ?? 0).safeInt(or: 0))
        return String(format: "%02d:%02d:%02d", e / 3600, (e % 3600) / 60, e % 60)
    }

    private func formattedEET(_ wp: CompanionWaypoint) -> String {
        let hasLeg = (wp.estimatedElapsedTime ?? 0) > 0
        let hasExtra = (wp.legEETExtra ?? 0) > 0
        if !hasLeg && !hasExtra { return "---" }
        // `safeInt`: the leg times come from the master's plan, and an EET of 1e19 in a shared route
        // trapped the viewer. (S9-07)
        let minutes = hasLeg ? (wp.estimatedElapsedTime! / 60).safeInt(or: 0) : 0
        if hasExtra {
            let extra = (wp.legEETExtra! / 60).safeInt(or: 0)
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

/// What NEXT's review lists on the viewer.
struct CompanionOpenItemsReview: Identifiable {
    let phase: ChecklistPhase
    let items: [ChecklistItem]
    let count: Int
    /// A memory check left unconfirmed. (6.1)
    var memoryCheck: Bool = false
    var id: Int { phase.rawValue }
}
