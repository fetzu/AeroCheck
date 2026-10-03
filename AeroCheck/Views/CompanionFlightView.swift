import Combine
import SwiftUI

/// Full-screen iPhone companion — the "wingman" second screen. Two glanceable modes the pilot swipes
/// between (NAV | CHECKLIST), defaulting by flight phase: CHECKLIST on the ground, NAV in the air.
/// Only shown once a flight is active on the iPad; otherwise a "start a flight" prompt.
/// - Over both: the read band, as on the phone Cockpit (the strip, the next line, the NOW line).
/// - NAV: the phone Cockpit's ROUTE from the stream (DEST, legs, radio) and its act band
///   (`CompanionNavScreen.swift`). (6.2.0)
/// - CHECKLIST: the SAME hero + rows as the iPad checklist; tap to advance + NEXT, driving the iPad.
///
/// Theming: the view renders in the MASTER's resolved day/sunlight/night cockpit theme (streamed in the
/// flight data), overriding this device's own theme so the two screens match. (companion v2)
struct CompanionFlightView: View {
    @EnvironmentObject var companionConnectivityManager: CompanionConnectivityManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Mode: Hashable { case nav, checklist }
    @State private var mode: Mode
    @State private var userPickedMode: Bool

    /// `initialMode`: a mode picked from the start, as a swipe would (the stack-budget test's NAV).
    init(initialMode: Mode? = nil) {
        _mode = State(initialValue: initialMode ?? .checklist)
        _userPickedMode = State(initialValue: initialMode != nil)
    }
    /// The hold on the COMPANION tag that leaves Companion mode, 0 to 1: the tag fills red from the left
    /// for as long as the hold takes, as END FLIGHT's button does, and empties if released early. (6.1.0)
    @State private var exitHoldProgress: CGFloat = 0
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
                // The read band over both modes, as on the phone Cockpit; frozen data dimmed. (6.2.0)
                CompanionReadBand(flightData: flightData,
                                  nav: CompanionNav(flightData: flightData, snapshot: flightPlan),
                                  onShowNav: { pick(.nav) })
                    .opacity(isDataStale ? 0.4 : 1)
                    // A mid-flight link drop keeps the last (frozen) flight data, so isFlightActive stays
                    // true. Surface the "connection lost / switch to standalone" escape here too — not only
                    // on the not-flying screen — falling back to the amber stale banner when merely
                    // connected-but-stale. Over the read band, not above it: in the layout, each gap in the
                    // stream pushed everything under it down 37–60 pt and back. What it covers is what is
                    // frozen while it shows. (6.1.0; over the read band 6.2.0)
                    .overlay(alignment: .top) {
                        if companionConnectivityManager.connectionState == .reconnecting ||
                           companionConnectivityManager.connectionState == .disconnected {
                            disconnectedBanner
                        } else if isDataStale {
                            staleBanner
                        }
                    }
                modeSwitcher
                TabView(selection: $mode) {
                    navMode.tag(Mode.nav)
                    checklistMode.tag(Mode.checklist)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
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

    /// How long the COMPANION tag is held to leave Companion mode.
    private static let exitHoldDuration: TimeInterval = 1.0

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
                    .background {
                        theme.action
                            .overlay(alignment: .leading) {
                                GeometryReader { geo in
                                    theme.danger.frame(width: geo.size.width * exitHoldProgress)
                                }
                            }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .onLongPressGesture(minimumDuration: Self.exitHoldDuration, pressing: { pressing in
                        if reduceMotion {
                            exitHoldProgress = pressing ? 1 : 0   // no sweep; the hold is still required (UX-18)
                        } else {
                            withAnimation(.linear(duration: pressing ? Self.exitHoldDuration : 0.2)) {
                                exitHoldProgress = pressing ? 1 : 0
                            }
                        }
                    }, perform: {
                        exitHoldProgress = 0
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
            // The line keeps its height without a name (the iPad ended the link): the header lost 13 pt
            // and the NAV / CHECKLIST switch under it moved up. (6.1.0)
            Text(companionConnectivityManager.connectedDeviceName ?? " ")
                .font(.aero(size: CockpitType.label)).foregroundColor(theme.textSecondary).lineLimit(1)
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

    /// A mode picked by the pilot: the switch, the read band's lines, the slot's "open the list".
    /// Latched directly (even when re-selecting the already-active mode, which wouldn't fire an
    /// .onChange) so auto-by-phase stops overriding the pilot.
    private func pick(_ m: Mode) {
        userPickedMode = true
        withAnimation(reduceMotion ? nil : .default) { mode = m } // (UX-18)
    }

    private func modeButton(_ m: Mode, _ title: String, _ icon: String) -> some View {
        Button { pick(m) } label: {
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

    /// The phone Cockpit's ROUTE, from the stream, with its act band (`CompanionNavScreen.swift`). (6.2.0)
    private var navMode: some View {
        CompanionNavPage(flightData: flightData, snapshot: flightPlan, checkSlot: checkSlot,
                         onCheckSlot: tapCheckSlot, memoryUndo: $memoryUndo)
    }

    /// The iPad's check slot, from its snapshot: the same name, line and colour, and its tap sent back.
    /// Only from an iPad that sends it; its room kept otherwise, as on the Cockpit.
    private var checkSlot: CheckSlot? {
        guard let cl = checklist, cl.supportsFlightCues, let data = cl.checkSlotData else { return nil }
        return try? JSONDecoder().decode(CheckSlot.self, from: data)
    }

    /// The slot's tap: CHECKLIST is this phone's own mode; everything else is the iPad's, sent there. A
    /// confirmation is offered back for six seconds, as on the iPad.
    private func tapCheckSlot(_ slot: CheckSlot) {
        if slot.action == .showChecklist {
            pick(.checklist)
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

    /// An angle folded into -180…180°: the next line's turn arrow (`CompanionNav.next`). In one step: the
    /// `while rel > 180 { rel -= 360 }` it replaces
    /// never ended on a course of 1e300 from the master (subtracting 360 changes nothing at that
    /// magnitude), freezing the phone. The wire bounds the course now; this holds without them.
    static func signedAngle(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var r = degrees.truncatingRemainder(dividingBy: 360)
        if r > 180 { r -= 360 } else if r < -180 { r += 360 }
        return r
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
                // Out of the check before departure: READY FOR LINE UP, which the iPad records on this
                // NEXT, as on its own. (6.2)
                let phase = ChecklistPhase(rawValue: cl.phaseRawValue)
                let label = CockpitNextLabel(
                    leaving: phase,
                    to: phase?.nextNavigable(circuitMode: flightData?.isCircuitMode == true),
                    deferred: cl.deferredItemIds.count)
                CockpitThumbButton(title: label.title, subtitle: label.subtitle, icon: label.icon,
                                   style: .filled(fill: theme.action, text: theme.actionText)) {
                    requestNextPhase(cl)
                }
                .accessibilityHint(label.accessibilityHint ?? "")
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

    // MARK: - Shared chrome

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

    // MARK: - Formatting

    private func formattedTime(_ date: Date?) -> String {
        CompanionClock.text(date, utc: flightData?.alwaysUseUTC == true)
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
