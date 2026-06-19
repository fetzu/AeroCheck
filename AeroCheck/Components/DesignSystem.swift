import SwiftUI
import AVFoundation
import UIKit

// MARK: - Aviation Theme Colors — moved to Shared/DesignTokens.swift (shared with the Watch app + widget).

// MARK: - Typography

extension Font {
    // Custom aviation-style fonts
    static let checklistTitle = Font.system(size: 28, weight: .bold, design: .default)
    static let buttonText = Font.system(size: 20, weight: .semibold, design: .default)
    static let headerText = Font.system(size: 18, weight: .bold, design: .default)
    static let bodyText = Font.system(size: 18, weight: .regular, design: .default)
    static let captionText = Font.system(size: 14, weight: .medium, design: .default)
}

// MARK: - Button Styles

struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = .aviationGold
    var isLarge: Bool = true
    // Read the system enabled state so `.disabled()` automatically dims the button. (UX-23)
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.buttonText)
            .foregroundColor(.onAccent)
            .padding(.horizontal, isLarge ? 32 : 20)
            .padding(.vertical, isLarge ? 18 : 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(color)
                    .shadow(color: color.opacity(0.3), radius: 4, x: 0, y: 2)
            )
            .opacity(isEnabled ? 1.0 : 0.45)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var color: Color = .aviationBlue
    @Environment(\.isEnabled) private var isEnabled

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
            .opacity(isEnabled ? 1.0 : 0.45) // dim when `.disabled()` (UX-23)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.96 : 1.0)
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
            // Defense-in-depth: a button that *looks* disabled must not stay tappable even if a
            // call site forgets the matching `.disabled()`. (UX-23)
            .allowsHitTesting(isEnabled)
    }
}

struct ActionButtonStyle: ButtonStyle {
    var color: Color
    @Environment(\.isEnabled) private var isEnabled

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
            .opacity(isEnabled ? 1.0 : 0.45) // dim when `.disabled()` (UX-23)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.95 : 1.0)
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

