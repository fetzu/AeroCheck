import SwiftUI
import AVFoundation
import UIKit

// MARK: - Aviation Theme Colors

extension Color {
    // Primary colors - Aviation inspired
    static let aviationBlue = Color(red: 0.1, green: 0.2, blue: 0.4)
    static let aviationDarkBlue = Color(red: 0.05, green: 0.1, blue: 0.25)
    static let aviationGold = Color(red: 0.85, green: 0.65, blue: 0.2)
    static let aviationAmber = Color(red: 1.0, green: 0.75, blue: 0.0)
    
    // Status colors
    static let aviationGreen = Color(red: 0.2, green: 0.7, blue: 0.3)
    static let aviationRed = Color(red: 0.85, green: 0.2, blue: 0.2)
    static let aviationYellow = Color(red: 0.95, green: 0.8, blue: 0.2)
    
    // Background colors
    static let cockpitBackground = Color(red: 0.08, green: 0.08, blue: 0.1)
    static let panelBackground = Color(red: 0.12, green: 0.12, blue: 0.15)
    static let cardBackground = Color(red: 0.15, green: 0.15, blue: 0.18)
    
    // Text colors
    static let primaryText = Color.white
    static let secondaryText = Color(white: 0.7)
    static let dimText = Color(white: 0.5)
}

// MARK: - Typography

extension Font {
    // Custom aviation-style fonts
    static let checklistTitle = Font.system(size: 28, weight: .bold, design: .default)
    static let checklistItem = Font.system(size: 22, weight: .medium, design: .monospaced)
    static let checklistResponse = Font.system(size: 22, weight: .regular, design: .monospaced)
    static let buttonText = Font.system(size: 20, weight: .semibold, design: .default)
    static let headerText = Font.system(size: 18, weight: .bold, design: .default)
    static let bodyText = Font.system(size: 18, weight: .regular, design: .default)
    static let captionText = Font.system(size: 14, weight: .medium, design: .default)
    static let timeDisplay = Font.system(size: 24, weight: .bold, design: .monospaced)
    static let speedValue = Font.system(size: 20, weight: .bold, design: .monospaced)
}

// MARK: - Button Styles

struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = .aviationGold
    var isLarge: Bool = true
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.buttonText)
            .foregroundColor(.black)
            .padding(.horizontal, isLarge ? 32 : 20)
            .padding(.vertical, isLarge ? 18 : 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(color)
                    .shadow(color: color.opacity(0.3), radius: 4, x: 0, y: 2)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var color: Color = .aviationBlue
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.buttonText)
            .foregroundColor(.primaryText)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(color, lineWidth: 2)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(color.opacity(0.2))
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct NavigationButtonStyle: ButtonStyle {
    var direction: NavigationDirection = .next
    var isEnabled: Bool = true
    
    enum NavigationDirection {
        case previous, next
        
        var color: Color {
            switch self {
            case .previous: return .aviationBlue
            case .next: return .aviationGreen
            }
        }
    }
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.buttonText)
            .foregroundColor(isEnabled ? .primaryText : .dimText)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isEnabled ? direction.color : Color.gray.opacity(0.3))
            )
            .scaleEffect(configuration.isPressed && isEnabled ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct ActionButtonStyle: ButtonStyle {
    var color: Color
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(color)
                    .shadow(color: color.opacity(0.4), radius: 6, x: 0, y: 3)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Card Style

struct CardModifier: ViewModifier {
    var backgroundColor: Color = .cardBackground
    var padding: CGFloat = 16
    
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(backgroundColor)
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
            )
    }
}

extension View {
    func cardStyle(backgroundColor: Color = .cardBackground, padding: CGFloat = 16) -> some View {
        modifier(CardModifier(backgroundColor: backgroundColor, padding: padding))
    }
}

// MARK: - Header Style

struct HeaderModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.checklistTitle)
            .foregroundColor(.aviationGold)
            .textCase(.uppercase)
            .tracking(2)
    }
}

