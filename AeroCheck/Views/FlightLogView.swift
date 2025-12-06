import SwiftUI
import MapKit
import Charts
import UniformTypeIdentifiers

/// Flight log view showing all recorded flights
struct FlightLogView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var selectedFlight: Flight?
    @State private var showImportPicker = false
    @State private var importError: String?
    @State private var showImportError = false
    @State private var showExportAllOptions = false
    @State private var showExportAllSheet = false
    @State private var exportAllType: ExportAllType = .gpx
    
    enum ExportAllType {
        case gpx
        case json
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.cockpitBackground
                    .ignoresSafeArea()
                
                if appState.flights.isEmpty {
                    emptyState
                } else {
                    flightList
                }
            }
            .navigationTitle("Flight Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                
                ToolbarItemGroup(placement: .primaryAction) {
                    if !appState.flights.isEmpty {
                        Button(action: { showExportAllOptions = true }) {
                            Image(systemName: "square.and.arrow.up.on.square")
                        }
                    }
                    
                    Button(action: { showImportPicker = true }) {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $selectedFlight) { flight in
            FlightDetailView(flight: flight)
        }
        .confirmationDialog("Export All Flights", isPresented: $showExportAllOptions, titleVisibility: .visible) {
            Button("GPX Files (.zip)") {
                exportAllType = .gpx
                showExportAllSheet = true
            }
            Button("JSON Files (.zip)") {
                exportAllType = .json
                showExportAllSheet = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Export all \(appState.flights.count) flights as a ZIP archive")
        }
        .sheet(isPresented: $showExportAllSheet) {
            if let zipData = createExportAllZip() {
                let filename = "AeroCheck_Flights_\(formattedExportDate).\(exportAllType == .gpx ? "gpx" : "json").zip"
                ShareSheet(activityItems: [
                    ZIPFile(data: zipData, filename: filename)
                ])
            }
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [
                UTType(filenameExtension: "gpx") ?? .xml,
                UTType(filenameExtension: "json") ?? .json
            ],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert("Import Error", isPresented: $showImportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(importError ?? "Unknown error")
        }
    }
    
    private var formattedExportDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
    
    private func createExportAllZip() -> Data? {
        var zipEntries: [(filename: String, data: Data)] = []

        for flight in appState.flights {
            switch exportAllType {
            case .gpx:
                if let data = flight.toGPX().data(using: .utf8) {
                    zipEntries.append((filename: "\(flight.exportFilename).gpx", data: data))
                }
            case .json:
                if let data = flight.toJSON() {
                    zipEntries.append((filename: "\(flight.exportFilename).json", data: data))
                }
            }
        }

        return createSimpleZip(entries: zipEntries)
    }
    
    /// Create a simple ZIP file from entries (basic implementation)
    private func createSimpleZip(entries: [(filename: String, data: Data)]) -> Data? {
        var zipData = Data()
        var centralDirectory = Data()
        var centralDirectoryOffset: UInt32 = 0
        
        for entry in entries {
            let localHeaderOffset = UInt32(zipData.count)
            
            // Local file header
            var localHeader = Data()
            localHeader.append(contentsOf: [0x50, 0x4B, 0x03, 0x04]) // Signature
            localHeader.append(contentsOf: [0x14, 0x00]) // Version needed
            localHeader.append(contentsOf: [0x00, 0x00]) // Flags
            localHeader.append(contentsOf: [0x00, 0x00]) // Compression (none)
            localHeader.append(contentsOf: [0x00, 0x00]) // Mod time
            localHeader.append(contentsOf: [0x00, 0x00]) // Mod date
            
            // CRC-32
            let crc = crc32(entry.data)
            localHeader.append(contentsOf: withUnsafeBytes(of: crc.littleEndian) { Array($0) })
            
            // Compressed and uncompressed size
            let size = UInt32(entry.data.count)
            localHeader.append(contentsOf: withUnsafeBytes(of: size.littleEndian) { Array($0) })
            localHeader.append(contentsOf: withUnsafeBytes(of: size.littleEndian) { Array($0) })
            
            // Filename length
            let filenameData = entry.filename.data(using: .utf8) ?? Data()
            let filenameLen = UInt16(filenameData.count)
            localHeader.append(contentsOf: withUnsafeBytes(of: filenameLen.littleEndian) { Array($0) })
            
            // Extra field length
            localHeader.append(contentsOf: [0x00, 0x00])
            
            // Filename
            localHeader.append(filenameData)
            
            zipData.append(localHeader)
            zipData.append(entry.data)
            
            // Central directory entry
            var cdEntry = Data()
            cdEntry.append(contentsOf: [0x50, 0x4B, 0x01, 0x02]) // Signature
            cdEntry.append(contentsOf: [0x14, 0x00]) // Version made by
            cdEntry.append(contentsOf: [0x14, 0x00]) // Version needed
            cdEntry.append(contentsOf: [0x00, 0x00]) // Flags
            cdEntry.append(contentsOf: [0x00, 0x00]) // Compression
            cdEntry.append(contentsOf: [0x00, 0x00]) // Mod time
            cdEntry.append(contentsOf: [0x00, 0x00]) // Mod date
            cdEntry.append(contentsOf: withUnsafeBytes(of: crc.littleEndian) { Array($0) })
            cdEntry.append(contentsOf: withUnsafeBytes(of: size.littleEndian) { Array($0) })
            cdEntry.append(contentsOf: withUnsafeBytes(of: size.littleEndian) { Array($0) })
            cdEntry.append(contentsOf: withUnsafeBytes(of: filenameLen.littleEndian) { Array($0) })
            cdEntry.append(contentsOf: [0x00, 0x00]) // Extra field length
            cdEntry.append(contentsOf: [0x00, 0x00]) // Comment length
            cdEntry.append(contentsOf: [0x00, 0x00]) // Disk number start
            cdEntry.append(contentsOf: [0x00, 0x00]) // Internal attributes
            cdEntry.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // External attributes
            cdEntry.append(contentsOf: withUnsafeBytes(of: localHeaderOffset.littleEndian) { Array($0) })
            cdEntry.append(filenameData)
            
            centralDirectory.append(cdEntry)
        }
        
        centralDirectoryOffset = UInt32(zipData.count)
        zipData.append(centralDirectory)
        
        // End of central directory
        var eocd = Data()
        eocd.append(contentsOf: [0x50, 0x4B, 0x05, 0x06]) // Signature
        eocd.append(contentsOf: [0x00, 0x00]) // Disk number
        eocd.append(contentsOf: [0x00, 0x00]) // Disk with CD
        let entryCount = UInt16(entries.count)
        eocd.append(contentsOf: withUnsafeBytes(of: entryCount.littleEndian) { Array($0) })
        eocd.append(contentsOf: withUnsafeBytes(of: entryCount.littleEndian) { Array($0) })
        let cdSize = UInt32(centralDirectory.count)
        eocd.append(contentsOf: withUnsafeBytes(of: cdSize.littleEndian) { Array($0) })
        eocd.append(contentsOf: withUnsafeBytes(of: centralDirectoryOffset.littleEndian) { Array($0) })
        eocd.append(contentsOf: [0x00, 0x00]) // Comment length
        
        zipData.append(eocd)
        
        return zipData
    }
    
    /// Simple CRC-32 calculation
    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 != 0 ? 0xEDB88320 : 0)
            }
        }
        return ~crc
    }
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "airplane.circle")
                .font(.system(size: 80))
                .foregroundColor(.dimText)
            
            Text("No Flights Recorded")
                .font(.headerText)
                .foregroundColor(.primaryText)
            
            Text("Start a flight to begin recording.\nYour flights will appear here.")
                .font(.bodyText)
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)
            
            Button(action: { showImportPicker = true }) {
                HStack {
                    Image(systemName: "square.and.arrow.down")
                    Text("Import Flight")
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .padding(.top, 16)
        }
        .padding(40)
    }
    
    // MARK: - Flight List
    
    private var flightList: some View {
        List {
            ForEach(appState.flights) { flight in
                FlightRowView(flight: flight)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedFlight = flight
                    }
                    .listRowBackground(Color.cardBackground)
            }
            .onDelete { indexSet in
                appState.deleteFlight(at: indexSet)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
    
    // MARK: - Import Handler
    
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            
            guard url.startAccessingSecurityScopedResource() else {
                importError = "Cannot access the selected file."
                showImportError = true
                return
            }
            
            defer { url.stopAccessingSecurityScopedResource() }
            
            do {
                let data = try Data(contentsOf: url)
                if appState.importFlight(from: data) {
                    // Success - no action needed
                } else {
                    importError = "Could not parse the flight file. Supported formats: GPX, JSON"
                    showImportError = true
                }
            } catch {
                importError = error.localizedDescription
                showImportError = true
            }
            
        case .failure(let error):
            importError = error.localizedDescription
            showImportError = true
        }
    }
}

