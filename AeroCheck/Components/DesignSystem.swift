import SwiftUI

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
    }
    
    let status: Status
    let size: CGFloat
    
    init(_ status: Status, size: CGFloat = 12) {
        self.status = status
        self.size = size
    }
    
    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: size, height: size)
            .shadow(color: status.color.opacity(0.5), radius: 4)
    }
}

// MARK: - Speed Indicator for Flight

struct SpeedIndicatorView: View {
    let currentSpeed: Double // in knots (from GPS, m/s converted)
    let targetSpeed: Int
    let stallSpeed: Int = 42 // Vs clean stall speed

    @State private var isFlashing = false

    // Speed state categories
    private var speedState: SpeedState {
        let speedInt = Int(currentSpeed)
        if speedInt < stallSpeed {
            return .stall
        } else if abs(speedInt - targetSpeed) <= 5 {
            return .onTarget
        } else {
            return .offTarget
        }
    }

    enum SpeedState {
        case onTarget   // Green (solid): within 5 KIAS of target
        case offTarget  // Orange (solid): above Vs but outside 5 KIAS range
        case stall      // Flashing red/white: below stall speed
    }
    
    var body: some View {
        VStack(spacing: 4) {
            // Speed label
            Text("SPEED")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.secondaryText)
            
            // Current speed display
            ZStack {
                // Background
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundColor)
                
                // Speed value
                VStack(spacing: 2) {
                    Text("\(Int(currentSpeed))")
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .foregroundColor(textColor)
                    
                    Text("KIAS")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(textColor.opacity(0.8))
                }
            }
            .frame(width: 100, height: 70)
            
            // Target speed indicator
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
            } else {
                stopFlashing()
            }
        }
    }
    
    private var backgroundColor: Color {
        switch speedState {
        case .onTarget:
            return Color.aviationGreen.opacity(0.2)
        case .offTarget:
            return Color.orange.opacity(0.2)
        case .stall:
            // Only animate in stall state
            return isFlashing ? Color.aviationRed : Color.aviationRed.opacity(0.7)
        }
    }

    private var textColor: Color {
        switch speedState {
        case .onTarget:
            return .aviationGreen
        case .offTarget:
            return .orange
        case .stall:
            // Only animate in stall state
            return isFlashing ? .white : .aviationRed
        }
    }
    
    private var targetIcon: String {
        let speedInt = Int(currentSpeed)
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
        }
    }
    
    private func startFlashing() {
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

// MARK: - Speed Indicator Container (handles GPS speed conversion)

struct FlightSpeedIndicator: View {
    let gpsSpeedMetersPerSecond: Double
    let targetSpeed: Int?

    // Convert m/s to knots (1 m/s = 1.94384 knots)
    private var speedInKnots: Double {
        gpsSpeedMetersPerSecond * 1.94384
    }

    var body: some View {
        if let target = targetSpeed {
            SpeedIndicatorView(currentSpeed: max(0, speedInKnots), targetSpeed: target)
        }
    }
}

// MARK: - Altimeter Display

/// Light blue color for altimeter background
extension Color {
    static let altimeterBlue = Color(red: 0.4, green: 0.6, blue: 0.8)
}

struct AltimeterView: View {
    let altitudeFeet: Double

    var body: some View {
        VStack(spacing: 4) {
            // Altitude label
            Text("ALT")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.black.opacity(0.6))

            // Altitude display
            ZStack {
                // Background
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.altimeterBlue)

                // Altitude value
                VStack(spacing: 2) {
                    Text("\(Int(altitudeFeet))")
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)

                    Text("FT")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.black.opacity(0.7))
                }
            }
            .frame(width: 100, height: 70)

            // MSL indicator
            Text("MSL")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.secondaryText)
        }
    }
}

// MARK: - Altimeter Container (handles altitude in feet)

struct FlightAltimeter: View {
    let altitudeFeet: Double

    var body: some View {
        AltimeterView(altitudeFeet: max(0, altitudeFeet))
    }
}

// MARK: - Pulse Animation Modifier

/// A pulse animation to draw attention to a button - 2 distinct pulses
struct PulseModifier: ViewModifier {
    let isActive: Bool
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
