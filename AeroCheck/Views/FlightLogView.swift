import SwiftUI
import MapKit
import Charts
import UniformTypeIdentifiers
import Compression

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
                let filename = "AeroCheck_\(formattedExportDate)_ExportBundle.zip"
                ShareSheet(activityItems: [
                    ZIPFile(data: zipData, filename: filename)
                ])
            }
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [
                UTType(filenameExtension: "gpx") ?? .xml,
                UTType(filenameExtension: "json") ?? .json,
                .zip
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
        formatter.dateFormat = "yyyyMMdd"
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

                // Check if it's a ZIP file
                if url.pathExtension.lowercased() == "zip" {
                    handleZipImport(data: data)
                } else if appState.importFlight(from: data) {
                    // Success - no action needed
                } else {
                    importError = "Could not parse the flight file. Supported formats: GPX, JSON, ZIP"
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

    private func handleZipImport(data: Data) {
        do {
            let entries = try extractZipEntries(from: data)
            var successCount = 0
            var failCount = 0

            for entry in entries {
                if appState.importFlight(from: entry.data) {
                    successCount += 1
                } else {
                    failCount += 1
                }
            }

            if successCount == 0 {
                importError = "No valid flight files found in the ZIP archive."
                showImportError = true
            } else if failCount > 0 {
                importError = "Imported \(successCount) flight(s). \(failCount) file(s) could not be imported."
                showImportError = true
            }
            // If all succeeded, no error message needed
        } catch {
            importError = "Failed to extract ZIP archive: \(error.localizedDescription)"
            showImportError = true
        }
    }

    private func extractZipEntries(from data: Data) throws -> [(filename: String, data: Data)] {
        var entries: [(filename: String, data: Data)] = []
        var offset = 0

        while offset < data.count {
            // Check for local file header signature (0x04034b50)
            guard offset + 30 <= data.count else { break }

            // Read signature using aligned access
            let signature: UInt32 = data.withUnsafeBytes { rawPtr in
                let bytes = rawPtr.bindMemory(to: UInt8.self)
                guard offset + 4 <= bytes.count else { return 0 }
                return UInt32(bytes[offset])
                    | (UInt32(bytes[offset + 1]) << 8)
                    | (UInt32(bytes[offset + 2]) << 16)
                    | (UInt32(bytes[offset + 3]) << 24)
            }

            // 0x04034b50 = local file header
            if signature != 0x04034b50 {
                // Check for central directory (0x02014b50) or end (0x06054b50)
                if signature == 0x02014b50 || signature == 0x06054b50 {
                    break
                }
                offset += 1
                continue
            }

            // Read header fields using aligned byte-by-byte access
            let compressionMethod: UInt16 = data.withUnsafeBytes { rawPtr in
                let bytes = rawPtr.bindMemory(to: UInt8.self)
                let pos = offset + 8
                return UInt16(bytes[pos]) | (UInt16(bytes[pos + 1]) << 8)
            }

            let compressedSize: UInt32 = data.withUnsafeBytes { rawPtr in
                let bytes = rawPtr.bindMemory(to: UInt8.self)
                let pos = offset + 18
                return UInt32(bytes[pos])
                    | (UInt32(bytes[pos + 1]) << 8)
                    | (UInt32(bytes[pos + 2]) << 16)
                    | (UInt32(bytes[pos + 3]) << 24)
            }

            let uncompressedSize: UInt32 = data.withUnsafeBytes { rawPtr in
                let bytes = rawPtr.bindMemory(to: UInt8.self)
                let pos = offset + 22
                return UInt32(bytes[pos])
                    | (UInt32(bytes[pos + 1]) << 8)
                    | (UInt32(bytes[pos + 2]) << 16)
                    | (UInt32(bytes[pos + 3]) << 24)
            }

            let filenameLength: UInt16 = data.withUnsafeBytes { rawPtr in
                let bytes = rawPtr.bindMemory(to: UInt8.self)
                let pos = offset + 26
                return UInt16(bytes[pos]) | (UInt16(bytes[pos + 1]) << 8)
            }

            let extraFieldLength: UInt16 = data.withUnsafeBytes { rawPtr in
                let bytes = rawPtr.bindMemory(to: UInt8.self)
                let pos = offset + 28
                return UInt16(bytes[pos]) | (UInt16(bytes[pos + 1]) << 8)
            }

            // Read filename
            let filenameStart = offset + 30
            let filenameEnd = filenameStart + Int(filenameLength)
            guard filenameEnd <= data.count else { break }

            let filenameData = data.subdata(in: filenameStart..<filenameEnd)
            let filename = String(data: filenameData, encoding: .utf8) ?? ""

            // Skip directories and hidden files
            if filename.hasSuffix("/") || filename.hasPrefix("__MACOSX/") || filename.contains("/.") {
                offset = filenameEnd + Int(extraFieldLength) + Int(compressedSize)
                continue
            }

            // Only process .gpx and .json files
            let ext = (filename as NSString).pathExtension.lowercased()
            guard ext == "gpx" || ext == "json" else {
                offset = filenameEnd + Int(extraFieldLength) + Int(compressedSize)
                continue
            }

            // Read file data
            let dataStart = filenameEnd + Int(extraFieldLength)
            let dataEnd = dataStart + Int(compressedSize)
            guard dataEnd <= data.count else { break }

            var fileData = data.subdata(in: dataStart..<dataEnd)

            // Handle compression (method 0 = uncompressed, method 8 = deflate)
            if compressionMethod == 8 {
                // Decompress using zlib
                fileData = try decompress(fileData, uncompressedSize: Int(uncompressedSize))
            }

            entries.append((filename: filename, data: fileData))
            offset = dataEnd
        }

        return entries
    }

    private func decompress(_ data: Data, uncompressedSize: Int) throws -> Data {
        // Use Swift's built-in decompression with DEFLATE algorithm
        let decompressedData = try (data as NSData).decompressed(using: .zlib) as Data
        return decompressedData
    }
}

// MARK: - Flight Row View

struct FlightRowView: View {
    @EnvironmentObject var appState: AppState
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
        if appState.settings.alwaysUseUTC {
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.string(from: date) + " (UTC)"
        }
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
    @State private var selectedTime: Date?
    @State private var showShareSheet = false
    @State private var shareImage: UIImage?
    @State private var isGeneratingImage = false

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
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { generateAndShareImage() }) {
                        if isGeneratingImage {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    .disabled(isGeneratingImage)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            flightName = flight.name
            notes = flight.notes
        }
        .sheet(isPresented: $showShareSheet, onDismiss: {
            shareImage = nil
        }) {
            if let image = shareImage {
                ImageShareSheet(image: image)
            }
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
                FlightMapView(points: flight.gpsTrack, selectedTime: selectedTime)
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
                    goAroundTimes: flight.goAroundTimes,
                    touchAndGoTimes: flight.touchAndGoTimes,
                    selectedTime: $selectedTime
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
        if appState.settings.alwaysUseUTC {
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.string(from: date) + " (UTC)"
        }
        return formatter.string(from: date)
    }

    private func generateAndShareImage() {
        isGeneratingImage = true

        Task {
            // First, generate map snapshot if we have GPS data
            let mapImage: UIImage? = await generateMapSnapshot()

            // Then render the share card on main thread
            await MainActor.run {
                let shareCard = FlightShareCard(flight: flight, mapImage: mapImage, useUTC: appState.settings.alwaysUseUTC)
                let renderer = ImageRenderer(content: shareCard)
                renderer.scale = 3.0 // High resolution for sharing

                if let image = renderer.uiImage {
                    shareImage = image
                    isGeneratingImage = false
                    showShareSheet = true
                } else {
                    isGeneratingImage = false
                }
            }
        }
    }

    private func generateMapSnapshot() async -> UIImage? {
        guard flight.gpsTrack.count >= 2 else { return nil }

        let coordinates = flight.gpsTrack.map { $0.coordinate }
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        let mapRect = polyline.boundingMapRect

        // Target size for the snapshot (matching card map dimensions at 3x scale)
        let targetWidth: CGFloat = 1000 * 3
        let targetHeight: CGFloat = 620 * 3
        let targetAspectRatio = targetWidth / targetHeight

        // Calculate padded rect that maintains aspect ratio
        // Use 15% padding to match the flight view's visual padding
        let paddingFactor = 0.15
        var paddedRect = mapRect.insetBy(
            dx: -mapRect.size.width * paddingFactor,
            dy: -mapRect.size.height * paddingFactor
        )

        // Adjust rect to match target aspect ratio
        let currentAspectRatio = paddedRect.size.width / paddedRect.size.height
        if currentAspectRatio > targetAspectRatio {
            // Map is wider than target - expand height
            let newHeight = paddedRect.size.width / targetAspectRatio
            let heightDiff = newHeight - paddedRect.size.height
            paddedRect.origin.y -= heightDiff / 2
            paddedRect.size.height = newHeight
        } else {
            // Map is taller than target - expand width
            let newWidth = paddedRect.size.height * targetAspectRatio
            let widthDiff = newWidth - paddedRect.size.width
            paddedRect.origin.x -= widthDiff / 2
            paddedRect.size.width = newWidth
        }

        let options = MKMapSnapshotter.Options()
        options.mapRect = paddedRect
        options.size = CGSize(width: targetWidth, height: targetHeight)
        options.scale = 1.0
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)

        let snapshotter = MKMapSnapshotter(options: options)

        do {
            let snapshot = try await snapshotter.start()

            // Draw the route on the snapshot
            UIGraphicsBeginImageContextWithOptions(snapshot.image.size, true, snapshot.image.scale)
            snapshot.image.draw(at: .zero)

            guard let context = UIGraphicsGetCurrentContext() else {
                UIGraphicsEndImageContext()
                return snapshot.image
            }

            // Draw polyline
            context.setStrokeColor(UIColor(Color.aviationGold).cgColor)
            context.setLineWidth(8)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            let path = UIBezierPath()
            for (index, coordinate) in coordinates.enumerated() {
                let point = snapshot.point(for: coordinate)
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            context.addPath(path.cgPath)
            context.strokePath()

            // Draw start marker (green circle)
            if let firstCoord = coordinates.first {
                let startPoint = snapshot.point(for: firstCoord)
                drawMarker(at: startPoint, color: UIColor(Color.aviationGreen), in: context)
            }

            // Draw end marker (red circle)
            if let lastCoord = coordinates.last {
                let endPoint = snapshot.point(for: lastCoord)
                drawMarker(at: endPoint, color: UIColor(Color.aviationRed), in: context)
            }

            let finalImage = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()

            return finalImage
        } catch {
            return nil
        }
    }

    private func drawMarker(at point: CGPoint, color: UIColor, in context: CGContext) {
        let markerSize: CGFloat = 24
        let rect = CGRect(
            x: point.x - markerSize / 2,
            y: point.y - markerSize / 2,
            width: markerSize,
            height: markerSize
        )

        // Draw filled circle
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: rect)

        // Draw white border
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(3)
        context.strokeEllipse(in: rect)
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
    let selectedTime: Date?

    /// Find the GPS point closest to the selected time
    private var selectedPoint: GPSPoint? {
        guard let time = selectedTime else { return nil }
        return points.min(by: { abs($0.timestamp.timeIntervalSince(time)) < abs($1.timestamp.timeIntervalSince(time)) })
    }

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
            let startAnnotation = FlightAnnotation(coordinate: first.coordinate, title: "Start", isStart: true, isSelected: false)
            let endAnnotation = FlightAnnotation(coordinate: last.coordinate, title: "End", isStart: false, isSelected: false)
            mapView.addAnnotations([startAnnotation, endAnnotation])
        }

        // Add selected position annotation if available
        if let selected = selectedPoint {
            let selectedAnnotation = FlightAnnotation(
                coordinate: selected.coordinate,
                title: "Position",
                isStart: false,
                isSelected: true
            )
            mapView.addAnnotation(selectedAnnotation)
        }

        // Set visible region (only on initial load, not when selection changes)
        if context.coordinator.initialRegionSet == false {
            let rect = polyline.boundingMapRect
            let padding = UIEdgeInsets(top: 50, left: 50, bottom: 50, right: 50)
            mapView.setVisibleMapRect(rect, edgePadding: padding, animated: false)
            context.coordinator.initialRegionSet = true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var initialRegionSet = false

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

            // Handle selected position marker
            if flightAnnotation.isSelected {
                let identifier = "selected"
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView

                if view == nil {
                    view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                }

                view?.annotation = annotation
                view?.markerTintColor = UIColor(Color.aviationGold)
                view?.glyphImage = UIImage(systemName: "location.fill")
                view?.displayPriority = .required
                view?.zPriority = .max

                return view
            }

            // Handle start/end markers
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
    let isSelected: Bool

    init(coordinate: CLLocationCoordinate2D, title: String, isStart: Bool, isSelected: Bool) {
        self.coordinate = coordinate
        self.title = title
        self.isStart = isStart
        self.isSelected = isSelected
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
    let goAroundTimes: [Date]
    let touchAndGoTimes: [Date]
    @Binding var selectedTime: Date?

    /// Altitude data points for the chart
    private var altitudeData: [(time: Date, altitude: Double)] {
        gpsTrack.map { (time: $0.timestamp, altitude: $0.altitude * 3.28084) } // Convert to feet
    }

    /// Computed altitude range with 500ft padding
    private var altitudeRange: ClosedRange<Double> {
        guard !altitudeData.isEmpty else { return 0...1000 }
        let altitudes = altitudeData.map { $0.altitude }
        let minAlt = altitudes.min() ?? 0
        let maxAlt = altitudes.max() ?? 1000
        // Add 500ft padding above and below, but don't go below 0
        let lowerBound = max(0, floor((minAlt - 500) / 100) * 100)
        let upperBound = ceil((maxAlt + 500) / 100) * 100
        return lowerBound...upperBound
    }

    /// Flight event annotations to display on the chart
    private var eventAnnotations: [(time: Date, icon: String, color: Color)] {
        var annotations: [(time: Date, icon: String, color: Color)] = []

        if let engineStart = engineStartTime {
            annotations.append((time: engineStart, icon: "engine.combustion", color: .aviationGreen))
        }
        if let lineUp = lineUpTime {
            annotations.append((time: lineUp, icon: "airplane.departure", color: .aviationAmber))
        }

        // Add go-around events
        for goAroundTime in goAroundTimes {
            annotations.append((time: goAroundTime, icon: "arrow.up.right.circle.fill", color: .aviationAmber))
        }

        // Add touch-and-go events
        for touchAndGoTime in touchAndGoTimes {
            annotations.append((time: touchAndGoTime, icon: "arrow.triangle.2.circlepath", color: .aviationBlue))
        }

        if let landing = landingTime {
            annotations.append((time: landing, icon: "airplane.arrival", color: .aviationBlue))
        }
        if let shutdown = engineShutdownTime {
            annotations.append((time: shutdown, icon: "engine.combustion.fill", color: .aviationRed))
        }

        return annotations
    }

    /// Find the altitude at the selected time
    private var selectedAltitude: Double? {
        guard let time = selectedTime else { return nil }
        // Find the closest GPS point to the selected time
        let closest = gpsTrack.min(by: { abs($0.timestamp.timeIntervalSince(time)) < abs($1.timestamp.timeIntervalSince(time)) })
        return closest.map { $0.altitude * 3.28084 }
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
                        yStart: .value("Baseline", altitudeRange.lowerBound),
                        yEnd: .value("Altitude", point.altitude)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.altimeterBlue.opacity(0.3), Color.altimeterBlue.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }

                // Event annotations with icons
                ForEach(eventAnnotations, id: \.time) { event in
                    RuleMark(x: .value("Event", event.time))
                        .foregroundStyle(event.color.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))
                        .annotation(position: .top, alignment: .center) {
                            Image(systemName: event.icon)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(event.color)
                                .padding(4)
                                .background(
                                    Circle()
                                        .fill(Color.cardBackground)
                                        .shadow(color: event.color.opacity(0.3), radius: 2)
                                )
                        }
                }

                // Selection indicator
                if let time = selectedTime, let altitude = selectedAltitude {
                    RuleMark(x: .value("Selected", time))
                        .foregroundStyle(Color.aviationGold.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 2))

                    PointMark(
                        x: .value("Selected", time),
                        y: .value("Altitude", altitude)
                    )
                    .foregroundStyle(Color.aviationGold)
                    .symbolSize(100)
                    .annotation(position: .top, spacing: 8) {
                        Text("\(Int(altitude)) ft")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.aviationGold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.cardBackground)
                                    .shadow(color: Color.aviationGold.opacity(0.3), radius: 3)
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
            .chartYScale(domain: altitudeRange)
            .chartYAxisLabel(position: .leading, alignment: .center) {
                Text("Altitude (ft MSL)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.secondaryText)
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let xPosition = value.location.x
                                    if let time: Date = proxy.value(atX: xPosition) {
                                        // Clamp to track bounds
                                        if let first = gpsTrack.first?.timestamp,
                                           let last = gpsTrack.last?.timestamp {
                                            if time >= first && time <= last {
                                                selectedTime = time
                                            }
                                        }
                                    }
                                }
                                .onEnded { _ in
                                    // Keep selection visible after touch ends
                                }
                        )
                        .simultaneousGesture(
                            TapGesture()
                                .onEnded {
                                    // Clear selection on tap outside
                                    selectedTime = nil
                                }
                        )
                }
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

// MARK: - Image Share Sheet

/// A share sheet specifically for UIImage that properly registers as an image
/// This ensures iOS recognizes the content as an image for Save to Photos and other image-specific actions
struct ImageShareSheet: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        // Pass UIImage directly - iOS will recognize it as an image and show Save to Photos
        let controller = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        return controller
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
        return filename
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? data.write(to: tempURL)
        return tempURL
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
        return filename
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? data.write(to: tempURL)
        return tempURL
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
        return filename
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? data.write(to: tempURL)
        return tempURL
    }

    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        return "public.zip-archive"
    }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        return filename
    }
}