extension View {
    func headerStyle() -> some View {
        modifier(HeaderModifier())
    }
}

// MARK: - Divider Style

struct AviationDivider: View {
    var color: Color = .aviationGold.opacity(0.5)
    
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 1)
    }
}

// MARK: - Instrument Failure Flag

/// Avionics-style failure flag overlay (X pattern)
/// Used to indicate GPS signal degradation affecting speed/altitude readings
struct InstrumentFailureFlag: View {
    enum FailureLevel {
        case degraded   // White X, data still visible underneath
        case lost       // Red X, black background, no data shown
    }

    let level: FailureLevel
    let size: CGSize

    /// Stroke width based on failure level
    private var strokeWidth: CGFloat {
        switch level {
        case .degraded:
            // Thinner stroke so data is still readable underneath
            return min(size.width, size.height) * 0.06
        case .lost:
            // Thicker stroke for clear failure indication
            return min(size.width, size.height) * 0.12
        }
    }

    private var strokeColor: Color {
        switch level {
        case .degraded: return .white
        case .lost: return .aviationRed
        }
    }

    var body: some View {
        ZStack {
            // Black background only for lost signal
            if level == .lost {
                Rectangle()
                    .fill(Color.black)
            }

            // X pattern (failure flag)
            Canvas { context, canvasSize in
                let inset: CGFloat = 4
                let topLeft = CGPoint(x: inset, y: inset)
                let topRight = CGPoint(x: canvasSize.width - inset, y: inset)
                let bottomLeft = CGPoint(x: inset, y: canvasSize.height - inset)
                let bottomRight = CGPoint(x: canvasSize.width - inset, y: canvasSize.height - inset)

                var path = Path()
                // Diagonal 1: top-left to bottom-right
                path.move(to: topLeft)
                path.addLine(to: bottomRight)
                // Diagonal 2: top-right to bottom-left
                path.move(to: topRight)
                path.addLine(to: bottomLeft)

                context.stroke(
                    path,
                    with: .color(strokeColor),
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )
            }
        }
        .frame(width: size.width, height: size.height)
        // VoiceOver: the failure X is a Canvas glyph with no inherent semantics. (UX-24)
        // (When overlaid on an instrument that uses `.accessibilityElement(children: .ignore)`,
        // the parent's composed value subsumes this; this covers standalone use.)
        .accessibilityElement()
        .accessibilityLabel("GPS signal")
        .accessibilityValue(level == .lost ? "lost" : "degraded")
    }
}

// MARK: - Status Indicator

struct StatusIndicator: View {
    enum Status {
        case active, inactive, warning, error

        var color: Color {
            switch self {
            case .active: return .aviationGreen
            case .inactive: return .dimText
            case .warning: return .aviationYellow
            case .error: return .aviationRed
            }
        }

        /// Textual status for VoiceOver, so the state is conveyed by words, not colour alone. (UX-10)
        var accessibilityText: String {
            switch self {
            case .active: return "active"
            case .inactive: return "inactive"
            case .warning: return "warning"
            case .error: return "error"
            }
        }
    }

    let status: Status
    let size: CGFloat
    /// Optional description of what this dot indicates (e.g. "GPS", "iCloud sync"). VoiceOver reads
    /// "<label>, <status>".
    let accessibilityLabelText: String?

    init(_ status: Status, size: CGFloat = 12, label: String? = nil) {
        self.status = status
        self.size = size
        self.accessibilityLabelText = label
    }

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: size, height: size)
            .shadow(color: status.color.opacity(0.5), radius: 4)
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabelText ?? "Status")
            .accessibilityValue(status.accessibilityText)
            .accessibilityAddTraits(status == .error || status == .warning ? .updatesFrequently : [])
    }
}

// MARK: - Speed Indicator for Flight

