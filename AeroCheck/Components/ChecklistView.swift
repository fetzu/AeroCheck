import SwiftUI

// MARK: - Action Button with Long Press Support

/// A button that can only be pressed once, but allows long-press (3+ seconds) to update the time
struct TimestampActionButton: View {
    @Environment(\.cockpitTheme) private var theme
    let title: String
    let icon: String
    let color: Color
    let timestamp: String?
    let timestampLabel: String
    var timestampSuffix: String = ""
    let isPulsing: Bool
    /// HUD bottom-bar style: single row at NEXT's height/corner radius (no timestamp/hint stacked
    /// below), so it sits flush next to the NEXT button. (v4 UI/UX Revamp)
    var compact: Bool = false
    let onFirstPress: () -> Void
    let onUpdateTime: () -> Void

    @State private var isPressed = false
    @State private var showUpdateConfirmation = false
    @State private var longPressProgress: CGFloat = 0
    @State private var longPressTimer: Timer?
    
    private var hasBeenPressed: Bool {
        timestamp != nil
    }
    
    var body: some View {
        VStack(spacing: compact ? 0 : 8) {
            // The button — black text on the colour, matching the NEXT button. (v4 UI/UX Revamp)
            HStack {
                Image(systemName: icon)
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .font(.system(size: compact ? 20 : 18, weight: .bold))
            .foregroundColor(compact ? .black : .white)
            // Compact = HUD bottom bar: fill width + match NEXT's vertical padding so the heights are
            // identical; the title shrinks (one line) rather than wrapping when the row is tight.
            .frame(maxWidth: compact ? .infinity : nil)
            .padding(.horizontal, compact ? 0 : 24)
            .padding(.vertical, compact ? 18 : 14)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: compact ? 14 : 10)
                        .fill(hasBeenPressed ? color.opacity(0.5) : color)
                        .shadow(color: color.opacity(hasBeenPressed ? 0.2 : 0.4), radius: 6, x: 0, y: 3)

                    // Long press progress indicator
                    if longPressProgress > 0 && hasBeenPressed {
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: compact ? 14 : 10)
                                .fill(color.opacity(0.8))
                                .frame(width: geo.size.width * longPressProgress)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: compact ? 14 : 10))
                    }
                }
            )
            .scaleEffect(isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isPressed)
            .modifier(PulseModifier(isActive: isPulsing && !hasBeenPressed))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed {
                            isPressed = true
                            if hasBeenPressed {
                                startLongPressTimer()
                            }
                        }
                    }
                    .onEnded { _ in
                        isPressed = false
                        if hasBeenPressed {
                            cancelLongPressTimer()
                        } else {
                            // First press
                            onFirstPress()
                        }
                    }
            )
            
            // Timestamp display + hold hint (full mode only — the compact HUD button is a single row).
            if !compact, let time = timestamp {
                Text("\(timestampLabel): \(time)\(timestampSuffix)")
                    .font(.captionText)
                    .foregroundColor(color)
            }

            if !compact, hasBeenPressed {
                Text(L10n.ChecklistAction.holdToUpdate)
                    .font(.system(size: 10))
                    .foregroundColor(theme.textDim)
            }
        }
        .alert(L10n.ChecklistAction.updateTimeTitle, isPresented: $showUpdateConfirmation) {
            Button(L10n.Button.cancel, role: .cancel) { }
            Button(L10n.ChecklistAction.update) {
                onUpdateTime()
            }
        } message: {
            Text(L10n.ChecklistAction.updateConfirm(timestampLabel.lowercased()))
        }
        // VoiceOver: this control is a DragGesture on a VStack, not a Button, so it exposed no
        // button trait, no name and no activation path — ENGINE START, LINE UP, LANDED and SHUTDOWN
        // were literally inoperable with VoiceOver running, on the HUD bottom bar of an app used in
        // flight. Semantics are added HERE rather than by converting to a Button so the press feel,
        // long-press progress fill and haptics are untouched.
        //
        // Hold-to-update becomes a NAMED ACTION rather than a 1.5 s hold: holding a control steady
        // is exactly what VoiceOver's own gesture handling makes hardest, so a rotor action is both
        // more reliable and more discoverable than the sighted gesture. (UX-10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(
            timestamp.map { "\(timestampLabel) \($0)\(timestampSuffix)" }
                ?? L10n.ChecklistAction.notRecorded
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(hasBeenPressed ? L10n.ChecklistAction.holdToUpdate : "")
        .accessibilityAction {
            // Mirrors the gesture: the first press records, and a control already recorded is not
            // re-recorded by activation — that is what the named action below is for.
            if !hasBeenPressed { onFirstPress() }
        }
        .accessibilityAction(named: L10n.ChecklistAction.update) {
            if hasBeenPressed { showUpdateConfirmation = true }
        }
    }
    
    private func startLongPressTimer() {
        longPressProgress = 0
        longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            longPressProgress += 0.05 / 1.5 // 1.5 seconds total
            if longPressProgress >= 1.0 {
                timer.invalidate()
                longPressTimer = nil
                longPressProgress = 0
                // Haptic feedback
                let generator = UIImpactFeedbackGenerator(style: .heavy)
                generator.impactOccurred()
                showUpdateConfirmation = true
            }
        }
    }
    
    private func cancelLongPressTimer() {
        longPressTimer?.invalidate()
        longPressTimer = nil
        withAnimation(.easeOut(duration: 0.2)) {
            longPressProgress = 0
        }
    }
}

// MARK: - Counter Action Button (for Go Around / Touch and Go)

