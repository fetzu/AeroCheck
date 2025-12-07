import WidgetKit
import SwiftUI

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
    var body: some View {
        VStack(spacing: 8) {
            // Header
            HStack {
                Image(systemName: "airplane")
                    .font(.system(size: 14, weight: .semibold))
                Text("AéroCheck")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.secondary)

            Spacer()

            // Aircraft buttons
            HStack(spacing: 12) {
                AircraftButton(
                    aircraft: "F-HVXA",
                    color: .blue
                )

                AircraftButton(
                    aircraft: "HB-PFA",
                    color: .orange
                )
            }

            Spacer()
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct MediumWidgetView: View {
    var body: some View {
        HStack(spacing: 16) {
            // Aircraft buttons section
            VStack(spacing: 8) {
                Text("Start Flight")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    AircraftButton(
                        aircraft: "F-HVXA",
                        color: .blue
                    )

                    AircraftButton(
                        aircraft: "HB-PFA",
                        color: .orange
                    )
                }
            }
            .frame(maxWidth: .infinity)

            Divider()
                .frame(height: 60)

            // Flight Log button section
            VStack(spacing: 8) {
                Text("View History")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                Link(destination: URL(string: "aerocheck://flight-log")!) {
                    VStack(spacing: 4) {
                        Image(systemName: "book.closed.fill")
                            .font(.system(size: 24))
                        Text("Flight Log")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(width: 70, height: 70)
                    .background(Color.green.opacity(0.2))
                    .foregroundStyle(.green)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct AircraftButton: View {
    let aircraft: String
    let color: Color

    var body: some View {
        Link(destination: URL(string: "aerocheck://start-flight?aircraft=\(aircraft)")!) {
            VStack(spacing: 4) {
                Image(systemName: "airplane")
                    .font(.system(size: 20))
                Text(aircraft)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 60, height: 60)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
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

#Preview("Small", as: .systemSmall) {
    AeroCheckWidget()
} timeline: {
    AeroCheckEntry(date: .now)
}

#Preview("Medium", as: .systemMedium) {
    AeroCheckWidget()
} timeline: {
    AeroCheckEntry(date: .now)
}