// MARK: - Flight Row View

struct FlightRowView: View {
    let flight: Flight
    
    var body: some View {
        HStack(spacing: 16) {
            // Date indicator
            VStack(spacing: 4) {
                Text(dayString)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(.aviationGold)
                Text(monthString)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondaryText)
                    .textCase(.uppercase)
            }
            .frame(width: 50)
            
            // Flight info
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(flight.displayName)
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(.primaryText)
                    
                    Spacer()
                    
                    Text(flight.formattedDuration)
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .foregroundColor(.aviationGreen)
                }
                
                HStack(spacing: 16) {
                    Label(flight.formattedDistance, systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill")
                        .font(.captionText)
                        .foregroundColor(.secondaryText)
                    
                    Label("\(flight.gpsTrack.count) pts", systemImage: "location.fill")
                        .font(.captionText)
                        .foregroundColor(.secondaryText)
                    
                    if let startTime = flight.startTime {
                        Text(timeString(from: startTime))
                            .font(.captionText)
                            .foregroundColor(.secondaryText)
                    }
                }
            }
            
            Image(systemName: "chevron.right")
                .font(.system(size: 14))
                .foregroundColor(.dimText)
        }
        .padding(.vertical, 8)
    }
    
    private var dayString: String {
        guard let date = flight.startTime else { return "--" }
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: date)
    }
    
    private var monthString: String {
        guard let date = flight.startTime else { return "---" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter.string(from: date)
    }
    
    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Flight Detail View

struct FlightDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    let flight: Flight
    
    @State private var flightName: String = ""
    @State private var notes: String = ""
    @State private var showExportSheet = false
    @State private var showDeleteAlert = false
    @State private var showExportOptions = false
    @State private var exportType: ExportType = .gpx
    
    enum ExportType {
        case gpx
        case json
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Map
                    mapSection

                    // Altitude graph
                    altitudeGraphSection

                    // Flight details
                    detailsSection

                    // Notes
                    notesSection

                    // Actions
                    actionsSection
                }
                .padding(24)
            }
            .background(Color.cockpitBackground)
            .navigationTitle(flight.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            flightName = flight.name
            notes = flight.notes
        }
        .confirmationDialog("Export Format", isPresented: $showExportOptions, titleVisibility: .visible) {
            Button("GPX (GPS Track)") {
                exportType = .gpx
                showExportSheet = true
            }
            Button("JSON (Full Data)") {
                exportType = .json
                showExportSheet = true
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Choose export format. JSON includes all flight times and data.")
        }
        .sheet(isPresented: $showExportSheet) {
            switch exportType {
            case .gpx:
                if let gpxData = flight.toGPX().data(using: .utf8) {
                    ShareSheet(activityItems: [
                        GPXFile(data: gpxData, filename: "\(flight.exportFilename).gpx")
                    ])
                }
            case .json:
                if let jsonData = flight.toJSON() {
                    ShareSheet(activityItems: [
                        JSONFile(data: jsonData, filename: "\(flight.exportFilename).json")
                    ])
                }
            }
        }
        .alert("Delete Flight?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                appState.deleteFlight(flight)
                dismiss()
            }
        } message: {
            Text("This action cannot be undone.")
        }
    }
    
    // MARK: - Map Section
    
    private var mapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FLIGHT TRACK")
                .font(.captionText)
                .foregroundColor(.secondaryText)
            
            if flight.gpsTrack.isEmpty {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.cardBackground)
                    .frame(height: 300)
                    .overlay(
                        VStack(spacing: 12) {
                            Image(systemName: "map")
                                .font(.system(size: 40))
                                .foregroundColor(.dimText)
                            Text("No GPS data recorded")
                                .font(.bodyText)
                                .foregroundColor(.dimText)
                        }
                    )
            } else {
                FlightMapView(points: flight.gpsTrack)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Altitude Graph Section

    private var altitudeGraphSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ALTITUDE PROFILE")
                .font(.captionText)
                .foregroundColor(.secondaryText)

            if flight.gpsTrack.isEmpty {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.cardBackground)
                    .frame(height: 200)
                    .overlay(
                        VStack(spacing: 12) {
                            Image(systemName: "chart.xyaxis.line")
                                .font(.system(size: 40))
                                .foregroundColor(.dimText)
                            Text("No altitude data recorded")
                                .font(.bodyText)
                                .foregroundColor(.dimText)
                        }
                    )
            } else {
                AltitudeChartView(
                    gpsTrack: flight.gpsTrack,
                    engineStartTime: flight.engineStartTime,
                    lineUpTime: flight.lineUpTime,
                    landingTime: flight.landingTime,
                    engineShutdownTime: flight.engineShutdownTime,
                    goAroundCount: flight.goAroundCount,
                    touchAndGoCount: flight.touchAndGoCount
                )
                .frame(height: 200)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.cardBackground)
                )
            }
        }
    }

    // MARK: - Details Section

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("FLIGHT DETAILS")
                .font(.captionText)
                .foregroundColor(.secondaryText)

            VStack(spacing: 12) {
                DetailRow(label: "Aircraft", value: flight.airplane, icon: "airplane")
                DetailRow(label: "Date", value: flight.formattedDate, icon: "calendar")
                DetailRow(label: "Flight Time", value: flight.formattedDuration, icon: "clock.fill")
                DetailRow(label: "Distance", value: flight.formattedDistance, icon: "point.topleft.down.to.point.bottomright.curvepath.fill")
                DetailRow(label: "GPS Points", value: "\(flight.gpsTrack.count)", icon: "location.fill")
                if flight.goAroundCount > 0 {
                    DetailRow(label: "Go Arounds", value: "\(flight.goAroundCount)", icon: "arrow.up.right.circle.fill")
                }
                if flight.touchAndGoCount > 0 {
                    DetailRow(label: "Touch-and-goes", value: "\(flight.touchAndGoCount)", icon: "arrow.triangle.2.circlepath")
                }
            }
            .cardStyle()

            // Chronological times
            Text("FLIGHT TIMES")
                .font(.captionText)
                .foregroundColor(.secondaryText)
                .padding(.top, 8)

            VStack(spacing: 12) {
                if let start = flight.startTime {
                    TimelineRow(label: "Session Start", time: timeString(from: start), icon: "play.fill", color: .dimText)
                }

                if let engineStart = flight.engineStartTime {
                    TimelineRow(label: "Engine Start", time: timeString(from: engineStart), icon: "engine.combustion", color: .aviationGreen)
                }

                if let lineUp = flight.lineUpTime {
                    TimelineRow(label: "Take-off", time: timeString(from: lineUp), icon: "airplane.departure", color: .aviationAmber)
                }

                if let landing = flight.landingTime {
                    TimelineRow(label: "Landing", time: timeString(from: landing), icon: "airplane.arrival", color: .aviationBlue)
                }

                if let shutdown = flight.engineShutdownTime {
                    TimelineRow(label: "Engine Shutdown", time: timeString(from: shutdown), icon: "engine.combustion.fill", color: .aviationRed)
                }

                if let stop = flight.stopTime {
                    TimelineRow(label: "Session End", time: timeString(from: stop), icon: "stop.fill", color: .dimText)
                }
            }
            .cardStyle()

            // Flight Name editing (moved to be between FLIGHT TIMES and NOTES)
            Text("FLIGHT NAME")
                .font(.captionText)
                .foregroundColor(.secondaryText)
                .padding(.top, 8)

            TextField("Enter flight name (e.g., Circuits 2)", text: $flightName)
                .font(.bodyText)
                .foregroundColor(.primaryText)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.cardBackground)
                )
                .onChange(of: flightName) { _, newValue in
                    appState.updateFlightName(flight, name: newValue)
                }
        }
    }
    
    // MARK: - Notes Section
    
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Notes
            Text("NOTES")
                .font(.captionText)
                .foregroundColor(.secondaryText)
            
            TextEditor(text: $notes)
                .font(.bodyText)
                .foregroundColor(.primaryText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 100)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.cardBackground)
                )
                .onChange(of: notes) { _, newValue in
                    appState.updateFlightNotes(flight, notes: newValue)
                }
        }
    }
    
    // MARK: - Actions Section
    
    private var actionsSection: some View {
        HStack(spacing: 16) {
            Button(action: { showExportOptions = true }) {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("Export")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            
            Button(action: { showDeleteAlert = true }) {
                HStack {
                    Image(systemName: "trash")
                    Text("Delete")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionButtonStyle(color: .aviationRed))
        }
    }
    
    // MARK: - Helpers
    
    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Detail Row

struct DetailRow: View {
    let label: String
    let value: String
    let icon: String
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.aviationGold)
                .frame(width: 24)
            
            Text(label)
                .font(.bodyText)
                .foregroundColor(.secondaryText)
            
            Spacer()
            
            Text(value)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundColor(.primaryText)
        }
    }
}