// MARK: - Flight Share Card

/// A portrait card view designed for sharing flight summaries on mobile
/// Renders at 1080x1920 (9:16 aspect ratio, standard mobile/stories format)
struct FlightShareCard: View {
    let flight: Flight
    let mapImage: UIImage?
    let useUTC: Bool

    // Card dimensions (9:16 aspect ratio for mobile viewing and stories)
    private let cardWidth: CGFloat = 1080
    private let cardHeight: CGFloat = 1920

    /// Display title: flight name if set, otherwise airplane
    private var displayTitle: String {
        if flight.name.isEmpty {
            return flight.airplane
        }
        return "\(flight.airplane) - \(flight.name)"
    }

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.08, blue: 0.15),
                    Color(red: 0.08, green: 0.10, blue: 0.18),
                    Color(red: 0.1, green: 0.12, blue: 0.2)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 0) {
                // Header section
                headerSection
                    .padding(.top, 60)
                    .padding(.horizontal, 40)

                // Map section
                mapSection
                    .padding(.top, 40)
                    .padding(.horizontal, 40)

                // Altitude graph section
                altitudeSection
                    .padding(.top, 40)
                    .padding(.horizontal, 40)

                // Stats section
                statsSection
                    .padding(.top, 40)
                    .padding(.horizontal, 40)

                // Timeline section
                timelineSection
                    .padding(.top, 40)
                    .padding(.horizontal, 40)

                Spacer()

                // Footer
                footerSection
                    .padding(.bottom, 50)
                    .padding(.horizontal, 40)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title line: airplane and flight name
            Text(displayTitle)
                .font(.system(size: 52, weight: .bold, design: .default))
                .foregroundColor(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)

            // Date and flight time
            HStack {
                Text(flight.formattedDate)
                    .font(.system(size: 28, weight: .regular))
                    .foregroundColor(.white.opacity(0.7))

                Spacer()

                // Flight duration
                VStack(alignment: .trailing, spacing: 2) {
                    Text("FLIGHT TIME")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                        .tracking(2)

                    Text(flight.formattedDuration)
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .foregroundColor(.aviationGold)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Map Section

    private var mapSection: some View {
        Group {
            if let mapImg = mapImage {
                Image(uiImage: mapImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 620)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 620)
                    .overlay(
                        VStack(spacing: 16) {
                            Image(systemName: "map")
                                .font(.system(size: 50))
                                .foregroundColor(.white.opacity(0.3))
                            Text("No GPS data")
                                .font(.system(size: 24))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    )
            }
        }
    }

    // MARK: - Altitude Section

    private var altitudeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ALTITUDE PROFILE")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white.opacity(0.5))
                .tracking(2)

            if !flight.gpsTrack.isEmpty {
                ShareCardAltitudeChart(gpsTrack: flight.gpsTrack)
                    .frame(height: 280)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.white.opacity(0.05))
                    )
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 280)
                    .overlay(
                        Text("No altitude data")
                            .font(.system(size: 20))
                            .foregroundColor(.white.opacity(0.4))
                    )
            }
        }
    }

    // MARK: - Stats Section

    private var statsSection: some View {
        HStack(spacing: 0) {
            // Distance
            statItem(
                icon: "point.topleft.down.to.point.bottomright.curvepath.fill",
                label: "DISTANCE",
                value: flight.formattedDistance
            )

            Spacer()

            // Max Altitude
            if let maxAlt = flight.gpsTrack.map({ $0.altitude * 3.28084 }).max() {
                statItem(
                    icon: "arrow.up.to.line",
                    label: "MAX ALT",
                    value: "\(Int(maxAlt)) ft"
                )
            }

            Spacer()

            // Go-arounds or Touch-and-goes (show whichever is non-zero, or GPS points)
            if flight.goAroundCount > 0 {
                statItem(
                    icon: "arrow.up.right.circle.fill",
                    label: "GO-AROUNDS",
                    value: "\(flight.goAroundCount)"
                )
            } else if flight.touchAndGoCount > 0 {
                statItem(
                    icon: "arrow.triangle.2.circlepath",
                    label: "TOUCH & GO",
                    value: "\(flight.touchAndGoCount)"
                )
            } else {
                statItem(
                    icon: "location.fill",
                    label: "GPS POINTS",
                    value: "\(flight.gpsTrack.count)"
                )
            }
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 25)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func statItem(icon: String, label: String, value: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(.aviationGold)

            Text(label)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white.opacity(0.5))
                .tracking(1)

            Text(value)
                .font(.system(size: 30, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Timeline Section

    private var timelineSection: some View {
        HStack(spacing: 0) {
            // Engine Start
            if let time = flight.engineStartTime {
                timelineItem(
                    icon: "engine.combustion",
                    label: "Start",
                    time: formatTime(time),
                    color: .aviationGreen
                )
            }

            timelineConnector

            // Take-off
            if let time = flight.lineUpTime {
                timelineItem(
                    icon: "airplane.departure",
                    label: "Takeoff",
                    time: formatTime(time),
                    color: .aviationAmber
                )
            }

            timelineConnector

            // Landing
            if let time = flight.landingTime {
                timelineItem(
                    icon: "airplane.arrival",
                    label: "Landing",
                    time: formatTime(time),
                    color: .aviationBlue
                )
            }

            timelineConnector

            // Engine Shutdown
            if let time = flight.engineShutdownTime {
                timelineItem(
                    icon: "engine.combustion.fill",
                    label: "Shutdown",
                    time: formatTime(time),
                    color: .aviationRed
                )
            }
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 15)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func timelineItem(icon: String, label: String, time: String, color: Color) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.2))
                    .frame(width: 54, height: 54)

                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(color)
            }

            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.7))

            Text(time)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
    }

    private var timelineConnector: some View {
        Rectangle()
            .fill(Color.white.opacity(0.2))
            .frame(width: 20, height: 2)
    }

    // MARK: - Footer Section

    private var footerSection: some View {
        HStack {
            // App branding
            HStack(spacing: 10) {
                Image(systemName: "airplane.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.aviationGold)

                Text("AéroCheck")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
            }

            Spacer()
        }
    }

    // MARK: - Helpers

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        if useUTC {
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.string(from: date) + " (UTC)"
        }
        return formatter.string(from: date)
    }
}

