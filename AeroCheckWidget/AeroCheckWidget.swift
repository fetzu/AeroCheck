import WidgetKit
import SwiftUI

// MARK: - Aviation Theme Colors — now from Shared/DesignTokens.swift.

// MARK: - Shared Owned-Aircraft Data
// NOTE: The App Group id, defaults key, and `WidgetAircraft` shape are duplicated from the main
// app's WidgetBridge.swift. The widget can't share code with the app, so keep these in sync.

/// One start button the widget can render. `key` is the stable deep-link token.
struct WidgetAircraft: Codable, Hashable {
    let key: String
    let registration: String
}

enum WidgetSharedData {
    static let appGroupID = "group.com.fetzu.aerocheck"
    static let aircraftDefaultsKey = "widgetAircraft"

    /// The aircraft the user owns, as published by the app. Falls back to just the free bundled
    /// aircraft if the App Group hasn't been written yet — so an unowned premium aircraft never
    /// appears as a widget button.
    static func ownedAircraft() -> [WidgetAircraft] {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: aircraftDefaultsKey),
              let list = try? JSONDecoder().decode([WidgetAircraft].self, from: data),
              !list.isEmpty
        else {
            return [WidgetAircraft(key: "wt9-dynamic", registration: "F-HVXA")]
        }
        return list
    }
}

// MARK: - Widget Timeline Entry

struct AeroCheckEntry: TimelineEntry {
    let date: Date
    let aircraft: [WidgetAircraft]
}

// MARK: - Widget Timeline Provider

struct AeroCheckProvider: TimelineProvider {
    func placeholder(in context: Context) -> AeroCheckEntry {
        AeroCheckEntry(date: Date(), aircraft: WidgetSharedData.ownedAircraft())
    }

