import Foundation
import os

/// Centralized structured logging built on `os.Logger`, replacing the app's former
/// `print("[Channel] …")` convention. Each former bracketed channel maps to one `Logger`
/// category; all categories share the running process's bundle-id subsystem, so the app and
/// the Watch extension log under their own subsystems automatically.
///
/// Migrate `print("[Sync] foo")` → `AppLog.sync.debugLine("foo")`. View output in Console.app
/// or Xcode filtered by subsystem/category instead of scraping a flat console stream.
enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "app.aerocheck"

    static let general = Logger(subsystem: subsystem, category: "General")
    static let sync = Logger(subsystem: subsystem, category: "Sync")
    static let flightEvents = Logger(subsystem: subsystem, category: "FlightEvents")
    static let aircraftData = Logger(subsystem: subsystem, category: "AircraftData")
    static let companion = Logger(subsystem: subsystem, category: "Companion")
    static let watch = Logger(subsystem: subsystem, category: "Watch")
    static let airportData = Logger(subsystem: subsystem, category: "AirportData")
    static let bundledChecklist = Logger(subsystem: subsystem, category: "BundledChecklist")
    static let openAIP = Logger(subsystem: subsystem, category: "OpenAIP")
    static let subscription = Logger(subsystem: subsystem, category: "Subscription")
    static let marketing = Logger(subsystem: subsystem, category: "Marketing")
    static let location = Logger(subsystem: subsystem, category: "Location")
}

extension Logger {
    /// Logs an already-interpolated diagnostic line at `.info` level and `.public` privacy,
    /// preserving the visibility of the `print()` statements this replaced. These are developer
    /// diagnostics, not user PII — redact sensitive values at the call site before passing them.
    func debugLine(_ message: String) {
        self.info("\(message, privacy: .public)")
    }
}
