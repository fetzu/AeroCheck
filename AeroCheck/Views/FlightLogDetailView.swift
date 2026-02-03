import SwiftUI
import MapKit

/// Detailed view of a recorded flight showing all timing, route, and event data
struct FlightLogDetailView: View {
    let flight: Flight
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            // Flight Header Section
            Section("Flight") {
                LabeledContent("Date", value: flight.formattedDate)
                LabeledContent("Aircraft", value: flight.displayName)
                if let aircraftType = flight.aircraftType {
                    LabeledContent("Type", value: aircraftType)
                }
                if let version = flight.checklistVersion {
                    LabeledContent("Checklist Version", value: version)
                }
            }

            // Route Section
            if flight.departureAirportIdent != nil || flight.arrivalAirportIdent != nil {
                Section("Route") {
                    if let dep = flight.departureAirportIdent {
                        LabeledContent("Departure", value: dep)
                    }
                    if let arr = flight.arrivalAirportIdent {
                        LabeledContent("Arrival", value: arr)
                    }
                    LabeledContent("Distance", value: flight.formattedDistance)
                }
            }

            // Times Section
            Section("Times") {
                if let blockOff = flight.blockOffTime {
                    LabeledContent("Block Off", value: formatTime(blockOff))
                }
                if let engineStart = flight.engineStartTime {
                    LabeledContent("Engine Start", value: formatTime(engineStart))
                }
                if let lineUp = flight.lineUpTime {
                    LabeledContent("Take-off", value: formatTime(lineUp))
                }
                if let landing = flight.landingTime {
                    LabeledContent("Landing", value: formatTime(landing))
                }
                if let engineStop = flight.engineShutdownTime {
                    LabeledContent("Engine Stop", value: formatTime(engineStop))
                }
                if let blockOn = flight.blockOnTime {
                    LabeledContent("Block On", value: formatTime(blockOn))
                }
            }

            // Durations Section
            Section("Durations") {
                if let blockTime = flight.blockTime {
                    LabeledContent("Block Time", value: formatDuration(blockTime))
                }
                if let flightTime = flight.flightTime {
                    LabeledContent("Flight Time", value: formatDuration(flightTime))
                }
                if let duration = flight.duration {
                    LabeledContent("Engine Time", value: formatDuration(duration))
                }
            }

            // Engine Hours Section (if logged)
            if flight.engineHourStart != nil || flight.engineHourEnd != nil {
                Section("Engine Hours") {
                    if let start = flight.engineHourStart {
                        LabeledContent("Hours Before", value: formatHours(start))
                    }
                    if let end = flight.engineHourEnd {
                        LabeledContent("Hours After", value: formatHours(end))
                    }
                    if let flown = flight.engineHoursFlown {
                        LabeledContent("Hours Flown", value: formatHours(flown))
                            .foregroundColor(.aviationGreen)
                    }
                }
            }

            // Events Section
            Section("Events") {
                LabeledContent("Go-arounds", value: "\(flight.goAroundCount)")
                LabeledContent("Touch-and-gos", value: "\(flight.touchAndGoCount)")
                LabeledContent("Full Stop Landings", value: "\(flight.fullStopCount)")
                LabeledContent("Total Landings", value: "\(flight.totalLandings)")
            }

            // Track Preview Section (if GPS track available)
            if !flight.gpsTrack.isEmpty {
                Section("Track") {
                    TrackPreviewView(flight: flight)
                        .frame(height: 200)
                        .listRowInsets(EdgeInsets())
                }
            }

            // Notes Section
            if !flight.notes.isEmpty {
                Section("Notes") {
                    Text(flight.notes)
                        .font(.body)
                        .foregroundColor(.primaryText)
                }
            }

            // Export Section
            Section {
                NavigationLink(destination: FlightExportView(flight: flight)) {
                    Label("Export Flight", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle("Flight Details")
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
                Annotation("Start", coordinate: first.coordinate) {
                    Circle()
                        .fill(.green)
                        .frame(width: 12, height: 12)
                }
            }

            // End marker
            if let last = flight.gpsTrack.last {
                Annotation("End", coordinate: last.coordinate) {
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
            Section("Export Format") {
                Button(action: { exportGPX() }) {
                    Label("Export as GPX", systemImage: "map")
                }

                Button(action: { exportJSON() }) {
                    Label("Export as JSON", systemImage: "doc.text")
                }

                Button(action: { exportZIP() }) {
                    Label("Export as ZIP (GPX + JSON)", systemImage: "doc.zipper")
                }
            }
        }
        .navigationTitle("Export")
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