/// A button that can be pressed multiple times and shows a counter
struct CounterActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let count: Int
    let countLabel: String
    let onPress: () -> Void

    @State private var isPressed = false

    var body: some View {
        VStack(spacing: 8) {
            // The button
            Button(action: {
                // Haptic feedback
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                onPress()
            }) {
                HStack {
                    Image(systemName: icon)
                    Text(title)
                }
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color)
                        .shadow(color: color.opacity(0.4), radius: 6, x: 0, y: 3)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .scaleEffect(isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isPressed)

            // Counter display
            if count > 0 {
                Text("\(countLabel): \(count)")
                    .font(.captionText)
                    .foregroundColor(color)
            }
        }
    }
}

/// Main checklist display view - shows checklist items exactly as in the document
struct ChecklistView: View {
    @Environment(\.cockpitTheme) private var theme
    let phase: ChecklistPhase
    /// The owned, resolved checklist for the active aircraft (items + learning-mode counts).
    var activeChecklist: ActiveChecklist = .bundledDefault
    var onEngineStart: (() -> Void)?
    var onEngineStartUpdate: (() -> Void)?
    var onLineUp: (() -> Void)?
    var onLineUpUpdate: (() -> Void)?
    var onEngineShutdown: (() -> Void)?
    var onEngineShutdownUpdate: (() -> Void)?
    var onGoAround: (() -> Void)?
    var onTouchAndGo: (() -> Void)?
    var onFullStop: (() -> Void)?
    var onLanded: (() -> Void)?
    var onLandedUpdate: (() -> Void)?
    var onBriefingTap: ((BriefingType) -> Void)?
    var onTapToAdvance: (() -> Void)?
    var onAllItemsCompleted: (() -> Void)?
    var engineStartTime: String?
    var lineUpTime: String?
    var landingTime: String?
    var engineShutdownTime: String?
    var goAroundCount: Int = 0
    var touchAndGoCount: Int = 0
    var fullStopCount: Int = 0

    // Settings
    var stepByStepEnabled: Bool = true
    var learningModeEnabled: Bool = false
    var highlightedItemIndex: Int = 0
    var pulseActionButton: Bool = false
    var isCompact: Bool = false
    var checklistLanguage: String = "en" // Language code for button translations
    /// When embedded in the iPad HUD: hide the redundant page/title header, the inline briefing banner
    /// (it's a phase-aware tile), and the inline action buttons (engine-start / line-up / events live
    /// in the HUD bottom bar + event row). (v4 UI/UX Revamp)
    var hudMode: Bool = false

    // Engine hours display
    var engineHourStart: Double? = nil
    var engineHourEnd: Double? = nil
    var engineHourStartInputFormat: String? = nil
    var engineHourEndInputFormat: String? = nil
    var onEditEngineHourStart: (() -> Void)? = nil
    var onEditEngineHourEnd: (() -> Void)? = nil
    /// Owned by the parent so tap-to-advance / completion include revealed items. (v4 UI/UX Revamp)
    @Binding var hiddenItemsRevealed: Bool

    // State for temporarily revealing hidden items
    @State private var revealLongPressProgress: CGFloat = 0
    @State private var revealLongPressTimer: Timer?
    
    // Computed properties
    private var allItems: [ChecklistItem] {
        activeChecklist.items(for: phase)
    }

    private var effectiveLearningMode: Bool {
        learningModeEnabled || hiddenItemsRevealed
    }

    private var visibleItems: [ChecklistItem] {
        activeChecklist.visibleItems(for: phase, learningMode: effectiveLearningMode)
    }

    /// Whether there are items that could be hidden (memorizable items exist and learning mode is off)
    private var hasHiddenItems: Bool {
        !learningModeEnabled && !hiddenItemsRevealed && activeChecklist.hasHiddenItems(for: phase, learningMode: false)
    }

    private var hiddenItemCount: Int {
        // Count of items hidden when not in learning mode
        activeChecklist.items(for: phase).count - activeChecklist.visibleItems(for: phase, learningMode: false).count
    }
    
