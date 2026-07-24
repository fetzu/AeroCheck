import SwiftUI
import WidgetKit
#if canImport(ActivityKit)
import ActivityKit

/// Live Activity for an in-progress flight: phase, self-ticking elapsed clock, and circuit
/// counters on the Lock Screen and in the Dynamic Island. (UX-25)
///
/// The clock uses `Text(timerInterval:)` so the system renders every tick — the app only pushes
/// updates on discrete events (phase change, timing events, landings). Cockpit-dark styling is
/// deliberate and matches the app's design language.
struct FlightLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlightActivityAttributes.self) { context in
            // Lock Screen / banner presentation.
            lockScreenView(context)
                .activityBackgroundTint(Color.black.opacity(0.8))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "aerocheck://"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.registration, systemImage: "airplane")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsedClock(context, font: .caption.monospacedDigit().weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.phaseName)
                            .font(.subheadline.weight(.bold))
                            .lineLimit(1)
                        Spacer()
                        if context.state.isCircuitMode {
                            circuitCounters(context)
                                .font(.caption2)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "airplane")
            } compactTrailing: {
                elapsedClock(context, font: .caption2.monospacedDigit())
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "airplane")
            }
            .widgetURL(URL(string: "aerocheck://"))
        }
    }

    @ViewBuilder
    private func lockScreenView(_ context: ActivityViewContext<FlightActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "airplane")
                .font(.title2)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.registration)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Text(context.state.phaseName)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                elapsedClock(context, font: .title3.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
                if context.state.isCircuitMode {
                    circuitCounters(context)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(14)
    }

    /// Self-ticking elapsed clock from the engine/session start; a placeholder before any start.
    @ViewBuilder
    private func elapsedClock(_ context: ActivityViewContext<FlightActivityAttributes>, font: Font) -> some View {
        if let start = context.state.startTime {
            Text(timerInterval: start...Date(timeIntervalSinceNow: 24 * 60 * 60), countsDown: false)
                .font(font)
                .multilineTextAlignment(.trailing)
        } else {
            Text("--:--")
                .font(font)
        }
    }

    @ViewBuilder
    private func circuitCounters(_ context: ActivityViewContext<FlightActivityAttributes>) -> some View {
        // Aviation abbreviations (T&G, FS) are intentionally not localized, per ICAO conventions.
        Text("T&G \(context.state.touchAndGoCount) · FS \(context.state.fullStopCount)")
            .lineLimit(1)
    }
}
#endif