        /// A glyph that distinguishes the state without relying on colour — overlaid when the user has
        /// "Differentiate Without Color" enabled (WCAG 1.4.1). (v4.1.0 Data Freshness)
        var differentiatingSymbol: String? {
            switch self {
            case .active: return "checkmark"
            case .warning: return "exclamationmark"
            case .error: return "xmark"
            case .inactive: return nil
            }
        }
    }

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
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
            .overlay {
                // Non-colour channel for "Differentiate Without Color" users (WCAG 1.4.1).
                if differentiateWithoutColor, let symbol = status.differentiatingSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.62, weight: .black))
                        .foregroundColor(.black.opacity(0.85))
                }
            }
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

    // Speed state categories — delegates to the shared pure function so iPad and iPhone
    // annunciate identically. (UX-02)
    private var speedState: SpeedState {
        SpeedIndicatorView.annunciationState(
            displaySpeed: displaySpeed, targetSpeed: targetSpeed, stallSpeed: stallSpeed,
            showingEstimatedAirspeed: showingEstimatedAirspeed, gpsSignalStatus: gpsSignalStatus)
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

            // Color-blind-safe proximity bar: WIDTH shows how close to target, COLOR the state — a
            // glanceable analog complement to the numeric readout and TGT arrow. Hidden when GPS is
            // lost (no reliable speed to plot), matching the readout. (v4 UI/UX Revamp)
            if gpsSignalStatus != .lost {
                InstrumentTargetBar(
                    fraction: SpeedIndicatorView.targetBarFraction(displaySpeed: displaySpeed, targetSpeed: targetSpeed),
                    state: SpeedIndicatorView.barState(for: speedState)
                )
                .frame(width: 100)
                .accessibilityHidden(true) // the composed speed value already states the target state in words
            }
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

    /// Pure, unit-testable speed-state computation shared by the iPad `SpeedIndicatorView` and the
    /// iPhone `CompactSpeedView`, so both annunciate a stall identically. A `.stall` is annunciated
    /// ONLY from a reliable airspeed estimate (`showingEstimatedAirspeed`): with only GPS ground
    /// speed the value can be wrong by the wind component — a tailwind can mask a real stall and a
    /// headwind can fake one — so it is suppressed to `.offTarget`. Unreliable GPS likewise never
    /// annunciates a stall (the failure flag already communicates the GPS issue). (UX-02)
    static func annunciationState(displaySpeed: Double, targetSpeed: Int, stallSpeed: Int,
                                  showingEstimatedAirspeed: Bool,
                                  gpsSignalStatus: GPSSignalStatus) -> SpeedState {
        let speedInt = displaySpeed.isFinite ? Int(displaySpeed) : 0
        if gpsSignalStatus == .degraded || gpsSignalStatus == .lost {
            return abs(speedInt - targetSpeed) <= 5 ? .onTarget : .offTarget
        }
        if showingEstimatedAirspeed && speedInt < stallSpeed {
            return .stall
        } else if abs(speedInt - targetSpeed) <= 5 {
            return .onTarget
        } else {
            return .offTarget
        }
    }

    /// Maps the annunciated speed state to the color-blind-safe instrument-bar state. Pure + testable
    /// so the bar can never disagree with the readout's annunciation. (v4 UI/UX Revamp)
    static func barState(for state: SpeedState) -> InstrumentTargetState {
        switch state {
        case .onTarget: return .onTarget
        case .offTarget: return .caution
        case .stall: return .stall
        }
    }

    /// 0...1 proximity-to-target fill for the on-target bar: full at the target speed, shrinking
    /// linearly with deviation (30 kt full-scale) and floored so the bar never vanishes (a thin nub
    /// still reads "far off" via its color). Pure + testable. (v4 UI/UX Revamp)
    static func targetBarFraction(displaySpeed: Double, targetSpeed: Int) -> Double {
        let deviation = abs(displaySpeed - Double(targetSpeed))
        return max(0.12, min(1.0, 1.0 - deviation / 30.0))
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
        let speedInt = displaySpeed.isFinite ? Int(displaySpeed) : 0
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

// MARK: - Floating chrome over the map (UX-21)

extension View {
    /// Background for rounded floating chrome over the map: adopts iOS 26 Liquid Glass when
    /// available, falling back to a system material (not a flat dark tint) on iOS 17–25. (UX-21)
    @ViewBuilder
    func floatingChromeBackground(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// Circular variant of `floatingChromeBackground` for round map buttons.
    @ViewBuilder
    func floatingChromeCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .circle)
        } else {
            self.background(.regularMaterial, in: Circle())
        }
    }
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

// MARK: - Cockpit Theme (v4 UI/UX Revamp foundation)

/// The three cockpit display modes. Generalises the binary night-mode toggle (UX-09) into a
/// readable-in-any-light system the revamped screens theme against:
/// - `day` — the standard dark cockpit (unchanged from today).
/// - `sunlight` — high-contrast, brighter, for direct-sun readability.
/// - `night` — red-shifted, dimmed, to preserve scotopic dark adaptation.
enum CockpitThemeMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case day, sunlight, night
    var id: String { rawValue }
}

/// A complete semantic palette resolved from a `CockpitThemeMode`. Revamped views read it from the
/// environment (`@Environment(\.cockpitTheme)`) and use the semantic tokens (`action`, `onTarget`,
/// `textPrimary`, …) so a single mode switch re-themes every screen consistently. `day` maps to the
/// existing `Color` tokens, so the current look is unchanged until a screen opts into the theme.
struct CockpitTheme: Equatable {
    let mode: CockpitThemeMode
    let background: Color
    let panel: Color
    let panelStroke: Color
    let action: Color
    let actionText: Color
    let onTarget: Color
    let warning: Color
    let danger: Color
    let info: Color
    let textPrimary: Color
    let textSecondary: Color
    let textDim: Color
    let glassFill: Color
    let glassStroke: Color

    static func resolve(_ mode: CockpitThemeMode) -> CockpitTheme {
        switch mode {
        case .day: return .day
        case .sunlight: return .sunlight
        case .night: return .night
        }
    }
}

extension CockpitTheme {
    static let day = CockpitTheme(
        mode: .day,
        background: .cockpitBackground, panel: .panelBackground,
        panelStroke: Color(white: 0.18),
        action: .aviationGold, actionText: Color(red: 0.16, green: 0.12, blue: 0.03),
        onTarget: .aviationGreen, warning: Color(red: 0.91, green: 0.56, blue: 0.18),
        danger: .aviationRed, info: .altimeterBlue,
        textPrimary: .primaryText, textSecondary: .secondaryText, textDim: .dimText,
        glassFill: Color(white: 1.0).opacity(0.06), glassStroke: Color(white: 1.0).opacity(0.14)
    )

