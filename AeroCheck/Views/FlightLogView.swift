import SwiftUI
import MapKit
import Charts
import UniformTypeIdentifiers
import Compression

/// Flight log view showing all recorded flights
struct FlightLogView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @Environment(\.dismiss) var dismiss
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
            .navigationTitle(L10n.FlightLog.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.FlightLog.close) { dismiss() }
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
        .confirmationDialog(L10n.FlightLog.exportAllTitle, isPresented: $showExportAllOptions, titleVisibility: .visible) {
            Button(L10n.FlightLog.exportAllGPX) {
                exportAllType = .gpx
                showExportAllSheet = true
            }
            Button(L10n.FlightLog.exportAllJSON) {
                exportAllType = .json
                showExportAllSheet = true
            }
            Button(L10n.Button.cancel, role: .cancel) { }
        } message: {
            Text(L10n.FlightLog.exportAllMessage(appState.flights.count))
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
        .alert(L10n.FlightLog.importErrorTitle, isPresented: $showImportError) {
            Button(L10n.FlightLog.importErrorOK, role: .cancel) { }
        } message: {
            Text(importError ?? L10n.FlightLog.importErrorUnknown)
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

            Text(L10n.FlightLog.noFlightsTitle)
                .font(.headerText)
                .foregroundColor(.primaryText)

            Text(L10n.FlightLog.noFlightsMessage)
                .font(.bodyText)
                .foregroundColor(.secondaryText)
                .multilineTextAlignment(.center)

            Button(action: { showImportPicker = true }) {
                HStack {
                    Image(systemName: "square.and.arrow.down")
                    Text(L10n.FlightLog.importFlight)
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .padding(.top, 16)
        }
        .padding(40)
    }
    
    // MARK: - Flight List

    /// Flights sorted counter-chronologically (most recent first)
    private var sortedFlights: [Flight] {
        appState.flights.sorted { flight1, flight2 in
            let date1 = flight1.startTime ?? Date.distantPast
            let date2 = flight2.startTime ?? Date.distantPast
            return date1 > date2
        }
    }

    private var flightList: some View {
        List {
            ForEach(sortedFlights) { flight in
                NavigationLink(destination: FlightDetailView(flight: flight)) {
                    FlightRowView(flight: flight)
                }
                .listRowBackground(Color.cardBackground)
            }
            .onDelete { indexSet in
                deleteFlights(at: indexSet)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// Delete flights from the sorted list by mapping indices back to the original array
    private func deleteFlights(at indexSet: IndexSet) {
        let flightsToDelete = indexSet.map { sortedFlights[$0] }
        for flight in flightsToDelete {
            appState.deleteFlight(flight)
        }
    }
    
    // MARK: - Import Handler

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            guard url.startAccessingSecurityScopedResource() else {
                importError = L10n.FlightLog.importErrorNoAccess
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
                    importError = L10n.FlightLog.importErrorParse
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
                importError = L10n.FlightLog.importErrorZipNoFiles
                showImportError = true
            } else if failCount > 0 {
                importError = L10n.FlightLog.importErrorZipPartial(successCount, failCount)
                showImportError = true
            }
            // If all succeeded, no error message needed
        } catch {
            importError = L10n.FlightLog.importErrorZipExtract(error.localizedDescription)
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

// MARK: - Custom Label Style

/// A custom label style with configurable spacing between icon and text
struct CustomLabelStyle: LabelStyle {
    var spacing: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Flight Row View

struct FlightRowView: View {
    @EnvironmentObject var appState: AppState
    let flight: Flight

    var body: some View {
        HStack(spacing: 16) {
            // Date indicator
            VStack(spacing: 2) {
                Text(dayString)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(.aviationGold)
                Text(monthString)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondaryText)
                    .textCase(.uppercase)
                Text(yearString)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.aviationGold)
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
                
                HStack(spacing: 14) {
                    if let startTime = flight.startTime {
                        Label {
                            Text(timeString(from: startTime))
                        } icon: {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                        }
                        .font(.captionText)
                        .foregroundColor(.secondaryText)
                        .labelStyle(CustomLabelStyle(spacing: 4))
                    }

                    Label {
                        Text(flight.formattedDistance)
                    } icon: {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                            .font(.system(size: 10))
                    }
                    .font(.captionText)
                    .foregroundColor(.secondaryText)
                    .labelStyle(CustomLabelStyle(spacing: 4))

                    Label {
                        Text("\(flight.gpsTrack.count) \(L10n.FlightLog.pts)")
                    } icon: {
                        Image(systemName: "location.fill")
                            .font(.system(size: 10))
                    }
                    .font(.captionText)
                    .foregroundColor(.secondaryText)
                    .labelStyle(CustomLabelStyle(spacing: 4))
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

    private var yearString: String {
        guard let date = flight.startTime else { return "----" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
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
    @EnvironmentObject var flightPlanManager: FlightPlanManager
    @EnvironmentObject var airportDataService: AirportDataService
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
    @State private var showFlightPlan = false

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
                    Button(L10n.Button.close) { dismiss() }
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
        .confirmationDialog(L10n.FlightDetail.exportFormatTitle, isPresented: $showExportOptions, titleVisibility: .visible) {
            Button(L10n.FlightDetail.exportFormatGPX) {
                exportType = .gpx
                showExportSheet = true
            }
            Button(L10n.FlightDetail.exportFormatJSON) {
                exportType = .json
                showExportSheet = true
            }
            Button(L10n.Button.cancel, role: .cancel) { }
        } message: {
            Text(L10n.FlightDetail.exportFormatMessage)
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
                // Include flight plan data if available
                let flightPlan: FlightPlan? = {
                    guard let flightPlanId = flight.flightPlanId else { return nil }
                    return flightPlanManager.flightPlans.first { $0.id == flightPlanId }
                }()
                if let jsonData = flight.toJSON(withFlightPlan: flightPlan) {
                    ShareSheet(activityItems: [
                        JSONFile(data: jsonData, filename: "\(flight.exportFilename).json")
                    ])
                }
            }
        }
        .alert(L10n.FlightDetail.deleteTitle, isPresented: $showDeleteAlert) {
            Button(L10n.Button.cancel, role: .cancel) { }
            Button(L10n.Button.delete, role: .destructive) {
                appState.deleteFlight(flight)
                dismiss()
            }
        } message: {
            Text(L10n.FlightDetail.deleteMessage)
        }
    }
    
    // MARK: - Map Section
    
    private var mapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.FlightDetail.flightTrack)
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
                            Text(L10n.FlightDetail.noGPSData)
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
            Text(L10n.FlightDetail.altitudeProfile)
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
                            Text(L10n.FlightDetail.noAltitudeData)
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
                    fullStopTimes: flight.fullStopTimes,
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
            Text(L10n.FlightDetail.flightDetails)
                .font(.captionText)
                .foregroundColor(.secondaryText)

            VStack(spacing: 12) {
                DetailRow(label: L10n.FlightDetail.aircraft, value: flight.aircraftRegistration ?? flight.airplane, icon: "airplane")
                if let aircraftType = flight.aircraftType {
                    DetailRow(label: L10n.FlightDetail.aircraftType, value: aircraftType, icon: "info.circle")
                }
                if let version = flight.checklistVersion {
                    DetailRow(label: L10n.FlightDetail.checklistVersion, value: version, icon: "doc.text")
                }
                DetailRow(label: L10n.FlightDetail.date, value: flight.formattedDate, icon: "calendar")
                DetailRow(label: L10n.FlightDetail.flightTime, value: flight.formattedDuration, icon: "clock.fill")
                DetailRow(label: L10n.FlightDetail.distance, value: flight.formattedDistance, icon: "point.topleft.down.to.point.bottomright.curvepath.fill")
                DetailRow(label: L10n.FlightDetail.gpsPoints, value: "\(flight.gpsTrack.count)", icon: "location.fill")
                if flight.goAroundCount > 0 {
                    DetailRow(label: L10n.FlightDetail.goArounds, value: "\(flight.goAroundCount)", icon: "arrow.up.right.circle.fill")
                }
                if flight.touchAndGoCount > 0 {
                    DetailRow(label: L10n.FlightDetail.touchAndGoes, value: "\(flight.touchAndGoCount)", icon: "arrow.triangle.2.circlepath")
                }
                if flight.fullStopCount > 0 {
                    DetailRow(label: L10n.FlightDetail.fullStops, value: "\(flight.fullStopCount)", icon: "stop.circle.fill")
                }
            }
            .cardStyle()

            // Route
            if flight.departureAirportIdent != nil || flight.arrivalAirportIdent != nil || flight.flightPlan != nil {
                Text(L10n.FlightDetail.route.uppercased())
                    .font(.captionText)
                    .foregroundColor(.secondaryText)
                    .padding(.top, 8)

                VStack(spacing: 12) {
                    if let dep = flight.departureAirportIdent {
                        DetailRow(label: L10n.FlightDetail.departure, value: dep, icon: "airplane.departure")
                    }
                    if let waypoints = flight.flightPlan?.waypoints, !waypoints.isEmpty {
                        ForEach(waypoints) { wp in
                            DetailRow(label: wp.name, value: wp.formattedCoordinate, icon: "mappin")
                        }
                    }
                    if let arr = flight.arrivalAirportIdent {
                        DetailRow(label: L10n.FlightDetail.arrival, value: arr, icon: "airplane.arrival")
                    }
                }
                .cardStyle()
            }

            // Chronological times
            Text(L10n.FlightDetail.flightTimes)
                .font(.captionText)
                .foregroundColor(.secondaryText)
                .padding(.top, 8)

            VStack(spacing: 12) {
                if let start = flight.startTime {
                    TimelineRow(label: L10n.FlightDetail.sessionStart, time: timeString(from: start), icon: "play.fill", color: .dimText)
                }

                if let engineStart = flight.engineStartTime {
                    TimelineRow(label: L10n.FlightDetail.engineStart, time: timeString(from: engineStart), icon: "engine.combustion", color: .aviationGreen)
                }

                if let blockOff = flight.blockOffTime {
                    TimelineRow(label: L10n.FlightDetail.blockOff, time: timeString(from: blockOff), icon: "door.left.hand.open", color: .dimText)
                }

                if let lineUp = flight.lineUpTime {
                    TimelineRow(label: L10n.FlightDetail.takeoff, time: timeString(from: lineUp), icon: "airplane.departure", color: .aviationAmber)
                }

                if let landing = flight.landingTime {
                    TimelineRow(label: L10n.FlightDetail.landing, time: timeString(from: landing), icon: "airplane.arrival", color: .aviationBlue)
                }

                if let blockOn = flight.blockOnTime {
                    TimelineRow(label: L10n.FlightDetail.blockOn, time: timeString(from: blockOn), icon: "door.left.hand.closed", color: .dimText)
                }

                if let shutdown = flight.engineShutdownTime {
                    TimelineRow(label: L10n.FlightDetail.engineShutdown, time: timeString(from: shutdown), icon: "engine.combustion.fill", color: .aviationRed)
                }

                if let stop = flight.stopTime {
                    TimelineRow(label: L10n.FlightDetail.sessionEnd, time: timeString(from: stop), icon: "stop.fill", color: .dimText)
                }
            }
            .cardStyle()

            // Engine Hours (if logged)
            if flight.engineHourStart != nil || flight.engineHourEnd != nil {
                Text(L10n.FlightDetail.engineHours.uppercased())
                    .font(.captionText)
                    .foregroundColor(.secondaryText)
                    .padding(.top, 8)

                VStack(spacing: 12) {
                    if let start = flight.engineHourStart {
                        ToggleableHoursRow(
                            label: L10n.FlightDetail.hoursBefore,
                            hours: start,
                            inputFormat: flight.engineHourStartInputFormat,
                            icon: "gauge.with.dots.needle.0percent",
                            color: .aviationGold
                        )
                    }
                    if let end = flight.engineHourEnd {
                        ToggleableHoursRow(
                            label: L10n.FlightDetail.hoursAfter,
                            hours: end,
                            inputFormat: flight.engineHourEndInputFormat,
                            icon: "gauge.with.dots.needle.100percent",
                            color: .aviationGold
                        )
                    }
                    if let formatted = flight.engineHoursFlownFormatted {
                        HStack {
                            Image(systemName: "clock.badge.checkmark")
                                .foregroundColor(.aviationGreen)
                                .frame(width: 24)
                            Text(L10n.FlightDetail.hoursFlown)
                                .font(.bodyText)
                                .foregroundColor(.secondaryText)
                            Spacer()
                            Text(formatted)
                                .font(.system(size: 16, weight: .medium, design: .monospaced))
                                .foregroundColor(.aviationGreen)
                        }
                    }
                }
                .cardStyle()
            }

            // Flight Name editing (moved to be between FLIGHT TIMES and NOTES)
            Text(L10n.FlightDetail.flightName)
                .font(.captionText)
                .foregroundColor(.secondaryText)
                .padding(.top, 8)

            TextField(L10n.FlightDetail.namePlaceholder, text: $flightName)
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
            Text(L10n.FlightDetail.notes)
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
        HStack(spacing: 8) {
            // Flight Plan button (only shown if flight has saved flight plan data)
            if let savedFlightPlan = flight.flightPlan {
                Button(action: {
                    showFlightPlan = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        Text(L10n.FlightDetail.navPlan)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
                .sheet(isPresented: $showFlightPlan) {
                    FlightPlanEditorView(flightPlan: savedFlightPlan, isViewingFromFlightLog: true)
                        .environmentObject(appState)
                        .environmentObject(flightPlanManager)
                        .environmentObject(airportDataService)
                }
            }

            Button(action: { showExportOptions = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                    Text(L10n.FlightDetail.export)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())

            Button(action: { showDeleteAlert = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                    Text(L10n.FlightDetail.delete)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
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
                // Use 2.0 scale for better file size while maintaining quality
                // Results in 2160x3840 image (4K) which is high quality but reasonable size
                renderer.scale = 2.0

                if let uiImage = renderer.uiImage {
                    // Compress the image to JPEG for better file size (quality 0.85)
                    if let jpegData = uiImage.jpegData(compressionQuality: 0.85),
                       let compressedImage = UIImage(data: jpegData) {
                        shareImage = compressedImage
                    } else {
                        shareImage = uiImage
                    }
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

        // Target size for the snapshot (matching card map dimensions at 2x scale for the renderer)
        // Card hero map section is 1016x780 points, we render at 2x = 2032x1560
        let targetWidth: CGFloat = 2032
        let targetHeight: CGFloat = 1560
        let targetAspectRatio = targetWidth / targetHeight

        // Calculate padded rect that maintains aspect ratio
        // Use 15% padding to give visual breathing room around the track
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
        // Use UIScreen.main.scale for proper device scaling
        options.scale = UIScreen.main.scale
        options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)

        let snapshotter = MKMapSnapshotter(options: options)

        do {
            let snapshot = try await snapshotter.start()

            // Draw the route on the snapshot using modern UIGraphicsImageRenderer
            let renderer = UIGraphicsImageRenderer(size: snapshot.image.size)
            let finalImage = renderer.image { rendererContext in
                // Draw the base map
                snapshot.image.draw(at: .zero)

                let context = rendererContext.cgContext

                // Draw polyline with thicker line for visibility
                context.setStrokeColor(UIColor(Color.aviationGold).cgColor)
                context.setLineWidth(6 * UIScreen.main.scale)
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
                    self.drawMarker(at: startPoint, color: UIColor(Color.aviationGreen), in: context, scale: UIScreen.main.scale)
                }

                // Draw end marker (red circle)
                if let lastCoord = coordinates.last {
                    let endPoint = snapshot.point(for: lastCoord)
                    self.drawMarker(at: endPoint, color: UIColor(Color.aviationRed), in: context, scale: UIScreen.main.scale)
                }
            }

            return finalImage
        } catch {
            print("Map snapshot error: \(error)")
            return nil
        }
    }

    private func drawMarker(at point: CGPoint, color: UIColor, in context: CGContext, scale: CGFloat = 1.0) {
        let markerSize: CGFloat = 20 * scale
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
        context.setLineWidth(2 * scale)
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

// MARK: - Toggleable Hours Row

/// A row that toggles between decimal and time format on tap
struct ToggleableHoursRow: View {
    let label: String
    let hours: Double
    let inputFormat: String? // "decimal" or "time"
    let icon: String
    let color: Color

    @State private var showTimeFormat: Bool = false

    private var displayValue: String {
        if showTimeFormat {
            return Flight.formatHoursTime(hours)
        } else {
            return Flight.formatHoursDecimal(hours)
        }
    }

    var body: some View {
        Button(action: { showTimeFormat.toggle() }) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .frame(width: 24)

                Text(label)
                    .font(.bodyText)
                    .foregroundColor(.secondaryText)

                Spacer()

                Text(displayValue)
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundColor(.primaryText)
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            // Default to the format the user used during input
            showTimeFormat = (inputFormat == "time")
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
    let fullStopTimes: [Date]
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

        // Add full stop events
        for fullStopTime in fullStopTimes {
            annotations.append((time: fullStopTime, icon: "stop.circle.fill", color: .aviationAmber))
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
            Text(L10n.FlightDetail.noAltitudeData)
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
                Text(L10n.FlightDetail.altitudeFtMSL)
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

/// A share sheet for UIImage that saves to a temporary JPEG file and shares the URL.
/// Sharing a file URL (instead of raw UIImage) reliably surfaces "Save Image" in the share sheet,
/// provided NSPhotoLibraryAddUsageDescription is set in Info.plist.
struct ImageShareSheet: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        // Write image to a temporary JPEG file — sharing a file URL is the most
        // reliable way to get iOS to show "Save Image" and proper preview thumbnails
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AeroCheck_Flight_\(UUID().uuidString.prefix(8)).jpg")
        if let jpegData = image.jpegData(compressionQuality: 0.9) {
            try? jpegData.write(to: tempURL)
        }
        let controller = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
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

    // Card dimensions (9:16 aspect ratio for Instagram/WhatsApp/Signal stories)
    private let cardWidth: CGFloat = 1080
    private let cardHeight: CGFloat = 1920

    // MARK: - Computed Properties

    /// Aircraft registration or airplane ID
    private var aircraftIdentifier: String {
        flight.aircraftRegistration ?? flight.airplane
    }

    /// Route string: "LSGG → LSZB" or just the identifier if no airports
    private var routeString: String? {
        guard let dep = flight.departureAirportIdent, let arr = flight.arrivalAirportIdent else {
            return nil
        }
        return "\(dep) → \(arr)"
    }

    /// Flight time between takeoff and landing, with fallback times.
    private var exportFlightTime: TimeInterval? {
        let takeoff = flight.lineUpTime ?? flight.blockOffTime ?? flight.engineStartTime ?? flight.startTime
        let landing = flight.landingTime ?? flight.blockOnTime ?? flight.engineShutdownTime ?? flight.stopTime
        guard let t = takeoff, let l = landing else { return nil }
        return l.timeIntervalSince(t)
    }

    private var formattedExportFlightTime: String {
        guard let ft = exportFlightTime else { return "--:--" }
        let hours = Int(ft) / 3600
        let minutes = (Int(ft) % 3600) / 60
        return String(format: "%dh%02d", hours, minutes)
    }

    /// Max altitude in feet from GPS track
    private var maxAltitudeFt: Int? {
        guard let maxAlt = flight.gpsTrack.map({ $0.altitude * 3.28084 }).max() else { return nil }
        return Int(maxAlt)
    }

    /// Distance in nautical miles
    private var distanceNM: String {
        let nm = flight.distanceKilometers / 1.852
        if nm < 1 {
            return String(format: "%.1f NM", nm)
        }
        return String(format: "%.0f NM", nm)
    }

    /// Total landings count
    private var landingsCount: Int {
        flight.totalLandings
    }

    /// Formatted flight date
    private var formattedDate: String {
        guard let start = flight.startTime else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: start).uppercased()
    }

    // Altitude chart data
    private var altitudeData: [(time: Date, altitude: Double)] {
        flight.gpsTrack.map { (time: $0.timestamp, altitude: $0.altitude * 3.28084) }
    }

    private var altitudeRange: ClosedRange<Double> {
        guard !altitudeData.isEmpty else { return 0...1000 }
        let altitudes = altitudeData.map { $0.altitude }
        let minAlt = altitudes.min() ?? 0
        let maxAlt = altitudes.max() ?? 1000
        let lowerBound = max(0, floor((minAlt - 200) / 100) * 100)
        let upperBound = ceil((maxAlt + 200) / 100) * 100
        return lowerBound...upperBound
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            // Deep dark background
            Color(red: 0.04, green: 0.05, blue: 0.09)

            VStack(spacing: 0) {
                // Top bar: date + branding
                topBarSection
                    .padding(.top, 50)
                    .padding(.horizontal, 48)

                // Route / Title area
                routeSection
                    .padding(.top, 32)
                    .padding(.horizontal, 48)

                // Hero map with overlaid stats
                heroMapSection
                    .padding(.top, 32)
                    .padding(.horizontal, 32)

                // Altitude sparkline
                altitudeSparkline
                    .padding(.top, 24)
                    .padding(.horizontal, 48)

                // Bottom stats row
                bottomStatsRow
                    .padding(.top, 28)
                    .padding(.horizontal, 48)

                Spacer()

                // Footer branding
                footerSection
                    .padding(.bottom, 50)
                    .padding(.horizontal, 48)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
    }

    // MARK: - Top Bar

    private var topBarSection: some View {
        HStack {
            // Date
            Text(formattedDate)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
                .tracking(2)

            Spacer()

            // Aircraft identifier pill
            Text(aircraftIdentifier)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(.aviationGold)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.aviationGold.opacity(0.15))
                        .overlay(
                            Capsule()
                                .stroke(Color.aviationGold.opacity(0.3), lineWidth: 1)
                        )
                )
        }
    }

    // MARK: - Route Section

    private var routeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let route = routeString {
                // Airport-to-airport route
                Text(route)
                    .font(.system(size: 56, weight: .heavy, design: .default))
                    .foregroundColor(.white)
                    .tracking(1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else if !flight.name.isEmpty {
                // Flight name as main title
                Text(flight.name)
                    .font(.system(size: 48, weight: .bold, design: .default))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }

            // Hero number: flight time
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(formattedExportFlightTime)
                    .font(.system(size: 72, weight: .bold, design: .monospaced))
                    .foregroundColor(.aviationGold)

                Text("FLIGHT TIME")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white.opacity(0.4))
                    .tracking(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Hero Map with Overlaid Stats

    private var heroMapSection: some View {
        ZStack(alignment: .bottom) {
            // Map image
            if let mapImg = mapImage {
                Image(uiImage: mapImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 780)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(
                        // Subtle gradient at bottom for stat readability
                        VStack {
                            Spacer()
                            LinearGradient(
                                colors: [.clear, Color.black.opacity(0.6)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 200)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.white.opacity(0.04))
                    .frame(height: 780)
                    .overlay(
                        VStack(spacing: 16) {
                            Image(systemName: "map")
                                .font(.system(size: 60))
                                .foregroundColor(.white.opacity(0.15))
                            Text(L10n.FlightDetail.noGPSData)
                                .font(.system(size: 24))
                                .foregroundColor(.white.opacity(0.25))
                        }
                    )
            }

            // Overlaid stat pills at the bottom of the map
            if mapImage != nil {
                HStack(spacing: 12) {
                    mapStatPill(icon: "arrow.up.to.line", value: maxAltitudeFt.map { "\($0) ft" } ?? "—", label: "MAX ALT")

                    mapStatPill(icon: "point.topleft.down.to.point.bottomright.curvepath.fill", value: distanceNM, label: "DISTANCE")

                    if landingsCount > 0 {
                        mapStatPill(icon: "airplane.arrival", value: "\(landingsCount)", label: landingsCount == 1 ? "LANDING" : "LANDINGS")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    private func mapStatPill(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.aviationGold)

            Text(value)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.5))
                .tracking(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
    }

    // MARK: - Altitude Sparkline

    private var altitudeSparkline: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section label
            HStack {
                Text("ALTITUDE PROFILE")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.35))
                    .tracking(2)

                Spacer()

                if let maxAlt = maxAltitudeFt {
                    Text("PEAK \(maxAlt) FT")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.altimeterBlue.opacity(0.7))
                }
            }

            if !altitudeData.isEmpty {
                ShareCardAltitudeChart(gpsTrack: flight.gpsTrack)
                    .frame(height: 180)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.white.opacity(0.03))
                    )
            }
        }
    }

    // MARK: - Bottom Stats Row

    private var bottomStatsRow: some View {
        HStack(spacing: 0) {
            // Takeoff time
            if let takeoff = flight.lineUpTime {
                bottomStatItem(
                    icon: "airplane.departure",
                    value: formatTime(takeoff),
                    label: "TAKEOFF",
                    color: .aviationGreen
                )
            }

            // Landing time
            if let landing = flight.landingTime {
                bottomStatItem(
                    icon: "airplane.arrival",
                    value: formatTime(landing),
                    label: "LANDING",
                    color: .aviationAmber
                )
            }

            // Activity count (go-arounds or touch-and-gos)
            if flight.goAroundCount > 0 {
                bottomStatItem(
                    icon: "arrow.up.right.circle.fill",
                    value: "\(flight.goAroundCount)",
                    label: "GO-AROUNDS",
                    color: .aviationRed
                )
            } else if flight.touchAndGoCount > 0 {
                bottomStatItem(
                    icon: "arrow.triangle.2.circlepath",
                    value: "\(flight.touchAndGoCount)",
                    label: "TOUCH & GO",
                    color: .altimeterBlue
                )
            }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private func bottomStatItem(icon: String, value: String, label: String, color: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(color)

            Text(value)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(label)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white.opacity(0.4))
                .tracking(1)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer Section

    private var footerSection: some View {
        HStack {
            // Flight name (if we have a route, show the name here)
            if routeString != nil && !flight.name.isEmpty {
                Text(flight.name)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white.opacity(0.3))
                    .lineLimit(1)
            }

            Spacer()

            // App branding
            HStack(spacing: 8) {
                Image(systemName: "airplane.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.aviationGold.opacity(0.6))

                Text("AéroCheck")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }

    // MARK: - Helpers

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        if useUTC {
            formatter.timeZone = TimeZone(identifier: "UTC")
        }
        return formatter.string(from: date)
    }
}

// MARK: - Share Card Altitude Chart

/// A minimal altitude sparkline chart for the share card
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
        let lowerBound = max(0, floor((minAlt - 200) / 100) * 100)
        let upperBound = ceil((maxAlt + 200) / 100) * 100
        return lowerBound...upperBound
    }

    var body: some View {
        if altitudeData.isEmpty {
            Text(L10n.FlightDetail.noAltitudeData)
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(0.4))
        } else {
            Chart {
                ForEach(altitudeData, id: \.time) { point in
                    AreaMark(
                        x: .value("Time", point.time),
                        yStart: .value("Baseline", altitudeRange.lowerBound),
                        yEnd: .value("Altitude", point.altitude)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.altimeterBlue.opacity(0.3), Color.altimeterBlue.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }

                ForEach(altitudeData, id: \.time) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Altitude", point.altitude)
                    )
                    .foregroundStyle(Color.altimeterBlue.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: altitudeRange)
        }
    }
}

// MARK: - Preview

#Preview {
    FlightLogView()
        .environmentObject(AppState())
}
