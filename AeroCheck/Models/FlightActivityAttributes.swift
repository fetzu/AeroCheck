import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Attributes for the in-flight Live Activity (Lock Screen / Dynamic Island).
/// Target membership: app + AeroCheckWidgetExtension ONLY — ActivityKit does not exist on watchOS,
/// so this deliberately does NOT live in Shared/ (whose files are also in the Watch target).
///
/// Design: static attributes are the aircraft identity; the content state is the small set of
/// values that change on discrete events (phase transitions, timing events, landing counts).
/// The elapsed-time clock is rendered with `Text(timerInterval:)` from `engineStartTime`, so the
/// system ticks it — no per-second updates are ever pushed. (UX-25)
#if canImport(ActivityKit)
struct FlightActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Localized display name of the current checklist phase.
        var phaseName: String
        /// Engine start (or session start) — drives the self-ticking elapsed clock.
        var startTime: Date?
        var touchAndGoCount: Int
        var fullStopCount: Int
        var isCircuitMode: Bool
    }

    /// Aircraft display name (e.g. "WT9 Dynamic").
    var aircraftName: String
    /// Registration (e.g. "F-HVXA").
    var registration: String
}
#endif