    init(phase: ChecklistPhase,
         activeChecklist: ActiveChecklist = .bundledDefault,
         onEngineStart: (() -> Void)? = nil,
         onEngineStartUpdate: (() -> Void)? = nil,
         onLineUp: (() -> Void)? = nil,
         onLineUpUpdate: (() -> Void)? = nil,
         onEngineShutdown: (() -> Void)? = nil,
         onEngineShutdownUpdate: (() -> Void)? = nil,
         onGoAround: (() -> Void)? = nil,
         onTouchAndGo: (() -> Void)? = nil,
         onFullStop: (() -> Void)? = nil,
         onLanded: (() -> Void)? = nil,
         onLandedUpdate: (() -> Void)? = nil,
         onBriefingTap: ((BriefingType) -> Void)? = nil,
         onTapToAdvance: (() -> Void)? = nil,
         onAllItemsCompleted: (() -> Void)? = nil,
         engineStartTime: String? = nil,
         lineUpTime: String? = nil,
         landingTime: String? = nil,
         engineShutdownTime: String? = nil,
         goAroundCount: Int = 0,
         touchAndGoCount: Int = 0,
         fullStopCount: Int = 0,
         stepByStepEnabled: Bool = true,
         learningModeEnabled: Bool = false,
         highlightedItemIndex: Int = 0,
         pulseActionButton: Bool = false,
         isCompact: Bool = false,
         checklistLanguage: String = "en",
         hudMode: Bool = false,
         engineHourStart: Double? = nil,
         engineHourEnd: Double? = nil,
         engineHourStartInputFormat: String? = nil,
         engineHourEndInputFormat: String? = nil,
         onEditEngineHourStart: (() -> Void)? = nil,
         onEditEngineHourEnd: (() -> Void)? = nil,
         hiddenItemsRevealed: Binding<Bool> = .constant(false)) {
        self.phase = phase
        self.activeChecklist = activeChecklist
        self.onEngineStart = onEngineStart
        self.onEngineStartUpdate = onEngineStartUpdate
        self.onLineUp = onLineUp
        self.onLineUpUpdate = onLineUpUpdate
        self.onEngineShutdown = onEngineShutdown
        self.onEngineShutdownUpdate = onEngineShutdownUpdate
        self.onGoAround = onGoAround
        self.onTouchAndGo = onTouchAndGo
        self.onFullStop = onFullStop
        self.onLanded = onLanded
        self.onLandedUpdate = onLandedUpdate
        self.onBriefingTap = onBriefingTap
        self.onTapToAdvance = onTapToAdvance
        self.onAllItemsCompleted = onAllItemsCompleted
        self.engineStartTime = engineStartTime
        self.lineUpTime = lineUpTime
        self.landingTime = landingTime
        self.engineShutdownTime = engineShutdownTime
        self.goAroundCount = goAroundCount
        self.touchAndGoCount = touchAndGoCount
        self.fullStopCount = fullStopCount
        self.stepByStepEnabled = stepByStepEnabled
        self.learningModeEnabled = learningModeEnabled
        self.highlightedItemIndex = highlightedItemIndex
        self.pulseActionButton = pulseActionButton
        self.isCompact = isCompact
        self.checklistLanguage = checklistLanguage
        self.hudMode = hudMode
        self.engineHourStart = engineHourStart
        self.engineHourEnd = engineHourEnd
        self.engineHourStartInputFormat = engineHourStartInputFormat
        self.engineHourEndInputFormat = engineHourEndInputFormat
        self.onEditEngineHourStart = onEditEngineHourStart
        self.onEditEngineHourEnd = onEditEngineHourEnd
        self._hiddenItemsRevealed = hiddenItemsRevealed
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Page indicator with optional step-by-step hint
            HStack {
                if !hudMode {
                    Text(L10n.ChecklistAction.page(phase.pageNumber))
                        .font(isCompact ? .system(size: 11) : .captionText)
                        .foregroundColor(theme.textDim)
                }

                Spacer()

                if stepByStepEnabled && !visibleItems.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: isCompact ? 9 : 10))
                        Text(L10n.ChecklistAction.tapToAdvance)
                            .font(.system(size: isCompact ? 10 : 11))
                    }
                    .foregroundColor(theme.textDim)
                }
            }
            .padding(.bottom, isCompact ? 4 : 8)

            // Briefing text if applicable (tappable). Hidden in HUD mode — it's a phase-aware tile there.
            if !hudMode, let briefingText = phase.briefingText, let briefingType = phase.briefingType {
                Button(action: { onBriefingTap?(briefingType) }) {
                    HStack {
                        Text(briefingText)
                            .font(.system(size: isCompact ? 13 : 16, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.warning)
                            .italic()
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(theme.warning)
                    }
                    .padding(.vertical, isCompact ? 8 : 12)
                    .padding(.horizontal, isCompact ? 8 : 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.warning.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.warning.opacity(0.3), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.bottom, isCompact ? 8 : 16)
            }

            // Checklist title + divider. Hidden in HUD mode — the phase name is in the top-bar badge.
            if !hudMode {
                HStack {
                    Text(phase.title)
                        .font(isCompact ? .system(size: 20, weight: .bold) : .checklistTitle)
                        .foregroundColor(theme.action)
                        .textCase(.uppercase)
                        .tracking(isCompact ? 1 : 2)
                    Spacer()
                }

                AviationDivider()
                    .padding(.vertical, isCompact ? 8 : 12)
            }
            
            // Checklist items with optional step-by-step highlighting
            ScrollViewReader { scrollProxy in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                        let isHighlighted = stepByStepEnabled && index == highlightedItemIndex && highlightedItemIndex < visibleItems.count
                        let isCompleted = stepByStepEnabled && index < highlightedItemIndex

                        Group {
                            // The CURRENT item becomes the one-glance "hero" (v4 UI/UX Revamp HUD): same
                            // challenge/response data, rendered large and themed (compact-scaled on
                            // iPhone). Completed/upcoming items stay as normal rows. The global
                            // tap-to-advance hint already lives in the header, so it's suppressed on
                            // the card; the card is presentational so taps still reach the parent
                            // tap-to-advance gesture.
                            if isHighlighted {
                                CockpitHeroChecklistItem(
                                    challenge: item.challenge,
                                    response: item.response,
                                    progressText: "\(index + 1) / \(visibleItems.count)",
                                    showAdvanceHint: false,
                                    isCompact: isCompact
                                )
                                .padding(.vertical, 4)
                            } else {
                                ChecklistItemRow(
                                    item: item,
                                    showSeparator: index < visibleItems.count - 1,
                                    isHighlighted: isHighlighted,
                                    isCompleted: isCompleted,
                                    isCompact: isCompact
                                )
                            }
                        }
                        .id(index)
                    }
                    
                    // Learning mode indicator
                    if hasHiddenItems {
                        learningModeIndicator
                    }
                }
                // Tap gesture handled by parent view for larger tap area
                .onChange(of: highlightedItemIndex) { _, newIndex in
                    // Keep the current item near the TOP so completed items scroll up out of the way and
                    // the upcoming items dominate the view — but not flush-top, so the just-completed
                    // item stays visible for confirmation. (v4 UI/UX Revamp feedback)
                    if newIndex < visibleItems.count {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            scrollProxy.scrollTo(newIndex, anchor: UnitPoint(x: 0.5, y: 0.12))
                        }
                    }
                }
                .onChange(of: phase) { _, _ in
                    // Reset hidden items reveal state when phase changes
                    hiddenItemsRevealed = false
                }
            }
            
            // Completion text
            if !phase.completionText.isEmpty {
                AviationDivider()
                    .padding(.vertical, 12)
                
                HStack {
                    Spacer()
                    Text(phase.completionText)
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.onTarget)
                    Spacer()
                }
            }
            
            // Engine hours display (between completion text and action button)
            if phase.showsEngineStartButton, let hours = engineHourStart {
                Spacer().frame(height: 12)
                engineHoursRow(hours: hours, format: engineHourStartInputFormat) {
                    onEditEngineHourStart?()
                }
            }
            if phase.showsEngineShutdownButton, let hours = engineHourEnd {
                Spacer().frame(height: 12)
                engineHoursRow(hours: hours, format: engineHourEndInputFormat) {
                    onEditEngineHourEnd?()
                }
            }

            // Special buttons (engine-start / ready-for-line-up / shutdown). In HUD mode these move to
            // the bottom bar next to NEXT, so they're hidden here.
            if !hudMode, phase.showsEngineStartButton || phase.showsLineUpButton || phase.showsEngineShutdownButton {
                Spacer().frame(height: 24)

                HStack {
                    Spacer()

                    if phase.showsEngineStartButton {
                        TimestampActionButton(
                            title: L10n.ChecklistAction.engineStart(language: checklistLanguage),
                            icon: "engine.combustion.fill",
                            color: theme.onTarget,
                            timestamp: engineStartTime,
                            timestampLabel: L10n.ChecklistAction.started(language: checklistLanguage),
                            isPulsing: pulseActionButton,
                            onFirstPress: { onEngineStart?() },
                            onUpdateTime: { onEngineStartUpdate?() }
                        )
                        .id("actionButton")
                    }

                    if phase.showsLineUpButton {
                        TimestampActionButton(
                            title: L10n.ChecklistAction.readyForLineUp(language: checklistLanguage),
                            icon: "airplane.departure",
                            color: theme.warning,
                            timestamp: lineUpTime,
                            timestampLabel: L10n.ChecklistAction.lineUp(language: checklistLanguage),
                            timestampSuffix: " (+2 min)",
                            isPulsing: pulseActionButton,
                            onFirstPress: { onLineUp?() },
                            onUpdateTime: { onLineUpUpdate?() }
                        )
                        .id("actionButton")
                    }

                    if phase.showsEngineShutdownButton {
                        TimestampActionButton(
                            title: L10n.ChecklistAction.engineShutdown(language: checklistLanguage),
                            icon: "engine.combustion.fill",
                            color: theme.danger,
                            timestamp: engineShutdownTime,
                            timestampLabel: L10n.ChecklistAction.shutdown(language: checklistLanguage),
                            isPulsing: pulseActionButton,
                            onFirstPress: { onEngineShutdown?() },
                            onUpdateTime: { onEngineShutdownUpdate?() }
                        )
                        .id("actionButton")
                    }

                    Spacer()
                }
            }

            // Go Around / Touch and Go buttons. In HUD mode these live in the event-actions row.
            if !hudMode, phase.showsGoAroundButtons {
                Spacer().frame(height: 24)

                HStack(spacing: 16) {
                    Spacer()

                    // Go Around button
                    CounterActionButton(
                        title: L10n.ChecklistAction.goAround(language: checklistLanguage),
                        icon: "arrow.up.right.circle.fill",
                        color: theme.warning,
                        count: goAroundCount,
                        countLabel: L10n.ChecklistAction.goArounds(language: checklistLanguage),
                        onPress: { onGoAround?() }
                    )
                    .id("goAroundButton")

                    // Touch and Go button
                    CounterActionButton(
                        title: L10n.ChecklistAction.touchAndGo(language: checklistLanguage),
                        icon: "arrow.triangle.2.circlepath",
                        color: .aviationBlue,
                        count: touchAndGoCount,
                        countLabel: L10n.ChecklistAction.touchAndGoes(language: checklistLanguage),
                        onPress: { onTouchAndGo?() }
                    )
                    .id("touchAndGoButton")

                    Spacer()
                }
            }

            // Full Stop Landing button. In HUD mode this lives in the event-actions row.
            if !hudMode, phase.showsLandedButton {
                Spacer().frame(height: 24)

                HStack(spacing: 16) {
                    Spacer()

                    TimestampActionButton(
                        title: L10n.ChecklistAction.landed(language: checklistLanguage),
                        icon: "airplane.arrival",
                        color: .aviationBlue,
                        timestamp: landingTime,
                        timestampLabel: L10n.ChecklistAction.landing(language: checklistLanguage),
                        timestampSuffix: " (-1 min)",
                        isPulsing: pulseActionButton,
                        onFirstPress: { onLanded?() },
                        onUpdateTime: { onLandedUpdate?() }
                    )
                    .id("actionButton")

                    Spacer()
                }
            }
        }
    }
    
    // MARK: - Learning Mode Indicator

    private var learningModeIndicator: some View {
        VStack(spacing: 12) {
            AviationDivider(color: theme.warning.opacity(0.3))
                .padding(.top, 16)

            HStack {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 20))
                    .foregroundColor(theme.warning)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.ChecklistAction.hiddenItemsTitle)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(theme.warning)

                    Text(L10n.ChecklistAction.hiddenItemsCount(hiddenItemCount, hiddenItemCount == 1 ? "" : "s"))
                        .font(.system(size: 12))
                        .foregroundColor(theme.textSecondary)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.warning.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.warning.opacity(0.3), lineWidth: 1)
                        )

                    // Long press progress indicator
                    if revealLongPressProgress > 0 {
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.warning.opacity(0.3))
                                .frame(width: geo.size.width * revealLongPressProgress)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if revealLongPressTimer == nil {
                            startRevealLongPressTimer()
                        }
                    }
                    .onEnded { _ in
                        cancelRevealLongPressTimer()
                    }
            )
        }
    }

    private func startRevealLongPressTimer() {
        revealLongPressProgress = 0
        revealLongPressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            revealLongPressProgress += 0.05 / 0.40 // 0.40 seconds total
            if revealLongPressProgress >= 1.0 {
                timer.invalidate()
                revealLongPressTimer = nil
                revealLongPressProgress = 0
                // Haptic feedback
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                // Reveal hidden items
                withAnimation(.easeInOut(duration: 0.3)) {
                    hiddenItemsRevealed = true
                }
            }
        }
    }

    private func cancelRevealLongPressTimer() {
        revealLongPressTimer?.invalidate()
        revealLongPressTimer = nil
        withAnimation(.easeOut(duration: 0.2)) {
            revealLongPressProgress = 0
        }
    }

    /// Tappable engine hours display row
    private func engineHoursRow(hours: Double, format: String?, onEdit: @escaping () -> Void) -> some View {
        Button(action: onEdit) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .foregroundColor(theme.action)
                    .font(.system(size: 14))
                Text(L10n.FlightDetail.engineHours.uppercased())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.textSecondary)
                Spacer()
                Text(format == "time" ? Flight.formatHoursTime(hours) : Flight.formatHoursDecimal(hours))
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.action)
                Image(systemName: "pencil")
                    .foregroundColor(theme.textDim)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.action.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.action.opacity(0.2), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