struct SpeedIndicatorView: View {
    let currentSpeed: Double // Ground speed in knots (from GPS, m/s converted)
    let targetSpeed: Int
    let stallSpeed: Int // Stall speed (clean) of the active aircraft
    let gpsSignalStatus: GPSSignalStatus
    var estimatedAirspeed: Double? = nil // Optional estimated airspeed in knots
    var stallAlertEnabled: Bool = false // When true, fire an aural+haptic alert on stall (UX-02)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isNightMode) private var nightMode
    @State private var isFlashing = false

    /// The speed value to display (estimated airspeed if available, otherwise ground speed)
    private var displaySpeed: Double {
        estimatedAirspeed ?? currentSpeed
    }

    /// Whether we're showing estimated airspeed
    private var showingEstimatedAirspeed: Bool {
        estimatedAirspeed != nil
    }

    // Speed state categories
    private var speedState: SpeedState {
        // Don't trigger stall warning based on unreliable GPS data —
        // the InstrumentFailureFlag overlay already communicates GPS issues
        if gpsSignalStatus == .degraded || gpsSignalStatus == .lost {
            let speedInt = Int(displaySpeed)
            if abs(speedInt - targetSpeed) <= 5 { return .onTarget }
            return .offTarget
        }

        let speedInt = Int(displaySpeed)
        // Only annunciate a stall from a reliable airspeed estimate. With only ground speed
        // known, the value can be wrong by the wind component (a tailwind can mask a real
        // stall, a headwind can fake one), so suppress the red stall and treat it as
        // off-target — the GND SPD label keeps the source unambiguous. (UX-02)
        if showingEstimatedAirspeed && speedInt < stallSpeed {
            return .stall
        } else if abs(speedInt - targetSpeed) <= 5 {
            return .onTarget
        } else {
            return .offTarget
        }
    }

    enum SpeedState {
        case onTarget   // Green (solid): within 5 kt of target
        case offTarget  // Orange (solid): above Vs but outside 5 kt range
        case stall      // Flashing red/white: below stall speed
    }

    /// Whether to show failure flag overlay
    private var showFailureFlag: Bool {
        gpsSignalStatus == .degraded || gpsSignalStatus == .lost
    }

    /// Failure level for the flag
    private var failureLevel: InstrumentFailureFlag.FailureLevel {
        gpsSignalStatus == .lost ? .lost : .degraded
    }

