import SwiftUI

// MARK: - Runtime-overridable accent palette (shared)
//
// A small indirection layer that lets the shared cockpit colour tokens (see DesignTokens.swift) be
// re-skinned at runtime — for a seasonal accent or an in-app trial — without shipping a new build.
// When no override is installed the tokens return their standard cockpit values, so this is inert by
// default and on platforms that never install one (the Watch app and the widget).

enum AmbientPalette {

    // Installed overrides, or `nil` to fall back to the standard token value. These are written only
    // from the main actor during a user-driven appearance change; reads happen inline while SwiftUI
    // evaluates view bodies, also on the main thread.
    nonisolated(unsafe) static var accent: Color?
    nonisolated(unsafe) static var background: Color?
    nonisolated(unsafe) static var panel: Color?
    nonisolated(unsafe) static var card: Color?
    nonisolated(unsafe) static var textPrimary: Color?
    nonisolated(unsafe) static var textSecondary: Color?
    nonisolated(unsafe) static var textDim: Color?
    // Navigation chrome (rail / tab bar) surface and the hairline separators that, in the standard
    // palette, are a faint white-on-dark line.
    nonisolated(unsafe) static var chrome: Color?
    nonisolated(unsafe) static var hairline: Color?

    /// `true` while an accent override is installed.
    static var isActive: Bool { accent != nil }

    /// Drops every installed override, restoring the standard cockpit palette.
    static func clear() {
        accent = nil
        background = nil
        panel = nil
        card = nil
        textPrimary = nil
        textSecondary = nil
        textDim = nil
        chrome = nil
        hairline = nil
    }
}