/// Single checklist item row
struct ChecklistItemRow: View {
    @Environment(\.cockpitTheme) private var theme
    let item: ChecklistItem
    let showSeparator: Bool
    var isHighlighted: Bool = false
    var isCompleted: Bool = false
    var isCompact: Bool = false

    init(item: ChecklistItem, showSeparator: Bool = true, isHighlighted: Bool = false, isCompleted: Bool = false, isCompact: Bool = false) {
        self.item = item
        self.showSeparator = showSeparator
        self.isHighlighted = isHighlighted
        self.isCompleted = isCompleted
        self.isCompact = isCompact
    }
    
    // Past/future rows are deliberately muted "one-liners" so the current item (rendered as the hero
    // card) is the focus. (v4 UI/UX Revamp)

    private var challengeColor: Color {
        isCompleted ? theme.textDim : theme.textSecondary
    }

    private var responseColor: Color {
        isCompleted ? theme.textDim.opacity(0.7) : theme.textDim
    }

    // Smaller than the old fixed 22 pt rows (still text-style-based for Dynamic Type — challenge/response
    // wrap vertically via .fixedSize, so large sizes grow the row instead of clipping). (UX-14 / v4 UI/UX Revamp)
    private var itemFont: Font {
        .system(isCompact ? .subheadline : .callout, design: .monospaced).weight(.medium)
    }

