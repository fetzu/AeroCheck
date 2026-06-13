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
    /// The export bundle is built off the main actor (PERF-12); the share sheet presents only once
    /// `exportAllZipData` is ready. `isPreparingExportAll` drives a progress indicator meanwhile.
    @State private var exportAllZipData: Data?
    @State private var isPreparingExportAll = false
    
    enum ExportAllType: Sendable {
        case gpx
        case json
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.cockpitBackground
                    .ignoresSafeArea()
                
                if appState.isLoadingFlights {
                    VStack(spacing: 16) {
                        ProgressView()
                            .tint(Color.aviationGold)
                        Text(L10n.FlightLog.loading)
                            .font(.subheadline)
                            .foregroundColor(.secondaryText)
                    }
                } else if appState.flights.isEmpty {
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
                prepareExportAll()
            }
            Button(L10n.FlightLog.exportAllJSON) {
                exportAllType = .json
                prepareExportAll()
            }
            Button(L10n.Button.cancel, role: .cancel) { }
        } message: {
            Text(L10n.FlightLog.exportAllMessage(appState.flights.count))
        }
        .sheet(isPresented: $showExportAllSheet) {
            if let zipData = exportAllZipData {
                let filename = "AeroCheck_\(formattedExportDate)_ExportBundle.zip"
                ShareSheet(activityItems: [
                    ZIPFile(data: zipData, filename: filename)
                ])
            }
        }
        .overlay {
            if isPreparingExportAll {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    ProgressView(L10n.FlightLog.preparingExport)
                        .padding(24)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .transition(.opacity)
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
    
    /// Serialize every flight and zip them off the main actor, then present the share sheet.
    /// Keeps the heavy serialize/CRC/zip work out of the `.sheet` content builder. (PERF-12)
    private func prepareExportAll() {
        let flights = appState.flights
        let type = exportAllType
        isPreparingExportAll = true
        Task { @MainActor in
            let data = await Task.detached(priority: .userInitiated) {
                FlightLogView.buildExportAllZip(flights: flights, type: type)
            }.value
            exportAllZipData = data
            isPreparingExportAll = false
            showExportAllSheet = (data != nil)
        }
    }

    /// Builds the export bundle (serialize each flight → zip). `nonisolated static` so it runs off
    /// the main actor; only the resulting `Data` crosses back. (PERF-12)
    nonisolated static func buildExportAllZip(flights: [Flight], type: ExportAllType) -> Data? {
        var zipEntries: [(filename: String, data: Data)] = []

        for flight in flights {
            switch type {
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
    nonisolated static func createSimpleZip(entries: [(filename: String, data: Data)]) -> Data? {
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
    nonisolated static func crc32(_ data: Data) -> UInt32 {
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
    @EnvironmentObject var openAIPDataService: OpenAIPDataService
    @Environment(\.dismiss) var dismiss
    let flight: Flight

    @State private var flightName: String = ""
    @State private var notes: String = ""
    @State private var showExportSheet = false
    @State private var showDeleteAlert = false
    @State private var showExportOptions = false
    @State private var exportType: ExportType = .gpx
    @State private var selectedTime: Date?
    @State private var showFlightPlan = false
    @State private var showShareCustomization = false
    // PR-25: serialize the export off the main actor and present only when ready — never serialize
    // a long flight's GPX/JSON inside the .sheet content builder (blocks the UI as the sheet
    // animates), and never present an empty share sheet on failure.
    @State private var preparedExportData: Data?
    @State private var isPreparingExport = false
    @State private var showExportError = false

    enum ExportType {
        case gpx
        case json
    }

    /// PR-25: build the GPX/JSON `Data` off the main actor, then present the share sheet (or an
    /// error alert). Mirrors `prepareExportAll`.
    private func prepareExport(_ type: ExportType) {
        exportType = type
        let flight = self.flight
        let flightPlan: FlightPlan? = {
            guard let id = flight.flightPlanId else { return nil }
            return flightPlanManager.flightPlans.first { $0.id == id }
        }()
        isPreparingExport = true
        Task { @MainActor in
            let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                switch type {
                case .gpx: return flight.toGPX().data(using: .utf8)
                case .json: return flight.toJSON(withFlightPlan: flightPlan)
                }
            }.value
            isPreparingExport = false
            if let data {
                preparedExportData = data
                showExportSheet = true
            } else {
                showExportError = true
            }
        }
    }
    
    var body: some View {
        NavigationStack {
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
                    Button(action: { showShareCustomization = true }) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            flightName = flight.name
            notes = flight.notes
        }
        .sheet(isPresented: $showShareCustomization) {
            ShareCardCustomizationView(
                flight: flight,
                appState: appState
            )
        }
        .confirmationDialog(L10n.FlightDetail.exportFormatTitle, isPresented: $showExportOptions, titleVisibility: .visible) {
            Button(L10n.FlightDetail.exportFormatGPX) {
                prepareExport(.gpx)
            }
            Button(L10n.FlightDetail.exportFormatJSON) {
                prepareExport(.json)
            }
            Button(L10n.Button.cancel, role: .cancel) { }
        } message: {
            Text(L10n.FlightDetail.exportFormatMessage)
        }
        .sheet(isPresented: $showExportSheet) {
            // PR-25: data is already serialized off-main in prepareExport — the builder only wraps it.
            if let data = preparedExportData {
                switch exportType {
                case .gpx:
                    ShareSheet(activityItems: [GPXFile(data: data, filename: "\(flight.exportFilename).gpx")])
                case .json:
                    ShareSheet(activityItems: [JSONFile(data: data, filename: "\(flight.exportFilename).json")])
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
        .alert(L10n.FlightDetail.exportFailedTitle, isPresented: $showExportError) {
            Button(L10n.Button.close, role: .cancel) { }
        } message: {
            Text(L10n.FlightDetail.exportFailedMessage)
        }
        .overlay {
            if isPreparingExport {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    ProgressView(L10n.FlightLog.preparingExport)
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
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
                if flight.fullStopCount > 1 {
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
                        .environmentObject(openAIPDataService)
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

    // MARK: - Web Mercator Tile Math

    fileprivate static func lonToTileX(lon: Double, zoom: Int) -> Int {
        Int(floor((lon + 180.0) / 360.0 * pow(2.0, Double(zoom))))
    }

    fileprivate static func latToTileY(lat: Double, zoom: Int) -> Int {
        let latRad = lat * .pi / 180.0
        return Int(floor((1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / .pi) / 2.0 * pow(2.0, Double(zoom))))
    }

    fileprivate static func tileXToLon(tileX: Int, zoom: Int) -> Double {
        Double(tileX) / pow(2.0, Double(zoom)) * 360.0 - 180.0
    }

    fileprivate static func tileYToLat(tileY: Int, zoom: Int) -> Double {
        let n = .pi - 2.0 * .pi * Double(tileY) / pow(2.0, Double(zoom))
        return 180.0 / .pi * atan(0.5 * (exp(n) - exp(-n)))
    }

    /// Calculate optimal zoom level so the bounding box fits within the target width
    fileprivate static func optimalZoomLevel(
        minLat: Double, maxLat: Double,
        minLon: Double, maxLon: Double,
        targetWidth: CGFloat, tileSize: CGFloat,
        layerMinZoom: Int, layerMaxZoom: Int
    ) -> Int {
        let lonSpan = maxLon - minLon
        for z in stride(from: layerMaxZoom, through: layerMinZoom, by: -1) {
            let tilesNeeded = lonSpan / 360.0 * pow(2.0, Double(z))
            let pixelsNeeded = tilesNeeded * Double(tileSize)
            if pixelsNeeded <= Double(targetWidth) * 1.5 {
                return z
            }
        }
        return layerMinZoom
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

extension Array where Element == GPSPoint {
    /// Binary-search the chronologically-ordered track for the point nearest `time`. O(log n), vs
    /// the O(n) `min(by:)` it replaces — which ran on every scrub frame of a multi-hour flight. (PR-26)
    func closestByTimestamp(to time: Date) -> GPSPoint? {
        guard !isEmpty else { return nil }
        var lo = startIndex, hi = endIndex - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if self[mid].timestamp < time { lo = mid + 1 } else { hi = mid }
        }
        let candidate = self[lo]
        if lo > startIndex {
            let prev = self[lo - 1]
            if abs(prev.timestamp.timeIntervalSince(time)) <= abs(candidate.timestamp.timeIntervalSince(time)) {
                return prev
            }
        }
        return candidate
    }
}

struct FlightMapView: UIViewRepresentable {
    let points: [GPSPoint]
    let selectedTime: Date?

    /// Find the GPS point closest to the selected time (binary search, O(log n)). (PR-26)
    private var selectedPoint: GPSPoint? {
        guard let time = selectedTime else { return nil }
        return points.closestByTimestamp(to: time)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.overrideUserInterfaceStyle = .dark
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator

        // Rebuild the static track layer (polyline + start/end markers) ONLY when the track itself
        // changes — not on every scrub, which previously tore down and re-added the whole O(n)
        // polyline each frame. For an immutable past flight this runs exactly once. (PR-26)
        if coordinator.builtPointCount != points.count {
            coordinator.builtPointCount = points.count
            mapView.removeOverlays(mapView.overlays)
            // Remove only the start/end markers, never the live selection marker.
            let staticMarkers = mapView.annotations.compactMap { $0 as? FlightAnnotation }.filter { !$0.isSelected }
            mapView.removeAnnotations(staticMarkers)

            if points.count >= 2 {
                let coordinates = points.map { $0.coordinate }
                let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
                mapView.addOverlay(polyline)

                if let first = points.first, let last = points.last {
                    mapView.addAnnotations([
                        FlightAnnotation(coordinate: first.coordinate, title: "Start", isStart: true, isSelected: false),
                        FlightAnnotation(coordinate: last.coordinate, title: "End", isStart: false, isSelected: false)
                    ])
                }
                // Set the visible region only on initial load, not when selection changes.
                if coordinator.initialRegionSet == false {
                    let padding = UIEdgeInsets(top: 50, left: 50, bottom: 50, right: 50)
                    mapView.setVisibleMapRect(polyline.boundingMapRect, edgePadding: padding, animated: false)
                    coordinator.initialRegionSet = true
                }
            }
        }

        // Update ONLY the selected-position marker on scrub.
        if let existing = coordinator.selectedAnnotation {
            mapView.removeAnnotation(existing)
            coordinator.selectedAnnotation = nil
        }
        if let selected = selectedPoint {
            let annotation = FlightAnnotation(coordinate: selected.coordinate, title: "Position", isStart: false, isSelected: true)
            mapView.addAnnotation(annotation)
            coordinator.selectedAnnotation = annotation
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var initialRegionSet = false
        /// Number of track points the static layer was last built for (-1 = not yet built). (PR-26)
        var builtPointCount = -1
        /// The live selection marker, updated in place on scrub. (PR-26)
        var selectedAnnotation: FlightAnnotation?

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

    /// Downsample target for the overview chart line.
    private static let maxChartPoints = 400

    // PR-26: the altitude line and Y-range are computed ONCE (the line downsampled to ~400 points),
    // cached in @State, and populated in onAppear — instead of being O(n) computed properties that
    // re-ran on every body re-evaluation during a scrub of a multi-hour flight.
    @State private var altitudeData: [(time: Date, altitude: Double)] = []
    @State private var altitudeRange: ClosedRange<Double> = 0...1000

    /// Populate the cached chart line + Y-range once. The line is stride-downsampled; the Y-range is
    /// taken from the FULL track so a peak between samples never clips the axis. (PR-26)
    private func populateAltitudeCacheIfNeeded() {
        guard altitudeData.isEmpty, !gpsTrack.isEmpty else { return }
        altitudeData = Self.downsampledAltitude(gpsTrack, maxPoints: Self.maxChartPoints)
        let altsFeet = gpsTrack.map { $0.altitude * 3.28084 }
        altitudeRange = Self.paddedAltitudeRange(min: altsFeet.min() ?? 0, max: altsFeet.max() ?? 1000)
    }

    /// Stride-downsample the track to feet-altitude points, always keeping the last point so the
    /// chart spans the full flight.
    static func downsampledAltitude(_ track: [GPSPoint], maxPoints: Int) -> [(time: Date, altitude: Double)] {
        let feet = track.map { (time: $0.timestamp, altitude: $0.altitude * 3.28084) }
        guard feet.count > maxPoints, maxPoints > 1 else { return feet }
        let step = Double(feet.count - 1) / Double(maxPoints - 1)
        var result: [(time: Date, altitude: Double)] = []
        result.reserveCapacity(maxPoints + 1)
        var pos = 0.0
        while Int(pos.rounded()) < feet.count {
            result.append(feet[Int(pos.rounded())])
            pos += step
        }
        if let last = feet.last, result.last?.time != last.time { result.append(last) }
        return result
    }

    /// Y-range with 500 ft padding, snapped to 100 ft, never below 0.
    static func paddedAltitudeRange(min minAlt: Double, max maxAlt: Double) -> ClosedRange<Double> {
        let lowerBound = Swift.max(0, floor((minAlt - 500) / 100) * 100)
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

    /// Find the altitude at the selected time. Binary search (O(log n)) over the chronological track
    /// instead of an O(n) `min(by:)` on every scrub frame. (PR-26)
    private var selectedAltitude: Double? {
        guard let time = selectedTime else { return nil }
        return gpsTrack.closestByTimestamp(to: time).map { $0.altitude * 3.28084 }
    }

    var body: some View {
        if gpsTrack.isEmpty {
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
            .onAppear { populateAltitudeCacheIfNeeded() }
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

/// Present a UIActivityViewController for an image directly via UIKit,
/// bypassing SwiftUI sheet timing issues that can cause grey/empty sheets on first invocation.
@MainActor
func presentImageShareSheet(image: UIImage) {
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("AeroCheck_Flight_\(UUID().uuidString.prefix(8)).jpg")
    if let jpegData = image.jpegData(compressionQuality: 0.9) {
        try? jpegData.write(to: tempURL)
    }

    let activityVC = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)

    // Find the topmost presented view controller
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let rootVC = windowScene.windows.first(where: \.isKeyWindow)?.rootViewController else {
        return
    }
    var topVC = rootVC
    while let presented = topVC.presentedViewController {
        topVC = presented
    }

    // For iPad: configure popover source to center of screen
    if let popover = activityVC.popoverPresentationController {
        popover.sourceView = topVC.view
        popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
    }

    topVC.present(activityVC, animated: true)
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

// MARK: - Share Card Color Scheme

/// Color scheme options for the flight share card
enum ShareCardColorScheme: String, Codable, CaseIterable, Identifiable {
    case light        // White/light gray background
    case lightBlue    // Aviation blue (pre-redesign look)
    case darkBlue     // Current dark navy (default)
    case dark         // Pure black OLED

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: return "Light"
        case .lightBlue: return "Aviation"
        case .darkBlue: return "Navy"
        case .dark: return "Dark"
        }
    }

    var backgroundColor: Color {
        switch self {
        case .light: return Color(red: 0.96, green: 0.96, blue: 0.97)
        case .lightBlue: return Color(red: 0.1, green: 0.2, blue: 0.4) // aviationBlue
        case .darkBlue: return Color(red: 0.04, green: 0.05, blue: 0.09)
        case .dark: return .black
        }
    }

    var primaryTextColor: Color {
        switch self {
        case .light: return Color(red: 0.1, green: 0.1, blue: 0.12)
        case .lightBlue, .darkBlue, .dark: return .white
        }
    }

    var secondaryTextColor: Color {
        switch self {
        case .light: return Color(red: 0.4, green: 0.4, blue: 0.45)
        case .lightBlue: return .white.opacity(0.6)
        case .darkBlue: return .white.opacity(0.5)
        case .dark: return .white.opacity(0.5)
        }
    }

    var tertiaryTextColor: Color {
        switch self {
        case .light: return Color(red: 0.55, green: 0.55, blue: 0.6)
        case .lightBlue: return .white.opacity(0.4)
        case .darkBlue: return .white.opacity(0.35)
        case .dark: return .white.opacity(0.35)
        }
    }

    var accentColor: Color {
        switch self {
        case .light: return .aviationBlue
        case .lightBlue: return .aviationGold
        case .darkBlue: return .aviationGold
        case .dark: return .aviationGold
        }
    }

    var cardOverlayColor: Color {
        switch self {
        case .light: return Color.black.opacity(0.04)
        case .lightBlue: return .white.opacity(0.08)
        case .darkBlue: return .white.opacity(0.05)
        case .dark: return .white.opacity(0.06)
        }
    }

    var cardBorderColor: Color {
        switch self {
        case .light: return Color.black.opacity(0.06)
        case .lightBlue: return .white.opacity(0.1)
        case .darkBlue: return .white.opacity(0.06)
        case .dark: return .white.opacity(0.08)
        }
    }

    var sparklineColor: Color {
        switch self {
        case .light: return .aviationBlue
        case .lightBlue: return .altimeterBlue
        case .darkBlue: return .altimeterBlue
        case .dark: return .altimeterBlue
        }
    }

    var mapBorderColor: Color {
        switch self {
        case .light: return Color.black.opacity(0.08)
        case .lightBlue: return .white.opacity(0.12)
        case .darkBlue: return .white.opacity(0.08)
        case .dark: return .white.opacity(0.1)
        }
    }

    var routeDotColor: Color {
        switch self {
        case .light: return Color(red: 0.3, green: 0.3, blue: 0.35)
        case .lightBlue, .darkBlue, .dark: return .white.opacity(0.6)
        }
    }

    var routeLineColor: Color {
        switch self {
        case .light: return Color.black.opacity(0.15)
        case .lightBlue, .darkBlue, .dark: return .white.opacity(0.2)
        }
    }

    var footerTextColor: Color {
        switch self {
        case .light: return Color.black.opacity(0.25)
        case .lightBlue, .darkBlue, .dark: return .white.opacity(0.4)
        }
    }

    var footerUrlColor: Color {
        switch self {
        case .light: return Color.black.opacity(0.18)
        case .lightBlue, .darkBlue, .dark: return .white.opacity(0.25)
        }
    }

    var footerIconColor: Color {
        switch self {
        case .light: return .aviationBlue.opacity(0.5)
        case .lightBlue, .darkBlue, .dark: return .aviationGold.opacity(0.6)
        }
    }

    var mapTraitStyle: UIUserInterfaceStyle {
        switch self {
        case .light: return .light
        case .lightBlue, .darkBlue, .dark: return .dark
        }
    }

    /// The color shown as a dot in the color scheme selector
    var dotColor: Color {
        switch self {
        case .light: return Color(red: 0.92, green: 0.92, blue: 0.94)
        case .lightBlue: return Color(red: 0.1, green: 0.2, blue: 0.4)
        case .darkBlue: return Color(red: 0.06, green: 0.08, blue: 0.18)
        case .dark: return .black
        }
    }
}

// MARK: - Share Card Map Layer

/// Map layer options for the flight share card
enum ShareCardMapLayer: String, Codable, CaseIterable, Identifiable {
    case standard
    case satellite
    case icao
    case segelflugkarte
    case swissimage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .satellite: return "Satellite"
        case .icao: return "ICAO Chart"
        case .segelflugkarte: return "Segelflugkarte"
        case .swissimage: return "SWISSIMAGE"
        }
    }

    var icon: String {
        switch self {
        case .standard: return "map"
        case .satellite: return "globe.americas"
        case .icao: return "airplane"
        case .segelflugkarte: return "map.fill"
        case .swissimage: return "photo"
        }
    }

    var isSwissOnly: Bool {
        switch self {
        case .standard, .satellite: return false
        case .icao, .segelflugkarte, .swissimage: return true
        }
    }

    /// WMTS layer identifier for swisstopo
    var swisstopoLayerIdentifier: String? {
        switch self {
        case .standard, .satellite: return nil
        case .icao: return "ch.bazl.luftfahrtkarten-icao"
        case .segelflugkarte: return "ch.bazl.segelflugkarte"
        case .swissimage: return "ch.swisstopo.swissimage"
        }
    }

    /// File extension for WMTS tiles
    var tileExtension: String {
        switch self {
        case .standard, .satellite, .icao, .segelflugkarte: return "png"
        case .swissimage: return "jpeg"
        }
    }

    /// Path color override for layers where the default accent (gold) isn't visible
    var pathColorOverride: Color? {
        switch self {
        case .icao, .segelflugkarte: return Color(red: 0.9, green: 0.0, blue: 0.6) // Magenta
        case .standard, .satellite, .swissimage: return nil
        }
    }

    /// Recommended zoom level for share card snapshots
    var snapshotZoomLevel: Int {
        switch self {
        case .standard, .satellite: return 10
        case .icao: return 10
        case .segelflugkarte: return 11
        case .swissimage: return 12
        }
    }
}

// MARK: - Share Card Customization View

/// Spotify-style customization view for share cards.
/// Shows a live preview with color scheme dots and map layer picker.
struct ShareCardCustomizationView: View {
    let flight: Flight
    @ObservedObject var appState: AppState

    @Environment(\.dismiss) private var dismiss

    @State private var selectedScheme: ShareCardColorScheme
    @State private var selectedMapLayer: ShareCardMapLayer
    @State private var showTerrain: Bool = false
    @State private var terrainData: [(time: Date, elevationFeet: Double)] = []
    @State private var isLoadingTerrain = false
    @State private var previewMapImage: UIImage?
    @State private var isLoadingMap = false
    @State private var isGeneratingShare = false

    private let elevationService = ElevationService()

    init(flight: Flight, appState: AppState) {
        self.flight = flight
        self.appState = appState
        _selectedScheme = State(initialValue: appState.settings.shareCardColorScheme)
        _selectedMapLayer = State(initialValue: appState.settings.shareCardMapLayer)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.cockpitBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Card preview (scaled down)
                    cardPreview
                        .padding(.top, 12)
                        .padding(.horizontal, 24)

                    Spacer(minLength: 16)

                    // Map layer picker
                    mapLayerPicker
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)

                    // Color scheme dots + terrain toggle
                    HStack {
                        colorSchemePicker

                        Spacer()

                        // Terrain toggle
                        terrainToggle
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)

                    // Share button
                    shareButton
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                }
            }
            .navigationTitle("Share Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Button.close) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await loadMapPreview()
        }
        .onChange(of: selectedMapLayer) { _, _ in
            Task { await loadMapPreview() }
        }
        .onChange(of: selectedScheme) { _, _ in
            // For standard/satellite, regenerate with new trait style
            if !selectedMapLayer.isSwissOnly {
                Task { await loadMapPreview() }
            }
        }
        .onChange(of: showTerrain) { _, newValue in
            if newValue && terrainData.isEmpty {
                Task { await loadTerrainData() }
            }
        }
    }

    // MARK: - Card Preview

    private var cardPreview: some View {
        GeometryReader { geometry in
            let maxWidth = geometry.size.width
            let maxHeight = geometry.size.height
            let cardAspect: CGFloat = 1080.0 / 1920.0
            let previewWidth = min(maxWidth, maxHeight * cardAspect)
            let previewHeight = previewWidth / cardAspect

            ZStack {
                FlightShareCard(
                    flight: flight,
                    mapImage: previewMapImage,
                    useUTC: appState.settings.alwaysUseUTC,
                    colorScheme: selectedScheme,
                    terrainData: showTerrain ? terrainData : []
                )
                .scaleEffect(previewWidth / 1080.0)
                .frame(width: previewWidth, height: previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                if isLoadingMap {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.black.opacity(0.4))
                        .frame(width: previewWidth, height: previewHeight)
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.5)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Map Layer Picker

    private var mapLayerPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MAP STYLE")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.secondaryText)
                .tracking(1.5)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ShareCardMapLayer.allCases) { layer in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedMapLayer = layer
                                appState.settings.shareCardMapLayer = layer
                                appState.saveSettings()
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: layer.icon)
                                    .font(.system(size: 13, weight: .medium))

                                Text(layer.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                Capsule()
                                    .fill(selectedMapLayer == layer ? Color.aviationGold : Color.cardBackground)
                            )
                            .foregroundColor(selectedMapLayer == layer ? .black : .white)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Color Scheme Picker

    private var colorSchemePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("COLOR THEME")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.secondaryText)
                .tracking(1.5)

            HStack(spacing: 12) {
                ForEach(ShareCardColorScheme.allCases) { scheme in
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedScheme = scheme
                            appState.settings.shareCardColorScheme = scheme
                            appState.saveSettings()
                        }
                    }) {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(scheme.dotColor)
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Circle()
                                            .stroke(
                                                scheme == .dark || scheme == .darkBlue ? Color.white.opacity(0.2) : Color.black.opacity(0.1),
                                                lineWidth: 1
                                            )
                                    )

                                if selectedScheme == scheme {
                                    Circle()
                                        .stroke(Color.aviationGold, lineWidth: 2.5)
                                        .frame(width: 40, height: 40)
                                }
                            }
                            .frame(width: 44, height: 44)

                            Text(scheme.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(selectedScheme == scheme ? .aviationGold : .secondaryText)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Terrain Toggle

    private var terrainToggle: some View {
        VStack(alignment: .center, spacing: 8) {
            Text("TERRAIN")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.secondaryText)
                .tracking(1.5)

            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showTerrain.toggle()
                }
            }) {
                VStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(showTerrain ? Color(red: 0.45, green: 0.32, blue: 0.18) : Color.cardBackground)
                            .frame(width: 32, height: 32)
                            .overlay(
                                Group {
                                    if isLoadingTerrain {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                            .tint(.white)
                                    } else {
                                        Image(systemName: "mountain.2.fill")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(showTerrain ? .white : .secondaryText)
                                    }
                                }
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(showTerrain ? Color(red: 0.45, green: 0.32, blue: 0.18) : Color.white.opacity(0.2), lineWidth: showTerrain ? 2.5 : 1)
                            )
                    }
                    .frame(width: 44, height: 44)

                    Text(isLoadingTerrain ? "..." : (showTerrain ? "On" : "Off"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(showTerrain ? Color(red: 0.65, green: 0.48, blue: 0.28) : .secondaryText)
                }
            }
            .disabled(isLoadingTerrain)
        }
    }

    // MARK: - Share Button

    private var shareButton: some View {
        Button(action: {
            Task { await generateAndShare() }
        }) {
            HStack(spacing: 8) {
                if isGeneratingShare {
                    ProgressView()
                        .tint(.black)
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
                Text("Share")
                    .font(.system(size: 18, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.aviationGold)
            )
            .foregroundColor(.black)
        }
        .disabled(isGeneratingShare)
    }

    // MARK: - Helpers

    private func loadMapPreview() async {
        isLoadingMap = true
        let image = await generateMapSnapshotForCustomization(
            flight: flight,
            mapLayer: selectedMapLayer,
            cardColorScheme: selectedScheme
        )
        await MainActor.run {
            previewMapImage = image
            isLoadingMap = false
        }
    }

    private func loadTerrainData() async {
        isLoadingTerrain = true

        let trackPoints = flight.gpsTrack.map { point in
            (coordinate: point.coordinate, timestamp: point.timestamp)
        }

        let results = await elevationService.fetchTrackTerrainProfile(
            gpsTrack: trackPoints,
            targetSamples: 80
        )

        await MainActor.run {
            // Convert meters to feet
            terrainData = results.map { (time: $0.time, elevationFeet: $0.elevationMeters * 3.28084) }
            isLoadingTerrain = false
            // If terrain data couldn't be fetched, turn off the toggle
            if terrainData.isEmpty {
                showTerrain = false
            }
        }
    }

    @MainActor
    private func generateAndShare() async {
        isGeneratingShare = true

        // Reuse the already-loaded preview map image to avoid re-downloading tiles
        let mapImage = previewMapImage
        let scheme = selectedScheme
        let currentTerrainData = showTerrain ? terrainData : []
        let utc = appState.settings.alwaysUseUTC
        let flightData = flight

        // Render the share card image
        // ImageRenderer must run on MainActor but we capture all values first
        let shareCard = FlightShareCard(
            flight: flightData,
            mapImage: mapImage,
            useUTC: utc,
            colorScheme: scheme,
            terrainData: currentTerrainData
        )
        let renderer = ImageRenderer(content: shareCard)
        renderer.scale = 2.0
        // Propose explicit size to help ImageRenderer resolve the layout
        renderer.proposedSize = ProposedViewSize(width: 1080, height: 1920)

        // ImageRenderer can return nil on first invocation for complex views.
        // Retry up to 3 times with brief yields to let the rendering pipeline warm up.
        var uiImage: UIImage?
        for attempt in 0..<3 {
            uiImage = renderer.uiImage
            if uiImage != nil { break }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
            }
        }

        guard let renderedImage = uiImage else {
            isGeneratingShare = false
            return
        }

        // Compress to JPEG on a background thread to not block UI
        let finalImage: UIImage = await Task.detached(priority: .userInitiated) {
            if let jpegData = renderedImage.jpegData(compressionQuality: 0.85),
               let compressed = UIImage(data: jpegData) {
                return compressed
            }
            return renderedImage
        }.value

        isGeneratingShare = false

        // Present share sheet directly via UIKit — avoids SwiftUI's two-sheet
        // transition race condition that causes grey/empty sheets on first export
        presentImageShareSheet(image: finalImage)
    }

    /// Standalone map snapshot generator for the customization view
    private func generateMapSnapshotForCustomization(
        flight: Flight,
        mapLayer: ShareCardMapLayer,
        cardColorScheme: ShareCardColorScheme
    ) async -> UIImage? {
        guard flight.gpsTrack.count >= 2 else { return nil }

        let coordinates = flight.gpsTrack.map { $0.coordinate }
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        let mapRect = polyline.boundingMapRect

        let targetWidth: CGFloat = 2032
        let targetHeight: CGFloat = 1500
        let targetAspectRatio = targetWidth / targetHeight

        let paddingFactor = 0.15
        var paddedRect = mapRect.insetBy(
            dx: -mapRect.size.width * paddingFactor,
            dy: -mapRect.size.height * paddingFactor
        )

        let currentAspectRatio = paddedRect.size.width / paddedRect.size.height
        if currentAspectRatio > targetAspectRatio {
            let newHeight = paddedRect.size.width / targetAspectRatio
            let heightDiff = newHeight - paddedRect.size.height
            paddedRect.origin.y -= heightDiff / 2
            paddedRect.size.height = newHeight
        } else {
            let newWidth = paddedRect.size.height * targetAspectRatio
            let widthDiff = newWidth - paddedRect.size.width
            paddedRect.origin.x -= widthDiff / 2
            paddedRect.size.width = newWidth
        }

        // Swiss layers: WMTS tile compositing
        if mapLayer.isSwissOnly, let layerId = mapLayer.swisstopoLayerIdentifier {
            let pathColor = mapLayer.pathColorOverride ?? cardColorScheme.accentColor
            return await generateSwissLayerSnapshotStandalone(
                layerIdentifier: layerId,
                tileExtension: mapLayer.tileExtension,
                zoomLevel: mapLayer.snapshotZoomLevel,
                paddedRect: paddedRect,
                coordinates: coordinates,
                targetSize: CGSize(width: targetWidth, height: targetHeight),
                accentColor: pathColor
            )
        }

        // Standard / Satellite
        let options = MKMapSnapshotter.Options()
        options.mapRect = paddedRect
        options.size = CGSize(width: targetWidth, height: targetHeight)
        options.scale = UITraitCollection.current.displayScale
        options.traitCollection = UITraitCollection(userInterfaceStyle: cardColorScheme.mapTraitStyle)
        options.mapType = mapLayer == .satellite ? .satellite : .standard

        let snapshotter = MKMapSnapshotter(options: options)

        do {
            let snapshot = try await snapshotter.start()
            return drawRouteOnSnapshotStandalone(
                snapshot: snapshot,
                coordinates: coordinates,
                accentColor: cardColorScheme.accentColor
            )
        } catch {
            print("Map snapshot error: \(error)")
            return nil
        }
    }

    private func drawRouteOnSnapshotStandalone(snapshot: MKMapSnapshotter.Snapshot, coordinates: [CLLocationCoordinate2D], accentColor: Color) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: snapshot.image.size)
        return renderer.image { rendererContext in
            snapshot.image.draw(at: .zero)
            let context = rendererContext.cgContext

            context.setStrokeColor(UIColor(accentColor).cgColor)
            context.setLineWidth(6 * UITraitCollection.current.displayScale)
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

            if let firstCoord = coordinates.first {
                let startPoint = snapshot.point(for: firstCoord)
                drawMarkerStandalone(at: startPoint, color: UIColor(Color.aviationGreen), in: context, scale: UITraitCollection.current.displayScale)
            }
            if let lastCoord = coordinates.last {
                let endPoint = snapshot.point(for: lastCoord)
                drawMarkerStandalone(at: endPoint, color: UIColor(Color.aviationRed), in: context, scale: UITraitCollection.current.displayScale)
            }
        }
    }

    private func generateSwissLayerSnapshotStandalone(
        layerIdentifier: String,
        tileExtension: String,
        zoomLevel: Int,
        paddedRect: MKMapRect,
        coordinates: [CLLocationCoordinate2D],
        targetSize: CGSize,
        accentColor: Color
    ) async -> UIImage? {
        let northWest = MKMapPoint(x: paddedRect.minX, y: paddedRect.minY).coordinate
        let southEast = MKMapPoint(x: paddedRect.maxX, y: paddedRect.maxY).coordinate

        let z = FlightDetailView.optimalZoomLevel(
            minLat: southEast.latitude, maxLat: northWest.latitude,
            minLon: northWest.longitude, maxLon: southEast.longitude,
            targetWidth: targetSize.width, tileSize: 256,
            layerMinZoom: 7, layerMaxZoom: zoomLevel
        )

        let minTileX = FlightDetailView.lonToTileX(lon: northWest.longitude, zoom: z)
        let maxTileX = FlightDetailView.lonToTileX(lon: southEast.longitude, zoom: z)
        let minTileY = FlightDetailView.latToTileY(lat: northWest.latitude, zoom: z)
        let maxTileY = FlightDetailView.latToTileY(lat: southEast.latitude, zoom: z)

        let tileXRange = min(minTileX, maxTileX)...max(minTileX, maxTileX)
        let tileYRange = min(minTileY, maxTileY)...max(minTileY, maxTileY)

        let tileSize: CGFloat = 256

        var tileImages: [String: UIImage] = [:]
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for tileX in tileXRange {
                for tileY in tileYRange {
                    let key = "\(tileX)-\(tileY)"
                    group.addTask {
                        let urlString = "https://wmts.geo.admin.ch/1.0.0/\(layerIdentifier)/default/current/3857/\(z)/\(tileX)/\(tileY).\(tileExtension)"
                        guard let url = URL(string: urlString),
                              let (data, response) = try? await URLSession.shared.data(from: url),
                              let httpResponse = response as? HTTPURLResponse,
                              httpResponse.statusCode == 200,
                              let image = UIImage(data: data) else {
                            return (key, nil)
                        }
                        return (key, image)
                    }
                }
            }
            for await (key, image) in group {
                if let image = image { tileImages[key] = image }
            }
        }

        if tileImages.isEmpty { return nil }

        // Calculate tile grid geo-bounds
        let tileOriginLon = FlightDetailView.tileXToLon(tileX: tileXRange.lowerBound, zoom: z)
        let tileOriginLat = FlightDetailView.tileYToLat(tileY: tileYRange.lowerBound, zoom: z)
        let tileEndLon = FlightDetailView.tileXToLon(tileX: tileXRange.upperBound + 1, zoom: z)
        let tileEndLat = FlightDetailView.tileYToLat(tileY: tileYRange.upperBound + 1, zoom: z)

        let lonRange = tileEndLon - tileOriginLon
        let latRange = tileOriginLat - tileEndLat

        guard lonRange > 0, latRange > 0 else { return nil }

        let tilesWide = CGFloat(tileXRange.count)
        let tilesHigh = CGFloat(tileYRange.count)
        let compositeWidth = tilesWide * tileSize
        let compositeHeight = tilesHigh * tileSize

        // Calculate fractional crop within the tile grid
        let cropFracXStart = (northWest.longitude - tileOriginLon) / lonRange
        let cropFracXEnd = (southEast.longitude - tileOriginLon) / lonRange
        let cropFracYStart = (tileOriginLat - northWest.latitude) / latRange
        let cropFracYEnd = (tileOriginLat - southEast.latitude) / latRange
        let cropFracWidth = cropFracXEnd - cropFracXStart
        let cropFracHeight = cropFracYEnd - cropFracYStart

        guard cropFracWidth > 0, cropFracHeight > 0 else { return nil }

        let scaleX = targetSize.width / (cropFracWidth * compositeWidth)
        let scaleY = targetSize.height / (cropFracHeight * compositeHeight)
        let offsetX = -cropFracXStart * compositeWidth * scaleX
        let offsetY = -cropFracYStart * compositeHeight * scaleY

        let finalRenderer = UIGraphicsImageRenderer(size: targetSize)
        return finalRenderer.image { ctx in
            let context = ctx.cgContext

            // Draw tiles
            for tileX in tileXRange {
                for tileY in tileYRange {
                    let key = "\(tileX)-\(tileY)"
                    if let tileImg = tileImages[key] {
                        let xPos = CGFloat(tileX - tileXRange.lowerBound) * tileSize * scaleX + offsetX
                        let yPos = CGFloat(tileY - tileYRange.lowerBound) * tileSize * scaleY + offsetY
                        tileImg.draw(in: CGRect(x: xPos, y: yPos, width: tileSize * scaleX, height: tileSize * scaleY))
                    }
                }
            }

            func geoToPoint(_ coord: CLLocationCoordinate2D) -> CGPoint {
                let fracX = (coord.longitude - tileOriginLon) / lonRange
                let fracY = (tileOriginLat - coord.latitude) / latRange
                return CGPoint(
                    x: fracX * compositeWidth * scaleX + offsetX,
                    y: fracY * compositeHeight * scaleY + offsetY
                )
            }

            context.setStrokeColor(UIColor(accentColor).cgColor)
            context.setLineWidth(14)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            let path = UIBezierPath()
            for (index, coordinate) in coordinates.enumerated() {
                let point = geoToPoint(coordinate)
                if index == 0 { path.move(to: point) }
                else { path.addLine(to: point) }
            }
            context.addPath(path.cgPath)
            context.strokePath()

            if let firstCoord = coordinates.first {
                drawMarkerStandalone(at: geoToPoint(firstCoord), color: UIColor(Color.aviationGreen), in: context, scale: 2.0)
            }
            if let lastCoord = coordinates.last {
                drawMarkerStandalone(at: geoToPoint(lastCoord), color: UIColor(Color.aviationRed), in: context, scale: 2.0)
            }
        }
    }

    private func drawMarkerStandalone(at point: CGPoint, color: UIColor, in context: CGContext, scale: CGFloat) {
        let markerSize: CGFloat = 20 * scale
        let rect = CGRect(x: point.x - markerSize / 2, y: point.y - markerSize / 2, width: markerSize, height: markerSize)
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(2 * scale)
        context.strokeEllipse(in: rect)
    }
}

// MARK: - Flight Share Card

/// A portrait card view designed for sharing flight summaries on mobile
/// Renders at 1080x1920 (9:16 aspect ratio, standard mobile/stories format)
struct FlightShareCard: View {
    let flight: Flight
    let mapImage: UIImage?
    let useUTC: Bool
    var colorScheme: ShareCardColorScheme = .darkBlue
    var terrainData: [(time: Date, elevationFeet: Double)] = []

    // Card dimensions (9:16 aspect ratio for Instagram/WhatsApp/Signal stories)
    private let cardWidth: CGFloat = 1080
    private let cardHeight: CGFloat = 1920

    // MARK: - Computed Properties

    /// Aircraft registration or airplane ID
    private var aircraftIdentifier: String {
        flight.aircraftRegistration ?? flight.airplane
    }

    /// Aircraft type display name (e.g. "PA-28-181", "WT9 Dynamic")
    private var aircraftTypeDisplay: String? {
        flight.aircraftType
    }

    /// Route string: "LSGG → LSZB" or nil if no airports
    private var routeString: String? {
        guard let dep = flight.departureAirportIdent, let arr = flight.arrivalAirportIdent else {
            return nil
        }
        return "\(dep) → \(arr)"
    }

    /// Display title: route, flight name, or aircraft identifier
    private var displayTitle: String {
        if let route = routeString {
            return route
        } else if !flight.name.isEmpty {
            return flight.name
        }
        return aircraftIdentifier
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

    /// Route waypoints for the route strip (departure → waypoints → arrival)
    private var routeWaypoints: [String]? {
        var names: [String] = []

        // If there's a flight plan with waypoints, use those directly
        // (the flight plan already includes departure and arrival)
        if let waypoints = flight.flightPlan?.waypoints, !waypoints.isEmpty {
            names = waypoints.compactMap { $0.name.isEmpty ? nil : $0.name }
        }

        // If no flight plan waypoints, fall back to dep/arr airports
        if names.isEmpty {
            if let dep = flight.departureAirportIdent {
                names.append(dep)
            }
            if let arr = flight.arrivalAirportIdent, names.last != arr {
                names.append(arr)
            }
        }

        return names.count >= 2 ? names : nil
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
            // Background
            colorScheme.backgroundColor

            VStack(spacing: 0) {
                // Top bar: date + aircraft info
                topBarSection
                    .padding(.top, 50)
                    .padding(.horizontal, 48)

                // Title + flight time on same line
                titleSection
                    .padding(.top, 24)
                    .padding(.horizontal, 48)

                // Route strip (waypoints)
                if routeWaypoints != nil {
                    routeStripSection
                        .padding(.top, 20)
                        .padding(.horizontal, 48)
                }

                // Hero map (no overlaid stats)
                heroMapSection
                    .padding(.top, 24)
                    .padding(.horizontal, 32)

                // Stat pills row (below the map)
                statPillsRow
                    .padding(.top, 16)
                    .padding(.horizontal, 32)

                // Altitude sparkline
                altitudeSparkline
                    .padding(.top, 20)
                    .padding(.horizontal, 48)

                // Bottom stats row (takeoff/landing times)
                bottomStatsRow
                    .padding(.top, 20)
                    .padding(.horizontal, 48)

                Spacer(minLength: 16)

                // Footer branding
                footerSection
                    .padding(.bottom, 40)
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
                .foregroundColor(colorScheme.secondaryTextColor)
                .tracking(2)

            Spacer()

            // Aircraft identifier pill with type
            HStack(spacing: 10) {
                if let type = aircraftTypeDisplay {
                    Text(type)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(colorScheme.secondaryTextColor)
                }

                Text(aircraftIdentifier)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(colorScheme.accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(colorScheme.accentColor.opacity(0.15))
                    .overlay(
                        Capsule()
                            .stroke(colorScheme.accentColor.opacity(0.3), lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Title Section (name left, flight time right)

    private var titleSection: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                // Title (route, flight name, or aircraft)
                Text(displayTitle)
                    .font(.system(size: 52, weight: .bold, design: .default))
                    .foregroundColor(colorScheme.primaryTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                Spacer(minLength: 16)

                // Flight time
                Text(formattedExportFlightTime)
                    .font(.system(size: 46, weight: .bold, design: .monospaced))
                    .foregroundColor(colorScheme.accentColor)
                    .lineLimit(1)
            }

            // FLIGHT TIME label aligned right
            HStack {
                // Show flight name below if route is the main title
                if routeString != nil && !flight.name.isEmpty {
                    Text(flight.name)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(colorScheme.tertiaryTextColor)
                        .lineLimit(1)
                }

                Spacer()

                Text("FLIGHT TIME")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(colorScheme.tertiaryTextColor)
                    .tracking(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Route Strip

    private var routeStripSection: some View {
        Group {
            if let waypoints = routeWaypoints {
                let displayWaypoints: [String] = {
                    if waypoints.count <= 7 {
                        return waypoints
                    } else {
                        return [waypoints[0], waypoints[1], "···"] + waypoints.suffix(2)
                    }
                }()

                VStack(spacing: 0) {
                    // "ROUTE" label
                    HStack {
                        Text("ROUTE")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(colorScheme.tertiaryTextColor)
                            .tracking(3)
                        Spacer()
                    }
                    .padding(.bottom, 16)

                    // Combined dots, lines, and waypoint names
                    HStack(spacing: 0) {
                        ForEach(Array(displayWaypoints.enumerated()), id: \.offset) { index, name in
                            if index > 0 {
                                // Connecting line (flexible width)
                                VStack(spacing: 0) {
                                    Rectangle()
                                        .fill(colorScheme.routeLineColor)
                                        .frame(height: 4)
                                        .padding(.bottom, 30)
                                }
                            }

                            let isFirst = index == 0
                            let isLast = index == displayWaypoints.count - 1
                            let isEllipsis = name == "···"
                            let dotSize: CGFloat = (isFirst || isLast) ? 18 : 14
                            let wpDotColor: Color = isFirst ? .aviationGreen :
                                                  isLast ? .aviationRed :
                                                  isEllipsis ? .clear :
                                                  colorScheme.routeDotColor

                            if isEllipsis {
                                VStack(spacing: 8) {
                                    Text("···")
                                        .font(.system(size: 22, weight: .bold))
                                        .foregroundColor(colorScheme.tertiaryTextColor)
                                    Text("")
                                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                                }
                                .frame(width: 34)
                            } else {
                                // Dot + name stacked vertically
                                VStack(spacing: 8) {
                                    Circle()
                                        .fill(wpDotColor)
                                        .frame(width: dotSize, height: dotSize)

                                    Text(name)
                                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                                        .foregroundColor(isFirst || isLast ? colorScheme.primaryTextColor : colorScheme.secondaryTextColor)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.5)
                                }
                                .frame(minWidth: (isFirst || isLast) ? 56 : 34)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Hero Map (clean, no overlays)

    private var heroMapSection: some View {
        Group {
            if let mapImg = mapImage {
                Image(uiImage: mapImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 750)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(colorScheme.mapBorderColor, lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: 24)
                    .fill(colorScheme.cardOverlayColor)
                    .frame(height: 750)
                    .overlay(
                        VStack(spacing: 16) {
                            Image(systemName: "map")
                                .font(.system(size: 60))
                                .foregroundColor(colorScheme.tertiaryTextColor)
                            Text(L10n.FlightDetail.noGPSData)
                                .font(.system(size: 24))
                                .foregroundColor(colorScheme.tertiaryTextColor)
                        }
                    )
            }
        }
    }

    // MARK: - Stat Pills Row (below the map)

    private var statPillsRow: some View {
        HStack(spacing: 12) {
            mapStatPill(icon: "arrow.up.to.line", value: maxAltitudeFt.map { "\($0) ft" } ?? "—", label: "MAX ALT")

            mapStatPill(icon: "point.topleft.down.to.point.bottomright.curvepath.fill", value: distanceNM, label: "DISTANCE")

            if landingsCount > 0 {
                mapStatPill(icon: "airplane.arrival", value: "\(landingsCount)", label: landingsCount == 1 ? "LANDING" : "LANDINGS")
            }
        }
    }

    private func mapStatPill(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(colorScheme.accentColor)

            Text(value)
                .font(.system(size: 21, weight: .bold, design: .monospaced))
                .foregroundColor(colorScheme.primaryTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(colorScheme.secondaryTextColor)
                .tracking(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(colorScheme.cardOverlayColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(colorScheme.cardBorderColor, lineWidth: 1)
                )
        )
    }

    // MARK: - Altitude Sparkline

    private var altitudeSparkline: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Section label
            HStack {
                Text("ALTITUDE PROFILE")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(colorScheme.tertiaryTextColor)
                    .tracking(2)

                Spacer()

                if let maxAlt = maxAltitudeFt {
                    Text("PEAK \(maxAlt) FT")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(colorScheme.sparklineColor.opacity(0.7))
                }
            }

            if !altitudeData.isEmpty {
                ShareCardAltitudeChart(gpsTrack: flight.gpsTrack, sparklineColor: colorScheme.sparklineColor, terrainData: terrainData)
                    .frame(height: 160)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(colorScheme.cardOverlayColor.opacity(0.6))
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
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(colorScheme.cardOverlayColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(colorScheme.cardBorderColor, lineWidth: 1)
                )
        )
    }

    private func bottomStatItem(icon: String, value: String, label: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(color)

            Text(value)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundColor(colorScheme.primaryTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(colorScheme.tertiaryTextColor)
                .tracking(1)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer Section

    private var footerSection: some View {
        HStack {
            Spacer()

            // App branding
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "airplane.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(colorScheme.footerIconColor)

                    Text("AéroCheck")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(colorScheme.footerTextColor)
                }

                Text("https://aerocheck.app")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(colorScheme.footerUrlColor)
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
    var sparklineColor: Color = .altimeterBlue
    var terrainData: [(time: Date, elevationFeet: Double)] = []

    private static let terrainColor = Color(red: 0.45, green: 0.32, blue: 0.18)

    /// Unified data point with both altitude and interpolated terrain at the same timestamp
    private struct ChartDataPoint: Identifiable {
        let id = UUID()
        let time: Date
        let altitude: Double   // flight altitude in feet
        let terrain: Double    // ground elevation in feet
    }

    // PR-27: precompute once in init. These were computed properties that re-mapped the whole
    // gpsTrack on every access; the four Path closures and the per-point xPosition/yPosition
    // helpers each read them, making the render O(n²) on the main actor inside ImageRenderer.
    private let altitudeData: [(time: Date, altitude: Double)]
    private let altitudeRange: ClosedRange<Double>
    private let unifiedData: [ChartDataPoint]
    private let firstTime: Date?
    private let timeSpan: TimeInterval

    init(gpsTrack: [GPSPoint], sparklineColor: Color = .altimeterBlue,
         terrainData: [(time: Date, elevationFeet: Double)] = []) {
        self.gpsTrack = gpsTrack
        self.sparklineColor = sparklineColor
        self.terrainData = terrainData

        let altData = gpsTrack.map { (time: $0.timestamp, altitude: $0.altitude * 3.28084) }
        self.altitudeData = altData

        let range: ClosedRange<Double>
        if altData.isEmpty {
            range = 0...1000
        } else {
            let allValues = altData.map { $0.altitude } + terrainData.map { $0.elevationFeet }
            let minAlt = allValues.min() ?? 0
            let maxAlt = allValues.max() ?? 1000
            let lowerBound = max(0, floor((minAlt - 200) / 100) * 100)
            let upperBound = ceil((maxAlt + 200) / 100) * 100
            range = lowerBound...upperBound
        }
        self.altitudeRange = range

        self.unifiedData = altData.map { point in
            ChartDataPoint(
                time: point.time,
                altitude: point.altitude,
                terrain: ShareCardAltitudeChart.interpolatedTerrain(at: point.time, terrainData: terrainData) ?? range.lowerBound
            )
        }

        self.firstTime = altData.first?.time
        if let f = altData.first?.time, let l = altData.last?.time {
            self.timeSpan = l.timeIntervalSince(f)
        } else {
            self.timeSpan = 0
        }
    }

    /// Interpolate terrain elevation at a given time. Static so it can run during init (PR-27).
    private static func interpolatedTerrain(at time: Date, terrainData: [(time: Date, elevationFeet: Double)]) -> Double? {
        guard terrainData.count >= 2 else { return terrainData.first?.elevationFeet }
        let t = time.timeIntervalSince1970

        // Find surrounding terrain points
        for i in 0..<(terrainData.count - 1) {
            let t0 = terrainData[i].time.timeIntervalSince1970
            let t1 = terrainData[i + 1].time.timeIntervalSince1970
            if t >= t0 && t <= t1 {
                let fraction = (t1 - t0) > 0 ? (t - t0) / (t1 - t0) : 0
                let e0 = terrainData[i].elevationFeet
                let e1 = terrainData[i + 1].elevationFeet
                return e0 + fraction * (e1 - e0)
            }
        }

        // Outside range — clamp to nearest
        if t < terrainData.first!.time.timeIntervalSince1970 {
            return terrainData.first!.elevationFeet
        }
        return terrainData.last!.elevationFeet
    }

    // MARK: - Coordinate Mapping Helpers

    private func xPosition(for time: Date, in size: CGSize) -> CGFloat {
        // PR-27: use the precomputed firstTime/timeSpan instead of re-scanning altitudeData per call.
        guard let first = firstTime, timeSpan > 0 else { return 0 }
        return CGFloat(time.timeIntervalSince(first) / timeSpan) * size.width
    }

    private func yPosition(for value: Double, in size: CGSize) -> CGFloat {
        let range = altitudeRange.upperBound - altitudeRange.lowerBound
        guard range > 0 else { return size.height }
        return size.height - CGFloat((value - altitudeRange.lowerBound) / range) * size.height
    }

    var body: some View {
        if altitudeData.isEmpty {
            Text(L10n.FlightDetail.noAltitudeData)
                .font(.system(size: 18))
                .foregroundColor(sparklineColor.opacity(0.4))
        } else if !terrainData.isEmpty {
            // Path-based terrain rendering — SwiftUI Charts AreaMark always stacks
            // multiple series, so we use GeometryReader + ZStack + Path for true
            // painter's model layering (matching TerrainProfileView.swift pattern).
            GeometryReader { geometry in
                let size = geometry.size

                ZStack {
                    // 1) Altitude fill: baseline → flight altitude (blue, behind)
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: size.height))
                        for point in unifiedData {
                            path.addLine(to: CGPoint(
                                x: xPosition(for: point.time, in: size),
                                y: yPosition(for: point.altitude, in: size)
                            ))
                        }
                        path.addLine(to: CGPoint(x: size.width, y: size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(
                        colors: [sparklineColor.opacity(0.35), sparklineColor.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    ))

                    // 2) Terrain fill: baseline → terrain (brown, on top of blue)
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: size.height))
                        for point in unifiedData {
                            path.addLine(to: CGPoint(
                                x: xPosition(for: point.time, in: size),
                                y: yPosition(for: point.terrain, in: size)
                            ))
                        }
                        path.addLine(to: CGPoint(x: size.width, y: size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(
                        colors: [Self.terrainColor.opacity(0.9), Self.terrainColor.opacity(0.6)],
                        startPoint: .top, endPoint: .bottom
                    ))

                    // 3) Terrain outline
                    Path { path in
                        for (i, point) in unifiedData.enumerated() {
                            let pt = CGPoint(x: xPosition(for: point.time, in: size),
                                             y: yPosition(for: point.terrain, in: size))
                            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                        }
                    }
                    .stroke(Self.terrainColor, lineWidth: 1.5)

                    // 4) Altitude line (on top of everything)
                    Path { path in
                        for (i, point) in unifiedData.enumerated() {
                            let pt = CGPoint(x: xPosition(for: point.time, in: size),
                                             y: yPosition(for: point.altitude, in: size))
                            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                        }
                    }
                    .stroke(sparklineColor.opacity(0.9), lineWidth: 2.5)
                }
            }
        } else {
            // No terrain: original style
            Chart {
                ForEach(altitudeData, id: \.time) { point in
                    AreaMark(
                        x: .value("Time", point.time),
                        yStart: .value("Baseline", altitudeRange.lowerBound),
                        yEnd: .value("Altitude", point.altitude)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [sparklineColor.opacity(0.3), sparklineColor.opacity(0.02)],
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
                    .foregroundStyle(sparklineColor.opacity(0.8))
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
