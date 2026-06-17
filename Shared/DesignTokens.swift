import SwiftUI

// MARK: - AeroCheck Design Tokens (shared)
//
// The single source of truth for the cockpit colour palette, compiled into the app, the Watch app,
// and the home-screen widget via multi-target membership. These values were previously duplicated in
// DesignSystem.swift (app), AeroCheckWatch/ContentView.swift, and AeroCheckWidget/AeroCheckWidget.swift.
// Keep only cross-platform tokens here (plain SwiftUI `Color`); iOS-only view code, the `CockpitTheme`
// modes, and the night-instrument palette stay in the app's DesignSystem.swift.

extension Color {
    // Primary colors — aviation inspired
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

    // Instrument accent
    static let altimeterBlue = Color(red: 0.4, green: 0.6, blue: 0.8)
}
