import SwiftUI
import MapKit

/// Detailed view of a recorded flight showing all timing, route, and event data
struct FlightLogDetailView: View {
    let flight: Flight
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            // Flight Header Section
            Section(L10n.FlightLogDetail.flightSection) {
                LabeledContent(L10n.FlightLogDetail.date, value: flight.formattedDate)
                LabeledContent(L10n.FlightLogDetail.aircraft, value: flight.displayName)
                if let aircraftType = flight.aircraftType {
                    LabeledContent(L10n.FlightLogDetail.type, value: aircraftType)
                }
                if let version = flight.checklistVersion {
                    LabeledContent(L10n.FlightLogDetail.checklistVersion, value: version)
                }
            }

            // Route Section
            if flight.departureAirportIdent != nil || flight.arrivalAirportIdent != nil {
                Section(L10n.FlightLogDetail.routeSection) {
                    if let dep = flight.departureAirportIdent {
                        LabeledContent(L10n.FlightLogDetail.departure, value: dep)
                    }
                    if let arr = flight.arrivalAirportIdent {
                        LabeledContent(L10n.FlightLogDetail.arrival, value: arr)
                    }
                    LabeledContent(L10n.FlightLogDetail.distance, value: flight.formattedDistance)
                }
            }

            // Times Section
            Section(L10n.FlightLogDetail.timesSection) {
                if let blockOff = flight.blockOffTime {
                    LabeledContent(L10n.FlightLogDetail.blockOff, value: formatTime(blockOff))
                }
                if let engineStart = flight.engineStartTime {
                    LabeledContent(L10n.FlightLogDetail.engineStart, value: formatTime(engineStart))
                }
                if let lineUp = flight.lineUpTime {
                    LabeledContent(L10n.FlightLogDetail.takeOff, value: formatTime(lineUp))
                }
                if let landing = flight.landingTime {
                    LabeledContent(L10n.FlightLogDetail.landing, value: formatTime(landing))
                }
                if let engineStop = flight.engineShutdownTime {
                    LabeledContent(L10n.FlightLogDetail.engineStop, value: formatTime(engineStop))
                }
                if let blockOn = flight.blockOnTime {
                    LabeledContent(L10n.FlightLogDetail.blockOn, value: formatTime(blockOn))
                }
            }

            // Durations Section
            Section(L10n.FlightLogDetail.durationsSection) {
                if let blockTime = flight.blockTime {
                    LabeledContent(L10n.FlightLogDetail.blockTime, value: formatDuration(blockTime))
                }
                if let flightTime = flight.flightTime {
                    LabeledContent(L10n.FlightLogDetail.flightTime, value: formatDuration(flightTime))
                }
                if let duration = flight.duration {
                    LabeledContent(L10n.FlightLogDetail.engineTime, value: formatDuration(duration))
                }
            }

            // Engine Hours Section (if logged)
            if flight.engineHourStart != nil || flight.engineHourEnd != nil {
                Section(L10n.FlightLogDetail.engineHoursSection) {
                    if let start = flight.engineHourStart {
                        LabeledContent(L10n.FlightLogDetail.hoursBefore, value: formatHours(start))
                    }
                    if let end = flight.engineHourEnd {
                        LabeledContent(L10n.FlightLogDetail.hoursAfter, value: formatHours(end))
                    }
                    if let flown = flight.engineHoursFlown {
                        LabeledContent(L10n.FlightLogDetail.hoursFlown, value: formatHours(flown))
                            .foregroundColor(.aviationGreen)
                    }
                }
            }

            // Events Section
            Section(L10n.FlightLogDetail.eventsSection) {
                LabeledContent(L10n.FlightLogDetail.goArounds, value: "\(flight.goAroundCount)")
                LabeledContent(L10n.FlightLogDetail.touchAndGos, value: "\(flight.touchAndGoCount)")
                LabeledContent(L10n.FlightLogDetail.fullStopLandings, value: "\(flight.fullStopCount)")
                LabeledContent(L10n.FlightLogDetail.totalLandings, value: "\(flight.totalLandings)")
            }

            // Track Preview Section (if GPS track available)
            if !flight.gpsTrack.isEmpty {
                Section(L10n.FlightLogDetail.trackSection) {
                    TrackPreviewView(flight: flight)
                        .frame(height: 200)
                        .listRowInsets(EdgeInsets())
                }
            }

            // Notes Section
            if !flight.notes.isEmpty {
                Section(L10n.FlightLogDetail.notesSection) {
                    Text(flight.notes)
                        .font(.body)
                        .foregroundColor(.primaryText)
                }
            }

