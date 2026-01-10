import WidgetKit
import SwiftUI

// MARK: - Aviation Theme Colors
// NOTE: These colors are duplicated from AeroCheck/Components/DesignSystem.swift
// Keep in sync with the main app's color definitions.
// Widget extensions cannot share code with the main app without a shared framework.

extension Color {
    // Primary colors - Aviation inspired (source: DesignSystem.swift)
    static let aviationGold = Color(red: 0.85, green: 0.65, blue: 0.2)
    static let aviationGreen = Color(red: 0.2, green: 0.7, blue: 0.3)
    static let aviationBlue = Color(red: 0.1, green: 0.2, blue: 0.4)

    // Background colors for dark mode (source: DesignSystem.swift)
    static let cockpitBackground = Color(red: 0.08, green: 0.08, blue: 0.1)
    static let panelBackground = Color(red: 0.12, green: 0.12, blue: 0.15)
    static let cardBackground = Color(red: 0.15, green: 0.15, blue: 0.18)
}

// MARK: - Widget Timeline Entry

struct AeroCheckEntry: TimelineEntry {
    let date: Date
}

// MARK: - Widget Timeline Provider

struct AeroCheckProvider: TimelineProvider {
    func placeholder(in context: Context) -> AeroCheckEntry {
        AeroCheckEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (AeroCheckEntry) -> Void) {
        completion(AeroCheckEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AeroCheckEntry>) -> Void) {
        // Static widget - no need to update frequently
        let entry = AeroCheckEntry(date: Date())
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

// MARK: - Widget Views

struct SmallWidgetView: View {
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

            // Aircraft buttons
            HStack(spacing: 12) {
                AircraftButton(
                    aircraft: "F-HVXA",
                    accentColor: .aviationBlue
                )

                AircraftButton(
                    aircraft: "HB-PFA",
                    accentColor: .aviationGold
                )
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
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 16) {
            // Aircraft buttons section
            VStack(spacing: 8) {
                Text("Start Flight")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(labelColor)

                HStack(spacing: 12) {
                    AircraftButton(
                        aircraft: "F-HVXA",
                        accentColor: .aviationBlue
                    )

                    AircraftButton(
                        aircraft: "HB-PFA",
                        accentColor: .aviationGold
                    )
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

struct AircraftButton: View {
    let aircraft: String
    let accentColor: Color

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Link(destination: URL(string: "aerocheck://start-flight?aircraft=\(aircraft)")!) {
            VStack(spacing: 4) {
                Image(systemName: "airplane")
                    .font(.system(size: 20))
                Text(aircraft)
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
            SmallWidgetView()
        case .systemMedium:
            MediumWidgetView()
        default:
            SmallWidgetView()
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
    AeroCheckEntry(date: .now)
}

#Preview("Medium - Dark", as: .systemMedium) {
    AeroCheckWidget()
} timeline: {
    AeroCheckEntry(date: .now)
}
