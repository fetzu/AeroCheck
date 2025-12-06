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
                Text("Hold 3s to update")
                    .font(.system(size: 10))
                    .foregroundColor(.dimText)
            }
        }
        .alert("Update Time?", isPresented: $showUpdateConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Update") {
                onUpdateTime()
            }
        } message: {
            Text("Do you want to update the \(timestampLabel.lowercased()) time to now?")
        }
    }
    
    private func startLongPressTimer() {
        longPressProgress = 0
        longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            longPressProgress += 0.05 / 3.0 // 3 seconds total
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
    var onEngineStart: (() -> Void)?
    var onEngineStartUpdate: (() -> Void)?
    var onLineUp: (() -> Void)?
    var onLineUpUpdate: (() -> Void)?
    var onEngineShutdown: (() -> Void)?
    var onEngineShutdownUpdate: (() -> Void)?
    var onGoAround: (() -> Void)?
    var onTouchAndGo: (() -> Void)?
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

    // Settings
    var stepByStepEnabled: Bool = true
    var learningModeEnabled: Bool = false
    var highlightedItemIndex: Int = 0
    var pulseActionButton: Bool = false

    // State for temporarily revealing hidden items
    @State private var hiddenItemsRevealed: Bool = false
    @State private var revealLongPressProgress: CGFloat = 0
    @State private var revealLongPressTimer: Timer?
    
    // Computed properties
    private var allItems: [ChecklistItem] {
        ChecklistData.items(for: phase)
    }

    private var effectiveLearningMode: Bool {
        learningModeEnabled || hiddenItemsRevealed
    }

    private var visibleItems: [ChecklistItem] {
        ChecklistData.visibleItems(for: phase, learningMode: effectiveLearningMode)
    }

    /// Whether there are items that could be hidden (memorizable items exist and learning mode is off)
    private var hasHiddenItems: Bool {
        !learningModeEnabled && !hiddenItemsRevealed && ChecklistData.hasHiddenItems(for: phase, learningMode: false)
    }

    private var hiddenItemCount: Int {
        // Count of items hidden when not in learning mode
        ChecklistData.items(for: phase).count - ChecklistData.visibleItems(for: phase, learningMode: false).count
    }
    
    init(phase: ChecklistPhase,
         onEngineStart: (() -> Void)? = nil,
         onEngineStartUpdate: (() -> Void)? = nil,
         onLineUp: (() -> Void)? = nil,
         onLineUpUpdate: (() -> Void)? = nil,
         onEngineShutdown: (() -> Void)? = nil,
         onEngineShutdownUpdate: (() -> Void)? = nil,
         onGoAround: (() -> Void)? = nil,
         onTouchAndGo: (() -> Void)? = nil,
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
         stepByStepEnabled: Bool = true,
         learningModeEnabled: Bool = false,
         highlightedItemIndex: Int = 0,
         pulseActionButton: Bool = false) {
        self.phase = phase
        self.onEngineStart = onEngineStart
        self.onEngineStartUpdate = onEngineStartUpdate
        self.onLineUp = onLineUp
        self.onLineUpUpdate = onLineUpUpdate
        self.onEngineShutdown = onEngineShutdown
        self.onEngineShutdownUpdate = onEngineShutdownUpdate
        self.onGoAround = onGoAround
        self.onTouchAndGo = onTouchAndGo
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
        self.stepByStepEnabled = stepByStepEnabled
        self.learningModeEnabled = learningModeEnabled
        self.highlightedItemIndex = highlightedItemIndex
        self.pulseActionButton = pulseActionButton
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Page indicator with optional step-by-step hint
            HStack {
                Text("PAGE \(phase.pageNumber)")
                    .font(.captionText)
                    .foregroundColor(.dimText)
                
                Spacer()
                
                if stepByStepEnabled && !visibleItems.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 10))
                        Text("Tap to advance")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.dimText)
                }
            }
            .padding(.bottom, 8)
            
            // Briefing text if applicable (tappable)
            if let briefingText = phase.briefingText, let briefingType = phase.briefingType {
                Button(action: { onBriefingTap?(briefingType) }) {
                    HStack {
                        Text(briefingText)
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                            .foregroundColor(.aviationAmber)
                            .italic()
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.aviationAmber)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
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
                .padding(.bottom, 16)
            }
            
            // Checklist title
            HStack {
                Text(phase.title)
                    .headerStyle()
                Spacer()
            }
            
            AviationDivider()
                .padding(.vertical, 12)
            
            // Checklist items with optional step-by-step highlighting
            ScrollViewReader { scrollProxy in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                        ChecklistItemRow(
                            item: item,
                            showSeparator: index < visibleItems.count - 1,
                            isHighlighted: stepByStepEnabled && index == highlightedItemIndex && highlightedItemIndex < visibleItems.count,
                            isCompleted: stepByStepEnabled && index < highlightedItemIndex
                        )
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
            
            // Special buttons
            if phase.showsEngineStartButton || phase.showsLineUpButton || phase.showsEngineShutdownButton {
                Spacer().frame(height: 24)

                HStack {
                    Spacer()

                    if phase.showsEngineStartButton {
                        TimestampActionButton(
                            title: "ENGINE START",
                            icon: "engine.combustion.fill",
                            color: .aviationGreen,
                            timestamp: engineStartTime,
                            timestampLabel: "Started",
                            isPulsing: pulseActionButton,
                            onFirstPress: { onEngineStart?() },
                            onUpdateTime: { onEngineStartUpdate?() }
                        )
                        .id("actionButton")
                    }

                    if phase.showsLineUpButton {
                        TimestampActionButton(
                            title: "READY FOR LINE UP",
                            icon: "airplane.departure",
                            color: .aviationAmber,
                            timestamp: lineUpTime,
                            timestampLabel: "Line Up",
                            timestampSuffix: " (+2 min)",
                            isPulsing: pulseActionButton,
                            onFirstPress: { onLineUp?() },
                            onUpdateTime: { onLineUpUpdate?() }
                        )
                        .id("actionButton")
                    }

                    if phase.showsEngineShutdownButton {
                        TimestampActionButton(
                            title: "ENGINE SHUTDOWN",
                            icon: "engine.combustion.fill",
                            color: .aviationRed,
                            timestamp: engineShutdownTime,
                            timestampLabel: "Shutdown",
                            isPulsing: pulseActionButton,
                            onFirstPress: { onEngineShutdown?() },
                            onUpdateTime: { onEngineShutdownUpdate?() }
                        )
                        .id("actionButton")
                    }

                    Spacer()
                }
            }

            // Go Around / Touch and Go buttons
            if phase.showsGoAroundButtons {
                Spacer().frame(height: 24)

                HStack(spacing: 16) {
                    Spacer()

                    // Go Around button
                    CounterActionButton(
                        title: "GO AROUND",
                        icon: "arrow.up.right.circle.fill",
                        color: .aviationAmber,
                        count: goAroundCount,
                        countLabel: "Go Arounds",
                        onPress: { onGoAround?() }
                    )
                    .id("goAroundButton")

                    // Touch and Go button
                    CounterActionButton(
                        title: "TOUCH-AND-GO",
                        icon: "arrow.triangle.2.circlepath",
                        color: .aviationBlue,
                        count: touchAndGoCount,
                        countLabel: "Touch-and-goes",
                        onPress: { onTouchAndGo?() }
                    )
                    .id("touchAndGoButton")

                    Spacer()
                }
            }

            // Landed button
            if phase.showsLandedButton {
                Spacer().frame(height: 24)

                HStack {
                    Spacer()

                    TimestampActionButton(
                        title: "LANDED",
                        icon: "airplane.arrival",
                        color: .aviationBlue,
                        timestamp: landingTime,
                        timestampLabel: "Landing",
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
                    Text("HIDDEN CHECKLIST ITEMS")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.aviationAmber)

                    Text("\(hiddenItemCount) item\(hiddenItemCount == 1 ? "" : "s") hidden — hold to reveal")
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
}

/// Single checklist item row
struct ChecklistItemRow: View {
    let item: ChecklistItem
    let showSeparator: Bool
    var isHighlighted: Bool = false
    var isCompleted: Bool = false
    
    init(item: ChecklistItem, showSeparator: Bool = true, isHighlighted: Bool = false, isCompleted: Bool = false) {
        self.item = item
        self.showSeparator = showSeparator
        self.isHighlighted = isHighlighted
        self.isCompleted = isCompleted
    }
    
    private var numberColor: Color {
        if isCompleted {
            return .aviationGreen.opacity(0.6)
        } else if isHighlighted {
            return .aviationGold
        }
        return .aviationGold
    }
    
    private var challengeColor: Color {
        if isCompleted {
            return .primaryText.opacity(0.5)
        }
        return .primaryText
    }
    
    private var responseColor: Color {
        if isCompleted {
            return .secondaryText.opacity(0.5)
        }
        return .secondaryText
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                // Item number - fixed width to prevent wrapping
                if let number = item.number {
                    HStack(spacing: 4) {
                        if isCompleted {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.aviationGreen.opacity(0.6))
                        }
                        Text("\(number).")
                            .font(.checklistItem)
                            .foregroundColor(numberColor)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(minWidth: isCompleted ? 60 : 40, alignment: .trailing)
                    .padding(.trailing, 10)
                } else {
                    Spacer().frame(width: 50)
                }
                
                // Challenge text
                Text(item.challenge)
                    .font(.checklistItem)
                    .foregroundColor(challengeColor)
                    .fixedSize(horizontal: false, vertical: true)
                
                // Dot leader - fills remaining space, aligned to text baseline
                DotLeader()
                    .padding(.horizontal, 8)
                    .opacity(isCompleted ? 0.5 : 1.0)
                
                // Response text
                Text(item.response)
                    .font(.checklistResponse)
                    .foregroundColor(responseColor)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, isHighlighted ? 8 : 0)
            .background(
                Group {
                    if isHighlighted {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.aviationGold.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.aviationGold.opacity(0.4), lineWidth: 2)
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
                    .padding(.leading, 50)
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
    /// Current aircraft type from ChecklistData
    private var aircraft: AircraftType {
        ChecklistData.currentAircraft
    }

    /// Get speeds split into two columns
    private var speedColumns: (left: [SpeedReference], right: [SpeedReference]) {
        let speeds = aircraft.speeds
        let midpoint = (speeds.count + 1) / 2
        let left = Array(speeds.prefix(midpoint))
        let right = Array(speeds.suffix(from: midpoint))
        return (left, right)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with aircraft info
            HStack {
                Text("SPEEDS (according to AFM)")
                    .headerStyle()
                Spacer()
                Text(aircraft.registration)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondaryText)
            }
            .padding(.top, 8)

            AviationDivider()
                .padding(.bottom, 4)

            // Use two columns for compact display
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

            AviationDivider()
                .padding(.top, 6)

            // Crosswind limits
            HStack {
                Text("Max crosswind")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondaryText)
                Spacer()
                let crosswind = aircraft.crosswindLimits
                Text("TO: \(crosswind.takeoff)  /  LDG: \(crosswind.landing)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.aviationAmber)
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
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
                .frame(width: 75, alignment: .leading)
                .lineLimit(1)
            
            Spacer()
            
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(.primaryText)
                .lineLimit(1)
            
            Text("kt")
                .font(.system(size: 11))
                .foregroundColor(.dimText)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Briefing Views

struct DepartureBriefingView: View {
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Runway and wind
                    BriefingSection(title: "DEPARTURE") {
                        BriefingItem(label: "Runway", value: "LSZQ 25")
                        BriefingItem(label: "Wind", value: "calm / crosswind / headwind / tailwind...")
                        BriefingItem(label: "First turn", value: "RIGHT after departure")
                        BriefingItem(label: "Level off", value: "2900 ft")
                        BriefingItem(label: "Outbound", value: "for circuits")
                    }
                    
                    // Speeds
                    BriefingSection(title: "SPEEDS") {
                        BriefingItem(label: "Rotation", value: "40 KIAS")
                        BriefingItem(label: "Vx", value: "55 KIAS")
                        BriefingItem(label: "Vy", value: "70 KIAS")
                        BriefingItem(label: "Vbest glide", value: "70 KIAS")
                    }
                    
                    // Emergency
                    BriefingSection(title: "EMERGENCY BRIEFING", isWarning: true) {
                        VStack(alignment: .leading, spacing: 12) {
                            EmergencyItem(text: "Any malfunction before rotation: IDLE - BRAKE - STOP")
                            EmergencyItem(text: "Engine failure after rotation: NOSE DOWN, LAND STRAIGHT AHEAD")
                            EmergencyItem(text: "No return below 1000 ft AAL")
                            EmergencyItem(text: "No parachute activation below 600 ft AAL")
                        }
                    }
                    
                    Spacer()
                }
                .padding(24)
            }
            .background(Color.cockpitBackground)
            .navigationTitle("Departure Briefing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct ApproachBriefingView: View {
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Approach info
                    BriefingSection(title: "APPROACH") {
                        BriefingItem(label: "Runway", value: "LSZQ 25")
                        BriefingItem(label: "Routing", value: "Proceed via sector West/East/North @ 3500 ft")
                        BriefingItem(label: "Downwind", value: "Join downwind runway 07/25 @ 2900 ft")
                    }
                    
                    // Speeds
                    BriefingSection(title: "SPEEDS") {
                        BriefingItem(label: "Initial", value: "70 KIAS - FLAPS 1")
                        BriefingItem(label: "Intermediate", value: "65 KIAS - FLAPS 2")
                        BriefingItem(label: "Final", value: "60 KIAS - FLAPS 3")
                    }
                    
                    // Missed approach
                    BriefingSection(title: "MISSED APPROACH", isWarning: true) {
                        VStack(alignment: .leading, spacing: 12) {
                            EmergencyItem(text: "GO AROUND, join Downwind @ 2900 ft")
                        }
                    }
                    
                    // Alternate
                    BriefingSection(title: "ALTERNATE") {
                        BriefingItem(label: "Aerodrome", value: "(none)")
                    }
                    
                    Spacer()
                }
                .padding(24)
            }
            .background(Color.cockpitBackground)
            .navigationTitle("Approach Briefing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
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
