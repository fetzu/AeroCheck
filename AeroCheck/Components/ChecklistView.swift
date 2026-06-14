import SwiftUI

// MARK: - Action Button with Long Press Support

/// A button that can only be pressed once, but allows long-press (3+ seconds) to update the time
struct TimestampActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let timestamp: String?
    let timestampLabel: String
    var timestampSuffix: String = ""
    let isPulsing: Bool
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
        VStack(spacing: 8) {
            // The button
            HStack {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 18, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(hasBeenPressed ? color.opacity(0.5) : color)
                        .shadow(color: color.opacity(hasBeenPressed ? 0.2 : 0.4), radius: 6, x: 0, y: 3)
                    
                    // Long press progress indicator
                    if longPressProgress > 0 && hasBeenPressed {
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 10)
                                .fill(color.opacity(0.8))
                                .frame(width: geo.size.width * longPressProgress)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
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
            
            // Timestamp display
            if let time = timestamp {
                Text("\(timestampLabel): \(time)\(timestampSuffix)")
                    .font(.captionText)
                    .foregroundColor(color)
            }
            
            // Long press hint when already pressed
            if hasBeenPressed {
                Text(L10n.ChecklistAction.holdToUpdate)
                    .font(.system(size: 10))
                    .foregroundColor(.dimText)
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
    /// in the HUD bottom bar + event row). (Phase 3.1)
    var hudMode: Bool = false

    // Engine hours display
    var engineHourStart: Double? = nil
    var engineHourEnd: Double? = nil
    var engineHourStartInputFormat: String? = nil
    var engineHourEndInputFormat: String? = nil
    var onEditEngineHourStart: (() -> Void)? = nil
    var onEditEngineHourEnd: (() -> Void)? = nil

    // State for temporarily revealing hidden items
    @State private var hiddenItemsRevealed: Bool = false
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
         onEditEngineHourEnd: (() -> Void)? = nil) {
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
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Page indicator with optional step-by-step hint
            HStack {
                if !hudMode {
                    Text(L10n.ChecklistAction.page(phase.pageNumber))
                        .font(isCompact ? .system(size: 11) : .captionText)
                        .foregroundColor(.dimText)
                }

                Spacer()

                if stepByStepEnabled && !visibleItems.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: isCompact ? 9 : 10))
                        Text(L10n.ChecklistAction.tapToAdvance)
                            .font(.system(size: isCompact ? 10 : 11))
                    }
                    .foregroundColor(.dimText)
                }
            }
            .padding(.bottom, isCompact ? 4 : 8)

            // Briefing text if applicable (tappable). Hidden in HUD mode — it's a phase-aware tile there.
            if !hudMode, let briefingText = phase.briefingText, let briefingType = phase.briefingType {
                Button(action: { onBriefingTap?(briefingType) }) {
                    HStack {
                        Text(briefingText)
                            .font(.system(size: isCompact ? 13 : 16, weight: .medium, design: .monospaced))
                            .foregroundColor(.aviationAmber)
                            .italic()
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.aviationAmber)
                    }
                    .padding(.vertical, isCompact ? 8 : 12)
                    .padding(.horizontal, isCompact ? 8 : 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.aviationAmber.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.aviationAmber.opacity(0.3), lineWidth: 1)
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
                        .foregroundColor(.aviationGold)
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
                            // The CURRENT item becomes the one-glance "hero" (Phase 3.1 HUD): same
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
                    // Auto-scroll to highlighted item
                    if newIndex < visibleItems.count {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            scrollProxy.scrollTo(newIndex, anchor: .center)
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
                        .foregroundColor(.aviationGreen)
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
                            color: .aviationGreen,
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
                            color: .aviationAmber,
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
                            color: .aviationRed,
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
                        color: .aviationAmber,
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
            AviationDivider(color: .aviationAmber.opacity(0.3))
                .padding(.top, 16)

            HStack {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.aviationAmber)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.ChecklistAction.hiddenItemsTitle)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.aviationAmber)

                    Text(L10n.ChecklistAction.hiddenItemsCount(hiddenItemCount, hiddenItemCount == 1 ? "" : "s"))
                        .font(.system(size: 12))
                        .foregroundColor(.secondaryText)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.aviationAmber.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.aviationAmber.opacity(0.3), lineWidth: 1)
                        )

                    // Long press progress indicator
                    if revealLongPressProgress > 0 {
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.aviationAmber.opacity(0.3))
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
                    .foregroundColor(.aviationGold)
                    .font(.system(size: 14))
                Text(L10n.FlightDetail.engineHours.uppercased())
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondaryText)
                Spacer()
                Text(format == "time" ? Flight.formatHoursTime(hours) : Flight.formatHoursDecimal(hours))
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundColor(.aviationGold)
                Image(systemName: "pencil")
                    .foregroundColor(.dimText)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.aviationGold.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.aviationGold.opacity(0.2), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

/// Single checklist item row
struct ChecklistItemRow: View {
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
    // card) is the focus — the numbering is subtle, not the prominent gold of the old design. (Phase 3.1)
    private var numberColor: Color {
        .dimText
    }

    private var challengeColor: Color {
        isCompleted ? .dimText : .secondaryText
    }

    private var responseColor: Color {
        isCompleted ? .dimText.opacity(0.7) : .dimText
    }

    // Smaller than the old fixed 22 pt rows (still text-style-based for Dynamic Type — challenge/response
    // wrap vertically via .fixedSize, so large sizes grow the row instead of clipping). (UX-14 / Phase 3.1)
    private var itemFont: Font {
        .system(isCompact ? .subheadline : .callout, design: .monospaced).weight(.medium)
    }

