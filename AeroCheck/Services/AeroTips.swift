import SwiftUI
import TipKit

// MARK: - One-time tips (6.8.0)

/// A few tips where a feature lives, each shown once with Apple's TipKit (the author's answer 8 A on the onboarding
/// page, 31 Oct 2026): the Map sheet and the logbook's line. None in the Cockpit
/// (the author's q2, 5 Nov 2026): the dry run teaches the Cockpit, with the aircraft moving and nobody flying. Never in a
/// flight past its line-up nor in a dry run (`isQuiet`); never in the tests or a screenshot run. Settings › About shows
/// them again from the next launch.
enum AeroTips {

    /// Settings › About's "Show the tips again": TipKit's store is reset before it is configured, so at the next launch.
    nonisolated static let resetPendingKey = "tips.resetPending"

    /// The tests, a replay or a screenshot run: nothing of this kind comes over their screens.
    nonisolated static var isScripted: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil || environment.keys.contains { $0.hasPrefix("AEROCHECK_") }
    }

    /// Once, at launch.
    static func configure(defaults: UserDefaults = .standard) {
        if defaults.bool(forKey: resetPendingKey) {
            try? Tips.resetDatastore()
            defaults.set(false, forKey: resetPendingKey)
        }
        if isScripted { Tips.hideAllTipsForTesting() }
        try? Tips.configure([.displayFrequency(.immediate), .datastoreLocation(.applicationDefault)])
    }

    /// Whether the tips keep quiet now: a flight past its line-up check, or a dry run under way.
    static func isQuiet(flightActive: Bool, phase: ChecklistPhase, dryRunRunning: Bool) -> Bool {
        if dryRunRunning { return true }
        guard flightActive else { return false }
        return phase.rawValue > ChecklistPhase.lineUp.rawValue
    }

    /// Read by every tip's rule; set by the app's root as the flight and the dry run go.
    @Parameter static var quiet: Bool = false
}

/// Plan › Map: the Map sheet holds the charts and the overlays.
struct MapSheetTip: Tip {
    var title: Text { Text(L10n.Tips.mapSheetTitle) }
    var message: Text? { Text(L10n.Tips.mapSheetBody) }
    var image: Image? { Image(systemName: "square.stack.3d.up") }
    var rules: [Rule] { #Rule(AeroTips.$quiet) { !$0 } }
}

/// The logbook: a flight's line, once there is one.
struct LogbookLineTip: Tip {
    var title: Text { Text(L10n.Tips.logbookLineTitle) }
    var message: Text? { Text(L10n.Tips.logbookLineBody) }
    var image: Image? { Image(systemName: "book.closed") }
    var rules: [Rule] { #Rule(AeroTips.$quiet) { !$0 } }
}

extension View {
    /// `tip` as a popover on this view where `shown`: one view, the tip on only one of its uses.
    @ViewBuilder
    func aeroTip(_ tip: some Tip, shown: Bool = true, arrowEdge: Edge) -> some View {
        if shown { popoverTip(tip, arrowEdge: arrowEdge) } else { self }
    }
}