            // Export Section
            Section {
                NavigationLink(destination: FlightExportView(flight: flight)) {
                    Label(L10n.FlightLogDetail.exportFlight, systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle(L10n.FlightLogDetail.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    // MARK: - Formatting Helpers

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        if appState.settings.alwaysUseUTC {
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.string(from: date) + " UTC"
        }
        return formatter.string(from: date)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        return String(format: "%d:%02d", hours, minutes)
    }

    private func formatHours(_ hours: Double) -> String {
        return String(format: "%.1f", hours)
    }
}

// MARK: - Track Preview Map

struct TrackPreviewView: View {
    let flight: Flight

    var body: some View {
        Map {
            // Draw the flight track as a polyline
            if flight.gpsTrack.count > 1 {
                MapPolyline(coordinates: flight.gpsTrack.map { $0.coordinate })
                    .stroke(.blue, lineWidth: 3)
            }

            // Start marker
            if let first = flight.gpsTrack.first {
                Annotation(L10n.FlightLogDetail.trackStart, coordinate: first.coordinate) {
                    Circle()
                        .fill(.green)
                        .frame(width: 12, height: 12)
                }
            }

            // End marker
            if let last = flight.gpsTrack.last {
                Annotation(L10n.FlightLogDetail.trackEnd, coordinate: last.coordinate) {
                    Circle()
                        .fill(.red)
                        .frame(width: 12, height: 12)
                }
            }
        }
        .mapStyle(.standard)
    }
}

// MARK: - Flight Export View (placeholder - connects to existing export functionality)

struct FlightExportView: View {
    let flight: Flight
    @State private var showShareSheet = false
    @State private var exportURL: URL?

    var body: some View {
        List {
            Section(L10n.FlightLogDetail.exportFormat) {
                Button(action: { exportGPX() }) {
                    Label(L10n.FlightLogDetail.exportGPX, systemImage: "map")
                }

                Button(action: { exportJSON() }) {
                    Label(L10n.FlightLogDetail.exportJSON, systemImage: "doc.text")
                }

                Button(action: { exportZIP() }) {
                    Label(L10n.FlightLogDetail.exportZIP, systemImage: "doc.zipper")
                }
            }
        }
        .navigationTitle(L10n.FlightLogDetail.exportTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShareSheet) {
            if let url = exportURL {
                ShareSheet(activityItems: [url])
            }
        }
    }

    private func exportGPX() {
        let gpxContent = flight.toGPX()
        if let url = saveToTemp(content: gpxContent, filename: "\(flight.exportFilename).gpx") {
            exportURL = url
            showShareSheet = true
        }
    }

    private func exportJSON() {
        if let jsonData = flight.toJSON(),
           let url = saveToTemp(data: jsonData, filename: "\(flight.exportFilename).json") {
            exportURL = url
            showShareSheet = true
        }
    }

    private func exportZIP() {
        // Create temp directory
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Write GPX
        let gpxURL = tempDir.appendingPathComponent("\(flight.exportFilename).gpx")
        try? flight.toGPX().write(to: gpxURL, atomically: true, encoding: .utf8)

        // Write JSON
        let jsonURL = tempDir.appendingPathComponent("\(flight.exportFilename).json")
        try? flight.toJSON()?.write(to: jsonURL)

        // Create ZIP
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(flight.exportFilename).zip")
        try? FileManager.default.removeItem(at: zipURL) // Remove if exists

        // Use Archive to create ZIP (simplified - in production use ZIPFoundation or similar)
        let coordinator = NSFileCoordinator()
        var error: NSError?
        coordinator.coordinate(readingItemAt: tempDir, options: .forUploading, error: &error) { url in
            try? FileManager.default.copyItem(at: url, to: zipURL)
        }

        if FileManager.default.fileExists(atPath: zipURL.path) {
            exportURL = zipURL
            showShareSheet = true
        }

        // Cleanup temp directory
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func saveToTemp(content: String, filename: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("[AeroCheck] Failed to save file: \(error)")
            return nil
        }
    }

    private func saveToTemp(data: Data, filename: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url)
            return url
        } catch {
            print("[AeroCheck] Failed to save file: \(error)")
            return nil
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationView {
        FlightLogDetailView(flight: Flight(
            name: "Test Flight",
            airplane: "wt9-dynamic",
            aircraftRegistration: "F-HVXA",
            aircraftType: "WT9",
            startTime: Date().addingTimeInterval(-3600),
            stopTime: Date(),
            engineStartTime: Date().addingTimeInterval(-3500),
            lineUpTime: Date().addingTimeInterval(-3400),
            landingTime: Date().addingTimeInterval(-600),
            engineShutdownTime: Date().addingTimeInterval(-300),
            blockOffTime: Date().addingTimeInterval(-3450),
            blockOnTime: Date().addingTimeInterval(-350),
            departureAirportIdent: "LSZH",
            arrivalAirportIdent: "LSZH",
            engineHourStart: 1234.5,
            engineHourEnd: 1235.3,
            goAroundCount: 1,
            touchAndGoCount: 2
        ))
        .environmentObject(AppState())
    }
}