    static let sunlight = CockpitTheme(
        mode: .sunlight,
        background: .black, panel: Color(white: 0.10),
        panelStroke: Color(white: 0.30),
        action: Color(red: 1.0, green: 0.78, blue: 0.18), actionText: .black,
        onTarget: Color(red: 0.30, green: 0.92, blue: 0.45),
        warning: Color(red: 1.0, green: 0.66, blue: 0.10),
        danger: Color(red: 1.0, green: 0.30, blue: 0.30),
        info: Color(red: 0.45, green: 0.74, blue: 1.0),
        textPrimary: .white, textSecondary: Color(white: 0.82), textDim: Color(white: 0.62),
        glassFill: Color(white: 1.0).opacity(0.10), glassStroke: Color(white: 1.0).opacity(0.22)
    )

    static let night = CockpitTheme(
        mode: .night,
        background: Color(red: 0.06, green: 0.02, blue: 0.02),
        panel: Color(red: 0.10, green: 0.045, blue: 0.045),
        panelStroke: Color(red: 0.20, green: 0.09, blue: 0.09),
        action: Color(red: 0.78, green: 0.28, blue: 0.16),
        actionText: Color(red: 0.95, green: 0.80, blue: 0.76),
        onTarget: .nightOnTarget, warning: Color(red: 0.55, green: 0.26, blue: 0.0),
        danger: .nightStall, info: Color(red: 0.62, green: 0.30, blue: 0.26),
        textPrimary: Color(red: 0.90, green: 0.62, blue: 0.56),
        textSecondary: Color(red: 0.60, green: 0.35, blue: 0.32),
        textDim: Color(red: 0.42, green: 0.24, blue: 0.22),
        glassFill: Color(red: 0.78, green: 0.30, blue: 0.26).opacity(0.08),
        glassStroke: Color(red: 0.78, green: 0.30, blue: 0.26).opacity(0.20)
    )
}

private struct CockpitThemeKey: EnvironmentKey {
    static let defaultValue = CockpitTheme.day
}

extension EnvironmentValues {
    /// The active cockpit theme palette. Injected once near the app root from the user's theme mode;
    /// revamped screens read it instead of hardcoding colors. (v4 UI/UX Revamp)
    var cockpitTheme: CockpitTheme {
        get { self[CockpitThemeKey.self] }
        set { self[CockpitThemeKey.self] = newValue }
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
/// A settings-hub section row, styled as a cockpit card (tinted icon circle + title/subtitle +
/// chevron). The reference implementation of the v4 UI/UX Revamp cockpit language for list surfaces: dark
/// `cardBackground`, per-section accent in a soft circle, a gold-bordered selected state for the iPad
/// split view, and an optional badge (e.g. BETA). Title/subtitle use semantic fonts so they scale
/// with Dynamic Type. (v4 UI/UX Revamp reference)
struct SettingsRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var tint: Color = .aviationGold
    var badge: String? = nil
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(tint)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(.primaryText)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 5).fill(tint))
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.dimText.opacity(0.7))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(isSelected ? Color.aviationGold.opacity(0.7) : Color.white.opacity(0.06),
                                      lineWidth: isSelected ? 1.5 : 1)
                )
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Cockpit Settings Components (settings sub-page revamp)

/// Lays settings rows out in a card with leading-inset hairlines between them (none after the last).
/// `_VariadicView` is how SwiftUI itself interleaves separators between ViewBuilder children.
private struct SettingsRowSeparators: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let lastID = children.last?.id
        return VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != lastID {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 0.5)
                        .padding(.leading, 14)
                }
            }
        }
    }
}

/// A vertical scroll of cockpit cards on the cockpit background — the shell for a settings sub-page.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.cockpitBackground.ignoresSafeArea())
        .scrollContentBackground(.hidden)
    }
}

/// A titled group: uppercase accent header + a card holding rows, plus an optional footer line.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var tint: Color = .aviationGold
    var footer: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.4)
                    .foregroundColor(tint)
                    .padding(.horizontal, 4)
            }
            _VariadicView.Tree(SettingsRowSeparators()) { content }
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                )
            if let footer {
                Text(footer)
                    .font(.caption2)
                    .foregroundColor(.dimText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
        }
    }
}