    var body: some View {
        VStack(spacing: 4) {
            // Speed label - shows type of speed being displayed
            Text(showingEstimatedAirspeed ? "EST. IAS" : "GND SPD")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(showingEstimatedAirspeed ? .aviationAmber : .secondaryText)

            // Current speed display
            ZStack {
                // Background
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundColor)

                // Speed value (hidden when GPS lost)
                if gpsSignalStatus != .lost {
                    VStack(spacing: 0) {
                        // Static, always-on STALL annunciation: the warning never depends on the
                        // flash animation or colour alone (and is steady under Reduce Motion). (UX-18)
                        if speedState == .stall {
                            Text("STALL")
                                .font(.system(size: 13, weight: .heavy))
                                .foregroundColor(.white)
                        }
                        // "~" marks an estimated (wind-derived) value, not a measured airspeed. (UX-12)
                        Text("\(showingEstimatedAirspeed ? "~" : "")\(Int(displaySpeed))")
                            .font(.system(size: 32, weight: .bold, design: .monospaced))
                            .foregroundColor(textColor)

                        Text(showingEstimatedAirspeed ? "KIAS" : "kt")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(textColor.opacity(0.8))
                    }
                }

                // Failure flag overlay
                if showFailureFlag {
                    InstrumentFailureFlag(level: failureLevel, size: CGSize(width: 100, height: 70))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(width: 100, height: 70)

            // Target speed indicator (always shown)
            // Intentionally untranslated: aviation instrument labels (TGT = Target)
            HStack(spacing: 4) {
                Image(systemName: targetIcon)
                    .font(.system(size: 10))
                Text("TGT: \(targetSpeed)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            .foregroundColor(.secondaryText)
        }
        .onAppear {
            startFlashingIfNeeded()
        }
        .onChange(of: speedState) { _, newState in
            if newState == .stall {
                startFlashing()
                if stallAlertEnabled { StallAlert.shared.trigger() }
            } else {
                stopFlashing()
            }
        }
        // VoiceOver: read the speed as one element with a composed value, so state is conveyed by
        // words (on/off target, below stall speed), never colour alone. (UX-10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showingEstimatedAirspeed ? "Estimated airspeed" : "Ground speed")
        .accessibilityValue(SpeedIndicatorView.accessibilityValue(
            displaySpeed: Int(displaySpeed), targetSpeed: targetSpeed, state: speedState,
            estimated: showingEstimatedAirspeed, gpsLost: gpsSignalStatus == .lost))
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// Composes the VoiceOver value string. Pure + static so the wording is unit-tested — a
    /// mis-stated speed/state on a safety instrument is the main risk of accessibility text. (UX-10)
    static func accessibilityValue(displaySpeed: Int, targetSpeed: Int, state: SpeedState,
                                   estimated: Bool, gpsLost: Bool) -> String {
        if gpsLost { return "GPS signal lost" }
        let source = estimated ? "knots estimated airspeed" : "knots ground speed"
        let prefix = estimated ? "approximately " : ""
        let stateText: String
        switch state {
        case .onTarget: stateText = "on target"
        case .offTarget: stateText = "off target"
        case .stall: stateText = "below stall speed"
        }
        return "\(prefix)\(displaySpeed) \(source), \(stateText). Target \(targetSpeed) knots"
    }

    private var backgroundColor: Color {
        // Solid, high-contrast fills with black text (mirroring the altimeter's solid blue) instead
        // of 20%-opacity same-hue tints — far more legible on a glossy iPad in direct sunlight. (UX-17)
        // Night mode swaps in low-luminance variants of the same state hues. (UX-09)
        switch speedState {
        case .onTarget:
            return nightMode ? .nightOnTarget : .aviationGreen
        case .offTarget:
            return nightMode ? .nightOffTarget : .orange
        case .stall:
            if nightMode { return .nightStall }
            // Under Reduce Motion, a steady solid red (the brightest, most-alarming state) — never
            // the dimmer 0.7 — so a non-flashing stall is still unmistakable. Otherwise flash. (UX-18)
            if reduceMotion { return Color.aviationRed }
            return isFlashing ? Color.aviationRed : Color.aviationRed.opacity(0.7)
        }
    }

    private var textColor: Color {
        if nightMode { return .nightInstrumentText } // dim amber on all night fills (UX-09)
        switch speedState {
        case .onTarget, .offTarget:
            return .black // black on the solid green/orange fill for max sunlight contrast (UX-17)
        case .stall:
            return .white // white on solid red (never red-on-red, which was unreadable when unlit)
        }
    }

    private var targetIcon: String {
        let speedInt = Int(displaySpeed)
        if speedInt < targetSpeed - 5 {
            return "arrow.up"
        } else if speedInt > targetSpeed + 5 {
            return "arrow.down"
        } else {
            return "checkmark"
        }
    }

    private func startFlashingIfNeeded() {
        if speedState == .stall {
            startFlashing()
            if stallAlertEnabled { StallAlert.shared.trigger() }
        }
    }

    private func startFlashing() {
        // Respect Reduce Motion: no repeatForever flashing. The stall background stays a solid,
        // high-contrast red (see backgroundColor) and the static "STALL" text carries the warning. (UX-18)
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true)) {
            isFlashing = true
        }
    }

    private func stopFlashing() {
        withAnimation(.easeInOut(duration: 0.1)) {
            isFlashing = false
        }
    }
}

// MARK: - Stall Aural/Haptic Alert

/// Speaks a "stall" warning (ducking other cockpit audio) plus a warning haptic when the
/// airspeed indicator enters the stall state. Throttled so it doesn't repeat on every
/// recompute/flash. Opt-in via Settings. (UX-02)
final class StallAlert {
    static let shared = StallAlert()
    private let synthesizer = AVSpeechSynthesizer()
    private let haptic = UINotificationFeedbackGenerator()
    private var lastFired: Date?
    private let minInterval: TimeInterval = 4.0

    private init() {}

    func trigger() {
        let now = Date()
        if let last = lastFired, now.timeIntervalSince(last) < minInterval { return }
        lastFired = now

        // Play over other cockpit audio (intercom/music), ducking it briefly.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true, options: [])

        let utterance = AVSpeechUtterance(string: "Stall. Stall.")
        utterance.volume = 1.0
        synthesizer.speak(utterance)

        haptic.notificationOccurred(.warning)
    }
}

// MARK: - Speed Indicator Container (handles GPS speed conversion)

struct FlightSpeedIndicator: View {
    let gpsSpeedMetersPerSecond: Double
    let targetSpeed: Int?
    let stallSpeed: Int
    let gpsSignalStatus: GPSSignalStatus
    var estimatedAirspeed: Double? = nil // Optional estimated airspeed in knots
    var stallAlertEnabled: Bool = false

    // Convert m/s to knots (1 m/s = 1.94384 knots)
    private var speedInKnots: Double {
        gpsSpeedMetersPerSecond * 1.94384
    }

    var body: some View {
        if let target = targetSpeed {
            SpeedIndicatorView(
                currentSpeed: max(0, speedInKnots),
                targetSpeed: target,
                stallSpeed: stallSpeed,
                gpsSignalStatus: gpsSignalStatus,
                estimatedAirspeed: estimatedAirspeed,
                stallAlertEnabled: stallAlertEnabled
            )
        }
    }
}

// MARK: - Altimeter Display

/// Light blue color for altimeter background
extension Color {
    static let altimeterBlue = Color(red: 0.4, green: 0.6, blue: 0.8)
}

// MARK: - Night Mode (UX-09)

/// Low-luminance instrument palette for night flight: no bright blue/white emitters, so the
/// instruments don't wreck the pilot's scotopic dark adaptation. State is still encoded by
/// distinct (dim) hues, preserving the redundant encoding from Tasks 1 and 8.
extension Color {
    static let nightAltimeterBackground = Color(red: 0.16, green: 0.0, blue: 0.0)
    static let nightInstrumentText = Color(red: 0.90, green: 0.50, blue: 0.12) // dim amber
    static let nightOnTarget = Color(red: 0.0, green: 0.28, blue: 0.0)
    static let nightOffTarget = Color(red: 0.34, green: 0.20, blue: 0.0)
    static let nightStall = Color(red: 0.55, green: 0.0, blue: 0.0)
}

private struct NightModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when the user enabled Night mode. Set once near the app root from
    /// `AppState.settings.nightMode`; the flight instruments read it to dim their palette. (UX-09)
    var isNightMode: Bool {
        get { self[NightModeKey.self] }
        set { self[NightModeKey.self] = newValue }
    }
}

struct AltimeterView: View {
    let altitudeFeet: Double
    let gpsSignalStatus: GPSSignalStatus
    @Environment(\.isNightMode) private var nightMode