// MARK: - Timeline Row

struct TimelineRow: View {
    let label: String
    let time: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack {
            // Timeline indicator
            VStack(spacing: 0) {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
            }
            .frame(width: 24)
            
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 24)
            
            Text(label)
                .font(.bodyText)
                .foregroundColor(.secondaryText)
            
            Spacer()
            
            Text(time)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundColor(.primaryText)
        }
    }
}

// MARK: - Flight Map View with Polyline

struct FlightMapView: UIViewRepresentable {
    let points: [GPSPoint]
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.overrideUserInterfaceStyle = .dark
        return mapView
    }
    
    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Remove existing overlays and annotations
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)
        
        guard points.count >= 2 else { return }
        
        // Create coordinates array
        let coordinates = points.map { $0.coordinate }
        
        // Add polyline
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        mapView.addOverlay(polyline)
        
        // Add start and end annotations
        if let first = points.first, let last = points.last {
            let startAnnotation = FlightAnnotation(coordinate: first.coordinate, title: "Start", isStart: true)
            let endAnnotation = FlightAnnotation(coordinate: last.coordinate, title: "End", isStart: false)
            mapView.addAnnotations([startAnnotation, endAnnotation])
        }
        
        // Set visible region
        let rect = polyline.boundingMapRect
        let padding = UIEdgeInsets(top: 50, left: 50, bottom: 50, right: 50)
        mapView.setVisibleMapRect(rect, edgePadding: padding, animated: false)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor(Color.aviationGold)
                renderer.lineWidth = 4
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let flightAnnotation = annotation as? FlightAnnotation else { return nil }
            
            let identifier = flightAnnotation.isStart ? "start" : "end"
            var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
            
            if view == nil {
                view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            }
            
            view?.annotation = annotation
            view?.markerTintColor = flightAnnotation.isStart ? UIColor(Color.aviationGreen) : UIColor(Color.aviationRed)
            view?.glyphImage = UIImage(systemName: flightAnnotation.isStart ? "airplane.departure" : "airplane.arrival")
            view?.displayPriority = .required
            
            return view
        }
    }
}

class FlightAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let isStart: Bool

    init(coordinate: CLLocationCoordinate2D, title: String, isStart: Bool) {
        self.coordinate = coordinate
        self.title = title
        self.isStart = isStart
        super.init()
    }
}

// MARK: - Altitude Chart View

struct AltitudeChartView: View {
    let gpsTrack: [GPSPoint]
    let engineStartTime: Date?
    let lineUpTime: Date?
    let landingTime: Date?
    let engineShutdownTime: Date?
    let goAroundCount: Int
    let touchAndGoCount: Int

    /// Altitude data points for the chart
    private var altitudeData: [(time: Date, altitude: Double)] {
        gpsTrack.map { (time: $0.timestamp, altitude: $0.altitude * 3.28084) } // Convert to feet
    }

    /// Flight event annotations to display on the chart
    private var eventAnnotations: [(time: Date, label: String, color: Color)] {
        var annotations: [(time: Date, label: String, color: Color)] = []

        if let engineStart = engineStartTime {
            annotations.append((time: engineStart, label: "Engine Start", color: .aviationGreen))
        }
        if let lineUp = lineUpTime {
            annotations.append((time: lineUp, label: "Take-off", color: .aviationAmber))
        }
        if let landing = landingTime {
            annotations.append((time: landing, label: "Landing", color: .aviationBlue))
        }
        if let shutdown = engineShutdownTime {
            annotations.append((time: shutdown, label: "Shutdown", color: .aviationRed))
        }

        return annotations
    }