    private var responseFont: Font {
        .system(isCompact ? .subheadline : .callout, design: .monospaced)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                // Leading status slot — a check for completed items, empty otherwise. The item NUMBER is
                // intentionally dropped: it added clutter to the muted past/future rows. (v4 UI/UX Revamp)
                Group {
                    if isCompleted {
                        Image(systemName: "checkmark")
                            .font(.system(size: isCompact ? 10 : 12, weight: .bold))
                            .foregroundColor(theme.onTarget.opacity(0.7))
                    }
                }
                .frame(width: isCompact ? 18 : 22, alignment: .leading)
                .padding(.trailing, isCompact ? 4 : 6)

                // Challenge text
                Text(item.challenge)
                    .font(itemFont)
                    .foregroundColor(challengeColor)
                    .fixedSize(horizontal: false, vertical: true)

                // Dot leader - fills remaining space, aligned to text baseline
                if !isCompact {
                    DotLeader()
                        .padding(.horizontal, 8)
                        .opacity(isCompleted ? 0.5 : 1.0)
                } else {
                    Spacer(minLength: 8)
                }

                // Response text
                Text(item.response)
                    .font(responseFont)
                    .foregroundColor(responseColor)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, isCompact ? 4 : 6)
            .padding(.horizontal, isHighlighted ? (isCompact ? 4 : 8) : 0)
            .background(
                Group {
                    if isHighlighted {
                        RoundedRectangle(cornerRadius: isCompact ? 6 : 8)
                            .fill(theme.action.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: isCompact ? 6 : 8)
                                    .stroke(theme.action.opacity(0.4), lineWidth: isCompact ? 1.5 : 2)
                            )
                    }
                }
            )
            .animation(.easeInOut(duration: 0.2), value: isHighlighted)

            // Subtle separator line
            if showSeparator {
                Rectangle()
                    .fill(Color.subtleOverlay(0.08))
                    .frame(height: 1)
                    .padding(.leading, isCompact ? 22 : 28)
            }
        }
        // VoiceOver: read the row as ONE element. Left alone, a checklist item is three separate
        // elements — challenge, dot leader, response — so a pilot swipes twice per line and hears
        // the two halves of a challenge/response pair split apart, with the dot leader in between.
        //
        // Completion is spoken, not just drawn. It was conveyed ONLY by a green checkmark glyph and
        // dimmer text, both invisible to VoiceOver and the second of which is colour alone. On a
        // checklist, "have I done this one" is the entire question the control exists to answer.
        // (UX-10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.challenge), \(item.response)")
        .accessibilityValue(isCompleted ? L10n.Accessibility.itemCompleted : "")
        .accessibilityAddTraits(isHighlighted ? [.isStaticText, .isSelected] : .isStaticText)
    }
}