/// The leading content of a settings row: tinted icon disc + title + optional subtitle, then a spacer
/// so a trailing control (toggle, value, chevron) is pushed to the edge.
struct SettingsRowLabel: View {
    var icon: String? = nil
    let title: String
    var subtitle: String? = nil
    var tint: Color = .aviationGold
    var titleColor: Color = .primaryText
    var body: some View {
        HStack(spacing: 13) {
            if let icon {
                ZStack {
                    Circle().fill(tint.opacity(0.16)).frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(tint)
                }
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundColor(titleColor)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
        }
    }
}

/// A row carrying a gold-tinted toggle. The whole label is the toggle's label, so VoiceOver reads
/// the title and switch state together.
struct SettingsToggleRow: View {
    var icon: String? = nil
    let title: String
    var subtitle: String? = nil
    var tint: Color = .aviationGold
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsRowLabel(icon: icon, title: title, subtitle: subtitle, tint: tint)
        }
        .tint(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// A tappable row (navigation push or action), optionally showing a trailing value and a chevron.
struct SettingsButtonRow: View {
    var icon: String? = nil
    let title: String
    var subtitle: String? = nil
    var tint: Color = .aviationGold
    var value: String? = nil
    var showsChevron: Bool = true
    var destructive: Bool = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SettingsRowLabel(icon: icon, title: title, subtitle: subtitle,
                                 tint: destructive ? .aviationRed : tint,
                                 titleColor: destructive ? .aviationRed : .primaryText)
                if let value {
                    Text(value).font(.subheadline).foregroundColor(.secondaryText).lineLimit(1)
                }
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.dimText.opacity(0.7))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A read-only row: label on the left, a static value on the right.
struct SettingsValueRow: View {
    var icon: String? = nil
    let title: String
    var subtitle: String? = nil
    var tint: Color = .aviationGold
    let value: String
    /// Colour of the value text — override to keep a status semantic (e.g. green/red authorisation).
    var valueColor: Color = .secondaryText
    var body: some View {
        HStack(spacing: 10) {
            SettingsRowLabel(icon: icon, title: title, subtitle: subtitle, tint: tint)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundColor(valueColor)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// A row that opens a menu picker for an enum/value selection (label · current value · chevron).
struct SettingsMenuRow<T: Hashable, Options: View>: View {
    var icon: String? = nil
    let title: String
    var subtitle: String? = nil
    var tint: Color = .aviationGold
    @Binding var selection: T
    @ViewBuilder var options: Options
    var body: some View {
        Picker(selection: $selection) {
            options
        } label: {
            SettingsRowLabel(icon: icon, title: title, subtitle: subtitle, tint: tint)
        }
        .pickerStyle(.menu)
        .tint(.secondaryText)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}

// MARK: - Cockpit Instrument Panel (v4 UI/UX Revamp HUD)

/// On-target state of the live speed, encoded by SHAPE/POSITION (the bar) as well as color, so it
/// reads for color-blind pilots and in any theme. (v4 UI/UX Revamp)
enum InstrumentTargetState: Equatable {
    case onTarget
    case caution
    case stall
    case neutral

    /// Bar/accent color for this state in the given theme.
    func barColor(in theme: CockpitTheme) -> Color {
        switch self {
        case .onTarget: return theme.onTarget
        case .caution: return theme.warning
        case .stall: return theme.danger
        case .neutral: return theme.textDim
        }
    }
}

/// The color-blind-safe on-target proximity bar: a centered capsule whose WIDTH encodes how close the
/// live value is to its target (full = on target, shrinking with deviation) and whose COLOR encodes
/// the target state — so the reading never depends on color alone. Shared by the full instruments and
/// `CockpitInstrumentPanel` so they render identically in any theme. (v4 UI/UX Revamp)
struct InstrumentTargetBar: View {
    /// 0...1 fill of the bar (1 = on target).
    let fraction: Double
    let state: InstrumentTargetState

    @Environment(\.cockpitTheme) private var theme

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(state.barColor(in: theme))
                .frame(width: max(0, min(1, fraction)) * geo.size.width, height: 4)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(height: 4)
    }
}

// MARK: - Cockpit Instrument Strip (live, safety-bearing)

/// The real in-flight instrument strip for the revamped HUD: SPD / ALT / HDG in one horizontal
/// Liquid-Glass panel with the color-blind-safe on-target bar — the look of `CockpitInstrumentPanel`,
/// but carrying the live SAFETY behavior (stall annunciation + aural/haptic alert, GPS-failure flags,
/// VoiceOver values). The safety LOGIC is the same shared, unit-tested code the boxed instruments use
/// (`SpeedIndicatorView.annunciationState` / `.accessibilityValue` / `.targetBarFraction` / `.barState`,
/// `AltimeterView.accessibilityValue`, `StallAlert`, `InstrumentFailureFlag`); only the visual layout
/// is new. (v4 UI/UX Revamp)
struct CockpitInstrumentStrip: View {
    let speedKnots: Double           // ground speed (display fallback)
    let targetSpeed: Int?
    let stallSpeed: Int
    let gpsSignalStatus: GPSSignalStatus
    var estimatedAirspeed: Double? = nil
    var stallAlertEnabled: Bool = false
    let altitudeFeet: Double
    var headingDegrees: Double? = nil
    var verticalSpeedFPM: Double? = nil

    /// Vertical speed for the ALT cell, formatted (e.g. "↑480" / "↓300") with a colour — shown only
    /// above ±50 fpm so level flight stays clean. Hidden when GPS is lost.
    private var verticalSpeedDisplay: (text: String, color: Color)? {
        guard gpsSignalStatus != .lost, let vs = verticalSpeedFPM, abs(vs) >= 50 else { return nil }
        let rounded = Int((vs / 10).rounded()) * 10
        return (vs > 0 ? "↑\(abs(rounded))" : "↓\(abs(rounded))", vs > 0 ? theme.onTarget : theme.info)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cockpitTheme) private var theme
    @State private var isFlashing = false

    private var displaySpeed: Double { estimatedAirspeed ?? speedKnots }
    private var showingEstimatedAirspeed: Bool { estimatedAirspeed != nil }

    private var speedState: SpeedIndicatorView.SpeedState {
        SpeedIndicatorView.annunciationState(
            displaySpeed: displaySpeed, targetSpeed: targetSpeed ?? 0, stallSpeed: stallSpeed,
            showingEstimatedAirspeed: showingEstimatedAirspeed, gpsSignalStatus: gpsSignalStatus)
    }

    private var showFailureFlag: Bool { gpsSignalStatus == .degraded || gpsSignalStatus == .lost }
    private var failureLevel: InstrumentFailureFlag.FailureLevel { gpsSignalStatus == .lost ? .lost : .degraded }

    private var speedColor: Color {
        switch speedState {
        case .onTarget: return theme.onTarget
        case .offTarget: return theme.warning
        case .stall:
            if reduceMotion { return theme.danger }
            return isFlashing ? theme.danger : theme.danger.opacity(0.7)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            speedCell
            divider
            altitudeCell
            divider
            headingCell
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(theme.glassFill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(theme.glassStroke, lineWidth: 0.5))
        .onAppear { if speedState == .stall { startFlash(); fireStallAlert() } }
        .onChange(of: speedState) { _, newState in
            if newState == .stall { startFlash(); fireStallAlert() } else { stopFlash() }
        }
    }

    private var speedCell: some View {
        cell(label: showingEstimatedAirspeed ? "IAS kt" : "SPD kt") {
            ZStack {
                VStack(spacing: 0) {
                    if gpsSignalStatus != .lost {
                        // Static STALL annunciation — never colour/flash alone, steady under Reduce Motion.
                        if speedState == .stall {
                            Text("STALL").font(.system(size: 11, weight: .heavy)).foregroundColor(theme.danger)
                        }
                        Text("\(showingEstimatedAirspeed ? "~" : "")\(Int(max(0, displaySpeed)))")
                            .font(.system(size: 30, weight: .medium, design: .monospaced))
                            .foregroundColor(speedColor)
                            .minimumScaleFactor(0.6).lineLimit(1)
                        if let target = targetSpeed {
                            InstrumentTargetBar(
                                fraction: SpeedIndicatorView.targetBarFraction(displaySpeed: displaySpeed, targetSpeed: target),
                                state: SpeedIndicatorView.barState(for: speedState)
                            )
                            .frame(maxWidth: 72).padding(.top, 3)
                        }
                    }
                }
                if showFailureFlag {
                    InstrumentFailureFlag(level: failureLevel, size: CGSize(width: 70, height: 34))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showingEstimatedAirspeed ? "Estimated airspeed" : "Ground speed")
        .accessibilityValue(SpeedIndicatorView.accessibilityValue(
            displaySpeed: Int(displaySpeed), targetSpeed: targetSpeed ?? 0, state: speedState,
            estimated: showingEstimatedAirspeed, gpsLost: gpsSignalStatus == .lost))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var altitudeCell: some View {
        cell(label: "ALT ft") {
            ZStack {
                if gpsSignalStatus != .lost {
                    VStack(spacing: 1) {
                        Text("\(Int(max(0, altitudeFeet)))")
                            .font(.system(size: 24, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.textPrimary)
                            .minimumScaleFactor(0.5).lineLimit(1)
                        if let vs = verticalSpeedDisplay {
                            Text(vs.text)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(vs.color)
                        }
                    }
                }
                if showFailureFlag {
                    InstrumentFailureFlag(level: failureLevel, size: CGSize(width: 70, height: 34))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Altitude")
        .accessibilityValue(AltimeterView.accessibilityValue(altitudeFeet: Int(altitudeFeet), gpsLost: gpsSignalStatus == .lost))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var headingCell: some View {
        cell(label: "HDG") {
            Text(headingDegrees.map { String(format: "%03d°", (Int($0.rounded()) % 360 + 360) % 360) } ?? "---")
                .font(.system(size: 24, weight: .medium, design: .monospaced))
                .foregroundColor(theme.textPrimary)
            Text("track").font(.system(size: 10)).foregroundColor(theme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heading")
        .accessibilityValue(headingDegrees.map { "\((Int($0.rounded()) % 360 + 360) % 360) degrees track" } ?? "unknown")
    }

    private var divider: some View {
        Rectangle().fill(theme.glassStroke).frame(width: 0.5).frame(maxHeight: 44)
    }

    @ViewBuilder
    private func cell<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundColor(theme.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity)
    }

    private func fireStallAlert() { if stallAlertEnabled { StallAlert.shared.trigger() } }

    private func startFlash() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.3).repeatForever(autoreverses: true)) { isFlashing = true }
    }
    private func stopFlash() {
        withAnimation(.easeInOut(duration: 0.1)) { isFlashing = false }
    }
}

// MARK: - Cockpit Hero Checklist Item (v4 UI/UX Revamp HUD)

/// The one-glance centerpiece of the revamped in-flight HUD: the CURRENT checklist item rendered
/// large (challenge + response) with the item progress and a tap-to-advance hint. Presentational
/// and themed via `\.cockpitTheme`; the container supplies the surrounding dimmed completed/next
/// items. (v4 UI/UX Revamp)
struct CockpitHeroChecklistItem: View {
    let challenge: String
    var response: String? = nil
    /// e.g. "item 2 / 5"; nil hides the progress line.
    var progressText: String? = nil
    var showAdvanceHint: Bool = true
    /// Scales the type/padding down for the narrower iPhone checklist.
    var isCompact: Bool = false

    @Environment(\.cockpitTheme) private var theme

    private var challengeSize: CGFloat { isCompact ? 20 : 28 }
    private var responseSize: CGFloat { isCompact ? 16 : 22 }
    private var metaSize: CGFloat { isCompact ? 11 : 12 }
    private var pad: CGFloat { isCompact ? 10 : 14 }
    private var corner: CGFloat { isCompact ? 10 : 12 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if progressText != nil || showAdvanceHint {
                HStack {
                    if let progressText {
                        Text(progressText.uppercased())
                            .font(.system(size: metaSize))
                            .foregroundColor(theme.textSecondary)
                    }
                    Spacer(minLength: 8)
                    if showAdvanceHint {
                        Label(L10n.ChecklistAction.tapToAdvance, systemImage: "hand.point.up.left")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: metaSize))
                            .foregroundColor(theme.action)
                    }
                }
                .padding(.bottom, 1)
            }
            Text(challenge)
                .font(.system(size: challengeSize, weight: .medium))
                .foregroundColor(theme.textPrimary)
                .lineLimit(2)                 // never run past 2 lines — long item names threw off the HUD
                .minimumScaleFactor(0.6)
            if let response, !response.isEmpty {
                Text(response)
                    .font(.system(size: responseSize, weight: .medium))
                    .foregroundColor(theme.action)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(pad)
        .background(theme.panel)
        .overlay(alignment: .leading) {
            Rectangle().fill(theme.action).frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay(
            RoundedRectangle(cornerRadius: corner).strokeBorder(theme.panelStroke, lineWidth: 0.5)
        )
    }
}