    private var responseFont: Font {
        .system(isCompact ? .subheadline : .callout, design: .monospaced)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                // Item number - fixed width to prevent wrapping
                if let number = item.number {
                    HStack(spacing: isCompact ? 2 : 4) {
                        if isCompleted {
                            Image(systemName: "checkmark")
                                .font(.system(size: isCompact ? 11 : 14, weight: .bold))
                                .foregroundColor(.aviationGreen.opacity(0.6))
                        }
                        Text("\(number).")
                            .font(itemFont)
                            .foregroundColor(numberColor)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(minWidth: isCompleted ? (isCompact ? 44 : 60) : (isCompact ? 28 : 40), alignment: .trailing)
                    .padding(.trailing, isCompact ? 6 : 10)
                } else {
                    Spacer().frame(width: isCompact ? 34 : 50)
                }

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
                            .fill(Color.aviationGold.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: isCompact ? 6 : 8)
                                    .stroke(Color.aviationGold.opacity(0.4), lineWidth: isCompact ? 1.5 : 2)
                            )
                    }
                }
            )
            .animation(.easeInOut(duration: 0.2), value: isHighlighted)

            // Subtle separator line
            if showSeparator {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
                    .padding(.leading, isCompact ? 34 : 50)
            }
        }
    }
}

/// Custom dot leader view with consistent spacing - aligned to text baseline
struct DotLeader: View {
    var body: some View {
        GeometryReader { geometry in
            let dotCount = max(3, Int(geometry.size.width / 8))
            HStack(spacing: 0) {
                ForEach(0..<dotCount, id: \.self) { _ in
                    Circle()
                        .fill(Color.dimText.opacity(0.5))
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
                    .foregroundColor(.secondaryText)
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
                    .foregroundColor(.secondaryText)
                Spacer()
                let crosswind = currentCrosswindLimits
                Text(L10n.ChecklistAction.crosswindFormat(takeoff: crosswind.takeoff, landing: crosswind.landing))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.aviationAmber)
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
                .foregroundColor(.aviationGold)

            Spacer(minLength: 4)

            // Value + unit (e.g., "33 kt")
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(speed.value)
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundColor(.primaryText)
                Text("kt")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.dimText)
            }
        }
        .overlay(alignment: .bottomLeading) {
            // Description below the name
            Text(speed.description)
                .font(.system(size: 11))
                .foregroundColor(.dimText)
                .offset(y: 14)
        }
        .padding(.bottom, 12)
    }
}

struct CompactSpeedRow: View {
    let name: String
    let description: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(.aviationGold)
                .frame(width: 55, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(description)
                .font(.system(size: 12))
                .foregroundColor(.dimText)
                .frame(minWidth: 75, alignment: .leading)
                .lineLimit(1)

            Spacer()

            HStack(spacing: 2) {
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(.primaryText)
                    .lineLimit(1)

                Text("kt")
                    .font(.system(size: 11))
                    .foregroundColor(.dimText)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Briefing Views

struct DepartureBriefingView: View {
    let context: BriefingContext
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
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
                                .foregroundColor(.dimText)
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

                    // Departure Procedure Section
                    BriefingSection(title: L10n.Briefing.departureProcedure.uppercased()) {
                        BriefingItem(label: L10n.Briefing.firstTurn, value: L10n.Briefing.toBeBriefed)
                        BriefingItem(label: L10n.Briefing.levelOff, value: L10n.Briefing.toBeBriefed)
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

                    Spacer()
                }
                .padding(24)
            }
            .background(Color.cockpitBackground)
            .navigationTitle(L10n.Briefing.departureTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Briefing.close) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct ApproachBriefingView: View {
    let context: BriefingContext
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
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
                                .foregroundColor(.dimText)
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

                    // Airspeeds Section - Dynamic from aircraft
                    BriefingSection(title: L10n.Briefing.airspeedsIAS.uppercased()) {
                        SpeedGridView(speeds: context.speeds, phase: .approach)
                    }

                    // Missed Approach Section
                    BriefingSection(title: L10n.Briefing.missedApproach.uppercased(), isWarning: true) {
                        EmergencyItem(text: L10n.Briefing.goAroundProcedure)
                    }

                    Spacer()
                }
                .padding(24)
            }
            .background(Color.cockpitBackground)
            .navigationTitle(L10n.Briefing.approachTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Briefing.close) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Speed Grid View

struct SpeedGridView: View {
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
                        .foregroundColor(.secondaryText)
                    Spacer()
                    Text(item.value)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(item.value == L10n.Briefing.speedNA ? .dimText : .aviationGreen)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Runway Row View

struct RunwayRowView: View {
    let runway: Runway
    var isSuggested: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            if isSuggested {
                Image(systemName: "star.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.aviationGold)
            }

            Text(runway.identifier)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(isSuggested ? .aviationGold : .primaryText)

            Text("-")
                .foregroundColor(.dimText)

            Text(runway.descriptionString)
                .font(.system(size: 12))
                .foregroundColor(.secondaryText)

            Spacer()
        }
        .padding(.vertical, 4)
        .background(isSuggested ? Color.aviationGold.opacity(0.1) : Color.clear)
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
    let title: String
    var isWarning: Bool = false
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(isWarning ? .aviationRed : .aviationGold)
                .tracking(1)
            
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isWarning ? Color.aviationRed.opacity(0.3) : Color.aviationGold.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

struct BriefingItem: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondaryText)
                .frame(width: 100, alignment: .leading)
            
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundColor(.primaryText)
            
            Spacer()
        }
    }
}

struct EmergencyItem: View {
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(.aviationRed)
            
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primaryText)
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