/// Custom dot leader view with consistent spacing - aligned to text baseline
struct DotLeader: View {
    @Environment(\.cockpitTheme) private var theme
    var body: some View {
        GeometryReader { geometry in
            let dotCount = max(3, Int(geometry.size.width / 8))
            HStack(spacing: 0) {
                ForEach(0..<dotCount, id: \.self) { _ in
                    Circle()
                        .fill(theme.textDim.opacity(0.5))
                        .frame(width: 2, height: 2)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
            .padding(.bottom, 6) // Align with text baseline
        }
        .frame(minWidth: 20, maxWidth: .infinity)
        .frame(height: 20)
    }
}

// MARK: - Speed Reference View

struct SpeedReferenceView: View {
    @Environment(\.cockpitTheme) private var theme
    @Environment(\.horizontalSizeClass) var horizontalSizeClass

    /// The owned, resolved checklist for the active aircraft (registration, speeds, limits).
    var activeChecklist: ActiveChecklist = .bundledDefault

    /// Current aircraft registration
    private var currentRegistration: String {
        activeChecklist.registration
    }

    /// Current speeds list
    private var currentSpeeds: [SpeedReference] {
        activeChecklist.speeds
    }

    /// Current crosswind limits
    private var currentCrosswindLimits: (takeoff: String, landing: String) {
        activeChecklist.crosswindLimits
    }

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    /// Get speeds split into two columns
    private var speedColumns: (left: [SpeedReference], right: [SpeedReference]) {
        let speeds = currentSpeeds
        let midpoint = (speeds.count + 1) / 2
        let left = Array(speeds.prefix(midpoint))
        let right = Array(speeds.suffix(from: midpoint))
        return (left, right)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with aircraft info
            HStack {
                Text(L10n.ChecklistAction.airspeedsAFM)
                    .headerStyle()
                Spacer()
                Text(currentRegistration)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.textSecondary)
            }
            .padding(.top, 8)

            AviationDivider()
                .padding(.bottom, 4)

            // Use two columns on iPad, grid layout on iPhone
            if isCompact {
                // Two-column grid layout for iPhone - keeps related info close together
                iPhoneSpeedGrid
            } else {
                // Two columns for iPad
                HStack(alignment: .top, spacing: 24) {
                    // Left column
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(speedColumns.left) { speed in
                            CompactSpeedRow(name: speed.name, description: speed.description, value: speed.value)
                        }
                    }

                    // Right column
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(speedColumns.right) { speed in
                            CompactSpeedRow(name: speed.name, description: speed.description, value: speed.value)
                        }
                    }
                }
            }

            AviationDivider()
                .padding(.top, 6)

            // Crosswind limits
            HStack {
                Text(L10n.ChecklistAction.maxCrosswind)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.textSecondary)
                Spacer()
                let crosswind = currentCrosswindLimits
                Text(L10n.ChecklistAction.crosswindFormat(takeoff: crosswind.takeoff, landing: crosswind.landing))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.warning)
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
    }

    /// iPhone-optimized grid layout with two columns
    /// Each cell shows: Name + Value on one line, description below
    private var iPhoneSpeedGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]

        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(currentSpeeds) { speed in
                iPhoneSpeedCell(speed: speed)
            }
        }
    }

    /// Individual speed cell for iPhone grid
    private func iPhoneSpeedCell(speed: SpeedReference) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // Name (e.g., "Vso")
            Text(speed.name)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(theme.action)

            Spacer(minLength: 4)

            // Value + unit (e.g., "33 kt")
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(speed.value)
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.textPrimary)
                Text("kt")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.textDim)
            }
        }
        .overlay(alignment: .bottomLeading) {
            // Description below the name
            Text(speed.description)
                .font(.system(size: 11))
                .foregroundColor(theme.textDim)
                .offset(y: 14)
        }
        .padding(.bottom, 12)
    }
}