    var body: some View {
        if altitudeData.isEmpty {
            Text("No altitude data")
                .font(.captionText)
                .foregroundColor(.dimText)
        } else {
            Chart {
                // Altitude line
                ForEach(altitudeData, id: \.time) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Altitude", point.altitude)
                    )
                    .foregroundStyle(Color.altimeterBlue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }

                // Area fill under the line
                ForEach(altitudeData, id: \.time) { point in
                    AreaMark(
                        x: .value("Time", point.time),
                        y: .value("Altitude", point.altitude)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.altimeterBlue.opacity(0.3), Color.altimeterBlue.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }

                // Event annotations
                ForEach(eventAnnotations, id: \.time) { event in
                    RuleMark(x: .value("Event", event.time))
                        .foregroundStyle(event.color.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))
                        .annotation(position: .top, alignment: .center) {
                            Text(event.label)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(event.color)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.cardBackground)
                                )
                        }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.dimText.opacity(0.3))
                    AxisValueLabel()
                        .foregroundStyle(Color.secondaryText)
                        .font(.system(size: 10))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.dimText.opacity(0.3))
                    AxisValueLabel {
                        if let altitude = value.as(Double.self) {
                            Text("\(Int(altitude)) ft")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.secondaryText)
                        }
                    }
                }
            }
            .chartYAxisLabel(position: .leading, alignment: .center) {
                Text("Altitude (ft MSL)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.secondaryText)
            }
        }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - GPX File for Sharing

class GPXFile: NSObject, UIActivityItemSource {
    let data: Data
    let filename: String
    
    init(data: Data, filename: String) {
        self.data = data
        self.filename = filename
        super.init()
    }
    
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        return data
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        return data
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        return "com.topografix.gpx"
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        return filename
    }
}

// MARK: - JSON File for Sharing

class JSONFile: NSObject, UIActivityItemSource {
    let data: Data
    let filename: String
    
    init(data: Data, filename: String) {
        self.data = data
        self.filename = filename
        super.init()
    }
    
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        return data
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        return data
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        return "public.json"
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        return filename
    }
}

// MARK: - ZIP File for Sharing

class ZIPFile: NSObject, UIActivityItemSource {
    let data: Data
    let filename: String
    
    init(data: Data, filename: String) {
        self.data = data
        self.filename = filename
        super.init()
    }
    
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        return data
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        return data
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        return "public.zip-archive"
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        return filename
    }
}

// MARK: - Preview

#Preview {
    FlightLogView()
        .environmentObject(AppState())
}