// MARK: - Share Card Altitude Chart

/// A simplified altitude chart for the share card
struct ShareCardAltitudeChart: View {
    let gpsTrack: [GPSPoint]

    private var altitudeData: [(time: Date, altitude: Double)] {
        gpsTrack.map { (time: $0.timestamp, altitude: $0.altitude * 3.28084) }
    }

    private var altitudeRange: ClosedRange<Double> {
        guard !altitudeData.isEmpty else { return 0...1000 }
        let altitudes = altitudeData.map { $0.altitude }
        let minAlt = altitudes.min() ?? 0
        let maxAlt = altitudes.max() ?? 1000
        let lowerBound = max(0, floor((minAlt - 500) / 100) * 100)
        let upperBound = ceil((maxAlt + 500) / 100) * 100
        return lowerBound...upperBound
    }

    var body: some View {
        if altitudeData.isEmpty {
            Text("No altitude data")
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(0.4))
        } else {
            Chart {
                ForEach(altitudeData, id: \.time) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Altitude", point.altitude)
                    )
                    .foregroundStyle(Color.altimeterBlue)
                    .lineStyle(StrokeStyle(lineWidth: 3))
                }

                ForEach(altitudeData, id: \.time) { point in
                    AreaMark(
                        x: .value("Time", point.time),
                        yStart: .value("Baseline", altitudeRange.lowerBound),
                        yEnd: .value("Altitude", point.altitude)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.altimeterBlue.opacity(0.4), Color.altimeterBlue.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.white.opacity(0.2))
                    AxisValueLabel()
                        .foregroundStyle(Color.white.opacity(0.6))
                        .font(.system(size: 12))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.white.opacity(0.2))
                    AxisValueLabel {
                        if let altitude = value.as(Double.self) {
                            Text("\(Int(altitude)) ft")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.white.opacity(0.6))
                        }
                    }
                }
            }
            .chartYScale(domain: altitudeRange)
        }
    }
}

// MARK: - Preview

#Preview {
    FlightLogView()
        .environmentObject(AppState())
}
