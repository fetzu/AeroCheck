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

    var body: some View {
        VStack(spacing: 8) {
            // Header with aviation gold accent
            HStack(spacing: 6) {
                Image(systemName: "airplane")
                    .font(.system(size: 14, weight: .semibold))
                Text("AéroCheck")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(Color.aviationGold)

            Spacer()

            // Aircraft buttons — only the aircraft the user owns
            HStack(spacing: 12) {
                ForEach(Array(aircraft.prefix(2)), id: \.key) { item in
                    AircraftButton(aircraft: item, accentColor: aircraftAccentColor(for: item))
                }
            }

            Spacer()
        }
        .padding()
        .containerBackground(for: .widget) {
            containerBackgroundView
        }
    }

    @ViewBuilder
    private var containerBackgroundView: some View {
        if colorScheme == .dark {
            Color.cockpitBackground
        } else {
            Color(white: 0.95)
        }
    }
}

struct MediumWidgetView: View {
    let aircraft: [WidgetAircraft]
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 16) {
            // Aircraft buttons section
            VStack(spacing: 8) {
                Text("Start Flight")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(labelColor)

                HStack(spacing: 12) {
                    ForEach(Array(aircraft.prefix(2)), id: \.key) { item in
                        AircraftButton(aircraft: item, accentColor: aircraftAccentColor(for: item))
                    }
                }
            }
            .frame(maxWidth: .infinity)

            // Divider with aviation styling
            Rectangle()
                .fill(Color.aviationGold.opacity(0.3))
                .frame(width: 1, height: 60)

            // Flight Log button section
            VStack(spacing: 8) {
                Text("History")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(labelColor)

                Link(destination: URL(string: "aerocheck://flight-log")!) {
                    VStack(spacing: 4) {
                        Image(systemName: "book.closed.fill")
                            .font(.system(size: 24))
                        Text("Flight Log")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(width: 70, height: 70)
                    .background(buttonBackground(for: .aviationGreen))
                    .foregroundStyle(Color.aviationGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding()
        .containerBackground(for: .widget) {
            containerBackgroundView
        }
    }

    private var labelColor: Color {
        colorScheme == .dark ? Color(white: 0.6) : Color(white: 0.4)
    }

    private func buttonBackground(for color: Color) -> Color {
        colorScheme == .dark ? color.opacity(0.2) : color.opacity(0.15)
    }

    @ViewBuilder
    private var containerBackgroundView: some View {
        if colorScheme == .dark {
            Color.cockpitBackground
        } else {
            Color(white: 0.95)
        }
    }
}

/// Accent colour for an aircraft button. The free bundled aircraft uses blue; premium aircraft
/// use the aviation gold accent.
private func aircraftAccentColor(for aircraft: WidgetAircraft) -> Color {
    aircraft.key == "wt9-dynamic" ? .aviationBlue : .aviationGold
}

struct AircraftButton: View {
    let aircraft: WidgetAircraft
    let accentColor: Color

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Link(destination: URL(string: "aerocheck://start-flight?aircraft=\(aircraft.key)")!) {
            VStack(spacing: 4) {
                Image(systemName: "airplane")
                    .font(.system(size: 20))
                Text(aircraft.registration)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 60, height: 60)
            .background(buttonBackground)
            .foregroundStyle(accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(accentColor.opacity(0.3), lineWidth: 1)
            )
        }
    }

    private var buttonBackground: Color {
        colorScheme == .dark ? accentColor.opacity(0.2) : accentColor.opacity(0.12)
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
        .supportedFamilies([.systemSmall, .systemMedium])
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
