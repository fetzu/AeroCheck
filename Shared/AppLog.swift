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
    /// Logs an already-interpolated diagnostic line at `.info` level with **private** interpolation.
    ///
    /// SA-20: this used to force `privacy: .public` on every message, overriding `os.Logger`'s
    /// default redaction for all ~227 call sites at once, with nothing gated to `DEBUG`. Any future
    /// call site interpolating a raw identifier, coordinate, receipt or token would have written it
    /// to the unified log in the clear — readable from a sysdiagnose, from Console.app on a paired
    /// Mac, or from a support bundle. The safety property was convention ("redact at the call
    /// site"), not enforcement, and existing discipline being good is not a guarantee about the next
    /// line someone writes.
    ///
    /// Redaction is now the default. Values are elided as `<private>` in release builds and shown
    /// normally when a debugger is attached, so day-to-day development is unaffected. Use
    /// `publicLine` for the deliberately non-sensitive minority.
    func debugLine(_ message: String) {
        self.info("\(message, privacy: .private)")
    }

    /// Logs a diagnostic line that is explicitly safe to expose in the clear.
    ///
    /// Use only for messages that carry no identifier, coordinate, credential or user content —
    /// lifecycle markers, mode changes, counts. The name is the point: making the public case
    /// opt-in and visible at the call site is what turns "we redact by convention" into something a
    /// reviewer can check. (SA-20)
    func publicLine(_ message: String) {
        self.info("\(message, privacy: .public)")
    }
}