struct CompactSpeedRow: View {
    @Environment(\.cockpitTheme) private var theme
    let name: String
    let description: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(theme.action)
                .frame(width: 55, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(description)
                .font(.system(size: 12))
                .foregroundColor(theme.textDim)
                .frame(minWidth: 75, alignment: .leading)
                .lineLimit(1)

            Spacer()

            HStack(spacing: 2) {
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.textPrimary)
                    .lineLimit(1)

                Text("kt")
                    .font(.system(size: 11))
                    .foregroundColor(theme.textDim)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Briefing Views

/// Departure briefing content, hosted in the HUD reference panel (Pattern B). The section blocks are
/// unchanged; only the NavigationStack/sheet chrome was lifted out so the panel owns it. (v4 UI/UX Revamp)
struct DepartureBriefingContent: View {
    @Environment(\.cockpitTheme) private var theme
    let context: BriefingContext

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
                    // Departure Section
                    BriefingSection(title: L10n.Briefing.departureTitle.uppercased()) {
                        if let airport = context.departureAirport {
                            BriefingItem(label: L10n.Briefing.airport, value: "\(airport.name) (\(airport.ident))")
                            if let elev = airport.elevation {
                                BriefingItem(label: L10n.Briefing.elevation, value: "\(elev) \(L10n.Unit.ft)")
                            }
                        } else {
                            BriefingItem(label: L10n.Briefing.airport, value: L10n.Briefing.notDetected)
                        }
                        if let wind = context.currentWind {
                            BriefingItem(label: L10n.Briefing.wind, value: String(format: "%03.0f\u{00B0} / %.0f \(L10n.Unit.kt)", wind.direction, wind.speed))
                        } else {
                            BriefingItem(label: L10n.Briefing.wind, value: L10n.Briefing.notAvailable)
                            Text(L10n.Briefing.windCheckHint)
                                .font(.system(size: 11))
                                .foregroundColor(theme.textDim)
                                .italic()
                        }
                    }

                    // Runway Section
                    if !context.departureRunways.isEmpty {
                        BriefingSection(title: L10n.Briefing.runway.uppercased()) {
                            if let suggested = context.suggestedDepartureRunway {
                                RunwayRowView(runway: suggested, isSuggested: true)
                            }
                            ForEach(context.departureRunways.filter { $0.id != context.suggestedDepartureRunway?.id }) { runway in
                                RunwayRowView(runway: runway, isSuggested: false)
                            }
                        }
                    }

                    // VFR Reporting Points Section (v4.1.0) — only when the OpenAIP layer is downloaded
                    if !context.departureReportingPoints.isEmpty {
                        BriefingSection(title: L10n.Briefing.reportingPoints.uppercased()) {
                            ForEach(context.departureReportingPoints) { rp in
                                BriefingItem(label: rp.name ?? "—",
                                             value: rp.compulsory ? L10n.Briefing.compulsory : L10n.Briefing.onRequest)
                            }
                        }
                    }

                    // Departure Procedure Section — derived from the active flight plan's first leg when
                    // available; "To be briefed" otherwise. (v4.1.0 — was a static placeholder.)
                    BriefingSection(title: L10n.Briefing.departureProcedure.uppercased()) {
                        if let track = context.departureInitialTrack {
                            let fix = context.departureFirstFix.map { " → \($0)" } ?? ""
                            BriefingItem(label: L10n.Briefing.initialTrack,
                                         value: String(format: "%03.0f°", track) + fix)
                        } else {
                            BriefingItem(label: L10n.Briefing.firstTurn, value: L10n.Briefing.toBeBriefed)
                        }
                        if let alt = context.departureCruiseAltitude {
                            BriefingItem(label: L10n.Briefing.climbTo, value: "\(alt) \(L10n.Unit.ft)")
                        } else {
                            BriefingItem(label: L10n.Briefing.levelOff, value: L10n.Briefing.toBeBriefed)
                        }
                    }

                    // Airspeeds Section - Dynamic from aircraft
                    BriefingSection(title: L10n.Briefing.airspeedsIAS.uppercased()) {
                        SpeedGridView(speeds: context.speeds, phase: .departure)
                    }

                    // Emergency Section - Conditional
                    BriefingSection(title: L10n.Briefing.emergencyBriefing.uppercased(), isWarning: true) {
                        EmergencyBriefingContent(
                            hasParachute: context.hasParachute,
                            fieldElevation: context.departureElevation
                        )
                    }

        }
    }
}

/// Approach briefing content, hosted in the HUD reference panel (Pattern B). The section blocks are
/// unchanged; only the NavigationStack/sheet chrome was lifted out so the panel owns it. (v4 UI/UX Revamp)
struct ApproachBriefingContent: View {
    @Environment(\.cockpitTheme) private var theme
    let context: BriefingContext

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
                    // Approach Section
                    BriefingSection(title: L10n.Briefing.approachTitle.uppercased()) {
                        if let airport = context.destinationAirport {
                            BriefingItem(label: L10n.Briefing.airport, value: "\(airport.name) (\(airport.ident))")
                            if let elev = airport.elevation {
                                BriefingItem(label: L10n.Briefing.elevation, value: "\(elev) \(L10n.Unit.ft)")
                            }
                        } else {
                            BriefingItem(label: L10n.Briefing.airport, value: L10n.Briefing.notDetected)
                        }
                        if let wind = context.currentWind {
                            BriefingItem(label: L10n.Briefing.wind, value: String(format: "%03.0f\u{00B0} / %.0f \(L10n.Unit.kt)", wind.direction, wind.speed))
                        } else {
                            BriefingItem(label: L10n.Briefing.wind, value: L10n.Briefing.notAvailable)
                            Text(L10n.Briefing.windCheckHint)
                                .font(.system(size: 11))
                                .foregroundColor(theme.textDim)
                                .italic()
                        }
                    }

                    // Runway Section
                    if !context.destinationRunways.isEmpty {
                        BriefingSection(title: L10n.Briefing.runway.uppercased()) {
                            if let suggested = context.suggestedArrivalRunway {
                                RunwayRowView(runway: suggested, isSuggested: true)
                            }
                            ForEach(context.destinationRunways.filter { $0.id != context.suggestedArrivalRunway?.id }) { runway in
                                RunwayRowView(runway: runway, isSuggested: false)
                            }
                        }
                    }