    func getSnapshot(in context: Context, completion: @escaping (AeroCheckEntry) -> Void) {
        completion(AeroCheckEntry(date: Date(), aircraft: WidgetSharedData.ownedAircraft()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AeroCheckEntry>) -> Void) {
        // Static widget — refreshed explicitly by the app (via WidgetCenter) when ownership changes.
        let entry = AeroCheckEntry(date: Date(), aircraft: WidgetSharedData.ownedAircraft())
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

// MARK: - Widget Views


struct SmallWidgetView: View {
    let aircraft: [WidgetAircraft]
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        VStack(spacing: 6) {
            // De-emphasised brand at the top.
            HStack(spacing: 4) {
                Image(systemName: "airplane").font(.system(size: 11, weight: .semibold))
                Text("AéroCheck").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(colorScheme == .dark ? Color(white: 0.5) : Color(white: 0.45))
            .frame(maxWidth: .infinity, alignment: .leading)

            // Owned-aircraft launch button(s) — the hero.
            HStack(spacing: 8) {
                ForEach(Array(aircraft.prefix(2)), id: \.key) { item in
                    AircraftButton(aircraft: item, accentColor: aircraftAccentColor(for: item))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Start-a-flight CTA at the bottom. Accentable + a plain-color fallback so it stays
            // legible once iOS 18 tinted/StandBy rendering drops the custom gold fill.
            HStack(spacing: 4) {
                Image(systemName: "airplane.departure").font(.system(size: 11, weight: .semibold))
                Text("Start a flight").font(.system(size: 12, weight: .semibold))
            }
            .widgetAccentable()
            .foregroundStyle(renderingMode == .fullColor ? Color.aviationGold : .primary)
        }
        .padding()
        .containerBackground(for: .widget) { widgetContainerBackground(colorScheme) }
    }
}

struct MediumWidgetView: View {
    let aircraft: [WidgetAircraft]
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        VStack(spacing: 10) {
            // Small brand header. Accentable + a plain-color fallback so the mark still reads once
            // iOS 18 tinted Home Screen / StandBy rendering drops the custom gold fill.
            HStack(spacing: 5) {
                Image(systemName: "airplane").font(.system(size: 13, weight: .semibold))
                Text("AéroCheck").font(.system(size: 13, weight: .bold))
            }
            .widgetAccentable()
            .foregroundStyle(renderingMode == .fullColor ? Color.aviationGold : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 14) {
                // Start a flight — aircraft tiles fill this section.
                VStack(alignment: .leading, spacing: 6) {
                    Text("START A FLIGHT").modifier(WidgetSectionLabel())
                    HStack(spacing: 10) {
                        ForEach(Array(aircraft.prefix(2)), id: \.key) { item in
                            AircraftButton(aircraft: item, accentColor: aircraftAccentColor(for: item))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity)

                Rectangle().fill(Color.aviationGold.opacity(0.3)).frame(width: 0.5)

                // History — Flight Log tile fills this section.
                VStack(alignment: .leading, spacing: 6) {
                    Text("HISTORY").modifier(WidgetSectionLabel())
                    // `Link` (not `Button(intent:)`) is the sanctioned way to launch the app from a
                    // widget — Button(intent:) only performs in-place actions and would not open
                    // AeroCheck's Flight Log screen.
                    Link(destination: URL(string: "aerocheck://flight-log")!) {
                        VStack(spacing: 4) {
                            Image(systemName: "book.closed.fill").font(.system(size: 22))
                                .widgetAccentable()
                            Text("Flight Log").font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(renderingMode == .fullColor ? (colorScheme == .dark ? Color.aviationGreen.opacity(0.2) : Color.aviationGreen.opacity(0.15)) : Color.clear)
                        .foregroundStyle(renderingMode == .fullColor ? Color.aviationGreen : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(renderingMode == .fullColor ? Color.aviationGreen.opacity(0.3) : Color.primary.opacity(0.2), lineWidth: 1)
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .padding()
        .containerBackground(for: .widget) { widgetContainerBackground(colorScheme) }
    }
}

/// Uppercase section label for the medium widget.
private struct WidgetSectionLabel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(Color(white: 0.55))
    }
}

/// Shared widget container background (cockpit dark / light).
@ViewBuilder
private func widgetContainerBackground(_ colorScheme: ColorScheme) -> some View {
    if colorScheme == .dark {
        Color.cockpitBackground
    } else {
        Color(white: 0.95)
    }
}

/// Accent colour for an aircraft button. The free bundled aircraft uses the v4 blue; premium
/// aircraft use the aviation gold accent.
private func aircraftAccentColor(for aircraft: WidgetAircraft) -> Color {
    aircraft.key == "wt9-dynamic" ? .altimeterBlue : .aviationGold
}

struct AircraftButton: View {
    let aircraft: WidgetAircraft
    let accentColor: Color

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var isFullColor: Bool { renderingMode == .fullColor }

    var body: some View {
        // `Link` (not `Button(intent:)`) is the sanctioned pattern for launching the app from a
        // widget — Button(intent:) only performs in-place actions and would not open AeroCheck.
        Link(destination: URL(string: "aerocheck://start-flight?aircraft=\(aircraft.key)")!) {
            VStack(spacing: 4) {
                Image(systemName: "airplane")
                    .font(.system(size: 22))
                    .widgetAccentable()
                Text(aircraft.registration)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .widgetAccentable()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // In accented (iOS 18 tinted Home Screen) / vibrant (StandBy) rendering, drop the
            // per-aircraft accent fill and border and let the system supply its own tint — a
            // saturated custom fill under a system-tinted glyph reads as unreadable color-on-color.
            .background(isFullColor ? (colorScheme == .dark ? accentColor.opacity(0.2) : accentColor.opacity(0.12)) : Color.clear)
            .foregroundStyle(isFullColor ? accentColor : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isFullColor ? accentColor.opacity(0.3) : Color.primary.opacity(0.2), lineWidth: 1)
            )
        }
    }
}

// MARK: - Lock Screen / StandBy Accessory Views

/// Lock Screen circular accessory: a single app-glyph quick-launch button. There's no room to pick
/// an aircraft in this tiny face, so it launches the same "default" aircraft the systemSmall /
/// systemMedium tiles put first — i.e. the front of the owned-aircraft list published by the app.
struct CircularWidgetView: View {
    let aircraft: [WidgetAircraft]

    /// The default owned aircraft to quick-launch (falls back to the free bundled aircraft's key,
    /// matching `WidgetSharedData.ownedAircraft()`'s own fallback, if the list is ever empty).
    private var defaultAircraftKey: String { aircraft.first?.key ?? "wt9-dynamic" }

    var body: some View {
        // `Link` (not `Button(intent:)`) is the sanctioned pattern for launching the app from a
        // widget — Button(intent:) only performs in-place actions and would not open AeroCheck.
        Link(destination: URL(string: "aerocheck://start-flight?aircraft=\(defaultAircraftKey)")!) {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "airplane")
                    .font(.system(size: 22, weight: .semibold))
                    .widgetAccentable()
            }
        }
        // Required since iOS 17 even for accessory families; the Lock Screen/StandBy chrome comes
        // from the system regardless, so this is just satisfying the unified container-background API.
        .containerBackground(for: .widget) { Color.clear }
    }
}

/// Lock Screen rectangular accessory: up to 2 owned-aircraft quick-start rows, using the same
/// deep-link URLs as the systemSmall/systemMedium `AircraftButton` tiles.
struct RectangularWidgetView: View {
    let aircraft: [WidgetAircraft]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "airplane").font(.system(size: 11, weight: .semibold))
                Text("AéroCheck").font(.system(size: 11, weight: .semibold))
            }
            .widgetAccentable()

            ForEach(Array(aircraft.prefix(2)), id: \.key) { item in
                // `Link` (not `Button(intent:)`) is the sanctioned pattern for launching the app
                // from a widget — Button(intent:) only performs in-place actions and would not
                // open AeroCheck.
                Link(destination: URL(string: "aerocheck://start-flight?aircraft=\(item.key)")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "airplane.departure")
                            .font(.system(size: 11, weight: .semibold))
                            .widgetAccentable()
                        Text(item.registration)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
        }
        // Required since iOS 17 even for accessory families; the Lock Screen/StandBy chrome comes
        // from the system regardless, so this is just satisfying the unified container-background API.
        .containerBackground(for: .widget) { Color.clear }
    }
}

// MARK: - Widget Configuration

struct AeroCheckWidget: Widget {
    let kind: String = "AeroCheckWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AeroCheckProvider()) { entry in
            AeroCheckWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("AéroCheck")
        .description("Quickly start a flight or view your flight log.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct AeroCheckWidgetEntryView: View {
    var entry: AeroCheckProvider.Entry

    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(aircraft: entry.aircraft)
        case .systemMedium:
            MediumWidgetView(aircraft: entry.aircraft)
        case .accessoryCircular:
            CircularWidgetView(aircraft: entry.aircraft)
        case .accessoryRectangular:
            RectangularWidgetView(aircraft: entry.aircraft)
        default:
            SmallWidgetView(aircraft: entry.aircraft)
        }
    }
}

// MARK: - Widget Bundle

@main
struct AeroCheckWidgetBundle: WidgetBundle {
    var body: some Widget {
        AeroCheckWidget()
        #if canImport(ActivityKit)
        FlightLiveActivity()
        #endif
    }
}

// MARK: - Previews

#Preview("Small - Dark", as: .systemSmall) {
    AeroCheckWidget()
} timeline: {
    AeroCheckEntry(date: .now, aircraft: [
        WidgetAircraft(key: "wt9-dynamic", registration: "F-HVXA"),
        WidgetAircraft(key: "pa28-181", registration: "HB-PFA")
    ])
}

#Preview("Medium - Dark", as: .systemMedium) {
    AeroCheckWidget()
} timeline: {
    AeroCheckEntry(date: .now, aircraft: [
        WidgetAircraft(key: "wt9-dynamic", registration: "F-HVXA")
    ])
}

#Preview("Lock Screen - Circular", as: .accessoryCircular) {
    AeroCheckWidget()
} timeline: {
    AeroCheckEntry(date: .now, aircraft: [
        WidgetAircraft(key: "wt9-dynamic", registration: "F-HVXA")
    ])
}

#Preview("Lock Screen - Rectangular", as: .accessoryRectangular) {
    AeroCheckWidget()
} timeline: {
    AeroCheckEntry(date: .now, aircraft: [
        WidgetAircraft(key: "wt9-dynamic", registration: "F-HVXA"),
        WidgetAircraft(key: "pa28-181", registration: "HB-PFA")
    ])
}