    /// Altimeter background: the brightest emitter on the panel — dimmed to dark red at night. (UX-09)
    private var altimeterFill: Color { nightMode ? .nightAltimeterBackground : .altimeterBlue }
    /// Altitude text: black on daytime blue, dim amber at night.
    private var altimeterText: Color { nightMode ? .nightInstrumentText : .black }

    /// Dynamic font size based on digit count to ensure full number is always visible
    private var altitudeFontSize: CGFloat {
        let altitude = Int(altitudeFeet)
        let digitCount = String(abs(altitude)).count
        switch digitCount {
        case 1, 2:
            return 36  // 0-99
        case 3:
            return 32  // 100-999
        case 4:
            return 26  // 1000-9999
        default:
            return 20  // 10000-99999+
        }
    }

    /// Whether to show failure flag overlay
    private var showFailureFlag: Bool {
        gpsSignalStatus == .degraded || gpsSignalStatus == .lost
    }

    /// Failure level for the flag
    private var failureLevel: InstrumentFailureFlag.FailureLevel {
        gpsSignalStatus == .lost ? .lost : .degraded
    }

    // Intentionally untranslated: aviation instrument labels (ALT, FT, MSL)
    var body: some View {
        VStack(spacing: 4) {
            // Altitude label
            Text("ALT")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.secondaryText)

            // Altitude display
            ZStack {
                // Background
                RoundedRectangle(cornerRadius: 8)
                    .fill(altimeterFill)

                // Altitude value (hidden when GPS lost)
                if gpsSignalStatus != .lost {
                    VStack(spacing: 2) {
                        Text("\(Int(altitudeFeet))")
                            .font(.system(size: altitudeFontSize, weight: .bold, design: .monospaced))
                            .foregroundColor(altimeterText)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)

                        Text("FT")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(altimeterText.opacity(0.7))
                    }
                    .padding(.horizontal, 4)
                }

                // Failure flag overlay
                if showFailureFlag {
                    InstrumentFailureFlag(level: failureLevel, size: CGSize(width: 100, height: 70))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(width: 100, height: 70)

            // MSL indicator
            Text("MSL")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Altitude")
        .accessibilityValue(AltimeterView.accessibilityValue(
            altitudeFeet: Int(altitudeFeet), gpsLost: gpsSignalStatus == .lost))
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// Composes the VoiceOver value string (pure + static, unit-tested). (UX-10)
    static func accessibilityValue(altitudeFeet: Int, gpsLost: Bool) -> String {
        gpsLost ? "GPS signal lost" : "\(altitudeFeet) feet M S L"
    }
}

// MARK: - Altimeter Container (handles altitude in feet)

struct FlightAltimeter: View {
    let altitudeFeet: Double
    let gpsSignalStatus: GPSSignalStatus

    var body: some View {
        AltimeterView(altitudeFeet: max(0, altitudeFeet), gpsSignalStatus: gpsSignalStatus)
    }
}

// MARK: - Pulse Animation Modifier

/// A pulse animation to draw attention to a button - 2 distinct pulses
struct PulseModifier: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseCount = 0
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .overlay(
                // Inset by negative half of stroke width so inner edge of stroke is flush with button
                RoundedRectangle(cornerRadius: 12)
                    .inset(by: -3)
                    .stroke(Color.aviationGold, lineWidth: isPulsing ? 6 : 0)
                    .opacity(isPulsing ? 0.9 : 0)
                    .animation(.easeInOut(duration: 0.4), value: isPulsing)
            )
            .onChange(of: isActive) { _, newValue in
                if newValue {
                    startPulseSequence()
                } else {
                    pulseCount = 0
                    isPulsing = false
                }
            }
            .onAppear {
                if isActive {
                    startPulseSequence()
                }
            }
    }
    
    private func startPulseSequence() {
        guard !reduceMotion else { return } // no attention-pulse animation under Reduce Motion (UX-18)
        pulseCount = 0
        doPulse()
    }
    
    private func doPulse() {
        guard pulseCount < 2 else {
            isPulsing = false
            return
        }
        
        // Pulse on
        isPulsing = true
        
        // Pulse off after 0.4s
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            isPulsing = false
            pulseCount += 1
            
            // Start next pulse after short gap
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                doPulse()
            }
        }
    }
}

// MARK: - Settings Row

/// A navigation row component for the settings hub, displaying an icon, title, and subtitle
struct SettingsRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            // Icon in a rounded rectangle
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.aviationGold)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.aviationGold.opacity(0.15))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