                    // VFR Reporting Points Section (v4.1.0) — only when the OpenAIP layer is downloaded
                    if !context.destinationReportingPoints.isEmpty {
                        BriefingSection(title: L10n.Briefing.reportingPoints.uppercased()) {
                            ForEach(context.destinationReportingPoints) { rp in
                                BriefingItem(label: rp.name ?? "—",
                                             value: rp.compulsory ? L10n.Briefing.compulsory : L10n.Briefing.onRequest)
                            }
                        }
                    }

                    // Airspeeds Section - Dynamic from aircraft
                    BriefingSection(title: L10n.Briefing.airspeedsIAS.uppercased()) {
                        SpeedGridView(speeds: context.speeds, phase: .approach)
                    }

                    // Missed Approach Section
                    BriefingSection(title: L10n.Briefing.missedApproach.uppercased(), isWarning: true) {
                        EmergencyItem(text: L10n.Briefing.goAroundProcedure)
                    }

        }
    }
}

// MARK: - Speed Grid View

struct SpeedGridView: View {
    @Environment(\.cockpitTheme) private var theme
    let speeds: AircraftSpeeds
    let phase: BriefingPhase

    private var speedItems: [(label: String, value: String)] {
        switch phase {
        case .departure:
            return [
                (L10n.Briefing.speedRotation, formatSpeed(speeds.vr)),
                (L10n.Briefing.speedBestAngle, formatSpeed(speeds.vx)),
                (L10n.Briefing.speedBestRate, formatSpeed(speeds.vy)),
                (L10n.Briefing.speedBestGlide, formatSpeed(speeds.vbg))
            ]
        case .approach:
            return [
                (L10n.Briefing.speedInitial, formatSpeed(speeds.vapp)),
                (L10n.Briefing.speedFinal, formatSpeed(speeds.vfinal)),
                (L10n.Briefing.speedStall, formatSpeed(speeds.vso)),
                (L10n.Briefing.speedBestGlide, formatSpeed(speeds.vbg))
            ]
        }
    }

    private func formatSpeed(_ speed: Int?) -> String {
        guard let speed = speed else { return L10n.Briefing.speedNA }
        return L10n.Briefing.speedFormat(speed)
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(speedItems, id: \.label) { item in
                HStack {
                    Text(item.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.textSecondary)
                    Spacer()
                    Text(item.value)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(item.value == L10n.Briefing.speedNA ? theme.textDim : theme.onTarget)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Runway Row View

struct RunwayRowView: View {
    @Environment(\.cockpitTheme) private var theme
    let runway: Runway
    var isSuggested: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if isSuggested {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.action)
                }

                Text(runway.identifier)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(isSuggested ? theme.action : theme.textPrimary)

                Text("-")
                    .foregroundColor(theme.textDim)

                Text(runway.descriptionString)
                    .font(.system(size: 12))
                    .foregroundColor(theme.textSecondary)

                Spacer()
            }

            // OpenAIP extras (PCN + declared distances), only when present. Indented under the runway id.
            if let extra = runway.extraInfoLine {
                Text(extra)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.textDim)
                    .padding(.leading, isSuggested ? 20 : 0)
            }
        }
        .padding(.vertical, 4)
        .background(isSuggested ? theme.action.opacity(0.1) : Color.clear)
        .cornerRadius(4)
    }
}

// MARK: - Emergency Briefing Content

struct EmergencyBriefingContent: View {
    let hasParachute: Bool
    let fieldElevation: Int?

    /// Calculate MSL altitude for no-return (1000 ft AAL)
    var noReturnAltitudeMSL: Int? {
        guard let elev = fieldElevation else { return nil }
        return elev + 1000
    }

    /// Calculate MSL altitude for minimum parachute activation (600 ft AAL)
    var minParachuteAltitudeMSL: Int? {
        guard let elev = fieldElevation else { return nil }
        return elev + 600
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Always show these
            EmergencyItem(text: L10n.Briefing.malfunctionBeforeRotation)
            EmergencyItem(text: L10n.Briefing.engineFailureAfterRotation)

            // Show actual altitudes if available
            if let mslAlt = noReturnAltitudeMSL {
                EmergencyItem(text: L10n.Briefing.noReturnBelowWithMSL(mslAlt))
            } else {
                EmergencyItem(text: L10n.Briefing.noReturnBelow)
            }

            // Conditional parachute info
            if hasParachute {
                if let mslAlt = minParachuteAltitudeMSL {
                    EmergencyItem(text: L10n.Briefing.noParachuteBelowWithMSL(mslAlt))
                } else {
                    EmergencyItem(text: L10n.Briefing.noParachuteBelow)
                }
            }
        }
    }
}

struct BriefingSection<Content: View>: View {
    @Environment(\.cockpitTheme) private var theme
    let title: String
    var isWarning: Bool = false
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(isWarning ? theme.danger : theme.action)
                .tracking(1)
            
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isWarning ? theme.danger.opacity(0.3) : theme.action.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

struct BriefingItem: View {
    @Environment(\.cockpitTheme) private var theme
    let label: String
    let value: String
    
    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.textSecondary)
                .frame(width: 100, alignment: .leading)
            
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.textPrimary)
            
            Spacer()
        }
    }
}

struct EmergencyItem: View {
    @Environment(\.cockpitTheme) private var theme
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(theme.danger)
            
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.textPrimary)
        }
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        VStack(spacing: 32) {
            ChecklistView(phase: .beforeEngineStart)
            SpeedReferenceView()
        }
        .padding()
    }
    .background(Color.cockpitBackground)
}
